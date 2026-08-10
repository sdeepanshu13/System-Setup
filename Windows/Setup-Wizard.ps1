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

# Show a readable message instead of the raw .NET "Unhandled exception" dialog,
# whose Continue button just retriggers the same error.
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
}
catch { }

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

# global: on purpose. GetNewClosure() handlers run in their own module scope,
# which resolves commands against global -- not the script scope this file is
# dot-sourced into. Without this, every handler below dies with
# "Set-SafeColor is not recognized" whenever Setup.ps1 isn't the top-level script.
function global:Get-Ink {
    # $script:Ink isn't visible inside GetNewClosure() handlers, so dialogs take
    # a local copy of this and close over that instead.
    if ($script:Ink -and $script:Ink.Text) { return $script:Ink }
    return @{
        Bg      = [System.Drawing.Color]::FromArgb(30, 30, 30)
        Panel   = [System.Drawing.Color]::FromArgb(45, 45, 45)
        Accent  = [System.Drawing.Color]::FromArgb(0, 180, 255)
        Primary = [System.Drawing.Color]::FromArgb(0, 120, 212)
        Muted   = [System.Drawing.Color]::FromArgb(160, 160, 160)
        Good    = [System.Drawing.Color]::FromArgb(120, 220, 120)
        Bad     = [System.Drawing.Color]::FromArgb(255, 120, 120)
        Text    = [System.Drawing.Color]::White
    }
}

function global:Set-SafeColor {
    # Assigning $null to ForeColor throws; fall back rather than crash the dialog.
    param($Control, $Color, $Fallback = [System.Drawing.Color]::White)
    try {
        if ($Color -is [System.Drawing.Color]) { $Control.ForeColor = $Color }
        else { $Control.ForeColor = $Fallback }
    }
    catch { try { $Control.ForeColor = $Fallback } catch { } }
}

function New-WizardForm {
    param([string]$Title, [int]$Width = 760, [int]$Height = 620)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    # Scale with the user's DPI instead of assuming 96dpi.
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $f.AutoScaleDimensions = New-Object System.Drawing.SizeF(7, 15)
    $f.ClientSize = New-Object System.Drawing.Size($Width, $Height)
    $f.MinimumSize = New-Object System.Drawing.Size(520, 420)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'Sizable'   # let users resize if their scaling is unusual
    $f.MaximizeBox = $true
    $f.BackColor = $script:Ink.Bg
    $f.ForeColor = $script:Ink.Text
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    return $f
}

function New-ScrollHost {
    <#
        Scrollable content area that fills whatever space is left above the buttons.
        Add this to the form BEFORE the header and button bars: WinForms docks in
        reverse z-order, so a Fill added last claims the whole client area and the
        bars then overlay it, hiding the end of the content.
        AutoScroll stays off -- the FlowLayoutPanel inside is the scroller, and two
        nested AutoScroll containers fight over the wheel and stack scrollbars.
    #>
    param($Parent)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'
    $p.AutoScroll = $false
    $p.BackColor = $script:Ink.Bg
    $p.Padding = New-Object System.Windows.Forms.Padding(20, 10, 20, 10)
    $Parent.Controls.Add($p)
    return $p
}

function New-ButtonBar {
    <# Fixed-height strip pinned to the bottom so buttons are never clipped. #>
    param($Parent, [int]$Height = 56)
    $b = New-Object System.Windows.Forms.Panel
    $b.Dock = 'Bottom'
    $b.Height = $Height
    $b.BackColor = $script:Ink.Bg
    $Parent.Controls.Add($b)
    return $b
}

function New-HeaderBar {
    param($Parent, [string]$Title, [string]$Subtitle, [int]$Height = 78)
    $h = New-Object System.Windows.Forms.Panel
    $h.Dock = 'Top'
    $h.Height = $Height
    $h.BackColor = $script:Ink.Bg
    $Parent.Controls.Add($h)

    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title
    $t.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $t.ForeColor = $script:Ink.Accent
    $t.Location = New-Object System.Drawing.Point(20, 14)
    $t.AutoSize = $true
    $h.Controls.Add($t)

    if ($Subtitle) {
        $s = New-Object System.Windows.Forms.Label
        $s.Text = $Subtitle
        $s.ForeColor = $script:Ink.Muted
        $s.Location = New-Object System.Drawing.Point(22, 46)
        $s.Size = New-Object System.Drawing.Size(($Parent.ClientSize.Width - 50), 26)
        $s.Anchor = 'Top,Left,Right'
        $h.Controls.Add($s)
    }
    return $h
}

function New-WizardLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20,
        $Color = $null, [single]$Size = 9.5, [bool]$Bold = $false)
    $ink = Get-Ink
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    Set-SafeColor $l $Color $ink.Text
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
    $f = New-WizardForm -Title 'System-Setup' -Width 620 -Height 560

    $host_ = New-ScrollHost $f
    $bar = New-ButtonBar $f
    New-HeaderBar $f 'What would you like to do?' 'Applications and settings only -- your files are never read or uploaded.' | Out-Null

    $options = @(
        @{ Key = 'backup'; Title = 'This is my OLD machine'
            Desc = "Back up what's installed here, plus your repo folders," + [Environment]::NewLine + 'so you can restore it somewhere else.'
        }
        @{ Key = 'restore'; Title = 'This is my NEW machine'
            Desc = 'Sign in and restore the apps and settings' + [Environment]::NewLine + 'you backed up previously.'
        }
        @{ Key = 'fresh'; Title = 'Just set up this machine'
            Desc = 'Skip backup and restore -- pick from the standard' + [Environment]::NewLine + 'catalogue of developer tools.'
        }
    )

    # FlowLayoutPanel reflows on resize, so nothing is clipped at any DPI.
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.BackColor = $script:Ink.Bg
    $host_.Controls.Add($flow)

    $script:PickedMode = $null
    foreach ($opt in $options) {
        $card = New-Object System.Windows.Forms.Panel
        $card.Size = New-Object System.Drawing.Size(540, 96)
        $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
        $card.BackColor = $script:Ink.Panel
        $card.Cursor = [System.Windows.Forms.Cursors]::Hand
        $card.Tag = $opt.Key
        $flow.Controls.Add($card)

        $t = New-Object System.Windows.Forms.Label
        $t.Text = $opt.Title
        $t.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $t.ForeColor = $script:Ink.Accent
        $t.Location = New-Object System.Drawing.Point(18, 12)
        $t.AutoSize = $true
        $t.Tag = $opt.Key
        $card.Controls.Add($t)

        $d = New-Object System.Windows.Forms.Label
        $d.Text = $opt.Desc
        $d.ForeColor = $script:Ink.Muted
        $d.Location = New-Object System.Drawing.Point(18, 40)
        $d.AutoSize = $true
        $d.Tag = $opt.Key
        $card.Controls.Add($d)

        $click = {
            param($sender, $e)
            $script:PickedMode = $sender.Tag
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
        $card.Add_Click($click); $t.Add_Click($click); $d.Add_Click($click)

        $hoverColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
        $baseColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $hoverOn = { param($s, $e) try { $s.BackColor = $hoverColor } catch { } }.GetNewClosure()
        $hoverOff = { param($s, $e) try { $s.BackColor = $baseColor } catch { } }.GetNewClosure()
        $card.Add_MouseEnter($hoverOn); $card.Add_MouseLeave($hoverOff)
    }

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object System.Drawing.Size(110, 34)
    $cancel.Location = New-Object System.Drawing.Point(($f.ClientSize.Width - 130), 10)
    $cancel.Anchor = 'Top,Right'
    $cancel.FlatStyle = 'Flat'
    $cancel.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $cancel.ForeColor = [System.Drawing.Color]::FromArgb(215, 215, 215)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $bar.Controls.Add($cancel)
    $f.CancelButton = $cancel

    $result = $f.ShowDialog()
    $f.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $script:PickedMode }
    return $null
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

    $f = New-WizardForm -Title $Title -Width 760 -Height 620

    $host_ = New-ScrollHost $f
    $bar = New-ButtonBar $f 60
    $status = New-Object System.Windows.Forms.Panel
    $status.Dock = 'Bottom'; $status.Height = 26; $status.BackColor = $script:Ink.Bg
    $f.Controls.Add($status)
    New-HeaderBar $f $Title $Message 88 | Out-Null

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.BackColor = $script:Ink.Bg
    $host_.Controls.Add($flow)

    $boxes = New-Object 'System.Collections.Generic.List[System.Windows.Forms.CheckBox]'
    foreach ($g in $Groups) {
        if ($g.Items.Count -eq 0) { continue }
        $head = New-Object System.Windows.Forms.Label
        $head.Text = $g.Heading
        $head.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
        $head.ForeColor = $script:Ink.Accent
        $head.AutoSize = $true
        $head.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 4)
        $flow.Controls.Add($head)

        foreach ($item in $g.Items) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $item.Label
            $cb.Tag = $item.Tag
            $cb.Checked = [bool]$item.Checked
            $cb.AutoSize = $true
            $cb.MaximumSize = New-Object System.Drawing.Size(660, 0)
            $cb.Margin = New-Object System.Windows.Forms.Padding(16, 1, 0, 1)
            $cb.ForeColor = $script:Ink.Text
            $flow.Controls.Add($cb)
            $boxes.Add($cb)
        }
    }

    $count = New-Object System.Windows.Forms.Label
    $count.ForeColor = $script:Ink.Muted
    $count.Location = New-Object System.Drawing.Point(22, 4)
    $count.AutoSize = $true
    $status.Controls.Add($count)

    $refresh = {
        $n = @($boxes | Where-Object { $_.Checked }).Count
        $count.Text = "$n of $($boxes.Count) selected"
    }.GetNewClosure()
    foreach ($cb in $boxes) { $cb.Add_CheckedChanged($refresh) }
    & $refresh

    $all = New-WizardButton $bar 'Select All' 20 12 110 34
    $all.ForeColor = $script:Ink.Accent
    $all.Add_Click({ foreach ($cb in $boxes) { $cb.Checked = $true } }.GetNewClosure())

    $none = New-WizardButton $bar 'Deselect All' 138 12 110 34
    $none.Add_Click({ foreach ($cb in $boxes) { $cb.Checked = $false } }.GetNewClosure())

    $ok = New-WizardButton $bar $ConfirmText ($f.ClientSize.Width - 260) 10 130 38 $true
    $ok.Anchor = 'Top,Right'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.AcceptButton = $ok

    $cancel = New-WizardButton $bar 'Cancel' ($f.ClientSize.Width - 120) 10 105 38
    $cancel.Anchor = 'Top,Right'
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
    $ink = Get-Ink          # local copy: closures below can't see $script:Ink
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
            try {
                Set-SafeColor $status $ink.Bad
                $status.Text = ''
                $id = $tbId.Text.Trim()
                $pass = $tbPass.Text

                if ([string]::IsNullOrWhiteSpace($id)) { $status.Text = 'Enter your email or mobile.'; return }
                if ([string]::IsNullOrEmpty($pass)) { $status.Text = 'A passphrase is required.'; return }

                if (-not $state.Sent) {
                    $btnGo.Enabled = $false
                    Set-SafeColor $status $ink.Muted
                    $status.Text = 'Sending verification code...'
                    $f.Refresh()
                    try { $begin = $Manager.BeginVerification($id) }
                    catch { $begin = @{ Ok = $false; Error = $_.Exception.Message } }
                    $btnGo.Enabled = $true

                    if (-not $begin.Ok) {
                        Set-SafeColor $status $ink.Bad
                        $status.Text = "Couldn't send code: $($begin.Error)"
                        return
                    }
                    $state.Sent = $true
                    $lblCode.Visible = $true; $tbCode.Visible = $true; $tbCode.Focus()
                    $btnGo.Text = 'Verify'
                    Set-SafeColor $status $ink.Good
                    $status.Text = if ($begin.Method -eq 'dev') { 'Dev mode: code printed to the console.' }
                    else { "Code sent to your $($begin.Channel)." }
                    return
                }

                if (-not $Manager.Verified) {
                    $chk = $Manager.CompleteVerification($tbCode.Text)
                    if (-not $chk.Ok) {
                        Set-SafeColor $status $ink.Bad
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
            }
            catch {
                # Never let the raw .NET crash dialog surface here.
                $btnGo.Enabled = $true
                try {
                    Set-SafeColor $status $ink.Bad
                    $status.Text = 'Something went wrong -- see the console for details.'
                }
                catch { }
                Write-Host "Sign-in error: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
            }
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
