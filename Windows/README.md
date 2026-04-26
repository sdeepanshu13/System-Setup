# Windows Setup -- Detailed Guide

This document covers everything the setup does, how each phase works, and how to customize it.

For quick start instructions, see the [main README](../README.md).

---

## How the Setup Works

When you run `Setup.cmd`, three phases happen in order:

### Phase 1 -- Install Software (restore.ps1)

1. Resets the winget source cache (prevents stale-manifest failures)
2. Checks what's already installed and **skips** those packages
3. Installs priority packages first (Git, PowerShell 7, Windows Terminal, GitHub CLI) -- these are needed by later phases
4. Installs everything else in **parallel** (5 at a time by default)
5. Each package gets its own log file in `logs/<timestamp>/packages/`

Only the categories you selected in the menu are installed. If you unchecked "Web Browsers", Chrome and Firefox are skipped.

### Phase 1b -- Windows Features (Enable-WindowsFeatures.ps1)

Runs only if you selected category 10. Enables:

| Feature | Why |
|---------|-----|
| WSL + Virtual Machine Platform | Linux on Windows |
| Hyper-V | Docker, Android emulators |
| Hypervisor Platform | Third-party virtualization |
| Containers | Docker native containers |
| Windows Sandbox | Safe disposable VM for testing |
| .NET 3.5 | Legacy app compatibility |
| Print to PDF / XPS | Document creation |

**Not enabled** (for security): SMB1, Telnet, TFTP, PowerShell v2, Internet Explorer.

### Phase 2 -- Dev Environment (bootstrap-dev.sh)

Runs in Git Bash. Only the sections matching your selected categories execute.

| Category | What gets set up |
|----------|-----------------|
| **13: Git & SSH** | `git config` identity + sane defaults, ed25519 SSH key generation |
| **8: Git Bash + Zsh** | Zsh extracted into Git for Windows, Oh My Zsh, Powerlevel10k, MesloLGS NF font, Windows Terminal profile, `.bashrc` auto-launch |
| **9: Oh My Posh** | PowerShell modules (Terminal-Icons, PSReadLine, Z), PS profile with aliases/functions, Clink for CMD, Oh My Posh prompt on all shells |
| **11: VS Code Extensions** | Installs extensions from `vscode-extensions.txt` in parallel |
| **12: Language Tooling** | npm globals (React/TS/ESLint/Prettier), Python pipx tools (uv/ruff/poetry), Rust stable + clippy + rust-analyzer, Go workspace, Maven + Gradle |

---

## The PowerShell Profile (Oh My Posh)

When you select category 9 (Oh My Posh), the setup writes a full PowerShell profile to both `Documents\PowerShell\` (PS 7) and `Documents\WindowsPowerShell\` (PS 5.1).

**What's in it:**

| Feature | Description |
|---------|-------------|
| Oh My Posh | `powerlevel10k_lean` theme with Nerd Font icons, git status, etc. |
| Terminal-Icons | File/folder type icons in `ls` / `Get-ChildItem` output |
| PSReadLine | Auto-complete from history, ListView predictions, Tab = MenuComplete |
| Z | Directory jumper -- `z Downloads` instead of `cd C:\Users\...\Downloads` |
| Aliases | `ll` `g` `grep` `ip` `tt` `which` `head` `tail` `touch` `mkcd` `df` `hosts` `envs` |
| curl/wget fix | Removes PS5's broken aliases that shadow real curl/wget |

**Change the Oh My Posh theme:**
```powershell
# List all available themes:
Get-PoshThemes

# Or browse: https://ohmyposh.dev/docs/themes

# Edit your profile to change the theme:
notepad $PROFILE
# Change the --config path to your preferred theme
```

---

## CMD Support (via Clink)

CMD doesn't support custom prompts natively. The setup installs [Clink](https://chrisant996.github.io/clink/) which supercharges CMD with:

- Oh My Posh prompt (same `powerlevel10k_lean` theme)
- Autosuggestions (like fish shell)
- Better tab completion

The config is at `%LOCALAPPDATA%\clink\oh-my-posh.lua`.

---

## Installed Packages

**Dev Tools:** Git, GitHub CLI, GitHub Desktop, GitHub Copilot, VS Code, Visual Studio Enterprise, JetBrains Toolbox, Docker Desktop, Warp, Oh My Posh, Clink, VS 2022 Build Tools

**Languages:** Python 3.14, Node.js LTS + NVM, .NET SDK 10, Java (Temurin 17 + 21), Go, Rust (rustup), LLVM, MinGW, CMake, Ninja

**Cloud / CLI:** Azure CLI, PowerShell 7, Redis, WSL + Ubuntu 24.04

**Browsers:** Chrome, Firefox, Edge (pre-installed)

**Productivity:** Teams, Office 365, OneDrive, Google Drive, Adobe Reader

**Media / Misc:** VLC, Unity Hub, Samsung SmartSwitch, YubiKey Manager, Remote Help

**Runtimes:** .NET Desktop/AspNetCore 8, .NET Framework DevPack 4, VCRedist 2015+, ODBC 17, SQL CLR Types

---

## Default Terminal Options

The setup asks which shell should open when you launch Windows Terminal:

| Option | What happens |
|--------|-------------|
| **1. Git Bash + Zsh** | Git Bash profile with `exec zsh`, Powerlevel10k prompt, elevated by default |
| **2. PowerShell 7** | `pwsh.exe` with Oh My Posh + PSReadLine + Terminal-Icons |
| **3. PowerShell 5** | `powershell.exe` (built-in) with Oh My Posh |
| **4. Command Prompt** | `cmd.exe` with Clink + Oh My Posh |
| **5. Keep current** | Don't change the default |

All profiles get the MesloLGS NF font applied automatically. The Git Bash profile is always created (even if not default) so it's available in the dropdown.

---

## Logging

One log file per run, plus per-package logs:

```
Windows\logs\20260426-125500\
  setup.log              <-- everything in one file
  packages\
    Git.Git.log
    Docker.DockerDesktop.log
    ...
```

---

## Running Individual Scripts

```powershell
# Just install packages:
.\restore.ps1

# Just install packages, preview only:
.\restore.ps1 -WhatIfMode

# Just enable Windows features:
.\Enable-WindowsFeatures.ps1

# Enable Windows features + IIS:
.\Enable-WindowsFeatures.ps1 -IncludeIIS

# Disable Hyper-V (for VirtualBox users):
.\Enable-WindowsFeatures.ps1 -IncludeHyperV:$false

# Self-sign scripts (optional, for AllSigned policy):
.\Sign-Scripts.ps1

# Run Phase 2 standalone from Git Bash:
chmod +x bootstrap-dev.sh
./bootstrap-dev.sh
```

---

## Customizing the Package List

Edit `winget-packages.json` to add or remove packages. The format is standard winget export:

```json
{
    "PackageIdentifier": "YourApp.Name"
}
```

Find package IDs: `winget search <name>` or browse https://winget.run

After editing, the next `.\Setup.cmd` run will install the new packages and skip existing ones.

---

## Updating Bundled Files

After you've customized your machine, save your current state back into the repo:

```powershell
# Snapshot installed packages:
winget export -o winget-packages.json --accept-source-agreements

# Snapshot VS Code extensions:
code --list-extensions > vscode-extensions.txt
```

```bash
# Re-bundle zsh (if you upgraded it):
cd "/c/Program Files/Git"
tar czf /path/to/System-Setup/Windows/zsh-gitbash.tar.gz \
    usr/bin/zsh.exe usr/bin/zsh-5.9.exe usr/bin/msys-zsh-5.9.dll \
    usr/share/zsh etc/zsh usr/lib/zsh

# Save dotfiles:
cp ~/.zshrc   /path/to/System-Setup/Windows/zshrc-template
cp ~/.p10k.zsh /path/to/System-Setup/Windows/p10k-template
```

---

## Design Decisions

- **Idempotent** -- every step checks if it's already done before acting. Safe to re-run.
- **Single log file** -- `setup.log` captures everything via PowerShell transcript.
- **Fail-loud, recover-gracefully** -- failures are reported with log paths. The script continues so you don't have to restart from scratch.
- **PS 5.1 compatible** -- all `.ps1` files are pure ASCII (no Unicode that breaks the default parser).
- **No curl-pipe-bash** -- all bundled files live in the repo (except Oh My Zsh's official installer).
- **Security hygiene** -- dangerous Windows features (SMB1, Telnet, PS v2) are deliberately not enabled.
