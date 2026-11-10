#Requires -Version 5.1
<#
.SYNOPSIS
    One-command installer for cguard.

.DESCRIPTION
    Two ways to run it.

    From the internet, no git, no admin:

        irm https://raw.githubusercontent.com/Huichao007/cguard/main/install.ps1 | iex

    From a local checkout:

        .\install.ps1

    What it does:
      1. copies (or downloads) cguard into an install directory
      2. drops a cguard.cmd shim next to it and adds that directory to the
         user PATH, so "cguard" works from any terminal
      3. optionally registers the scheduled guard task
      4. runs a scan so you immediately see what is reclaimable

    Nothing is deleted by the installer. Cleanup only happens when you run
    "cguard clean -Force".

.PARAMETER InstallDir
    Where to install. Default: %LOCALAPPDATA%\Programs\cguard

.PARAMETER NoPath
    Do not modify the user PATH.

.PARAMETER InstallTask
    Register the scheduled guard task (opt-in when run unattended).

.PARAMETER NoScan
    Skip the post-install scan.

.PARAMETER Uninstall
    Remove the install directory, the PATH entry and the scheduled task.

.PARAMETER Force
    Overwrite an existing installation.

.EXAMPLE
    irm https://raw.githubusercontent.com/Huichao007/cguard/main/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -InstallDir D:\Tools\cguard -InstallTask

.EXAMPLE
    .\install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$NoPath,
    [switch]$InstallTask,
    [switch]$NoScan,
    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoZip = 'https://github.com/Huichao007/cguard/archive/refs/heads/main.zip'
$TaskName = 'cguard-Cleanup'

function Say {
    param([string]$Text, [string]$Kind = 'info')
    switch ($Kind) {
        'ok' { Write-Host "OK $Text" -ForegroundColor Green }
        'warn' { Write-Host "!! $Text" -ForegroundColor Yellow }
        'err' { Write-Host "XX $Text" -ForegroundColor Red }
        default { Write-Host "   $Text" -ForegroundColor Gray }
    }
}

function Get-DefaultInstallDir {
    return (Join-Path $env:LOCALAPPDATA 'Programs\cguard')
}

function Get-RealPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if ($p.StartsWith('~')) { $p = $env:USERPROFILE + $p.Substring(1) }
    try { return (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { return $p }
}

function Remove-FromUserPath {
    param([string]$Entry)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { return $false }
    $parts = @($cur.Split(';') | Where-Object { $_ -and $_.Trim() })
    $keep = @($parts | Where-Object { $_.TrimEnd('\') -ne $Entry.TrimEnd('\') })
    if ($keep.Count -eq $parts.Count) { return $false }
    [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), 'User')
    return $true
}

function Add-ToUserPath {
    param([string]$Entry)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { $cur = '' }
    $parts = @($cur.Split(';') | Where-Object { $_ -and $_.Trim() })
    if (@($parts | Where-Object { $_.TrimEnd('\') -eq $Entry.TrimEnd('\') }).Count -gt 0) {
        return 'already'
    }
    $new = if ($cur.Trim()) { $cur.TrimEnd(';') + ';' + $Entry } else { $Entry }
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    return 'added'
}

# ---------------------------------------------------------------- uninstall

if ($Uninstall) {
    Write-Host ''
    Write-Host '== cguard uninstall ==' -ForegroundColor Cyan

    $dirs = @()
    if ($InstallDir) { $dirs += (Get-RealPath $InstallDir) }
    $dirs += (Get-DefaultInstallDir)
    $dirs = @($dirs | Select-Object -Unique)

    foreach ($d in $dirs) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                Say ("removed $d") 'ok'
            } catch {
                Say ("could not remove ${d}: " + $_.Exception.Message) 'warn'
            }
        }
        if (Remove-FromUserPath $d) { Say "removed $d from PATH" 'ok' }
    }

    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    Say 'scheduled task removed (if it existed)' 'ok'

    $logDir = Join-Path $env:LOCALAPPDATA 'cguard'
    if (Test-Path -LiteralPath $logDir) {
        Say "audit log left in place: $logDir" 'info'
        Say 'delete that folder yourself if you want the history gone.' 'info'
    }

    Write-Host ''
    Say 'cguard uninstalled. Open a new terminal for PATH changes to apply.' 'ok'
    return
}

# ---------------------------------------------------------------- install

Write-Host ''
Write-Host '== cguard installer ==' -ForegroundColor Cyan
Write-Host ''

if (-not $InstallDir) { $InstallDir = Get-DefaultInstallDir }
$InstallDir = Get-RealPath $InstallDir

# Where are we running from? When piped through iex there is no script file,
# so fall back to downloading the repo zip.
$localSource = ''
$invoked = $MyInvocation.MyCommand.Path
if ($invoked) { $localSource = Split-Path -Parent $invoked }
elseif ($PSScriptRoot) { $localSource = $PSScriptRoot }

$hasLocal = $false
if ($localSource) {
    $hasLocal = Test-Path -LiteralPath (Join-Path $localSource 'cguard.ps1')
}

Say ("install directory : $InstallDir")
Say ("source            : " + $(if ($hasLocal) { "local checkout ($localSource)" } else { 'GitHub (main branch zip)' }))
Write-Host ''

if ((Test-Path -LiteralPath $InstallDir) -and -not $Force) {
    $existing = Join-Path $InstallDir 'cguard.ps1'
    if (Test-Path -LiteralPath $existing) {
        Say 'cguard is already installed here.' 'warn'
        Say 're-run with -Force to overwrite, or -Uninstall to remove.' 'info'
        Say ('installed version: ' + (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $existing version 2>&1))
        return
    }
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cguard-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    if ($hasLocal) {
        $files = @('cguard.ps1', 'cguard.cmd', 'README.md', 'README.zh-CN.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md')
        foreach ($f in $files) {
            $src = Join-Path $localSource $f
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $f) -Force
            }
        }
        foreach ($sub in @('modules', 'config', 'tests')) {
            $srcDir = Join-Path $localSource $sub
            if (Test-Path -LiteralPath $srcDir) {
                $dstDir = Join-Path $InstallDir $sub
                if (Test-Path -LiteralPath $dstDir) { Remove-Item -LiteralPath $dstDir -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force
            }
        }
        Say 'copied from local checkout' 'ok'
    } else {
        Say 'downloading...'
        $zip = Join-Path $tempRoot 'cguard.zip'
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

        $progressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing

        $extract = Join-Path $tempRoot 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $rootInside = @(Get-ChildItem -LiteralPath $extract -Directory)[0]
        if (-not $rootInside) { throw 'downloaded archive was empty' }

        foreach ($item in (Get-ChildItem -LiteralPath $rootInside.FullName -Force)) {
            $dest = Join-Path $InstallDir $item.Name
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
        }
        Say 'downloaded and extracted' 'ok'
    }

    $scriptPath = Join-Path $InstallDir 'cguard.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "cguard.ps1 missing after install at $scriptPath" }

    # shim: lets the user type "cguard ..." from any shell
    $shim = Join-Path $InstallDir 'cguard.cmd'
    $shimBody = @(
        '@echo off',
        'setlocal',
        'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cguard.ps1" %*',
        'endlocal',
        'exit /b %ERRORLEVEL%'
    ) -join "`r`n"
    Set-Content -LiteralPath $shim -Value $shimBody -Encoding ASCII
    Say 'launcher written (cguard.cmd)' 'ok'

    if (-not $NoPath) {
        $r = Add-ToUserPath $InstallDir
        if ($r -eq 'added') { Say "added $InstallDir to your user PATH" 'ok' }
        else { Say 'PATH already contains the install directory' 'ok' }
    } else {
        Say 'skipped PATH change (-NoPath)' 'info'
    }

    if ($InstallTask) {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath watch -Install -NoColor 2>&1 | Out-String
        if ($out -match 'installed') { Say 'scheduled guard task installed (every 6 hours)' 'ok' }
        else { Say ('task install said: ' + ($out.Trim() -split "`r?`n" | Select-Object -Last 1)) 'warn' }
    } else {
        Say 'scheduled task not installed; enable later with: cguard watch -Install' 'info'
    }

    Write-Host ''
    Say 'installed' 'ok'
    Say ("location : $InstallDir")
    Say ''
    Say 'next steps' 'info'
    Say '  1. open a NEW terminal (PATH changes only apply to new shells)'
    Say '  2. run:  cguard scan        where did my disk go'
    Say '  3. run:  cguard clean       preview, deletes nothing'
    Say '  4. run:  cguard clean -Force    actually reclaim'
    Say ''
    Say 'without a new terminal, use the full path:' 'info'
    Say ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" scan")

    if (-not $NoScan) {
        Write-Host ''
        Write-Host '== post-install scan ==' -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath scan -NoColor -Top 8
    }
}
catch {
    Say ('install failed: ' + $_.Exception.Message) 'err'
    exit 1
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
