<#
.SYNOPSIS
    macOS dev machine setup -- Homebrew packages, shell, dotfiles.
.DESCRIPTION
    Mirrors the Windows installer and shares its profile/OTP/encryption layer
    (Shared/Modules/SetupCore.psm1), so selections saved on Windows come back
    here and vice-versa.

    Run via Setup.sh (installs Homebrew + PowerShell first), or directly:
        pwsh ./Setup.ps1
.PARAMETER Unattended
    Install the catalogue defaults without prompting.
.PARAMETER SkipPackages
    Skip the Homebrew install phase.
.PARAMETER SkipBootstrap
    Skip the shell/dotfiles phase.
#>
param(
    [string]$GitName,
    [string]$GitEmail,
    [switch]$Unattended,
    [switch]$SkipPackages,
    [switch]$SkipBootstrap
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SharedRoot = Join-Path (Split-Path -Parent $ScriptDir) 'Shared'

if (-not $IsMacOS) { Write-Warning 'This installer targets macOS. Use Windows/Setup.cmd on Windows.' }

# --- Logging -------------------------------------------------
$RunLogDir = Join-Path $ScriptDir ('logs/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $RunLogDir -Force | Out-Null
$SetupLog = Join-Path $RunLogDir 'setup.log'
try { Start-Transcript -Path $SetupLog -Append | Out-Null } catch { }

Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '   macOS Dev Machine Setup' -ForegroundColor Cyan
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host "  Log: $SetupLog" -ForegroundColor DarkGray

# --- Homebrew ------------------------------------------------
function Get-BrewPath {
    $cmd = Get-Command brew -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @('/opt/homebrew/bin/brew', '/usr/local/bin/brew')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$brew = Get-BrewPath
if (-not $brew -and -not $SkipPackages) {
    Write-Error @'
Homebrew is not installed. Run Setup.sh instead -- it installs Homebrew first:
    ./Setup.sh
Or install it manually: https://brew.sh
'@
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
if ($brew) {
    # brew's shellenv isn't inherited when pwsh is launched directly.
    $brewPrefix = Split-Path -Parent (Split-Path -Parent $brew)
    $env:PATH = "$brewPrefix/bin:$brewPrefix/sbin:$env:PATH"
}

# --- Catalogue + shared profile core -------------------------
$cataloguePath = Join-Path $ScriptDir 'brew-packages.json'
if (-not (Test-Path $cataloguePath)) {
    Write-Error "brew-packages.json not found at $cataloguePath"
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
$catalogue = Get-Content $cataloguePath -Raw | ConvertFrom-Json

$manager = $null
$coreModule = Join-Path $SharedRoot 'Modules/SetupCore.psm1'
if (Test-Path $coreModule) {
    try {
        Import-Module $coreModule -Force -ErrorAction Stop
        $manager = New-ProfileManager -SharedRoot $SharedRoot
    }
    catch { Write-Warning "Profile sync unavailable: $_" }
}

# --- Selection -----------------------------------------------
if ($Unattended) {
    $selection = @{
        Packages = @(foreach ($s in $catalogue.sections) {
                foreach ($i in $s.items) { if ($i.default) { @{ Key = $i.id; Type = $i.type } } }
            })
        Features = @(foreach ($s in $catalogue.features) {
                foreach ($i in $s.items) { if ($i.default) { $i.flag } } })
        Profile  = $null
    }
}
else {
    . (Join-Path $ScriptDir 'Setup-UI.ps1')
    $selection = Show-SetupConsole -Catalogue $catalogue -Manager $manager
}

$features = @($selection.Features)
Write-Host ''
Write-Host ("  Selected {0} package(s), {1} feature(s)." -f $selection.Packages.Count, $features.Count) -ForegroundColor Cyan

# --- Phase 1: Homebrew packages ------------------------------
function Install-BrewPackages {
    param([array]$Packages, [string]$Brew, [string]$LogDir)

    $pkgLogDir = Join-Path $LogDir 'packages'
    New-Item -ItemType Directory -Path $pkgLogDir -Force | Out-Null

    Write-Host ''
    Write-Host '  Phase 1: Installing Homebrew packages...' -ForegroundColor Cyan
    & $Brew update 2>&1 | Out-Null

    $installedFormulae = @(& $Brew list --formula 2>$null)
    $installedCasks = @(& $Brew list --cask 2>$null)

    $done = 0; $ok = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Packages) {
        $done++
        $isCask = $p.Type -eq 'cask'
        $already = if ($isCask) { $installedCasks -contains $p.Key } else { $installedFormulae -contains $p.Key }
        if ($already) {
            Write-Host ("    [{0,3}/{1}] {2} -- already installed" -f $done, $Packages.Count, $p.Key) -ForegroundColor DarkGray
            $ok++
            continue
        }

        Write-Host ("    [{0,3}/{1}] installing {2}..." -f $done, $Packages.Count, $p.Key) -NoNewline
        $log = Join-Path $pkgLogDir (($p.Key -replace '[^A-Za-z0-9._@-]', '_') + '.log')
        $brewArgs = @('install')
        if ($isCask) { $brewArgs += '--cask' }
        $brewArgs += $p.Key

        & $Brew @brewArgs *>&1 | Out-File -FilePath $log -Encoding utf8
        if ($LASTEXITCODE -eq 0) { Write-Host ' OK' -ForegroundColor Green; $ok++ }
        else { Write-Host " FAILED (see $log)" -ForegroundColor Yellow; $failed.Add($p.Key) }
    }

    Write-Host ''
    Write-Host ("  Packages: {0} ok, {1} failed" -f $ok, $failed.Count) -ForegroundColor Cyan
    if ($failed.Count) { $failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow } }
}

if (-not $SkipPackages -and $selection.Packages.Count -gt 0) {
    if ($features -contains 'xcodeclt') {
        if (-not (xcode-select -p 2>$null)) {
            Write-Host '  Installing Xcode Command Line Tools (may open a dialog)...' -ForegroundColor Cyan
            xcode-select --install 2>$null
        }
    }
    Install-BrewPackages -Packages $selection.Packages -Brew $brew -LogDir $RunLogDir
}
else {
    Write-Host '  Skipping package install.' -ForegroundColor Yellow
}

# --- Phase 2: shell / dotfiles -------------------------------
if (-not $SkipBootstrap) {
    $bootstrap = Join-Path $ScriptDir 'bootstrap-mac.sh'
    if (Test-Path $bootstrap) {
        if (-not $GitName -and $manager -and $manager.Identity) {
            $GitName = $env:SETUP_USER_NAME
        }
        if (-not $GitEmail -and $manager -and $manager.Identity -and $manager.Identity.IsEmail()) {
            $GitEmail = $manager.Identity.Value
        }
        if (-not $GitName) { $GitName = (git config --global user.name) 2>$null }
        if (-not $GitEmail) { $GitEmail = (git config --global user.email) 2>$null }
        if (-not $GitName -and ($features -contains 'gitssh')) { $GitName = Read-Host '  Your full name (git config)' }
        if (-not $GitEmail -and ($features -contains 'gitssh')) { $GitEmail = Read-Host '  Your email (git config + SSH key)' }

        $env:SETUP_FEATURES = ($features -join ',')
        if ($GitName) { $env:SETUP_GIT_NAME = $GitName }
        if ($GitEmail) { $env:SETUP_GIT_EMAIL = $GitEmail }

        Write-Host ''
        Write-Host '  Phase 2: Shell, dotfiles and tooling...' -ForegroundColor Cyan
        chmod +x $bootstrap 2>$null
        & bash $bootstrap 2>&1 | Tee-Object -FilePath (Join-Path $RunLogDir 'bootstrap-mac.log')
    }
}

# --- Save the profile ----------------------------------------
if ($selection.Profile -and $selection.Profile.Passphrase) {
    try {
        $data = New-ProfileData -Name $env:SETUP_GIT_NAME `
            -Packages @($selection.Packages | ForEach-Object { $_.Key }) `
            -Features $features -DefaultShell 'zsh'
        $saved = $selection.Profile.Manager.SaveProfile($selection.Profile.Passphrase, $data)
        if ($saved.Ok) {
            Write-Host ''
            Write-Host '  Preferences saved (encrypted).' -ForegroundColor DarkGray
            $pub = $selection.Profile.Manager.PublishIfLocal()
            if ($pub.Ok -and $pub.Reason -eq 'pushed') { Write-Host '  Synced to git.' -ForegroundColor DarkGray }
        }
        else { Write-Warning "Could not save preferences: $($saved.Error)" }
    }
    catch { Write-Warning "Could not save your profile: $_" }
}

Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '   Setup complete!' -ForegroundColor Green
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '  1. Restart your terminal (or: exec zsh)'
Write-Host '  2. Set your terminal font to MesloLGS NF'
$pubKey = Join-Path $HOME '.ssh/id_ed25519.pub'
if (Test-Path $pubKey) {
    Write-Host '  3. Add this SSH key to GitHub -- https://github.com/settings/ssh/new'
    Write-Host ''
    Get-Content $pubKey | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
}
Write-Host ''
Write-Host "  Log: $SetupLog" -ForegroundColor DarkGray

Remove-Item Env:SETUP_FEATURES, Env:SETUP_GIT_NAME, Env:SETUP_GIT_EMAIL -ErrorAction SilentlyContinue
try { Stop-Transcript | Out-Null } catch { }
