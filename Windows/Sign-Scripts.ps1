<#
.SYNOPSIS
    Self-sign all .ps1 scripts in this folder with a personal code-signing cert.
.DESCRIPTION
    Creates a self-signed code-signing certificate in CurrentUser\My (if one
    doesn't already exist), exports the public cert, and Authenticode-signs
    every .ps1 in the script folder.

    On *this* machine the script will then run under AllSigned / RemoteSigned
    policy. To make the signature trusted on a *different* fresh machine you
    must first import 'CodeSigning.cer' into:
        Cert:\LocalMachine\Root              (Trusted Root CAs)
        Cert:\LocalMachine\TrustedPublisher  (Trusted Publishers)

    For most one-off bootstraps it's simpler to just use Setup.cmd (which
    bypasses the policy). Run this only if you specifically want signed scripts.
.PARAMETER Subject
    CN for the cert. Default: "CN=System-Setup Self-Signed".
#>
param(
    [string]$Subject = 'CN=System-Setup Self-Signed'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "Looking for existing code-signing cert: $Subject" -ForegroundColor Cyan
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Subject } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "  Not found. Creating a new self-signed cert (valid 5 years)..." -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -Type CodeSigningCert `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(5)
    Write-Host "  Created: $($cert.Thumbprint)" -ForegroundColor Green
}
else {
    Write-Host "  Found: $($cert.Thumbprint) (expires $($cert.NotAfter))" -ForegroundColor Green
}

# Export the public cert so it can be imported into Trusted Root / Publishers
# on other machines.
$cerPath = Join-Path $ScriptDir 'CodeSigning.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
Write-Host "Public cert exported: $cerPath" -ForegroundColor DarkGray

# Trust this cert on the current machine so AllSigned/RemoteSigned accepts it.
foreach ($store in 'Root', 'TrustedPublisher') {
    try {
        $storeObj = Get-Item "Cert:\CurrentUser\$store"
        $storeObj.Open('ReadWrite')
        if (-not ($storeObj.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
            $storeObj.Add($cert)
            Write-Host "  Added to CurrentUser\$store" -ForegroundColor DarkGray
        }
        $storeObj.Close()
    }
    catch {
        Write-Warning "Could not add to CurrentUser\${store}: $_"
    }
}

# Sign every .ps1 in the folder.
$scripts = Get-ChildItem -Path $ScriptDir -Filter *.ps1 -File
Write-Host ""
Write-Host "Signing $($scripts.Count) script(s)..." -ForegroundColor Cyan
foreach ($s in $scripts) {
    $result = Set-AuthenticodeSignature -FilePath $s.FullName -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com' `
        -ErrorAction Continue
    $color = if ($result.Status -eq 'Valid') { 'Green' } else { 'Yellow' }
    Write-Host ("  [{0}] {1}" -f $result.Status, $s.Name) -ForegroundColor $color
}

Write-Host ""
Write-Host "Done. To trust on another machine, run there as Administrator:" -ForegroundColor Yellow
Write-Host "  Import-Certificate -FilePath CodeSigning.cer -CertStoreLocation Cert:\LocalMachine\Root"
Write-Host "  Import-Certificate -FilePath CodeSigning.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher"
