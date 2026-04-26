#!/bin/bash
# ==============================================
# Dev Machine Bootstrap (Git Bash)
# ==============================================
# Usage: Open Git Bash as Administrator, then run:
#   ./bootstrap-dev.sh
#
# Two-phase setup:
#   Phase 1: restore.ps1 — installs all software via winget
#   Phase 2: this script — zsh, p10k, fonts, dotfiles
# ==============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC_SRC="$SCRIPT_DIR/zshrc-template"
P10K_SRC="$SCRIPT_DIR/p10k-template"
ZSH_BUNDLE="$SCRIPT_DIR/zsh-gitbash.tar.gz"

# Helper: clone a git repo only if the target dir doesn't exist
clone_if_missing() {
    local repo="$1" dest="$2" label="$3"
    if [[ -d "$dest" ]]; then
        echo "✅ $label already installed, skipping."
    else
        echo "📦 Installing $label..."
        git clone --depth=1 "$repo" "$dest"
        echo "✅ $label installed."
    fi
}

# Detect runtime environment
detect_environment() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || -n "${MSYSTEM:-}" ]]; then
        echo "gitbash"
    elif [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

# Locate Git for Windows install root (where bash.exe lives in /usr/bin)
find_git_root() {
    for c in "/c/Program Files/Git" "/c/Program Files (x86)/Git"; do
        if [[ -x "$c/usr/bin/bash.exe" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Install zsh into Git Bash by extracting the bundled tarball.
install_zsh_gitbash() {
    if command -v zsh &>/dev/null; then
        echo "✅ zsh already installed: $(zsh --version | head -1)"
        return 0
    fi

    if [[ ! -f "$ZSH_BUNDLE" ]]; then
        echo "❌ zsh-gitbash.tar.gz not found at $ZSH_BUNDLE"
        return 1
    fi

    local GIT_ROOT
    GIT_ROOT="$(find_git_root)" || {
        echo "❌ Git for Windows not found. Install Git first (winget install Git.Git)."
        return 1
    }

    echo "📦 Installing zsh into $GIT_ROOT (extracting $ZSH_BUNDLE)..."
    # Try writing directly; if denied, retry elevated via PowerShell.
    if ! tar -xzf "$ZSH_BUNDLE" -C "$GIT_ROOT" 2>/dev/null; then
        echo "  Permission denied — re-extracting elevated..."
        local WIN_BUNDLE WIN_GIT
        WIN_BUNDLE="$(cygpath -w "$ZSH_BUNDLE")"
        WIN_GIT="$(cygpath -w "$GIT_ROOT")"
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
            Start-Process -FilePath 'tar.exe' -Verb RunAs -Wait -ArgumentList @(
                '-xzf', '$WIN_BUNDLE', '-C', '$WIN_GIT'
            )
        " 2>/dev/null || {
            echo "❌ Failed to extract zsh bundle. Run Git Bash as Administrator."
            return 1
        }
    fi

    # Refresh PATH so the just-installed zsh is visible in this session
    hash -r 2>/dev/null || true
    if command -v zsh &>/dev/null; then
        echo "✅ zsh installed: $(zsh --version | head -1)"
        return 0
    fi
    echo "❌ zsh installation failed (binary not found after extract)."
    return 1
}

echo "============================================="
echo "Dev Machine Bootstrap Starting"
echo "============================================="

ENV_TYPE=$(detect_environment)
echo "🔍 Detected environment: $ENV_TYPE"

# --- Category selection (passed from Setup.ps1 menu) ---
# SETUP_CATEGORIES is a comma-separated list of selected category IDs.
# If empty/unset, all categories are enabled (standalone run).
SELECTED="${SETUP_CATEGORIES:-1,2,3,4,5,6,7,8,9,10,11,12,13}"
category_enabled() {
    echo ",$SELECTED," | grep -q ",$1,"
}

# Granular feature flags (from the GUI). Comma-separated list of flags.
# If empty/unset, all features are enabled (standalone or -Unattended run).
FEATURES="${SETUP_FEATURES:-zsh,omp,ompcmd,nerdfont,wsl,hyperv,containers,sandbox,netfx3,hypplat,gitssh,vscode,npm,pipx,rust,golang,maven,gradle}"
feature_enabled() {
    echo ",$FEATURES," | grep -q ",$1,"
}

# ---------------------------
# 0) Install winget packages (Phase 1)
# ---------------------------
RESTORE_PS1="$SCRIPT_DIR/restore.ps1"
if [[ "${SETUP_SKIP_PHASE1:-0}" == "1" ]]; then
    echo "⏭️  Phase 1 already done by Setup.ps1 — skipping winget install."
elif [[ -f "$RESTORE_PS1" ]]; then
    echo ""
    echo "📦 Phase 1: Installing software via winget (parallel, unattended)..."
    WIN_RESTORE="$(cygpath -w "$RESTORE_PS1")"
    # Run elevated PowerShell so per-package UAC prompts are suppressed.
    # Override parallelism with: WINGET_THROTTLE=8 ./bootstrap-dev.sh
    THROTTLE="${WINGET_THROTTLE:-5}"
    if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_RESTORE" -Throttle "$THROTTLE"; then
        echo ""
        echo "✅ Phase 1 complete."
    else
        echo ""
        echo "⚠️  Phase 1 reported failures (some packages may not have installed)."
        echo "    Check logs/<latest>/restore.log and packages/*.log for details."
        echo "    Continuing with Phase 2 -- it can recover from missing packages,"
        echo "    but you may want to re-run Setup.ps1 afterwards."
    fi
    echo ""
else
    echo "⚠️  restore.ps1 not found — skipping winget package install."
fi

if category_enabled 13; then
echo "🔧 Phase 2: Git & SSH setup"
echo ""

# ---------------------------
# 1) Git identity & defaults (prompt early so rest runs unattended)
# ---------------------------
echo "⚙️  Git Configuration"
echo ""

# Allow non-interactive use: SETUP_GIT_NAME / SETUP_GIT_EMAIL env vars
# (set by Setup.ps1 -GitName / -GitEmail) bypass the prompts.
GIT_NAME="${SETUP_GIT_NAME:-}"
GIT_EMAIL="${SETUP_GIT_EMAIL:-}"

if [[ -z "$GIT_NAME" ]]; then
    if [[ -t 0 ]]; then
        read -rp "Enter your full name (for git config): " GIT_NAME
    else
        echo "⚠️  No SETUP_GIT_NAME set and no TTY — skipping git user.name."
    fi
fi
if [[ -z "$GIT_EMAIL" ]]; then
    if [[ -t 0 ]]; then
        read -rp "Enter your GitHub email: " GIT_EMAIL
    else
        echo "⚠️  No SETUP_GIT_EMAIL set and no TTY — skipping git user.email."
    fi
fi

if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    echo "✅ Git identity set: $GIT_NAME <$GIT_EMAIL>"
fi

git config --global init.defaultBranch main
git config --global core.autocrlf true
git config --global pull.rebase true
git config --global fetch.prune true
git config --global diff.colorMoved zebra
git config --global rebase.autoStash true
echo "✅ Git defaults set."
echo ""

# ---------------------------
# 2) Generate SSH key for GitHub
# ---------------------------
echo "🔑 SSH Key Setup for GitHub"

if [[ -z "${GIT_EMAIL:-}" ]]; then
    echo "⚠️  No email provided — skipping SSH key generation."
else
    SSH_KEY="$HOME/.ssh/id_ed25519"
    if [[ -f "$SSH_KEY" ]]; then
        echo "✅ SSH key already exists at $SSH_KEY — skipping generation."
    else
        echo "🔐 Generating ed25519 SSH key..."
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY" -N ""
        echo "✅ SSH key generated."
    fi

    # Start ssh-agent and add the key
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    ssh-add "$SSH_KEY" 2>/dev/null || true

    # Use Windows OpenSSH to avoid MSYS2 vs Windows agent conflict
    if [[ "$ENV_TYPE" == "gitbash" && -f "/c/Windows/System32/OpenSSH/ssh.exe" ]]; then
        git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
    fi

    # Start Windows ssh-agent service (Git Bash / Windows only)
    if [[ "$ENV_TYPE" == "gitbash" ]]; then
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
            \$svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
            if (\$svc) {
                if (\$svc.StartType -eq 'Disabled') { Set-Service -Name ssh-agent -StartupType Manual }
                if (\$svc.Status -ne 'Running') { Start-Service ssh-agent }
            }
        " 2>/dev/null || true
    fi

    # Save public key for easy copying
    PUB_KEY_FILE="$SCRIPT_DIR/github-ssh-pubkey.txt"
    cp "$SSH_KEY.pub" "$PUB_KEY_FILE"

    echo ""
    echo "============================================="
    echo "🔑 Your GitHub SSH Public Key"
    echo "============================================="
    cat "$SSH_KEY.pub"
    echo ""
    echo "============================================="
    echo "📋 Saved to: $PUB_KEY_FILE"
    echo "👉 Add to GitHub: https://github.com/settings/ssh/new"
    echo ""
fi

echo "✅ Phase 2 complete (Git & SSH)."
fi  # end category 13 (Git & SSH)

echo ""

if category_enabled 8; then
echo "🔧 Phase 3: Shell & dotfiles setup"
echo ""

# ---------------------------
# 3) Install zsh into Git Bash (from bundled tarball)
# ---------------------------
ZSH_AVAILABLE=true
ZSH_HOME="$HOME"   # Git Bash's home == %USERPROFILE%

if [[ "$ENV_TYPE" == "gitbash" ]]; then
    install_zsh_gitbash || ZSH_AVAILABLE=false
elif command -v zsh &>/dev/null; then
    : # zsh already on PATH (Linux/macOS/WSL)
else
    echo "⚠️  zsh not found and not in Git Bash — skipping zsh-related setup."
    ZSH_AVAILABLE=false
fi

if $ZSH_AVAILABLE; then
    ZSH_CUSTOM_DIR="$ZSH_HOME/.oh-my-zsh/custom"

# ---------------------------
# 4) Install Oh My Zsh
# ---------------------------
if [[ -d "$ZSH_HOME/.oh-my-zsh" ]]; then
    echo "✅ Oh My Zsh already installed at $ZSH_HOME/.oh-my-zsh"
else
    echo "📦 Installing Oh My Zsh into $ZSH_HOME..."
    RUNZSH=no KEEP_ZSHRC=yes ZSH="$ZSH_HOME/.oh-my-zsh" \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo "✅ Oh My Zsh installed."
fi

# ---------------------------
# 5) Install Powerlevel10k + plugins (all shallow clones)
# ---------------------------
clone_if_missing "https://github.com/romkatv/powerlevel10k.git" \
    "$ZSH_CUSTOM_DIR/themes/powerlevel10k" "Powerlevel10k"

clone_if_missing "https://github.com/zsh-users/zsh-autosuggestions.git" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions" "zsh-autosuggestions"

clone_if_missing "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting" "zsh-syntax-highlighting"

# Pre-download gitstatusd for MSYS2 so p10k doesn't fail on first launch
# with "[ERROR]: gitstatus failed to initialize".
P10K_DIR="$ZSH_CUSTOM_DIR/themes/powerlevel10k"
GITSTATUS_DIR="$P10K_DIR/gitstatus"
if [[ -d "$GITSTATUS_DIR" && "$ENV_TYPE" == "gitbash" ]]; then
    GITSTATUS_BIN="$GITSTATUS_DIR/usrbin/gitstatusd"
    if [[ ! -x "$GITSTATUS_BIN" ]]; then
        echo "📦 Pre-downloading gitstatusd for MSYS2..."
        # gitstatus ships a build script that downloads the correct binary.
        (cd "$GITSTATUS_DIR" && bash -c './install' 2>/dev/null) || {
            # Fallback: manually download the i686/x86_64 cygwin build.
            ARCH="$(uname -m)"
            TAG="$(cat "$GITSTATUS_DIR/build.info" 2>/dev/null | grep -oP 'version=\K.*' || echo 'v1.5.5')"
            URL="https://github.com/romkatv/gitstatus/releases/download/$TAG/gitstatusd-cygwin_nt-10.0-$ARCH.tar.gz"
            echo "  Trying: $URL"
            if curl -fsSL "$URL" -o /tmp/gitstatusd.tar.gz 2>/dev/null; then
                tar -xzf /tmp/gitstatusd.tar.gz -C "$GITSTATUS_DIR/usrbin/" 2>/dev/null || true
                rm -f /tmp/gitstatusd.tar.gz
            fi
        }
        if [[ -x "$GITSTATUS_BIN" ]] || ls "$GITSTATUS_DIR/usrbin/"gitstatusd* &>/dev/null; then
            echo "  ✅ gitstatusd ready."
        else
            echo "  ⚠️  gitstatusd download failed. Run 'exec zsh' after reboot to retry."
        fi
    else
        echo "  ✅ gitstatusd already present."
    fi
fi

fi  # end ZSH_AVAILABLE (sections 4-5)

# ---------------------------
# 6) Install MesloLGS Nerd Font
# ---------------------------
echo "🔤 Installing MesloLGS Nerd Font..."

FONT_DIR="$HOME/meslo-font"
mkdir -p "$FONT_DIR"

FONT_BASE="https://github.com/romkatv/powerlevel10k-media/raw/master"
FONT_FILES=(
    "MesloLGS%20NF%20Regular.ttf"
    "MesloLGS%20NF%20Bold.ttf"
    "MesloLGS%20NF%20Italic.ttf"
    "MesloLGS%20NF%20Bold%20Italic.ttf"
)

for f in "${FONT_FILES[@]}"; do
    DECODED=$(printf '%b' "${f//%/\\x}")
    if [[ -f "$FONT_DIR/$DECODED" ]]; then
        echo "  ✅ $DECODED already downloaded."
    else
        echo "  ⬇️  Downloading $DECODED ..."
        if ! curl -fsSL -o "$FONT_DIR/$DECODED" "$FONT_BASE/$f"; then
            echo "  ❌ Failed to download $DECODED"
        fi
    fi
done

# Install fonts via PowerShell using proper Windows paths
WIN_FONT_DIR="$(cygpath -w "$FONT_DIR")"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$fonts = '$WIN_FONT_DIR'
    \$shell = New-Object -ComObject Shell.Application
    \$fontsFolder = \$shell.Namespace(0x14)
    Get-ChildItem \$fonts -Filter *.ttf | ForEach-Object {
        if (-not (Test-Path \"\$env:WINDIR\\Fonts\\\$(\$_.Name)\")) {
            Write-Host \"  Installing \$(\$_.Name)...\"
            \$fontsFolder.CopyHere(\$_.FullName, 0x10)
        } else {
            Write-Host \"  \$(\$_.Name) already installed.\"
        }
    }
" 2>/dev/null || echo "  ⚠️  Font install requires Administrator — install manually if needed."
echo "✅ MesloLGS Nerd Font done."

if $ZSH_AVAILABLE; then

# ---------------------------
# 7) Deploy .zshrc and .p10k.zsh
# ---------------------------
echo "📝 Deploying zsh dotfiles into $ZSH_HOME..."

deploy_dotfile() {
    local src="$1" name="$2"
    if [[ ! -f "$src" ]]; then
        echo "  ⚠️  $name template not found at $src — skipping."
        return
    fi
    if [[ -f "$ZSH_HOME/$name" ]] && ! cmp -s "$src" "$ZSH_HOME/$name"; then
        cp "$ZSH_HOME/$name" "$ZSH_HOME/$name.backup.$(date +%Y%m%d%H%M%S)"
        echo "  Backed up existing $name"
    fi
    cp "$src" "$ZSH_HOME/$name"
    echo "  ✅ $name deployed."
}

deploy_dotfile "$ZSHRC_SRC" ".zshrc"
deploy_dotfile "$P10K_SRC"  ".p10k.zsh"

# ---------------------------
# 8) Add Git Bash profile to Windows Terminal & set default per user choice
# ---------------------------
# SETUP_DEFAULT_SHELL: 1=Git Bash+Zsh, 2=PowerShell 7, 3=PowerShell 5, 4=CMD, 5=Keep current
SHELL_CHOICE="${SETUP_DEFAULT_SHELL:-1}"
WT_SETTINGS_PATH="$HOME/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
GIT_ROOT_POSIX="$(find_git_root 2>/dev/null || true)"

if [[ -f "$WT_SETTINGS_PATH" ]]; then
    GIT_ROOT_WIN=""
    [[ -n "$GIT_ROOT_POSIX" ]] && GIT_ROOT_WIN="$(cygpath -w "$GIT_ROOT_POSIX")"
    WIN_WT_PATH="$(cygpath -w "$WT_SETTINGS_PATH")"
    echo "🖥️  Configuring Windows Terminal (profiles + font + default=$SHELL_CHOICE)..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
        \$path = '$WIN_WT_PATH'
        \$gitDir = '$GIT_ROOT_WIN'
        \$shellChoice = '$SHELL_CHOICE'

        # One-time backup
        \$backup = \$path + '.systemsetup.backup'
        if (-not (Test-Path \$backup)) {
            Copy-Item \$path \$backup -ErrorAction SilentlyContinue
        }

        \$s = Get-Content \$path -Raw | ConvertFrom-Json
        if (-not \$s.profiles) { \$s | Add-Member -NotePropertyName profiles -NotePropertyValue ([PSCustomObject]@{ defaults = [PSCustomObject]@{}; list = @() }) -Force }
        if (-not \$s.profiles.list) { \$s.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force }
        if (-not \$s.profiles.defaults) { \$s.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{}) -Force }

        # Apply MesloLGS NF font to all profiles via defaults
        \$s.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([PSCustomObject]@{ face = 'MesloLGS NF'; size = 11 }) -Force

        # --- Ensure Git Bash profile exists (even if not the default) ---
        \$gitBashGuid = '{00000000-0000-0000-ba54-000000000001}'
        if (\$gitDir) {
            \$bashExe = Join-Path \$gitDir 'bin\\bash.exe'
            \$icon    = Join-Path \$gitDir 'mingw64\\share\\git\\git-for-windows.ico'
            \$cmdLine = '\"' + \$bashExe + '\" --login -i'

            \$existing = \$s.profiles.list | Where-Object { \$_.name -eq 'Git Bash' -or \$_.guid -eq \$gitBashGuid }
            if (\$existing) {
                \$existing | Add-Member -NotePropertyName guid              -NotePropertyValue \$gitBashGuid -Force
                \$existing | Add-Member -NotePropertyName name              -NotePropertyValue 'Git Bash'   -Force
                \$existing | Add-Member -NotePropertyName commandline       -NotePropertyValue \$cmdLine    -Force
                \$existing | Add-Member -NotePropertyName icon              -NotePropertyValue \$icon       -Force
                \$existing | Add-Member -NotePropertyName startingDirectory -NotePropertyValue '%USERPROFILE%' -Force
                \$existing | Add-Member -NotePropertyName elevate           -NotePropertyValue \$true       -Force
            } else {
                \$gb = [PSCustomObject]@{
                    guid              = \$gitBashGuid
                    name              = 'Git Bash'
                    commandline       = \$cmdLine
                    icon              = \$icon
                    startingDirectory = '%USERPROFILE%'
                    elevate           = \$true
                }
                \$s.profiles.list = @(\$s.profiles.list) + \$gb
            }
            Write-Host '  Git Bash profile ready (elevate=true).'
        }

        # --- Set defaultProfile based on user's choice ---
        # Well-known GUIDs used by Windows Terminal:
        #   PS7:  {574e775e-4f2a-5b96-ac1e-a2962a402336}
        #   PS5:  {61c54bbd-c2c6-5271-96e7-009a87ff44bf}
        #   CMD:  {0caa0dad-35be-5f56-a8ff-afceeeaa6101}
        switch (\$shellChoice) {
            '1' {
                \$s | Add-Member -NotePropertyName defaultProfile -NotePropertyValue \$gitBashGuid -Force
                Write-Host '  Default profile: Git Bash + Zsh'
            }
            '2' {
                \$ps7Guid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
                # Also check if a PS7 profile exists with a different GUID
                \$ps7 = \$s.profiles.list | Where-Object { \$_.name -like '*PowerShell*' -and \$_.source -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
                if (\$ps7) { \$ps7Guid = \$ps7.guid }
                \$s | Add-Member -NotePropertyName defaultProfile -NotePropertyValue \$ps7Guid -Force
                Write-Host '  Default profile: PowerShell 7'
            }
            '3' {
                \$s | Add-Member -NotePropertyName defaultProfile -NotePropertyValue '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}' -Force
                Write-Host '  Default profile: Windows PowerShell 5.1'
            }
            '4' {
                \$s | Add-Member -NotePropertyName defaultProfile -NotePropertyValue '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}' -Force
                Write-Host '  Default profile: Command Prompt'
            }
            '5' {
                Write-Host '  Default profile: unchanged (keeping current)'
            }
        }

        \$s | ConvertTo-Json -Depth 32 | Set-Content \$path -Encoding UTF8
    " 2>&1 || echo "  ⚠️  Could not update Windows Terminal settings automatically."
else
    echo "ℹ️  Windows Terminal not installed -- skipping profile setup."
fi

# ---------------------------
# 8b) Make zsh auto-launch from Git Bash
# ---------------------------
if [[ "$ENV_TYPE" == "gitbash" ]]; then
    echo "🔧 Configuring Git Bash to auto-launch zsh..."
    BASHRC="$HOME/.bashrc"
    MARKER='# >>> System-Setup: launch zsh >>>'
    if [[ -f "$BASHRC" ]] && grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
        echo "✅ .bashrc already launches zsh."
    else
        if [[ -f "$BASHRC" ]]; then
            cp "$BASHRC" "$BASHRC.backup.$(date +%Y%m%d%H%M%S)"
            echo "  Backed up existing .bashrc"
        fi
        cat >> "$BASHRC" << 'BASH_EOF'

# >>> System-Setup: launch zsh >>>
# Force UTF-8 codepage so zsh / p10k glyphs render correctly
/c/Windows/System32/chcp.com 65001 > /dev/null 2>&1
# Auto-launch zsh in interactive sessions
if [ -t 1 ] && [ -z "$ZSH_VERSION" ] && command -v zsh >/dev/null 2>&1; then
    exec zsh
fi
# <<< System-Setup: launch zsh <<<
BASH_EOF
        echo "✅ .bashrc configured to launch zsh + UTF-8 codepage."
    fi

    # Also write ~/.bash_profile so Git Bash doesn't show the "Found ~/.bashrc
    # but no ~/.bash_profile" warning on the very first launch. Idempotent.
    BASH_PROFILE="$HOME/.bash_profile"
    PROFILE_MARKER='# >>> System-Setup: source bashrc >>>'
    if [[ ! -f "$BASH_PROFILE" ]] || ! grep -qF "$PROFILE_MARKER" "$BASH_PROFILE" 2>/dev/null; then
        cat >> "$BASH_PROFILE" << 'PROFILE_EOF'

# >>> System-Setup: source bashrc >>>
# Login shells should source .bashrc so zsh auto-launch + UTF-8 take effect.
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
# <<< System-Setup: source bashrc <<<
PROFILE_EOF
        echo "✅ .bash_profile created (suppresses Git Bash 'no profile' warning)."
    fi
fi

else
    echo ""
    echo "⚠️  Skipping zsh setup (zsh not available)."
fi  # end ZSH_AVAILABLE (sections 7-8)
fi  # end category 8 (Shell: zsh + p10k)

# ---------------------------
# 8c) Oh My Posh for PowerShell & CMD (category 9)
#     Based on: Terminal-Icons, PSReadLine (auto-complete + ListView),
#     useful aliases, Z directory jumper, and Oh My Posh prompt.
#     Also sets up CMD via Clink.
# ---------------------------
if category_enabled 9; then
    echo "🎨 Setting up Oh My Posh + productive PowerShell environment..."

    # --- Install PowerShell modules (via pwsh if available, else powershell) ---
    PWSH_BIN=""
    for p in pwsh.exe powershell.exe; do
        if command -v "$p" >/dev/null 2>&1; then PWSH_BIN="$p"; break; fi
    done

    if [[ -n "$PWSH_BIN" ]]; then
        echo "  Installing PowerShell modules (Terminal-Icons, PSReadLine, Z)..."
        "$PWSH_BIN" -NoProfile -Command '
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue

            $modules = @("Terminal-Icons", "PSReadLine", "Z")
            foreach ($m in $modules) {
                if (-not (Get-Module -Name $m -ListAvailable -ErrorAction SilentlyContinue)) {
                    Write-Host "    [..]  $m"
                    try {
                        Install-Module -Name $m -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                        Write-Host "    [ok]  $m"
                    } catch {
                        Write-Host "    [fail] $m - $($_.Exception.Message)"
                    }
                } else {
                    Write-Host "    [skip] $m (already installed)"
                }
            }
        ' 2>&1 || echo "  ⚠️  Module installation had errors (continuing)."
    fi

    # --- Write the PowerShell profile ---
    PS_PROFILE_DIR="$HOME/Documents/PowerShell"
    PS_PROFILE="$PS_PROFILE_DIR/Microsoft.PowerShell_profile.ps1"
    PS5_PROFILE_DIR="$HOME/Documents/WindowsPowerShell"
    PS5_PROFILE="$PS5_PROFILE_DIR/Microsoft.PowerShell_profile.ps1"
    OMP_MARKER='# >>> System-Setup: PowerShell Profile >>>'

    # The profile is written as a heredoc. Single-quotes around the delimiter
    # prevent bash from expanding $variables — they stay as literal PowerShell.
    read -r -d '' OMP_BLOCK << 'PSPROFILE'

# >>> System-Setup: PowerShell Profile >>>
# ═══════════════════════════════════════════════════════════
#  Oh My Posh + Terminal-Icons + PSReadLine + Aliases
#  Generated by System-Setup bootstrap. Edit freely.
# ═══════════════════════════════════════════════════════════

# --- Oh My Posh prompt ---------------------------------------------------
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\powerlevel10k_lean.omp.json" | Invoke-Expression
}

# --- Terminal Icons (file/folder icons in ls output) ----------------------
if (Get-Module -Name Terminal-Icons -ListAvailable -ErrorAction SilentlyContinue) {
    Import-Module Terminal-Icons
}

# --- PSReadLine (auto-complete, prediction, history) ----------------------
if ($host.Name -eq 'ConsoleHost') {
    if (Get-Module -Name PSReadLine -ListAvailable -ErrorAction SilentlyContinue) {
        Import-Module PSReadLine

        # Predict from history as you type
        Set-PSReadLineOption -PredictionSource History
        Set-PSReadLineOption -PredictionViewStyle ListView

        # Tab completes inline (like bash)
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

        # Up/Down arrow filters history by what you've already typed
        Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

        # No duplicate entries in history
        Set-PSReadLineOption -HistoryNoDuplicates

        # Editing mode: Windows (avoids conflicts with Ctrl+C, etc.)
        Set-PSReadLineOption -EditMode Windows

        # Ctrl+D deletes char (like bash); exit on empty line
        Set-PSReadLineKeyHandler -Chord 'Ctrl+d' -Function DeleteChar
    }
}

# --- Z directory jumper ---------------------------------------------------
if (Get-Module -Name Z -ListAvailable -ErrorAction SilentlyContinue) {
    Import-Module Z
}

# --- Useful aliases -------------------------------------------------------
Set-Alias -Name ll -Value Get-ChildItem -Force
Set-Alias -Name g  -Value git -Force
Set-Alias -Name grep -Value findstr -Force
Set-Alias -Name ip -Value ipconfig -Force
Set-Alias -Name tt -Value tree -Force

# --- Useful functions (Linux-like) ----------------------------------------
function which ($command) {
    Get-Command -Name $command -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Path -ErrorAction SilentlyContinue
}

function head {
    param($Path, $n = 10)
    Get-Content $Path -Head $n
}

function tail {
    param($Path, $n = 10, [switch]$f)
    if ($f) { Get-Content $Path -Wait -Tail $n }
    else    { Get-Content $Path -Tail $n }
}

function mkcd ($dir) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Location $dir
}

function hosts { notepad C:\Windows\System32\drivers\etc\hosts }

function df { Get-Volume }

function envs { Get-ChildItem env: | Sort-Object Name }

function touch ($file) { if (Test-Path $file) { (Get-Item $file).LastWriteTime = Get-Date } else { New-Item $file -ItemType File } }

# Remove Windows PowerShell 5.x aliases that shadow real curl/wget
if (Test-Path Alias:curl) { Remove-Item Alias:curl -Force -ErrorAction SilentlyContinue }
if (Test-Path Alias:wget) { Remove-Item Alias:wget -Force -ErrorAction SilentlyContinue }

# --- Hide the startup logo ------------------------------------------------
# (add -NoLogo to your WT profile commandline for a cleaner look)

# <<< System-Setup: PowerShell Profile <<<
PSPROFILE

    for dir in "$PS_PROFILE_DIR" "$PS5_PROFILE_DIR"; do
        mkdir -p "$dir" 2>/dev/null
    done

    for prof in "$PS_PROFILE" "$PS5_PROFILE"; do
        if [[ -f "$prof" ]] && grep -qF "$OMP_MARKER" "$prof" 2>/dev/null; then
            echo "  [skip] $(basename "$(dirname "$prof")") profile already configured."
        else
            echo "$OMP_BLOCK" >> "$prof"
            echo "  ✅ $(basename "$(dirname "$prof")") profile configured."
        fi
    done

    # --- CMD support via Clink -------------------------------------------
    echo "  Setting up Oh My Posh for CMD (via Clink)..."
    CLINK_EXE=""
    if command -v clink >/dev/null 2>&1; then
        CLINK_EXE="clink"
    elif [[ -f "/c/Program Files (x86)/clink/clink_x64.exe" ]]; then
        CLINK_EXE="/c/Program Files (x86)/clink/clink_x64.exe"
    fi

    # Install Clink if not found (via winget)
    if [[ -z "$CLINK_EXE" ]]; then
        echo "    Installing Clink for CMD support..."
        powershell.exe -NoProfile -Command "winget install --id chrisant996.Clink --exact --silent --accept-package-agreements --accept-source-agreements --source winget" 2>/dev/null || true
    fi

    # Write Clink oh-my-posh autostart script
    CLINK_DIR="$HOME/AppData/Local/clink"
    if [[ -d "$CLINK_DIR" ]] || mkdir -p "$CLINK_DIR" 2>/dev/null; then
        CLINK_LUA="$CLINK_DIR/oh-my-posh.lua"
        CLINK_MARKER='-- System-Setup: oh-my-posh'
        if [[ -f "$CLINK_LUA" ]] && grep -qF "$CLINK_MARKER" "$CLINK_LUA" 2>/dev/null; then
            echo "    [skip] Clink oh-my-posh.lua already configured."
        else
            cat > "$CLINK_LUA" << 'CLINKLUA'
-- System-Setup: oh-my-posh for CMD
-- This file is loaded by Clink automatically on CMD startup.
-- Uses POSH_THEMES_PATH env var with a fallback to the default install location.
local themes = os.getenv("POSH_THEMES_PATH")
if not themes then
    local localappdata = os.getenv("LOCALAPPDATA") or ""
    themes = localappdata .. "\\Programs\\oh-my-posh\\themes"
end
local config = themes .. "\\powerlevel10k_lean.omp.json"
load(io.popen('oh-my-posh init cmd --config "' .. config .. '"'):read("*a"))()
CLINKLUA
            echo "    ✅ Clink oh-my-posh.lua written to $CLINK_DIR"
        fi

        # Enable Clink autosuggestions (like fish/zsh-autosuggestions)
        if command -v clink >/dev/null 2>&1; then
            clink set autosuggest.enable true 2>/dev/null || true
            echo "    ✅ Clink autosuggestions enabled."
        fi
    fi

    echo "  ✅ Oh My Posh ready for PowerShell + CMD. Open a new window to see it."
    echo "     Browse themes: Get-PoshThemes (in PowerShell) or https://ohmyposh.dev/docs/themes"
fi  # end category 9 (Oh My Posh)

# ---------------------------
# 9) Install VS Code extensions (category 11)
# ---------------------------
if category_enabled 11; then
VSCODE_EXT_FILE="$SCRIPT_DIR/vscode-extensions.txt"
if [[ -f "$VSCODE_EXT_FILE" ]] && command -v code &>/dev/null; then
    echo "🧩 Installing VS Code extensions..."
    INSTALLED_EXT=$(code --list-extensions 2>/dev/null)
    TOTAL=0
    SKIPPED=0
    JOBS=0
    MAX_JOBS=5
    while IFS= read -r ext; do
        [[ -z "$ext" || "$ext" == \#* ]] && continue
        TOTAL=$((TOTAL + 1))
        if echo "$INSTALLED_EXT" | grep -Fxqi "$ext"; then
            SKIPPED=$((SKIPPED + 1))
        else
            code --install-extension "$ext" --force 2>/dev/null &
            JOBS=$((JOBS + 1))
            if [[ $JOBS -ge $MAX_JOBS ]]; then
                wait
                JOBS=0
            fi
        fi
    done < "$VSCODE_EXT_FILE"
    wait
    echo "✅ VS Code extensions: $TOTAL total, $SKIPPED already installed."
else
    [[ ! -f "${VSCODE_EXT_FILE:-}" ]] && echo "⚠️  vscode-extensions.txt not found — skipping." \
        || echo "⚠️  'code' command not found — skipping VS Code extensions."
fi
fi  # end category 11 (VS Code Extensions)

# ---------------------------
# PATH refresh: tools installed by winget (Phase 1) aren't visible in this
# bash session because it inherited the pre-install PATH. Pull in the latest
# Windows PATH from the registry so npm, go, rustup, python, java etc. are
# all found.
# ---------------------------
if [[ "$ENV_TYPE" == "gitbash" ]]; then
    echo "🔄 Refreshing PATH (picking up newly-installed tools)..."
    # Read current Machine + User PATH from registry via PowerShell
    FRESH_PATH="$(powershell.exe -NoProfile -Command '
        $m = [Environment]::GetEnvironmentVariable("Path","Machine")
        $u = [Environment]::GetEnvironmentVariable("Path","User")
        ($m + ";" + $u)
    ' 2>/dev/null | tr -d '\r')"
    if [[ -n "$FRESH_PATH" ]]; then
        # Convert Windows paths to MSYS2 paths and merge with existing
        IFS=';' read -ra WDIRS <<< "$FRESH_PATH"
        for d in "${WDIRS[@]}"; do
            d="$(echo "$d" | sed 's/^ *//;s/ *$//')"
            [[ -z "$d" ]] && continue
            posix_d="$(cygpath -u "$d" 2>/dev/null || true)"
            [[ -n "$posix_d" ]] && case ":$PATH:" in
                *:"$posix_d":*) ;;
                *) export PATH="$PATH:$posix_d" ;;
            esac
        done
        hash -r 2>/dev/null || true
        echo "  ✅ PATH updated."
    fi
fi

if category_enabled 12; then
# ---------------------------
# 10) Install Node.js LTS via nvm
# ---------------------------
echo "📦 Checking Node.js / nvm..."
set +e  # nvm commands can return non-zero
export NVM_DIR="$HOME/.nvm"
NVM_WIN="$(command -v nvm 2>/dev/null)"

if [[ -n "$NVM_WIN" ]]; then
    nvm install lts 2>/dev/null || nvm install --lts 2>/dev/null
    nvm use lts 2>/dev/null || nvm use --lts 2>/dev/null
    echo "✅ Node.js: $(node --version 2>/dev/null || echo 'run nvm use lts')"
elif [[ -s "$NVM_DIR/nvm.sh" ]]; then
    source "$NVM_DIR/nvm.sh"
    nvm install --lts && nvm use --lts
    echo "✅ Node.js: $(node --version)"
else
    echo "⚠️  nvm not found — skipping Node.js. Install via winget (CoreyButler.NVMforWindows)."
fi
set -e

# ---------------------------
# 10b) Install global npm packages (React, TS, linters, common CLIs)
# ---------------------------
echo "📦 Installing global npm packages..."
set +e
if command -v npm >/dev/null 2>&1; then
    NPM_GLOBALS=(
        yarn
        pnpm
        typescript
        ts-node
        eslint
        prettier
        nodemon
        serve
        create-react-app
        create-next-app
        create-vite
        vercel
        wrangler
        npm-check-updates
    )
    for pkg in "${NPM_GLOBALS[@]}"; do
        if npm list -g --depth=0 "$pkg" >/dev/null 2>&1; then
            echo "  [skip] $pkg (already installed)"
        else
            echo "  [..]   $pkg"
            npm install -g "$pkg" >/dev/null 2>&1 \
                && echo "  [ok]   $pkg" \
                || echo "  [fail] $pkg"
        fi
    done
else
    echo "⚠️  npm not found -- skipping global npm packages."
fi
set -e

# ---------------------------
# 10c) Install global Python tools (via pipx if available, else pip --user)
# ---------------------------
echo "🐍 Installing global Python tools..."
set +e
PYBIN=""
for cand in python python3 py; do
    if command -v "$cand" >/dev/null 2>&1; then PYBIN="$cand"; break; fi
done
if [[ -n "$PYBIN" ]]; then
    echo "  Using: $PYBIN ($("$PYBIN" --version 2>&1))"
    # Ensure pip is available, then install pipx
    "$PYBIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$PYBIN" -m pip install --user --upgrade --quiet pip pipx 2>/dev/null || true
    "$PYBIN" -m pipx ensurepath >/dev/null 2>&1 || true

    # pipx installs to ~/.local/bin (or AppData on Windows) — add to PATH
    PIPX_BIN="$HOME/.local/bin"
    [[ -d "$APPDATA/Python/Scripts" ]] && PIPX_BIN="$(cygpath -u "$APPDATA/Python/Scripts")"
    case ":$PATH:" in
        *:"$PIPX_BIN":*) ;;
        *) export PATH="$PATH:$PIPX_BIN" ;;
    esac

    PIPX_TOOLS=(uv ruff black httpie poetry virtualenv)
    for tool in "${PIPX_TOOLS[@]}"; do
        if "$PYBIN" -m pipx list 2>/dev/null | grep -q "package $tool "; then
            echo "  [skip] $tool (already installed)"
        else
            echo "  [..]   $tool"
            "$PYBIN" -m pipx install "$tool" 2>&1 | tail -1 | grep -q 'installed' \
                && echo "  [ok]   $tool" \
                || echo "  [fail] $tool (may need: pip install --user pipx)"
        fi
    done
else
    echo "⚠️  python not found -- skipping pipx tools."
fi
set -e

# ---------------------------
# 10d) Initialize Rust toolchain (rustup install stable)
# ---------------------------
echo "🦀 Configuring Rust toolchain..."
set +e
if command -v rustup >/dev/null 2>&1; then
    if ! rustup toolchain list 2>/dev/null | grep -q stable; then
        rustup toolchain install stable >/dev/null 2>&1 \
            && echo "  [ok] stable toolchain installed" \
            || echo "  [fail] rustup toolchain install"
    else
        echo "  [skip] stable toolchain already installed"
    fi
    rustup default stable >/dev/null 2>&1
    rustup component add rustfmt clippy rust-analyzer >/dev/null 2>&1
else
    echo "⚠️  rustup not found -- skipping (winget Rustlang.Rustup)."
fi
set -e

# ---------------------------
# 10e) Configure Go workspace
# ---------------------------
echo "🐹 Configuring Go..."
set +e
if command -v go >/dev/null 2>&1; then
    mkdir -p "$HOME/go/bin" "$HOME/go/src" "$HOME/go/pkg"
    go env -w GOPATH="$HOME/go" >/dev/null 2>&1
    echo "  [ok] GOPATH=$HOME/go"
else
    echo "⚠️  go not found -- skipping (winget GoLang.Go)."
fi
set -e

# ---------------------------
# 10f) Java + Maven + Gradle
# ---------------------------
set +e
if command -v java >/dev/null 2>&1; then
    echo "☕ Java: $(java -version 2>&1 | head -n1)"

    # Maven (not in winget — download from Apache directly)
    if command -v mvn >/dev/null 2>&1; then
        echo "  [skip] Maven $(mvn --version 2>/dev/null | head -1 | grep -oP '[\d.]+')"
    else
        echo "  [..]   Installing Apache Maven..."
        MVN_VER="3.9.9"
        MVN_URL="https://dlcdn.apache.org/maven/maven-3/$MVN_VER/binaries/apache-maven-$MVN_VER-bin.zip"
        MVN_HOME="/c/tools/maven"
        mkdir -p "$MVN_HOME"
        if curl -fsSL "$MVN_URL" -o /tmp/maven.zip 2>/dev/null; then
            unzip -qo /tmp/maven.zip -d /tmp/maven 2>/dev/null
            cp -rf /tmp/maven/apache-maven-*/* "$MVN_HOME/" 2>/dev/null || \
                powershell.exe -NoProfile -Command "Start-Process -Verb RunAs -Wait -FilePath xcopy.exe -ArgumentList '/E','/Y','/I','C:\Users\$env:USERNAME\AppData\Local\Temp\maven\apache-maven-$MVN_VER','C:\tools\maven'" 2>/dev/null
            rm -rf /tmp/maven /tmp/maven.zip
            export PATH="$PATH:$MVN_HOME/bin"
            echo "  [ok]   Maven $MVN_VER -> $MVN_HOME"
        else
            echo "  [fail] Maven download failed"
        fi
    fi

    # Gradle (not in winget — download from Gradle directly)
    if command -v gradle >/dev/null 2>&1; then
        echo "  [skip] Gradle $(gradle --version 2>/dev/null | grep '^Gradle' | awk '{print $2}')"
    else
        echo "  [..]   Installing Gradle..."
        GRADLE_VER="8.12"
        GRADLE_URL="https://services.gradle.org/distributions/gradle-$GRADLE_VER-bin.zip"
        GRADLE_HOME="/c/tools/gradle"
        mkdir -p "$GRADLE_HOME"
        if curl -fsSL "$GRADLE_URL" -o /tmp/gradle.zip 2>/dev/null; then
            unzip -qo /tmp/gradle.zip -d /tmp/gradle 2>/dev/null
            cp -rf /tmp/gradle/gradle-*/* "$GRADLE_HOME/" 2>/dev/null || \
                powershell.exe -NoProfile -Command "Start-Process -Verb RunAs -Wait -FilePath xcopy.exe -ArgumentList '/E','/Y','/I','C:\Users\$env:USERNAME\AppData\Local\Temp\gradle\gradle-$GRADLE_VER','C:\tools\gradle'" 2>/dev/null
            rm -rf /tmp/gradle /tmp/gradle.zip
            export PATH="$PATH:$GRADLE_HOME/bin"
            echo "  [ok]   Gradle $GRADLE_VER -> $GRADLE_HOME"
        else
            echo "  [fail] Gradle download failed"
        fi
    fi
else
    echo "⚠️  java not found -- skipping Maven/Gradle (JDK not installed yet)."
fi
set -e
fi  # end category 12 (Language Tooling)

# ---------------------------
# Done
# ---------------------------
echo ""
echo "============================================="
echo "✅ Bootstrap Complete!"
echo "============================================="
echo ""
echo "Next steps:"
echo "  1. Close and reopen Git Bash — zsh will start automatically."
echo "  2. Run 'p10k configure' to set up your Powerlevel10k prompt."
echo "  3. If SSH key was generated, add it to GitHub:"
echo "     https://github.com/settings/ssh/new"
echo "  4. Set terminal font to 'MesloLGS NF'."
echo "  5. Sign into VS Code with GitHub for Settings Sync."
echo "  6. Sign into apps: Chrome, Docker, JetBrains, etc."
echo ""
