# macOS Setup -- Technical Reference

For user-facing docs, see the [main README](../README.md).

---

## Quick start

```bash
git clone https://github.com/sdeepanshu13/System-Setup.git
cd System-Setup/Mac
chmod +x Setup.sh
./Setup.sh
```

`Setup.sh` installs Xcode Command Line Tools, Homebrew and PowerShell if they're
missing, then hands over to `Setup.ps1`.

---

## Architecture

```
./Setup.sh
  |
  +--> Xcode Command Line Tools (if missing)
  +--> Homebrew (if missing)
  +--> PowerShell via brew cask (if missing)
  |
  +--> Setup.ps1 (pwsh)
         |
         +--> Setup-UI.ps1 (console)
         |      +--> profile sign-in (email/mobile -> OTP -> passphrase)
         |      +--> package selector  (brew-packages.json)
         |      +--> feature selector
         |
         +--> Phase 1: brew install (formulae + casks, per-package logs)
         +--> Phase 2: bootstrap-mac.sh
         |      +--> git config + SSH key (Apple keychain)
         |      +--> Oh My Zsh + Powerlevel10k + plugins
         |      +--> VS Code extensions
         |      +--> npm / pipx / rust / go / maven / gradle
         |      +--> macOS defaults (Dock, Finder, keyboard)
         |
         +--> save encrypted profile
```

---

## Shared with Windows

Profiles, OTP and encryption come from [`Shared/Modules/SetupCore.psm1`](../Shared/Modules/SetupCore.psm1),
so selections saved on Windows load here and vice-versa. Database settings live
in [`Shared/Config`](../Shared/Config) -- see the
[Windows reference](../Windows/README.md#shared-core-shared) for the class design.

macOS also reuses `Windows/zshrc-template`, `Windows/p10k-template` and
`Windows/vscode-extensions.txt`.

---

## Files

| File | Purpose |
|------|---------|
| `Setup.sh` | Entry point; installs brew + pwsh, then runs Setup.ps1 |
| `Setup.ps1` | Orchestrator: selection, brew install, Phase 2, profile save |
| `Setup-UI.ps1` | Console UI (sign-in + numbered toggle selectors) |
| `brew-packages.json` | Package catalogue (`formula` = CLI, `cask` = GUI) |
| `bootstrap-mac.sh` | Shell, dotfiles, SSH key, language tooling, macOS defaults |

---

## Console UI

Both selectors accept:

| Input | Action |
|-------|--------|
| `5` | toggle item 5 |
| `1,3,7` | toggle several |
| `2-6` | toggle a range |
| `a` / `n` | select all / deselect all |
| `go` | continue |
| `q` | quit |

---

## Feature Flags

`bootstrap-mac.sh` checks these via `feature_enabled <flag>`:

| Flag | Controls |
|------|----------|
| `zsh` | Oh My Zsh, Powerlevel10k, `.zshrc` / `.p10k.zsh` |
| `zshplugins` | zsh-autosuggestions, zsh-syntax-highlighting |
| `gitssh` | Git identity + ed25519 key (added to Apple keychain) |
| `vscode` | VS Code extension restore |
| `npm` | Global npm packages |
| `pipx` | Python tools (uv, ruff, poetry, black, httpie) |
| `rust` | Rust stable + clippy + rustfmt + rust-analyzer |
| `golang` | GOPATH + workspace folders |
| `maven` / `gradle` | Build tools via brew |
| `macdefaults` | Dock, Finder, keyboard, screenshot location |
| `xcodeclt` | Xcode Command Line Tools |

---

## Options

```bash
pwsh ./Setup.ps1 -Unattended        # catalogue defaults, no prompts
pwsh ./Setup.ps1 -SkipPackages      # Phase 2 only
pwsh ./Setup.ps1 -SkipBootstrap     # packages only
pwsh ./Setup.ps1 -GitName "Jane Doe" -GitEmail jane@example.com
```

Logs land in `Mac/logs/<timestamp>/` with `packages/*.log` per formula/cask.

---

## Adding a package

Add an entry to `brew-packages.json` -- no code changes:

```json
{ "name": "Neovim", "id": "neovim", "type": "formula", "default": true }
```

Use `"type": "cask"` for GUI apps. Verify the name with `brew info <id>`.
