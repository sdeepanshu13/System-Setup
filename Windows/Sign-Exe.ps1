<#
.SYNOPSIS
    Authenticode-sign the built Setup.exe.
.DESCRIPTION
    Signs dist\Setup.exe with whichever certificate is available, in order:

      1. -PfxPath          a .pfx on disk
      2. CODE_SIGN_PFX_BASE64 env var (CI -- the pfx as base64)
      3. an installed cert matching -Subject in CurrentUser\My
      4. -SelfSigned       create one on the fly

    Skips quietly when no certificate is available so an unsigned build still
    succeeds.

    Passwords are read from the environment or prompted as SecureString --
    never passed on the command line, never logged.

    A NOTE ON SMARTSCREEN: a self-signed certificate does not remove the
    SmartScreen prompt. Windows only trusts certificates chaining to a public
    CA, and reputation still has to accumulate (an EV certificate is the only
    thing that clears it immediately). Self-signing is for internal deployment,
    where you can push the certificate to Trusted Publishers via GPO.
.EXAMPLE
    .\Sign-Exe.ps1 -PfxPath C:\certs\codesign.pfx
.EXAMPLE
    $env:CODE_SIGN_PASSWORD = '...'; .\Sign-Exe.ps1 -SelfSigned
#>
param(
    [string]$Path,
    [string]$PfxPath,
    [string]$Subject = 'CN=System-Setup',
    [switch]$SelfSigned,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not $Path) {
    $Path = Join-Path (Split-Path $ScriptDir) 'dist\Setup.exe'
}
if (-not (Test-Path $Path)) {
    Write-Warning "Nothing to sign -- $Path not found. Run Build-Exe.ps1 first."
    exit 0
}

function Get-SigningPassword {
    $fromEnv = [Environment]::GetEnvironmentVariable('CODE_SIGN_PASSWORD')
    if (-not [string]::IsNullOrEmpty($fromEnv)) {
        return (ConvertTo-SecureString $fromEnv -AsPlainText -Force)
    }
    return (Read-Host 'Certificate password' -AsSecureString)
}

$cert = $null
$tempPfx = $null

try {
    # 1 + 2 -- a pfx from disk or from CI secrets.
    $b64 = [Environment]::GetEnvironmentVariable('CODE_SIGN_PFX_BASE64')
    if (-not $PfxPath -and -not [string]::IsNullOrWhiteSpace($b64)) {
        $tempPfx = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.pfx')
        [IO.File]::WriteAllBytes($tempPfx, [Convert]::FromBase64String($b64))
        $PfxPath = $tempPfx
        Write-Host '  Using certificate from CODE_SIGN_PFX_BASE64.' -ForegroundColor DarkGray
    }

    if ($PfxPath) {
        if (-not (Test-Path $PfxPath)) { throw "Certificate not found: $PfxPath" }
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $PfxPath, (Get-SigningPassword),
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    }

    # 3 -- an already-installed certificate.
    if (-not $cert) {
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -like "*$Subject*" -and $_.NotAfter -gt (Get-Date) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) { Write-Host "  Using installed certificate $($cert.Thumbprint)." -ForegroundColor DarkGray }
    }

    # 4 -- last resort, only when explicitly asked for.
    if (-not $cert -and $SelfSigned) {
        Write-Host '  Creating a self-signed certificate (internal use only)...' -ForegroundColor Yellow
        $cert = New-SelfSignedCertificate -Subject $Subject -Type CodeSigningCert `
            -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 `
            -KeyUsage DigitalSignature -NotAfter (Get-Date).AddYears(3)
        Export-Certificate -Cert $cert -FilePath (Join-Path $ScriptDir 'CodeSigning.cer') -Force | Out-Null
        Write-Host '  Public certificate exported to CodeSigning.cer' -ForegroundColor DarkGray
        Write-Host '  Import it into Trusted Publishers on target machines to avoid warnings.' -ForegroundColor DarkGray
    }

    if (-not $cert) {
        Write-Host '  No code-signing certificate available -- leaving the build unsigned.' -ForegroundColor Yellow
        Write-Host '  Provide one with -PfxPath, CODE_SIGN_PFX_BASE64, or -SelfSigned.' -ForegroundColor DarkGray
        exit 0
    }

    Write-Host "Signing $([IO.Path]::GetFileName($Path))..." -ForegroundColor Cyan
    $sig = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $TimestampServer -ErrorAction Stop

    if ($sig.Status -ne 'Valid') {
        # A self-signed chain reports UnknownError until the cert is trusted -- that's expected.
        Write-Warning "Signature status: $($sig.Status) -- $($sig.StatusMessage)"
        if ($sig.Status -eq 'HashMismatch') { exit 1 }
    }
    else {
        Write-Host '  Signed and timestamped.' -ForegroundColor Green
    }

    $verify = Get-AuthenticodeSignature -FilePath $Path
    Write-Host ("  Signer : " + $verify.SignerCertificate.Subject) -ForegroundColor DarkGray
    Write-Host ("  Expires: " + $verify.SignerCertificate.NotAfter) -ForegroundColor DarkGray
    if ($verify.TimeStamperCertificate) {
        Write-Host '  Timestamped, so the signature outlives the certificate.' -ForegroundColor DarkGray
    }
    else {
        Write-Warning '  No timestamp -- the signature will expire with the certificate.'
    }
}
finally {
    if ($tempPfx -and (Test-Path $tempPfx)) { Remove-Item $tempPfx -Force -ErrorAction SilentlyContinue }
}
