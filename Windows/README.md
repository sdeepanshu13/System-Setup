# Windows Setup

Automated, **production-ready** setup for a fresh Windows 10/11 dev machine. **One command** installs ~55 apps in parallel, enables Windows features (WSL/Hyper-V/Sandbox), configures Git Bash + zsh + Powerlevel10k, generates an SSH key, and sets up a polyglot dev environment (Node/React, Python, Java, Go, Rust, .NET, C/C++).

---

## What's Included

| File                        | Purpose                                                                          |
| --------------------------- | -------------------------------------------------------------------------------- |
| `Setup.cmd`                 | One-click launcher (avoids execution-policy issues)                              |
| `Setup.ps1`                 | **Universal entry point** — auto-elevates, runs Phase 1 + 1b + 2, single log dir |
| `restore.ps1`               | Phase 1 — installs all winget packages in parallel (skips already-installed)     |
| `Enable-WindowsFeatures.ps1`| Phase 1b — enables WSL, Hyper-V, Containers, Windows Sandbox, .NET 3.5, etc.     |
| `bootstrap-dev.sh`          | Phase 2 — Git config, SSH key, zsh, oh-my-zsh, p10k, fonts, dotfiles, dev tools  |
| `Sign-Scripts.ps1`          | Optional — self-sign all `.ps1` files for stricter execution policies            |
| `winget-packages.json`      | List of winget packages to install                                               |
| `vscode-extensions.txt`     | List of VS Code extensions to restore                                            |
| `zshrc-template`            | Optimized `.zshrc` for Git Bash + Powerlevel10k                                  |
| `p10k-template`             | Powerlevel10k config (`~/.p10k.zsh`)                                             |
| `zsh-gitbash.tar.gz`        | Bundled zsh binaries + DLLs that get extracted into `C:\Program Files\Git`       |

---

## Prerequisites

- Windows 10 / 11
- [winget](https://aka.ms/getwinget) (bundled with App Installer from the Microsoft Store on modern Windows)
- Internet connection
- An **Administrator** account — every script auto-elevates via UAC if needed.

---

## Quick Start — pick your shell

> **Fresh Windows install?** Only PowerShell and Command Prompt are available out of the box. Git Bash is installed as part of Phase 1, so use **Option A** or **Option B** for the first run.

### Option A — `Setup.cmd` (recommended)

Double-click `Setup.cmd` in Explorer, or run from any shell:
```cmd
.\Setup.cmd
```
This wrapper calls `Setup.ps1` with `-ExecutionPolicy Bypass`, so you never see the *"file is not digitally signed"* error.

Pre-fill Git config to run **fully unattended**:
```cmd
.\Setup.cmd -GitName "Jane Doe" -GitEmail "jane@example.com"
```

### Option B — PowerShell directly

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

If you just type `.\Setup.ps1` and get **"file ... is not digitally signed"**, do one of:
```powershell
Unblock-File .\Setup.ps1; .\Setup.ps1
# or
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
.\Setup.ps1
```

### Option C — Command Prompt (cmd.exe)

```cmd
cd C:\path\to\System-Setup\Windows
.\Setup.cmd
```

### Option D — Git Bash (only if Git for Windows is already installed)

```bash
cd /c/path/to/System-Setup/Windows
chmod +x bootstrap-dev.sh
./bootstrap-dev.sh
```

> **Do not run from WSL.** The script targets the Windows side (winget, Windows Terminal, Git for Windows). Use Option A from PowerShell instead.

### Don't have `git` yet?

If you're on a brand-new machine without Git, you have two options to get the repo onto the box:

1. **Install Git first**, then clone:
   ```powershell
   winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
   git clone https://github.com/sdeepanshu13/System-Setup.git
   cd System-Setup\Windows
   .\Setup.cmd
   ```
2. **Download the ZIP** from https://github.com/sdeepanshu13/System-Setup → "Code" → "Download ZIP", extract it, then run `.\Setup.cmd` from the `Windows` folder.

---

## What runs in each phase

### Phase 1 — winget packages ([restore.ps1](restore.ps1))
1. Auto-elevates to Administrator.
2. Resets + refreshes the winget source cache (with a 120 s hard timeout so a stalled CDN can't hang the run).
3. Pre-flight: snapshots installed packages and **skips already-installed** items (also probes disk for Git/VS Code/etc. that don't show up in `winget list`).
4. **Phase A** — installs priority packages sequentially (`Git.Git`, `GitHub.cli`, `Microsoft.WindowsTerminal`, `Microsoft.PowerShell`).
5. **Phase B** — installs everything else **in parallel** (default 5 at a time, configurable with `-Throttle`). Uses `Start-ThreadJob` if available, falls back to `Start-Job`.
6. Hash-mismatch packages are auto-handled with `--ignore-security-hash`.
7. If `Git.Git` is somehow still missing after Phase 1, `Setup.ps1` falls back to downloading the official Git for Windows installer directly from GitHub releases (with a 5-minute download timeout).

**Bundled package categories** (`winget-packages.json`):
- **Dev Tools**: VS Code, Visual Studio Enterprise, JetBrains Toolbox, GitHub Desktop, GitHub Copilot, Docker Desktop, Warp, VS 2022 Build Tools
- **Languages**: Python 3.14, Node.js LTS + NVM, .NET SDK 10, Go, Rust (rustup), Java (Temurin 17 + 21), LLVM, MinGW, CMake, Ninja, Maven, Gradle
- **CLI / Infra**: Azure CLI, PowerShell 7, Redis, WSL + Ubuntu 24.04
- **Browsers**: Chrome, Firefox, Edge
- **Productivity**: Teams, Office, OneDrive, Google Drive, Adobe Reader
- **Media / Misc**: VLC, Unity Hub, Yubico, Samsung Smart Switch
- **Runtimes**: .NET DesktopRuntime 8, AspNetCore 8, .NET Framework Dev Pack 4, VCRedist 2015+

### Phase 1b — Windows Optional Features ([Enable-WindowsFeatures.ps1](Enable-WindowsFeatures.ps1))
Enables (idempotent — already-on features are skipped):
- **WSL** + Virtual Machine Platform (then `wsl --set-default-version 2` and `wsl --update`)
- **Hyper-V** (full)
- **Hypervisor Platform** (Docker / Android emulators)
- **Containers**
- **Windows Sandbox**
- **.NET 3.5** + .NET 4 advanced services
- **Print to PDF / XPS Services**
- **Media Playback**

Deliberately **NOT** enabled (security hygiene): SMB1, Telnet, TFTP, SimpleTCP, DirectPlay, PowerShell v2, Internet Explorer.

### Phase 2 — Dev environment ([bootstrap-dev.sh](bootstrap-dev.sh))
| # | Action |
|---|--------|
| 1 | `git config` identity + sane defaults (`init.defaultBranch=main`, `pull.rebase=true`, `core.autocrlf=true`, etc.) |
| 2 | Generates ed25519 SSH key (skipped if already present) and writes pubkey to `github-ssh-pubkey.txt` |
| 3 | Extracts bundled `zsh-gitbash.tar.gz` into `C:\Program Files\Git` (auto-elevates if needed) |
| 4 | Installs Oh My Zsh (idempotent) |
| 5 | Clones Powerlevel10k + zsh-autosuggestions + zsh-syntax-highlighting (shallow) |
| 6 | Downloads & installs MesloLGS Nerd Font (4 weights) |
| 7 | Deploys `~/.zshrc` and `~/.p10k.zsh` from templates (with backup-on-diff) |
| 8 | Adds **Git Bash** profile to Windows Terminal, sets it as **default**, sets `elevate: true` so it always launches as admin, applies MesloLGS NF font to all profiles |
| 8b | Adds `exec zsh` + UTF-8 codepage to `~/.bashrc` and writes a matching `~/.bash_profile` (idempotent, marker-guarded) |
| 9 | Restores VS Code extensions from `vscode-extensions.txt` (parallel, throttled) |
| 10 | Installs Node.js LTS via nvm (if installed) |
| 10b | Installs global npm packages: `yarn`, `pnpm`, `typescript`, `ts-node`, `eslint`, `prettier`, `nodemon`, `serve`, `create-react-app`, `create-next-app`, `create-vite`, `vercel`, `wrangler`, `npm-check-updates` |
| 10c | Installs Python tools via `pipx`: `uv`, `ruff`, `black`, `httpie`, `poetry`, `virtualenv` |
| 10d | Installs Rust `stable` toolchain + `rustfmt`, `clippy`, `rust-analyzer` |
| 10e | Initializes Go workspace (`~/go/{bin,src,pkg}`) and sets `GOPATH` |

---

## Logging

Every run produces a single timestamped folder under `Windows\logs\`:
```
Windows\logs\20260426-115500\
├── setup.log              ← Setup.ps1 + everything it called
├── restore.log            ← Phase 1 winget transcript
├── bootstrap-dev.log      ← Phase 2 bash output
└── packages\
    ├── Git.Git.log
    ├── Microsoft.VisualStudioCode.log
    └── ...
```
Transcripts are guaranteed-closed via `trap` blocks even on errors, ctrl-c, or early exits — you can always re-run cleanly.

---

## Common Operations

```powershell
# Skip Phase 1 (winget already done) — useful for re-running Phase 2 only:
.\Setup.cmd -SkipPhase1

# Skip Phase 2 (just install software):
.\Setup.cmd -SkipPhase2

# Faster parallelism (more memory used, fewer minutes):
.\Setup.cmd -Throttle 8

# Preview packages without installing:
.\restore.ps1 -WhatIfMode

# Enable Windows Features only:
.\Enable-WindowsFeatures.ps1                       # default: WSL + Hyper-V + Sandbox
.\Enable-WindowsFeatures.ps1 -IncludeIIS           # also IIS
.\Enable-WindowsFeatures.ps1 -IncludeHyperV:$false # if you use VirtualBox/Android Studio

# Self-sign all .ps1 scripts (optional, for AllSigned policy):
.\Sign-Scripts.ps1
```

---

## After Setup Completes

1. **Reboot once** — Windows Features (WSL, Hyper-V, Sandbox) require a restart to finalize.
2. **Close all Windows Terminal windows** and reopen — the Git Bash default profile + `elevate: true` + MesloLGS NF font kick in only on a fresh launch.
3. **Add the SSH key to GitHub**: https://github.com/settings/ssh/new
   - The public key is also printed at the end of the run for direct copy-paste, and saved to `Windows\github-ssh-pubkey.txt`.
4. Run `p10k configure` if you want to re-tune the Powerlevel10k prompt; otherwise the bundled `~/.p10k.zsh` is used.
5. Sign into Chrome, Docker Desktop, JetBrains Toolbox, VS Code (Settings Sync), etc.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `is not digitally signed` when running `.ps1` | Use `Setup.cmd` instead, or `Unblock-File .\Setup.ps1` |
| `zsh.exe: error while loading shared libraries: msys-zsh-5.9.dll` | Old `zsh-gitbash.tar.gz` bundle — re-pull and rerun `.\Setup.cmd -SkipPhase1` |
| Windows Terminal still uses old font / profile | Close **all** Terminal windows first, then reopen — settings are loaded once at startup |
| `MSYSTEM: unbound variable` | You ran `bootstrap-dev.sh` from WSL. Run from Git Bash, or use `Setup.cmd` from PowerShell |
| A winget package fails | Check `logs\<latest>\packages\<PackageId>.log`. Most failures are transient — just rerun `Setup.cmd`; already-installed packages are skipped |
| `Git.Git` keeps failing with hash mismatch | Already mitigated with `--ignore-security-hash`; if it still fails, `Setup.ps1` Phase 2 will download the installer directly from git-scm.com |
| Hyper-V conflicts with VirtualBox / Android emulator | Run `.\Enable-WindowsFeatures.ps1 -IncludeHyperV:$false` and reboot |
| Script appears stuck on "Refreshing winget sources" | Hard timeout of 120 s now applies; if you see this on an old version, pull the latest |

---

## Updating the bundled artifacts

Re-export your current state into the repo:

```powershell
# winget packages snapshot
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
cp ~/.zshrc    /c/path/to/System-Setup/Windows/zshrc-template
cp ~/.p10k.zsh /c/path/to/System-Setup/Windows/p10k-template
```

---

## Design Notes

- **Idempotent end-to-end** — every step checks "is this already done?" before acting. Re-running is always safe.
- **Single log directory per run** — `Setup.ps1`, `restore.ps1`, and `bootstrap-dev.sh` all write into the same timestamped folder.
- **Fail-loud, recover-gracefully** — Phase 1 failures are reported clearly with log paths; Phase 2 has its own Git fallback so it can still finish.
- **No hidden state** — all bundled files (zsh, dotfiles, package list) live in the repo; no curl-piped-to-bash from random URLs (except Oh My Zsh's official installer).
- **Security hygiene** — SMB1, Telnet, PowerShell v2, and other deprecated/insecure features are explicitly **not** enabled.
