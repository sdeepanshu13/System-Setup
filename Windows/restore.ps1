<#
.SYNOPSIS
    Restores a Windows dev machine by installing all software via winget.
.DESCRIPTION
    Reads winget-packages.json from the script directory, installs all packages
    in parallel and fully unattended (no prompts), and reports successes/failures.
    Best run as Administrator so per-package UAC prompts are suppressed.
.PARAMETER WhatIfMode
    Preview packages without installing.
.PARAMETER SkipVerify
    Skip post-install verification (faster).
.PARAMETER Throttle
    Max number of parallel winget installs. Default: 5.
.PARAMETER Sequential
    Force the old sequential `winget import` behavior.
#>

param(
    [switch]$WhatIfMode,
    [switch]$SkipVerify,
    [int]$Throttle = 5,
    [switch]$Sequential
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$wingetJson = Join-Path $ScriptDir "winget-packages.json"

# ─── Auto-elevate to Administrator ───────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not running as Administrator -- relaunching elevated..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Definition)`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        }
        else {
            $argList += "-$($kv.Key)"
            $argList += "$($kv.Value)"
        }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
        exit 0
    }
    catch {
        Write-Error "Failed to elevate: $_"
        exit 1
    }
}

# ─── Per-run logging ─────────────────────────────────────
$LogRoot = Join-Path $ScriptDir 'logs'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunLogDir = Join-Path $LogRoot $RunStamp
New-Item -ItemType Directory -Path $RunLogDir -Force | Out-Null
$TranscriptPath = Join-Path $RunLogDir 'restore.log'
try { Start-Transcript -Path $TranscriptPath -Append | Out-Null } catch { }
Write-Host "Log file: $TranscriptPath" -ForegroundColor DarkGray

# ─── Validation ───────────────────────────────────────────
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget is not installed. Install App Installer from the Microsoft Store."
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

if (-not (Test-Path $wingetJson)) {
    Write-Error "winget-packages.json not found in $ScriptDir"
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

# ─── Parse package list ──────────────────────────
try {
    $json = Get-Content $wingetJson -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse winget-packages.json: $_"
    try { Stop-Transcript | Out-Null } catch { }
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
    Write-Host "WhatIf mode -- no packages will be installed." -ForegroundColor Yellow
    exit 0
}

# ─── Install via winget ──────────────────────────────────
$commonArgs = @(
    '--silent',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--disable-interactivity',
    '--ignore-warnings',
    '--source', 'winget'
)

# Priority packages installed sequentially BEFORE the parallel batch so that
# Git + a working terminal exist for any follow-up work.
$priorityPackages = @(
    'Git.Git',
    'GitHub.cli',
    'Microsoft.WindowsTerminal',
    'Microsoft.PowerShell'
)
$priorityToInstall = $priorityPackages | Where-Object { $packages -contains $_ }
$remainingPackages = $packages | Where-Object { $priorityToInstall -notcontains $_ }

if ($Sequential) {
    Write-Host "Starting winget import (sequential)..." -ForegroundColor Cyan
    Write-Host "(This may take a while and prompt for elevation)" -ForegroundColor DarkGray
    Write-Host ""
    & winget import $wingetJson `
        --accept-package-agreements `
        --accept-source-agreements `
        --ignore-unavailable `
        --disable-interactivity
}
else {
    # Prefer ThreadJob (lightweight). Fall back to Start-Job if unavailable.
    $useThreadJob = $false
    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        $useThreadJob = $true
    }
    else {
        try {
            Import-Module ThreadJob -ErrorAction Stop
            $useThreadJob = $true
        }
        catch { $useThreadJob = $false }
    }

    $logDir = Join-Path $RunLogDir 'packages'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Write-Host "Per-package logs: $logDir" -ForegroundColor DarkGray
    Write-Host ""

    # ── Phase A: Priority packages (Git + Terminal first, sequential) ──
    if ($priorityToInstall.Count -gt 0) {
        Write-Host "Phase A: Installing priority packages first (Git + Terminal)..." -ForegroundColor Cyan
        foreach ($pkg in $priorityToInstall) {
            $log = Join-Path $logDir ((($pkg -replace '[^A-Za-z0-9._-]', '_')) + '.log')
            Write-Host ("  -> installing: $pkg") -ForegroundColor DarkGray
            $wgArgs = @('install', '--id', $pkg, '--exact') + $commonArgs
            & winget @wgArgs *>&1 | Tee-Object -FilePath $log | Out-Null
            $code = $LASTEXITCODE
            $status = if ($code -eq 0) { 'OK    ' } else { "FAIL($code)" }
            $color  = if ($code -eq 0) { 'Green' } else { 'Yellow' }
            Write-Host ("     {0} {1}" -f $status, $pkg) -ForegroundColor $color
        }
        Write-Host ""
    }

    Write-Host "Phase B: Installing remaining packages in parallel (throttle: $Throttle)..." -ForegroundColor Cyan
    Write-Host ""

    $scriptBlock = {
        param($pkg, $commonArgs, $logDir)
        $log = Join-Path $logDir ("{0}.log" -f ($pkg -replace '[^A-Za-z0-9._-]', '_'))
        $wgArgs = @('install', '--id', $pkg, '--exact') + $commonArgs
        try {
            $output = & winget @wgArgs 2>&1
            $output | Out-File -FilePath $log -Encoding UTF8
            [pscustomobject]@{
                Package  = $pkg
                ExitCode = $LASTEXITCODE
                Log      = $log
            }
        }
        catch {
            "EXCEPTION: $_" | Out-File -FilePath $log -Encoding UTF8
            [pscustomobject]@{
                Package  = $pkg
                ExitCode = -1
                Log      = $log
            }
        }
    }

    $jobs = @()
    $completed = 0
    $total = $remainingPackages.Count

    foreach ($pkg in $remainingPackages) {
        # Throttle: wait until a slot opens
        while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $Throttle) {
            $done = Wait-Job -Job $jobs -Any -Timeout 5
            if ($done) {
                foreach ($j in @($done)) {
                    $r = Receive-Job -Job $j
                    $completed++
                    $status = if ($r.ExitCode -eq 0) { 'OK    ' } else { "FAIL($($r.ExitCode))" }
                    $color  = if ($r.ExitCode -eq 0) { 'Green' } else { 'Yellow' }
                    Write-Host ("  [{0,3}/{1}] {2} {3}" -f $completed, $total, $status, $r.Package) -ForegroundColor $color
                    Remove-Job -Job $j | Out-Null
                }
                $jobs = $jobs | Where-Object { $_.State -eq 'Running' }
            }
        }

        Write-Host ("  -> queued: $pkg") -ForegroundColor DarkGray
        if ($useThreadJob) {
            $jobs += Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList $pkg, $commonArgs, $logDir
        }
        else {
            $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList $pkg, $commonArgs, $logDir
        }
    }

    # Drain remaining
    while ($jobs.Count -gt 0) {
        $done = Wait-Job -Job $jobs -Any
        foreach ($j in @($done)) {
            $r = Receive-Job -Job $j
            $completed++
            $status = if ($r.ExitCode -eq 0) { 'OK    ' } else { "FAIL($($r.ExitCode))" }
            $color  = if ($r.ExitCode -eq 0) { 'Green' } else { 'Yellow' }
            Write-Host ("  [{0,3}/{1}] {2} {3}" -f $completed, $total, $status, $r.Package) -ForegroundColor $color
            Remove-Job -Job $j | Out-Null
        }
        $jobs = $jobs | Where-Object { $_.State -eq 'Running' }
    }
}

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
Write-Host "Full log: $TranscriptPath" -ForegroundColor DarkGray
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }

# Keep elevated window open so the user can read the summary.
if ($Host.Name -eq 'ConsoleHost' -and -not $env:WT_SESSION) {
    Write-Host "Press Enter to exit..." -ForegroundColor DarkGray
    [void][System.Console]::ReadLine()
}
