using module ..\Shared\Modules\SetupCore.psm1
using module ..\Shared\Modules\SetupInventory.psm1

<#
.SYNOPSIS
    Full test suite. Run after every change:

        powershell -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1

.DESCRIPTION
    Two rules this suite enforces, both learned the hard way:

    1. Every assertion is a scriptblock wrapped in try/catch. An earlier version
       passed conditions as bare expressions -- when one threw (module classes
       need `using module`, not Import-Module) the whole statement was abandoned
       and the test was never counted at all. The suite reported "55 passed"
       while entire sections had not executed.

    2. Anything involving closures, colours or scope is INVOKED, not just parsed.
       A parse-only suite stayed green while the sign-in dialog threw on every
       click, because $script:Ink is valid syntax but null inside a
       GetNewClosure() handler.
#>

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:Passed = 0
$script:Failed = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Section($name) {
    Write-Host ''
    Write-Host "== $name " -NoNewline -ForegroundColor Cyan
    Write-Host ('=' * [Math]::Max(0, 58 - $name.Length)) -ForegroundColor Cyan
}

function Test-That {
    # Scriptblock, not an expression: a throw must fail the test, never skip it.
    param([string]$Name, [scriptblock]$Condition)
    try {
        if (& $Condition) {
            Write-Host "  PASS  $Name" -ForegroundColor Green
            $script:Passed++
        }
        else {
            Write-Host "  FAIL  $Name" -ForegroundColor Red
            $script:Failed++; $script:Failures.Add($Name)
        }
    }
    catch {
        Write-Host "  FAIL  $Name  -- threw: $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++; $script:Failures.Add("$Name (threw)")
    }
}

function Test-NoThrow {
    param([string]$Name, [scriptblock]$Action)
    try { $null = & $Action; Test-That $Name { $true } }
    catch { Test-That "$Name -- threw: $($_.Exception.Message)" { $false } }
}

# =====================================================================
Section 'Syntax'
# =====================================================================
foreach ($f in @(
        'install.ps1',
        'Shared\Modules\SetupCore.psm1', 'Shared\Modules\SetupInventory.psm1',
        'Shared\Protect-Config.ps1', 'Shared\Admin\Get-SetupErrors.ps1',
        'Windows\Setup.ps1', 'Windows\Setup-UI.ps1', 'Windows\Setup-Wizard.ps1',
        'Windows\Setup-Flows.ps1', 'Windows\restore.ps1',
        'Windows\Build-Installer.ps1', 'Windows\Sign-Exe.ps1',
        'Mac\Setup.ps1', 'Mac\Setup-UI.ps1')) {
    $path = $f
    Test-That "parses: $f" {
        if (-not (Test-Path $path)) { return $false }
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $path).Path, [ref]$null, [ref]$errs)
        return (-not ($errs -and $errs.Count))
    }.GetNewClosure()
}

# Proves the types loaded, so later sections can't silently skip.
Test-That 'SetupCrypto type available' { $null -ne ('SetupCrypto' -as [type]) }
Test-That 'InventoryScanner type available' { $null -ne ('InventoryScanner' -as [type]) }
Test-That 'ErrorReporter type available' { $null -ne ('ErrorReporter' -as [type]) }

# =====================================================================
Section 'Encryption'
# =====================================================================
Test-That 'round-trips with the right passphrase' {
    $p = [SetupCrypto]::Protect('{"secret":"value"}', 'pass1')
    [SetupCrypto]::Unprotect($p, 'pass1') -eq '{"secret":"value"}'
}
Test-That 'rejects the wrong passphrase' {
    $p = [SetupCrypto]::Protect('{"secret":"value"}', 'pass1')
    [string]::IsNullOrEmpty([SetupCrypto]::Unprotect($p, 'wrong'))
}
Test-That 'rejects tampered ciphertext' {
    $p = [SetupCrypto]::Protect('{"secret":"value"}', 'pass1')
    $t = $p.Clone()
    $c = [char[]]$t.cipher; $c[3] = $(if ($c[3] -eq 'A') { 'B' } else { 'A' }); $t.cipher = -join $c
    [string]::IsNullOrEmpty([SetupCrypto]::Unprotect($t, 'pass1'))
}
Test-That 'ciphertext hides the plaintext' {
    ([SetupCrypto]::Protect('{"secret":"value"}', 'pass1')).cipher -notmatch 'secret|value'
}

# =====================================================================
Section 'Identity'
# =====================================================================
Test-That 'email normalised' { ([UserIdentity]::new('  Jane@Example.COM ')).Value -eq 'jane@example.com' }
Test-That 'mobile normalised' { ([UserIdentity]::new('+91 (98765) 43210')).ToE164() -eq '+919876543210' }
Test-That 'email channel' { ([UserIdentity]::new('a@b.com')).AuthChannel() -eq 'email' }
Test-That 'sms channel' { ([UserIdentity]::new('9876543210')).AuthChannel() -eq 'sms' }
Test-That 'id is stable' { ([UserIdentity]::new('JANE@example.com')).Id -eq ([UserIdentity]::new('jane@EXAMPLE.com')).Id }
Test-That 'id is 32 chars' { ([UserIdentity]::new('a@b.com')).Id.Length -eq 32 }
Test-That 'raw email not in id' { ([UserIdentity]::new('jane@example.com')).Id -notmatch 'jane' }
Test-That 'blank identity rejected' {
    try { [UserIdentity]::new('   ') | Out-Null; return $false } catch { return $true }
}

# =====================================================================
Section 'OTP verification'
# =====================================================================
# A first-time address is confirmed as 'signup', a returning one as 'email'.
Test-That 'verify accepts both email and signup types' {
    $src = Get-Content .\Shared\Modules\SetupCore.psm1 -Raw
    $src -match "@\('email', 'signup'\)"
}
Test-That 'otp email templates must not send a link' {
    # A link lands on localhost and mail scanners pre-click it, burning the code.
    $src = Get-Content .\Shared\Modules\SetupCore.psm1 -Raw
    ($src -notmatch 'ConfirmationURL') -and ($src -notmatch 'email_redirect_to')
}
Test-NoThrow 'verify fails gracefully when unreachable' {
    $c = [SupabaseClient]::new([SupabaseConfig]::new())
    $r = $c.VerifyOtp([UserIdentity]::new('a@b.com'), '123456')
    if ($r.Ok) { throw 'unreachable endpoint reported success' }
}

# =====================================================================
Section 'Profile data'
# =====================================================================
$mk = {
    New-ProfileData -Name 'T' -Packages @('Git.Git') -Features @('zsh') `
        -Apps @(@{ name = 'VS Code'; id = 'Microsoft.VisualStudioCode' }) `
        -Repos @(@{ name = 'r'; remote = 'https://x/y.git'; branch = 'main' }) `
        -Dotfiles @(@{ name = '.zshrc'; target = '.zshrc'; content = 'alias ll="ls -la"' }) `
        -Tools @{ vscode = @('ms-python.python') }
}
Test-That 'apps survive' { ((& $mk).ToJson() | ConvertFrom-Json).apps.Count -eq 1 }
Test-That 'repos survive' { ((& $mk).ToJson() | ConvertFrom-Json).repos.Count -eq 1 }
Test-That 'dotfiles survive' { ((& $mk).ToJson() | ConvertFrom-Json).dotfiles[0].content -match 'alias' }
Test-That 'tools survive' { ((& $mk).ToJson() | ConvertFrom-Json).tools.vscode.Count -eq 1 }
Test-That 'schema is 3' { ((& $mk).ToJson() | ConvertFrom-Json).schema -eq 3 }
Test-That 'empty json safe' { [ProfileData]::FromJson('').Packages.Count -eq 0 }
Test-That 'garbage json safe' { [ProfileData]::FromJson('not json').Packages.Count -eq 0 }
Test-That 'null json safe' { [ProfileData]::FromJson($null).Packages.Count -eq 0 }

# =====================================================================
Section 'Secret exclusion'
# =====================================================================
Test-That 'blocks .git-credentials' { [InventoryScanner]::LooksSecret('C:\u\.git-credentials', 'x') }
Test-That 'blocks private key body' { [InventoryScanner]::LooksSecret('C:\u\.zshrc', '-----BEGIN OPENSSH PRIVATE KEY-----') }
Test-That 'blocks npm auth token' { [InventoryScanner]::LooksSecret('C:\u\.npmrc', '//r/:_authToken=abc') }
Test-That 'blocks docker auths' { [InventoryScanner]::LooksSecret('C:\u\config.json', '{"auths": {}}') }
Test-That 'blocks aws secret' { [InventoryScanner]::LooksSecret('C:\u\credentials', 'aws_secret_access_key=A') }
Test-That 'blocks github token' { [InventoryScanner]::LooksSecret('C:\u\.zshrc', 'ghp_abcdefghij0123456789xyz') }
Test-That 'blocks id_rsa by name' { [InventoryScanner]::LooksSecret('C:\u\.ssh\id_rsa', 'x') }
Test-That 'allows a normal .zshrc' { -not [InventoryScanner]::LooksSecret('C:\u\.zshrc', "alias ll='ls -la'") }
Test-That 'allows a normal .gitconfig' { -not [InventoryScanner]::LooksSecret('C:\u\.gitconfig', "[user]`n name = J") }
Test-That 'real scan leaks nothing' {
    $dots = (New-InventoryScanner).ScanDotfiles()
    @($dots | Where-Object { [InventoryScanner]::LooksSecret($_.Path, $_.Content) }).Count -eq 0
}

# =====================================================================
Section 'Inventory filtering'
# =====================================================================
Test-That 'filters Steam' { [InventoryScanner]::IsGame('Steam') }
Test-That 'filters by path' { [InventoryScanner]::IsGame('C:\Steam\steamapps\common\X') }
Test-That 'keeps VS Code' { -not [InventoryScanner]::IsGame('Visual Studio Code') }
Test-That 'drops KB updates' { [InventoryScanner]::IsNoise('Update for Office KB1234567') }
Test-That 'classifies runtime' { [InventoryScanner]::Classify('Microsoft VC++ Redistributable') -eq 'runtime' }
Test-That 'finds real apps' { (New-InventoryScanner).ScanApplications().Count -gt 5 }
Test-That 'no games in results' {
    @((New-InventoryScanner).ScanApplications() | Where-Object { [InventoryScanner]::IsGame($_.Name) }).Count -eq 0
}

# =====================================================================
Section 'Config safety'
# =====================================================================
Test-That 'config decrypts' { -not [string]::IsNullOrWhiteSpace((New-ProfileManager -SharedRoot (Resolve-Path .\Shared).Path).Config.Url) }
Test-That 'uses publishable key' { (New-ProfileManager -SharedRoot (Resolve-Path .\Shared).Path).Config.Key -like 'sb_publishable*' }
Test-That 'rejects secret keys' { [SupabaseConfig]::LooksSecret('sb_secret_abc123') }
Test-That 'rejects service_role' { [SupabaseConfig]::LooksSecret('eyJ_service_role_x') }
Test-That 'no plaintext key on disk' { (Get-Content Shared\Config\supabase-config.json -Raw) -notmatch 'sb_publishable' }
Test-That 'no secret keys committed' {
    $needle = 'sb_' + 'secret_[A-Za-z0-9]{10,}|xkey' + 'sib-[A-Za-z0-9]{20,}'
    $null -eq (Get-ChildItem -Recurse -File -Include *.ps1, *.psm1, *.json, *.yml, *.md |
        Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -ne 'Run-Tests.ps1' } |
        Select-String -Pattern $needle -ErrorAction SilentlyContinue)
}

# =====================================================================
Section 'UI behaviour (handlers invoked, not just parsed)'
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. .\Windows\Setup-Wizard.ps1

Test-That 'Get-Ink returns real colours' { (Get-Ink).Bad -is [System.Drawing.Color] }
Test-NoThrow 'Set-SafeColor tolerates null' {
    Set-SafeColor (New-Object System.Windows.Forms.Label) $null
}
Test-That 'null colour still throws unguarded' {
    $l = New-Object System.Windows.Forms.Label
    try { $l.ForeColor = $null; return $false } catch { return $true }
}
# The exact shipped failure: a handler reading a script-scope colour.
Test-That 'click handler runs and sets a colour' {
    $ink = Get-Ink
    $btn = New-Object System.Windows.Forms.Button
    $lb = New-Object System.Windows.Forms.Label
    $btn.Add_Click({ Set-SafeColor $lb $ink.Bad; $lb.Text = 'handled' }.GetNewClosure())
    $btn.PerformClick()
    ($lb.Text -eq 'handled') -and ($lb.ForeColor.R -gt 0)
}
# The shipped crash, and the reason it survived a green suite.
#
# A GetNewClosure() handler resolves commands against global scope, not the
# script scope this file was dot-sourced into. Those are the same thing for a
# top-level `powershell -File` run, and different in production, where
# install.ps1 invokes Setup.ps1 one scope down. So the in-process test passed
# on a laptop and the identical code threw "Set-SafeColor is not recognized"
# for the user.
#
# Run the probe in a child process with -Command & to pin the production scope
# depth, instead of inheriting whatever depth this suite happens to run at.
Test-That 'handler resolves helpers at production scope depth' {
    $probe = Join-Path $env:TEMP 'setup-scope-probe.ps1'
    @'
. .\Windows\Setup-Wizard.ps1
$ink = Get-Ink
$lb = New-Object System.Windows.Forms.Label
$btn = New-Object System.Windows.Forms.Button
$btn.Add_Click({ Set-SafeColor $lb $ink.Bad; $lb.Text = 'handled' }.GetNewClosure())
try { $btn.PerformClick() } catch { }
if ($lb.Text -eq 'handled') { 'PROBE=OK' } else { 'PROBE=BAD' }
'@ | Set-Content -Path $probe -Encoding UTF8
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$probe'" 2>&1
        "$out" -match 'PROBE=OK'
    }
    finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
}
# Structural backstop: true or false identically in every topology.
Test-That 'closure-facing helpers are declared global' {
    $src = Get-Content .\Windows\Setup-Wizard.ps1 -Raw
    ($src -match 'function global:Set-SafeColor') -and ($src -match 'function global:Get-Ink')
}
Test-That 'no colour lookups inside handlers' {
    $null -eq (Select-String -Path .\Windows\Setup-Wizard.ps1 -Pattern 'script:Ink' |
        Where-Object { $_.Line -match 'param\(\$s, \$e\)|Add_Click' })
}
Test-That 'unhandled exception mode set' { Select-String -Path .\Windows\Setup-Wizard.ps1 -Pattern 'SetUnhandledExceptionMode' -Quiet }
Test-That 'sign-in handler has a catch' { Select-String -Path .\Windows\Setup-Wizard.ps1 -Pattern 'Sign-in error' -Quiet }

foreach ($fn in @('Show-ModeDialog', 'Show-ChecklistDialog', 'Show-RepoFolderDialog',
        'Show-SignInDialog', 'New-WizardForm', 'New-ScrollHost', 'New-ButtonBar')) {
    # Not GetNewClosure(): a closure runs in its own module scope and cannot see
    # script-scoped functions, so every one of these would report a false FAIL.
    Test-That "defined: $fn" ([scriptblock]::Create("[bool](Get-Command '$fn' -ErrorAction SilentlyContinue)"))
}
Test-That 'form scales with DPI' { (New-WizardForm -Title 't' -Width 500 -Height 400).AutoScaleMode -eq [System.Windows.Forms.AutoScaleMode]::Font }
Test-That 'form is resizable' { (New-WizardForm -Title 't' -Width 500 -Height 400).FormBorderStyle -eq 'Sizable' }
Test-NoThrow 'scroll host + button bar build' {
    $f = New-WizardForm -Title 't' -Width 500 -Height 400
    New-ScrollHost $f | Out-Null; New-ButtonBar $f | Out-Null; $f.Dispose()
}

# =====================================================================
Section 'Flow wiring'
# =====================================================================
. .\Windows\Setup-Flows.ps1
foreach ($fn in @('Invoke-BackupFlow', 'Invoke-RestoreFlow', 'Restore-Repositories',
        'Restore-Dotfiles', 'Restore-ToolLists')) {
    Test-That "defined: $fn" ([scriptblock]::Create("[bool](Get-Command '$fn' -ErrorAction SilentlyContinue)"))
}
Test-That 'flows avoid module type literals' {
    -not (Select-String -Path .\Windows\Setup-Flows.ps1 -Pattern '\-is \[(InstalledApp|GitRepository)\]' -Quiet)
}
Test-That 'sign-in comes before scanning' {
    $src = Get-Content .\Windows\Setup-Flows.ps1 -Raw
    $a = $src.IndexOf('Show-SignInDialog'); $b = $src.IndexOf('ScanApplications')
    ($a -gt 0) -and ($a -lt $b)
}
Test-NoThrow 'empty restores are no-ops' {
    $m = New-ProfileManager -SharedRoot (Resolve-Path .\Shared).Path
    Restore-Repositories -Repos @() -Manager $m
    Restore-Dotfiles -Dotfiles @() -Manager $m
    Restore-ToolLists -Tools @{} -Manager $m
}

# =====================================================================
Section 'Error reporting'
# =====================================================================
Test-That 'queues when offline instead of throwing' {
    $r = [ErrorReporter]::new([SupabaseConfig]::new())
    $r.Report('packages', 'X', 'failed', 'exit 1')
    $r.PendingCount() -eq 1
}
Test-That 'ignores empty messages' {
    $r = [ErrorReporter]::new([SupabaseConfig]::new())
    $r.Report('x', '', '', '')
    $r.PendingCount() -eq 0
}
Test-That 'platform detected' {
    ([ErrorReporter]::new([SupabaseConfig]::new())).Platform -in @('windows', 'macos')
}

# =====================================================================
Write-Host ''
Write-Host ('=' * 62) -ForegroundColor Cyan
$total = $script:Passed + $script:Failed
if ($script:Failed -eq 0) {
    Write-Host "ALL $total TESTS PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Passed)/$total passed, $($script:Failed) FAILED" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
