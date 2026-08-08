<#
.SYNOPSIS
    Inventories what's installed on this machine, plus local git repositories.
.DESCRIPTION
    Backs up applications and settings only -- never game libraries, and never
    the contents of your files. Works on Windows (registry + winget) and macOS
    (Homebrew + /Applications).

    Classes:
        InstalledApp        one discovered application
        GitRepository       one discovered repo (path, remote, branch)
        InventoryScanner    the scanner itself

    Dot-sourced or imported by the installers; New-* factories keep callers
    free of `using module`.
#>

Set-StrictMode -Version Latest

$script:OnWindowsHost = $true
if (Test-Path -LiteralPath 'variable:global:IsWindows') {
    $script:OnWindowsHost = [bool](Get-Variable -Name IsWindows -Scope Global -ValueOnly)
}

class InstalledApp {
    [string] $Name
    [string] $Id          # winget / brew id when known
    [string] $Version
    [string] $Publisher
    [string] $Source      # winget | registry | brew | cask | app-bundle
    [string] $Kind        # app | runtime | driver
    [bool]   $Selected = $true

    [string] Display() {
        if ($this.Version) { return "$($this.Name)  ($($this.Version))" }
        return $this.Name
    }
}

class GitRepository {
    [string] $Name
    [string] $Path
    [string] $Remote
    [string] $Branch
    [bool]   $Dirty
    [bool]   $Selected = $true

    [string] Display() {
        $suffix = if ($this.Remote) { $this.Remote } else { '(no remote)' }
        return "$($this.Name) -> $suffix"
    }
}

class EnvironmentSetting {
    [string] $Name
    [string] $Flag        # feature flag the installer already understands
    [string] $Detail
    [bool]   $Selected = $true

    [string] Display() {
        if ($this.Detail) { return "$($this.Name)  --  $($this.Detail)" }
        return $this.Name
    }
}

class DotFile {
    [string] $Name        # logical name, e.g. '.zshrc'
    [string] $Path        # where it came from
    [string] $Target      # where to write it back, relative to the home dir
    [string] $Content
    [bool]   $Selected = $true

    [string] Display() {
        $kb = [Math]::Round(($this.Content.Length / 1KB), 1)
        return "$($this.Name)  ($kb KB)"
    }
}

class InventoryScanner {

    # Games and launchers are explicitly excluded -- this tool restores work
    # environments, and game libraries are huge and re-downloadable.
    static [string[]] $GamePatterns = @(
        'steam', 'steamapps', 'epic games', 'epicgames', 'gog galaxy', 'origin',
        'ea app', 'ea desktop', 'battle.net', 'blizzard', 'ubisoft', 'uplay',
        'riot ', 'riot games', 'valorant', 'league of legends', 'minecraft',
        'roblox', 'xbox', 'game bar', 'gamebar', 'geforce experience',
        'rockstar games', 'playnite', 'itch.io', 'nintendo', 'playstation'
    )

    # Noise that should never appear in a restore list.
    static [string[]] $NoisePatterns = @(
        'update for', 'security update', 'hotfix', 'kb[0-9]{6,}',
        'language pack', 'msi development tool', 'windows sdk addon',
        'crash reporter', 'uninstall', 'setup bootstrap'
    )

    static [bool] IsGame([string]$text) {
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        $lower = $text.ToLowerInvariant()
        foreach ($p in [InventoryScanner]::GamePatterns) {
            if ($lower -like "*$p*") { return $true }
        }
        return $false
    }

    static [bool] IsNoise([string]$text) {
        if ([string]::IsNullOrWhiteSpace($text)) { return $true }
        $lower = $text.ToLowerInvariant()
        foreach ($p in [InventoryScanner]::NoisePatterns) {
            if ($lower -match $p) { return $true }
        }
        return $false
    }

    static [string] Classify([string]$name) {
        $lower = $name.ToLowerInvariant()
        if ($lower -match 'redistributable|runtime|\.net framework|vcredist|webview') { return 'runtime' }
        if ($lower -match 'driver|minidriver') { return 'driver' }
        return 'app'
    }

    [System.Collections.Generic.List[InstalledApp]] ScanApplications() {
        $found = [System.Collections.Generic.List[InstalledApp]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        if ($script:OnWindowsHost) { $this.ScanWinget($found, $seen); $this.ScanRegistry($found, $seen) }
        else { $this.ScanHomebrew($found, $seen); $this.ScanAppBundles($found, $seen) }

        return $found
    }

    hidden [void] Add([System.Collections.Generic.List[InstalledApp]]$list,
        [System.Collections.Generic.HashSet[string]]$seen,
        [string]$name, [string]$id, [string]$version, [string]$publisher, [string]$source) {

        if ([InventoryScanner]::IsNoise($name)) { return }
        if ([InventoryScanner]::IsGame($name) -or [InventoryScanner]::IsGame($publisher)) { return }

        $key = if ($id) { $id } else { $name }
        if (-not $seen.Add($key)) { return }

        $app = [InstalledApp]::new()
        $app.Name = $name.Trim()
        $app.Id = $id
        $app.Version = $version
        $app.Publisher = $publisher
        $app.Source = $source
        $app.Kind = [InventoryScanner]::Classify($name)
        # Runtimes get reinstalled as dependencies; don't clutter the default set.
        $app.Selected = ($app.Kind -eq 'app')
        $list.Add($app)
    }

    hidden [void] ScanWinget([System.Collections.Generic.List[InstalledApp]]$list,
        [System.Collections.Generic.HashSet[string]]$seen) {
        $exe = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $exe) { return }
        try {
            # --source winget keeps entries that have a restorable package id.
            $raw = & $exe.Source list --source winget --accept-source-agreements 2>$null | Out-String
            foreach ($line in ($raw -split "`r?`n")) {
                # Columns are space-padded; an id looks like Publisher.Product.
                if ($line -match '^(?<name>.+?)\s{2,}(?<id>[\w\.\+-]+\.[\w\.\+-]+)\s{2,}(?<ver>[^\s]+)') {
                    $this.Add($list, $seen, $Matches['name'], $Matches['id'], $Matches['ver'], '', 'winget')
                }
            }
        }
        catch { }
    }

    hidden [void] ScanRegistry([System.Collections.Generic.List[InstalledApp]]$list,
        [System.Collections.Generic.HashSet[string]]$seen) {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($key in $keys) {
            try { $entries = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue }
            catch { continue }
            foreach ($e in $entries) {
                $name = $null
                try { $name = $e.DisplayName } catch { continue }
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                # System components aren't user-facing applications.
                try { if ($e.SystemComponent -eq 1) { continue } } catch { }
                try { if ($e.ReleaseType -match 'Update|Hotfix') { continue } } catch { }

                $ver = ''; $pub = ''; $loc = ''
                try { $ver = [string]$e.DisplayVersion } catch { }
                try { $pub = [string]$e.Publisher } catch { }
                try { $loc = [string]$e.InstallLocation } catch { }
                if ([InventoryScanner]::IsGame($loc)) { continue }

                $this.Add($list, $seen, $name, '', $ver, $pub, 'registry')
            }
        }
    }

    hidden [void] ScanHomebrew([System.Collections.Generic.List[InstalledApp]]$list,
        [System.Collections.Generic.HashSet[string]]$seen) {
        $brew = Get-Command brew -ErrorAction SilentlyContinue
        if (-not $brew) { return }
        try {
            foreach ($f in (& $brew.Source list --formula 2>$null)) {
                if ($f) { $this.Add($list, $seen, $f, $f, '', '', 'brew') }
            }
            foreach ($c in (& $brew.Source list --cask 2>$null)) {
                if ($c) { $this.Add($list, $seen, $c, $c, '', '', 'cask') }
            }
        }
        catch { }
    }

    hidden [void] ScanAppBundles([System.Collections.Generic.List[InstalledApp]]$list,
        [System.Collections.Generic.HashSet[string]]$seen) {
        $home = [Environment]::GetEnvironmentVariable('HOME')
        $dirs = @('/Applications')
        if ($home) { $dirs += [IO.Path]::Combine($home, 'Applications') }
        foreach ($dir in $dirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            try {
                foreach ($app in (Get-ChildItem -LiteralPath $dir -Filter '*.app' -ErrorAction SilentlyContinue)) {
                    $this.Add($list, $seen, $app.BaseName, '', '', '', 'app-bundle')
                }
            }
            catch { }
        }
    }

    # --- Repositories -----------------------------------------------------

    [System.Collections.Generic.List[GitRepository]] ScanRepositories([string[]]$roots, [int]$maxDepth = 4) {
        $repos = [System.Collections.Generic.List[GitRepository]]::new()
        $git = (Get-Command git -ErrorAction SilentlyContinue)

        foreach ($root in $roots) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($root.Trim().Trim('"'))
            if (-not (Test-Path -LiteralPath $expanded)) {
                Write-Warning "Folder not found, skipping: $expanded"
                continue
            }
            $this.FindRepos($expanded, $maxDepth, $repos, $git)
        }
        return $repos
    }

    hidden [void] FindRepos([string]$dir, [int]$depthLeft,
        [System.Collections.Generic.List[GitRepository]]$repos, $git) {
        if ($depthLeft -lt 0) { return }

        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            $repo = [GitRepository]::new()
            $repo.Name = Split-Path -Leaf $dir
            $repo.Path = $dir
            if ($git) {
                try { $repo.Remote = (& $git.Source -C $dir config --get remote.origin.url 2>$null) } catch { }
                try { $repo.Branch = (& $git.Source -C $dir rev-parse --abbrev-ref HEAD 2>$null) } catch { }
                try { $repo.Dirty = [bool](& $git.Source -C $dir status --porcelain 2>$null) } catch { }
            }
            $repos.Add($repo)
            return   # don't descend into a repo's own subfolders
        }

        try {
            foreach ($sub in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($sub.Name -in @('node_modules', '.venv', 'venv', 'vendor', 'Library', 'AppData', '$Recycle.Bin')) { continue }
                if ($sub.Name.StartsWith('.') -and $sub.Name -ne '.git') { continue }
                $this.FindRepos($sub.FullName, $depthLeft - 1, $repos, $git)
            }
        }
        catch { }
    }

    # --- Terminal, shell and tooling configuration ------------------------

    hidden [string] HomeDir() {
        $h = [Environment]::GetEnvironmentVariable('USERPROFILE')
        if (-not $h) { $h = [Environment]::GetEnvironmentVariable('HOME') }
        return $h
    }

    hidden [void] AddSetting([System.Collections.Generic.List[EnvironmentSetting]]$list,
        [string]$name, [string]$flag, [string]$detail) {
        $s = [EnvironmentSetting]::new()
        $s.Name = $name; $s.Flag = $flag; $s.Detail = $detail
        $list.Add($s)
    }

    [System.Collections.Generic.List[EnvironmentSetting]] ScanEnvironment() {
        $found = [System.Collections.Generic.List[EnvironmentSetting]]::new()
        $home_ = $this.HomeDir()
        $git = Get-Command git -ErrorAction SilentlyContinue

        if ($git) {
            $n = ''; $e = ''
            try { $n = (& $git.Source config --global user.name 2>$null) } catch { }
            try { $e = (& $git.Source config --global user.email 2>$null) } catch { }
            if ($n -or $e) { $this.AddSetting($found, 'Git identity and settings', 'gitssh', "$n <$e>") }
        }
        # The public key is recorded; the private key is never read.
        if ($home_ -and (Test-Path -LiteralPath (Join-Path $home_ '.ssh\id_ed25519.pub'))) {
            $this.AddSetting($found, 'SSH key for GitHub', 'gitssh', 'ed25519 (public key only)')
        }

        if ($home_ -and (Test-Path -LiteralPath (Join-Path $home_ '.oh-my-zsh'))) {
            $theme = ''
            $zshrc = Join-Path $home_ '.zshrc'
            if (Test-Path -LiteralPath $zshrc) {
                try {
                    $m = Select-String -Path $zshrc -Pattern '^\s*ZSH_THEME="?([^"\r\n]+)"?' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                    if ($m) { $theme = $m.Matches[0].Groups[1].Value }
                }
                catch { }
            }
            $this.AddSetting($found, 'Oh My Zsh', 'zsh', $(if ($theme) { "theme: $theme" } else { '' }))
        }
        if ($home_ -and (Test-Path -LiteralPath (Join-Path $home_ '.p10k.zsh'))) {
            $this.AddSetting($found, 'Powerlevel10k prompt', 'zsh', 'configured')
        }

        foreach ($z in @("$env:ProgramFiles\Git\usr\bin\zsh.exe", '/usr/bin/zsh', '/bin/zsh', '/opt/homebrew/bin/zsh')) {
            if ($z -and (Test-Path -LiteralPath $z)) {
                $this.AddSetting($found, 'Zsh shell', 'zsh', $z)
                break
            }
        }

        if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
            $this.AddSetting($found, 'Oh My Posh prompt', 'omp', '')
        }
        foreach ($p in @(
                "$home_\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
                "$home_\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1")) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                $this.AddSetting($found, 'PowerShell profile', 'omp', (Split-Path -Leaf (Split-Path -Parent $p)))
                break
            }
        }

        $wt = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
        if (Test-Path -LiteralPath $wt) {
            $this.AddSetting($found, 'Windows Terminal settings', 'terminal', 'profiles and default shell')
        }

        $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        foreach ($d in @($fontDir, "$env:WINDIR\Fonts")) {
            if ($d -and (Test-Path -LiteralPath $d)) {
                try {
                    if (Get-ChildItem -LiteralPath $d -Filter '*Meslo*' -ErrorAction SilentlyContinue | Select-Object -First 1) {
                        $this.AddSetting($found, 'MesloLGS Nerd Font', 'nerdfont', '')
                        break
                    }
                }
                catch { }
            }
        }

        $code = Get-Command code -ErrorAction SilentlyContinue
        if (-not $code -and (Test-Path -LiteralPath "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd")) {
            $code = @{ Source = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" }
        }
        if ($code) {
            try {
                $exts = @(& $code.Source --list-extensions 2>$null)
                if ($exts.Count) { $this.AddSetting($found, 'VS Code extensions', 'vscode', "$($exts.Count) installed") }
            }
            catch { }
        }

        if (Get-Command npm -ErrorAction SilentlyContinue) {
            $this.AddSetting($found, 'npm global packages', 'npm', '')
        }
        if (Get-Command pipx -ErrorAction SilentlyContinue) {
            $this.AddSetting($found, 'Python tools (pipx)', 'pipx', '')
        }
        if (Get-Command rustup -ErrorAction SilentlyContinue) {
            $this.AddSetting($found, 'Rust toolchain', 'rust', '')
        }
        if (Get-Command go -ErrorAction SilentlyContinue) {
            $this.AddSetting($found, 'Go workspace', 'golang', '')
        }

        return $found
    }

    # Config files worth carrying over. Secrets are never included -- SSH
    # private keys and credential stores are deliberately absent.
    [System.Collections.Generic.List[DotFile]] ScanDotfiles() {
        $found = [System.Collections.Generic.List[DotFile]]::new()
        $home_ = $this.HomeDir()
        if (-not $home_) { return $found }

        $candidates = @(
            @{ N = '.gitconfig'; P = (Join-Path $home_ '.gitconfig'); T = '.gitconfig' }
            @{ N = '.zshrc'; P = (Join-Path $home_ '.zshrc'); T = '.zshrc' }
            @{ N = '.p10k.zsh'; P = (Join-Path $home_ '.p10k.zsh'); T = '.p10k.zsh' }
            @{ N = '.bashrc'; P = (Join-Path $home_ '.bashrc'); T = '.bashrc' }
            @{ N = '.bash_profile'; P = (Join-Path $home_ '.bash_profile'); T = '.bash_profile' }
            @{ N = 'ssh config'; P = (Join-Path $home_ '.ssh\config'); T = '.ssh/config' }
            @{ N = 'PowerShell 7 profile'; P = (Join-Path $home_ 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'); T = 'Documents/PowerShell/Microsoft.PowerShell_profile.ps1' }
            @{ N = 'Windows PowerShell profile'; P = (Join-Path $home_ 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'); T = 'Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1' }
            @{ N = 'Windows Terminal settings'; P = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'); T = 'AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json' }
        )

        foreach ($c in $candidates) {
            if (-not (Test-Path -LiteralPath $c.P)) { continue }
            try {
                $item = Get-Item -LiteralPath $c.P -ErrorAction Stop
                if ($item.Length -gt 256KB) { continue }   # config files, not data
                $d = [DotFile]::new()
                $d.Name = $c.N
                $d.Path = $c.P
                $d.Target = $c.T
                $d.Content = Get-Content -LiteralPath $c.P -Raw -ErrorAction Stop
                $found.Add($d)
            }
            catch { }
        }
        return $found
    }

    # Globally installed CLI tooling, so it can be reinstalled by name.
    [hashtable] ScanToolLists() {
        $lists = @{}
        $code = Get-Command code -ErrorAction SilentlyContinue
        if (-not $code -and (Test-Path -LiteralPath "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd")) {
            $code = @{ Source = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" }
        }
        if ($code) {
            try { $lists['vscode'] = @(& $code.Source --list-extensions 2>$null | Where-Object { $_ }) } catch { }
        }
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            try {
                $raw = & npm ls -g --depth=0 --parseable 2>$null
                $lists['npm'] = @($raw | ForEach-Object { Split-Path $_ -Leaf } |
                    Where-Object { $_ -and $_ -ne 'node_modules' } | Sort-Object -Unique)
            }
            catch { }
        }
        if (Get-Command pipx -ErrorAction SilentlyContinue) {
            try {
                $raw = & pipx list --short 2>$null
                $lists['pipx'] = @($raw | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
            }
            catch { }
        }
        return $lists
    }
}

function New-InventoryScanner { return [InventoryScanner]::new() }

function Get-InstalledApplications {
    return (New-InventoryScanner).ScanApplications()
}

function Get-LocalRepositories {
    param([Parameter(Mandatory)][string[]]$Roots, [int]$MaxDepth = 4)
    return (New-InventoryScanner).ScanRepositories($Roots, $MaxDepth)
}

function Get-EnvironmentSettings {
    return (New-InventoryScanner).ScanEnvironment()
}

function Get-Dotfiles {
    return (New-InventoryScanner).ScanDotfiles()
}

Export-ModuleMember -Function New-InventoryScanner, Get-InstalledApplications, Get-LocalRepositories,
Get-EnvironmentSettings, Get-Dotfiles
