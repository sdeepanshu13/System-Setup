<#
.SYNOPSIS
    Restores a Windows dev machine by installing all software via winget.
.DESCRIPTION
    Reads winget-packages.json from the script directory, installs all packages,
    and reports successes/failures. Run as Administrator.
.PARAMETER WhatIf
    Preview packages without installing.
#>

#Requires -RunAsAdministrator
param(
    [switch]$WhatIfMode
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$wingetJson = Join-Path $ScriptDir "winget-packages.json"

# ─── Validation ───────────────────────────────────────────
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget is not installed. Install App Installer from the Microsoft Store."
    exit 1
}

if (-not (Test-Path $wingetJson)) {
    Write-Error "winget-packages.json not found in $ScriptDir"
    exit 1
}

# ─── Parse package list ──────────────────────────────────
try {
    $json = Get-Content $wingetJson -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse winget-packages.json: $_"
    exit 1
}

$packages = @()
foreach ($source in $json.Sources) {
    foreach ($p in $source.Packages) {
        if ($p.PackageIdentifier) { $packages += $p.PackageIdentifier }
    }
}

if ($packages.Count -eq 0) {
    Write-Error "No packages found in winget-packages.json"
    exit 1
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Windows Software Restore" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Packages to install: $($packages.Count)" -ForegroundColor Yellow
Write-Host ""

# ─── Categorize for display ──────────────────────────────
$categories = [ordered]@{
    "Dev Tools"    = @("Git.Git", "GitHub.cli", "GitHub.GitHubDesktop", "GitHub.Copilot",
        "Microsoft.VisualStudioCode", "Microsoft.VisualStudio.Enterprise",
        "JetBrains.Toolbox", "Docker.DockerDesktop", "Warp.Warp")
    "Languages"    = @("Python.Python.3.14", "Python.Python.3.13", "Python.Launcher",
        "CoreyButler.NVMforWindows", "Microsoft.DotNet.SDK.10")
    "CLI / Infra"  = @("Microsoft.PowerShell", "Microsoft.WindowsTerminal",
        "Microsoft.AzureCLI", "Redis.Redis", "Microsoft.WSL", "Canonical.Ubuntu.2404")
    "Browsers"     = @("Google.Chrome.EXE", "Mozilla.Firefox", "Microsoft.Edge")
    "Productivity" = @("Microsoft.Teams", "Microsoft.Office", "Microsoft.OneDrive",
        "Google.GoogleDrive", "Adobe.Acrobat.Reader.64-bit")
    "Media / Misc" = @("VideoLAN.VLC", "Unity.UnityHub", "Samsung.SmartSwitch",
        "Yubico.YubikeyManager", "Yubico.YubiKeySmartCardMinidriver")
}

foreach ($cat in $categories.Keys) {
    $matched = $packages | Where-Object { $_ -in $categories[$cat] }
    if ($matched) {
        Write-Host "  [$cat]" -ForegroundColor Green
        $matched | ForEach-Object { Write-Host "    - $_" }
    }
}

# Show uncategorized (runtimes, libs, etc.)
$allCategorized = $categories.Values | ForEach-Object { $_ }
$uncategorized = $packages | Where-Object { $_ -notin $allCategorized }
if ($uncategorized) {
    Write-Host "  [Runtimes & Libraries]" -ForegroundColor Green
    $uncategorized | ForEach-Object { Write-Host "    - $_" }
}

Write-Host ""

if ($WhatIfMode) {
    Write-Host "WhatIf mode — no packages will be installed." -ForegroundColor Yellow
    exit 0
}

# ─── Install via winget import ───────────────────────────
Write-Host "Starting winget import..." -ForegroundColor Cyan
Write-Host "(This may take a while and prompt for elevation)" -ForegroundColor DarkGray
Write-Host ""

$importArgs = @(
    "import", $wingetJson,
    "--accept-package-agreements",
    "--accept-source-agreements",
    "--ignore-unavailable"
)
& winget @importArgs

Write-Host ""

# ─── Verify installation ────────────────────────────────
Write-Host "Verifying installed packages..." -ForegroundColor Cyan

$installedRaw = winget list --source winget 2>$null | Out-String
$succeeded = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[string]]::new()

foreach ($pkg in $packages) {
    if ($installedRaw -match [regex]::Escape($pkg)) {
        $succeeded.Add($pkg)
    }
    else {
        $failed.Add($pkg)
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Results" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Installed: $($succeeded.Count)/$($packages.Count)" -ForegroundColor Green

if ($failed.Count -gt 0) {
    Write-Host "  Failed:    $($failed.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Failed packages:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  To retry failed packages individually:" -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host "    winget install --id $_ --accept-package-agreements" -ForegroundColor DarkGray }
}
else {
    Write-Host "  All packages installed successfully!" -ForegroundColor Green
}

Write-Host ""
Write-Host "Next: Run bootstrap-dev.sh in Git Bash for zsh/p10k setup." -ForegroundColor Yellow
Write-Host ""