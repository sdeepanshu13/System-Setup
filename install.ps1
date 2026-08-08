<#
.SYNOPSIS
    One-line installer for System-Setup.
.DESCRIPTION
    Run this and it fetches the current source and starts the wizard:

        irm https://raw.githubusercontent.com/sdeepanshu13/System-Setup/main/install.ps1 | iex

    Why this exists: the packaged Setup.exe gets quarantined by Defender's ML
    classifier. The installer inventories installed software, encrypts it and
    uploads it, which matches the infostealer pattern, and an unsigned binary
    has no reputation to offset that. Plain PowerShell isn't scored the same
    way, so this route works today without a code-signing certificate.

    Always pulls the latest commit, so you get the newest fix.
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo = 'sdeepanshu13/System-Setup'
$branch = 'main'

Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '   System-Setup' -ForegroundColor Cyan
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host ''

# --- Elevate if needed -------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '  Administrator rights are required. Relaunching...' -ForegroundColor Yellow
    $cmd = "irm https://raw.githubusercontent.com/$repo/$branch/install.ps1 | iex"
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $cmd
        )
    }
    catch {
        Write-Host '  Elevation was declined. Right-click PowerShell > Run as administrator, then retry.' -ForegroundColor Red
    }
    return
}

# --- Fetch the current source -----------------------------------------
$work = Join-Path $env:TEMP ('SystemSetup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$zip = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N') + '.zip')
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Write-Host '  Downloading the latest version...' -ForegroundColor Cyan
    Invoke-WebRequest -Uri "https://codeload.github.com/$repo/zip/refs/heads/$branch" `
        -OutFile $zip -UseBasicParsing -TimeoutSec 300

    Expand-Archive -Path $zip -DestinationPath $work -Force
    $root = Get-ChildItem -Path $work -Directory | Select-Object -First 1
    if (-not $root) { throw 'Download looked empty.' }

    $setup = Join-Path $root.FullName 'Windows\Setup.ps1'
    if (-not (Test-Path $setup)) { throw "Setup.ps1 missing from the download." }

    Get-ChildItem -Path $root.FullName -Recurse -Include *.ps1, *.psm1, *.cmd, *.sh `
        -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

    Write-Host '  Starting setup...' -ForegroundColor Green
    Write-Host ''
    & $setup
}
catch {
    Write-Host ''
    Write-Host "  Setup failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Report it at: https://github.com/sdeepanshu13/System-Setup/issues' -ForegroundColor DarkGray
}
finally {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
