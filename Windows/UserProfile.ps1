<#
.SYNOPSIS
    Encrypted, git-synced per-user setup profiles.
.DESCRIPTION
    Stores each user's setup selections (packages, features, default shell) so
    they can be restored on any machine. The data is written to
    Windows\users\<id>.json and committed to the repo, but every profile is:

      * NAMED BY A HASH  -- the file name is SHA-256(email/mobile), so the raw
                            email or phone number is never written to disk.
      * ENCRYPTED        -- the payload is AES-256-CBC encrypted with a key
                            derived (PBKDF2-SHA256, 200k iterations) from a
                            passphrase that only the user knows, and protected
                            with an HMAC-SHA256 tag (encrypt-then-MAC).

    Result: even though the file lives in a shared/public git repo and syncs
    across machines, only the person who knows the passphrase can read it.

    This file is dot-sourced by Setup-UI.ps1 (read/write) and Setup.ps1 (publish).
    It relies only on .NET Framework crypto that ships with Windows PowerShell 5.1
    -- no external modules.
.NOTES
    Nothing here ever stores or transmits the passphrase. It exists only in the
    memory of the process that is doing the encrypt/decrypt.
#>

# Directory that holds this script (works when dot-sourced or embedded).
if ($PSScriptRoot) { $script:ProfileBaseDir = $PSScriptRoot }
else { $script:ProfileBaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$script:ProfileKdfIterations = 200000

# ---------------------------------------------------------------------------
# Key / identity helpers
# ---------------------------------------------------------------------------

function ConvertTo-ProfileKey {
    <# Normalise an email or mobile number into a stable lookup value. #>
    param([Parameter(Mandatory)][string]$Identifier)
    $id = $Identifier.Trim()
    if ($id -match '@') {
        return @{ Type = 'email';  Value = $id.ToLowerInvariant() }
    }
    else {
        $digits = ($id -replace '\D', '')
        return @{ Type = 'mobile'; Value = $digits }
    }
}

function Get-ProfileId {
    <# SHA-256 of the normalised identifier -> 32 hex chars used as the file name. #>
    param([Parameter(Mandatory)][string]$NormalizedValue)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($NormalizedValue)
        $hash  = $sha.ComputeHash($bytes)
    }
    finally { $sha.Dispose() }
    return (([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()).Substring(0, 32)
}

function Get-ProfileStoreDir {
    param([string]$BaseDir = $script:ProfileBaseDir)
    $dir = Join-Path $BaseDir 'users'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-UserProfilePath {
    param([Parameter(Mandatory)][string]$Id, [string]$BaseDir = $script:ProfileBaseDir)
    return (Join-Path (Get-ProfileStoreDir -BaseDir $BaseDir) ("$Id.json"))
}

function Test-UserProfileExists {
    param([Parameter(Mandatory)][string]$Identifier, [string]$BaseDir = $script:ProfileBaseDir)
    $norm = ConvertTo-ProfileKey $Identifier
    $id   = Get-ProfileId $norm.Value
    return (Test-Path (Get-UserProfilePath -Id $id -BaseDir $BaseDir))
}

# ---------------------------------------------------------------------------
# Cryptography (PBKDF2 -> AES-256-CBC + HMAC-SHA256, encrypt-then-MAC)
# ---------------------------------------------------------------------------

function Get-ProfileDerivedKeys {
    param(
        [Parameter(Mandatory)][string]$Passphrase,
        [Parameter(Mandatory)][byte[]]$Salt,
        [int]$Iterations = $script:ProfileKdfIterations
    )
    # Prefer the SHA-256 PBKDF2 constructor (.NET 4.6+); fall back to SHA-1 on
    # older frameworks so this never hard-fails.
    try {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $Passphrase, $Salt, $Iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    }
    catch {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Passphrase, $Salt, $Iterations)
    }
    try { $material = $kdf.GetBytes(64) } finally { $kdf.Dispose() }

    $aesKey  = New-Object byte[] 32
    $hmacKey = New-Object byte[] 32
    [Array]::Copy($material, 0,  $aesKey,  0, 32)
    [Array]::Copy($material, 32, $hmacKey, 0, 32)
    return @{ Aes = $aesKey; Hmac = $hmacKey }
}

function Protect-ProfilePayload {
    param(
        [Parameter(Mandatory)][string]$PlainText,
        [Parameter(Mandatory)][string]$Passphrase,
        [int]$Iterations = $script:ProfileKdfIterations
    )
    $salt = New-Object byte[] 16
    $iv   = New-Object byte[] 16
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt); $rng.GetBytes($iv) } finally { $rng.Dispose() }

    $keys = Get-ProfileDerivedKeys -Passphrase $Passphrase -Salt $salt -Iterations $Iterations

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $keys.Aes
    $aes.IV      = $iv
    try {
        $enc     = $aes.CreateEncryptor()
        $ptBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $ct      = $enc.TransformFinalBlock($ptBytes, 0, $ptBytes.Length)
        $enc.Dispose()
    }
    finally { $aes.Dispose() }

    # HMAC over IV || ciphertext (encrypt-then-MAC).
    $macInput = New-Object byte[] ($iv.Length + $ct.Length)
    [Array]::Copy($iv, 0, $macInput, 0, $iv.Length)
    [Array]::Copy($ct, 0, $macInput, $iv.Length, $ct.Length)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keys.Hmac)
    try { $mac = $hmac.ComputeHash($macInput) } finally { $hmac.Dispose() }

    return @{
        salt   = [Convert]::ToBase64String($salt)
        iv     = [Convert]::ToBase64String($iv)
        cipher = [Convert]::ToBase64String($ct)
        mac    = [Convert]::ToBase64String($mac)
    }
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}

function Unprotect-ProfilePayload {
    <# Returns the decrypted plaintext, or $null if the passphrase is wrong or
       the record was tampered with (HMAC mismatch). #>
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Passphrase
    )
    try {
        $salt = [Convert]::FromBase64String($Record.salt)
        $iv   = [Convert]::FromBase64String($Record.iv)
        $ct   = [Convert]::FromBase64String($Record.cipher)
        $mac  = [Convert]::FromBase64String($Record.mac)
    }
    catch { return $null }

    $iterations = $script:ProfileKdfIterations
    if ($Record.PSObject.Properties.Name -contains 'iterations' -and $Record.iterations) {
        $iterations = [int]$Record.iterations
    }
    $keys = Get-ProfileDerivedKeys -Passphrase $Passphrase -Salt $salt -Iterations $iterations

    # Verify the MAC first -- reject before we ever touch the cipher.
    $macInput = New-Object byte[] ($iv.Length + $ct.Length)
    [Array]::Copy($iv, 0, $macInput, 0, $iv.Length)
    [Array]::Copy($ct, 0, $macInput, $iv.Length, $ct.Length)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keys.Hmac)
    try { $expected = $hmac.ComputeHash($macInput) } finally { $hmac.Dispose() }
    if (-not (Test-BytesEqual $expected $mac)) { return $null }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $keys.Aes
    $aes.IV      = $iv
    try {
        $dec = $aes.CreateDecryptor()
        $pt  = $dec.TransformFinalBlock($ct, 0, $ct.Length)
        $dec.Dispose()
    }
    catch { return $null }
    finally { $aes.Dispose() }

    return [System.Text.Encoding]::UTF8.GetString($pt)
}

# ---------------------------------------------------------------------------
# Profile read / write
# ---------------------------------------------------------------------------

function Read-UserProfile {
    <#
        Look up a user's encrypted profile.
        Returns a hashtable:
          Found     - a file exists for this identifier
          Decrypted - the passphrase successfully decrypted it
          Data      - the decrypted payload object (when Decrypted)
          Id        - the hashed id
          KeyType   - 'email' or 'mobile'
    #>
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][string]$Passphrase,
        [string]$BaseDir = $script:ProfileBaseDir
    )
    $norm = ConvertTo-ProfileKey $Identifier
    $id   = Get-ProfileId $norm.Value
    $path = Get-UserProfilePath -Id $id -BaseDir $BaseDir

    if (-not (Test-Path $path)) {
        return @{ Found = $false; Decrypted = $false; Id = $id; KeyType = $norm.Type; Path = $path }
    }
    try { $record = Get-Content $path -Raw | ConvertFrom-Json }
    catch { return @{ Found = $true; Decrypted = $false; Id = $id; KeyType = $norm.Type; Path = $path; Error = 'corrupt' } }

    $json = Unprotect-ProfilePayload -Record $record -Passphrase $Passphrase
    if ($null -eq $json) {
        return @{ Found = $true; Decrypted = $false; Id = $id; KeyType = $norm.Type; Path = $path }
    }
    try { $payload = $json | ConvertFrom-Json }
    catch { return @{ Found = $true; Decrypted = $false; Id = $id; KeyType = $norm.Type; Path = $path } }

    return @{ Found = $true; Decrypted = $true; Id = $id; KeyType = $norm.Type; Path = $path; Data = $payload }
}

function Write-UserProfile {
    <# Encrypt and persist a user's selections. Returns the file path. #>
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][string]$Passphrase,
        [Parameter(Mandatory)][hashtable]$Data,
        [string]$BaseDir = $script:ProfileBaseDir
    )
    $norm = ConvertTo-ProfileKey $Identifier
    $id   = Get-ProfileId $norm.Value
    $path = Get-UserProfilePath -Id $id -BaseDir $BaseDir

    $payload = @{
        schema         = 1
        name           = $Data.name
        identifierType = $norm.Type
        packages       = @($Data.packages)
        features       = @($Data.features)
        defaultShell   = $Data.defaultShell
        updatedAt      = (Get-Date).ToString('o')
    }
    $plain = $payload | ConvertTo-Json -Depth 6 -Compress
    $prot  = Protect-ProfilePayload -PlainText $plain -Passphrase $Passphrase

    $record = [ordered]@{
        id             = $id
        v              = 1
        alg            = 'AES-256-CBC+HMAC-SHA256'
        kdf            = 'PBKDF2-SHA256'
        iterations     = $script:ProfileKdfIterations
        identifierType = $norm.Type
        salt           = $prot.salt
        iv             = $prot.iv
        mac            = $prot.mac
        cipher         = $prot.cipher
        updatedAt      = (Get-Date).ToString('o')
    }
    ($record | ConvertTo-Json -Depth 4) | Set-Content -Path $path -Encoding UTF8
    return $path
}

# ---------------------------------------------------------------------------
# Git sync (best-effort -- never fatal)
# ---------------------------------------------------------------------------

function Find-ProfileGitExe {
    foreach ($p in @(
            "$env:ProgramFiles\Git\cmd\git.exe",
            "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
            "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if (Test-Path $p) { return $p }
    }
    $c = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Get-ProfileRepoRoot {
    param([string]$BaseDir = $script:ProfileBaseDir)
    $parent = Split-Path -Parent $BaseDir
    if ($parent -and (Test-Path (Join-Path $parent '.git'))) { return $parent }
    if (Test-Path (Join-Path $BaseDir '.git')) { return $BaseDir }
    return $null
}

function Sync-ProfileStore {
    <# Pull the latest committed profiles before a lookup (best-effort). #>
    param([string]$BaseDir = $script:ProfileBaseDir)
    $git = Find-ProfileGitExe
    if (-not $git) { return }
    $root = Get-ProfileRepoRoot -BaseDir $BaseDir
    if (-not $root) { return }
    try { & $git -C $root pull --ff-only 2>&1 | Out-Null } catch { }
}

function Publish-ProfileStore {
    <#
        Commit + push a single encrypted profile file. Scoped to just that file
        so we never accidentally commit logs, SSH keys, or other artifacts.
        Returns @{ Ok; Reason }.
    #>
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [string]$BaseDir = $script:ProfileBaseDir,
        [string]$CommitMessage = 'Update encrypted user setup profile'
    )
    $git = Find-ProfileGitExe
    if (-not $git) { return @{ Ok = $false; Reason = 'git-not-found' } }
    $root = Get-ProfileRepoRoot -BaseDir $BaseDir
    if (-not $root) { return @{ Ok = $false; Reason = 'not-a-git-repo' } }
    if (-not (Test-Path $ProfilePath)) { return @{ Ok = $false; Reason = 'profile-missing' } }

    try {
        & $git -C $root add -- "$ProfilePath" 2>&1 | Out-Null
        & $git -C $root diff --cached --quiet -- "$ProfilePath" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Reason = 'no-changes' } }
        & $git -C $root commit -m $CommitMessage -- "$ProfilePath" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = 'commit-failed' } }
        & $git -C $root push 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = 'push-failed' } }
        return @{ Ok = $true; Reason = 'pushed' }
    }
    catch { return @{ Ok = $false; Reason = $_.Exception.Message } }
}
