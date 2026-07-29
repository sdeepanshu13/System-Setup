#!/usr/bin/env bash
# ==============================================================
#  System-Setup -- macOS entry point.
#  Installs Homebrew + PowerShell if needed, then runs Setup.ps1.
#
#  Usage:  ./Setup.sh  [--unattended]
# ==============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS. On Windows run Windows\\Setup.cmd."

echo
info "============================================="
info "  System-Setup - macOS Dev Machine Setup"
info "============================================="
echo

# --- Xcode Command Line Tools (needed by Homebrew) ---
if ! xcode-select -p >/dev/null 2>&1; then
    info "Installing Xcode Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    warn "Finish the Command Line Tools dialog, then re-run this script."
    # Wait for it rather than failing outright.
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
    ok "Command Line Tools installed."
fi

# --- Homebrew ---
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$candidate" ]] && BREW="$candidate" && break
done
if [[ -z "$BREW" ]] && command -v brew >/dev/null 2>&1; then BREW="$(command -v brew)"; fi

if [[ -z "$BREW" ]]; then
    info "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew installation failed."
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$candidate" ]] && BREW="$candidate" && break
    done
    [[ -n "$BREW" ]] || die "Homebrew installed but 'brew' was not found."
    ok "Homebrew installed."
else
    ok "Homebrew already installed."
fi

eval "$("$BREW" shellenv)"

# --- PowerShell (runs the shared cross-platform core) ---
if ! command -v pwsh >/dev/null 2>&1; then
    info "Installing PowerShell..."
    "$BREW" install --cask powershell || die "Could not install PowerShell."
    ok "PowerShell installed."
fi

# --- Hand over to the orchestrator ---
info "Starting setup..."
echo
exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/Setup.ps1" "$@"
