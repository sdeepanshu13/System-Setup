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
echo ""
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
# 8) Add Git Bash profile to Windows Terminal & make it default
# ---------------------------
WT_SETTINGS_PATH="$HOME/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
GIT_ROOT_POSIX="$(find_git_root 2>/dev/null || true)"

if [[ -f "$WT_SETTINGS_PATH" && -n "$GIT_ROOT_POSIX" ]]; then
    GIT_ROOT_WIN="$(cygpath -w "$GIT_ROOT_POSIX")"
    WIN_WT_PATH="$(cygpath -w "$WT_SETTINGS_PATH")"
    echo "🖥️  Configuring Windows Terminal (Git Bash profile + default + font + elevate)..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
        \$path = '$WIN_WT_PATH'
        \$gitDir = '$GIT_ROOT_WIN'
        # One-time backup (don't pile up a backup per run).
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

        \$bashExe = Join-Path \$gitDir 'bin\\bash.exe'
        \$icon    = Join-Path \$gitDir 'mingw64\\share\\git\\git-for-windows.ico'
        \$gitBashGuid = '{00000000-0000-0000-ba54-000000000001}'
        # Use single quotes inside the JSON-bound string -- Windows accepts
        # them around a path with spaces and we avoid backslash-escaping.
        \$cmdLine = '\"' + \$bashExe + '\" --login -i'

        \$existing = \$s.profiles.list | Where-Object { \$_.name -eq 'Git Bash' -or \$_.guid -eq \$gitBashGuid }
        if (\$existing) {
            \$existing | Add-Member -NotePropertyName guid              -NotePropertyValue \$gitBashGuid -Force
            \$existing | Add-Member -NotePropertyName name              -NotePropertyValue 'Git Bash'   -Force
            \$existing | Add-Member -NotePropertyName commandline       -NotePropertyValue \$cmdLine    -Force
            \$existing | Add-Member -NotePropertyName icon              -NotePropertyValue \$icon       -Force
            \$existing | Add-Member -NotePropertyName startingDirectory -NotePropertyValue '%USERPROFILE%' -Force
            \$existing | Add-Member -NotePropertyName elevate           -NotePropertyValue \$true       -Force
            Write-Host '  Updated existing Git Bash profile (elevate=true).'
        } else {
            \$gb = [PSCustomObject]@{
                guid              = \$gitBashGuid
                name              = 'Git Bash'
                commandline       = \$cmdLine
                icon              = \$icon
                startingDirectory = '%USERPROFILE%'
                elevate           = \$true
            }
            # Force list to a real array before appending.
            \$listArr = @(\$s.profiles.list) + \$gb
            \$s.profiles.list = \$listArr
            Write-Host '  Added Git Bash profile (elevate=true).'
        }

        # Make Git Bash the default profile
        \$s | Add-Member -NotePropertyName defaultProfile -NotePropertyValue \$gitBashGuid -Force
        Write-Host '  Set Git Bash as default profile.'

        \$s | ConvertTo-Json -Depth 32 | Set-Content \$path -Encoding UTF8
    " 2>&1 || echo "  ⚠️  Could not update Windows Terminal settings automatically."
else
    [[ ! -f "$WT_SETTINGS_PATH" ]] && echo "ℹ️  Windows Terminal not installed — skipping profile setup."
    [[ -z "$GIT_ROOT_POSIX" ]]      && echo "ℹ️  Git for Windows not found — skipping profile setup."
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

# ---------------------------
# 9) Install VS Code extensions
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
    "$PYBIN" -m pip install --user --upgrade pip pipx >/dev/null 2>&1
    "$PYBIN" -m pipx ensurepath >/dev/null 2>&1 || true
    PIPX_TOOLS=(uv ruff black httpie poetry virtualenv)
    for tool in "${PIPX_TOOLS[@]}"; do
        if "$PYBIN" -m pipx list 2>/dev/null | grep -q "package $tool "; then
            echo "  [skip] $tool (already installed)"
        else
            echo "  [..]   $tool"
            "$PYBIN" -m pipx install "$tool" >/dev/null 2>&1 \
                && echo "  [ok]   $tool" \
                || echo "  [fail] $tool"
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
# 10f) Java (verify only -- JDK installed by winget)
# ---------------------------
if command -v java >/dev/null 2>&1; then
    echo "☕ Java: $(java -version 2>&1 | head -n1)"
fi

# ---------------------------
# 11) (Reserved) Windows Terminal font is configured in section 8.
# ---------------------------

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
