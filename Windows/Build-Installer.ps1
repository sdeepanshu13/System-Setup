<#
.SYNOPSIS
    Builds the System-Setup launcher with Inno Setup.
.DESCRIPTION
    The launcher is a thin bootstrapper: it carries install.ps1 only and fetches
    the application at run time.

    That matters for antivirus. Defender's cloud protection scores unsigned
    binaries mostly on reputation, which is tracked per file hash. While the app
    was bundled, every push produced a new binary with no reputation and
    downloads were quarantined. Keeping the payload outside means the hash only
    moves when the bootstrap logic does, so it can accumulate trust -- and users
    still get the latest code because it's fetched on each run.

    The launcher version is therefore pinned in installer.iss and is NOT the app
    version. -Version is accepted for compatibility but ignored.
#>
param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DistDir = Join-Path (Split-Path $ScriptDir) 'dist'
$Iss = Join-Path $ScriptDir 'installer.iss'

if ($Version) {
    Write-Host "  (ignoring -Version '$Version': the launcher version is pinned so its hash stays stable)" -ForegroundColor DarkGray
}
Write-Host 'Building System-Setup launcher...' -ForegroundColor Cyan

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

& $iscc $Iss
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
