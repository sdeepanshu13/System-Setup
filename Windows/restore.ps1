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

# --- Auto-elevate to Administrator -----------------------
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
            # Quote the value so paths/strings containing spaces survive elevation.
            $argList += "`"$($kv.Value)`""
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

# --- Per-run logging -------------------------------------
# When invoked via Setup.ps1, the parent already runs Start-Transcript into
# setup.log, so we DON'T start a second transcript (PS can only have one).
# We still set $RunLogDir so per-package logs land in the right place.
$script:OwnTranscript = $false
if ($env:SETUP_RUN_LOG_DIR -and (Test-Path $env:SETUP_RUN_LOG_DIR)) {
    $RunLogDir = $env:SETUP_RUN_LOG_DIR
}
else {
    # Running standalone -- create our own log folder + transcript.
    $LogRoot   = Join-Path $ScriptDir 'logs'
    $RunStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $RunLogDir = Join-Path $LogRoot $RunStamp
    New-Item -ItemType Directory -Path $RunLogDir -Force | Out-Null
    $TranscriptPath = Join-Path $RunLogDir 'setup.log'
    try { Start-Transcript -Path $TranscriptPath -Append | Out-Null; $script:OwnTranscript = $true } catch { }
    Write-Host "Log file: $TranscriptPath" -ForegroundColor DarkGray
}

trap {
    if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    break
}

# --- Validation -------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget is not installed. Install App Installer from the Microsoft Store."
    if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    exit 1
}

if (-not (Test-Path $wingetJson)) {
    Write-Error "winget-packages.json not found in $ScriptDir"
    if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    exit 1
}

# --- Refresh winget sources ------------------------------
# A stale or corrupt source cache is the #1 cause of mysterious package
# install failures (hash mismatches, "package not found", random hex codes).
# Reset + update once at the top so every run starts from a known-good state.
# Wrap in a job with a hard timeout so a hung CDN can't stall us forever.
Write-Host "Refreshing winget sources (reset + update)..." -ForegroundColor Cyan
$srcJob = Start-Job -ScriptBlock {
    & winget source reset --force *>&1 | Out-Null
    & winget source update *>&1 | Out-Null
}
if (Wait-Job -Job $srcJob -Timeout 120) {
    Receive-Job -Job $srcJob | Out-Null
    Write-Host "  Sources refreshed." -ForegroundColor DarkGray
}
else {
    Write-Warning "  winget source refresh timed out after 120s; continuing anyway."
    Stop-Job -Job $srcJob -ErrorAction SilentlyContinue
}
Remove-Job -Job $srcJob -Force -ErrorAction SilentlyContinue
Write-Host ""

# --- Parse package list --------------------------
try {
    $json = Get-Content $wingetJson -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse winget-packages.json: $_"
    if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }
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

# --- Pre-flight: skip already-installed packages ---------
Write-Host "Checking for already-installed packages..." -ForegroundColor Cyan
$installedSnapshot = winget list --source winget --accept-source-agreements 2>$null | Out-String

# Some packages are installed by tools other than winget (Git for Windows from
# its own installer, VS Code, etc.) and won't appear in `winget list` under
# their winget package ID. For these, also probe known on-disk locations.
function Test-PackagePresent([string]$pkg) {
    switch ($pkg) {
        'Git.Git' {
            return (Test-Path "$env:ProgramFiles\Git\bin\git.exe") -or
                   (Test-Path "${env:ProgramFiles(x86)}\Git\bin\git.exe") -or
                   (Test-Path "$env:LOCALAPPDATA\Programs\Git\bin\git.exe") -or
                   [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
        }
        'Microsoft.WindowsTerminal' {
            return [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
        }
        'Microsoft.PowerShell' {
            return (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") -or
                   [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)
        }
        'GitHub.cli' {
            return [bool](Get-Command gh.exe -ErrorAction SilentlyContinue)
        }
        'Microsoft.VisualStudioCode' {
            return (Test-Path "$env:ProgramFiles\Microsoft VS Code\Code.exe") -or
                   (Test-Path "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe")
        }
        default { return $false }
    }
}

$alreadyInstalled = @()
$toInstall = @()
foreach ($pkg in $packages) {
    if ($installedSnapshot -match [regex]::Escape($pkg)) {
        $alreadyInstalled += $pkg
    }
    elseif (Test-PackagePresent $pkg) {
        $alreadyInstalled += $pkg
    }
    else {
        $toInstall += $pkg
    }
}
Write-Host ("  Already installed: {0}" -f $alreadyInstalled.Count) -ForegroundColor DarkGray
Write-Host ("  To install:        {0}" -f $toInstall.Count) -ForegroundColor Yellow
if ($alreadyInstalled.Count -gt 0) {
    $alreadyInstalled | ForEach-Object { Write-Host "    [skip] $_" -ForegroundColor DarkGray }
}
Write-Host ""

if ($toInstall.Count -eq 0) {
    Write-Host "Nothing to install -- all packages already present." -ForegroundColor Green
    if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    exit 0
}

# Replace $packages with the filtered list for the rest of the script.
$packages = $toInstall

# --- Package filter: only install what the user selected -------
# SETUP_SELECTED_PACKAGES (from the GUI) contains exact winget IDs.
# SETUP_WINGET_GROUPS (from the console fallback) contains category names.
# If neither is set, install everything.
if ($env:SETUP_SELECTED_PACKAGES) {
    $allowedPkgs = $env:SETUP_SELECTED_PACKAGES -split ',' | ForEach-Object { $_.Trim() }
    $prioritySet = @('Git.Git','GitHub.cli','Microsoft.WindowsTerminal','Microsoft.PowerShell')
    $beforeCount = $packages.Count
    $packages = $packages | Where-Object {
        $prioritySet -contains $_ -or $allowedPkgs -contains $_
    }
    $droppedCount = $beforeCount - $packages.Count
    if ($droppedCount -gt 0) {
        Write-Host ("  Filtered out {0} package(s) not selected in UI." -f $droppedCount) -ForegroundColor DarkGray
    }
}
elseif ($env:SETUP_WINGET_GROUPS) {
    $allowedGroups = $env:SETUP_WINGET_GROUPS -split ',' | ForEach-Object { $_.Trim() }
    $prioritySet   = @('Git.Git','GitHub.cli','Microsoft.WindowsTerminal','Microsoft.PowerShell')
    $beforeCount   = $packages.Count
    $packages = $packages | Where-Object {
        $prioritySet -contains $_ -or $allowedGroups -contains (Get-Category $_)
    }
    $droppedCount = $beforeCount - $packages.Count
    if ($droppedCount -gt 0) {
        Write-Host ("  Filtered out {0} package(s) not in selected categories." -f $droppedCount) -ForegroundColor DarkGray
    }
}

if ($packages.Count -eq 0) {
    Write-Host "Nothing to install after filtering." -ForegroundColor Green
    if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    exit 0
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Windows Software Restore" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Packages to install: $($packages.Count)" -ForegroundColor Yellow
Write-Host ""

# --- Categorize for display (auto-derived from package IDs) --
function Get-Category([string]$id) {
    switch -Wildcard ($id) {
        'Git.*'                    { return 'Dev Tools' }
        'GitHub.*'                 { return 'Dev Tools' }
        'Microsoft.VisualStudio*'  { return 'Dev Tools' }
        'JetBrains.*'              { return 'Dev Tools' }
        'Docker.*'                 { return 'Dev Tools' }
        'Warp.*'                   { return 'Dev Tools' }
        'JanDeDobbeleer.*'         { return 'Dev Tools' }
        'Python.*'                 { return 'Languages' }
        'CoreyButler.*'            { return 'Languages' }
        'Microsoft.DotNet.SDK*'    { return 'Languages' }
        'EclipseAdoptium.*'        { return 'Languages' }
        'GoLang.*'                 { return 'Languages' }
        'Rustlang.*'               { return 'Languages' }
        'OpenJS.*'                 { return 'Languages' }
        'LLVM.*'                   { return 'Languages' }
        'MartinStorsjo.*'          { return 'Languages' }
        'Kitware.*'                { return 'Languages' }
        'Ninja-build.*'            { return 'Languages' }
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

# --- Install via winget ----------------------------------
# On winget v1.28+ the --ignore-security-hash flag is a restricted admin
# feature that must be explicitly enabled. Without it winget prints the usage
# help and exits. Enable it once; if the setting already exists this is a
# no-op.
try {
    & winget settings --enable InstallerHashOverride *>&1 | Out-Null
}
catch { }

$commonArgs = @(
    '--silent',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--disable-interactivity',
    '--ignore-warnings',
    '--ignore-security-hash',
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
    $logDir = Join-Path $RunLogDir 'packages'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Write-Host "Per-package logs: $logDir" -ForegroundColor DarkGray
    Write-Host ""

    # -- Phase A: Priority packages (Git + Terminal first, sequential) --
    # NOTE: priority packages are installed WITHOUT --disable-interactivity.
    # The Git installer in particular sometimes aborts when interactivity is
    # fully disabled (it tries to write to the registry / refresh PATH and
    # winget kills it). We're already elevated, so the only "prompts" winget
    # would suppress are progress bars -- safe to allow.
    # --ignore-security-hash works around the recurring INSTALLER_HASH_MISMATCH
    # (0x8A150006) failure on Git.Git when winget's manifest lags the actual
    # Git for Windows release.
    $priorityArgs = @(
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--ignore-warnings',
        '--ignore-security-hash',
        '--force',
        '--source', 'winget'
    )
    if ($priorityToInstall.Count -gt 0) {
        Write-Host "Phase A: Installing priority packages first (Git + Terminal)..." -ForegroundColor Cyan
        foreach ($pkg in $priorityToInstall) {
            $log = Join-Path $logDir ((($pkg -replace '[^A-Za-z0-9._-]', '_')) + '.log')
            Write-Host ("  -> installing: $pkg") -ForegroundColor DarkGray
            $wgArgs = @('install', '--id', $pkg, '--exact') + $priorityArgs
            & winget @wgArgs *>&1 | Tee-Object -FilePath $log | Out-Null
            $code = $LASTEXITCODE

            # Retry once with the full common args if the friendly attempt failed.
            if ($code -ne 0) {
                Write-Host ("     retry: $pkg (with --disable-interactivity)") -ForegroundColor DarkYellow
                $wgArgs = @('install', '--id', $pkg, '--exact') + $commonArgs + @('--force')
                & winget @wgArgs *>&1 | Tee-Object -FilePath $log -Append | Out-Null
                $code = $LASTEXITCODE
            }

            $status = if ($code -eq 0) { 'OK    ' } else { "FAIL($code)" }
            $color  = if ($code -eq 0) { 'Green' } else { 'Red' }
            Write-Host ("     {0} {1}" -f $status, $pkg) -ForegroundColor $color
            if ($code -ne 0) {
                Write-Host ("        log: $log") -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }

    Write-Host "Phase B: Installing remaining packages (throttle: $Throttle)..." -ForegroundColor Cyan
    Write-Host ""

    # Per-package timeout (5 minutes). Any installer that takes longer is killed.
    $pkgTimeoutSec = 300

    $completed = 0
    $total = $remainingPackages.Count
    $succeeded = 0
    $failed = [System.Collections.Generic.List[string]]::new()

    foreach ($pkg in $remainingPackages) {
        $completed++
        $log = Join-Path $logDir ("{0}.log" -f ($pkg -replace '[^A-Za-z0-9._-]', '_'))
        Write-Host ("  [{0,3}/{1}] installing: {2}" -f $completed, $total, $pkg) -ForegroundColor DarkGray -NoNewline

        $wgArgs = @('install', '--id', $pkg, '--exact') + $commonArgs

        # Run winget directly. No stdout capture (causes deadlocks).
        # Redirect output to log file via cmd /c piping.
        $wgArgStr = ($wgArgs | ForEach-Object { if ($_ -match ' ') { "`"$_`"" } else { $_ } }) -join ' '
        $cmdLine = "winget $wgArgStr > `"$log`" 2>&1"

        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmdLine" `
            -WindowStyle Hidden -PassThru

        if ($proc.WaitForExit($pkgTimeoutSec * 1000)) {
            $code = $proc.ExitCode
        }
        else {
            try { $proc.Kill() } catch { }
            "TIMEOUT after $pkgTimeoutSec seconds" | Out-File -FilePath $log -Append
            $code = -1
        }

        if ($code -eq 0) {
            Write-Host " OK" -ForegroundColor Green
            $succeeded++
        }
        else {
            Write-Host " FAIL($code)" -ForegroundColor Yellow
            $failed.Add($pkg)
        }
    }

    Write-Host ""
    Write-Host ("Phase B complete: {0} succeeded, {1} failed out of {2}" -f $succeeded, $failed.Count, $total) -ForegroundColor Cyan
}

Write-Host ""

# --- Verify installation --------------------------------
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
        $failed | ForEach-Object {
            Write-Host ("    winget install --id $_ --accept-package-agreements --force") -ForegroundColor DarkGray
            $logFile = Join-Path (Join-Path $RunLogDir 'packages') ((($_ -replace '[^A-Za-z0-9._-]', '_')) + '.log')
            if (Test-Path $logFile) {
                Write-Host ("      log: $logFile") -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host "  All packages installed successfully!" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Next: Run bootstrap-dev.sh in Git Bash for zsh/p10k setup." -ForegroundColor Yellow
Write-Host ""

if ($script:OwnTranscript) { try { Stop-Transcript | Out-Null } catch { } }

