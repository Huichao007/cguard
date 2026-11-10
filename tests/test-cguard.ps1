#Requires -Version 5.1
<#
.SYNOPSIS
    Self-test for cguard. Runs entirely inside a throwaway sandbox and never
    touches a real cache. Exits 0 when everything passes, 1 otherwise.

.DESCRIPTION
    The tool accepts -TargetsFile, so the whole engine can be pointed at a
    synthetic target list rooted in $env:TEMP. Every assertion below is about
    observable behaviour: what got measured, what got deleted, what survived.

    Note for future edits: build fixtures with @{ } hashtables. Writing
    ({ ... }) creates a scriptblock literal, and ConvertTo-Json will happily
    serialise its entire reflection tree instead of your data.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-cguard.ps1
#>

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$cguard = Join-Path $root 'cguard.ps1'
if (-not (Test-Path -LiteralPath $cguard)) { throw "cguard.ps1 not found at $cguard" }

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:Fail++ }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -eq "$Actual") { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:Pass++ }
    else {
        Write-Host "  FAIL  $Name  (expected '$Expected', got '$Actual')" -ForegroundColor Red
        $script:Fail++
    }
}

function New-Sandbox {
    $sb = Join-Path $env:TEMP ('cguard-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $sb | Out-Null
    return $sb
}

function New-File {
    param([string]$Path, [int]$KB = 4)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bytes = New-Object byte[] ($KB * 1024)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-Targets {
    param([string]$Path, $Targets)
    $doc = @{ version = 'test'; targets = @($Targets) }
    $json = $doc | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    return $Path
}

function Invoke-Cguard {
    param([string[]]$Arguments)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cguard, '-NoColor') + $Arguments
    $out = & powershell.exe @all 2>&1
    return ($out | Out-String)
}

function Get-ScanJson {
    param([string]$TargetsFile, [string[]]$Extra = @())
    $args = @('scan', '-Json', '-TargetsFile', $TargetsFile) + $Extra
    $raw = Invoke-Cguard $args
    if (-not $raw -or -not $raw.Contains('{')) {
        throw "scan -Json produced no JSON. raw output:`n$raw"
    }
    return ($raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json)
}

Write-Host ''
Write-Host '== cguard self-test =='
Write-Host ''

# ------------------------------------------------------------------ case 1
Write-Host 'case 1: engine measures only the declared target, ignores siblings'
$sb = New-Sandbox
$cacheDir = Join-Path $sb 'cache'
$siblingDir = Join-Path $sb 'sibling'
New-File (Join-Path $cacheDir 'a.bin') 64
New-File (Join-Path $cacheDir 'sub\b.bin') 64
New-File (Join-Path $siblingDir 'keep.bin') 512

$targets = Write-Targets -Path (Join-Path $sb 'targets.json') -Targets @{
    id = 'fake-cache'; tier = 'safe'; group = 'test'; label = 'fake cache'
    paths = @($cacheDir); minAgeDays = 0; keep = @(); reclaim = 'delete-contents'
}

$doc = Get-ScanJson -TargetsFile $targets
Assert-Equal 1 @($doc.targets).Count 'one target reported'
$bytes = [int64]$doc.targets[0].bytes
Assert-True ($bytes -ge 131072 -and $bytes -le 140000) ("size is ~128KB, not the 512KB sibling (got $bytes)")

# ------------------------------------------------------------------ case 2
Write-Host ''
Write-Host 'case 2: clean without -Force changes nothing'
$before = @(Get-ChildItem -LiteralPath $cacheDir -Recurse -File).Count
$dry = Invoke-Cguard @('clean', '-TargetsFile', $targets)
$after = @(Get-ChildItem -LiteralPath $cacheDir -Recurse -File).Count
Assert-Equal $before $after 'file count unchanged by dry run'
Assert-True ($dry -match 'would reclaim') 'dry run reports an estimate'
Assert-True ($dry -match 'nothing was deleted') 'dry run says so explicitly'

# ------------------------------------------------------------------ case 3
Write-Host ''
Write-Host 'case 3: clean -Force empties the target and leaves the sibling alone'
$apply = Invoke-Cguard @('clean', '-Force', '-TargetsFile', $targets)
$left = @(Get-ChildItem -LiteralPath $cacheDir -Recurse -File -ErrorAction SilentlyContinue)
Assert-Equal 0 $left.Count 'target cache is empty'
Assert-True (Test-Path -LiteralPath (Join-Path $siblingDir 'keep.bin')) 'sibling file survived'
Assert-True ($apply -match 'reclaimed') 'apply reports a reclaim number'
Assert-True (Test-Path -LiteralPath $cacheDir) 'target directory itself is kept, not removed'

# ------------------------------------------------------------------ case 4
Write-Host ''
Write-Host 'case 4: keep-list protects a live database inside a target'
$dbDir = Join-Path $sb 'dbdir'
New-File (Join-Path $dbDir 'session.db') 32
New-File (Join-Path $dbDir 'session.db-wal') 8
New-File (Join-Path $dbDir 'junk.bin') 64

$targets2 = Write-Targets -Path (Join-Path $sb 'targets2.json') -Targets @{
    id = 'fake-db'; tier = 'apps'; group = 'test'; label = 'fake db dir'
    paths = @($dbDir); minAgeDays = 0
    keep = @('session.db', 'session.db-wal')
    reclaim = 'delete-contents'
}

$null = Invoke-Cguard @('clean', '-Force', '-TargetsFile', $targets2)
Assert-True (Test-Path -LiteralPath (Join-Path $dbDir 'session.db')) 'session.db survived the keep list'
Assert-True (Test-Path -LiteralPath (Join-Path $dbDir 'session.db-wal')) 'session.db-wal survived the keep list'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $dbDir 'junk.bin'))) 'junk.bin was removed'

# ------------------------------------------------------------------ case 5
Write-Host ''
Write-Host 'case 5: subdirs reclaim mode only touches the listed children'
$agentDir = Join-Path $sb 'agent'
New-File (Join-Path $agentDir 'agent.db') 32
New-File (Join-Path $agentDir 'shell\a.txt') 64
New-File (Join-Path $agentDir 'tool-output\b.txt') 64
New-File (Join-Path $agentDir 'important\c.txt') 64

$targets3 = Write-Targets -Path (Join-Path $sb 'targets3.json') -Targets @{
    id = 'fake-agent'; tier = 'apps'; group = 'test'; label = 'fake agent dir'
    paths = @($agentDir); minAgeDays = 0; keep = @('agent.db')
    reclaim = 'subdirs'
    subdirs = @(
        @{ name = 'shell'; minAgeDays = 0 },
        @{ name = 'tool-output'; minAgeDays = 0 }
    )
}

$sub = Invoke-Cguard @('scan', '-Json', '-TargetsFile', $targets3)
$doc3 = $sub.Substring($sub.IndexOf('{')) | ConvertFrom-Json
$bytes3 = [int64]$doc3.targets[0].bytes
Assert-True ($bytes3 -ge 131072 -and $bytes3 -le 140000) ("scan counts only listed children (got $bytes3)")

$sub = Invoke-Cguard @('clean', '-Force', '-TargetsFile', $targets3)
Assert-True (-not (Test-Path -LiteralPath (Join-Path $agentDir 'shell\a.txt'))) 'shell child emptied'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $agentDir 'tool-output\b.txt'))) 'tool-output child emptied'
Assert-True (Test-Path -LiteralPath (Join-Path $agentDir 'important\c.txt')) 'unlisted child untouched'
Assert-True (Test-Path -LiteralPath (Join-Path $agentDir 'agent.db')) 'database untouched'
Assert-True ($sub -match 'fake-agent') 'subdir target shows up in the clean output'

# ------------------------------------------------------------------ case 6
Write-Host ''
Write-Host 'case 6: minAgeDays leaves fresh files alone'
$agedDir = Join-Path $sb 'aged'
New-File (Join-Path $agedDir 'fresh.bin') 64
New-File (Join-Path $agedDir 'old.bin') 64
(Get-Item -LiteralPath (Join-Path $agedDir 'old.bin')).LastWriteTime = (Get-Date).AddDays(-30)

$targets4 = Write-Targets -Path (Join-Path $sb 'targets4.json') -Targets @{
    id = 'fake-aged'; tier = 'safe'; group = 'test'; label = 'aged cache'
    paths = @($agedDir); minAgeDays = 7; keep = @(); reclaim = 'delete-contents'
}

$null = Invoke-Cguard @('clean', '-Force', '-TargetsFile', $targets4)
Assert-True (Test-Path -LiteralPath (Join-Path $agedDir 'fresh.bin')) 'fresh file kept'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $agedDir 'old.bin'))) 'old file removed'

# ------------------------------------------------------------------ case 7
Write-Host ''
Write-Host 'case 7: -Only narrows the run'
$onlyDir = Join-Path $sb 'only'
New-File (Join-Path $onlyDir 'x.bin') 64
$targets5 = Write-Targets -Path (Join-Path $sb 'targets5.json') -Targets @(
    @{ id = 'alpha'; tier = 'safe'; group = 'test'; label = 'alpha'; paths = @($onlyDir); minAgeDays = 0; keep = @(); reclaim = 'delete-contents' },
    @{ id = 'beta'; tier = 'safe'; group = 'test'; label = 'beta'; paths = @((Join-Path $sb 'nope')); minAgeDays = 0; keep = @(); reclaim = 'delete-contents' }
)

$doc5 = Get-ScanJson -TargetsFile $targets5 -Extra @('-Only', 'beta')
Assert-Equal 1 @($doc5.targets).Count '-Only selected exactly one target'
Assert-Equal 'beta' $doc5.targets[0].id 'the selected target is beta'

$doc5b = Get-ScanJson -TargetsFile $targets5 -Extra @('-Tier', 'apps')
Assert-Equal 0 @($doc5b.targets).Count '-Tier excludes targets in other tiers'

# ------------------------------------------------------------------ case 7b
Write-Host ''
Write-Host 'case 7b: watch task command stays under the schtasks 261-char limit'
$watchOut = Invoke-Cguard @('watch')
if ($watchOut -match 'length\s+:\s+(\d+) chars') {
    $len = [int]$Matches[1]
    Assert-True ($len -le 261) ("scheduled command is $len chars, within limit")
} else {
    Assert-True $false 'watch dry run reported a command length'
}
Assert-True ($watchOut -match 'auto-skip|below .* GB|-Auto') 'watch task is gated on free space'

# ------------------------------------------------------------------ case 8
Write-Host ''
Write-Host 'case 8: report-only targets are never deleted'
$roDir = Join-Path $sb 'readonly'
New-File (Join-Path $roDir 'precious.bin') 64
$targets6 = Write-Targets -Path (Join-Path $sb 'targets6.json') -Targets @{
    id = 'fake-ro'; tier = 'review'; group = 'test'; label = 'precious'
    paths = @($roDir); minAgeDays = 0; keep = @(); reclaim = 'report-only'
}

$null = Invoke-Cguard @('clean', '-Force', '-Deep', '-TargetsFile', $targets6)
Assert-True (Test-Path -LiteralPath (Join-Path $roDir 'precious.bin')) 'report-only survived even with -Force -Deep'

# ------------------------------------------------------------------ case 9
Write-Host ''
Write-Host 'case 9: a malformed target file is rejected, not silently obeyed'
$bad = Join-Path $sb 'bad.json'
Set-Content -LiteralPath $bad -Value '{ "version": "test", "targets": [] }' -Encoding UTF8
$badOut = Invoke-Cguard @('scan', '-TargetsFile', $bad)
Assert-True ($badOut -match 'zero usable targets') 'empty target list is refused with a clear message'

$bad2 = Join-Path $sb 'bad2.json'
Set-Content -LiteralPath $bad2 -Value '{ "version": "test", "targets": [ { "id": "x" } ] }' -Encoding UTF8
$badOut2 = Invoke-Cguard @('scan', '-TargetsFile', $bad2)
Assert-True ($badOut2 -match "no 'reclaim'") 'target without a reclaim mode is refused'

# ------------------------------------------------------------------ case 10
Write-Host ''
Write-Host 'case 10: shipped target list is valid JSON and schema-complete'
$shipped = Join-Path $root 'config\targets.json'
$sdoc = (Get-Content -LiteralPath $shipped -Raw -Encoding UTF8) | ConvertFrom-Json
Assert-True (@($sdoc.targets).Count -ge 20) 'at least 20 shipped targets'
$required = @('id', 'tier', 'group', 'label', 'reclaim')
$bad = @()
foreach ($t in @($sdoc.targets)) {
    foreach ($k in $required) {
        if (-not $t.PSObject.Properties[$k]) { $bad += ("{0}.{1}" -f $t.id, $k) }
    }
    if (@('safe', 'apps', 'review') -notcontains $t.tier) { $bad += ("{0}.tier={1}" -f $t.id, $t.tier) }
    if (@('delete-contents', 'subdirs', 'cmdlet', 'report-only') -notcontains $t.reclaim) { $bad += ("{0}.reclaim={1}" -f $t.id, $t.reclaim) }
}
Assert-Equal 0 $bad.Count ('every shipped target has the required fields' + $(if ($bad.Count) { ' -> ' + ($bad -join ', ') } else { '' }))
$ids = @($sdoc.targets | ForEach-Object { $_.id })
Assert-Equal $ids.Count (@($ids | Select-Object -Unique).Count) 'target ids are unique'
$live = @($sdoc.targets | Where-Object { $_.reclaim -ne 'report-only' })
Assert-True ($live.Count -ge 15) 'at least 15 shipped targets are actually cleanable'

# ------------------------------------------------------------------ teardown
Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('== {0} passed, {1} failed ==' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
Write-Host 'all green'
exit 0
