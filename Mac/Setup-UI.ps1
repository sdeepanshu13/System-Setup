<#
.SYNOPSIS
    Console setup UI for macOS -- profile sign-in plus package/feature selection.
.DESCRIPTION
    macOS has no Windows Forms, so this is a terminal UI. It reuses the same
    Shared/Modules/SetupCore.psm1 the Windows GUI uses, so profiles, OTP and
    encryption behave identically on both platforms.

    Dot-sourced by Mac/Setup.ps1; Show-SetupConsole returns the selections.
#>

function Write-Rule {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('  ' + ('=' * 62)) -ForegroundColor $Color
    if ($Text) { Write-Host "   $Text" -ForegroundColor $Color }
    Write-Host ('  ' + ('=' * 62)) -ForegroundColor $Color
}

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host -Prompt "  $Prompt" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

function Invoke-ProfileSignIn {
    <#
        Signs the user in and returns their saved profile, or $null if skipped.
        Returns @{ Manager; Passphrase; Data; Name }
    #>
    param([Parameter(Mandatory)]$Manager)

    Write-Rule 'Sync your setup preferences'
    Write-Host '  Enter your email or mobile to load the selections you saved on'
    Write-Host '  another machine. We send a one-time code to confirm it is you.'
    Write-Host '  Your data is encrypted with your passphrase -- only you can read it.'
    Write-Host ''
    Write-Host '  Press Enter on a blank line to skip and use the defaults.' -ForegroundColor DarkGray
    Write-Host ''

    $identifier = Read-Host '  Email or mobile'
    if ([string]::IsNullOrWhiteSpace($identifier)) {
        Write-Host '  Skipping profile sync.' -ForegroundColor DarkGray
        return $null
    }

    try { $Manager.Prepare() } catch { }

    Write-Host '  Sending verification code...' -ForegroundColor DarkGray
    $begin = $Manager.BeginVerification($identifier)
    if (-not $begin.Ok) {
        Write-Host "  Couldn't send code: $($begin.Error)" -ForegroundColor Yellow
        Write-Host '  Continuing without profile sync.' -ForegroundColor DarkGray
        return $null
    }
    Write-Host "  Code sent to your $($begin.Channel)." -ForegroundColor Green

    $verified = $false
    for ($i = 0; $i -lt 5 -and -not $verified; $i++) {
        $code = Read-Host '  Verification code (blank to skip)'
        if ([string]::IsNullOrWhiteSpace($code)) {
            Write-Host '  Skipping profile sync.' -ForegroundColor DarkGray
            return $null
        }
        $res = $Manager.CompleteVerification($code)
        if ($res.Ok) { $verified = $true }
        else { Write-Host "  $($res.Reason)" -ForegroundColor Yellow }
    }
    if (-not $verified) {
        Write-Host '  Too many failed attempts -- continuing without sync.' -ForegroundColor Yellow
        return $null
    }
    Write-Host '  Verified.' -ForegroundColor Green

    for ($i = 0; $i -lt 3; $i++) {
        $pass = Read-Secret 'Passphrase (unlocks your saved settings)'
        if ([string]::IsNullOrEmpty($pass)) { return $null }

        $loaded = $Manager.LoadProfile($pass)
        if (-not $loaded.Ok) {
            Write-Host "  Couldn't reach your profile: $($loaded.Error)" -ForegroundColor Yellow
            return $null
        }
        if (-not $loaded.Found) {
            $confirm = Read-Secret 'Confirm passphrase (new account)'
            if ($pass -ne $confirm) {
                Write-Host '  Passphrases do not match.' -ForegroundColor Yellow
                continue
            }
            Write-Host '  New profile created.' -ForegroundColor Green
            return @{ Manager = $Manager; Passphrase = $pass; Data = $null }
        }
        if (-not $loaded.Decrypted) {
            Write-Host '  Incorrect passphrase.' -ForegroundColor Yellow
            continue
        }
        Write-Host '  Loaded your saved selections.' -ForegroundColor Green
        return @{ Manager = $Manager; Passphrase = $pass; Data = $loaded.Data }
    }
    return $null
}

function Show-Selector {
    <# Generic numbered toggle list. Returns the selected entries. #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Groups,   # @{ Heading; Items = @(@{ Label; Key; On }) }
        [string]$KeyName = 'Key'
    )

    # Flatten so each item gets a stable number.
    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $Groups) { foreach ($it in $g.Items) { $flat.Add($it) } }

    while ($true) {
        Write-Rule $Title
        $n = 0
        foreach ($g in $Groups) {
            Write-Host ''
            Write-Host "   $($g.Heading)" -ForegroundColor Blue
            foreach ($it in $g.Items) {
                $n++
                $mark = if ($it.On) { 'x' } else { ' ' }
                $col = if ($it.On) { 'Green' } else { 'DarkGray' }
                Write-Host ("    [{0}] {1,3}. {2}" -f $mark, $n, $it.Label) -ForegroundColor $col
            }
        }
        Write-Host ''
        Write-Host '   Toggle: number (or 1,3,5 / 2-6)   ' -NoNewline -ForegroundColor DarkGray
        Write-Host 'a' -NoNewline -ForegroundColor Yellow
        Write-Host '=all  ' -NoNewline -ForegroundColor DarkGray
        Write-Host 'n' -NoNewline -ForegroundColor Yellow
        Write-Host '=none  ' -NoNewline -ForegroundColor DarkGray
        Write-Host 'go' -NoNewline -ForegroundColor Green
        Write-Host '=continue  ' -NoNewline -ForegroundColor DarkGray
        Write-Host 'q' -NoNewline -ForegroundColor Red
        Write-Host '=quit' -ForegroundColor DarkGray
        $answer = (Read-Host '  >').Trim().ToLower()

        switch ($answer) {
            'go' { return ($flat | Where-Object { $_.On }) }
            'a' { $flat | ForEach-Object { $_.On = $true } }
            'n' { $flat | ForEach-Object { $_.On = $false } }
            'q' { Write-Host '  Cancelled.'; exit 0 }
            default {
                foreach ($part in ($answer -split ',')) {
                    $part = $part.Trim()
                    if ($part -match '^(\d+)\s*-\s*(\d+)$') {
                        foreach ($i in [int]$Matches[1]..[int]$Matches[2]) {
                            if ($i -ge 1 -and $i -le $flat.Count) { $flat[$i - 1].On = -not $flat[$i - 1].On }
                        }
                    }
                    elseif ($part -match '^\d+$') {
                        $i = [int]$part
                        if ($i -ge 1 -and $i -le $flat.Count) { $flat[$i - 1].On = -not $flat[$i - 1].On }
                    }
                }
            }
        }
    }
}

function Show-SetupConsole {
    <#
        Full flow: sign in, pick packages, pick features.
        Returns @{ Packages; Features; Profile }
    #>
    param(
        [Parameter(Mandatory)]$Catalogue,
        $Manager
    )

    $profile = $null
    if ($Manager) {
        try { $profile = Invoke-ProfileSignIn -Manager $Manager }
        catch { Write-Host "  Profile sync unavailable: $_" -ForegroundColor Yellow }
    }

    # Saved selections win over the catalogue defaults.
    $savedPkgs = $null; $savedFeats = $null
    if ($profile -and $profile.Data) {
        $savedPkgs = @{}; $savedFeats = @{}
        foreach ($p in $profile.Data.Packages) { $savedPkgs[[string]$p] = $true }
        foreach ($f in $profile.Data.Features) { $savedFeats[[string]$f] = $true }
    }

    $pkgGroups = foreach ($s in $Catalogue.sections) {
        @{
            Heading = $s.heading
            Items   = @(foreach ($i in $s.items) {
                    @{
                        Label = "$($i.name)  ($($i.id))"
                        Key   = $i.id
                        Type  = $i.type
                        On    = if ($savedPkgs) { $savedPkgs.ContainsKey($i.id) } else { [bool]$i.default }
                    }
                })
        }
    }
    $selectedPkgs = Show-Selector -Title 'SOFTWARE PACKAGES (Homebrew)' -Groups $pkgGroups

    $featGroups = foreach ($s in $Catalogue.features) {
        @{
            Heading = $s.heading
            Items   = @(foreach ($i in $s.items) {
                    @{
                        Label = $i.name
                        Key   = $i.flag
                        On    = if ($savedFeats) { $savedFeats.ContainsKey($i.flag) } else { [bool]$i.default }
                    }
                })
        }
    }
    $selectedFeats = Show-Selector -Title 'SETUP & CONFIGURATION' -Groups $featGroups

    return @{
        Packages = @($selectedPkgs)
        Features = @($selectedFeats | ForEach-Object { $_.Key })
        Profile  = $profile
    }
}
