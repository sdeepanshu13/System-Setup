# End-to-end check: real OTP -> auth -> encrypted save -> reload -> cleanup.
# Creates a temporary profile row and deletes it afterwards.
$ErrorActionPreference = 'Stop'
Import-Module .\Shared\Modules\SetupCore.psm1 -Force

$email = 'sdeepanshu13@yahoo.com'
$testPass = 'e2e-temporary-passphrase'
$mgr = New-ProfileManager -SharedRoot (Resolve-Path .\Shared).Path

Write-Host ''
Write-Host ('Backend      : ' + $(if ($mgr.IsOnline()) { 'Supabase (online)' } else { 'local files' }))
Write-Host ("Sending code to $email ...") -ForegroundColor Cyan

$begin = $mgr.BeginVerification($email)
if (-not $begin.Ok) {
    Write-Host ('FAILED to send: ' + $begin.Error) -ForegroundColor Red
    exit 1
}
Write-Host ("Code sent via $($begin.Channel). Check your inbox (and spam).") -ForegroundColor Green
Write-Host ''
Write-Host 'Paste EITHER the 6-digit code OR the full sign-in link from the email.' -ForegroundColor DarkGray
Write-Host '(The default Supabase template sends a link; {{ .Token }} sends a code.)' -ForegroundColor DarkGray
Write-Host ''

$answer = Read-Host 'Code or link'

function Get-JwtSubject([string]$jwt) {
    $payload = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    return (([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))) | ConvertFrom-Json).sub
}

if ($answer -match 'access_token=([^&\s]+)') {
    # Magic-link flow: the redirect URL already carries a verified session.
    $mgr.Client.AccessToken = $Matches[1]
    $mgr.Client.UserId = Get-JwtSubject $mgr.Client.AccessToken
    Write-Host 'PASS  session extracted from redirect URL' -ForegroundColor Green
}
elseif ($answer -match '[?&]token=([a-f0-9]{20,})') {
    # Raw verification URL: exchange the token hash for a session.
    $hash = $Matches[1]
    $type = if ($answer -match 'type=([a-z]+)') { $Matches[1] } else { 'magiclink' }
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$($mgr.Config.Url)/auth/v1/verify" `
            -Headers @{ apikey = $mgr.Config.Key; 'Content-Type' = 'application/json' } `
            -Body (@{ token_hash = $hash; type = $type } | ConvertTo-Json) -TimeoutSec 30
        $mgr.Client.AccessToken = $r.access_token
        $mgr.Client.UserId = $r.user.id
        Write-Host 'PASS  token hash exchanged for a session' -ForegroundColor Green
    }
    catch {
        Write-Host 'FAILED to exchange token hash (already used or expired).' -ForegroundColor Red
        Write-Host 'Magic links are single-use -- request a fresh email.' -ForegroundColor Yellow
        exit 1
    }
}
else {
    $ver = $mgr.CompleteVerification($answer)
    if (-not $ver.Ok) {
        Write-Host ('VERIFY FAILED: ' + $ver.Reason) -ForegroundColor Red
        exit 1
    }
    Write-Host 'PASS  code verified server-side' -ForegroundColor Green
}
Write-Host ('      user id: ' + $mgr.Client.UserId) -ForegroundColor DarkGray

# Save an encrypted profile
$data = New-ProfileData -Name 'Deepanshu Singhal' `
    -Packages @('Git.Git', 'Microsoft.VisualStudioCode', 'Docker.DockerDesktop') `
    -Features @('zsh', 'gitssh', 'vscode') -DefaultShell '1'
$save = $mgr.SaveProfile($testPass, $data)
if (-not $save.Ok) { Write-Host ('SAVE FAILED: ' + $save.Error) -ForegroundColor Red; exit 1 }
Write-Host 'PASS  profile saved (encrypted) to Supabase' -ForegroundColor Green

# Confirm the server really stored ciphertext, not plaintext
$cfg = $mgr.Config
$raw = Invoke-RestMethod -Method Get -Headers @{ apikey = $cfg.Key; Authorization = "Bearer $($mgr.Client.AccessToken)" } `
    -Uri "$($cfg.Url)/rest/v1/user_profiles?user_id=eq.$($mgr.Client.UserId)&select=cipher,salt,iv,mac"
$stored = @($raw)[0]
Write-Host ('      stored cipher: ' + $stored.cipher.Substring(0, [Math]::Min(48, $stored.cipher.Length)) + '...') -ForegroundColor DarkGray
if ($stored.cipher -match 'Git|Docker|zsh|Deepanshu') {
    Write-Host 'FAIL  plaintext leaked into the database!' -ForegroundColor Red
}
else {
    Write-Host 'PASS  database holds ciphertext only (no readable selections)' -ForegroundColor Green
}

# Reload as a fresh client, as a new machine would
$mgr2 = New-ProfileManager -SharedRoot (Resolve-Path .\Shared).Path
$mgr2.Client.AccessToken = $mgr.Client.AccessToken
$mgr2.Client.UserId = $mgr.Client.UserId
$mgr2.Identity = $mgr.Identity

$load = $mgr2.LoadProfile($testPass)
if ($load.Found -and $load.Decrypted) {
    Write-Host 'PASS  reloaded and decrypted on a fresh client' -ForegroundColor Green
    Write-Host ('      name     : ' + $load.Data.Name)
    Write-Host ('      packages : ' + ($load.Data.Packages -join ', '))
    Write-Host ('      features : ' + ($load.Data.Features -join ', '))
    Write-Host ('      shell    : ' + $load.Data.DefaultShell)
}
else { Write-Host 'FAIL  could not reload profile' -ForegroundColor Red }

# Wrong passphrase must be rejected
$bad = $mgr2.LoadProfile('definitely-not-the-passphrase')
if ($bad.Found -and -not $bad.Decrypted) { Write-Host 'PASS  wrong passphrase rejected' -ForegroundColor Green }
else { Write-Host 'FAIL  wrong passphrase was accepted!' -ForegroundColor Red }

# Clean up the test row
try {
    Invoke-RestMethod -Method Delete -Headers @{ apikey = $cfg.Key; Authorization = "Bearer $($mgr.Client.AccessToken)" } `
        -Uri "$($cfg.Url)/rest/v1/user_profiles?user_id=eq.$($mgr.Client.UserId)" | Out-Null
    Write-Host 'PASS  test row deleted (nothing left behind)' -ForegroundColor Green
}
catch { Write-Host ('NOTE  cleanup failed: ' + $_.Exception.Message) -ForegroundColor Yellow }

Write-Host ''
Write-Host 'END-TO-END TEST COMPLETE' -ForegroundColor Cyan
