<#
.SYNOPSIS
    Review and clear installation errors reported by users.
.DESCRIPTION
    Owner-only tool. Clients can insert into setup_errors but never read it, so
    triage needs the service-role key -- which must come from the environment
    and must never be committed or shipped inside the installer.

        $env:SUPABASE_SERVICE_KEY = '<secret key>'
        ./Get-SetupErrors.ps1                 # unresolved, newest first
        ./Get-SetupErrors.ps1 -All            # include resolved
        ./Get-SetupErrors.ps1 -Summary        # group by message
        ./Get-SetupErrors.ps1 -Resolve 42     # mark one fixed
        ./Get-SetupErrors.ps1 -PurgeResolved  # delete resolved rows

    Get the key from Dashboard -> Project Settings -> API Keys.
#>
param(
    [switch]$All,
    [switch]$Summary,
    [int]$Resolve,
    [switch]$PurgeResolved,
    [int]$Limit = 50
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module ([IO.Path]::Combine((Split-Path -Parent $here), 'Modules', 'SetupCore.psm1')) -Force

$cfg = (New-ProfileManager -SharedRoot (Split-Path -Parent $here)).Config
if (-not $cfg.IsEnabled()) { throw 'Supabase config missing.' }

$serviceKey = [Environment]::GetEnvironmentVariable('SUPABASE_SERVICE_KEY')
if ([string]::IsNullOrWhiteSpace($serviceKey)) {
    throw 'Set SUPABASE_SERVICE_KEY first. Never hard-code it, and never ship it in the installer.'
}

$headers = @{
    apikey         = $serviceKey
    Authorization  = "Bearer $serviceKey"
    'Content-Type' = 'application/json'
}
$base = "$($cfg.Url)/rest/v1/setup_errors"

if ($Resolve) {
    Invoke-RestMethod -Method Patch -Uri "$base`?id=eq.$Resolve" -Headers $headers `
        -Body (@{ resolved = $true } | ConvertTo-Json) | Out-Null
    Write-Host "Marked error $Resolve as resolved." -ForegroundColor Green
    return
}

if ($PurgeResolved) {
    Invoke-RestMethod -Method Delete -Uri "$base`?resolved=eq.true" -Headers $headers | Out-Null
    Write-Host 'Deleted all resolved errors.' -ForegroundColor Green
    return
}

$filter = if ($All) { '' } else { 'resolved=eq.false&' }
$rows = @(Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "$base`?$($filter)order=created_at.desc&limit=$Limit")

if ($rows.Count -eq 0) {
    Write-Host 'No errors reported. ' -ForegroundColor Green
    return
}

if ($Summary) {
    Write-Host ''
    $rows | Group-Object message | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ("{0,4}x  {1}" -f $_.Count, $_.Name) -ForegroundColor Yellow
        $pkgs = @($_.Group | Where-Object { $_.package } | Select-Object -ExpandProperty package -Unique)
        if ($pkgs) { Write-Host ("       packages: " + ($pkgs -join ', ')) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host ("{0} error row(s)." -f $rows.Count) -ForegroundColor Cyan
    return
}

Write-Host ''
foreach ($e in $rows) {
    $when = ([datetime]$e.created_at).ToString('yyyy-MM-dd HH:mm')
    $flag = if ($e.resolved) { '[resolved]' } else { '[open]' }
    Write-Host ("#{0}  {1}  {2}  {3}/{4}" -f $e.id, $when, $flag, $e.platform, $e.phase) -ForegroundColor Cyan
    if ($e.package) { Write-Host ("     package : " + $e.package) }
    Write-Host ("     message : " + $e.message) -ForegroundColor Yellow
    if ($e.detail) {
        $d = [string]$e.detail
        if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + '...' }
        Write-Host ("     detail  : " + $d) -ForegroundColor DarkGray
    }
    if ($e.os_version) { Write-Host ("     os      : " + $e.os_version) -ForegroundColor DarkGray }
    Write-Host ''
}
Write-Host ("{0} row(s). Resolve with -Resolve <id>, clean up with -PurgeResolved." -f $rows.Count) -ForegroundColor Cyan
