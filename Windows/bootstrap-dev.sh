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
# ==============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC_SRC="$SCRIPT_DIR/zshrc-template"
ZSH_CUSTOM_DIR="$HOME/.oh-my-zsh/custom"

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
    WIN_RESTORE="$(cygpath -w "$RESTORE_PS1")"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_RESTORE" || true
    echo ""
    echo "✅ Phase 1 complete."
    echo ""
else
    echo "⚠️  restore.ps1 not found — skipping winget package install."
fi

echo "🔧 Phase 2: Shell & dotfiles setup"
echo ""

# ---------------------------
# 1) Git identity & defaults (prompt early so rest runs unattended)
# ---------------------------
echo "⚙️  Git Configuration"
echo ""
read -rp "Enter your full name (for git config): " GIT_NAME
read -rp "Enter your GitHub email: " GIT_EMAIL

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
# 2) Install Oh My Zsh
# ---------------------------
if [[ -d "$HOME/.oh-my-zsh" ]]; then
    echo "✅ Oh My Zsh already installed, skipping."
else
    echo "📦 Installing Oh My Zsh..."
    RUNZSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo "✅ Oh My Zsh installed."
fi

# ---------------------------
# 3) Install Powerlevel10k + plugins (all shallow clones)
# ---------------------------
clone_if_missing "https://github.com/romkatv/powerlevel10k.git" \
    "$ZSH_CUSTOM_DIR/themes/powerlevel10k" "Powerlevel10k"

clone_if_missing "https://github.com/zsh-users/zsh-autosuggestions.git" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions" "zsh-autosuggestions"

clone_if_missing "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting" "zsh-syntax-highlighting"

# ---------------------------
# 4) Install MesloLGS Nerd Font
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

# ---------------------------
# 5) Deploy optimized .zshrc
# ---------------------------
echo "📝 Setting up .zshrc..."
if [[ ! -f "$ZSHRC_SRC" ]]; then
    echo "❌ zshrc-template not found at $ZSHRC_SRC — skipping."
else
    if [[ -f "$HOME/.zshrc" ]]; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
        echo "  Backed up existing .zshrc"
    fi
    cp "$ZSHRC_SRC" "$HOME/.zshrc"
    echo "✅ .zshrc deployed from template."
fi

# ---------------------------
# 6) Make zsh default in Git Bash
# ---------------------------
echo "🔧 Setting zsh as default shell in Git Bash..."
BASHRC="$HOME/.bashrc"

if [[ -f "$BASHRC" ]] && grep -q 'exec zsh' "$BASHRC" 2>/dev/null; then
    echo "✅ .bashrc already launches zsh."
else
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
# 7) Generate SSH key for GitHub
# ---------------------------
echo ""
echo "🔑 SSH Key Setup for GitHub"

if [[ -z "${GIT_EMAIL:-}" ]]; then
    echo "⚠️  No email provided earlier — skipping SSH key generation."
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
    if [[ -f "/c/Windows/System32/OpenSSH/ssh.exe" ]]; then
        git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
    fi

    # Start Windows ssh-agent service
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
        \$svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if (\$svc) {
            if (\$svc.StartType -eq 'Disabled') { Set-Service -Name ssh-agent -StartupType Manual }
            if (\$svc.Status -ne 'Running') { Start-Service ssh-agent }
        }
    " 2>/dev/null || true

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

# ---------------------------
# 8) Install VS Code extensions
# ---------------------------
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
        if echo "$INSTALLED_EXT" | grep -qi "^${ext}$"; then
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

# ---------------------------
# 9) Install Node.js LTS via nvm
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
# 10) Configure Windows Terminal font (best-effort)
# ---------------------------
WT_SETTINGS="$HOME/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
if [[ -f "$WT_SETTINGS" ]]; then
    if ! grep -q "MesloLGS" "$WT_SETTINGS" 2>/dev/null; then
        echo "🖥️  Configuring Windows Terminal font..."
        WIN_WT_SETTINGS="$(cygpath -w "$WT_SETTINGS")"
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
            \$s = Get-Content '$WIN_WT_SETTINGS' -Raw | ConvertFrom-Json
            if (-not \$s.profiles.defaults.font) {
                \$s.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue @{} -Force
            }
            \$s.profiles.defaults.font = @{ face = 'MesloLGS NF'; size = 10 }
            \$s | ConvertTo-Json -Depth 32 | Set-Content '$WIN_WT_SETTINGS' -Encoding UTF8
        " 2>/dev/null && echo "✅ Windows Terminal font configured." \
                      || echo "⚠️  Could not update Windows Terminal settings."
    else
        echo "✅ Windows Terminal already uses MesloLGS NF."
    fi
else
    echo "ℹ️  Windows Terminal settings not found — configure font manually."
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
echo "  4. Set terminal font to 'MesloLGS NF'."
echo "  5. Sign into VS Code with GitHub for Settings Sync."
echo "  6. Sign into apps: Chrome, Docker, JetBrains, etc."
echo ""
