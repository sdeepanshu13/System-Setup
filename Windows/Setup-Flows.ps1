<#
.SYNOPSIS
    Backup and restore flows for the Windows installer.
.DESCRIPTION
    Orchestrates the wizard dialogs, the inventory scanner and the encrypted
    profile store. Kept apart from Setup-Wizard.ps1 (pure UI) so the sequencing
    can be reasoned about -- and tested -- on its own.
#>

function Invoke-BackupFlow {
    <# Inventory this machine, let the user prune it, then save. Returns $true on success. #>
    param([Parameter(Mandatory)]$Manager, [Parameter(Mandatory)]$Scanner)

    # Identity first: the backup has nowhere to go without it, and asking after
    # a long scan meant the work was wasted if the user backed out.
    $signIn = Show-SignInDialog -Manager $Manager -Purpose 'backup'
    if ($null -eq $signIn) {
        Show-Toast ("Backup cancelled.`r`n`r`n" +
            'Your email and a passphrase are needed so the backup can be saved ' +
            'and unlocked on your new machine.')
        return $false
    }

    try {
        Write-Host 'Scanning installed applications...' -ForegroundColor Cyan
        $apps = $Scanner.ScanApplications()
        Write-Host ("  found {0} applications" -f $apps.Count) -ForegroundColor DarkGray
    }
    catch {
        $Manager.Errors.ReportException('backup', '', $_)
        Show-Toast "Couldn't scan this machine: $($_.Exception.Message)"
        return $false
    }

    $folders = Show-RepoFolderDialog
    if ($null -eq $folders) { return $false }

    $repos = @()
    if ($folders.Count -gt 0) {
        Write-Host 'Scanning for repositories...' -ForegroundColor Cyan
        $repos = $Scanner.ScanRepositories($folders, 4)
        Write-Host ("  found {0} repositories" -f $repos.Count) -ForegroundColor DarkGray
    }

    Write-Host 'Reading terminal and shell settings...' -ForegroundColor Cyan
    $settings = @(); $dotfiles = @(); $tools = @{}
    try {
        $settings = $Scanner.ScanEnvironment()
        $dotfiles = $Scanner.ScanDotfiles()
        $tools = $Scanner.ScanToolLists()
        Write-Host ("  {0} settings, {1} config files" -f $settings.Count, $dotfiles.Count) -ForegroundColor DarkGray
    }
    catch {
        $Manager.Errors.ReportException('backup', 'environment', $_)
        Write-Host "  Couldn't read some settings: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Restorable apps first -- those are the ones we can actually reinstall.
    $restorable = @($apps | Where-Object { $_.Id })
    $manual = @($apps | Where-Object { -not $_.Id })

    $groups = @()
    if ($restorable.Count) {
        $groups += @{
            Heading = "Applications that can be reinstalled automatically ($($restorable.Count))"
            Items   = @($restorable | Sort-Object Name | ForEach-Object {
                    @{ Label = $_.Display(); Tag = @{ Kind = 'app'; Item = $_ }; Checked = $_.Selected }
                })
        }
    }
    if ($manual.Count) {
        $groups += @{
            Heading = "Detected, but no package id -- recorded for reference ($($manual.Count))"
            Items   = @($manual | Sort-Object Name | ForEach-Object {
                    @{ Label = $_.Display(); Tag = @{ Kind = 'app'; Item = $_ }; Checked = $false }
                })
        }
    }
    if ($repos.Count) {
        $groups += @{
            Heading = "Repositories ($($repos.Count))"
            Items   = @($repos | Sort-Object Name | ForEach-Object {
                    @{ Label = $_.Display(); Tag = @{ Kind = 'repo'; Item = $_ }; Checked = $true }
                })
        }
    }
    if ($settings.Count) {
        $groups += @{
            Heading = "Terminal and shell setup ($($settings.Count))"
            Items   = @($settings | ForEach-Object {
                    @{ Label = $_.Display(); Tag = @{ Kind = 'setting'; Item = $_ }; Checked = $true }
                })
        }
    }
    if ($dotfiles.Count) {
        $groups += @{
            Heading = "Config files ($($dotfiles.Count))"
            Items   = @($dotfiles | ForEach-Object {
                    @{ Label = $_.Display(); Tag = @{ Kind = 'dotfile'; Item = $_ }; Checked = $true }
                })
        }
    }

    if ($groups.Count -eq 0) {
        Show-Toast 'Nothing was found to back up on this machine.'
        return $false
    }

    $keep = Show-ChecklistDialog -Title 'Review your backup' -ConfirmText 'Back up' `
        -Message ("Only applications and settings are backed up -- never your files.`r`n" +
        'Untick anything you don''t want to carry over.') -Groups $groups
    if ($null -eq $keep) { return $false }

    # Discriminate on Kind: module classes aren't visible as type literals here.
    $keptApps = @($keep | Where-Object { $_.Kind -eq 'app' } | ForEach-Object { $_.Item })
    $keptRepos = @($keep | Where-Object { $_.Kind -eq 'repo' } | ForEach-Object { $_.Item })
    $keptSettings = @($keep | Where-Object { $_.Kind -eq 'setting' } | ForEach-Object { $_.Item })
    $keptDotfiles = @($keep | Where-Object { $_.Kind -eq 'dotfile' } | ForEach-Object { $_.Item })
    if ($keptApps.Count -eq 0 -and $keptRepos.Count -eq 0) {
        Show-Toast 'Nothing selected, so there was nothing to back up.'
        return $false
    }

    $data = New-ProfileData -Name $env:USERNAME `
        -Packages @($keptApps | Where-Object { $_.Id } | ForEach-Object { $_.Id }) `
        -Features @($keptSettings | ForEach-Object { $_.Flag } | Where-Object { $_ } | Sort-Object -Unique) `
        -DefaultShell '1' `
        -Apps @($keptApps | ForEach-Object {
            @{ name = $_.Name; id = $_.Id; version = $_.Version; source = $_.Source; kind = $_.Kind }
        }) `
        -Repos @($keptRepos | ForEach-Object {
            @{ name = $_.Name; path = $_.Path; remote = $_.Remote; branch = $_.Branch }
        }) `
        -Dotfiles @($keptDotfiles | ForEach-Object {
            @{ name = $_.Name; target = $_.Target; content = $_.Content }
        }) `
        -Tools $tools

    try {
        $saved = $Manager.SaveProfile($signIn.Passphrase, $data)
    }
    catch {
        $Manager.Errors.ReportException('profile', '', $_)
        Show-Toast "Backup failed: $($_.Exception.Message)"
        return $false
    }

    if (-not $saved.Ok) {
        $Manager.Errors.Report('profile', '', 'SaveProfile failed', [string]$saved.Error)
        Show-Toast "Backup failed: $($saved.Error)"
        return $false
    }

    $Manager.PublishIfLocal() | Out-Null
    Show-Toast ("Backup complete.`r`n`r`n" +
        "$($keptApps.Count) application(s), $($keptRepos.Count) repository record(s),`r`n" +
        "$($keptSettings.Count) setting(s) and $($keptDotfiles.Count) config file(s) saved, encrypted.`r`n`r`n" +
        'On your new machine, run this installer and choose "This is my NEW machine".')
    return $true
}

function Invoke-RestoreFlow {
    <#
        Verify, show what's stored, and return the user's selection.
        Returns @{ Packages; Repos } or $null.
    #>
    param([Parameter(Mandatory)]$Manager)

    $signIn = Show-SignInDialog -Manager $Manager -Purpose 'restore'
    if ($null -eq $signIn -or $null -eq $signIn.Data) { return $null }
    $data = $signIn.Data

    $groups = @()
    $apps = @($data.Apps | Where-Object { $_ -and $_.id })
    if ($apps.Count) {
        $groups += @{
            Heading = "Applications ($($apps.Count))"
            Items   = @($apps | ForEach-Object {
                    $label = if ($_.version) { "$($_.name)  ($($_.version))" } else { [string]$_.name }
                    @{ Label = $label; Tag = @{ Kind = 'app'; Id = [string]$_.id }; Checked = $true }
                })
        }
    }
    elseif ($data.Packages.Count) {
        $groups += @{
            Heading = "Applications ($($data.Packages.Count))"
            Items   = @($data.Packages | ForEach-Object {
                    @{ Label = [string]$_; Tag = @{ Kind = 'app'; Id = [string]$_ }; Checked = $true }
                })
        }
    }
    if ($data.Features.Count) {
        $groups += @{
            Heading = "Terminal and shell setup ($($data.Features.Count))"
            Items   = @($data.Features | ForEach-Object {
                    @{ Label = [string]$_; Tag = @{ Kind = 'feature'; Id = [string]$_ }; Checked = $true }
                })
        }
    }
    $dots = @($data.Dotfiles | Where-Object { $_ -and $_.target })
    if ($dots.Count) {
        $groups += @{
            Heading = "Config files ($($dots.Count))"
            Items   = @($dots | ForEach-Object {
                    @{ Label = [string]$_.name; Tag = @{ Kind = 'dotfile'; Item = $_ }; Checked = $true }
                })
        }
    }
    $repos = @($data.Repos | Where-Object { $_ })
    if ($repos.Count) {
        $groups += @{
            Heading = "Repositories to clone ($($repos.Count))"
            Items   = @($repos | ForEach-Object {
                    $remote = [string]$_.remote
                    $label = if ($remote) { "$($_.name) -> $remote" } else { "$($_.name)  (no remote -- skipped)" }
                    @{ Label = $label; Tag = @{ Kind = 'repo'; Name = [string]$_.name; Remote = $remote; Branch = [string]$_.branch }
                        Checked = [bool]$remote
                    }
                })
        }
    }

    if ($groups.Count -eq 0) {
        Show-Toast 'Your backup is empty -- nothing to restore.'
        return $null
    }

    $picked = Show-ChecklistDialog -Title 'Restore to this machine' -ConfirmText 'Install' `
        -Message 'Choose what to bring over. Anything already installed is skipped automatically.' `
        -Groups $groups
    if ($null -eq $picked) { return $null }

    return @{
        Packages = @($picked | Where-Object { $_.Kind -eq 'app' } | ForEach-Object { $_.Id })
        Features = @($picked | Where-Object { $_.Kind -eq 'feature' } | ForEach-Object { $_.Id })
        Repos    = @($picked | Where-Object { $_.Kind -eq 'repo' })
        Dotfiles = @($picked | Where-Object { $_.Kind -eq 'dotfile' } | ForEach-Object { $_.Item })
        Tools    = $data.Tools
    }
}

function Restore-Dotfiles {
    <# Write saved config files back, keeping a copy of anything replaced. #>
    param([array]$Dotfiles = @(), [Parameter(Mandatory)]$Manager)

    if ($null -eq $Dotfiles -or $Dotfiles.Count -eq 0) { return }
    $home_ = $env:USERPROFILE
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    Write-Host ''
    Write-Host 'Restoring terminal and shell config...' -ForegroundColor Cyan
    foreach ($d in $Dotfiles) {
        if (-not $d.target -or $null -eq $d.content) { continue }
        $dest = Join-Path $home_ ($d.target -replace '/', '\')
        try {
            $parent = Split-Path -Parent $dest
            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            # Never overwrite without leaving the original recoverable.
            if (Test-Path $dest) { Copy-Item $dest "$dest.backup-$stamp" -Force -ErrorAction SilentlyContinue }
            Set-Content -LiteralPath $dest -Value $d.content -Encoding UTF8 -Force
            Write-Host ("  restored {0}" -f $d.name) -ForegroundColor Green
        }
        catch {
            Write-Host ("  failed {0}: {1}" -f $d.name, $_.Exception.Message) -ForegroundColor Yellow
            $Manager.Errors.ReportException('dotfiles', [string]$d.name, $_)
        }
    }
}

function Restore-ToolLists {
    <# Reinstall globally installed tooling captured during backup. #>
    param([hashtable]$Tools = @{}, [Parameter(Mandatory)]$Manager)

    if ($null -eq $Tools -or $Tools.Count -eq 0) { return }

    if ($Tools.ContainsKey('vscode') -and @($Tools['vscode']).Count) {
        $code = Get-Command code -ErrorAction SilentlyContinue
        if (-not $code -and (Test-Path "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd")) {
            $code = @{ Source = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" }
        }
        if ($code) {
            Write-Host ''
            Write-Host ('Restoring {0} VS Code extension(s)...' -f @($Tools['vscode']).Count) -ForegroundColor Cyan
            foreach ($ext in $Tools['vscode']) {
                if (-not $ext) { continue }
                try { & $code.Source --install-extension $ext --force 2>&1 | Out-Null }
                catch { $Manager.Errors.ReportException('vscode', [string]$ext, $_) }
            }
            Write-Host '  done' -ForegroundColor Green
        }
    }

    if ($Tools.ContainsKey('npm') -and @($Tools['npm']).Count -and (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host ('Restoring {0} npm global(s)...' -f @($Tools['npm']).Count) -ForegroundColor Cyan
        foreach ($p in $Tools['npm']) {
            if (-not $p) { continue }
            try { & npm install -g $p 2>&1 | Out-Null }
            catch { $Manager.Errors.ReportException('npm', [string]$p, $_) }
        }
        Write-Host '  done' -ForegroundColor Green
    }

    if ($Tools.ContainsKey('pipx') -and @($Tools['pipx']).Count -and (Get-Command pipx -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host ('Restoring {0} pipx tool(s)...' -f @($Tools['pipx']).Count) -ForegroundColor Cyan
        foreach ($p in $Tools['pipx']) {
            if (-not $p) { continue }
            try { & pipx install $p 2>&1 | Out-Null }
            catch { $Manager.Errors.ReportException('pipx', [string]$p, $_) }
        }
        Write-Host '  done' -ForegroundColor Green
    }
}

function Restore-Repositories {
    <# Clone selected repos into a chosen root. Failures are reported, never fatal. #>
    param([array]$Repos = @(), [Parameter(Mandatory)]$Manager, [string]$Root)

    if ($null -eq $Repos -or $Repos.Count -eq 0) { return }
    if (-not $Root) { $Root = Join-Path $env:USERPROFILE 'source\repos' }
    if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        $Manager.Errors.Report('repos', '', 'git not found; skipped cloning', '')
        return
    }

    Write-Host ''
    Write-Host "Cloning repositories into $Root ..." -ForegroundColor Cyan
    foreach ($r in $Repos) {
        if (-not $r.Remote) { continue }
        $target = Join-Path $Root $r.Name
        if (Test-Path $target) {
            Write-Host ("  [skip] {0} already exists" -f $r.Name) -ForegroundColor DarkGray
            continue
        }
        Write-Host ("  cloning {0}..." -f $r.Name) -NoNewline
        try {
            & $git.Source clone --quiet $r.Remote $target 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if ($r.Branch) { & $git.Source -C $target checkout --quiet $r.Branch 2>&1 | Out-Null }
                Write-Host ' OK' -ForegroundColor Green
            }
            else {
                Write-Host " FAILED (exit $LASTEXITCODE)" -ForegroundColor Yellow
                $Manager.Errors.Report('repos', $r.Name, 'git clone failed', "exit $LASTEXITCODE; remote $($r.Remote)")
            }
        }
        catch {
            Write-Host ' FAILED' -ForegroundColor Yellow
            $Manager.Errors.ReportException('repos', $r.Name, $_)
        }
    }
}
