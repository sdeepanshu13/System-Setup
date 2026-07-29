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
  |      +--> Profile login: email/mobile + passphrase + OTP verify (optional)
  |      +--> Loads saved selections (encrypted) if that profile exists
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

The bottom bar has **Select All** / **Deselect All** buttons that toggle every
package and feature checkbox at once.

---

## User Profiles (encrypted, git-synced)

The first screen (`Show-ProfileLoginDialog` in `Setup-UI.ps1`) lets a user save
their selections and restore them on any machine. Logic lives in
`UserProfile.ps1` (crypto + local store), `SupabaseStore.ps1` (online store +
server-side OTP) and `Otp.ps1` (offline OTP).

There are two backends. Supabase is used automatically when configured;
otherwise it falls back to encrypted JSON files synced through git.

| | Supabase (default) | Offline fallback |
|---|---|---|
| Storage | `public.user_profiles` table | `Windows\users\<hash>.json` |
| OTP | Supabase Auth, **verified server-side** | generated locally (bypassable) |
| Sync | any user, any machine | needs git push access |
| Delivery config | none -- built in | your SMTP/Twilio creds |

### Supabase setup (one-time)

1. Run [`supabase-schema.sql`](supabase-schema.sql) in Dashboard -> SQL Editor.
   It creates `user_profiles` and RLS policies scoped to `auth.uid()`.
2. `supabase-config.json` holds the project URL + **publishable** key. Override
   with `SETUP_SUPABASE_URL` / `SETUP_SUPABASE_KEY`.
3. For volume, set a custom SMTP provider in Auth settings -- the built-in mailer
   is rate-limited to a few messages per hour.

> Never put the **secret / service-role** key in this repo or in `Setup.exe`. It
> bypasses RLS entirely. Only the publishable key is safe to ship.

Phone OTP additionally requires an SMS provider configured in Supabase Auth;
email works out of the box.

### Identity & lookup
- Primary key = the user's email or mobile, normalised (email lowercased, mobile
  reduced to digits, `+` prefixed for Supabase E.164).
- Offline mode file name = `SHA-256(normalised key)` (first 32 hex chars) -- the
  raw email/phone is never written to disk.
- Supabase mode keys rows by `auth.users.id` (uuid).

### Encryption (only the user can read it)
- Payload (name, packages, features, default shell) -> JSON -> **AES-256-CBC**.
- Key derived from the user's **passphrase** via **PBKDF2-SHA256** (200k
  iterations, random 16-byte salt).
- Integrity via **HMAC-SHA256** over IV+ciphertext (encrypt-then-MAC). A wrong
  passphrase or any tampering fails the MAC.
- The passphrase is never stored, logged, transmitted, or committed. The database
  only ever holds ciphertext -- the project owner cannot read user selections.

### Offline OTP delivery (fallback only)
Credentials come ONLY from env vars or a git-ignored
`Windows\users\.otp-config.json` -- never hard-coded:

| Channel | Variables |
|---------|-----------|
| Email (SMTP) | `SETUP_OTP_SMTP_HOST` `SETUP_OTP_SMTP_PORT` `SETUP_OTP_SMTP_USER` `SETUP_OTP_SMTP_PASS` `SETUP_OTP_SMTP_FROM` `SETUP_OTP_SMTP_SSL` |
| SMS (Twilio) | `SETUP_OTP_TWILIO_SID` `SETUP_OTP_TWILIO_TOKEN` `SETUP_OTP_TWILIO_FROM` |
| SMS (generic HTTP POST) | `SETUP_OTP_SMS_API_URL` `SETUP_OTP_SMS_API_KEY` `SETUP_OTP_SMS_FROM` |
| Local test | `SETUP_OTP_DEV=1` -> prints the code to console + git-ignored `.otp-dev.txt` |

A 6-digit code (crypto RNG) is generated; only its salted hash + expiry (5 min) +
attempt cap (5) are kept in memory. Users can always click **Skip**.

### Git sync (offline mode)
- `Publish-ProfileStore` git-adds ONLY the single `users\<hash>.json`, commits,
  and pushes (best-effort, never fatal). Logs / SSH keys are never staged.
- `Sync-ProfileStore` runs a best-effort `git pull --ff-only` before lookup.

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
| `SETUP_PROFILE_PATH` | Setup-UI.ps1 | Setup.ps1 | `...\Windows\users\ab12..json` |
| `SETUP_USER_NAME` | Setup-UI.ps1 | Setup.ps1 | `Jane Doe` |
| `SETUP_USER_EMAIL` | Setup-UI.ps1 | Setup.ps1 | `jane@example.com` |

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
