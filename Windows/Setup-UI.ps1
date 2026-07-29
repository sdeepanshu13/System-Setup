<#
.SYNOPSIS
    Interactive GUI for System-Setup with grouped sections and individual checkboxes.
.DESCRIPTION
    Shows a scrollable Windows Forms dialog with section headings and one checkbox
    per item. Nothing is clubbed. Returns selections via environment variables.
.OUTPUTS
    SETUP_SELECTED_PACKAGES  = comma-separated winget package IDs to install
    SETUP_FEATURES           = comma-separated feature flags (zsh,omp,winfeat,vscode,langtools,gitssh)
    SETUP_DEFAULT_SHELL      = shell choice (1-5)
    Exit code 0 = Install clicked, 1 = Cancelled.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# USER PROFILE: load this person's saved selections (encrypted, cross-platform)
# =====================================================================
# All storage/crypto/auth lives in Shared\Modules\SetupCore.psm1 so Windows and
# macOS share one implementation. Selections are encrypted with the user's
# passphrase before they ever leave the machine.

$script:SharedRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Shared'
if (-not (Test-Path $script:SharedRoot)) {
    # Packed exe layout: Shared\ sits beside the extracted scripts.
    $script:SharedRoot = Join-Path $PSScriptRoot 'Shared'
}
$coreModule = Join-Path $script:SharedRoot 'Modules\SetupCore.psm1'
$script:Profiles = $null
if (Test-Path $coreModule) {
    try {
        Import-Module $coreModule -Force -ErrorAction Stop
        $script:Profiles = New-ProfileManager -SharedRoot $script:SharedRoot
    }
    catch {
        Write-Warning "Profile sync unavailable: $_"
    }
}

$script:ProfileLoaded     = $false
$script:ProfilePassphrase = $null
$script:ProfileName       = $null
$script:SavedPackages     = $null
$script:SavedFeatures     = $null
$script:SavedShell        = $null
$script:OtpSent           = $false

function Show-ProfileLoginDialog {
    if (-not $script:Profiles) { return }
    try { $script:Profiles.Prepare() } catch { }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Sync your setup preferences'
    $dlg.Size = New-Object System.Drawing.Size(460, 470)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dlg.ForeColor = [System.Drawing.Color]::White
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'Load / save your preferences'
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 255)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.Size = New-Object System.Drawing.Size(420, 26)
    $dlg.Controls.Add($lblTitle)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Enter your email or mobile + a passphrase. We'll send a one-time code to verify it's yours. Your selections are then saved encrypted (only you can read them) and come back on any machine. Or click Skip to use defaults."
    $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
    $lblInfo.Location = New-Object System.Drawing.Point(22, 44)
    $lblInfo.Size = New-Object System.Drawing.Size(410, 50)
    $dlg.Controls.Add($lblInfo)

    function New-DlgLabel($text, $y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.ForeColor = [System.Drawing.Color]::White
        $l.Location = New-Object System.Drawing.Point(22, $y)
        $l.Size = New-Object System.Drawing.Size(410, 18)
        $dlg.Controls.Add($l)
    }
    function New-DlgBox($y, [bool]$mask) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(24, $y)
        $t.Size = New-Object System.Drawing.Size(405, 24)
        $t.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $t.ForeColor = [System.Drawing.Color]::White
        $t.BorderStyle = 'FixedSingle'
        if ($mask) { $t.UseSystemPasswordChar = $true }
        $dlg.Controls.Add($t)
        return $t
    }

    New-DlgLabel 'Email or mobile number' 96
    $tbId = New-DlgBox 116 $false
    New-DlgLabel 'Your name (for git config, optional)' 146
    $tbName = New-DlgBox 166 $false
    New-DlgLabel 'Passphrase' 196
    $tbPass = New-DlgBox 216 $true
    New-DlgLabel 'Confirm passphrase (new users only)' 246
    $tbConfirm = New-DlgBox 266 $true

    $lblOtp = New-Object System.Windows.Forms.Label
    $lblOtp.Text = 'Verification code'
    $lblOtp.ForeColor = [System.Drawing.Color]::White
    $lblOtp.Location = New-Object System.Drawing.Point(22, 296)
    $lblOtp.Size = New-Object System.Drawing.Size(410, 18)
    $lblOtp.Visible = $false
    $dlg.Controls.Add($lblOtp)

    $tbOtp = New-Object System.Windows.Forms.TextBox
    $tbOtp.Location = New-Object System.Drawing.Point(24, 316)
    $tbOtp.Size = New-Object System.Drawing.Size(405, 24)
    $tbOtp.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $tbOtp.ForeColor = [System.Drawing.Color]::White
    $tbOtp.BorderStyle = 'FixedSingle'
    $tbOtp.Visible = $false
    $dlg.Controls.Add($tbOtp)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 120, 120)
    $lblStatus.Location = New-Object System.Drawing.Point(22, 348)
    $lblStatus.Size = New-Object System.Drawing.Size(410, 18)
    $dlg.Controls.Add($lblStatus)

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text = 'Continue'
    $btnContinue.Size = New-Object System.Drawing.Size(150, 34)
    $btnContinue.Location = New-Object System.Drawing.Point(24, 372)
    $btnContinue.FlatStyle = 'Flat'
    $btnContinue.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnContinue.ForeColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($btnContinue)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = 'Skip'
    $btnSkip.Size = New-Object System.Drawing.Size(110, 34)
    $btnSkip.Location = New-Object System.Drawing.Point(319, 372)
    $btnSkip.FlatStyle = 'Flat'
    $btnSkip.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSkip.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
    $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $dlg.Controls.Add($btnSkip)
    $dlg.CancelButton = $btnSkip

    $btnContinue.Add_Click({
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 120, 120)
        $lblStatus.Text = ''
        $idText   = $tbId.Text.Trim()
        $passText = $tbPass.Text

        if ([string]::IsNullOrWhiteSpace($idText)) {
            $lblStatus.Text = 'Enter your email or mobile, or click Skip.'; return
        }
        if ([string]::IsNullOrEmpty($passText)) {
            $lblStatus.Text = 'A passphrase is required to protect your data.'; return
        }

        # --- Step 1: send the code ---
        if (-not $script:OtpSent) {
            try { $null = [void]$script:Profiles.Identity } catch { }
            $btnContinue.Enabled = $false
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
            $lblStatus.Text = 'Sending verification code...'
            $dlg.Refresh()
            try { $begin = $script:Profiles.BeginVerification($idText) }
            catch { $begin = @{ Ok = $false; Error = $_.Exception.Message } }
            $btnContinue.Enabled = $true

            if (-not $begin.Ok) {
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 120, 120)
                $hint = if ($script:Profiles.IsOnline()) { '' } else { ' Configure SMTP/SMS or click Skip.' }
                $lblStatus.Text = "Couldn't send code: $($begin.Error).$hint"
                return
            }
            $script:OtpSent = $true
            $lblOtp.Visible = $true
            $tbOtp.Visible = $true
            $tbOtp.Focus()
            $btnContinue.Text = 'Verify & continue'
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 120)
            $lblStatus.Text = if ($begin.Method -eq 'dev') {
                'Dev mode: code printed to the console. Enter it above.'
            }
            else { "We sent a code to your $($begin.Channel). Enter it above." }
            return
        }

        # --- Step 2: verify the code ---
        if (-not $script:Profiles.Verified) {
            $chk = $script:Profiles.CompleteVerification($tbOtp.Text)
            if (-not $chk.Ok) {
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 120, 120)
                $lblStatus.Text = "Code: $($chk.Reason)"
                if ($chk.Reason -match 'expired|too many') {
                    $script:Profiles.ResetChallenge()
                    $script:OtpSent = $false
                    $tbOtp.Visible = $false
                    $lblOtp.Visible = $false
                    $btnContinue.Text = 'Continue'
                }
                return
            }
        }

        # --- Step 3: load an existing profile, or start a new one ---
        $res = $script:Profiles.LoadProfile($passText)
        if (-not $res.Ok) {
            $lblStatus.Text = "Couldn't reach your profile: $($res.Error)"; return
        }
        if ($res.Found) {
            if ($res.Error -eq 'corrupt') {
                $lblStatus.Text = 'That profile is corrupt and cannot be read.'; return
            }
            if (-not $res.Decrypted) {
                $lblStatus.Text = 'Incorrect passphrase for this account.'; return
            }
            $script:ProfileLoaded = $true
            $script:SavedPackages = @($res.Data.Packages)
            $script:SavedFeatures = @($res.Data.Features)
            $script:SavedShell    = $res.Data.DefaultShell
            if (-not $tbName.Text -and $res.Data.Name) { $script:ProfileName = $res.Data.Name }
        }
        elseif ($tbPass.Text -ne $tbConfirm.Text) {
            $lblStatus.Text = "Passphrases don't match (new account)."; return
        }

        $script:ProfilePassphrase = $passText
        if ($tbName.Text) { $script:ProfileName = $tbName.Text.Trim() }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })

    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}

Show-ProfileLoginDialog

# Build fast lookup sets from the loaded profile (if any).
$savedPkgSet  = $null
$savedFeatSet = $null
if ($script:ProfileLoaded) {
    $savedPkgSet  = New-Object 'System.Collections.Generic.HashSet[string]'
    $savedFeatSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $script:SavedPackages) { if ($p) { [void]$savedPkgSet.Add([string]$p) } }
    foreach ($f in $script:SavedFeatures) { if ($f) { [void]$savedFeatSet.Add([string]$f) } }
}

# =====================================================================
# DATA: each item is a separate checkbox, grouped under section headings
# =====================================================================

$sections = @(
    @{
        Heading = 'Developer Tools & IDEs'
        Items = @(
            @{ Name='Git for Windows';              PkgId='Git.Git';                              Checked=$true }
            @{ Name='GitHub CLI';                   PkgId='GitHub.cli';                            Checked=$true }
            @{ Name='GitHub Desktop';               PkgId='GitHub.GitHubDesktop';                  Checked=$true }
            @{ Name='GitHub Copilot';               PkgId='GitHub.Copilot';                        Checked=$true }
            @{ Name='Visual Studio Code';           PkgId='Microsoft.VisualStudioCode';            Checked=$true }
            @{ Name='Visual Studio Enterprise';     PkgId='Microsoft.VisualStudio.Enterprise';     Checked=$true }
            @{ Name='JetBrains Toolbox';            PkgId='JetBrains.Toolbox';                     Checked=$true }
            @{ Name='Docker Desktop';               PkgId='Docker.DockerDesktop';                  Checked=$true }
            @{ Name='Warp Terminal';                PkgId='Warp.Warp';                             Checked=$true }
            @{ Name='VS 2022 Build Tools';          PkgId='Microsoft.VisualStudio.2022.BuildTools'; Checked=$true }
        )
    }
    @{
        Heading = 'Programming Languages'
        Items = @(
            @{ Name='Python 3.14';                  PkgId='Python.Python.3.14';                    Checked=$true }
            @{ Name='Python Launcher';              PkgId='Python.Launcher';                       Checked=$true }
            @{ Name='Node.js LTS';                  PkgId='OpenJS.NodeJS.LTS';                     Checked=$true }
            @{ Name='NVM for Windows';              PkgId='CoreyButler.NVMforWindows';             Checked=$true }
            @{ Name='.NET SDK 10';                  PkgId='Microsoft.DotNet.SDK.10';               Checked=$true }
            @{ Name='Java JDK 21 (Temurin)';        PkgId='EclipseAdoptium.Temurin.21.JDK';        Checked=$true }
            @{ Name='Java JDK 17 (Temurin)';        PkgId='EclipseAdoptium.Temurin.17.JDK';        Checked=$true }
            @{ Name='Go';                           PkgId='GoLang.Go';                             Checked=$true }
            @{ Name='Rust (rustup)';                PkgId='Rustlang.Rustup';                       Checked=$true }
            @{ Name='LLVM / Clang';                 PkgId='LLVM.LLVM';                             Checked=$true }
            @{ Name='MinGW (GCC/G++)';              PkgId='MartinStorsjo.LLVM-MinGW.UCRT';         Checked=$true }
            @{ Name='CMake';                        PkgId='Kitware.CMake';                         Checked=$true }
            @{ Name='Ninja Build';                  PkgId='Ninja-build.Ninja';                     Checked=$true }
        )
    }
    @{
        Heading = 'Web Browsers'
        Items = @(
            @{ Name='Google Chrome';                PkgId='Google.Chrome.EXE';                     Checked=$true }
            @{ Name='Mozilla Firefox';              PkgId='Mozilla.Firefox';                       Checked=$true }
        )
    }
    @{
        Heading = 'Cloud & CLI Tools'
        Items = @(
            @{ Name='Azure CLI';                    PkgId='Microsoft.AzureCLI';                    Checked=$true }
            @{ Name='PowerShell 7';                 PkgId='Microsoft.PowerShell';                  Checked=$true }
            @{ Name='Windows Terminal';             PkgId='Microsoft.WindowsTerminal';             Checked=$true }
            @{ Name='Redis';                        PkgId='Redis.Redis';                           Checked=$true }
            @{ Name='WSL';                          PkgId='Microsoft.WSL';                         Checked=$true }
            @{ Name='Ubuntu 24.04';                 PkgId='Canonical.Ubuntu.2404';                 Checked=$true }
            @{ Name='Azure VPN Client';             PkgId='Microsoft.AzureVPNClient';              Checked=$true }
        )
    }
    @{
        Heading = 'Office & Productivity'
        Items = @(
            @{ Name='Microsoft Teams';              PkgId='Microsoft.Teams';                       Checked=$true }
            @{ Name='Microsoft Office';             PkgId='Microsoft.Office';                      Checked=$true }
            @{ Name='OneDrive';                     PkgId='Microsoft.OneDrive';                    Checked=$true }
            @{ Name='Google Drive';                 PkgId='Google.GoogleDrive';                    Checked=$true }
            @{ Name='Adobe Acrobat Reader';         PkgId='Adobe.Acrobat.Reader.64-bit';           Checked=$true }
        )
    }
    @{
        Heading = 'Media & Utilities'
        Items = @(
            @{ Name='VLC Media Player';             PkgId='VideoLAN.VLC';                          Checked=$true }
            @{ Name='Unity Hub';                    PkgId='Unity.UnityHub';                        Checked=$true }
            @{ Name='Samsung SmartSwitch';          PkgId='Samsung.SmartSwitch';                   Checked=$true }
            @{ Name='YubiKey Manager';              PkgId='Yubico.YubikeyManager';                Checked=$true }
            @{ Name='YubiKey SmartCard Driver';     PkgId='Yubico.YubiKeySmartCardMinidriver';     Checked=$true }
            @{ Name='Microsoft Remote Help';        PkgId='Microsoft.RemoteHelp';                  Checked=$true }
        )
    }
    @{
        Heading = 'Runtimes & Libraries'
        Items = @(
            @{ Name='.NET Desktop Runtime 8';       PkgId='Microsoft.DotNet.DesktopRuntime.8';     Checked=$true }
            @{ Name='.NET AspNetCore 8';            PkgId='Microsoft.DotNet.AspNetCore.8';         Checked=$true }
            @{ Name='.NET Framework DevPack 4';     PkgId='Microsoft.DotNet.Framework.DeveloperPack_4'; Checked=$true }
            @{ Name='VCRedist 2015+ (x64)';        PkgId='Microsoft.VCRedist.2015+.x64';          Checked=$true }
            @{ Name='VCRedist 2015+ (x86)';        PkgId='Microsoft.VCRedist.2015+.x86';          Checked=$true }
            @{ Name='Microsoft WebDeploy';          PkgId='Microsoft.WebDeploy';                   Checked=$true }
            @{ Name='ODBC Driver 17';               PkgId='Microsoft.msodbcsql.17';                Checked=$true }
            @{ Name='SQL CLR Types 2019';           PkgId='Microsoft.CLRTypesSQLServer.2019';      Checked=$true }
        )
    }
    @{
        Heading = 'Shell & Prompt'
        Items = @(
            @{ Name='Oh My Posh';                   PkgId='JanDeDobbeleer.OhMyPosh';               Checked=$true }
            @{ Name='Clink (CMD prompt)';           PkgId='chrisant996.Clink';                     Checked=$true }
        )
    }
)

# Feature toggles (non-winget items)
$featureToggles = @(
    @{ Heading = 'Shell Setup' ; Items = @(
        @{ Name='Git Bash + Zsh + Oh My Zsh + Powerlevel10k';  Flag='zsh';       Checked=$true }
        @{ Name='Oh My Posh for PowerShell (profile + modules)'; Flag='omp';     Checked=$true }
        @{ Name='Oh My Posh for CMD (Clink)';                  Flag='ompcmd';    Checked=$true }
        @{ Name='MesloLGS Nerd Font';                          Flag='nerdfont';  Checked=$true }
    )}
    @{ Heading = 'Windows Features' ; Items = @(
        @{ Name='WSL2 + Virtual Machine Platform';             Flag='wsl';       Checked=$true }
        @{ Name='Hyper-V';                                     Flag='hyperv';    Checked=$true }
        @{ Name='Windows Containers';                          Flag='containers'; Checked=$true }
        @{ Name='Windows Sandbox';                             Flag='sandbox';   Checked=$true }
        @{ Name='.NET Framework 3.5';                          Flag='netfx3';    Checked=$true }
        @{ Name='Hypervisor Platform';                         Flag='hypplat';   Checked=$true }
    )}
    @{ Heading = 'Dev Environment' ; Items = @(
        @{ Name='Git Config + SSH Key';                        Flag='gitssh';    Checked=$true }
        @{ Name='VS Code Extensions';                          Flag='vscode';    Checked=$true }
        @{ Name='npm globals (React, TS, ESLint, Prettier)';   Flag='npm';       Checked=$true }
        @{ Name='Python pipx tools (uv, ruff, poetry, black)'; Flag='pipx';     Checked=$true }
        @{ Name='Rust toolchain (stable + clippy + analyzer)'; Flag='rust';      Checked=$true }
        @{ Name='Go workspace setup';                          Flag='golang';    Checked=$true }
        @{ Name='Maven (download from Apache)';                Flag='maven';     Checked=$true }
        @{ Name='Gradle (download from Gradle.org)';           Flag='gradle';    Checked=$true }
    )}
)

# =====================================================================
# BUILD THE FORM
# =====================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Windows Dev Machine Setup'
$form.Size = New-Object System.Drawing.Size(820, 850)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

# --- Title bar ---
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Windows Dev Machine Setup'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 255)
$titleLabel.Location = New-Object System.Drawing.Point(20, 10)
$titleLabel.Size = New-Object System.Drawing.Size(500, 32)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Tick the items you want. Every item is independent.'
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
$subtitleLabel.Location = New-Object System.Drawing.Point(22, 42)
$subtitleLabel.Size = New-Object System.Drawing.Size(500, 18)
$form.Controls.Add($subtitleLabel)

# --- Scrollable main panel ---
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Location = New-Object System.Drawing.Point(10, 65)
$mainPanel.Size = New-Object System.Drawing.Size(785, 640)
$mainPanel.AutoScroll = $true
$mainPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.Controls.Add($mainPanel)

$allPkgCheckBoxes = @()     # checkboxes with .Tag = winget package ID
$allFeatCheckBoxes = @()    # checkboxes with .Tag = feature flag

$y = 5

# Colors
$headingColor   = [System.Drawing.Color]::FromArgb(0, 180, 255)
$subheadColor   = [System.Drawing.Color]::FromArgb(100, 200, 255)
$checkColor     = [System.Drawing.Color]::White
$headingFont    = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$subheadFont    = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$checkFont      = New-Object System.Drawing.Font('Segoe UI', 9.5)
$colWidth       = 370

# Helper: add a heading label
function Add-Heading($text, $font, $color) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Font = $font
    $lbl.ForeColor = $color
    $lbl.Location = New-Object System.Drawing.Point(5, $script:y)
    $lbl.Size = New-Object System.Drawing.Size(760, 22)
    $mainPanel.Controls.Add($lbl)
    $script:y += 26
}

# Helper: add a separator line
function Add-Separator {
    $sep = New-Object System.Windows.Forms.Label
    $sep.Text = ''
    $sep.BorderStyle = 'Fixed3D'
    $sep.Location = New-Object System.Drawing.Point(5, $script:y)
    $sep.Size = New-Object System.Drawing.Size(755, 2)
    $mainPanel.Controls.Add($sep)
    $script:y += 8
}

# --- SOFTWARE PACKAGES (heading + per-package checkboxes) ---
Add-Heading 'SOFTWARE PACKAGES' $headingFont $headingColor
Add-Separator

foreach ($section in $sections) {
    Add-Heading $section.Heading $subheadFont $subheadColor

    $col = 0
    foreach ($item in $section.Items) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $item.Name
        $cb.Tag  = $item.PkgId
        if ($savedPkgSet) { $cb.Checked = $savedPkgSet.Contains([string]$item.PkgId) }
        else { $cb.Checked = $item.Checked }
        $cb.Font = $checkFont
        $cb.ForeColor = $checkColor
        $xOff = $(if ($col % 2 -eq 0) { 20 } else { $colWidth + 20 })
        $cb.Location = New-Object System.Drawing.Point($xOff, $y)
        $cb.Size = New-Object System.Drawing.Size(($colWidth - 10), 22)
        $mainPanel.Controls.Add($cb)
        $allPkgCheckBoxes += $cb

        if ($col % 2 -eq 1) { $y += 24 }
        $col++
    }
    if ($col % 2 -eq 1) { $y += 24 }  # close last row if odd count
    $y += 6
}

# --- FEATURES (heading + sub-heading + per-feature checkboxes) ---
Add-Separator
Add-Heading 'SETUP & CONFIGURATION' $headingFont $headingColor
Add-Separator

foreach ($fSection in $featureToggles) {
    Add-Heading $fSection.Heading $subheadFont $subheadColor

    $col = 0
    foreach ($item in $fSection.Items) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $item.Name
        $cb.Tag  = $item.Flag
        if ($savedFeatSet) { $cb.Checked = $savedFeatSet.Contains([string]$item.Flag) }
        else { $cb.Checked = $item.Checked }
        $cb.Font = $checkFont
        $cb.ForeColor = $checkColor
        $xOff = $(if ($col % 2 -eq 0) { 20 } else { $colWidth + 20 })
        $cb.Location = New-Object System.Drawing.Point($xOff, $y)
        $cb.Size = New-Object System.Drawing.Size(($colWidth - 10), 22)
        $mainPanel.Controls.Add($cb)
        $allFeatCheckBoxes += $cb

        if ($col % 2 -eq 1) { $y += 24 }
        $col++
    }
    if ($col % 2 -eq 1) { $y += 24 }
    $y += 6
}

# --- DEFAULT TERMINAL ---
Add-Separator
Add-Heading 'DEFAULT TERMINAL' $headingFont $headingColor

$shellOptions = @(
    @{ Id='1'; Name='Git Bash + Zsh (recommended)' }
    @{ Id='2'; Name='PowerShell 7' }
    @{ Id='3'; Name='PowerShell 5 (legacy)' }
    @{ Id='4'; Name='Command Prompt (CMD)' }
    @{ Id='5'; Name='Keep current (don''t change)' }
)

$defaultShellId = if ($script:ProfileLoaded -and $script:SavedShell) { $script:SavedShell } else { '1' }
$radioButtons = @()
$col = 0
foreach ($opt in $shellOptions) {
    $rb = New-Object System.Windows.Forms.RadioButton
    $rb.Text = $opt.Name
    $rb.Tag  = $opt.Id
    $rb.Font = $checkFont
    $rb.ForeColor = $checkColor
    $rb.Checked = ($opt.Id -eq $defaultShellId)
    $xOff = $(if ($col % 2 -eq 0) { 20 } else { $colWidth + 20 })
    $rb.Location = New-Object System.Drawing.Point($xOff, $y)
    $rb.Size = New-Object System.Drawing.Size(($colWidth - 10), 22)
    $mainPanel.Controls.Add($rb)
    $radioButtons += $rb

    if ($col % 2 -eq 1) { $y += 24 }
    $col++
}
if ($col % 2 -eq 1) { $y += 24 }
$y += 10

# --- Bottom buttons ---
$btnY = 720

$selectAllBtn = New-Object System.Windows.Forms.Button
$selectAllBtn.Text = 'Select All'
$selectAllBtn.Location = New-Object System.Drawing.Point(15, $btnY)
$selectAllBtn.Size = New-Object System.Drawing.Size(90, 32)
$selectAllBtn.FlatStyle = 'Flat'
$selectAllBtn.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 255)
$selectAllBtn.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$selectAllBtn.Add_Click({
    $allPkgCheckBoxes  | ForEach-Object { $_.Checked = $true }
    $allFeatCheckBoxes | ForEach-Object { $_.Checked = $true }
})
$form.Controls.Add($selectAllBtn)

$selectNoneBtn = New-Object System.Windows.Forms.Button
$selectNoneBtn.Text = 'Deselect All'
$selectNoneBtn.Location = New-Object System.Drawing.Point(110, $btnY)
$selectNoneBtn.Size = New-Object System.Drawing.Size(90, 32)
$selectNoneBtn.FlatStyle = 'Flat'
$selectNoneBtn.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$selectNoneBtn.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$selectNoneBtn.Add_Click({
    $allPkgCheckBoxes  | ForEach-Object { $_.Checked = $false }
    $allFeatCheckBoxes | ForEach-Object { $_.Checked = $false }
})
$form.Controls.Add($selectNoneBtn)

$installBtn = New-Object System.Windows.Forms.Button
$installBtn.Text = 'Install'
$installBtn.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$installBtn.Size = New-Object System.Drawing.Size(140, 40)
$installBtn.Location = New-Object System.Drawing.Point(510, ($btnY - 4))
$installBtn.FlatStyle = 'Flat'
$installBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$installBtn.ForeColor = [System.Drawing.Color]::White
$installBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($installBtn)
$form.AcceptButton = $installBtn

$cancelBtn = New-Object System.Windows.Forms.Button
$cancelBtn.Text = 'Cancel'
$cancelBtn.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$cancelBtn.Size = New-Object System.Drawing.Size(110, 40)
$cancelBtn.Location = New-Object System.Drawing.Point(660, ($btnY - 4))
$cancelBtn.FlatStyle = 'Flat'
$cancelBtn.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$cancelBtn.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancelBtn)
$form.CancelButton = $cancelBtn

# =====================================================================
# SHOW & COLLECT RESULTS
# =====================================================================
$result = $form.ShowDialog()

if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    # Selected winget packages
    $selectedPkgs = ($allPkgCheckBoxes | Where-Object { $_.Checked } |
        ForEach-Object { $_.Tag }) -join ','
    $env:SETUP_SELECTED_PACKAGES = $selectedPkgs

    # Selected feature flags
    $selectedFeats = ($allFeatCheckBoxes | Where-Object { $_.Checked } |
        ForEach-Object { $_.Tag }) -join ','
    $env:SETUP_FEATURES = $selectedFeats

    # Default shell
    $shellChoice = '1'
    foreach ($rb in $radioButtons) {
        if ($rb.Checked) { $shellChoice = $rb.Tag; break }
    }
    $env:SETUP_DEFAULT_SHELL = $shellChoice

    # Also set SETUP_CATEGORIES for backward compat with bootstrap-dev.sh
    # Map features to old category IDs
    $catIds = @()
    if ($selectedPkgs) { $catIds += @(1,2,3,4,5,6,7) }  # at least some packages
    if ($selectedFeats -match 'zsh')      { $catIds += 8 }
    if ($selectedFeats -match 'omp')      { $catIds += 9 }
    if ($selectedFeats -match 'wsl|hyperv|containers|sandbox|netfx3|hypplat') { $catIds += 10 }
    if ($selectedFeats -match 'vscode')   { $catIds += 11 }
    if ($selectedFeats -match 'npm|pipx|rust|golang|maven|gradle') { $catIds += 12 }
    if ($selectedFeats -match 'gitssh')   { $catIds += 13 }
    $env:SETUP_CATEGORIES = ($catIds | Sort-Object -Unique) -join ','

    # --- Save this user's selections (encrypted before it leaves the machine) ---
    if ($script:Profiles -and $script:Profiles.Verified -and $script:ProfilePassphrase) {
        try {
            $data = New-ProfileData -Name $script:ProfileName `
                -Packages @($allPkgCheckBoxes  | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag }) `
                -Features @($allFeatCheckBoxes | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag }) `
                -DefaultShell $shellChoice
            $saved = $script:Profiles.SaveProfile($script:ProfilePassphrase, $data)
            if ($saved.Ok) {
                Write-Host 'Preferences saved (encrypted).' -ForegroundColor DarkGray
                if (-not $script:Profiles.IsOnline()) { $env:SETUP_PUBLISH_PROFILE = '1' }
            }
            else {
                Write-Warning "Could not save preferences: $($saved.Error)"
            }
        }
        catch { Write-Warning "Could not save your profile: $_" }

        if ($script:ProfileName) { $env:SETUP_USER_NAME = $script:ProfileName }
        if ($script:Profiles.Identity -and $script:Profiles.Identity.IsEmail()) {
            $env:SETUP_USER_EMAIL = $script:Profiles.Identity.Value
        }
    }

    Write-Host "Packages:  $selectedPkgs"
    Write-Host "Features:  $selectedFeats"
    Write-Host "Shell:     $shellChoice"
    exit 0
}
else {
    exit 1
}
