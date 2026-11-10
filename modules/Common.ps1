# Common.ps1 - shared helpers for cguard
# PowerShell 5.1 compatible. ASCII only on purpose: PS 5.1 mis-parses
# UTF-8 files without a BOM, and this repo ships plain UTF-8.

$script:CgUseColor = $true

function Set-CgColor {
    param([bool]$Enabled)
    $script:CgUseColor = $Enabled
}

function Write-CgRule {
    param([string]$Text = '')
    if ($script:CgQuiet) { return }
    Write-Host ('-' * 78)
    if ($Text) { Write-Host $Text }
}

function Write-CgTitle {
    param([string]$Text)
    if ($script:CgQuiet) { return }
    Write-Host ''
    if ($script:CgUseColor) {
        Write-Host "== $Text ==" -ForegroundColor Cyan
    } else {
        Write-Host "== $Text =="
    }
}

function Write-CgInfo {
    param([string]$Text)
    if ($script:CgQuiet) { return }
    if ($script:CgUseColor) { Write-Host "   $Text" -ForegroundColor Gray }
    else { Write-Host "   $Text" }
}

function Write-CgOk {
    param([string]$Text)
    if ($script:CgQuiet) { return }
    if ($script:CgUseColor) { Write-Host "OK $Text" -ForegroundColor Green }
    else { Write-Host "OK $Text" }
}

function Write-CgWarn {
    param([string]$Text)
    if ($script:CgQuiet) { return }
    if ($script:CgUseColor) { Write-Host "!! $Text" -ForegroundColor Yellow }
    else { Write-Host "!! $Text" }
}

function Write-CgError {
    param([string]$Text)
    if ($script:CgUseColor) { Write-Host "XX $Text" -ForegroundColor Red }
    else { Write-Host "XX $Text" }
}

function Format-CgSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-CgAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Expand %VARS%, ~ and return an absolute path. Returns $null when the
# path cannot be resolved (unknown env var inside the string).
function Expand-CgPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path
    if ($p.StartsWith('~')) { $p = $env:USERPROFILE + $p.Substring(1) }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '%[A-Za-z_]+%') { return $null }
    return $p
}

# Test-Path that never throws (Test-Path on a denied folder raises with
# $ErrorActionPreference = 'Stop', and several targets live under ProgramData).
function Test-CgExists {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        return [bool](Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
    } catch {
        # folder exists but is not listable: treat as present so the caller
        # can report "needs Administrator" rather than silently skipping it
        try {
            $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
}

function Get-CgFreeGB {
    param([string]$Drive = 'C')
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $Drive) -ErrorAction Stop
        return [math]::Round($d.FreeSpace / 1GB, 2)
    } catch {
        try {
            return [math]::Round((Get-PSDrive -Name $Drive -ErrorAction Stop).Free / 1GB, 2)
        } catch {
            return $null
        }
    }
}

function Get-CgDriveStats {
    param([string]$Drive = 'C')
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $Drive) -ErrorAction Stop
        return [pscustomobject]@{
            Drive   = $Drive
            TotalGB = [math]::Round($d.Size / 1GB, 2)
            FreeGB  = [math]::Round($d.FreeSpace / 1GB, 2)
            UsedPct = [math]::Round((1 - ($d.FreeSpace / $d.Size)) * 100, 1)
        }
    } catch { return $null }
}

# Fast directory size using .NET enumeration plus a time budget, so a scan
# can never hang on a giant or locked tree.
function Get-CgPathSize {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$BudgetMs = 20000
    )

    $result = [pscustomobject]@{ Bytes = [int64]0; Files = 0; Truncated = $false }

    $p = Expand-CgPath $Path
    if (-not $p) { return $result }
    if (-not (Test-CgExists $p)) { return $result }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $bytes = [int64]0
    $count = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($p)

    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -gt $BudgetMs) { $result.Truncated = $true; break }
        $dir = [string]$stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $bytes += (New-Object System.IO.FileInfo($f)).Length
                    $count++
                } catch { }
            }
        } catch { }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                $stack.Push($d)
            }
        } catch { }
    }

    $sw.Stop()
    $result.Bytes = $bytes
    $result.Files = $count
    return $result
}

# Delete everything *inside* $Path, optionally only entries older than N days.
# Returns bytes that were actually removed plus a count of failures.
function Remove-CgChildren {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MinAgeDays = 0,
        [string[]]$ExcludeNames = @(),
        [switch]$WhatIfOnly
    )

    $out = [pscustomobject]@{ Bytes = [int64]0; Removed = 0; Failed = 0; Path = $Path }

    $p = Expand-CgPath $Path
    if (-not $p) { return $out }
    if (-not (Test-CgExists $p)) { return $out }

    $cut = (Get-Date).AddDays(-1 * [math]::Max(0, $MinAgeDays))

    $items = @()
    try { $items = Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { }

    foreach ($item in $items) {
        if ($ExcludeNames -contains $item.Name) { continue }

        $isOld = $true
        if ($MinAgeDays -gt 0) {
            $isOld = ($item.LastWriteTime -lt $cut)
        }

        $size = [int64]0
        if ($item.PSIsContainer) {
            $size = (Get-CgPathSize -Path $item.FullName -BudgetMs 30000).Bytes
        } else {
            $size = $item.Length
        }

        if (-not $isOld) { continue }

        if ($WhatIfOnly) {
            $out.Bytes += $size
            $out.Removed++
            continue
        }

        $freed = [int64]0
        try {
            if ($item.PSIsContainer) {
                # measure after the fact is unreliable once deleted; trust the pre-measure
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            }
            $freed = $size
            $out.Removed++
        } catch {
            # locked file: try the shell fallback for directories
            if ($item.PSIsContainer) {
                cmd /c ("rd /s /q `"{0}`" >nul 2>&1" -f $item.FullName) | Out-Null
                if (-not (Test-Path -LiteralPath $item.FullName)) { $freed = $size; $out.Removed++ }
                else { $out.Failed++ }
            } else {
                $out.Failed++
            }
        }
        $out.Bytes += $freed
    }

    return $out
}

function Invoke-CgNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    try {
        $out = & $FilePath @Arguments 2>&1
        return ($out | Out-String).Trim()
    } catch {
        return ($_.Exception.Message)
    }
}

function Get-CgTargetsPath {
    if ($script:CgTargetsFile -and (Test-Path -LiteralPath $script:CgTargetsFile)) {
        return $script:CgTargetsFile
    }
    return (Join-Path $script:CgRoot 'config\targets.json')
}

function Get-CgTargets {
    $file = Get-CgTargetsPath
    if (-not (Test-CgExists $file)) {
        throw "targets file not found: $file"
    }
    $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $doc = $raw | ConvertFrom-Json

    if (-not $doc.PSObject.Properties['targets']) {
        throw ("targets file has no 'targets' array: {0}" -f $file)
    }
    $list = @($doc.targets | Where-Object { $_ -ne $null })
    if ($list.Count -eq 0) {
        throw ("targets file declares zero usable targets: {0}" -f $file)
    }
    foreach ($t in $list) {
        if (-not $t.id) { throw ("a target in {0} has no 'id'" -f $file) }
        if (-not $t.reclaim) { throw ("target '{0}' has no 'reclaim' mode" -f $t.id) }
    }
    return $doc
}

function Select-CgTargets {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [string]$Only = '',
        [switch]$Deep
    )

    $list = @($Document.targets)
    if (-not $list -or $list.Count -eq 0) { return , @() }

    if ($Only) {
        $want = @($Only.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $list = @($list | Where-Object { $want -contains $_.id })
    }

    if (-not $Deep) {
        $list = @($list | Where-Object { $_.tier -ne 'review' })
    }

    # comma operator: stop PowerShell unrolling a single-element array on return
    return , $list
}

function Get-CgTargetSize {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [int]$BudgetMs = 20000
    )

    $total = [int64]0
    $files = 0
    $truncated = $false
    $existing = 0

    # subdir targets (agent data dirs holding a live database): only the
    # listed children are reclaimable, so only those get measured
    if ($Target.reclaim -eq 'subdirs' -and $Target.subdirs) {
        $base = $null
        if ($Target.paths) { $base = Expand-CgPath (@($Target.paths)[0]) }
        if ($base) {
            foreach ($sub in @($Target.subdirs)) {
                $subPath = Join-Path $base $sub.name
                if (-not (Test-CgExists $subPath)) { continue }
                $existing++
                $s = Get-CgPathSize -Path $subPath -BudgetMs $BudgetMs
                $total += $s.Bytes
                $files += $s.Files
                if ($s.Truncated) { $truncated = $true }
            }
        }
        return [pscustomobject]@{
            Id = $Target.id; Bytes = $total; Files = $files; Paths = $existing; Truncated = $truncated
        }
    }

    $paths = @()
    if ($Target.paths) { $paths += @($Target.paths) }
    if ($Target.explicitPaths) { $paths += @($Target.explicitPaths) }

    foreach ($p in $paths) {
        $expanded = Expand-CgPath $p
        if (-not $expanded) { continue }
        if (-not (Test-CgExists $expanded)) { continue }
        $existing++
        $s = Get-CgPathSize -Path $expanded -BudgetMs $BudgetMs
        $total += $s.Bytes
        $files += $s.Files
        if ($s.Truncated) { $truncated = $true }
    }

    return [pscustomobject]@{
        Id        = $Target.id
        Bytes     = $total
        Files     = $files
        Paths     = $existing
        Truncated = $truncated
    }
}

