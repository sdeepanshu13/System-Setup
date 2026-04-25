# System-Setup

Automated scripts to set up a fresh dev machine from scratch — software, shell, fonts, SSH keys, VS Code extensions, and more.

## Platforms

| Platform | Status | Docs |
|----------|--------|------|
| [Windows](Windows/) | ✅ Ready | [Windows/README.md](Windows/README.md) |
| [Mac](Mac/) | 🚧 Planned | [Mac/README.md](Mac/README.md) |

## Quick Start (Windows)

Clone the repo first:

```bash
git clone https://github.com/sdeepanshu13/System-Setup.git
cd System-Setup/Windows
```

Then run **one** of the following — they all do the same thing. `Setup.ps1` auto-elevates via UAC.

**PowerShell** (recommended):
```powershell
.\Setup.ps1
```

**Command Prompt** (`cmd.exe`):
```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

**Git Bash**:
```bash
chmod +x bootstrap-dev.sh
./bootstrap-dev.sh
```

**Fully unattended** (skip the Git name/email prompt):
```powershell
.\Setup.ps1 -GitName "Jane Doe" -GitEmail "jane@example.com"
```

See [Windows/README.md](Windows/README.md) for prerequisites, troubleshooting, and how to update the bundled artifacts.