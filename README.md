# System-Setup

**One file. One click. Fully configured Windows dev machine.**

---

## For Users

### Download

Go to [**Releases**](https://github.com/sdeepanshu13/System-Setup/releases) and download **`Setup.exe`** (3 MB).

### Run

Double-click `Setup.exe`. That's it.

1. Windows asks for admin permission (UAC)
2. A GUI opens with checkboxes for everything you can install
3. Untick what you don't want
4. Pick your default terminal (Git Bash, PowerShell, CMD)
5. Click **Install**
6. Reboot once when done (for WSL/Hyper-V)

### What you can install

Every item below is a **separate checkbox** -- nothing is forced:

**Software** -- Git, VS Code, Visual Studio, JetBrains, Docker, Chrome, Firefox, Python, Node.js, Java, Go, Rust, .NET, C/C++ toolchain, Office, Teams, VLC, and more (~55 packages)

**Shell & Prompt** -- Git Bash + Zsh + Oh My Zsh + Powerlevel10k, Oh My Posh for PowerShell & CMD, MesloLGS Nerd Font

**Windows Features** -- WSL2, Hyper-V, Containers, Windows Sandbox, .NET 3.5 (each separate)

**Dev Tools** -- Git config + SSH key, VS Code extensions, npm globals (React/TS/ESLint), Python tools (uv/ruff/poetry), Rust toolchain, Go workspace, Maven, Gradle (each separate)

### After Setup

1. **Reboot** -- WSL and Hyper-V need it
2. **Open Windows Terminal** -- your chosen shell with the fancy prompt is ready
3. **Add SSH key to GitHub** -- it was printed at the end and saved to `github-ssh-pubkey.txt`

---

## For Developers / Contributors

### Repo Structure

```
System-Setup/
  .gitignore
  LICENSE
  README.md                        <-- you are here
  Mac/
    README.md                      <-- planned
  Windows/
    README.md                      <-- technical reference
    Setup.cmd                      <-- entry point (source users)
    Setup.ps1                      <-- main orchestrator
    Setup-UI.ps1                   <-- GUI (Windows Forms)
    restore.ps1                    <-- parallel winget installer
    Enable-WindowsFeatures.ps1     <-- WSL, Hyper-V, Sandbox, etc.
    bootstrap-dev.sh               <-- shell + dev setup (Git Bash)
    Build-Exe.ps1                  <-- compiles Setup.exe
    Sign-Scripts.ps1               <-- optional code signing
    winget-packages.json           <-- package manifest
    vscode-extensions.txt          <-- VS Code extensions
    zshrc-template                 <-- .zshrc for Powerlevel10k
    p10k-template                  <-- Powerlevel10k config
    zsh-gitbash.tar.gz             <-- bundled zsh binaries
```

**Not committed** (in `.gitignore`):
- `dist/` -- build output (`Setup.exe`). Uploaded to GitHub Releases, not the repo.
- `Windows/logs/` -- per-run log files
- Generated files (`github-ssh-pubkey.txt`, `CodeSigning.cer`)

### What to commit

Everything in the tree above. The only large binary is `zsh-gitbash.tar.gz` (~2 MB) which must be committed since it's bundled into the exe.

### Building Setup.exe

```powershell
cd Windows
Install-Module ps2exe -Scope CurrentUser   # one-time
.\Build-Exe.ps1
# Output: ..\dist\Setup.exe (3 MB)
```

The build script:
1. Embeds all scripts + configs + zsh tarball (base64) into one PowerShell script
2. Compiles it into `dist\Setup.exe` using ps2exe
3. The exe auto-elevates, extracts to `%TEMP%`, shows the GUI, runs setup, cleans up

### Making a Release

1. Make your changes in `Windows/`
2. Test by running `.\Setup.cmd` from source
3. Run `.\Build-Exe.ps1` to rebuild the exe
4. Commit + push
5. Create a GitHub Release, attach `dist\Setup.exe`

### Running from source (without the exe)

```powershell
# Double-click Setup.cmd, or:
cd Windows
.\Setup.cmd

# Or with PowerShell directly:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1

# Fully unattended (no GUI, installs everything):
.\Setup.cmd -Unattended

# Pre-fill git identity:
.\Setup.cmd -GitName "Jane Doe" -GitEmail "jane@example.com" -Unattended
```

### Updating package list

```powershell
winget export -o winget-packages.json --accept-source-agreements
code --list-extensions > vscode-extensions.txt
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| SmartScreen blocks Setup.exe | Right-click > Properties > Unblock, or "Run anyway" |
| "File is not digitally signed" | Use `Setup.cmd` or `Setup.exe` (not `.ps1` directly) |
| Weird font in terminal | Set font to **MesloLGS NF** in terminal settings |
| Package failed to install | Check `logs\<timestamp>\packages\<Id>.log` and re-run |
| WSL not working | Reboot first |
| GUI doesn't appear | Run `powershell -ExecutionPolicy Bypass -File .\Setup.ps1` |

---

## Platforms

| Platform | Status |
|----------|--------|
| Windows 10/11 | Ready |
| Mac | Planned |

## License

MIT
