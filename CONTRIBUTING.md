# Contributing

Developer documentation for maintaining and building System-Setup.

---

## Repo Structure

```
.github/workflows/build-release.yml   <-- CI/CD: auto-builds Setup.exe on push
Windows/
  Setup.cmd              <-- Entry point (source users)
  Setup.ps1              <-- Main orchestrator
  Setup-UI.ps1           <-- GUI (Windows Forms)
  restore.ps1            <-- Parallel winget installer
  Enable-WindowsFeatures.ps1
  bootstrap-dev.sh       <-- Shell + dev setup (Git Bash)
  Build-Exe.ps1          <-- Compiles Setup.exe
  Sign-Scripts.ps1       <-- Optional code signing
  winget-packages.json   <-- Package manifest
  vscode-extensions.txt  <-- VS Code extensions
  zshrc-template         <-- .zshrc for Powerlevel10k
  p10k-template          <-- Powerlevel10k config
  zsh-gitbash.tar.gz     <-- Bundled zsh binaries (~2 MB)
  README.md              <-- Technical reference
```

---

## CI/CD Pipeline

Every push to `main` triggers `.github/workflows/build-release.yml`:

1. Checks out code on a `windows-latest` runner
2. Installs `ps2exe` module
3. Runs `Build-Exe.ps1` to produce `dist/Setup.exe`
4. Creates a GitHub Release with auto-incremented version tag (`v1.0.N`)
5. Attaches `Setup.exe` to the release

The release marked `latest` is always the most recent build. The download link in README always points to the latest.

**No manual steps needed.** Push to main = new release.

---

## Local Development

### Running from source

```powershell
cd Windows
.\Setup.cmd                    # interactive with GUI
.\Setup.cmd -Unattended        # install everything, no GUI
.\Setup.cmd -SkipPhase2        # only winget packages
.\Setup.cmd -SkipPhase1        # only shell/dev setup
.\Setup.cmd -Throttle 8        # faster parallel installs
```

### Building the exe locally

```powershell
cd Windows
Install-Module ps2exe -Scope CurrentUser   # one-time
.\Build-Exe.ps1
# Output: ..\dist\Setup.exe (~3 MB)
```

### Testing the GUI only

```powershell
.\Setup-UI.ps1
```

---

## Adding/Removing Packages

Edit `winget-packages.json`. Each entry:
```json
{ "PackageIdentifier": "Publisher.AppName" }
```

Find IDs: `winget search <name>` or [winget.run](https://winget.run)

The GUI (Setup-UI.ps1) has its own package list -- update both files when adding.

To snapshot your current installed apps:
```powershell
winget export -o winget-packages.json --accept-source-agreements
```

---

## Adding/Removing VS Code Extensions

Edit `vscode-extensions.txt` (one extension ID per line).

To snapshot current extensions:
```powershell
code --list-extensions > vscode-extensions.txt
```

---

## Updating Zsh Bundle

```bash
cd "/c/Program Files/Git"
tar czf /path/to/Windows/zsh-gitbash.tar.gz \
    usr/bin/zsh.exe usr/bin/zsh-5.9.exe usr/bin/msys-zsh-5.9.dll \
    usr/share/zsh etc/zsh usr/lib/zsh
```

---

## Key Design Constraints

| Constraint | Why |
|-----------|-----|
| All .ps1 files must be pure ASCII | PowerShell 5.1 without BOM chokes on Unicode |
| Use `$(if (...) {...} else {...})` not `if (...) {...} else {...}` in expressions | Ternary `if` is PS7-only |
| Don't use `$input` as a variable name | Reserved automatic variable |
| Use `@()` around pipeline results assigned to arrays | PS collapses single-element arrays to scalars |
| `winget settings --enable InstallerHashOverride` before `--ignore-security-hash` | Required on winget 1.28+ |
| `dist/` is in `.gitignore` | Exe goes to Releases via CI, not in the repo |

---

## Technical Reference

See [Windows/README.md](Windows/README.md) for architecture, environment variables, feature flags, and profile details.
