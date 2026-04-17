<#
.SYNOPSIS
    Restores a Windows dev machine by installing all software via winget.
.DESCRIPTION
    Reads winget-packages.json from the script directory, installs all packages,
    and reports successes/failures. Best run as Administrator.
.PARAMETER WhatIfMode
    Preview packages without installing.
.PARAMETER SkipVerify
    Skip post-install verification (faster).
#>

param(
    [switch]$WhatIfMode,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$wingetJson = Join-Path $ScriptDir "winget-packages.json"

# ─── Soft admin check ────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. Some packages may fail to install."
}

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

# ─── Categorize for display (auto-derived from package IDs) ──
function Get-Category([string]$id) {
    switch -Wildcard ($id) {
        'Git.*'                    { return 'Dev Tools' }
        'GitHub.*'                 { return 'Dev Tools' }
        'Microsoft.VisualStudio*'  { return 'Dev Tools' }
        'JetBrains.*'              { return 'Dev Tools' }
        'Docker.*'                 { return 'Dev Tools' }
        'Warp.*'                   { return 'Dev Tools' }
        'Python.*'                 { return 'Languages' }
        'CoreyButler.*'            { return 'Languages' }
        'Microsoft.DotNet.SDK*'    { return 'Languages' }
        'Microsoft.PowerShell'     { return 'CLI / Infra' }
        'Microsoft.WindowsTerminal' { return 'CLI / Infra' }
        'Microsoft.AzureCLI'       { return 'CLI / Infra' }
        'Redis.*'                  { return 'CLI / Infra' }
        'Microsoft.WSL'            { return 'CLI / Infra' }
        'Canonical.*'              { return 'CLI / Infra' }
        'Google.Chrome*'           { return 'Browsers' }
        'Mozilla.*'                { return 'Browsers' }
        'Microsoft.Edge'           { return 'Browsers' }
        'Microsoft.Teams'          { return 'Productivity' }
        'Microsoft.Office'         { return 'Productivity' }
        'Microsoft.OneDrive'       { return 'Productivity' }
        'Google.GoogleDrive'       { return 'Productivity' }
        'Adobe.*'                  { return 'Productivity' }
        'VideoLAN.*'               { return 'Media / Misc' }
        'Unity.*'                  { return 'Media / Misc' }
        'Samsung.*'                { return 'Media / Misc' }
        'Yubico.*'                 { return 'Media / Misc' }
        'Microsoft.VCRedist*'      { return 'Runtimes' }
        'Microsoft.VCLibs*'        { return 'Runtimes' }
        'Microsoft.DotNet.*'       { return 'Runtimes' }
        'Microsoft.UI.Xaml*'       { return 'Runtimes' }
        'Microsoft.WindowsApp*'    { return 'Runtimes' }
        default                    { return 'Other' }
    }
}

$grouped = $packages | Group-Object { Get-Category $_ } | Sort-Object Name
foreach ($group in $grouped) {
    Write-Host "  [$($group.Name)]" -ForegroundColor Green
    $group.Group | ForEach-Object { Write-Host "    - $_" }
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
if ($SkipVerify) {
    Write-Host "Skipping verification (use without -SkipVerify to check)." -ForegroundColor DarkGray
}
else {
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
}

Write-Host ""
Write-Host "Next: Run bootstrap-dev.sh in Git Bash for zsh/p10k setup." -ForegroundColor Yellow
Write-Host ""