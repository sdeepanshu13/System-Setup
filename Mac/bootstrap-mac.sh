#!/usr/bin/env bash
# ==============================================================
#  Phase 2 for macOS: shell, dotfiles, SSH key, language tooling.
#  Invoked by Setup.ps1. Reads SETUP_FEATURES / SETUP_GIT_NAME /
#  SETUP_GIT_EMAIL from the environment; runs everything when unset.
# ==============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }

FEATURES="${SETUP_FEATURES:-zsh,zshplugins,gitssh,vscode,npm,pipx,rust,golang}"
feature_enabled() { echo ",$FEATURES," | grep -q ",$1,"; }

command -v brew >/dev/null 2>&1 && eval "$(brew shellenv)"

# --- Git identity + SSH key ---
if feature_enabled gitssh; then
    step "Git config & SSH key"
    [[ -n "${SETUP_GIT_NAME:-}"  ]] && git config --global user.name  "$SETUP_GIT_NAME"
    [[ -n "${SETUP_GIT_EMAIL:-}" ]] && git config --global user.email "$SETUP_GIT_EMAIL"
    git config --global init.defaultBranch main
    git config --global pull.rebase true
    git config --global core.autocrlf input
    ok "git configured"

    if [[ -n "${SETUP_GIT_EMAIL:-}" && ! -f "$HOME/.ssh/id_ed25519" ]]; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -C "$SETUP_GIT_EMAIL" -f "$HOME/.ssh/id_ed25519" -N "" -q
        eval "$(ssh-agent -s)" >/dev/null
        # Apple keychain integration so the passphrase isn't re-asked.
        printf 'Host github.com\n  AddKeysToAgent yes\n  UseKeychain yes\n  IdentityFile ~/.ssh/id_ed25519\n' \
            >> "$HOME/.ssh/config"
        ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519" 2>/dev/null || ssh-add "$HOME/.ssh/id_ed25519"
        ok "SSH key created"
    else
        ok "SSH key already present"
    fi
fi

# --- Oh My Zsh + Powerlevel10k ---
if feature_enabled zsh; then
    step "Oh My Zsh + Powerlevel10k"
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        RUNZSH=no CHSH=no sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
            && ok "Oh My Zsh installed" || warn "Oh My Zsh install failed"
    else
        ok "Oh My Zsh already installed"
    fi

    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k" >/dev/null 2>&1 && ok "Powerlevel10k installed"
    fi

    if feature_enabled zshplugins; then
        for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
            if [[ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]]; then
                git clone --depth=1 "https://github.com/zsh-users/$plugin" \
                    "$ZSH_CUSTOM/plugins/$plugin" >/dev/null 2>&1 && ok "$plugin installed"
            fi
        done
    fi

    # Reuse the repo's shared zsh template when present.
    if [[ -f "$REPO_ROOT/Windows/zshrc-template" ]]; then
        [[ -f "$HOME/.zshrc" ]] && cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%s)"
        cp "$REPO_ROOT/Windows/zshrc-template" "$HOME/.zshrc"
        ok ".zshrc written (previous copy backed up)"
    fi
    if [[ -f "$REPO_ROOT/Windows/p10k-template" && ! -f "$HOME/.p10k.zsh" ]]; then
        cp "$REPO_ROOT/Windows/p10k-template" "$HOME/.p10k.zsh"
        ok ".p10k.zsh written"
    fi

    # macOS ships zsh already; only chsh if Homebrew's zsh is preferred.
    BREW_ZSH="$(brew --prefix 2>/dev/null)/bin/zsh"
    if [[ -x "$BREW_ZSH" && "$SHELL" != "$BREW_ZSH" ]]; then
        grep -qxF "$BREW_ZSH" /etc/shells 2>/dev/null || echo "$BREW_ZSH" | sudo tee -a /etc/shells >/dev/null
        chsh -s "$BREW_ZSH" && ok "default shell -> $BREW_ZSH"
    fi
fi

# --- VS Code extensions ---
if feature_enabled vscode; then
    step "VS Code extensions"
    CODE_BIN="$(command -v code || true)"
    [[ -z "$CODE_BIN" && -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]] \
        && CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    EXT_LIST="$REPO_ROOT/Windows/vscode-extensions.txt"
    if [[ -n "$CODE_BIN" && -f "$EXT_LIST" ]]; then
        while IFS= read -r ext; do
            [[ -z "$ext" || "$ext" == \#* ]] && continue
            "$CODE_BIN" --install-extension "$ext" --force >/dev/null 2>&1 \
                && ok "$ext" || warn "failed: $ext"
        done < "$EXT_LIST"
    else
        warn "VS Code CLI or extension list not found -- skipped"
    fi
fi

# --- npm globals ---
if feature_enabled npm && command -v npm >/dev/null 2>&1; then
    step "npm global packages"
    npm install -g typescript ts-node eslint prettier vite nodemon yarn pnpm >/dev/null 2>&1 \
        && ok "npm globals installed" || warn "some npm globals failed"
fi

# --- Python tooling ---
if feature_enabled pipx; then
    step "Python tools (pipx)"
    command -v pipx >/dev/null 2>&1 || brew install pipx >/dev/null 2>&1
    if command -v pipx >/dev/null 2>&1; then
        pipx ensurepath >/dev/null 2>&1
        for tool in uv ruff poetry black httpie; do
            pipx install "$tool" >/dev/null 2>&1 && ok "$tool" || warn "failed: $tool"
        done
    fi
fi

# --- Rust ---
if feature_enabled rust; then
    step "Rust toolchain"
    if command -v rustup-init >/dev/null 2>&1 && ! command -v rustup >/dev/null 2>&1; then
        rustup-init -y --no-modify-path >/dev/null 2>&1
    fi
    if command -v rustup >/dev/null 2>&1; then
        rustup default stable >/dev/null 2>&1
        rustup component add clippy rustfmt rust-analyzer >/dev/null 2>&1
        ok "rust stable + clippy + rustfmt"
    else
        warn "rustup not found -- skipped"
    fi
fi

# --- Go workspace ---
if feature_enabled golang && command -v go >/dev/null 2>&1; then
    step "Go workspace"
    mkdir -p "$HOME/go/"{bin,src,pkg}
    go env -w GOPATH="$HOME/go" >/dev/null 2>&1
    ok "GOPATH -> $HOME/go"
fi

# --- Maven / Gradle ---
feature_enabled maven  && command -v brew >/dev/null 2>&1 && { step "Maven";  brew install maven  >/dev/null 2>&1 && ok "maven installed"; }
feature_enabled gradle && command -v brew >/dev/null 2>&1 && { step "Gradle"; brew install gradle >/dev/null 2>&1 && ok "gradle installed"; }

# --- macOS defaults ---
if feature_enabled macdefaults; then
    step "macOS defaults"
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock show-recents -bool false
    defaults write com.apple.finder AppleShowAllFiles -bool true
    defaults write com.apple.finder ShowPathbar -bool true
    defaults write com.apple.finder ShowStatusBar -bool true
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true
    defaults write NSGlobalDomain KeyRepeat -int 2
    defaults write NSGlobalDomain InitialKeyRepeat -int 15
    defaults write com.apple.screencapture location -string "$HOME/Desktop"
    killall Dock 2>/dev/null || true
    killall Finder 2>/dev/null || true
    ok "Dock, Finder and keyboard preferences applied"
fi

printf '\n\033[32m==> Phase 2 complete.\033[0m\n'
