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
  +--> Setup-Wizard.ps1  -- "which machine is this?"
  |      |
  |      +-- OLD machine  --> Setup-Flows.ps1 :: Invoke-BackupFlow
  |      |     +--> InventoryScanner: installed apps (games filtered out)
  |      |     +--> repo folder picker (several locations)
  |      |     +--> review checklist (Select All / Deselect All)
  |      |     +--> sign in: email -> OTP -> passphrase
  |      |     +--> encrypted save, then exit
  |      |
  |      +-- NEW machine  --> Setup-Flows.ps1 :: Invoke-RestoreFlow
  |      |     +--> sign in: email -> OTP -> passphrase
  |      |     +--> review what's stored (apps / settings / repos)
  |      |     +--> feeds SETUP_SELECTED_PACKAGES + SETUP_FEATURES
  |      |
  |      +-- Fresh setup --> Setup-UI.ps1 (standard catalogue)
  |
  +--> Phase 1: restore.ps1        (winget, per-package logs)
  +--> Phase 1b: Enable-WindowsFeatures.ps1
  +--> Phase 2: bootstrap-dev.sh   (shell, dotfiles, SSH, tooling)
  +--> Restore-Repositories        (git clone, restore mode only)
  +--> ErrorReporter.Flush()       (queued failures -> setup_errors)
```

---

## Backup & restore

| File | Role |
|------|------|
| `Setup-Wizard.ps1` | Dialogs only -- mode chooser, checklist, repo picker, sign-in |
| `Setup-Flows.ps1` | Sequencing -- backup flow, restore flow, repo cloning |
| `Shared/Modules/SetupInventory.psm1` | App inventory + repo discovery |

UI and flow logic are kept apart so the sequencing can be reasoned about without
touching WinForms.

**What gets backed up:** application identities (name, package id, version) and
repository *metadata* (name, remote URL, branch). Never file contents.

**What's excluded:** games and launchers (Steam, Epic, Riot, Battle.net, ...),
Windows updates/hotfixes, and anything whose install path sits under a game
library. Runtimes and drivers are detected but unticked by default, since they
normally arrive as dependencies.

Apps without a package id can't be reinstalled automatically -- they're recorded
for reference and unticked by default.

**Restore** skips anything already installed, then clones selected repositories
into `%USERPROFILE%\source\repos` (repos without a remote are skipped).

---

## Error reporting

Failures are pushed to `setup_errors` with phase and package context. Reporting
never throws: if the network or auth is unavailable the row is queued in memory
and flushed at the end, so telemetry can't break an install.

Clients may **insert** but never **select** -- otherwise users would see each
other's machine names and paths. Triage is owner-only:

```powershell
$env:SUPABASE_SERVICE_KEY = '<secret key>'    # never commit or ship this
./Shared/Admin/Get-SetupErrors.ps1            # open errors, newest first
./Shared/Admin/Get-SetupErrors.ps1 -Summary   # grouped by message
./Shared/Admin/Get-SetupErrors.ps1 -Resolve 42
./Shared/Admin/Get-SetupErrors.ps1 -PurgeResolved
```

The script refuses to run without `SUPABASE_SERVICE_KEY` in the environment.

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

## Shared core (`Shared/`)

Database settings and profile logic live outside `Windows/` so macOS uses the
same implementation. Runs on Windows PowerShell 5.1 and pwsh 7+ (macOS/Linux).

```
Shared/
  Config/supabase-config.json     <- connection settings (obfuscated)
  Database/supabase-schema.sql    <- table + RLS policies
  Modules/SetupCore.psm1          <- all classes
  Protect-Config.ps1              <- regenerate the config
  profiles/                       <- offline encrypted profiles
```

### Class design

| Class | Responsibility |
|-------|----------------|
| `SetupCrypto` | AES-256-CBC + HMAC-SHA256 + PBKDF2 (static) |
| `SetupPaths` | resolves shared folders on any OS |
| `UserIdentity` | normalises email/mobile, derives the hashed key |
| `ProfileData` | payload model + JSON mapping |
| `SupabaseConfig` | loads/decrypts settings, rejects secret keys |
| `SupabaseClient` | REST transport (auth + rows) |
| `ProfileStore` | abstract contract |
| `SupabaseProfileStore` / `LocalProfileStore` | the two backends |
| `OtpService` / `OtpChallenge` | offline OTP delivery + verification |
| `ProfileManager` | facade used by the installers |

Callers use the `New-*` factory functions instead of `using module`, so the
module loads from any path (including the extracted exe).

```powershell
Import-Module Shared\Modules\SetupCore.psm1
$m = New-ProfileManager
$m.BeginVerification('you@example.com')
$m.CompleteVerification('123456')
$m.SaveProfile($passphrase, (New-ProfileData -Packages @('Git.Git')))
```

Swapping backends means adding one `ProfileStore` subclass -- nothing else changes.

---

## User Profiles (encrypted, cross-platform)

The first screen (`Show-ProfileLoginDialog` in `Setup-UI.ps1`) lets a user save
their selections and restore them on any machine.

There are two backends. Supabase is used automatically when configured;
otherwise it falls back to encrypted files synced through git.

| | Supabase (default) | Offline fallback |
|---|---|---|
| Storage | `public.user_profiles` table | `Shared/profiles/<hash>.json` |
| OTP | Supabase Auth, **verified server-side** | generated locally (bypassable) |
| Sync | any user, any machine | needs git push access |
| Delivery config | none -- built in | your SMTP/Twilio creds |

### Supabase setup (one-time)

1. Run [`supabase-schema.sql`](../Shared/Database/supabase-schema.sql) in
   Dashboard -> SQL Editor. It creates `user_profiles` and RLS policies scoped
   to `auth.uid()`.
2. `Shared/Config/supabase-config.json` holds the project URL + **publishable**
   key, stored obfuscated. Regenerate with
   `pwsh ./Shared/Protect-Config.ps1 -Url ... -PublishableKey ...`.
   Override at runtime with `SETUP_SUPABASE_URL` / `SETUP_SUPABASE_KEY`.
3. For volume, set a custom SMTP provider in Auth settings -- the built-in mailer
   is rate-limited to a few messages per hour.

#### Key safety

| Key | Where it may live |
|-----|-------------------|
| Publishable (`sb_publishable_...`) | shipped in the app -- safe, RLS protects the data |
| Secret / service-role (`sb_secret_...`) | **server-side only** -- never in this repo or the exe |

A service-role key bypasses every RLS policy: anyone who extracts it can read,
alter, or delete all users' rows. Client-side encryption cannot protect it,
because the app must decrypt it to use it -- so the unlock key ships too. It is
also unnecessary: OTP and profile read/write all work with the publishable key
plus the user's JWT.

Guards in place: `Get-SupabaseConfig` refuses any key that looks like a secret,
`.gitignore` blocks `.env*`, and the release workflow fails the build if
`sb_secret`/`service_role` appears in the compiled exe.

The config obfuscation stops bots scraping the public repo; it is not secrecy,
and the publishable key doesn't need it to be.

---

## Single-file distribution

`Build-Exe.ps1` base64-embeds every script into one `Setup.exe` (ps2exe,
`requireAdmin`). At runtime it extracts to a randomly named temp folder, runs,
and deletes it in a `finally` block -- so users get one file and no loose scripts.

`.github/workflows/release.yml` builds it on `windows-latest`, scans the binary
for secret keys, and attaches it to the GitHub Release. Publish with:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

> ps2exe bundles PowerShell source; it deters casual inspection but is not
> tamper-proof. Don't rely on it to hide anything that must stay secret.

---

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
`Shared/Config/.otp-config.json` -- never hard-coded:

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

## Code signing

`Sign-Exe.ps1` signs `dist\Setup.exe`. `Build-Exe.ps1` calls it automatically and
**skips quietly when no certificate is present**, so unsigned builds still work.

Certificate resolution order:

1. `-PfxPath <file.pfx>`
2. `CODE_SIGN_PFX_BASE64` environment variable (CI)
3. an installed cert in `CurrentUser\My` matching `-Subject`
4. `-SelfSigned` -- creates one on the fly

Passwords come from `CODE_SIGN_PASSWORD` or a SecureString prompt. They are
never passed as arguments and never logged.

### What actually clears SmartScreen

| Approach | Cost | Effect |
|----------|------|--------|
| Unsigned | free | Warning until reputation builds |
| **Self-signed** | free | **Still warns.** Shows "Unknown Publisher" -- the chain terminates in an untrusted root |
| OV certificate | ~$200-400/yr | Warning at first, clears as downloads accumulate |
| **EV certificate** | ~$300-600/yr | **Clears immediately** |

Self-signing only helps where you control the machines: export `CodeSigning.cer`
and push it to **Trusted Publishers** (GPO or Intune). For public downloads,
nothing but a CA-issued certificate helps.

### Signing in CI

Add two repository secrets and the release workflow signs automatically:

| Secret | Value |
|--------|-------|
| `CODE_SIGN_PFX_BASE64` | `[Convert]::ToBase64String([IO.File]::ReadAllBytes('cert.pfx'))` |
| `CODE_SIGN_PASSWORD` | the .pfx password |

Without them the workflow builds unsigned and emits a warning, so forks aren't
blocked. Signatures are timestamped, so they stay valid after the certificate
expires.

---

## Single-file distribution

`Build-Installer.ps1` compiles `installer.iss` with Inno Setup into one
`Setup.exe`. Files extract to `{tmp}`, the setup runs, and nothing is left on
disk -- no install directory, no uninstaller, no registry entries.

```powershell
cd Windows
.\Build-Installer.ps1 -Version 1.2.0
```

`Build-Exe.ps1` (ps2exe) is kept for reference but is no longer used by CI.

### Antivirus behaviour

The installer bundles PowerShell that inventories installed software and
uploads an encrypted profile. To an ML classifier that reads as
*collect system data -> encrypt -> send to a remote server*, which is the
infostealer pattern -- so unsigned builds get flagged
(`Trojan:Win32/Wacatac.C!ml`, `Phonzy.B!ml`) and sometimes quarantined on
download.

Findings from testing:

| | Result |
|---|---|
| Locally built, with Mark-of-the-Web | clean |
| Same version downloaded from a release | quarantined |
| ps2exe vs Inno Setup | **both flagged** -- packaging isn't the cause |

Only **code signing** reliably fixes this; see [code signing](#code-signing).
Releases are cut from tags rather than every push so a build isn't perpetually
brand new, which is what these classifiers penalise most.

Running from a clone (`Windows\Setup.cmd`) avoids the issue entirely.

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
