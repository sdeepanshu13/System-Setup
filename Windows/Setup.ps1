<#
.SYNOPSIS
    One-command Windows dev machine setup. Works from PowerShell, CMD, or Git Bash.
.DESCRIPTION
    Phase 1: Auto-elevates and runs restore.ps1 (installs all winget packages
             in parallel -- Git is installed first so we have bash for Phase 2).
    Phase 2: Invokes bootstrap-dev.sh via Git Bash for zsh / dotfiles / SSH key.
.PARAMETER GitName
    Your full name for `git config --global user.name`.
.PARAMETER GitEmail
    Your email for `git config --global user.email` and SSH key generation.
.PARAMETER Throttle
    Max number of parallel winget installs (default: 5).
.PARAMETER SkipPhase1
    Skip the winget package install (Phase 1).
.PARAMETER SkipPhase2
    Skip the zsh / dotfiles / SSH setup (Phase 2).
.EXAMPLE
    # From PowerShell (will auto-elevate):
    .\Setup.ps1

.EXAMPLE
    # Pre-fill Git config to run fully unattended:
    .\Setup.ps1 -GitName "Jane Doe" -GitEmail "jane@example.com"
#>

param(
    [string]$GitName,
    [string]$GitEmail,
    [int]$Throttle = 5,
    [switch]$SkipPhase1,
    [switch]$SkipPhase2
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Auto-elevate ----------------------------------------
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

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Windows Dev Machine Setup" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# --- Grant ourselves all permissions (Windows equivalent of `chmod 777`) ---
# Strip Mark-of-the-Web from every script in this folder so a freshly
# downloaded zip runs without "do you want to run this file?" prompts,
# and set ExecutionPolicy to Bypass for this process so any nested .ps1
# (restore.ps1, future helpers) runs without policy errors.
try {
    Get-ChildItem -Path $ScriptDir -Recurse -Include *.ps1, *.psm1, *.psd1, *.cmd, *.bat, *.sh `
        -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
}
catch { }
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
}
catch { }

# --- Phase 1: winget packages ----------------------------
if (-not $SkipPhase1) {
    $restore = Join-Path $ScriptDir 'restore.ps1'
    if (-not (Test-Path $restore)) {
        Write-Error "restore.ps1 not found at $restore"
        exit 1
    }
    Write-Host "Phase 1: Installing software via winget..." -ForegroundColor Cyan
    & $restore -Throttle $Throttle
}
else {
    Write-Host "Skipping Phase 1 (winget install)." -ForegroundColor Yellow
}

# --- Phase 2: bootstrap-dev.sh via Git Bash --------------
if (-not $SkipPhase2) {
    Write-Host ""
    Write-Host "Phase 2: zsh / dotfiles / SSH setup (via Git Bash)..." -ForegroundColor Cyan

    # Prompt for Git identity here in PowerShell. The bash script runs
    # non-interactively (no TTY) so it can't prompt itself.
    if (-not $GitName) {
        $GitName = Read-Host "Enter your full name (for git config)"
    }
    if (-not $GitEmail) {
        $GitEmail = Read-Host "Enter your GitHub email (for git config + SSH key)"
    }

    # Locate Git Bash (bash.exe). Try several common install locations + PATH.
    $bashCandidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    $bashExe = $null
    foreach ($c in $bashCandidates) {
        if ($c -and (Test-Path $c)) { $bashExe = $c; break }
    }
    if (-not $bashExe) {
        # Refresh PATH from the registry -- Git was just installed by Phase 1
        # but our process inherited the pre-install PATH.
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
        $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
        if ($cmd) { $bashExe = $cmd.Source }
    }

    if (-not $bashExe) {
        Write-Host ""
        Write-Host "  !! Git Bash not found. Phase 1 likely failed to install Git.Git." -ForegroundColor Red
        Write-Host "  Attempting one last fallback: winget install Git.Git --force ..." -ForegroundColor Yellow
        & winget install --id Git.Git --exact --silent --accept-package-agreements `
            --accept-source-agreements --ignore-warnings --force --source winget 2>&1 |
            Tee-Object -FilePath (Join-Path $ScriptDir 'git-fallback-install.log') | Out-Null
        # Re-check
        foreach ($c in $bashCandidates) {
            if ($c -and (Test-Path $c)) { $bashExe = $c; break }
        }
    }

    if (-not $bashExe) {
        Write-Error @"
Git Bash still not found. Phase 2 cannot proceed.

To fix manually:
  1. Install Git for Windows: https://git-scm.com/download/win
     OR: winget install --id Git.Git --force
  2. Re-run this script with -SkipPhase1:
     .\Setup.ps1 -SkipPhase1

See the failure log: $ScriptDir\git-fallback-install.log
"@
        exit 1
    }
    Write-Host "  Using bash: $bashExe" -ForegroundColor DarkGray

    $bootstrap = Join-Path $ScriptDir 'bootstrap-dev.sh'
    if (-not (Test-Path $bootstrap)) {
        Write-Error "bootstrap-dev.sh not found at $bootstrap"
        exit 1
    }

    # Pass Git identity through environment so the bash script can run unattended.
    if ($GitName)  { $env:SETUP_GIT_NAME  = $GitName }
    if ($GitEmail) { $env:SETUP_GIT_EMAIL = $GitEmail }
    # Tell bootstrap-dev.sh to skip Phase 1 -- we already did it.
    $env:SETUP_SKIP_PHASE1 = '1'

    # Convert C:\foo\bar to /c/foo/bar for bash
    $drive = $bootstrap.Substring(0, 1).ToLower()
    $bootstrapPosix = '/' + $drive + ($bootstrap.Substring(2) -replace '\\', '/')
    $bootstrapDirPosix = Split-Path -Parent $bootstrapPosix

    # -c is enough; --login + -i would emit job-control warnings without a TTY.
    & $bashExe -c "cd '$bootstrapDirPosix' && bash '$bootstrapPosix'"
    $bashExit = $LASTEXITCODE

    Remove-Item Env:SETUP_GIT_NAME, Env:SETUP_GIT_EMAIL, Env:SETUP_SKIP_PHASE1 -ErrorAction SilentlyContinue

    if ($bashExit -ne 0) {
        Write-Warning "bootstrap-dev.sh exited with code $bashExit"
    }
}
else {
    Write-Host "Skipping Phase 2 (zsh / dotfiles)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Setup complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Close & reopen Windows Terminal -- Git Bash + zsh is now the default."
Write-Host "  2. Add your SSH key to GitHub: https://github.com/settings/ssh/new"
Write-Host "     (Public key saved to: $ScriptDir\github-ssh-pubkey.txt)"
Write-Host "  3. Sign into Chrome / Docker / VS Code (Settings Sync) / JetBrains."
Write-Host ""

# Show the pubkey so the user can copy it directly from this window.
$pubKeyPath = Join-Path $ScriptDir 'github-ssh-pubkey.txt'
if (Test-Path $pubKeyPath) {
    Write-Host "--- SSH Public Key (copy & paste into GitHub) ---" -ForegroundColor Cyan
    Get-Content $pubKeyPath | Write-Host
    Write-Host "-------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
}

if ($Host.Name -eq 'ConsoleHost' -and -not $env:WT_SESSION) {
    Write-Host "Press Enter to exit..." -ForegroundColor DarkGray
    [void][System.Console]::ReadLine()
}
