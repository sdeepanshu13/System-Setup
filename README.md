# System-Setup

Automated scripts to set up a fresh dev machine from scratch — software, shell, fonts, SSH keys, VS Code extensions, and more.

## Platforms

| Platform | Status | Docs |
|----------|--------|------|
| [Windows](Windows/) | ✅ Ready | [Windows/README.md](Windows/README.md) |
| [Mac](Mac/) | 🚧 Planned | [Mac/README.md](Mac/README.md) |

## Quick Start (Windows)

> **On a fresh Windows install, only PowerShell and Command Prompt are available.** Git Bash is installed automatically by Phase 1 — so use one of those two for the first run.

Clone the repo first (PowerShell, CMD, or just download the ZIP from GitHub):

```powershell
git clone https://github.com/sdeepanshu13/System-Setup.git
cd System-Setup\Windows
```

> No `git` yet? `winget install Git.Git` first, **or** download the repo as a ZIP from GitHub and extract it.

Then run **one** of the following — they all do the same thing. `Setup.ps1` auto-elevates via UAC.

**Easiest — just double-click `Setup.cmd`** in Explorer, or run from CMD/PowerShell:
```cmd
.\Setup.cmd
```
This wrapper avoids the PowerShell execution-policy prompt.

**PowerShell** (use the bypass form to avoid the "file is not digitally signed" error):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

**Command Prompt** (`cmd.exe`):
```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

**Git Bash** (only if Git for Windows is already installed):
```bash
chmod +x bootstrap-dev.sh
./bootstrap-dev.sh
```

**Fully unattended** (skip the Git name/email prompt):
```cmd
.\Setup.cmd -GitName "Jane Doe" -GitEmail "jane@example.com"
```

See [Windows/README.md](Windows/README.md) for prerequisites, troubleshooting, and how to update the bundled artifacts.

## Highlights

- **One command** — no babysitting. Auto-elevates, parallel installs, idempotent re-runs.
- **~55 winget apps** — Git, VS Code, Visual Studio, JetBrains Toolbox, Docker, Chrome, Office, Teams, etc.
- **Polyglot dev stack** — Node + npm globals (React, TS, ESLint…), Python + pipx tools (uv, ruff, poetry…), Java (Temurin 17/21 + Maven/Gradle), Go, Rust (rustup + clippy + rust-analyzer), .NET SDK 10, C/C++ (LLVM, MinGW, CMake, Ninja, MSVC Build Tools).
- **Windows features** — WSL2, Hyper-V, Containers, Windows Sandbox, .NET 3.5 enabled in one shot.
- **Shell** — Git Bash + zsh + Oh My Zsh + Powerlevel10k + MesloLGS Nerd Font, set as the elevated default in Windows Terminal.
- **SSH key** — ed25519 generated and printed for direct copy-paste into GitHub.
- **One log folder per run** — `Windows\logs\<timestamp>\` with `setup.log`, `restore.log`, `bootstrap-dev.log`, plus per-package winget logs.
- **Production-ready** — guaranteed transcript closure, network timeouts on every external call, hash-mismatch resilience, fail-loud error reporting.