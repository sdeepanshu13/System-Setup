# System-Setup

**Set up a brand-new Windows dev machine in one click.**

Download. Double-click. Pick what you want. Done.

---

## Download

**[Download Setup.exe](https://github.com/sdeepanshu13/System-Setup/releases/latest/download/Setup.exe)** (3 MB)

---

## How to use

1. **Download** `Setup.exe` from the link above
2. **Double-click** it
3. **Allow** the admin prompt (UAC)
4. **Check/uncheck** what you want in the GUI
5. **Pick** your default terminal
6. **Click Install**
7. **Reboot** once when it finishes

That's it. Your machine is ready.

---

## What you get

A graphical installer where every item is a separate checkbox:

### Software (~55 apps, all optional)

| Category | Apps |
|----------|------|
| Dev Tools | Git, VS Code, Visual Studio, JetBrains Toolbox, Docker Desktop, GitHub Desktop, GitHub Copilot, Warp |
| Languages | Python, Node.js, Java 17 & 21, Go, Rust, .NET SDK, C/C++ (LLVM, CMake, Ninja) |
| Browsers | Chrome, Firefox |
| Cloud & CLI | Azure CLI, PowerShell 7, Windows Terminal, Redis, WSL + Ubuntu |
| Productivity | Teams, Office 365, OneDrive, Google Drive, Adobe Reader |
| Media | VLC, Unity Hub, Samsung SmartSwitch, YubiKey Manager |
| Runtimes | .NET 8, VCRedist, ODBC drivers |

### Terminal & Shell

| Option | What it sets up |
|--------|----------------|
| Git Bash + Zsh | Oh My Zsh + Powerlevel10k theme + MesloLGS Nerd Font |
| PowerShell | Oh My Posh prompt + Terminal-Icons + PSReadLine auto-complete + aliases |
| CMD | Oh My Posh via Clink + autosuggestions |

You choose which one becomes your default when you open Windows Terminal.

### Windows Features

Each is a separate checkbox:
- WSL2
- Hyper-V
- Windows Containers
- Windows Sandbox
- .NET Framework 3.5

### Dev Environment

Each is a separate checkbox:
- Git config + SSH key for GitHub
- VS Code extensions restore
- npm globals (React, TypeScript, ESLint, Prettier, Vite, etc.)
- Python tools (uv, ruff, poetry, black, httpie)
- Rust toolchain (stable + clippy + rust-analyzer)
- Go workspace
- Maven
- Gradle

---

## After setup

1. **Reboot** -- WSL and Hyper-V need a restart to activate
2. **Open Windows Terminal** -- your chosen shell with the fancy prompt is the default
3. **Add SSH key to GitHub** -- it was printed at the end of setup and saved to `github-ssh-pubkey.txt`. Paste it at https://github.com/settings/ssh/new
4. **Sign in to apps** -- Chrome, Docker, JetBrains, VS Code Settings Sync

---

## Requirements

- Windows 10 or 11
- Internet connection
- Administrator account (the installer asks for permission automatically)

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| SmartScreen warning | Click **More info** then **Run anyway** (the exe is unsigned) |
| Weird characters in terminal | Set your terminal font to **MesloLGS NF** |
| A package failed to install | Re-run Setup.exe. Already-installed packages are skipped automatically. |
| WSL not working | Reboot first. It needs a restart. |
| Need to change what's installed | Run Setup.exe again. Uncheck what you don't want. |

---

## License

MIT
