<#
.SYNOPSIS
    Regenerates the obfuscated supabase-config.json.
.DESCRIPTION
    Encrypts the project URL + publishable key so they aren't sitting in the repo
    as scrapeable plaintext, then writes them back to supabase-config.json.

    Run this whenever the keys change:
        .\Protect-Config.ps1 -Url https://xxx.supabase.co -PublishableKey sb_publishable_xxx

    With no arguments it re-encrypts whatever is already in the file.

    IMPORTANT -- this is obfuscation, not secrecy. The unlock key ships with the
    app, so anyone determined can recover these values. That is fine: the
    publishable key is designed to be public and RLS is what actually protects
    the data. NEVER put the secret / service-role key through this script.
#>
param(
    [string]$Url,
    [string]$PublishableKey
)

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $dir 'UserProfile.ps1')
. (Join-Path $dir 'SupabaseStore.ps1')

$configPath = Join-Path $dir 'supabase-config.json'

if (-not $Url -or -not $PublishableKey) {
    $existing = Get-SupabaseConfig
    if (-not $Url) { $Url = $existing.Url }
    if (-not $PublishableKey) { $PublishableKey = $existing.Key }
}

if (-not $Url -or -not $PublishableKey) {
    Write-Error "Could not determine URL / publishable key. Pass -Url and -PublishableKey."
    exit 1
}

if ($PublishableKey -like 'sb_secret*' -or $PublishableKey -like '*service_role*') {
    Write-Error "That looks like a SECRET key. Never ship it -- use the publishable key."
    exit 1
}

$plain = @{ url = $Url; publishableKey = $PublishableKey } | ConvertTo-Json -Compress
$prot = Protect-ProfilePayload -PlainText $plain -Passphrase (Get-ConfigObfuscationKey)

$out = [ordered]@{
    _comment = 'Obfuscated config. Regenerate with Protect-Config.ps1. Publishable key only -- never the secret key.'
    v        = 1
    salt     = $prot.salt
    iv       = $prot.iv
    mac      = $prot.mac
    cipher   = $prot.cipher
}
($out | ConvertTo-Json -Depth 4) | Set-Content -Path $configPath -Encoding UTF8

Write-Host "Wrote obfuscated config: $configPath" -ForegroundColor Green
$script:SupabaseConfigCache = $null
$check = Get-SupabaseConfig
if ($check.Url -eq $Url -and $check.Key -eq $PublishableKey) {
    Write-Host "Verified: decrypts back correctly." -ForegroundColor Green
}
else {
    Write-Error "Verification FAILED -- config does not round-trip."
    exit 1
}
