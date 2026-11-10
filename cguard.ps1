#Requires -Version 5.1
<#
.SYNOPSIS
    cguard - keep a Windows C: drive from silently filling up while AI coding
    agents (OpenCode, Codex, WorkBuddy, Claude Desktop, Cursor, VS Code) run
    day after day.

.DESCRIPTION
    Three verbs:

      scan      Measure every known bloat location. Read-only, always safe.
      clean     Reclaim space. Defaults to -DryRun; nothing is deleted unless
                you pass -Force, and never anything outside the target list.
      watch     Register a scheduled task that cleans the safe tiers on a
                schedule and logs what it reclaimed.

    Plus two maintenance verbs:

      doctor    Explain WHY the drive is full: biggest folders, shadow copies,
                hibernation, page file, OEM snapshots, redirect opportunities.
      relocate  Point agent caches at another drive permanently (env vars),
                which stops the growth instead of only cleaning up after it.

.EXAMPLE
    .\cguard.ps1 scan

.EXAMPLE
    .\cguard.ps1 scan -Deep -Top 15

.EXAMPLE
    .\cguard.ps1 clean                     # dry run, prints what it would free

.EXAMPLE
    .\cguard.ps1 clean -Force              # actually reclaim (safe + apps tiers)

.EXAMPLE
    .\cguard.ps1 clean -Force -Only opencode-data,codex-runtimes

.EXAMPLE
    .\cguard.ps1 watch -Install -EveryHours 6

.EXAMPLE
    .\cguard.ps1 clean -Force -Admin    # prompts for UAC once, cleans everything

.NOTES
    Author : Huichao007
    License: MIT
    The target list lives in config\targets.json. Add your own entries there;
    the engine treats every entry the same way.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'clean', 'watch', 'doctor', 'relocate', 'help', 'version')]
    [string]$Command = 'help',

    [string]$Only = '',

    [string]$Tier = '',

    [switch]$Deep,

    [switch]$Force,

    [switch]$Admin,

    [switch]$Auto,

    [switch]$Json,

    [int]$Top = 12,

    [string]$ReportPath = '',

    [string]$TargetsFile = '',

    [int]$EveryHours = 6,

    [switch]$NoColor,

    [switch]$Install,

    [switch]$Uninstall,

    [switch]$Status,

    [string]$ToDrive = 'D'
)

$ErrorActionPreference = 'Stop'

$script:CgRoot = $PSScriptRoot
if (-not $script:CgRoot) { $script:CgRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:CgTargetsFile = $TargetsFile
$script:CgVersion = '1.0.0'
$script:CgTaskName = 'cguard-Cleanup'
$script:CgLogDir = Join-Path $env:LOCALAPPDATA 'cguard'

. (Join-Path $script:CgRoot 'modules\Common.ps1')

if ($NoColor -or $Json) { Set-CgColor $false }

# ---------------------------------------------------------------- policy

function Get-CgPolicy {
    $file = Join-Path $script:CgRoot 'config\policy.json'
    $defaults = [pscustomobject]@{
        lowSpaceWarnGB   = 20
        lowSpaceAlertGB  = 10
        hardReserveGB    = 5
        watchTiers       = @('safe')
        keepRecentHours  = 2
    }
    if (Test-Path -LiteralPath $file) {
        try {
            $doc = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($p in $defaults.PSObject.Properties()) {
                $override = $doc.PSObject.Properties[$p.Name]
                if ($override -and $null -ne $override.Value) { $p.Value = $override.Value }
            }
        } catch { }
    }
    return $defaults
}

# ---------------------------------------------------------------- scan

function Invoke-CgScan {
    $doc = Get-CgTargets
    $list = Select-CgTargets -Document $doc -Only $Only -Tier $Tier -Deep:$Deep
    $policy = Get-CgPolicy

    if ($Json) { $script:CgQuiet = $true }

    $stats = Get-CgDriveStats -Drive 'C'
    $rows = New-Object System.Collections.ArrayList

    Write-CgTitle ("cguard {0} - scan" -f $script:CgVersion)
    if ($stats) {
        Write-CgInfo ("C: {0} GB total, {1} GB free ({2}% used)" -f $stats.TotalGB, $stats.FreeGB, $stats.UsedPct)
    }
    if ($Deep) { Write-CgInfo 'deep scan: including review-tier (real data) locations' }
    Write-CgInfo ("targets: {0}" -f $list.Count)

    foreach ($t in $list) {
        $s = Get-CgTargetSize -Target $t -BudgetMs 25000
        $null = $rows.Add([pscustomobject]@{
            id        = $t.id
            tier      = $t.tier
            group     = $t.group
            label     = $t.label
            bytes     = $s.Bytes
            files     = $s.Files
            paths     = $s.Paths
            truncated = $s.Truncated
            reclaim   = $t.reclaim
        })
    }

    $sorted = @($rows | Sort-Object bytes -Descending)

    if ($Json) {
        $payload = [pscustomobject]@{
            version = $script:CgVersion
            scannedAt = (Get-Date).ToString('o')
            drive = $stats
            totals = [pscustomobject]@{
                reclaimableSafe = [int64](($rows | Where-Object { $_.tier -eq 'safe' } | Measure-Object bytes -Sum).Sum)
                reclaimableApps = [int64](($rows | Where-Object { $_.tier -eq 'apps' } | Measure-Object bytes -Sum).Sum)
                dataOnly        = [int64](($rows | Where-Object { $_.tier -eq 'review' } | Measure-Object bytes -Sum).Sum)
            }
            targets = $sorted
        }
        $payload | ConvertTo-Json -Depth 6
        return
    }

    Write-Host ''
    Write-Host ('{0,-24} {1,-7} {2,10} {3,8}  {4}' -f 'TARGET', 'TIER', 'SIZE', 'FILES', 'WHAT IT IS')
    Write-CgRule
    $i = 0
    foreach ($r in $sorted) {
        if ($Top -gt 0 -and $i -ge $Top) { break }
        $i++
        $sz = Format-CgSize $r.bytes
        Write-Host ('{0,-24} {1,-7} {2,10} {3,8}  {4}' -f $r.id, $r.tier, $sz, $r.files, $r.label)
    }
    Write-CgRule

    $safe = [int64](($rows | Where-Object { $_.tier -eq 'safe' } | Measure-Object bytes -Sum).Sum)
    $apps = [int64](($rows | Where-Object { $_.tier -eq 'apps' } | Measure-Object bytes -Sum).Sum)
    $data = [int64](($rows | Where-Object { $_.tier -eq 'review' } | Measure-Object bytes -Sum).Sum)

    Write-Host ''
    Write-Host ('  safe tier   {0,10}   pure cache, deleting only costs a re-download' -f (Format-CgSize $safe))
    Write-Host ('  apps tier   {0,10}   agent runtimes, agent re-fetches on next start' -f (Format-CgSize $apps))
    if ($Deep) {
        Write-Host ('  review tier {0,10}   real data, reported only, never deleted' -f (Format-CgSize $data))
    }
    Write-Host ('  total       {0,10}' -f (Format-CgSize ($safe + $apps + $data)))
    Write-Host ''

    if ($stats -and $stats.FreeGB -lt $policy.lowSpaceWarnGB) {
        Write-CgWarn ("C: free space is {0} GB, below the {1} GB warning line" -f $stats.FreeGB, $policy.lowSpaceWarnGB)
    } else {
        Write-CgOk 'C: free space is above the warning line'
    }
    Write-CgInfo ('next: {0} clean            (dry run)' -f (Get-CgInvoke))
    Write-CgInfo ('      {0} clean -Force     (reclaim)' -f (Get-CgInvoke))
}

# ---------------------------------------------------------------- clean

function Get-CgTargetEffectivePaths {
    param($Target)
    $paths = @()
    if ($Target.paths) { $paths += @($Target.paths) }
    if ($Target.explicitPaths) { $paths += @($Target.explicitPaths) }
    return @($paths)
}

function Invoke-CgClean {
    $doc = Get-CgTargets
    $list = Select-CgTargets -Document $doc -Only $Only -Tier $Tier -Deep:$Deep
    $policy = Get-CgPolicy

    $isAdmin = Test-CgAdmin
    $free0 = Get-CgFreeGB -Drive 'C'

    # -Auto: only act when C: is genuinely short on space. This is what the
    # scheduled task uses, so a healthy machine is never touched.
    if ($Auto) {
        if ($null -eq $free0) {
            Write-CgError 'cannot read C: free space, refusing to run in -Auto mode'
            return
        }
        if ($free0 -ge $policy.lowSpaceWarnGB) {
            Write-CgInfo ('C: has {0} GB free (threshold {1} GB), nothing to do' -f $free0, $policy.lowSpaceWarnGB)
            Write-CgAudit -Results @() -TotalBytes 0 -Force $false -FreeBefore $free0 -Note 'auto-skip'
            return
        }
        Write-CgWarn ('C: has {0} GB free, below the {1} GB threshold: cleaning now' -f $free0, $policy.lowSpaceWarnGB)
        $Force = $true
    }

    Write-CgTitle ("cguard {0} - clean{1}" -f $script:CgVersion, $(if ($Force) { '' } else { ' (dry run)' }))
    Write-CgInfo ("C: free before: {0} GB" -f $free0)
    if (-not $isAdmin) {
        Write-CgInfo 'not elevated: targets marked requiresAdmin will be skipped'
        Write-CgInfo 'to include them: right-click PowerShell > Run as administrator'
    }
    Write-Host ''

    $results = New-Object System.Collections.ArrayList
    $totalBytes = [int64]0
    $totalRemoved = 0
    $totalFailed = 0

    foreach ($t in $list) {
        if ($t.reclaim -eq 'report-only') { continue }
        if ($t.requiresAdmin -and -not $isAdmin) {
            $null = $results.Add([pscustomobject]@{
                id = $t.id; label = $t.label; bytes = 0; removed = 0; failed = 0; status = 'skipped-needs-admin'
            })
            continue
        }

        $tBytes = [int64]0
        $tRemoved = 0
        $tFailed = 0
        $status = 'ok'

        # ---- cmdlet-based targets
        if ($t.reclaim -eq 'cmdlet') {
            if (-not $Force) {
                $s = Get-CgTargetSize -Target $t -BudgetMs 15000
                $tBytes = $s.Bytes
                $status = 'would-run-cmdlet'
            } else {
                $s = Get-CgTargetSize -Target $t -BudgetMs 15000
                $tBytes = $s.Bytes
                $out = Invoke-CgNative -FilePath 'powershell.exe' -Arguments @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $t.cmdlet
                )
                if ($out) { Write-CgInfo ("cmdlet output: {0}" -f $out) }
                $status = 'cmdlet-invoked'
            }
            $null = $results.Add([pscustomobject]@{
                id = $t.id; label = $t.label; bytes = $tBytes; removed = 0; failed = 0; status = $status
            })
            $totalBytes += $tBytes
            continue
        }

        # ---- stop services before touching their folders
        if ($t.stopBefore -and $Force) {
            foreach ($svc in @($t.stopBefore)) {
                try { Stop-Service -Name $svc -Force -ErrorAction Stop } catch { }
            }
        }

        # ---- subdir targets (e.g. opencode-data: only some children)
        if ($t.reclaim -eq 'subdirs') {
            $any = $false
            foreach ($sub in @($t.subdirs)) {
                $base = Expand-CgPath (@($t.paths)[0])
                if (-not $base) { continue }
                $subPath = Join-Path $base $sub.name
                if (-not (Test-Path -LiteralPath $subPath)) { continue }
                $any = $true
                $r = Remove-CgChildren -Path $subPath -MinAgeDays ([int]$sub.minAgeDays) `
                    -ExcludeNames @($t.keep) -WhatIfOnly:(-not $Force)
                $tBytes += $r.Bytes
                $tRemoved += $r.Removed
                $tFailed += $r.Failed
            }
            if (-not $any) { $status = 'not-found' }
            $null = $results.Add([pscustomobject]@{
                id = $t.id; label = $t.label; bytes = $tBytes; removed = $tRemoved; failed = $tFailed; status = $status
            })
            $totalBytes += $tBytes
            $totalRemoved += $tRemoved
            $totalFailed += $tFailed
            if ($tBytes -gt 0 -or $tFailed -gt 0) {
                Write-Host ('  {0,-24} {1,10}  {2} items' -f $t.id, (Format-CgSize $tBytes), $tRemoved)
            }
            continue
        }

        # ---- plain delete-contents targets
        $any2 = $false
        foreach ($p in (Get-CgTargetEffectivePaths -Target $t)) {
            $expanded = Expand-CgPath $p
            if (-not $expanded) { continue }
            if (-not (Test-Path -LiteralPath $expanded)) { continue }
            $any2 = $true
            $r = Remove-CgChildren -Path $expanded -MinAgeDays ([int]$t.minAgeDays) `
                -ExcludeNames @($t.keep) -WhatIfOnly:(-not $Force)
            $tBytes += $r.Bytes
            $tRemoved += $r.Removed
            $tFailed += $r.Failed
        }
        if (-not $any2) { $status = 'not-found' }

        $null = $results.Add([pscustomobject]@{
            id = $t.id; label = $t.label; bytes = $tBytes; removed = $tRemoved; failed = $tFailed; status = $status
        })
        $totalBytes += $tBytes
        $totalRemoved += $tRemoved
        $totalFailed += $tFailed

        if ($tBytes -gt 0 -or $tFailed -gt 0) {
            $note = ''
            if ($tFailed -gt 0) { $note = (' ({0} locked, skipped)' -f $tFailed) }
            Write-Host ('  {0,-24} {1,10}  {2} items{3}' -f $t.id, (Format-CgSize $tBytes), $tRemoved, $note)
        }

        if ($t.stopAfter -and $Force) {
            foreach ($svc in @($t.stopAfter)) {
                try { Start-Service -Name $svc -ErrorAction Stop } catch { }
            }
        }
    }

    Write-Host ''
    if ($Force) {
        $free1 = Get-CgFreeGB -Drive 'C'
        Write-CgOk ('reclaimed {0}; C: free {1} -> {2} GB' -f (Format-CgSize $totalBytes), $free0, $free1)
    } else {
        Write-CgOk ('would reclaim approximately {0}' -f (Format-CgSize $totalBytes))
        Write-Host ''
        Write-CgInfo 'nothing was deleted. re-run with -Force to execute.'
        $biggest = $results | Sort-Object bytes -Descending | Select-Object -First 1
        if ($biggest -and $biggest.bytes -gt 0) {
            Write-CgInfo ('biggest single win: {0} clean -Force -Only {1}' -f (Get-CgInvoke), $biggest.id)
        }
    }
    if ($totalFailed -gt 0) {
        Write-CgWarn ('{0} items were locked or in use and were skipped (close the app and retry, or rerun elevated)' -f $totalFailed)
    }

    Write-CgAudit -Results $results -TotalBytes $totalBytes -Force $Force -FreeBefore $free0

    if ($ReportPath) { Write-CgMarkdownReport -Results $results -Path $ReportPath }
}

function Get-CgInvoke {
    # "cguard" when installed with the .cmd shim, otherwise ".\cguard.ps1"
    if ($script:CgShim -eq $null) {
        $shim = Join-Path $script:CgRoot 'cguard.cmd'
        $script:CgShim = [bool](Test-CgExists $shim)
    }
    if ($script:CgShim) { return 'cguard' }
    return '.\cguard.ps1'
}

function Write-CgAudit {
    param($Results, [int64]$TotalBytes, [bool]$Force, $FreeBefore, [string]$Note = '')

    try {
        if (-not (Test-Path -LiteralPath $script:CgLogDir)) {
            New-Item -ItemType Directory -Force -Path $script:CgLogDir | Out-Null
        }
        $log = Join-Path $script:CgLogDir 'cguard.log'
        $mode = $(if ($Note) { $Note } elseif ($Force) { 'apply' } else { 'dryrun' })
        $line = '{0} mode={1} reclaimed={2} freeBefore={3} freeAfter={4}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode, `
            (Format-CgSize $TotalBytes), $FreeBefore, (Get-CgFreeGB -Drive 'C')
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    } catch { }
}

function Write-CgMarkdownReport {
    param($Results, [string]$Path)

    $stats = Get-CgDriveStats -Drive 'C'
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('# cguard report')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine(('- generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    if ($stats) {
        $null = $sb.AppendLine(('- C: {0} GB total / {1} GB free ({2}% used)' -f $stats.TotalGB, $stats.FreeGB, $stats.UsedPct))
    }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| target | tier | size | items | status |')
    $null = $sb.AppendLine('| --- | --- | --- | --- | --- |')
    foreach ($r in ($Results | Sort-Object bytes -Descending)) {
        $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} |' -f $r.id, '', (Format-CgSize $r.bytes), $r.removed, $r.status))
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding UTF8
    Write-CgOk ("report written: {0}" -f $Path)
}

# ---------------------------------------------------------------- doctor

function Invoke-CgDoctor {
    $policy = Get-CgPolicy
    Write-CgTitle ("cguard {0} - doctor" -f $script:CgVersion)

    $stats = Get-CgDriveStats -Drive 'C'
    if (-not $stats) { Write-CgError 'cannot read C: stats'; return }

    Write-Host ''
    Write-Host ('  C: {0} GB total / {1} GB free / {2}% used' -f $stats.TotalGB, $stats.FreeGB, $stats.UsedPct)

    $verdict = 'healthy'
    if ($stats.FreeGB -lt $policy.lowSpaceAlertGB) { $verdict = 'critical' }
    elseif ($stats.FreeGB -lt $policy.lowSpaceWarnGB) { $verdict = 'warning' }
    Write-Host ('  verdict: {0}' -f $verdict)
    Write-Host ''

    # --- biggest top-level folders
    Write-CgTitle 'biggest folders under C:\'
    $candidates = @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
        'C:\Users', 'C:\$WinREAgent', 'C:\Windows.old')
    $found = @()
    foreach ($c in $candidates) {
        if (-not (Test-CgExists $c)) { continue }
        $s = Get-CgPathSize -Path $c -BudgetMs 25000
        $found += [pscustomobject]@{ Path = $c; Bytes = $s.Bytes; Truncated = $s.Truncated }
    }
    foreach ($f in ($found | Sort-Object Bytes -Descending)) {
        $flag = ''
        if ($f.Truncated) { $flag = '  (25s budget reached - treat as a floor, not the real size)' }
        Write-Host ('  {0,10}  {1}{2}' -f (Format-CgSize $f.Bytes), $f.Path, $flag)
    }

    # --- per-user profile breakdown
    Write-CgTitle 'per-user folders (top 8)'
    $profileDirs = @()
    $roots = @("$env:USERPROFILE\AppData\Local", "$env:USERPROFILE\AppData\Roaming", $env:USERPROFILE)
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -eq 'AppData') { continue }
            if ($profileDirs.Path -contains $d.FullName) { continue }
            $profileDirs += [pscustomobject]@{ Path = $d.FullName }
        }
    }
    $sized = @()
    foreach ($d in $profileDirs) {
        $s = Get-CgPathSize -Path $d.Path -BudgetMs 4000
        if ($s.Bytes -gt 200MB) {
            $sized += [pscustomobject]@{ Path = $d.Path; Bytes = $s.Bytes }
        }
    }
    foreach ($f in ($sized | Sort-Object Bytes -Descending | Select-Object -First 8)) {
        Write-Host ('  {0,10}  {1}' -f (Format-CgSize $f.Bytes), $f.Path)
    }

    # --- shadow copies
    Write-CgTitle 'volume shadow copies (System Restore)'
    $vss = Invoke-CgNative -FilePath 'vssadmin.exe' -Arguments @('list', 'shadowstorage')
    if ($vss -match 'elevat|denied|Administrator|\u7ba1\u7406\u5458') {
        Write-CgWarn 'needs Administrator to read. Typical culprits are 10-60 GB here.'
    } else {
        foreach ($line in ($vss -split "`r?`n")) {
            if ($line.Trim()) { Write-Host ('  ' + $line.Trim()) }
        }
    }

    # --- hibernation / pagefile
    Write-CgTitle 'hiberfil.sys and pagefile.sys'
    foreach ($f in @('C:\hiberfil.sys', 'C:\pagefile.sys', 'C:\swapfile.sys')) {
        try {
            $fi = Get-Item -LiteralPath $f -Force -ErrorAction Stop
            Write-Host ('  {0,10}  {1}' -f (Format-CgSize $fi.Length), $f)
        } catch { }
    }
    $hib = $null
    try { $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled } catch { }
    if ($hib -eq 1) {
        Write-CgInfo 'hibernation is ON: "powercfg -h off" (admin) frees roughly your RAM size'
    }

    # --- OEM snapshots
    Write-CgTitle 'OEM repair snapshots'
    $dell = '%PROGRAMDATA%\Dell\SARemediation\SystemRepair\Snapshots'
    $dellPath = Expand-CgPath $dell
    $dellSize = Get-CgPathSize -Path $dell -BudgetMs 8000
    if ($dellSize.Bytes -gt 0) {
        Write-Host ('  {0,10}  {1}' -f (Format-CgSize $dellSize.Bytes), $dellPath)
        Write-CgWarn 'Dell SupportAssist keeps a full pre-repair image here. cguard clean -Admin removes it.'
    } else {
        Write-CgInfo 'none found (or not readable without Administrator)'
    }

    # --- redirect opportunities
    Write-CgTitle 'growth control (relocate)'
    $audit = Get-CgRedirectAudit
    foreach ($a in $audit) {
        $mark = 'not set'
        if ($a.Current) { $mark = $a.Current }
        $note = ''
        if ($a.Current -and $a.Current -notmatch '^C:') { $note = ' (already off C:)' }
        Write-Host ('  {0,-26} {1}{2}' -f $a.Name, $mark, $note)
    }
    Write-CgInfo ('run: {0} relocate -ToDrive {1} -Force   to move caches off C: permanently' -f (Get-CgInvoke), $ToDrive)
    Write-Host ''
}

# ---------------------------------------------------------------- relocate

function Get-CgToDrive {
    return ($ToDrive.TrimEnd(':') + ':')
}

function Set-CgToDrive {
    param([string]$Drive)
    $script:ToDrive = $Drive
}

# set of env vars that decide where the big agent caches land
function Get-CgRedirectMap {
    $d = $script:ToDrive
    if (-not $d) { $d = 'D:' }
    $d = $d.TrimEnd(':') + ':'
    return @(
        [pscustomobject]@{ Name = 'NPM_CONFIG_CACHE';        Value = "$d\cguard\npm-cache";        Why = 'npm package cache' }
        [pscustomobject]@{ Name = 'YARN_CACHE_FOLDER';       Value = "$d\cguard\yarn-cache";       Why = 'yarn offline mirror' }
        [pscustomobject]@{ Name = 'PNPM_HOME';               Value = "$d\cguard\pnpm-home";        Why = 'pnpm global store root' }
        [pscustomobject]@{ Name = 'UV_CACHE_DIR';            Value = "$d\cguard\uv-cache";         Why = 'uv / Python wheels' }
        [pscustomobject]@{ Name = 'PIP_CACHE_DIR';           Value = "$d\cguard\pip-cache";        Why = 'pip wheels' }
        [pscustomobject]@{ Name = 'BUN_INSTALL_CACHE_DIR';   Value = "$d\cguard\bun-cache";        Why = 'bun packages' }
        [pscustomobject]@{ Name = 'PUPPETEER_CACHE_DIR';     Value = "$d\cguard\puppeteer";        Why = 'Chromium download for puppeteer' }
        [pscustomobject]@{ Name = 'PLAYWRIGHT_BROWSERS_PATH'; Value = "$d\cguard\ms-playwright";   Why = 'Playwright browser bundles' }
        [pscustomobject]@{ Name = 'TMP';                     Value = "$d\cguard\temp";             Why = 'per-session scratch (only if you opt in)' }
        [pscustomobject]@{ Name = 'TEMP';                    Value = "$d\cguard\temp";             Why = 'per-session scratch (only if you opt in)' }
    )
}

function Get-CgRedirectAudit {
    $out = @()
    foreach ($m in (Get-CgRedirectMap)) {
        $cur = [Environment]::GetEnvironmentVariable($m.Name, 'User')
        $out += [pscustomobject]@{ Name = $m.Name; Current = $cur; Desired = $m.Value; Why = $m.Why }
    }
    return $out
}

function Invoke-CgRelocate {
    Set-CgToDrive $ToDrive
    $d = Get-CgToDrive

    Write-CgTitle ("cguard {0} - relocate caches to {1}" -f $script:CgVersion, $d)
    Write-CgInfo 'this writes USER environment variables; new processes pick them up, running ones do not'
    Write-CgInfo 'any path that already exists keeps its current value unless -Force is given'
    Write-Host ''

    $map = Get-CgRedirectMap
    $changed = 0
    foreach ($m in $map) {
        $cur = [Environment]::GetEnvironmentVariable($m.Name, 'User')
        if ($cur -and -not $Force) {
            Write-Host ('  skip  {0,-26} already set to {1}' -f $m.Name, $cur)
            continue
        }
        $dir = $m.Value
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {
                Write-CgWarn ("cannot create {0}" -f $dir); continue
            }
        }
        if ($Force) {
            [Environment]::SetEnvironmentVariable($m.Name, $dir, 'User')
            Write-Host ('  set   {0,-26} {1}' -f $m.Name, $dir)
            $changed++
        } else {
            Write-Host ('  plan  {0,-26} {1}   ({2})' -f $m.Name, $dir, $m.Why)
        }
    }

    Write-Host ''
    if ($Force) {
        Write-CgOk ('{0} variables updated. Restart your agents for them to take effect.' -f $changed)
        Write-CgInfo ('undo: set the same variables back to empty, or run: {0} relocate -Force -ToDrive <letter>' -f (Get-CgInvoke))
    } else {
        Write-CgOk 'dry run: nothing was written'
        Write-CgInfo ('run: {0} relocate -ToDrive {1} -Force' -f (Get-CgInvoke), $ToDrive)
    }
}

# ---------------------------------------------------------------- watch

function Invoke-CgWatch {
    $policy = Get-CgPolicy

    if ($Status) {
        Write-CgTitle ("cguard {0} - watch status" -f $script:CgVersion)
        $q = Invoke-CgNative -FilePath 'schtasks.exe' -Arguments @('/Query', '/TN', $script:CgTaskName, '/FO', 'LIST')
        if ($q -match 'cannot find|not exist') {
            Write-CgWarn 'task is not registered'
            Write-CgInfo ('install: {0} watch -Install -EveryHours {1}' -f (Get-CgInvoke), $EveryHours)
        } else {
            foreach ($line in ($q -split "`r?`n")) {
                if ($line.Trim()) { Write-Host ('  ' + $line.Trim()) }
            }
        }
        $log = Join-Path $script:CgLogDir 'cguard.log'
        if (Test-Path -LiteralPath $log) {
            Write-Host ''
            Write-CgTitle 'last 5 audit lines'
            Get-Content -LiteralPath $log -Tail 5 | ForEach-Object { Write-Host ('  ' + $_) }
        }
        return
    }

    if ($Uninstall) {
        $null = Invoke-CgNative -FilePath 'schtasks.exe' -Arguments @('/Delete', '/TN', $script:CgTaskName, '/F')
        Write-CgOk 'task removed'
        return
    }

    $scriptPath = Join-Path $script:CgRoot 'cguard.ps1'

    # schtasks /TR is capped at 261 characters, so pick the tier flag when it
    # covers the watch set and only fall back to an explicit id list otherwise.
    $watchTiers = (@($policy.watchTiers) | Where-Object { $_ }) -join ','
    $isAllSafe = $false
    if ($watchTiers -eq 'safe') {
        $tierIds = @((Get-CgTargets).targets | Where-Object { $_.tier -eq 'safe' -and $_.reclaim -ne 'report-only' } | ForEach-Object { $_.id })
        $watchIds = @(Get-CgWatchIds)
        $isAllSafe = ($tierIds.Count -eq $watchIds.Count)
    }

    if ($isAllSafe) {
        $selector = ('-Tier {0}' -f $watchTiers)
    } else {
        $selector = ('-Only {0}' -f (implodeIds (Get-CgWatchIds)))
    }

    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" clean -Auto -NoColor {1}' -f `
        $scriptPath, $selector

    if (-not $Install) {
        Write-CgTitle ("cguard {0} - watch (dry run)" -f $script:CgVersion)
        Write-CgInfo 'this is the scheduled task that would be created:'
        Write-Host ''
        Write-Host ('  name    : {0}' -f $script:CgTaskName)
        Write-Host ('  every   : {0} hours' -f $EveryHours)
        Write-Host ('  runs    : powershell.exe {0}' -f $argLine)
        Write-Host ('  length  : {0} chars (schtasks limit is 261)' -f ('powershell.exe ' + $argLine).Length)
        Write-CgInfo ('tiers cleaned: {0}' -f (($policy.watchTiers) -join ', '))
        Write-CgInfo ('only acts when C: free space drops below {0} GB (-Auto)' -f $policy.lowSpaceWarnGB)
        Write-Host ''
        Write-CgOk 'dry run: no task was created'
        Write-CgInfo ('install: {0} watch -Install -EveryHours {1}' -f (Get-CgInvoke), $EveryHours)
        return
    }

    $exeArgs = 'powershell.exe ' + $argLine
    if ($exeArgs.Length -gt 261) {
        Write-CgError ('task command is {0} chars, over the schtasks limit of 261' -f $exeArgs.Length)
        Write-CgInfo 'reduce it by setting watchTiers to a single tier in config\policy.json'
        return
    }

    $null = Invoke-CgNative -FilePath 'schtasks.exe' -Arguments @(
        '/Create', '/TN', $script:CgTaskName, '/SC', 'HOURLY', '/MO', "$EveryHours",
        '/TR', ('powershell.exe ' + $argLine), '/F'
    )
    $q = Invoke-CgNative -FilePath 'schtasks.exe' -Arguments @('/Query', '/TN', $script:CgTaskName)
    if ($q -match $script:CgTaskName) {
        Write-CgOk ('scheduled task installed: every {0} hours' -f $EveryHours)
        Write-CgInfo ('log: {0}' -f (Join-Path $script:CgLogDir 'cguard.log'))
    } else {
        Write-CgError 'task creation failed'
        Write-Host $q
    }
}

function Get-CgWatchIds {
    $doc = Get-CgTargets
    $policy = Get-CgPolicy
    $ids = @()
    foreach ($t in @($doc.targets)) {
        if ($policy.watchTiers -contains $t.tier -and $t.reclaim -ne 'report-only') {
            $ids += $t.id
        }
    }
    return $ids
}

function implodeIds {
    param($Ids)
    return (($Ids | Where-Object { $_ }) -join ',')
}

# ---------------------------------------------------------------- entry

function Show-CgHelp {
    $e = Get-CgInvoke
    Write-Host ''
    Write-Host ("cguard {0} - keep C: from filling up while AI agents run" -f $script:CgVersion)
    Write-Host ''
    Write-Host ("  {0} scan                 measure everything, change nothing" -f $e)
    Write-Host ("  {0} scan -Deep           also measure real-data locations" -f $e)
    Write-Host ("  {0} clean                dry run: what would be reclaimed" -f $e)
    Write-Host ("  {0} clean -Force         reclaim safe + apps tiers" -f $e)
    Write-Host ("  {0} clean -Force -Admin  include the locations needing Administrator" -f $e)
    Write-Host ("  {0} clean -Force -Only opencode-data,codex-runtimes" -f $e)
    Write-Host ("  {0} doctor               why is C: full, and what is safe to fix" -f $e)
    Write-Host ("  {0} relocate -ToDrive D  stop the growth: move caches to D:" -f $e)
    Write-Host ("  {0} watch -Install       clean the safe tier every 6 hours" -f $e)
    Write-Host ("  {0} watch -Status        is the task installed, what did it reclaim" -f $e)
    Write-Host ''
    Write-Host '  flags: -Json  -NoColor  -Top N  -ReportPath <file>  -TargetsFile <file>  -Tier <tier>'
    Write-Host ''
}

try {
    switch ($Command) {
        'scan' { Invoke-CgScan }
        'clean' {
            if ($Admin -and -not (Test-CgAdmin)) {
                # re-launch elevated with the same arguments
                $exe = (Get-Process -Id $PID).Path
                if (-not $exe) { $exe = 'powershell.exe' }
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', ('"' + (Join-Path $script:CgRoot 'cguard.ps1') + '"'),
                    'clean')
                if ($Force) { $argList += '-Force' }
                if ($Only) { $argList += @('-Only', $Only) }
                if ($Deep) { $argList += '-Deep' }
                if ($NoColor) { $argList += '-NoColor' }
                Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs
                Write-CgInfo 'elevated window opened; progress and the audit log are written there'
                return
            }
            Invoke-CgClean
        }
        'doctor' { Invoke-CgDoctor }
        'relocate' { Invoke-CgRelocate }
        'watch' { Invoke-CgWatch }
        'version' { Write-Host ("cguard {0}" -f $script:CgVersion) }
        default { Show-CgHelp }
    }
} catch {
    Write-CgError ('failed: {0}' -f $_.Exception.Message)
    Write-CgInfo ('at: {0}' -f $_.InvocationInfo.PositionMessage)
    exit 1
}


