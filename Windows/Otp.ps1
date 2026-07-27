<#
.SYNOPSIS
    One-time-passcode (OTP) verification for email / mobile identifiers.
.DESCRIPTION
    Proves that the person entering an email address or mobile number actually
    controls it, before their setup profile is created or loaded.

    Flow:
      New-OtpChallenge  -> generates a 6-digit code, sends it, returns a
                           challenge object that holds ONLY a salted hash of the
                           code (never the code itself), an expiry, and an
                           attempt counter.
      Test-OtpResponse  -> constant-time-checks the user's input against the
                           hash, enforcing expiry + max attempts.

    Delivery is pluggable and reads credentials ONLY from environment variables
    or a git-ignored local config (Windows\users\.otp-config.json). Secrets are
    NEVER hard-coded or committed.

      Email (SMTP):  SETUP_OTP_SMTP_HOST, SETUP_OTP_SMTP_PORT,
                     SETUP_OTP_SMTP_USER, SETUP_OTP_SMTP_PASS,
                     SETUP_OTP_SMTP_FROM, SETUP_OTP_SMTP_SSL (default true)
      Mobile (Twilio): SETUP_OTP_TWILIO_SID, SETUP_OTP_TWILIO_TOKEN,
                       SETUP_OTP_TWILIO_FROM
      Mobile (generic HTTP): SETUP_OTP_SMS_API_URL, SETUP_OTP_SMS_API_KEY,
                             SETUP_OTP_SMS_FROM

    If no channel is configured, set SETUP_OTP_DEV=1 to print the code to the
    console (and a git-ignored .otp-dev.txt) for local testing.

    Requires only .NET crypto shipped with Windows PowerShell 5.1.
#>

$script:OtpKeys = @(
    'SMTP_HOST', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM', 'SMTP_SSL',
    'SMS_API_URL', 'SMS_API_KEY', 'SMS_FROM',
    'TWILIO_SID', 'TWILIO_TOKEN', 'TWILIO_FROM'
)

function Get-OtpConfig {
    $cfg = @{}
    # 1) git-ignored local file (reuse the users\ dir so there's one place).
    if (Get-Command Get-ProfileStoreDir -ErrorAction SilentlyContinue) {
        $local = Join-Path (Get-ProfileStoreDir) '.otp-config.json'
        if (Test-Path $local) {
            try {
                $json = Get-Content $local -Raw | ConvertFrom-Json
                foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = [string]$p.Value }
            }
            catch { }
        }
    }
    # 2) environment variables (override the file).
    foreach ($k in $script:OtpKeys) {
        $v = [Environment]::GetEnvironmentVariable("SETUP_OTP_$k")
        if (-not [string]::IsNullOrEmpty($v)) { $cfg[$k] = $v }
    }
    return $cfg
}

function New-OtpCode {
    param([int]$Length = 6)
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $bytes) { [void]$sb.Append(($b % 10).ToString()) }
    return $sb.ToString()
}

function Get-OtpHash {
    param([string]$Code, [string]$SaltB64)
    $salt = [Convert]::FromBase64String($SaltB64)
    $codeBytes = [System.Text.Encoding]::UTF8.GetBytes($Code)
    $buf = New-Object byte[] ($salt.Length + $codeBytes.Length)
    [Array]::Copy($salt, 0, $buf, 0, $salt.Length)
    [Array]::Copy($codeBytes, 0, $buf, $salt.Length, $codeBytes.Length)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($buf) } finally { $sha.Dispose() }
    return [Convert]::ToBase64String($hash)
}

function Test-OtpHashEqual {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    $ba = [System.Text.Encoding]::ASCII.GetBytes($A)
    $bb = [System.Text.Encoding]::ASCII.GetBytes($B)
    if ($ba.Length -ne $bb.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $ba.Length; $i++) { $diff = $diff -bor ($ba[$i] -bxor $bb[$i]) }
    return ($diff -eq 0)
}

# ---------------------------------------------------------------------------
# Delivery adapters
# ---------------------------------------------------------------------------

function Send-OtpEmail {
    param($Cfg, [string]$To, [string]$Code)
    if ([string]::IsNullOrEmpty($Cfg.SMTP_HOST)) { return @{ Sent = $false; Method = 'none'; Error = 'SMTP not configured' } }
    try {
        $from = $Cfg.SMTP_FROM; if ([string]::IsNullOrEmpty($from)) { $from = $Cfg.SMTP_USER }
        $port = 587; if (-not [string]::IsNullOrEmpty($Cfg.SMTP_PORT)) { $port = [int]$Cfg.SMTP_PORT }
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress($from)
        $msg.To.Add($To)
        $msg.Subject = 'Your System-Setup verification code'
        $msg.Body = "Your System-Setup verification code is: $Code`r`n`r`nIt expires in 5 minutes. If you didn't request this, ignore this email."
        $smtp = New-Object System.Net.Mail.SmtpClient($Cfg.SMTP_HOST, $port)
        $smtp.EnableSsl = ($Cfg.SMTP_SSL -ne 'false')
        if (-not [string]::IsNullOrEmpty($Cfg.SMTP_USER)) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential($Cfg.SMTP_USER, $Cfg.SMTP_PASS)
        }
        $smtp.Send($msg)
        $msg.Dispose()
        return @{ Sent = $true; Method = 'email' }
    }
    catch { return @{ Sent = $false; Method = 'email'; Error = $_.Exception.Message } }
}

function Send-OtpSms {
    param($Cfg, [string]$To, [string]$Code)
    $text = "System-Setup verification code: $Code (expires in 5 minutes)"
    # Twilio
    if (-not [string]::IsNullOrEmpty($Cfg.TWILIO_SID) -and
        -not [string]::IsNullOrEmpty($Cfg.TWILIO_TOKEN) -and
        -not [string]::IsNullOrEmpty($Cfg.TWILIO_FROM)) {
        try {
            $uri = "https://api.twilio.com/2010-04-01/Accounts/$($Cfg.TWILIO_SID)/Messages.json"
            $body = @{ To = $To; From = $Cfg.TWILIO_FROM; Body = $text }
            $sec = ConvertTo-SecureString $Cfg.TWILIO_TOKEN -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($Cfg.TWILIO_SID, $sec)
            Invoke-RestMethod -Uri $uri -Method Post -Body $body -Credential $cred -TimeoutSec 30 | Out-Null
            return @{ Sent = $true; Method = 'sms' }
        }
        catch { return @{ Sent = $false; Method = 'sms'; Error = $_.Exception.Message } }
    }
    # Generic HTTP webhook
    if (-not [string]::IsNullOrEmpty($Cfg.SMS_API_URL)) {
        try {
            $headers = @{}
            if (-not [string]::IsNullOrEmpty($Cfg.SMS_API_KEY)) { $headers['Authorization'] = "Bearer $($Cfg.SMS_API_KEY)" }
            $payload = @{ to = $To; text = $text }
            if (-not [string]::IsNullOrEmpty($Cfg.SMS_FROM)) { $payload['from'] = $Cfg.SMS_FROM }
            Invoke-RestMethod -Uri $Cfg.SMS_API_URL -Method Post -Headers $headers `
                -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30 | Out-Null
            return @{ Sent = $true; Method = 'sms' }
        }
        catch { return @{ Sent = $false; Method = 'sms'; Error = $_.Exception.Message } }
    }
    return @{ Sent = $false; Method = 'none'; Error = 'SMS not configured' }
}

function Send-OtpCode {
    param(
        [Parameter(Mandatory)][ValidateSet('email', 'mobile')][string]$Channel,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Code
    )
    $cfg = Get-OtpConfig
    if ($Channel -eq 'email') { $res = Send-OtpEmail -Cfg $cfg -To $Target -Code $Code }
    else { $res = Send-OtpSms -Cfg $cfg -To $Target -Code $Code }
    if ($res.Sent) { return $res }

    # Local test fallback -- only when explicitly enabled.
    if ([Environment]::GetEnvironmentVariable('SETUP_OTP_DEV') -eq '1') {
        Write-Host "[OTP DEV] $Channel code for $Target = $Code" -ForegroundColor Yellow
        try {
            if (Get-Command Get-ProfileStoreDir -ErrorAction SilentlyContinue) {
                $p = Join-Path (Get-ProfileStoreDir) '.otp-dev.txt'
                "$([DateTime]::Now.ToString('s'))  $Target  $Code" | Add-Content -Path $p
            }
        }
        catch { }
        return @{ Sent = $true; Method = 'dev' }
    }
    return $res
}

# ---------------------------------------------------------------------------
# Challenge / verify
# ---------------------------------------------------------------------------

function New-OtpChallenge {
    param(
        [Parameter(Mandatory)][ValidateSet('email', 'mobile')][string]$Channel,
        [Parameter(Mandatory)][string]$Target,
        [int]$TtlSeconds = 300,
        [int]$MaxAttempts = 5,
        [int]$Length = 6
    )
    $code = New-OtpCode -Length $Length
    $saltBytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($saltBytes) } finally { $rng.Dispose() }
    $saltB64 = [Convert]::ToBase64String($saltBytes)
    $hash = Get-OtpHash -Code $code -SaltB64 $saltB64

    $send = Send-OtpCode -Channel $Channel -Target $Target -Code $code
    # The plaintext code goes out of scope here -- only its hash is retained.

    return @{
        Salt        = $saltB64
        Hash        = $hash
        Expires     = (Get-Date).AddSeconds($TtlSeconds)
        Attempts    = 0
        MaxAttempts = $MaxAttempts
        Channel     = $Channel
        Target      = $Target
        Sent        = $send.Sent
        Method      = $send.Method
        Error       = $send.Error
    }
}

function Test-OtpResponse {
    param(
        [Parameter(Mandatory)]$Challenge,
        [Parameter(Mandatory)][string]$InputCode
    )
    if ($null -eq $Challenge) { return @{ Ok = $false; Reason = 'no active code' } }
    if ((Get-Date) -gt $Challenge.Expires) { return @{ Ok = $false; Reason = 'code expired -- request a new one' } }
    if ($Challenge.Attempts -ge $Challenge.MaxAttempts) { return @{ Ok = $false; Reason = 'too many attempts' } }
    $Challenge.Attempts++

    $clean = ($InputCode -replace '\D', '')
    if ([string]::IsNullOrEmpty($clean)) { return @{ Ok = $false; Reason = 'enter the code you received' } }

    $inHash = Get-OtpHash -Code $clean -SaltB64 $Challenge.Salt
    if (Test-OtpHashEqual $inHash $Challenge.Hash) { return @{ Ok = $true; Reason = 'verified' } }

    $left = $Challenge.MaxAttempts - $Challenge.Attempts
    if ($left -le 0) { return @{ Ok = $false; Reason = 'too many attempts' } }
    return @{ Ok = $false; Reason = "incorrect code ($left attempt(s) left)" }
}
