<#
.SYNOPSIS
    Enables the dev-useful Windows Optional Features.
.DESCRIPTION
    Idempotent: features already enabled are skipped. Reboot may be required
    after this script runs (the caller is informed via the `$script:RebootRequired` flag).

    Deliberately SKIPPED for safety / sanity reasons:
      - SMB1Protocol            (deprecated, well-known security hole)
      - TelnetClient            (cleartext protocol; install only if needed)
      - TFTP                    (cleartext, unauthenticated)
      - SimpleTCP               (echo/discard/etc -- attack surface, no use)
      - DirectPlay              (legacy game networking)
      - LegacyComponents        (DirectShow filters, etc.)
      - Internet-Explorer-*     (deprecated)
      - MicrosoftWindowsPowerShellV2* (PSv2 -- security risk)
.NOTES
    Must be run elevated. Sets $script:RebootRequired = $true if any feature
    enable returned RestartNeeded.
#>

param(
    [switch]$IncludeHyperV = $true,
    [switch]$IncludeIIS    = $false,   # opt-in: most devs don't need IIS locally
    [switch]$IncludeWSL    = $true
)

$ErrorActionPreference = 'Continue'
$script:RebootRequired = $false

# Verify elevation.
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# Curated list of dev-useful features. Order matters slightly (parents first).
$features = @()

if ($IncludeWSL) {
    $features += @(
        'Microsoft-Windows-Subsystem-Linux',
        'VirtualMachinePlatform'
    )
}

if ($IncludeHyperV) {
    $features += @(
        'Microsoft-Hyper-V-All',
        'HypervisorPlatform',
        'Containers',
        'Containers-DisposableClientVM'   # Windows Sandbox
    )
}

# .NET runtimes / dev features
$features += @(
    'NetFx3',
    'NetFx4-AdvSrvs',
    'WorkFolders-Client',
    'Printing-PrintToPDFServices-Features',
    'Printing-XPSServices-Features',
    'MediaPlayback'
)

if ($IncludeIIS) {
    $features += @(
        'IIS-WebServerRole',
        'IIS-WebServer',
        'IIS-CommonHttpFeatures',
        'IIS-ManagementConsole',
        'IIS-ASPNET45',
        'IIS-NetFxExtensibility45',
        'IIS-ISAPIExtensions',
        'IIS-ISAPIFilter'
    )
}

Write-Host ""
Write-Host "Enabling Windows Optional Features..." -ForegroundColor Cyan
Write-Host ("  Total features: {0}" -f $features.Count) -ForegroundColor DarkGray
Write-Host ""

# Get current state in one call rather than one per feature -- much faster.
try {
    $allFeatures = Get-WindowsOptionalFeature -Online -ErrorAction Stop
}
catch {
    Write-Error "Get-WindowsOptionalFeature failed: $_"
    exit 1
}

$enabled = 0
$skipped = 0
$failed  = 0

foreach ($name in $features) {
    $f = $allFeatures | Where-Object { $_.FeatureName -eq $name } | Select-Object -First 1
    if (-not $f) {
        Write-Host ("  [n/a]  {0,-50} (not available on this Windows edition)" -f $name) -ForegroundColor DarkGray
        $skipped++
        continue
    }
    if ($f.State -eq 'Enabled') {
        Write-Host ("  [skip] {0,-50} (already enabled)" -f $name) -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Write-Host ("  [..]   {0,-50} enabling..." -f $name) -ForegroundColor Yellow -NoNewline
    try {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
        Write-Host (" OK") -ForegroundColor Green
        $enabled++
        if ($result.RestartNeeded) { $script:RebootRequired = $true }
    }
    catch {
        Write-Host (" FAIL") -ForegroundColor Red
        Write-Host ("         $($_.Exception.Message)") -ForegroundColor DarkRed
        $failed++
    }
}

Write-Host ""
Write-Host ("Features enabled: {0}, skipped: {1}, failed: {2}" -f $enabled, $skipped, $failed) -ForegroundColor Cyan

# WSL post-config -- only if WSL got enabled (or was already on).
if ($IncludeWSL) {
    Write-Host ""
    Write-Host "Configuring WSL..." -ForegroundColor Cyan
    try {
        & wsl --set-default-version 2 *>&1 | Out-Null
        Write-Host "  Default WSL version set to 2." -ForegroundColor DarkGray
        # `wsl --update` requires the WSL feature to actually be functional,
        # which on a first-time enable requires a reboot. Try anyway; ignore failures.
        & wsl --update --no-launch *>&1 | Out-Null
    }
    catch {
        Write-Host "  WSL not yet ready (likely needs reboot first); skipping --update." -ForegroundColor DarkGray
    }
}

if ($script:RebootRequired) {
    Write-Host ""
    Write-Host "*** A reboot is required to finish enabling some features. ***" -ForegroundColor Yellow
}
