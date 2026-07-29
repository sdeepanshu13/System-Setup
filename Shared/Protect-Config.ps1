<#
.SYNOPSIS
    Regenerates the obfuscated Shared/Config/supabase-config.json.
.DESCRIPTION
    Cross-platform (Windows PowerShell 5.1 and pwsh 7+ on macOS/Linux).

        pwsh ./Protect-Config.ps1 -Url https://xxx.supabase.co -PublishableKey sb_publishable_xxx

    With no arguments it re-encrypts whatever is already configured.

    This is obfuscation, not secrecy: the unlock key ships with the app. That's
    fine -- the publishable key is meant to be public and RLS protects the data.
    Never pass a secret / service-role key; the module rejects it.
#>
param(
    [string]$Url,
    [string]$PublishableKey
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module ([IO.Path]::Combine($here, 'Modules', 'SetupCore.psm1')) -Force

$paths = Get-SetupPaths -SharedRoot $here
$configFile = $paths.ConfigFile()

if (-not $Url -or -not $PublishableKey) {
    $mgr = New-ProfileManager -SharedRoot $here
    if (-not $Url) { $Url = $mgr.Config.Url }
    if (-not $PublishableKey) { $PublishableKey = $mgr.Config.Key }
}
if (-not $Url -or -not $PublishableKey) {
    throw 'Could not determine URL / publishable key. Pass -Url and -PublishableKey.'
}

if (-not (Test-Path -LiteralPath $paths.ConfigDir)) {
    New-Item -ItemType Directory -Path $paths.ConfigDir -Force | Out-Null
}
New-SupabaseConfigContent -Url $Url -PublishableKey $PublishableKey |
    Set-Content -LiteralPath $configFile -Encoding UTF8

Write-Host "Wrote obfuscated config: $configFile" -ForegroundColor Green

$verify = (New-ProfileManager -SharedRoot $here).Config
if ($verify.Url -eq $Url.TrimEnd('/') -and $verify.Key -eq $PublishableKey) {
    Write-Host 'Verified: decrypts back correctly.' -ForegroundColor Green
}
else {
    throw 'Verification FAILED -- config does not round-trip.'
}
