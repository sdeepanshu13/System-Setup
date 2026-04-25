# Windows Setup

Automated setup for a fresh Windows dev machine. **One command** installs ~50 apps, configures Git Bash + zsh + Powerlevel10k, generates an SSH key, restores VS Code extensions, and sets up Windows Terminal.

## What's Included

| File                     | Purpose                                                                            |
| ------------------------ | ---------------------------------------------------------------------------------- |
| `Setup.ps1`              | **Universal entry point** — auto-elevates, runs Phase 1 + Phase 2                  |
| `restore.ps1`            | Phase 1 — installs all winget packages in parallel (skips already-installed)       |
| `bootstrap-dev.sh`       | Phase 2 — Git config, SSH key, zsh, oh-my-zsh, p10k, fonts, dotfiles, VS Code      |
| `winget-packages.json`   | List of winget packages to install                                                 |
| `vscode-extensions.txt`  | List of VS Code extensions to restore                                              |
| `zshrc-template`         | Optimized `.zshrc` for Git Bash + Powerlevel10k                                    |
| `p10k-template`          | Powerlevel10k config (`~/.p10k.zsh`)                                               |
| `zsh-gitbash.tar.gz`     | Bundled zsh binaries + DLLs that get extracted into `C:\Program Files\Git`         |

## Prerequisites

- Windows 10 / 11
- [winget](https://aka.ms/getwinget) (comes with App Installer from the Microsoft Store)
- Internet connection
- An **Administrator** account — `Setup.ps1` auto-elevates via UAC if needed.

## Quick Start — pick your shell

> **Fresh Windows install?** Only PowerShell and Command Prompt are available out of the box. Git Bash is installed automatically as part of Phase 1, so use **Option A** or **Option B** for the first run. Option C is only for machines where Git for Windows is already installed.

You can run the setup from **any** of the following. They all do the same thing.

### Option A — `Setup.cmd` (easiest, no exec-policy issues)

Double-click `Setup.cmd` in Explorer, or run from any shell:
```cmd
.\Setup.cmd
```
This is a tiny wrapper that calls `Setup.ps1` with `-ExecutionPolicy Bypass`, so you never see the *"file is not digitally signed"* error.

Pre-fill Git config to run **fully unattended**:
```cmd
.\Setup.cmd -GitName "Jane Doe" -GitEmail "jane@example.com"
```

### Option B — PowerShell directly

Fresh Windows blocks unsigned scripts by default, so use the bypass form:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

If you just type `.\Setup.ps1` and get **"file ... cannot be loaded ... is not digitally signed"**, do one of:
```powershell
# Unblock the downloaded file (per-file):
Unblock-File .\Setup.ps1; .\Setup.ps1

# Or relax policy for the current user once (per-user):
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
.\Setup.ps1
```

### Option C — Command Prompt (cmd.exe)

```cmd
cd C:\path\to\System-Setup\Windows
.\Setup.cmd
```

Or without the wrapper:
```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

### Option D — Git Bash (only if Git for Windows is already installed)

```bash
cd /c/path/to/System-Setup/Windows
chmod +x bootstrap-dev.sh
./bootstrap-dev.sh
```

Pre-fill Git config via env vars:
```bash
SETUP_GIT_NAME="Jane Doe" SETUP_GIT_EMAIL="jane@example.com" ./bootstrap-dev.sh
```

### Option E — Windows Terminal / Warp / pwsh

Same as Option A or B — the script doesn't care which terminal hosts it.

> **Note:** Do **not** run from WSL. The script targets the Windows side (winget, Windows Terminal, Git for Windows). Use one of the options above instead.

### Don't have `git` yet?

If you're on a brand-new machine without Git, you have two options to get the repo onto the box:

1. **Install Git first**, then clone:
   ```powershell
   winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
   git clone https://github.com/sdeepanshu13/System-Setup.git
   cd System-Setup\Windows
   .\Setup.ps1
   ```
2. **Download the ZIP** from https://github.com/sdeepanshu13/System-Setup → "Code" → "Download ZIP", extract it, then run `.\Setup.ps1` from the `Windows` folder.

---

## What runs in each phase

**Phase 1** ([restore.ps1](restore.ps1)) — auto-elevates, then:
1. Snapshots `winget list` and **skips already-installed** packages.
2. Installs priority packages **sequentially** so they're available immediately:
   `Git.Git`, `GitHub.cli`, `Microsoft.WindowsTerminal`, `Microsoft.PowerShell`.
3. Installs everything else **in parallel** (default 5 at a time, configurable with `-Throttle`).
4. Logs everything to `Windows\logs\<timestamp>\` (full transcript + per-package logs).

**Phase 2** ([bootstrap-dev.sh](bootstrap-dev.sh)) — runs through Git Bash:
| # | Action |
|---|--------|
| 1 | `git config` identity + sane defaults (`init.defaultBranch=main`, `pull.rebase=true`, etc.) |
| 2 | Generates ed25519 SSH key + writes pubkey to `github-ssh-pubkey.txt` |
| 3 | Extracts bundled `zsh-gitbash.tar.gz` into `C:\Program Files\Git` |
| 4 | Installs Oh My Zsh (idempotent) |
| 5 | Clones Powerlevel10k + zsh-autosuggestions + zsh-syntax-highlighting |
| 6 | Downloads & installs MesloLGS Nerd Font (4 weights) |
| 7 | Deploys `~/.zshrc` and `~/.p10k.zsh` from templates (with backup-on-diff) |
| 8 | Adds **Git Bash** profile to Windows Terminal, sets it as **default**, applies MesloLGS NF font to all profiles |
| 8b | Adds `exec zsh` + UTF-8 codepage to `~/.bashrc` (idempotent, marker-guarded) |
| 9 | Restores VS Code extensions from `vscode-extensions.txt` (parallel) |
| 10 | Installs Node.js LTS via nvm (if nvm is installed) |

## Common Operations

```powershell
# Just install software, skip dotfile setup:
.\Setup.ps1 -SkipPhase2

# Just dotfiles, skip winget (everything already installed):
.\Setup.ps1 -SkipPhase1

# Faster parallelism:
.\Setup.ps1 -Throttle 8

# Preview what would be installed:
.\restore.ps1 -WhatIfMode

# Force the old sequential `winget import` behavior:
.\restore.ps1 -Sequential
```

## After Setup Completes

1. **Close all Windows Terminal windows** and reopen — the new default profile + font kick in only on a fresh launch.
2. **Add the SSH key to GitHub**: https://github.com/settings/ssh/new
   The public key is saved to `Windows\github-ssh-pubkey.txt`.
3. Run `p10k configure` if you want to re-tune the prompt; otherwise the bundled `~/.p10k.zsh` is used.
4. Sign into Chrome, Docker, JetBrains Toolbox, VS Code (Settings Sync), etc.

## Troubleshooting

- **"zsh.exe: error while loading shared libraries: msys-zsh-5.9.dll"** — Old `zsh-gitbash.tar.gz` bundle. Re-pull and re-run `.\Setup.ps1 -SkipPhase1`.
- **Windows Terminal still uses old font / profile** — Close *all* Terminal windows first, then reopen. Settings are loaded once at startup.
- **Script crashes with "MSYSTEM: unbound variable"** — You ran `bootstrap-dev.sh` from WSL. Run it from Git Bash instead, or use `Setup.ps1` from PowerShell.
- **A winget package fails** — Check `Windows\logs\<timestamp>\packages\<PackageId>.log`. Most failures are transient — just rerun `Setup.ps1`; already-installed packages are skipped.

## Updating the bundled artifacts

Re-export your current state into the repo:

```powershell
# winget packages
winget export -o winget-packages.json --accept-source-agreements

# VS Code extensions
code --list-extensions > vscode-extensions.txt
```

```bash
# Bundle the current zsh + DLLs from Git Bash:
cd "/c/Program Files/Git" && tar czf /c/path/to/System-Setup/Windows/zsh-gitbash.tar.gz \
    usr/bin/zsh.exe usr/bin/zsh-5.9.exe usr/bin/msys-zsh-5.9.dll \
    usr/share/zsh etc/zsh usr/lib/zsh

# Snapshot current dotfiles:
cp ~/.zshrc   /c/path/to/System-Setup/Windows/zshrc-template
cp ~/.p10k.zsh /c/path/to/System-Setup/Windows/p10k-template
```
