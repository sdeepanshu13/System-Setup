# System-Setup

> **One command to set up a brand-new Windows dev machine.** Pick what you want, sit back, and let it run.

![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6?logo=windows)

## What it does

You run **one script**. It shows you a menu. You pick what you want. It does everything else:

- Installs **~55 apps** (browsers, editors, languages, Docker, Office, etc.) in parallel via winget
- Enables **Windows features** (WSL2, Hyper-V, Containers, Windows Sandbox)
- Sets up a **beautiful terminal** with Oh My Posh / Powerlevel10k + Nerd Font on every shell (PowerShell, CMD, Git Bash + Zsh)
- Installs a **full dev stack** (Node/React, Python, Java, Go, Rust, .NET, C/C++)
- Generates an **SSH key** for GitHub and prints it for you to copy
- Restores your **VS Code extensions**
- Lets you **choose your default terminal** (Git Bash, PowerShell 7, PowerShell 5, or CMD)

Everything is idempotent -- re-running is always safe. Already-installed packages are skipped.

---

## Quick Start

### Step 1: Get the files onto your machine

**Option A -- Download ZIP (no git needed):**
1. Go to https://github.com/sdeepanshu13/System-Setup
2. Click **Code** > **Download ZIP**
3. Extract it somewhere (e.g. `C:\System-Setup`)

**Option B -- Clone (if you already have git):**
```powershell
git clone https://github.com/sdeepanshu13/System-Setup.git
cd System-Setup\Windows
```

### Step 2: Run it

**Double-click `Setup.cmd`** in the `Windows` folder. That's it.

Or from any terminal:
```
.\Setup.cmd
```

It will:
1. Ask for Administrator permission (UAC prompt)
2. Show you an **interactive menu** to pick what to install
3. Ask which **default terminal** you want
4. Install everything automatically

### Step 3: Reboot once

Some Windows features (WSL, Hyper-V, Sandbox) need a restart. After the reboot, open Windows Terminal -- your chosen shell with the fancy prompt is ready.

---

## The Interactive Menu

When Setup runs, you see this:

```
  =============================================
    Windows Dev Machine Setup - Configuration
  =============================================

  [x]  1. Developer Tools & IDEs     Git, VS Code, Visual Studio, Docker...
  [x]  2. Programming Languages      Python, Node, Java, Go, Rust, C/C++...
  [x]  3. Web Browsers               Chrome, Firefox
  [x]  4. Cloud & CLI Tools          Azure CLI, PowerShell 7, WSL + Ubuntu
  [x]  5. Office & Productivity      Teams, Office, OneDrive, Google Drive
  [x]  6. Media & Utilities          VLC, Unity Hub, Samsung, YubiKey
  [x]  7. Runtimes & Libraries       .NET runtimes, VCRedist, ODBC drivers
  [x]  8. Shell: Git Bash + Zsh      Oh My Zsh + Powerlevel10k + Nerd Font
  [x]  9. Shell: Oh My Posh          Fancy prompt for PowerShell & CMD
  [x] 10. Windows Features           WSL2, Hyper-V, Containers, Sandbox
  [x] 11. VS Code Extensions         Restore from vscode-extensions.txt
  [x] 12. Language Tooling            npm globals, pipx tools, Rust, Maven
  [x] 13. Git Config & SSH Key       Git identity + ed25519 SSH key

  Commands:  a = select all   n = select none   go = start   q = quit
```

Type a number to toggle it off. Type `go` when ready. Then pick your default terminal:

```
  1. Git Bash + Zsh       (recommended)
  2. PowerShell 7
  3. PowerShell 5
  4. Command Prompt
  5. Keep current
```

---

## Platforms

| Platform | Status |
|----------|--------|
| Windows 10/11 | Ready |
| Mac | Planned |

---

## Common Commands

```powershell
# Run with all defaults (no menu, installs everything):
.\Setup.cmd -Unattended

# Skip software install, only set up shell/dotfiles:
.\Setup.cmd -SkipPhase1

# Skip shell setup, only install software:
.\Setup.cmd -SkipPhase2

# Pre-fill git identity (fully unattended):
.\Setup.cmd -GitName "Jane Doe" -GitEmail "jane@example.com" -Unattended

# Install faster (more parallel downloads):
.\Setup.cmd -Throttle 8

# Preview what would be installed without doing it:
.\restore.ps1 -WhatIfMode

# Just enable Windows Features:
.\Enable-WindowsFeatures.ps1
```

---

## What's in the box

| File | What it does |
|------|-------------|
| `Setup.cmd` | One-click launcher. Double-click this. |
| `Setup.ps1` | The brain. Shows menu, runs everything, logs everything. |
| `restore.ps1` | Installs winget packages in parallel. |
| `Enable-WindowsFeatures.ps1` | Enables WSL, Hyper-V, Sandbox, etc. |
| `bootstrap-dev.sh` | Sets up Git, SSH, Zsh, Oh My Posh, dev tools (runs in Git Bash). |
| `Sign-Scripts.ps1` | Optional: self-sign scripts for strict execution policies. |
| `winget-packages.json` | The list of ~55 apps to install. |
| `vscode-extensions.txt` | VS Code extensions to restore. |
| `zshrc-template` | Your `.zshrc` for Git Bash + Powerlevel10k. |
| `p10k-template` | Powerlevel10k config. |
| `zsh-gitbash.tar.gz` | Bundled zsh binaries for Git Bash. |

---

## After Setup

1. **Reboot** -- Windows features need it.
2. **Open Windows Terminal** -- your chosen shell + fancy prompt is the default.
3. **Add SSH key to GitHub** -- the public key was printed at the end and saved to `github-ssh-pubkey.txt`. Go to https://github.com/settings/ssh/new
4. **Sign into apps** -- Chrome, Docker, JetBrains, VS Code Settings Sync, etc.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "File is not digitally signed" | Use `Setup.cmd` (not `Setup.ps1` directly) |
| Weird font characters in terminal | Set font to **MesloLGS NF** in terminal settings |
| Winget package failed | Check `logs\<timestamp>\packages\<Package>.log` and re-run |
| Git Bash not appearing in Terminal | Re-run `.\Setup.cmd -SkipPhase1` |
| WSL not working after install | Reboot first. WSL features need a restart. |
| "MSYSTEM: unbound variable" | Don't run bootstrap-dev.sh from WSL. Use Setup.cmd. |

---

## Updating Your Package List

After installing new apps or extensions, snapshot your current state:

```powershell
winget export -o winget-packages.json --accept-source-agreements
code --list-extensions > vscode-extensions.txt
```

---

## License

MIT
