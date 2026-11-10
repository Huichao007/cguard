#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for install.ps1: install, launcher, PATH entry bookkeeping, uninstall.

.DESCRIPTION
    Uses a throwaway install directory under $env:TEMP and always passes
    -NoPath, so the real user PATH is never touched. The uninstall-from-inside
    case is covered explicitly: that is where the deferred-delete logic lives.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-install.ps1
#>

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'install.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw "install.ps1 not found at $installer" }

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:Fail++ }
}

function Invoke-Installer {
    param([string[]]$Arguments)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer) + $Arguments
    $out = & powershell.exe @all 2>&1
    return ($out | Out-String)
}

Write-Host ''
Write-Host '== cguard installer test =='
Write-Host ''

$target = Join-Path $env:TEMP ('cguard-inst-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    # ---------------------------------------------------------------- install
    Write-Host 'case 1: install from a local checkout'
    $out = Invoke-Installer @('-InstallDir', $target, '-NoPath', '-NoScan', '-Force')
    Assert-True (Test-Path -LiteralPath $target) 'install directory created'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'cguard.ps1')) 'cguard.ps1 copied'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'modules\Common.ps1')) 'modules copied'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'config\targets.json')) 'config copied'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'cguard.cmd')) 'launcher written'
    Assert-True ($out -match 'installed') 'installer reported success'
    Assert-True ($out -match 'NEW terminal') 'installer warns that PATH needs a new shell'

    # ---------------------------------------------------------------- launcher
    Write-Host ''
    Write-Host 'case 2: the installed launcher runs the tool'
    $cmd = Join-Path $target 'cguard.cmd'
    $v = (& cmd /c "`"$cmd`" version" 2>&1) | Out-String
    Assert-True ($v -match 'cguard 1\.\d+\.\d+') ('launcher reports a version (' + $v.Trim() + ')')

    $scanOut = (& cmd /c "`"$cmd`" scan -NoColor -Top 3" 2>&1) | Out-String
    Assert-True ($scanOut -match 'TARGET') 'launcher can run scan'
    Assert-True ($scanOut -match 'total') 'scan produced a summary'

    # ---------------------------------------------------------------- idempotent
    Write-Host ''
    Write-Host 'case 3: a second install without -Force refuses instead of clobbering'
    $out2 = Invoke-Installer @('-InstallDir', $target, '-NoPath', '-NoScan')
    Assert-True ($out2 -match 'already installed') 'second install warns'
    Assert-True ($out2 -match '-Force') 'second install explains how to overwrite'

    # ---------------------------------------------------------------- uninstall
    Write-Host ''
    Write-Host 'case 4: uninstall while running from inside the install folder'
    $copy = Join-Path $target 'install.ps1'
    Copy-Item -LiteralPath $installer -Destination $copy -Force

    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'install.ps1',
        '-Uninstall', '-InstallDir', $target)
    $unOut = (& powershell.exe -WorkingDirectory $target @all 2>&1) | Out-String
    Assert-True ($unOut -match 'uninstall') 'uninstall ran'
    Assert-True ($unOut -match 'scheduled removal|removed') 'uninstall reported the folder handling'

    # deletion is deferred a few seconds when the script sits inside the folder
    $gone = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-Path -LiteralPath $target)) { $gone = $true; break }
    }
    Assert-True $gone 'install directory is gone within 15s'

    # ---------------------------------------------------------------- no path leak
    Write-Host ''
    Write-Host 'case 5: the real user PATH was never modified'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    Assert-True (-not ($userPath -match 'cguard-inst-test')) 'no test directory leaked into user PATH'
}
finally {
    if (Test-Path -LiteralPath $target) {
        cmd /c ("rd /s /q `"{0}`" >nul 2>&1" -f $target) | Out-Null
    }
}

Write-Host ''
Write-Host ('== {0} passed, {1} failed ==' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
Write-Host 'all green'
exit 0
