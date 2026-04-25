<#
.SYNOPSIS
    One-command Windows dev machine setup. Works from PowerShell, CMD, or Git Bash.
.DESCRIPTION
    Phase 1: Auto-elevates and runs restore.ps1 (installs all winget packages
             in parallel — Git is installed first so we have bash for Phase 2).
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

# ─── Auto-elevate ────────────────────────────────────────
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

# ─── Phase 1: winget packages ────────────────────────────
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

# ─── Phase 2: bootstrap-dev.sh via Git Bash ──────────────
if (-not $SkipPhase2) {
    Write-Host ""
    Write-Host "Phase 2: zsh / dotfiles / SSH setup (via Git Bash)..." -ForegroundColor Cyan

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
        $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
        if ($cmd) { $bashExe = $cmd.Source }
    }

    if (-not $bashExe) {
        Write-Error "Git Bash not found. Install Git for Windows (winget install Git.Git) and rerun with -SkipPhase1."
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
    # Tell bootstrap-dev.sh to skip Phase 1 — we already did it.
    $env:SETUP_SKIP_PHASE1 = '1'

    # Convert C:\foo\bar to /c/foo/bar for bash
    $drive = $bootstrap.Substring(0, 1).ToLower()
    $bootstrapPosix = '/' + $drive + ($bootstrap.Substring(2) -replace '\\', '/')
    $bootstrapDirPosix = Split-Path -Parent $bootstrapPosix

    & $bashExe --login -i -c "cd `"$bootstrapDirPosix`" && bash `"$bootstrapPosix`""
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
Write-Host "  1. Close & reopen Windows Terminal — Git Bash + zsh is now the default."
Write-Host "  2. Add your SSH key to GitHub: https://github.com/settings/ssh/new"
Write-Host "     (Public key saved to: $ScriptDir\github-ssh-pubkey.txt)"
Write-Host "  3. Sign into Chrome / Docker / VS Code (Settings Sync) / JetBrains."
Write-Host ""

if ($Host.Name -eq 'ConsoleHost' -and -not $env:WT_SESSION) {
    Write-Host "Press Enter to exit..." -ForegroundColor DarkGray
    [void][System.Console]::ReadLine()
}
