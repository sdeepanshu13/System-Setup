# Windows Setup

Automated setup scripts for a fresh Windows dev machine. One command installs all software, configures Git Bash with Zsh + Powerlevel10k, generates SSH keys, restores VS Code extensions, and more.

## What's Included

| File | Purpose |
|------|---------|
| `bootstrap-dev.sh` | Main entry point — runs everything in order |
| `restore.ps1` | Installs all software via `winget import` |
| `winget-packages.json` | List of 49 winget packages (dev tools, languages, browsers, etc.) |
| `vscode-extensions.txt` | 41 VS Code extensions to restore |
| `zshrc-template` | Optimized `.zshrc` for Git Bash with Powerlevel10k |

## Prerequisites

- **Windows 10/11** with [winget](https://aka.ms/getwinget) installed (comes with App Installer from the Microsoft Store)
- **Git for Windows** — needed to run Git Bash. If not already installed, get it from https://gitforwindows.org or run:
  ```
  winget install Git.Git
  ```
- **Administrator privileges** — required for font installation and winget imports

## Quick Start

1. **Clone the repo** (from Git Bash or PowerShell):
   ```bash
   git clone https://github.com/sdeepanshu13/System-Setup.git
   cd System-Setup/Windows
   ```

2. **Run the bootstrap script** (Git Bash as Administrator):
   ```bash
   chmod +x bootstrap-dev.sh
   ./bootstrap-dev.sh
   ```

3. **Follow the prompts** — the script will ask for your name and email (for Git config + SSH key).

4. **After completion**:
   - Close and reopen Git Bash — Zsh starts automatically
   - Run `p10k configure` to customize your prompt
   - Add the generated SSH key to GitHub: https://github.com/settings/ssh/new
   - Set terminal font to **MesloLGS NF**

## What the Bootstrap Script Does

| Step | Action |
|------|--------|
| 0 | Installs all winget packages via `restore.ps1` |
| 1 | Installs Oh My Zsh |
| 2 | Installs Powerlevel10k theme |
| 3 | Installs zsh-autosuggestions plugin |
| 4 | Installs zsh-syntax-highlighting plugin |
| 5 | Downloads & installs MesloLGS Nerd Font |
| 6 | Deploys optimized `.zshrc` |
| 7 | Configures `.bashrc` to auto-launch Zsh |
| 8 | Sets Git defaults (`init.defaultBranch main`, `pull.rebase true`, etc.) |
| 9 | Generates ed25519 SSH key & saves public key to file |
| 10 | Installs VS Code extensions from `vscode-extensions.txt` |
| 11 | Installs Node.js LTS via nvm |
| 12 | Configures Windows Terminal font (if installed) |

## Running Individual Scripts

**Install software only** (PowerShell as Administrator):
```powershell
.\restore.ps1
```

**Preview what would be installed** (dry run):
```powershell
.\restore.ps1 -WhatIfMode
```

## Customizing

- **Add/remove winget packages**: Edit `winget-packages.json`
- **Add/remove VS Code extensions**: Edit `vscode-extensions.txt` (one extension ID per line)
- **Change shell config**: Edit `zshrc-template`

## Updating the Package List

To re-export your current system's packages:
```powershell
winget export -o winget-packages.json --accept-source-agreements
```

To re-export VS Code extensions:
```bash
code --list-extensions > vscode-extensions.txt
```
