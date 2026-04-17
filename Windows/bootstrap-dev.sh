#!/bin/bash
# ==============================================
# 🚀 Deepanshu Dev Machine Bootstrap (Git Bash)
# ==============================================
# Usage: Open Git Bash as Administrator, then run:
#   ./bootstrap-dev.sh
#
# Two-phase setup:
#   Phase 1: restore.ps1 — installs all software via winget
#   Phase 2: this script — zsh, p10k, fonts, dotfiles
#
# If winget packages are already installed, Phase 1 is skipped.
# ==============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC_SRC="$SCRIPT_DIR/zshrc-template"

echo "============================================="
echo "🚀 Deepanshu Dev Machine Bootstrap Starting"
echo "============================================="

# ---------------------------
# 0) Install winget packages (Phase 1)
# ---------------------------
RESTORE_PS1="$SCRIPT_DIR/restore.ps1"
if [[ -f "$RESTORE_PS1" ]]; then
    echo ""
    echo "📦 Phase 1: Installing software via winget..."
    echo "   (This will run restore.ps1 in PowerShell)"
    echo ""
    WIN_RESTORE="$(cygpath -w "$RESTORE_PS1")"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_RESTORE"
    echo ""
    echo "✅ Phase 1 complete."
    echo ""
else
    echo "⚠️  restore.ps1 not found — skipping winget package install."
fi

echo "🔧 Phase 2: Shell & dotfiles setup"
echo ""

# ---------------------------
# 1) Install Oh My Zsh
# ---------------------------
if [[ -d "$HOME/.oh-my-zsh" ]]; then
    echo "✅ Oh My Zsh already installed, skipping."
else
    echo "📦 Installing Oh My Zsh..."
    # Unattended install; don't let it switch shell or overwrite .zshrc yet
    RUNZSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo "✅ Oh My Zsh installed."
fi

# ---------------------------
# 2) Install Powerlevel10k
# ---------------------------
P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [[ -d "$P10K_DIR" ]]; then
    echo "✅ Powerlevel10k already installed, skipping."
else
    echo "🎨 Installing Powerlevel10k..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
    echo "✅ Powerlevel10k installed."
fi

# ---------------------------
# 3) Install zsh-autosuggestions
# ---------------------------
ZSH_AS_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
if [[ -d "$ZSH_AS_DIR" ]]; then
    echo "✅ zsh-autosuggestions already installed, skipping."
else
    echo "⚡ Installing zsh-autosuggestions..."
    git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_AS_DIR"
    echo "✅ zsh-autosuggestions installed."
fi

# ---------------------------
# 4) Install zsh-syntax-highlighting
# ---------------------------
ZSH_SH_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
if [[ -d "$ZSH_SH_DIR" ]]; then
    echo "✅ zsh-syntax-highlighting already installed, skipping."
else
    echo "✨ Installing zsh-syntax-highlighting..."
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_SH_DIR"
    echo "✅ zsh-syntax-highlighting installed."
fi

# ---------------------------
# 5) Install MesloLGS Nerd Font
# ---------------------------
echo "🔤 Installing MesloLGS Nerd Font..."

# Use the Windows-native USERPROFILE path for font operations
WIN_HOME="$(cygpath -w "$HOME")"
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
        curl -fsSL -o "$FONT_DIR/$DECODED" "$FONT_BASE/$f"
    fi
done

# Install fonts via PowerShell using proper Windows paths
WIN_FONT_DIR="$(cygpath -w "$FONT_DIR")"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$fonts = '$WIN_FONT_DIR'
    \$shell = New-Object -ComObject Shell.Application
    \$fontsFolder = \$shell.Namespace(0x14)  # Windows Fonts folder
    Get-ChildItem \$fonts -Filter *.ttf | ForEach-Object {
        if (-not (Test-Path \"\$env:WINDIR\\Fonts\\\$(\$_.Name)\")) {
            Write-Host \"  Installing \$(\$_.Name)...\"
            \$fontsFolder.CopyHere(\$_.FullName, 0x10)
        } else {
            Write-Host \"  \$(\$_.Name) already installed.\"
        }
    }
"
echo "✅ MesloLGS Nerd Font installed."

# ---------------------------
# 6) Deploy optimized .zshrc
# ---------------------------
echo "📝 Setting up .zshrc..."
if [[ -f "$HOME/.zshrc" ]]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
    echo "  Backed up existing .zshrc"
fi

if [[ -f "$ZSHRC_SRC" ]]; then
    cp "$ZSHRC_SRC" "$HOME/.zshrc"
    echo "✅ .zshrc deployed from template."
else
    echo "⚠️  zshrc-template not found at $ZSHRC_SRC"
    echo "  Writing optimized .zshrc inline..."
    cat > "$HOME/.zshrc" << 'ZSHRC_EOF'
# -------------------------------
# 🚀 Ultra-Optimized Zsh (Windows Git Bash)
# -------------------------------

# Powerlevel10k instant prompt (MUST be first)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

# Path to Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"

# Theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Performance Tweaks
export DISABLE_UNTRACKED_FILES_DIRTY=true
typeset -g POWERLEVEL10K_VCS_MAX_INDEX_SIZE_DIRTY=-1
export POWERLEVEL10K_DISABLE_CONFIGURATION_WIZARD=true
export ZSH_DISABLE_COMPFIX=true
export GIT_OPTIONAL_LOCKS=0

# Disable update checks (important on Windows)
zstyle ':omz:update' frequency 1

# Cached compinit (important for Windows)
autoload -Uz compinit
if [[ -f ~/.zcompdump ]]; then
  compinit -C
else
  compinit
fi

# Minimal plugins (keep it light)
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
)

# Load Oh My Zsh
source "$ZSH/oh-my-zsh.sh"

# Load Powerlevel10k config
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# -------------------------------
# Aliases
# -------------------------------
alias gs='git status'
alias ga='git add'
alias gc='git commit -m'
alias gl='git log --oneline --graph --all'
alias ..='cd ..'
alias ...='cd ../..'
alias ll='ls -alF'

# Editor
export EDITOR='nvim'

# Colors
export TERM=xterm-256color
ZSHRC_EOF
    echo "✅ .zshrc written."
fi

# ---------------------------
# 7) Make zsh default in Git Bash
# ---------------------------
echo "🔧 Setting zsh as default shell in Git Bash..."
BASHRC="$HOME/.bashrc"

# Check if .bashrc already launches zsh
if [[ -f "$BASHRC" ]] && grep -q 'exec zsh' "$BASHRC" 2>/dev/null; then
    echo "✅ .bashrc already launches zsh."
else
    # Preserve existing .bashrc content
    if [[ -f "$BASHRC" ]]; then
        cp "$BASHRC" "$BASHRC.backup.$(date +%Y%m%d%H%M%S)"
        echo "  Backed up existing .bashrc"
    fi
    cat >> "$BASHRC" << 'BASH_EOF'

# Auto-start zsh
if [ -t 1 ] && [ -z "$ZSH_VERSION" ]; then
  exec zsh
fi
BASH_EOF
    echo "✅ .bashrc configured to launch zsh."
fi

# ---------------------------
# 8) Configure Git defaults
# ---------------------------
echo "⚙️  Setting Git defaults..."
git config --global init.defaultBranch main
git config --global core.autocrlf true
git config --global pull.rebase true
git config --global fetch.prune true
git config --global diff.colorMoved zebra
git config --global rebase.autoStash true
echo "✅ Git defaults set."

# ---------------------------
# 9) Install VS Code extensions
# ---------------------------
VSCODE_EXT_FILE="$SCRIPT_DIR/vscode-extensions.txt"
if [[ -f "$VSCODE_EXT_FILE" ]] && command -v code &>/dev/null; then
    echo "🧩 Installing VS Code extensions..."
    INSTALLED_EXT=$(code --list-extensions 2>/dev/null)
    TOTAL=0
    SKIPPED=0
    while IFS= read -r ext; do
        [[ -z "$ext" || "$ext" == \#* ]] && continue
        TOTAL=$((TOTAL + 1))
        if echo "$INSTALLED_EXT" | grep -qi "^${ext}$"; then
            SKIPPED=$((SKIPPED + 1))
        else
            code --install-extension "$ext" --force 2>/dev/null &
        fi
    done < "$VSCODE_EXT_FILE"
    wait
    echo "✅ VS Code extensions: $TOTAL total, $SKIPPED already installed."
else
    if [[ ! -f "$VSCODE_EXT_FILE" ]]; then
        echo "⚠️  vscode-extensions.txt not found — skipping VS Code extensions."
    else
        echo "⚠️  'code' command not found — skipping VS Code extensions."
    fi
fi

# ---------------------------
# 10) Install Node.js LTS via nvm
# ---------------------------
export NVM_DIR="$HOME/.nvm"
NVM_SH="$NVM_DIR/nvm.sh"
# nvm-windows stores its files differently, check for that too
NVM_WIN="$(command -v nvm 2>/dev/null)"

if [[ -n "$NVM_WIN" ]]; then
    echo "📦 Installing Node.js LTS via nvm..."
    nvm install lts 2>/dev/null || nvm install --lts 2>/dev/null || true
    nvm use lts 2>/dev/null || nvm use --lts 2>/dev/null || true
    echo "✅ Node.js LTS installed: $(node --version 2>/dev/null || echo 'check nvm use')"
elif [[ -s "$NVM_SH" ]]; then
    source "$NVM_SH"
    echo "📦 Installing Node.js LTS via nvm..."
    nvm install --lts
    nvm use --lts
    echo "✅ Node.js LTS installed: $(node --version)"
else
    echo "⚠️  nvm not found — skipping Node.js install. Install it via winget (CoreyButler.NVMforWindows)."
fi

# ---------------------------
# 11) Configure Windows Terminal font (best-effort)
# ---------------------------
WT_SETTINGS="$HOME/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
if [[ -f "$WT_SETTINGS" ]]; then
    # Only patch if MesloLGS is not already set
    if ! grep -q "MesloLGS" "$WT_SETTINGS" 2>/dev/null; then
        echo "🖥️  Configuring Windows Terminal font..."
        # Use PowerShell for safe JSON manipulation
        WIN_WT_SETTINGS="$(cygpath -w "$WT_SETTINGS")"
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
            \$s = Get-Content '$WIN_WT_SETTINGS' -Raw | ConvertFrom-Json
            if (-not \$s.profiles.defaults.font) {
                \$s.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue @{} -Force
            }
            \$s.profiles.defaults.font = @{ face = 'MesloLGS NF'; size = 10 }
            \$s | ConvertTo-Json -Depth 32 | Set-Content '$WIN_WT_SETTINGS' -Encoding UTF8
            Write-Host '  Set default font to MesloLGS NF'
        " 2>/dev/null
        echo "✅ Windows Terminal font configured."
    else
        echo "✅ Windows Terminal already uses MesloLGS NF."
    fi
else
    echo "ℹ️  Windows Terminal settings not found — configure font manually after installing."
fi

# ---------------------------
# 9) Generate SSH key for GitHub
# ---------------------------
echo ""
echo "🔑 SSH Key Setup for GitHub"
echo ""

# Prompt for name and email
read -rp "Enter your full name (for git config): " GIT_NAME
read -rp "Enter your GitHub email: " GIT_EMAIL

if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    echo "⚠️  Name or email is empty — skipping SSH key generation."
else
    # Set git identity
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    echo "✅ Git identity set: $GIT_NAME <$GIT_EMAIL>"

    SSH_KEY="$HOME/.ssh/id_ed25519"
    if [[ -f "$SSH_KEY" ]]; then
        echo "✅ SSH key already exists at $SSH_KEY — skipping generation."
    else
        echo "🔐 Generating ed25519 SSH key..."
        mkdir -p "$HOME/.ssh"
        ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY" -N ""
        echo "✅ SSH key generated."
    fi

    # Start ssh-agent and add the key
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    ssh-add "$SSH_KEY" 2>/dev/null
    echo "✅ SSH key added to ssh-agent."

    # Configure Git to use Windows OpenSSH so the Windows ssh-agent works
    # This avoids the MSYS2 vs Windows SSH agent conflict
    if [[ -f "/c/Windows/System32/OpenSSH/ssh.exe" ]]; then
        git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
        echo "✅ Git configured to use Windows OpenSSH (avoids agent conflicts)."
    fi

    # Also start the Windows ssh-agent service and add the key there
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
        \$svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if (\$svc) {
            if (\$svc.StartType -eq 'Disabled') {
                Set-Service -Name ssh-agent -StartupType Manual
            }
            if (\$svc.Status -ne 'Running') {
                Start-Service ssh-agent
            }
            Write-Host '  Windows ssh-agent service is running.'
        }
    " 2>/dev/null

    # Save public key to a file for easy copying to GitHub
    PUB_KEY_FILE="$SCRIPT_DIR/github-ssh-pubkey.txt"
    cp "$SSH_KEY.pub" "$PUB_KEY_FILE"

    echo ""
    echo "============================================="
    echo "🔑 Your GitHub SSH Public Key"
    echo "============================================="
    cat "$SSH_KEY.pub"
    echo ""
    echo "============================================="
    echo ""
    echo "📋 Public key saved to: $PUB_KEY_FILE"
    echo ""
    echo "👉 Add this key to GitHub:"
    echo "   https://github.com/settings/ssh/new"
    echo ""
fi

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
echo "  4. Verify font: In your terminal, set font to 'MesloLGS NF'."
echo "     - Windows Terminal: should be auto-configured above"
echo "     - Git Bash:         Options → Text → Font"
echo "  5. Sign into VS Code with GitHub for Settings Sync."
echo "  6. Sign into apps: Chrome, Docker, JetBrains, etc."
echo ""
