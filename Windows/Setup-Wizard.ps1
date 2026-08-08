<#
.SYNOPSIS
    Backup / restore wizard for the Windows installer.
.DESCRIPTION
    First thing the user sees. Asks whether this is the machine they're leaving
    (back up) or the machine they're moving to (restore), then drives the
    matching flow.

    Backup : inventory apps -> pick repo folders -> review -> verify -> save
    Restore: verify -> review what's saved -> hand the selection to the installer

    Applications and settings only. File contents are never read or uploaded.

    Dot-sourced by Setup.ps1; every dialog returns plain objects so the flow
    logic stays testable and free of UI concerns.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Ink = @{
    Bg      = [System.Drawing.Color]::FromArgb(30, 30, 30)
    Panel   = [System.Drawing.Color]::FromArgb(45, 45, 45)
    Accent  = [System.Drawing.Color]::FromArgb(0, 180, 255)
    Primary = [System.Drawing.Color]::FromArgb(0, 120, 212)
    Muted   = [System.Drawing.Color]::FromArgb(160, 160, 160)
    Good    = [System.Drawing.Color]::FromArgb(120, 220, 120)
    Bad     = [System.Drawing.Color]::FromArgb(255, 120, 120)
    Text    = [System.Drawing.Color]::White
}

function New-WizardForm {
    param([string]$Title, [int]$Width = 760, [int]$Height = 620)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Size = New-Object System.Drawing.Size($Width, $Height)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.BackColor = $script:Ink.Bg
    $f.ForeColor = $script:Ink.Text
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    return $f
}

function New-WizardLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20,
        $Color = $null, [single]$Size = 9.5, [bool]$Bold = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.ForeColor = if ($Color) { $Color } else { $script:Ink.Text }
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    $Parent.Controls.Add($l)
    return $l
}

function New-WizardButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 130, [int]$H = 34, [bool]$Primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.BackColor = if ($Primary) { $script:Ink.Primary } else { [System.Drawing.Color]::FromArgb(60, 60, 60) }
    $b.ForeColor = if ($Primary) { $script:Ink.Text } else { [System.Drawing.Color]::FromArgb(215, 215, 215) }
    $Parent.Controls.Add($b)
    return $b
}

# =====================================================================
# Step 1 -- which machine is this?
# =====================================================================

function Show-ModeDialog {
    # Returns 'backup', 'restore', 'fresh' or $null when cancelled.
    $f = New-WizardForm -Title 'System-Setup' -Width 640 -Height 470
    $choice = $null

    New-WizardLabel $f 'What would you like to do?' 30 24 560 34 $script:Ink.Accent 16 $true | Out-Null
    New-WizardLabel $f 'Applications and settings only -- your files are never read or uploaded.' 32 60 560 20 $script:Ink.Muted | Out-Null

    $options = @(
        @{ Key = 'backup'; Title = 'This is my OLD machine'
            Desc = "Back up what's installed here, plus your repo folders,`r`nso you can restore it somewhere else."
        }
        @{ Key = 'restore'; Title = 'This is my NEW machine'
            Desc = "Sign in and restore the apps and settings`r`nyou backed up previously."
        }
        @{ Key = 'fresh'; Title = 'Just set up this machine'
            Desc = "Skip backup and restore -- pick from the standard`r`ncatalogue of developer tools."
        }
    )

    $y = 100
    foreach ($opt in $options) {
        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point(30, $y)
        $card.Size = New-Object System.Drawing.Size(560, 95)
        $card.BackColor = $script:Ink.Panel
        $card.Cursor = [System.Windows.Forms.Cursors]::Hand
        $card.Tag = $opt.Key
        $f.Controls.Add($card)

        $t = New-WizardLabel $card $opt.Title 18 14 520 24 $script:Ink.Accent 11 $true
        $d = New-WizardLabel $card $opt.Desc 18 40 520 44 $script:Ink.Muted

        # Clicking anywhere on the card selects it.
        $handler = {
            $script:PickedMode = $this.Tag
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }.GetNewClosure()
        $card.Add_Click($handler)
        foreach ($child in @($t, $d)) {
            $child.Tag = $opt.Key
            $child.Add_Click($handler)
        }
        $y += 108
    }

    $cancel = New-WizardButton $f 'Cancel' 480 ($y + 6) 110 32
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.CancelButton = $cancel

    $script:PickedMode = $null
    $result = $f.ShowDialog()
    $f.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $choice = $script:PickedMode }
    return $choice
}

# =====================================================================
# Reusable checklist -- every review screen uses this
# =====================================================================

function Show-ChecklistDialog {
    <#
        Groups: @( @{ Heading='...'; Items=@( @{ Label; Tag; Checked } ) } )
        Returns the selected item objects, or $null if cancelled.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][array]$Groups,
        [string]$ConfirmText = 'Continue'
    )

    $f = New-WizardForm -Title $Title -Width 780 -Height 660
    New-WizardLabel $f $Title 24 18 700 30 $script:Ink.Accent 15 $true | Out-Null
    New-WizardLabel $f $Message 26 52 710 36 $script:Ink.Muted | Out-Null

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(20, 96)
    $panel.Size = New-Object System.Drawing.Size(725, 445)
    $panel.AutoScroll = $true
    $panel.BackColor = $script:Ink.Bg
    $f.Controls.Add($panel)

    $boxes = New-Object 'System.Collections.Generic.List[System.Windows.Forms.CheckBox]'
    $y = 4
    foreach ($g in $Groups) {
        if ($g.Items.Count -eq 0) { continue }
        New-WizardLabel $panel $g.Heading 4 $y 660 22 $script:Ink.Accent 10.5 $true | Out-Null
        $y += 26
        foreach ($item in $g.Items) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $item.Label
            $cb.Tag = $item.Tag
            $cb.Checked = [bool]$item.Checked
            $cb.Location = New-Object System.Drawing.Point(20, $y)
            $cb.Size = New-Object System.Drawing.Size(670, 22)
            $cb.ForeColor = $script:Ink.Text
            $panel.Controls.Add($cb)
            $boxes.Add($cb)
            $y += 23
        }
        $y += 10
    }

    $count = New-WizardLabel $f '' 26 552 300 20 $script:Ink.Muted
    $refresh = {
        $n = @($boxes | Where-Object { $_.Checked }).Count
        $count.Text = "$n of $($boxes.Count) selected"
    }.GetNewClosure()
    foreach ($cb in $boxes) { $cb.Add_CheckedChanged($refresh) }
    & $refresh

    $all = New-WizardButton $f 'Select All' 24 576 110 32
    $all.ForeColor = $script:Ink.Accent
    $all.Add_Click({ foreach ($cb in $boxes) { $cb.Checked = $true } }.GetNewClosure())

    $none = New-WizardButton $f 'Deselect All' 140 576 110 32
    $none.Add_Click({ foreach ($cb in $boxes) { $cb.Checked = $false } }.GetNewClosure())

    $ok = New-WizardButton $f $ConfirmText 500 574 130 36 $true
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.AcceptButton = $ok

    $cancel = New-WizardButton $f 'Cancel' 638 574 105 36
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.CancelButton = $cancel

    $result = $f.ShowDialog()
    $selected = if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        @($boxes | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
    }
    else { $null }
    $f.Dispose()
    return $selected
}

# =====================================================================
# Repo folders -- several locations supported
# =====================================================================

function Show-RepoFolderDialog {
    # Returns an array of folder paths (possibly empty), or $null if cancelled.
    $f = New-WizardForm -Title 'Where are your repositories?' -Width 660 -Height 440

    New-WizardLabel $f 'Where are your repositories?' 26 20 580 30 $script:Ink.Accent 14 $true | Out-Null
    New-WizardLabel $f "Add every folder you keep code in -- they're often in more than one place.`r`nWe record the remote URL and branch only, never your file contents." 28 54 590 44 $script:Ink.Muted | Out-Null

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(28, 108)
    $list.Size = New-Object System.Drawing.Size(590, 190)
    $list.BackColor = $script:Ink.Panel
    $list.ForeColor = $script:Ink.Text
    $list.BorderStyle = 'FixedSingle'
    $f.Controls.Add($list)

    foreach ($guess in @(
            (Join-Path $env:USERPROFILE 'source\repos'),
            (Join-Path $env:USERPROFILE 'repos'),
            (Join-Path $env:USERPROFILE 'Projects'),
            (Join-Path $env:USERPROFILE 'dev'))) {
        if (Test-Path $guess) { [void]$list.Items.Add($guess) }
    }

    $add = New-WizardButton $f 'Add folder...' 28 308 130 32
    $add.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select a folder that contains repositories'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                if (-not $list.Items.Contains($dlg.SelectedPath)) { [void]$list.Items.Add($dlg.SelectedPath) }
            }
        }.GetNewClosure())

    $remove = New-WizardButton $f 'Remove' 166 308 100 32
    $remove.Add_Click({
            if ($list.SelectedIndex -ge 0) { $list.Items.RemoveAt($list.SelectedIndex) }
        }.GetNewClosure())

    $ok = New-WizardButton $f 'Scan' 400 348 110 34 $true
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.AcceptButton = $ok

    $skip = New-WizardButton $f 'Skip' 518 348 100 34
    $skip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore

    $cancel = New-WizardButton $f 'Cancel' 28 348 100 34
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.CancelButton = $cancel

    $result = $f.ShowDialog()
    $folders = @($list.Items)
    $f.Dispose()

    switch ($result) {
        ([System.Windows.Forms.DialogResult]::OK) { return $folders }
        ([System.Windows.Forms.DialogResult]::Ignore) { return @() }
        default { return $null }
    }
}

# =====================================================================
# Sign in -- email/mobile, OTP, passphrase
# =====================================================================

function Show-SignInDialog {
    <#
        Drives the manager through verification and profile load.
        Returns @{ Passphrase; Data } or $null if skipped/cancelled.
    #>
    param(
        [Parameter(Mandatory)]$Manager,
        [string]$Purpose = 'restore'   # 'backup' -> saving, 'restore' -> loading
    )

    $isRestore = $Purpose -eq 'restore'
    $f = New-WizardForm -Title 'Verify it''s you' -Width 500 -Height 470

    New-WizardLabel $f 'Verify it''s you' 26 20 430 30 $script:Ink.Accent 14 $true | Out-Null
    $blurb = if ($isRestore) {
        "Enter the email or mobile you backed up with. We'll send a one-time code, then unlock your settings."
    }
    else {
        "We'll send a one-time code to confirm it's you, then save your backup securely."
    }
    New-WizardLabel $f $blurb 28 54 430 44 $script:Ink.Muted | Out-Null

    New-WizardLabel $f 'Email or mobile' 28 104 430 18 | Out-Null
    $tbId = New-Object System.Windows.Forms.TextBox
    $tbId.Location = New-Object System.Drawing.Point(30, 124)
    $tbId.Size = New-Object System.Drawing.Size(425, 24)
    $tbId.BackColor = $script:Ink.Panel; $tbId.ForeColor = $script:Ink.Text; $tbId.BorderStyle = 'FixedSingle'
    $f.Controls.Add($tbId)

    $lblCode = New-WizardLabel $f 'Verification code' 28 156 430 18
    $lblCode.Visible = $false
    $tbCode = New-Object System.Windows.Forms.TextBox
    $tbCode.Location = New-Object System.Drawing.Point(30, 176)
    $tbCode.Size = New-Object System.Drawing.Size(425, 24)
    $tbCode.BackColor = $script:Ink.Panel; $tbCode.ForeColor = $script:Ink.Text; $tbCode.BorderStyle = 'FixedSingle'
    $tbCode.Visible = $false
    $f.Controls.Add($tbCode)

    New-WizardLabel $f 'Passphrase (protects your data)' 28 210 430 18 | Out-Null
    $tbPass = New-Object System.Windows.Forms.TextBox
    $tbPass.Location = New-Object System.Drawing.Point(30, 230)
    $tbPass.Size = New-Object System.Drawing.Size(425, 24)
    $tbPass.BackColor = $script:Ink.Panel; $tbPass.ForeColor = $script:Ink.Text
    $tbPass.BorderStyle = 'FixedSingle'; $tbPass.UseSystemPasswordChar = $true
    $f.Controls.Add($tbPass)

    $lblConfirm = New-WizardLabel $f 'Confirm passphrase (new account)' 28 262 430 18
    $tbConfirm = New-Object System.Windows.Forms.TextBox
    $tbConfirm.Location = New-Object System.Drawing.Point(30, 282)
    $tbConfirm.Size = New-Object System.Drawing.Size(425, 24)
    $tbConfirm.BackColor = $script:Ink.Panel; $tbConfirm.ForeColor = $script:Ink.Text
    $tbConfirm.BorderStyle = 'FixedSingle'; $tbConfirm.UseSystemPasswordChar = $true
    $f.Controls.Add($tbConfirm)

    $status = New-WizardLabel $f '' 28 314 430 36 $script:Ink.Bad
    $status.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $btnGo = New-WizardButton $f 'Send code' 30 360 150 36 $true
    $btnSkip = New-WizardButton $f 'Skip' 350 360 105 36
    $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $f.CancelButton = $btnSkip

    $state = @{ Sent = $false; Result = $null }

    $btnGo.Add_Click({
            $status.ForeColor = $script:Ink.Bad
            $status.Text = ''
            $id = $tbId.Text.Trim()
            $pass = $tbPass.Text

            if ([string]::IsNullOrWhiteSpace($id)) { $status.Text = 'Enter your email or mobile.'; return }
            if ([string]::IsNullOrEmpty($pass)) { $status.Text = 'A passphrase is required.'; return }

            if (-not $state.Sent) {
                $btnGo.Enabled = $false
                $status.ForeColor = $script:Ink.Muted
                $status.Text = 'Sending verification code...'
                $f.Refresh()
                try { $begin = $Manager.BeginVerification($id) }
                catch { $begin = @{ Ok = $false; Error = $_.Exception.Message } }
                $btnGo.Enabled = $true

                if (-not $begin.Ok) {
                    $status.ForeColor = $script:Ink.Bad
                    $status.Text = "Couldn't send code: $($begin.Error)"
                    return
                }
                $state.Sent = $true
                $lblCode.Visible = $true; $tbCode.Visible = $true; $tbCode.Focus()
                $btnGo.Text = 'Verify'
                $status.ForeColor = $script:Ink.Good
                $status.Text = if ($begin.Method -eq 'dev') { 'Dev mode: code printed to the console.' }
                else { "Code sent to your $($begin.Channel)." }
                return
            }

            if (-not $Manager.Verified) {
                $chk = $Manager.CompleteVerification($tbCode.Text)
                if (-not $chk.Ok) {
                    $status.ForeColor = $script:Ink.Bad
                    $status.Text = "Code: $($chk.Reason)"
                    return
                }
            }

            $loaded = $Manager.LoadProfile($pass)
            if (-not $loaded.Ok) { $status.Text = "Couldn't reach your profile: $($loaded.Error)"; return }

            if ($loaded.Found) {
                if (-not $loaded.Decrypted) { $status.Text = 'Incorrect passphrase for this account.'; return }
                $state.Result = @{ Passphrase = $pass; Data = $loaded.Data }
            }
            else {
                if ($isRestore) { $status.Text = 'No backup found for this account.'; return }
                if ($tbPass.Text -ne $tbConfirm.Text) { $status.Text = "Passphrases don't match (new account)."; return }
                $state.Result = @{ Passphrase = $pass; Data = $null }
            }

            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }.GetNewClosure())

    [void]$f.ShowDialog()
    $f.Dispose()
    return $state.Result
}

function Show-Toast {
    param([string]$Text, [string]$Title = 'System-Setup')
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}
