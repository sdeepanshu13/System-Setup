<#
.SYNOPSIS
    Supabase-backed profile storage with real server-side OTP verification.
.DESCRIPTION
    Talks to Supabase over plain REST (Invoke-RestMethod) -- no npm, no SDK.

    Two things happen here:
      1. AUTH: Supabase Auth sends a one-time code to the user's email (or phone)
         and verifies it SERVER-SIDE, returning a signed JWT. Unlike a locally
         generated code, this cannot be bypassed by tampering with the script.
      2. STORAGE: the user's selections -- already AES-256 encrypted on their own
         machine -- are upserted into public.user_profiles. Row-level security
         ties each row to auth.uid(), so a user can only touch their own.

    The database only ever sees ciphertext. The passphrase never leaves the
    machine, so not even the project owner can read anyone's selections.

    Only the PUBLISHABLE (anon) key is used here. It is safe to ship: RLS is what
    protects the data. NEVER put the secret / service-role key in this file.

    Config resolution order:
      1. env: SETUP_SUPABASE_URL, SETUP_SUPABASE_KEY
      2. supabase-config.json next to this script
#>

if ($PSScriptRoot) { $script:SupabaseBaseDir = $PSScriptRoot }
else { $script:SupabaseBaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# PS 5.1 still negotiates TLS 1.0 by default, which Supabase rejects.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }

function Get-SupabaseConfig {
    if ($script:SupabaseConfigCache) { return $script:SupabaseConfigCache }
    $cfg = @{ Url = $null; Key = $null }

    $file = Join-Path $script:SupabaseBaseDir 'supabase-config.json'
    if (Test-Path $file) {
        try {
            $json = Get-Content $file -Raw | ConvertFrom-Json
            if ($json.url) { $cfg.Url = [string]$json.url }
            if ($json.publishableKey) { $cfg.Key = [string]$json.publishableKey }
        }
        catch { }
    }
    $envUrl = [Environment]::GetEnvironmentVariable('SETUP_SUPABASE_URL')
    $envKey = [Environment]::GetEnvironmentVariable('SETUP_SUPABASE_KEY')
    if (-not [string]::IsNullOrWhiteSpace($envUrl)) { $cfg.Url = $envUrl }
    if (-not [string]::IsNullOrWhiteSpace($envKey)) { $cfg.Key = $envKey }

    if ($cfg.Url) { $cfg.Url = $cfg.Url.TrimEnd('/') }
    $script:SupabaseConfigCache = $cfg
    return $cfg
}

function Test-SupabaseEnabled {
    $cfg = Get-SupabaseConfig
    return (-not [string]::IsNullOrWhiteSpace($cfg.Url)) -and (-not [string]::IsNullOrWhiteSpace($cfg.Key))
}

function Get-SupabaseErrorMessage {
    param($ErrorRecord)
    # Supabase returns useful JSON in the body of 4xx responses.
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) {
                try {
                    $j = $body | ConvertFrom-Json
                    foreach ($p in @('msg', 'message', 'error_description', 'error')) {
                        if ($j.PSObject.Properties.Name -contains $p -and $j.$p) { return [string]$j.$p }
                    }
                }
                catch { return $body }
            }
        }
    }
    catch { }
    return $ErrorRecord.Exception.Message
}

function ConvertTo-SupabaseTarget {
    <# Split an identifier into the shape Supabase Auth expects. #>
    param([Parameter(Mandatory)][string]$Identifier)
    $id = $Identifier.Trim()
    if ($id -match '@') {
        return @{ Channel = 'email'; Email = $id.ToLowerInvariant() }
    }
    $digits = ($id -replace '\D', '')
    return @{ Channel = 'sms'; Phone = "+$digits" }
}

function Send-SupabaseOtp {
    <# Ask Supabase to email/SMS a one-time code. Returns @{ Ok; Channel; Error }. #>
    param([Parameter(Mandatory)][string]$Identifier)
    $cfg = Get-SupabaseConfig
    $t = ConvertTo-SupabaseTarget $Identifier
    $body = @{ should_create_user = $true }
    if ($t.Channel -eq 'email') { $body['email'] = $t.Email } else { $body['phone'] = $t.Phone }

    try {
        Invoke-RestMethod -Method Post -Uri "$($cfg.Url)/auth/v1/otp" `
            -Headers @{ apikey = $cfg.Key; 'Content-Type' = 'application/json' } `
            -Body ($body | ConvertTo-Json) -TimeoutSec 30 | Out-Null
        return @{ Ok = $true; Channel = $t.Channel }
    }
    catch {
        return @{ Ok = $false; Channel = $t.Channel; Error = (Get-SupabaseErrorMessage $_) }
    }
}

function Confirm-SupabaseOtp {
    <# Verify the code server-side. Returns @{ Ok; AccessToken; UserId; Error }. #>
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][string]$Code
    )
    $cfg = Get-SupabaseConfig
    $t = ConvertTo-SupabaseTarget $Identifier
    $clean = ($Code -replace '\D', '')
    $body = @{ token = $clean; type = $t.Channel }
    if ($t.Channel -eq 'email') { $body['email'] = $t.Email } else { $body['phone'] = $t.Phone }

    try {
        $r = Invoke-RestMethod -Method Post -Uri "$($cfg.Url)/auth/v1/verify" `
            -Headers @{ apikey = $cfg.Key; 'Content-Type' = 'application/json' } `
            -Body ($body | ConvertTo-Json) -TimeoutSec 30
        if (-not $r.access_token) { return @{ Ok = $false; Error = 'no token returned' } }
        return @{ Ok = $true; AccessToken = $r.access_token; UserId = $r.user.id }
    }
    catch {
        return @{ Ok = $false; Error = (Get-SupabaseErrorMessage $_) }
    }
}

function Get-SupabaseProfileRow {
    <# Fetch this user's encrypted row. Returns @{ Ok; Found; Row; Error }. #>
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$UserId
    )
    $cfg = Get-SupabaseConfig
    try {
        $r = Invoke-RestMethod -Method Get `
            -Uri "$($cfg.Url)/rest/v1/user_profiles?user_id=eq.$UserId&select=salt,iv,mac,cipher,iterations" `
            -Headers @{ apikey = $cfg.Key; Authorization = "Bearer $AccessToken" } -TimeoutSec 30
        if ($r -and @($r).Count -gt 0) { return @{ Ok = $true; Found = $true; Row = @($r)[0] } }
        return @{ Ok = $true; Found = $false }
    }
    catch {
        return @{ Ok = $false; Found = $false; Error = (Get-SupabaseErrorMessage $_) }
    }
}

function Save-SupabaseProfileRow {
    <# Upsert the encrypted payload for this user. Returns @{ Ok; Error }. #>
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)]$Protected,
        [int]$Iterations = 200000
    )
    $cfg = Get-SupabaseConfig
    $row = @{
        user_id    = $UserId
        salt       = $Protected.salt
        iv         = $Protected.iv
        mac        = $Protected.mac
        cipher     = $Protected.cipher
        iterations = $Iterations
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
        Invoke-RestMethod -Method Post -Uri "$($cfg.Url)/rest/v1/user_profiles" `
            -Headers @{
                apikey          = $cfg.Key
                Authorization   = "Bearer $AccessToken"
                'Content-Type'  = 'application/json'
                Prefer          = 'resolution=merge-duplicates,return=minimal'
            } `
            -Body ($row | ConvertTo-Json) -TimeoutSec 30 | Out-Null
        return @{ Ok = $true }
    }
    catch {
        return @{ Ok = $false; Error = (Get-SupabaseErrorMessage $_) }
    }
}
