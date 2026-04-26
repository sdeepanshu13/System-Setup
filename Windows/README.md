# Windows Setup -- Technical Reference

For user-facing docs, see the [main README](../README.md).

---

## Architecture

```
User double-clicks Setup.exe (or Setup.cmd)
  |
  +--> Auto-elevates to Administrator
  +--> Starts logging (setup.log)
  |
  +--> Setup-UI.ps1 (GUI)
  |      |
  |      +--> Returns: selected winget package IDs
  |      +--> Returns: selected feature flags
  |      +--> Returns: default terminal choice (1-5)
  |
  +--> Phase 1: restore.ps1
  |      +--> winget source reset + update (120s timeout)
  |      +--> Skip already-installed packages
  |      +--> Priority installs: Git, Terminal, PS7, gh (sequential)
  |      +--> Everything else in parallel (throttle 5)
  |      +--> Per-package logs in packages/*.log
  |
  +--> Phase 1b: Enable-WindowsFeatures.ps1
  |      +--> Only features selected in GUI
  |
  +--> Phase 2: bootstrap-dev.sh (via Git Bash)
         +--> Git config + SSH key
         +--> Zsh + Oh My Zsh + Powerlevel10k + MesloLGS NF
         +--> Oh My Posh for PowerShell (profile + modules)
         +--> Oh My Posh for CMD (Clink + lua)
         +--> Windows Terminal default profile
         +--> VS Code extensions
         +--> Language tooling (npm, pipx, rust, go, maven, gradle)
```

---

## GUI Details (Setup-UI.ps1)

Windows Forms app, dark theme. Every item is its own checkbox.

**Section: SOFTWARE PACKAGES** -- sub-headings with individual checkboxes:

| Sub-heading | Checkboxes (each separate) |
|-------------|--------------------------|
| Developer Tools & IDEs | Git, GitHub CLI, GitHub Desktop, GitHub Copilot, VS Code, Visual Studio, JetBrains, Docker, Warp, Build Tools |
| Programming Languages | Python 3.14, Python Launcher, Node.js LTS, NVM, .NET SDK 10, Java 21, Java 17, Go, Rust, LLVM, MinGW, CMake, Ninja |
| Web Browsers | Chrome, Firefox |
| Cloud & CLI Tools | Azure CLI, PowerShell 7, Windows Terminal, Redis, WSL, Ubuntu, Azure VPN |
| Office & Productivity | Teams, Office, OneDrive, Google Drive, Adobe Reader |
| Media & Utilities | VLC, Unity Hub, Samsung SmartSwitch, YubiKey Manager, YubiKey Driver, Remote Help |
| Runtimes & Libraries | .NET Desktop 8, .NET AspNet 8, .NET FW DevPack, VCRedist x64, VCRedist x86, WebDeploy, ODBC 17, SQL CLR Types |
| Shell & Prompt | Oh My Posh, Clink |

**Section: SETUP & CONFIGURATION** -- sub-headings with individual checkboxes:

| Sub-heading | Checkboxes (each separate) |
|-------------|--------------------------|
| Shell Setup | Zsh + OMZ + P10k, OMP for PowerShell, OMP for CMD, Nerd Font |
| Windows Features | WSL2, Hyper-V, Containers, Sandbox, .NET 3.5, Hypervisor Platform |
| Dev Environment | Git + SSH, VS Code Ext, npm globals, pipx tools, Rust, Go, Maven, Gradle |

**Section: DEFAULT TERMINAL** -- radio buttons: Git Bash+Zsh / PS7 / PS5 / CMD / Keep current

---

## Environment Variables (internal)

| Variable | Set by | Used by | Example |
|----------|--------|---------|---------|
| `SETUP_SELECTED_PACKAGES` | Setup-UI.ps1 | restore.ps1 | `Git.Git,Docker.DockerDesktop` |
| `SETUP_FEATURES` | Setup-UI.ps1 | bootstrap-dev.sh | `zsh,omp,gitssh,vscode,npm` |
| `SETUP_DEFAULT_SHELL` | Setup-UI.ps1 | bootstrap-dev.sh | `1` |
| `SETUP_CATEGORIES` | Setup-UI.ps1 | bootstrap-dev.sh (compat) | `1,2,8,9,13` |
| `SETUP_RUN_LOG_DIR` | Setup.ps1 | restore.ps1 | `C:\...\logs\20260426-1255` |
| `SETUP_SKIP_PHASE1` | Setup.ps1 | bootstrap-dev.sh | `1` |
| `SETUP_GIT_NAME` | Setup.ps1 | bootstrap-dev.sh | `Jane Doe` |
| `SETUP_GIT_EMAIL` | Setup.ps1 | bootstrap-dev.sh | `jane@example.com` |

---

## Feature Flags

bootstrap-dev.sh checks these via `feature_enabled <flag>`:

| Flag | Controls |
|------|----------|
| `zsh` | Zsh install, Oh My Zsh, Powerlevel10k, .bashrc chain |
| `omp` | PowerShell profile (OMP, Terminal-Icons, PSReadLine, Z, aliases) |
| `ompcmd` | CMD via Clink + oh-my-posh.lua |
| `nerdfont` | MesloLGS Nerd Font download + install |
| `gitssh` | Git identity + SSH key |
| `vscode` | VS Code extension restore |
| `npm` | Global npm packages |
| `pipx` | Python tools via pipx |
| `rust` | Rust stable + components |
| `golang` | Go workspace + GOPATH |
| `maven` | Apache Maven |
| `gradle` | Gradle |
| `wsl` | WSL + VMP feature |
| `hyperv` | Hyper-V feature |
| `containers` | Containers feature |
| `sandbox` | Windows Sandbox feature |
| `netfx3` | .NET 3.5 feature |
| `hypplat` | Hypervisor Platform feature |

---

## PowerShell Profile (Oh My Posh)

Written to both `Documents\PowerShell\` (PS7) and `Documents\WindowsPowerShell\` (PS5):

| Feature | Details |
|---------|---------|
| Oh My Posh | `powerlevel10k_lean` theme |
| Terminal-Icons | File type icons in `ls` |
| PSReadLine | History prediction, ListView, MenuComplete, arrow filtering |
| Z | Directory jumper |
| Aliases | `ll` `g` `grep` `which` `head` `tail` `mkcd` `touch` `hosts` `df` `envs` |

---

## Logging

```
Windows\logs\20260426-125500\
  setup.log           <-- single file, everything
  packages\
    Git.Git.log        <-- per-package winget output
    Docker.DockerDesktop.log
```

---

## Building Setup.exe

```powershell
cd Windows
Install-Module ps2exe -Scope CurrentUser   # one-time
.\Build-Exe.ps1
# Output: ..\dist\Setup.exe (~3 MB)
```

Build-Exe.ps1:
1. Reads all 12 files (text as here-strings, zsh tarball as base64)
2. Wraps in a launcher that extracts to `%TEMP%`, runs Setup.ps1, cleans up
3. Compiles with ps2exe (`requireAdmin = $true`)

---

## Design Decisions

| Decision | Reason |
|----------|--------|
| Every item is separate | User asked for it. No clubbing. |
| PS 5.1 compatible | Fresh Windows has PS 5.1 only |
| All .ps1 files are ASCII | PS 5.1 without BOM chokes on Unicode |
| Single log file | No confusion about which log to check |
| `--ignore-security-hash` | winget manifest hashes lag upstream releases |
| `winget settings --enable InstallerHashOverride` | Required on winget 1.28+ |
| Priority packages sequential | Git must exist before Phase 2 |
| Transcript `trap` blocks | Guarantees log closure on error/ctrl-c |
| `$userChoice` not `$input` | `$input` is a reserved automatic variable |
| `$(if (...) {...} else {...})` | Ternary `if` is PS7-only |
| SMB1/Telnet not enabled | Security hygiene |
| dist/ in .gitignore | Exe goes to Releases, not the repo |
