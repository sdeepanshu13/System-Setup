<#
.SYNOPSIS
    Builds Setup.exe with Inno Setup.
.DESCRIPTION
    Replaces the ps2exe build. ps2exe produces a binary that decodes and runs an
    embedded script at runtime, which Windows Defender's ML classifier scores as
    a dropper (Trojan:Win32/Phonzy.B!ml) and quarantines. A conventional
    installer isn't treated that way.

    Finds ISCC.exe, or installs Inno Setup via winget/choco if it's missing.
    Signs the result when a certificate is available.
.PARAMETER Version
    Version stamped into the installer. Defaults to the newest git tag.
#>
param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DistDir = Join-Path (Split-Path $ScriptDir) 'dist'
$Iss = Join-Path $ScriptDir 'installer.iss'

if (-not $Version) {
    try {
        $tag = (& git -C $ScriptDir describe --tags --abbrev=0 2>$null)
        if ($tag) { $Version = ($tag -replace '^v', '') }
    }
    catch { }
    if (-not $Version) { $Version = '1.0.0' }
}
# Inno wants a numeric a.b.c version string.
if ($Version -notmatch '^\d+\.\d+\.\d+$') { $Version = ($Version -replace '[^\d.]', ''); }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { $Version = '1.0.0' }

Write-Host "Building System-Setup $Version..." -ForegroundColor Cyan

function Get-Iscc {
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget installs per-user by default, so check LOCALAPPDATA too.
    foreach ($p in @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

$iscc = Get-Iscc
if (-not $iscc) {
    Write-Host '  Inno Setup not found -- installing...' -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget install --id JRSoftware.InnoSetup --exact --silent `
            --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    }
    if (-not (Get-Iscc) -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        & choco install innosetup -y --no-progress 2>&1 | Out-Null
    }
    $iscc = Get-Iscc
}
if (-not $iscc) {
    Write-Error 'Inno Setup (ISCC.exe) not found. Install it from https://jrsoftware.org/isdl.php'
    exit 1
}
Write-Host "  Using: $iscc" -ForegroundColor DarkGray

if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir -Force | Out-Null }

& $iscc "/DAppVersion=$Version" $Iss
if ($LASTEXITCODE -ne 0) {
    Write-Error "Inno Setup failed with exit code $LASTEXITCODE"
    exit 1
}

$exePath = Join-Path $DistDir 'Setup.exe'
if (-not (Test-Path $exePath)) {
    Write-Error 'Build reported success but Setup.exe is missing.'
    exit 1
}

$signer = Join-Path $ScriptDir 'Sign-Exe.ps1'
if (Test-Path $signer) {
    Write-Host ''
    & $signer -Path $exePath
}

$sizeMB = (Get-Item $exePath).Length / 1MB
Write-Host ''
Write-Host '  Build successful!' -ForegroundColor Green
Write-Host ("  Output: {0}" -f $exePath) -ForegroundColor Green
Write-Host ("  Size:   {0:N1} MB" -f $sizeMB) -ForegroundColor Green
Write-Host ''
Write-Host '  Distribute this single file. Double-click to run.' -ForegroundColor DarkGray
