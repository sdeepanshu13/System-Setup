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