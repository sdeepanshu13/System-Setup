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
    [switch]$SkipPhase2,
    [switch]$Unattended
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

# --- Per-run logging (ONE file captures Phase 1 + 1b + 2) ---
$LogRoot   = Join-Path $ScriptDir 'logs'
$RunStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunLogDir = Join-Path $LogRoot $RunStamp
New-Item -ItemType Directory -Path $RunLogDir -Force | Out-Null
$SetupLog  = Join-Path $RunLogDir 'setup.log'
try { Start-Transcript -Path $SetupLog -Append | Out-Null } catch { }
# Pass log dir to restore.ps1 so per-package logs go here too.
# restore.ps1 won't start its own transcript when it sees this.
$env:SETUP_RUN_LOG_DIR = $RunLogDir
Write-Host "Log file: $SetupLog" -ForegroundColor DarkGray
Write-Host ""

# Guarantee we always close the transcript on error / ctrl-c paths.
trap {
    try { Stop-Transcript | Out-Null } catch { }
    Remove-Item Env:SETUP_RUN_LOG_DIR -ErrorAction SilentlyContinue
    break
}

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

# =====================================================================
# INTERACTIVE SETUP MENU -- let the user pick what to install
# =====================================================================
# Categories map to winget groups (restore.ps1) and bootstrap sections.
# Skip the menu with -Unattended (installs everything).

$allCategories = @(
    [pscustomobject]@{ Id= 1; Name='Developer Tools & IDEs';  Desc='Git, VS Code, Visual Studio, JetBrains, Docker, GitHub Desktop/CLI/Copilot, Warp, VS Build Tools'; On=$true; WingetGroup='Dev Tools' }
    [pscustomobject]@{ Id= 2; Name='Programming Languages';   Desc='Python 3.14, Node.js LTS + NVM, .NET SDK 10, Java JDK 17+21, Go, Rust, C/C++ (LLVM, MinGW, CMake, Ninja)'; On=$true; WingetGroup='Languages,Other' }
    [pscustomobject]@{ Id= 3; Name='Web Browsers';            Desc='Google Chrome, Mozilla Firefox'; On=$true; WingetGroup='Browsers' }
    [pscustomobject]@{ Id= 4; Name='Cloud & CLI Tools';       Desc='Azure CLI, PowerShell 7, Redis, WSL + Ubuntu 24.04'; On=$true; WingetGroup='CLI / Infra' }
    [pscustomobject]@{ Id= 5; Name='Office & Productivity';   Desc='Teams, Office 365, OneDrive, Google Drive, Adobe Acrobat Reader'; On=$true; WingetGroup='Productivity' }
    [pscustomobject]@{ Id= 6; Name='Media & Utilities';       Desc='VLC, Unity Hub, Samsung SmartSwitch, YubiKey Manager, Remote Help'; On=$true; WingetGroup='Media / Misc' }
    [pscustomobject]@{ Id= 7; Name='Runtimes & Libraries';    Desc='.NET Desktop/AspNet runtimes, .NET Framework DevPack 4, VCRedist 2015+, ODBC/SQL types'; On=$true; WingetGroup='Runtimes' }
    [pscustomobject]@{ Id= 8; Name='Shell: Git Bash + Zsh';   Desc='Zsh on Git Bash, Oh My Zsh, Powerlevel10k theme, MesloLGS Nerd Font, Windows Terminal default'; On=$true; WingetGroup='' }
    [pscustomobject]@{ Id= 9; Name='Shell: Oh My Posh';       Desc='Beautiful prompt for PowerShell & CMD (Nerd Font icons, git status, etc.)'; On=$true; WingetGroup='' }
    [pscustomobject]@{ Id=10; Name='Windows Features';        Desc='WSL2, Hyper-V, Containers, Windows Sandbox, .NET 3.5, Hypervisor Platform'; On=$true; WingetGroup='' }
    [pscustomobject]@{ Id=11; Name='VS Code Extensions';      Desc='Restore all extensions from vscode-extensions.txt (ESLint, GitLens, themes, etc.)'; On=$true; WingetGroup='' }
    [pscustomobject]@{ Id=12; Name='Language Tooling';        Desc='npm globals (React/TS/ESLint), Python pipx tools (uv/ruff/poetry), Rust components, Go workspace, Maven, Gradle'; On=$true; WingetGroup='' }
    [pscustomobject]@{ Id=13; Name='Git Config & SSH Key';    Desc='Set git identity + defaults, generate ed25519 SSH key for GitHub'; On=$true; WingetGroup='' }
)

function Show-SetupMenu {
    param([pscustomobject[]]$cats)

    $done = $false
    while (-not $done) {
        Clear-Host
        Write-Host ""
        Write-Host "  =============================================" -ForegroundColor Cyan
        Write-Host "    Windows Dev Machine Setup - Configuration" -ForegroundColor Cyan
        Write-Host "  =============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Select what to install. Enter a number to toggle on/off." -ForegroundColor DarkGray
        Write-Host ""

        foreach ($c in $cats) {
            $check = $(if ($c.On) { 'x' } else { ' ' })
            $color = $(if ($c.On) { 'Green' } else { 'DarkGray' })
            $num   = "{0,2}" -f $c.Id
            Write-Host ("  [{0}] {1}. " -f $check, $num) -NoNewline -ForegroundColor $color
            Write-Host ("{0,-28}" -f $c.Name) -NoNewline -ForegroundColor White
            Write-Host (" {0}" -f $c.Desc) -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  Commands:  " -NoNewline -ForegroundColor DarkGray
        Write-Host "a" -NoNewline -ForegroundColor Yellow
        Write-Host " = select all   " -NoNewline -ForegroundColor DarkGray
        Write-Host "n" -NoNewline -ForegroundColor Yellow
        Write-Host " = select none   " -NoNewline -ForegroundColor DarkGray
        Write-Host "go" -NoNewline -ForegroundColor Green
        Write-Host " = start install   " -NoNewline -ForegroundColor DarkGray
        Write-Host "q" -NoNewline -ForegroundColor Red
        Write-Host " = quit" -ForegroundColor DarkGray
        Write-Host ""
        $userChoice = Read-Host "  >"

        switch ($userChoice.Trim().ToLower()) {
            'go'  { $done = $true }
            'a'   { $cats | ForEach-Object { $_.On = $true } }
            'n'   { $cats | ForEach-Object { $_.On = $false } }
            'q'   { Write-Host "Cancelled."; exit 0 }
            default {
                $num = 0
                if ([int]::TryParse($userChoice.Trim(), [ref]$num)) {
                    $match = $cats | Where-Object { $_.Id -eq $num }
                    if ($match) { $match.On = -not $match.On }
                }
            }
        }
    }
}

# --- Default terminal/shell chooser ---
$defaultShellOptions = @(
    [pscustomobject]@{ Key='1'; Name='Git Bash + Zsh';  Desc='(recommended) Git Bash with zsh + Powerlevel10k as default, elevated' }
    [pscustomobject]@{ Key='2'; Name='PowerShell 7';     Desc='pwsh.exe as default profile' }
    [pscustomobject]@{ Key='3'; Name='PowerShell 5';     Desc='Windows PowerShell (built-in, legacy)' }
    [pscustomobject]@{ Key='4'; Name='Command Prompt';   Desc='CMD with Clink + Oh My Posh' }
    [pscustomobject]@{ Key='5'; Name='Keep current';     Desc='Don''t change the Windows Terminal default' }
)

function Show-DefaultShellMenu {
    Write-Host ""
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host "    Choose your default terminal profile" -ForegroundColor Cyan
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This sets which shell opens when you launch Windows Terminal." -ForegroundColor DarkGray
    Write-Host ""
    foreach ($o in $defaultShellOptions) {
        $color = $(if ($o.Key -eq '1') { 'Green' } else { 'White' })
        Write-Host ("    {0}. " -f $o.Key) -NoNewline -ForegroundColor Yellow
        Write-Host ("{0,-20}" -f $o.Name) -NoNewline -ForegroundColor $color
        Write-Host (" {0}" -f $o.Desc) -ForegroundColor DarkGray
    }
    Write-Host ""
    $choice = Read-Host "  Choose [1-5, default=1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
    return $choice.Trim()
}

if (-not $Unattended) {
    # Launch the GUI picker (Windows Forms with checkboxes + radio buttons).
    $uiScript = Join-Path $ScriptDir 'Setup-UI.ps1'
    if (Test-Path $uiScript) {
        Write-Host "Opening setup configuration window..." -ForegroundColor Cyan
        & $uiScript
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Setup cancelled by user." -ForegroundColor Yellow
            try { Stop-Transcript | Out-Null } catch { }
            exit 0
        }
        $shellChoice = $env:SETUP_DEFAULT_SHELL
        # $env:SETUP_CATEGORIES is already set by the UI script.
    }
    else {
        # Fallback to console menu if GUI script is missing.
        Show-SetupMenu -cats $allCategories
        $shellChoice = Show-DefaultShellMenu
        $env:SETUP_DEFAULT_SHELL = $shellChoice
    }
}
else {
    $shellChoice = '1'
    $env:SETUP_DEFAULT_SHELL = '1'
    $env:SETUP_CATEGORIES = '1,2,3,4,5,6,7,8,9,10,11,12,13'
}

# Build the selected set for downstream scripts.
# $env:SETUP_CATEGORIES is now set (by GUI, console fallback, or -Unattended).
$selectedIds = $env:SETUP_CATEGORIES
if ([string]::IsNullOrEmpty($selectedIds)) {
    Write-Host "No categories selected. Nothing to do." -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}
$catIdList = $selectedIds -split ',' | ForEach-Object { [int]$_.Trim() }

# Map selected category IDs to winget groups for restore.ps1.
$catToWingetGroup = @{
    1  = 'Dev Tools'
    2  = 'Languages,Other'
    3  = 'Browsers'
    4  = 'CLI / Infra'
    5  = 'Productivity'
    6  = 'Media / Misc'
    7  = 'Runtimes'
}
$selectedWingetGroups = ($catIdList | Where-Object { $catToWingetGroup.ContainsKey($_) } |
    ForEach-Object { $catToWingetGroup[$_] }) -join ','
$env:SETUP_WINGET_GROUPS = $selectedWingetGroups

# Determine phase skips from selections.
$hasWingetCategories = $selectedWingetGroups.Length -gt 0
if (-not $hasWingetCategories) { $SkipPhase1 = $true }

$hasPhase2 = ($catIdList | Where-Object { $_ -in @(8,9,11,12,13) }).Count -gt 0
if (-not $hasPhase2) { $SkipPhase2 = $true }

Write-Host ""
Write-Host ("Selected: {0} of 13 categories" -f $catIdList.Count) -ForegroundColor Cyan
Write-Host ""

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

# --- Phase 1b: Windows Optional Features -----------------
if ($catIdList -contains 10) {
    $featuresScript = Join-Path $ScriptDir 'Enable-WindowsFeatures.ps1'
    if (Test-Path $featuresScript) {
        Write-Host ""
        Write-Host "Phase 1b: Enabling Windows Optional Features (WSL, Hyper-V, Containers, Sandbox, .NET)..." -ForegroundColor Cyan
        & $featuresScript
    }
}

# --- Phase 2: bootstrap-dev.sh via Git Bash --------------
if (-not $SkipPhase2) {
    Write-Host ""
    Write-Host "Phase 2: zsh / dotfiles / SSH setup (via Git Bash)..." -ForegroundColor Cyan

    # Try to read existing git identity so we don't re-prompt on every run.
    $existingGitExe = $null
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe",
                     "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
                     "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if (Test-Path $p) { $existingGitExe = $p; break }
    }
    if (-not $existingGitExe) {
        $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($cmd) { $existingGitExe = $cmd.Source }
    }
    if ($existingGitExe) {
        if (-not $GitName) {
            try { $GitName = (& $existingGitExe config --global user.name) 2>$null } catch { }
        }
        if (-not $GitEmail) {
            try { $GitEmail = (& $existingGitExe config --global user.email) 2>$null } catch { }
        }
    }

    # Prompt for Git identity here in PowerShell only if still missing.
    # The bash script runs non-interactively (no TTY) so it can't prompt itself.
    if (-not $GitName) {
        $GitName = Read-Host "Enter your full name (for git config)"
    }
    else {
        Write-Host "  Git name:  $GitName (already configured)" -ForegroundColor DarkGray
    }
    if (-not $GitEmail) {
        $GitEmail = Read-Host "Enter your GitHub email (for git config + SSH key)"
    }
    else {
        Write-Host "  Git email: $GitEmail (already configured)" -ForegroundColor DarkGray
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
        Write-Host "  Fallback 1: winget install Git.Git --force --ignore-security-hash ..." -ForegroundColor Yellow
        & winget install --id Git.Git --exact --silent --accept-package-agreements `
            --accept-source-agreements --ignore-warnings --force --ignore-security-hash --source winget 2>&1 |
            Tee-Object -FilePath (Join-Path $ScriptDir 'git-fallback-install.log') | Out-Null
        # Re-check
        foreach ($c in $bashCandidates) {
            if ($c -and (Test-Path $c)) { $bashExe = $c; break }
        }
    }

    # Fallback 2: bypass winget entirely and download Git installer from git-scm.com.
    if (-not $bashExe) {
        Write-Host "  Fallback 2: downloading Git installer directly from git-scm.com ..." -ForegroundColor Yellow
        try {
            $api = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
                -UseBasicParsing -Headers @{ 'User-Agent' = 'System-Setup' } -TimeoutSec 30
            $asset = $api.assets | Where-Object {
                $_.name -like '*-64-bit.exe' -and $_.name -notlike '*Portable*' -and $_.name -notlike '*MinGit*'
            } | Select-Object -First 1
            if ($asset) {
                $installerPath = Join-Path $env:TEMP $asset.name
                Write-Host "    downloading: $($asset.browser_download_url)" -ForegroundColor DarkGray
                # 5-minute hard ceiling so a flaky network can't hang the script.
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath `
                    -UseBasicParsing -TimeoutSec 300
                Write-Host "    running silent installer ..." -ForegroundColor DarkGray
                $proc = Start-Process -FilePath $installerPath `
                    -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES' `
                    -Wait -PassThru
                Write-Host "    installer exit code: $($proc.ExitCode)" -ForegroundColor DarkGray
                Remove-Item $installerPath -ErrorAction SilentlyContinue
            }
            else {
                Write-Warning "Could not find a Git installer asset on the latest release."
            }
        }
        catch {
            Write-Warning "Direct download fallback failed: $_"
        }
        # Refresh PATH again and re-check.
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
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

    # Convert C:\foo\bar to /c/foo/bar for bash.
    # NOTE: do NOT use Split-Path here -- it uses the Windows separator and
    # would mangle a forward-slash path back into backslashes.
    function ConvertTo-PosixPath([string]$winPath) {
        $d = $winPath.Substring(0, 1).ToLower()
        return '/' + $d + ($winPath.Substring(2) -replace '\\', '/')
    }
    $bootstrapPosix    = ConvertTo-PosixPath $bootstrap
    $bootstrapDirPosix = ConvertTo-PosixPath $ScriptDir

    # -c is enough; --login + -i would emit job-control warnings without a TTY.
    # Tee bash output into our run log so Phase 2 is captured too.
    $bashLog = Join-Path $RunLogDir 'bootstrap-dev.log'
    & $bashExe -c "cd '$bootstrapDirPosix' && bash '$bootstrapPosix' 2>&1" |
        Tee-Object -FilePath $bashLog
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

Write-Host "Log file: $SetupLog" -ForegroundColor DarkGray
Write-Host "  Per-package logs: $RunLogDir\packages\" -ForegroundColor DarkGray
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }
Remove-Item Env:SETUP_RUN_LOG_DIR -ErrorAction SilentlyContinue

