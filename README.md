# System-Setup

**Move your dev setup to a new machine, or build one from scratch.**

Download one file. Double-click. Pick what you want. Done.

---

## Download

**[Download Setup.exe (v1.1.2)](https://github.com/sdeepanshu13/System-Setup/releases/download/v1.1.2/Setup.exe)**

One file. Nothing to extract, no scripts to run, no configuration. Everything it
needs is bundled inside and cleaned up afterwards.

*Other versions: [all releases](https://github.com/sdeepanshu13/System-Setup/releases).
Always take the newest -- older builds don't have the backup/restore flow.*

> **Check you got the right file.** It should be **~4.1 MB (4299447 bytes)**.
> If yours is smaller, it's an older build -- delete it and download again.
> ```powershell
> (Get-Item "$env:USERPROFILE\Downloads\Setup.exe").Length
> ```

---

## "Windows protected your PC"

You'll see this on first run:

> Microsoft Defender SmartScreen prevented an unrecognized app from starting.
> **Publisher: Unknown publisher**

**This is expected, and it isn't a virus warning.** SmartScreen shows it for any
program that isn't signed with a paid code-signing certificate, regardless of
what the program does.

**To run it:** click **More info**, then **Run anyway**.

If you'd rather verify the file first, compare its hash against `SHA256SUMS.txt`
on the [release page](https://github.com/sdeepanshu13/System-Setup/releases):

```powershell
Get-FileHash "$env:USERPROFILE\Downloads\Setup.exe" -Algorithm SHA256
```

The prompt fades away as more people download a given build and SmartScreen
gathers reputation, and it disappears entirely once the app is signed with a
certificate from a trusted authority -- see
[code signing](Windows/README.md#code-signing).

> Don't disable Defender or add exclusions to get around this. Click through the
> prompt, or verify the hash if you want certainty.

---

## How to use

Double-click `Setup.exe` and approve the Administrator prompt. It asks one
question first:

| Choose this | When | What happens |
|-------------|------|--------------|
| **This is my OLD machine** | You're moving off this PC | Saves a list of your apps and repo folders |
| **This is my NEW machine** | You just got this PC | Signs you in and puts everything back |
| **Just set up this machine** | Fresh start, nothing to restore | Pick from a catalogue of ~55 dev tools |

Then tick what you want (**Select All** / **Deselect All** are there), click
install, and reboot once at the end.

---

## Moving to a new machine

### On your old machine

1. Run `Setup.exe` and choose **"This is my OLD machine"**
2. It scans what's installed -- **games are skipped automatically**
3. Add the folders where you keep code (add as many as you like -- most people
   have repos in more than one place)
4. Review the list and untick anything you don't want to carry over
5. Enter your **email** and a **passphrase**, then type the code we email you
6. Done -- your setup is saved, encrypted

### On your new machine

1. Run `Setup.exe` and choose **"This is my NEW machine"**
2. Enter the **same email + passphrase**, and the code we email you
3. Tick what you want back
4. It installs your apps and clones your repositories

Anything already installed is skipped, so it's safe to run more than once.

---

## What's actually saved

| Saved | Not saved |
|-------|-----------|
| App names and package IDs | Your documents or code |
| App versions | Passwords or credentials |
| Repo name, remote URL, branch | Repo contents |
| Which tools/settings you picked | Browser history, email, anything personal |

**Only applications and settings.** Your files are never read or uploaded.

**Your data is encrypted before it leaves your machine** using your passphrase
(AES-256). Nobody else can read it -- not other users, and not whoever runs the
database. The trade-off: **if you forget your passphrase there is no recovery**,
because the passphrase *is* the key.

Don't want any of this? Click **Skip** and use it as a plain installer.

---

## On a Mac

```bash
git clone https://github.com/sdeepanshu13/System-Setup.git
cd System-Setup/Mac && chmod +x Setup.sh && ./Setup.sh
```

Installs Homebrew and everything else for you. Sign in with the same email you
used on Windows and your saved settings come across.

See [Mac/README.md](Mac/README.md) for details.

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

- Windows 10 or 11 (or macOS for the Mac installer)
- Internet connection
- Administrator account -- the installer asks for permission automatically

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **SmartScreen warning** | Click **More info** > **Run anyway**. The build is unsigned -- see [code signing](Windows/README.md#code-signing) if you want to sign your own. |
| Weird symbols in the terminal | Set your terminal font to **MesloLGS NF** |
| A package failed to install | Just run `Setup.exe` again. Anything already installed is skipped. |
| WSL not working | Reboot -- it needs a restart to activate. |
| Want to change what's installed | Run it again and pick **"Just set up this machine"**. |
| **Forgot my passphrase** | There's no recovery -- it *is* the encryption key. Start again with a new email or passphrase. |
| "Couldn't send code" | Check spam. Otherwise click **Skip** and use it as a plain installer. |
| An app didn't come back | Only apps with a known package ID can be reinstalled automatically. The rest are listed in your backup for reference. |
| A repo didn't clone | Repos with no remote are skipped -- there's nothing to clone from. |
| Nothing happens on double-click | Right-click > **Properties** > tick **Unblock**, then try again. |

---

## For developers

| | |
|---|---|
| [Windows/README.md](Windows/README.md) | Architecture, wizard internals, error triage |
| [Mac/README.md](Mac/README.md) | macOS installer and Homebrew catalogue |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to add packages or contribute |

Adding an app needs no code -- just an entry in
[winget-packages.json](Windows/winget-packages.json) or
[brew-packages.json](Mac/brew-packages.json).

---

## License

MIT
