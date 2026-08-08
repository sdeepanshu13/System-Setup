<#
.SYNOPSIS
    Cross-platform core for System-Setup: config, crypto, identity and profile storage.
.DESCRIPTION
    Shared by the Windows and macOS installers. Runs on Windows PowerShell 5.1
    and PowerShell 7+ (macOS/Linux) -- no platform-specific APIs, no external
    modules.

    Layering (each class has one job):

        SetupCrypto          static AES-256-CBC + HMAC-SHA256 + PBKDF2 helpers
        SetupPaths           resolves shared folders on any OS
        UserIdentity         normalises an email / mobile into a stable key
        ProfileData          the payload model (packages, features, shell)
        SupabaseConfig       loads + decrypts connection settings
        SupabaseClient       REST transport for auth + rows
        ProfileStore         abstract store contract
          |- SupabaseProfileStore   online, RLS-scoped
          |- LocalProfileStore      offline file fallback
        OtpService           offline OTP delivery (SMTP / SMS)
        ProfileManager       facade the installers actually talk to

    Callers use the New-* factory functions rather than `using module`, so the
    module works when dot-sourced from any location (including the packed exe).
#>

Set-StrictMode -Version Latest

# PS 5.1 has no $IsWindows (it's Windows-only); PS 7 defines it on every OS.
$script:OnWindows = $true
if (Test-Path -LiteralPath 'variable:global:IsWindows') {
    $script:OnWindows = [bool](Get-Variable -Name IsWindows -Scope Global -ValueOnly)
}

# PS 5.1 negotiates TLS 1.0 by default, which Supabase rejects.
if ($script:OnWindows -and $PSVersionTable.PSVersion.Major -lt 6) {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }
}

# =====================================================================
# Crypto
# =====================================================================

class SetupCrypto {
    static [int] $Iterations = 200000

    static [byte[]] RandomBytes([int]$count) {
        $b = [byte[]]::new($count)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($b) } finally { $rng.Dispose() }
        return $b
    }

    static [hashtable] DeriveKeys([string]$passphrase, [byte[]]$salt, [int]$iterations) {
        $kdf = $null
        try {
            $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
                $passphrase, $salt, $iterations,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        }
        catch {
            $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($passphrase, $salt, $iterations)
        }
        $material = $null
        try { $material = $kdf.GetBytes(64) } finally { $kdf.Dispose() }

        $aesKey = [byte[]]::new(32); $macKey = [byte[]]::new(32)
        [Array]::Copy($material, 0, $aesKey, 0, 32)
        [Array]::Copy($material, 32, $macKey, 0, 32)
        return @{ Aes = $aesKey; Mac = $macKey }
    }

    static [bool] ConstantTimeEquals([byte[]]$a, [byte[]]$b) {
        if ($null -eq $a -or $null -eq $b -or $a.Length -ne $b.Length) { return $false }
        $diff = 0
        for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
        return ($diff -eq 0)
    }

    static [byte[]] ComputeMac([byte[]]$key, [byte[]]$iv, [byte[]]$cipher) {
        $buf = [byte[]]::new($iv.Length + $cipher.Length)
        [Array]::Copy($iv, 0, $buf, 0, $iv.Length)
        [Array]::Copy($cipher, 0, $buf, $iv.Length, $cipher.Length)
        $h = [System.Security.Cryptography.HMACSHA256]::new($key)
        try { return $h.ComputeHash($buf) } finally { $h.Dispose() }
    }

    static [hashtable] Protect([string]$plainText, [string]$passphrase) {
        $salt = [SetupCrypto]::RandomBytes(16)
        $iv = [SetupCrypto]::RandomBytes(16)
        $keys = [SetupCrypto]::DeriveKeys($passphrase, $salt, [SetupCrypto]::Iterations)

        $aes = [System.Security.Cryptography.Aes]::Create()
        $cipher = $null
        try {
            $aes.KeySize = 256
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $keys.Aes
            $aes.IV = $iv
            $enc = $aes.CreateEncryptor()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)
                $cipher = $enc.TransformFinalBlock($bytes, 0, $bytes.Length)
            }
            finally { $enc.Dispose() }
        }
        finally { $aes.Dispose() }

        $mac = [SetupCrypto]::ComputeMac($keys.Mac, $iv, $cipher)
        return @{
            salt       = [Convert]::ToBase64String($salt)
            iv         = [Convert]::ToBase64String($iv)
            cipher     = [Convert]::ToBase64String($cipher)
            mac        = [Convert]::ToBase64String($mac)
            iterations = [SetupCrypto]::Iterations
        }
    }

    # Returns plaintext, or '' when the passphrase is wrong or data was altered.
    # (A [string]-typed method coerces $null to '', so callers must test with
    # [string]::IsNullOrEmpty rather than -eq $null.)
    static [string] Unprotect($record, [string]$passphrase) {
        $salt = $null; $iv = $null; $cipher = $null; $mac = $null
        try {
            $salt = [Convert]::FromBase64String([string]$record.salt)
            $iv = [Convert]::FromBase64String([string]$record.iv)
            $cipher = [Convert]::FromBase64String([string]$record.cipher)
            $mac = [Convert]::FromBase64String([string]$record.mac)
        }
        catch { return $null }

        $iterCount = [SetupCrypto]::Iterations
        try {
            if ($record.PSObject.Properties.Name -contains 'iterations' -and $record.iterations) {
                $iterCount = [int]$record.iterations
            }
        }
        catch { }

        $keys = [SetupCrypto]::DeriveKeys($passphrase, $salt, $iterCount)
        if (-not [SetupCrypto]::ConstantTimeEquals([SetupCrypto]::ComputeMac($keys.Mac, $iv, $cipher), $mac)) {
            return $null
        }

        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $keys.Aes
            $aes.IV = $iv
            $dec = $aes.CreateDecryptor()
            try {
                $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
                return [System.Text.Encoding]::UTF8.GetString($plain)
            }
            finally { $dec.Dispose() }
        }
        catch { return $null }
        finally { $aes.Dispose() }
    }

    static [string] Sha256Hex([string]$value) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($value))
            return (([BitConverter]::ToString($hash)) -replace '-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
}

# =====================================================================
# Paths -- one place that knows the shared layout, on any OS
# =====================================================================

class SetupPaths {
    [string] $SharedRoot
    [string] $ConfigDir
    [string] $ProfileDir
    [string] $DatabaseDir

    SetupPaths([string]$sharedRoot) {
        $this.SharedRoot = $sharedRoot
        $this.ConfigDir = [IO.Path]::Combine($sharedRoot, 'Config')
        $this.ProfileDir = [IO.Path]::Combine($sharedRoot, 'profiles')
        $this.DatabaseDir = [IO.Path]::Combine($sharedRoot, 'Database')
    }

    [string] ConfigFile() { return [IO.Path]::Combine($this.ConfigDir, 'supabase-config.json') }
    [string] OtpConfigFile() { return [IO.Path]::Combine($this.ConfigDir, '.otp-config.json') }

    [string] EnsureProfileDir() {
        if (-not (Test-Path -LiteralPath $this.ProfileDir)) {
            New-Item -ItemType Directory -Path $this.ProfileDir -Force | Out-Null
        }
        return $this.ProfileDir
    }

    [string] RepoRoot() {
        $candidate = Split-Path -Parent $this.SharedRoot
        if ($candidate -and (Test-Path -LiteralPath ([IO.Path]::Combine($candidate, '.git')))) { return $candidate }
        return $null
    }
}

# =====================================================================
# Identity
# =====================================================================

class UserIdentity {
    [string] $Raw
    [string] $Type      # 'email' or 'mobile'
    [string] $Value     # normalised
    [string] $Id        # stable hash used as a filename / lookup key

    UserIdentity([string]$raw) {
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Identifier is required.' }
        $this.Raw = $raw.Trim()
        if ($this.Raw -match '@') {
            $this.Type = 'email'
            $this.Value = $this.Raw.ToLowerInvariant()
        }
        else {
            $this.Type = 'mobile'
            $this.Value = ($this.Raw -replace '\D', '')
            if ([string]::IsNullOrEmpty($this.Value)) { throw 'Enter a valid email or mobile number.' }
        }
        $this.Id = [SetupCrypto]::Sha256Hex($this.Value).Substring(0, 32)
    }

    [bool] IsEmail() { return $this.Type -eq 'email' }
    [string] ToE164() { return "+$($this.Value)" }
    [string] AuthChannel() { if ($this.IsEmail()) { return 'email' } return 'sms' }
}

# =====================================================================
# Profile payload
# =====================================================================

class ProfileData {
    [string] $Name = ''
    [string[]] $Packages = @()
    [string[]] $Features = @()
    [string] $DefaultShell = '1'
    [object[]] $Apps = @()      # backed-up inventory: name/id/version/source
    [object[]] $Repos = @()     # name/path/remote/branch
    [object[]] $Dotfiles = @()  # shell, git and terminal config files
    [hashtable] $Tools = @{}    # vscode extensions, npm globals, pipx tools
    [string] $UpdatedAt = ''

    [string] ToJson() {
        return (@{
                schema       = 3
                name         = $this.Name
                packages     = @($this.Packages)
                features     = @($this.Features)
                defaultShell = $this.DefaultShell
                apps         = @($this.Apps)
                repos        = @($this.Repos)
                dotfiles     = @($this.Dotfiles)
                tools        = $this.Tools
                updatedAt    = (Get-Date).ToString('o')
            } | ConvertTo-Json -Depth 10 -Compress)
    }

    static [ProfileData] FromJson([string]$json) {
        $p = [ProfileData]::new()
        if ([string]::IsNullOrWhiteSpace($json)) { return $p }
        $o = $null
        try { $o = $json | ConvertFrom-Json } catch { return $p }
        if ($null -eq $o) { return $p }
        foreach ($map in @(@{ k = 'name'; t = 'Name' }, @{ k = 'defaultShell'; t = 'DefaultShell' })) {
            if ($o.PSObject.Properties.Name -contains $map.k -and $null -ne $o.($map.k)) {
                $p.($map.t) = [string]$o.($map.k)
            }
        }
        if ($o.PSObject.Properties.Name -contains 'packages' -and $o.packages) { $p.Packages = @($o.packages) }
        if ($o.PSObject.Properties.Name -contains 'features' -and $o.features) { $p.Features = @($o.features) }
        if ($o.PSObject.Properties.Name -contains 'apps' -and $o.apps) { $p.Apps = @($o.apps) }
        if ($o.PSObject.Properties.Name -contains 'repos' -and $o.repos) { $p.Repos = @($o.repos) }
        if ($o.PSObject.Properties.Name -contains 'dotfiles' -and $o.dotfiles) { $p.Dotfiles = @($o.dotfiles) }
        if ($o.PSObject.Properties.Name -contains 'tools' -and $o.tools) {
            $t = @{}
            foreach ($prop in $o.tools.PSObject.Properties) { $t[$prop.Name] = @($prop.Value) }
            $p.Tools = $t
        }
        return $p
    }
}

# =====================================================================
# Supabase configuration
# =====================================================================

class SupabaseConfig {
    [string] $Url
    [string] $Key

    hidden static [string] ObfuscationKey() { return (@('System', 'Setup', 'cfg', 'v1') -join '/') }

    static [bool] LooksSecret([string]$key) {
        if ([string]::IsNullOrEmpty($key)) { return $false }
        return ($key -like 'sb_secret*' -or $key -like '*service_role*')
    }

    static [SupabaseConfig] Load([string]$configFile) {
        $cfg = [SupabaseConfig]::new()

        if ($configFile -and (Test-Path -LiteralPath $configFile)) {
            try {
                $json = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
                if ($json.PSObject.Properties.Name -contains 'cipher' -and $json.cipher) {
                    $plain = [SetupCrypto]::Unprotect($json, [SupabaseConfig]::ObfuscationKey())
                    if ($plain) { $json = $plain | ConvertFrom-Json }
                }
                if ($json.PSObject.Properties.Name -contains 'url') { $cfg.Url = [string]$json.url }
                if ($json.PSObject.Properties.Name -contains 'publishableKey') { $cfg.Key = [string]$json.publishableKey }
            }
            catch { }
        }

        $envUrl = [Environment]::GetEnvironmentVariable('SETUP_SUPABASE_URL')
        $envKey = [Environment]::GetEnvironmentVariable('SETUP_SUPABASE_KEY')
        if (-not [string]::IsNullOrWhiteSpace($envUrl)) { $cfg.Url = $envUrl }
        if (-not [string]::IsNullOrWhiteSpace($envKey)) { $cfg.Key = $envKey }

        if ($cfg.Url) { $cfg.Url = $cfg.Url.TrimEnd('/') }

        # A service-role key bypasses RLS; it must never be used from a client.
        if ([SupabaseConfig]::LooksSecret($cfg.Key)) {
            Write-Warning 'Refusing to use a Supabase secret key in client code. Use the publishable key.'
            $cfg.Key = $null
        }
        return $cfg
    }

    [bool] IsEnabled() {
        return (-not [string]::IsNullOrWhiteSpace($this.Url)) -and (-not [string]::IsNullOrWhiteSpace($this.Key))
    }

    static [string] BuildEncryptedFile([string]$url, [string]$publishableKey) {
        if ([SupabaseConfig]::LooksSecret($publishableKey)) {
            throw 'That is a SECRET key. Never ship it -- use the publishable key.'
        }
        $plain = @{ url = $url; publishableKey = $publishableKey } | ConvertTo-Json -Compress
        $prot = [SetupCrypto]::Protect($plain, [SupabaseConfig]::ObfuscationKey())
        return ([ordered]@{
                _comment = 'Obfuscated. Regenerate with Shared/Protect-Config.ps1. Publishable key only.'
                v        = 1
                salt     = $prot.salt
                iv       = $prot.iv
                mac      = $prot.mac
                cipher   = $prot.cipher
            } | ConvertTo-Json -Depth 4)
    }
}

# =====================================================================
# Supabase REST transport
# =====================================================================

class SupabaseClient {
    [SupabaseConfig] $Config
    [string] $AccessToken
    [string] $UserId
    hidden [int] $TimeoutSec = 30

    SupabaseClient([SupabaseConfig]$config) { $this.Config = $config }

    [bool] IsAuthenticated() { return -not [string]::IsNullOrEmpty($this.AccessToken) }

    hidden [string] ErrorText($errorRecord) {
        try {
            $resp = $errorRecord.Exception.Response
            if ($resp) {
                $reader = [IO.StreamReader]::new($resp.GetResponseStream())
                $body = $reader.ReadToEnd(); $reader.Close()
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
        return $errorRecord.Exception.Message
    }

    [hashtable] SendOtp([UserIdentity]$identity) {
        $body = @{ should_create_user = $true }
        if ($identity.IsEmail()) { $body['email'] = $identity.Value } else { $body['phone'] = $identity.ToE164() }
        try {
            Invoke-RestMethod -Method Post -Uri "$($this.Config.Url)/auth/v1/otp" `
                -Headers @{ apikey = $this.Config.Key; 'Content-Type' = 'application/json' } `
                -Body ($body | ConvertTo-Json) -TimeoutSec $this.TimeoutSec | Out-Null
            return @{ Ok = $true; Channel = $identity.AuthChannel() }
        }
        catch { return @{ Ok = $false; Channel = $identity.AuthChannel(); Error = $this.ErrorText($_) } }
    }

    [hashtable] VerifyOtp([UserIdentity]$identity, [string]$code) {
        $body = @{ token = ($code -replace '\D', ''); type = $identity.AuthChannel() }
        if ($identity.IsEmail()) { $body['email'] = $identity.Value } else { $body['phone'] = $identity.ToE164() }
        try {
            $r = Invoke-RestMethod -Method Post -Uri "$($this.Config.Url)/auth/v1/verify" `
                -Headers @{ apikey = $this.Config.Key; 'Content-Type' = 'application/json' } `
                -Body ($body | ConvertTo-Json) -TimeoutSec $this.TimeoutSec
            if (-not $r.access_token) { return @{ Ok = $false; Error = 'no token returned' } }
            $this.AccessToken = $r.access_token
            $this.UserId = $r.user.id
            return @{ Ok = $true }
        }
        catch { return @{ Ok = $false; Error = $this.ErrorText($_) } }
    }

    hidden [hashtable] AuthHeaders() {
        return @{ apikey = $this.Config.Key; Authorization = "Bearer $($this.AccessToken)" }
    }

    [hashtable] FetchProfileRow() {
        try {
            $uri = "$($this.Config.Url)/rest/v1/user_profiles?user_id=eq.$($this.UserId)&select=salt,iv,mac,cipher,iterations"
            $r = Invoke-RestMethod -Method Get -Uri $uri -Headers $this.AuthHeaders() -TimeoutSec $this.TimeoutSec
            if ($r -and @($r).Count -gt 0) { return @{ Ok = $true; Found = $true; Row = @($r)[0] } }
            return @{ Ok = $true; Found = $false }
        }
        catch { return @{ Ok = $false; Found = $false; Error = $this.ErrorText($_) } }
    }

    [hashtable] UpsertProfileRow([hashtable]$protected) {
        $row = @{
            user_id    = $this.UserId
            salt       = $protected.salt
            iv         = $protected.iv
            mac        = $protected.mac
            cipher     = $protected.cipher
            iterations = $protected.iterations
            updated_at = (Get-Date).ToUniversalTime().ToString('o')
        }
        try {
            $headers = $this.AuthHeaders()
            $headers['Content-Type'] = 'application/json'
            $headers['Prefer'] = 'resolution=merge-duplicates,return=minimal'
            Invoke-RestMethod -Method Post -Uri "$($this.Config.Url)/rest/v1/user_profiles" `
                -Headers $headers -Body ($row | ConvertTo-Json) -TimeoutSec $this.TimeoutSec | Out-Null
            return @{ Ok = $true }
        }
        catch { return @{ Ok = $false; Error = $this.ErrorText($_) } }
    }
}

# =====================================================================
# Stores
# =====================================================================

class ProfileStore {
    [string] $Name = 'abstract'
    [bool] Exists([UserIdentity]$identity) { throw 'Not implemented.' }
    [hashtable] Load([UserIdentity]$identity, [string]$passphrase) { throw 'Not implemented.' }
    [hashtable] Save([UserIdentity]$identity, [string]$passphrase, [ProfileData]$data) { throw 'Not implemented.' }
}

class SupabaseProfileStore : ProfileStore {
    [SupabaseClient] $Client

    SupabaseProfileStore([SupabaseClient]$client) {
        $this.Client = $client
        $this.Name = 'supabase'
    }

    [bool] Exists([UserIdentity]$identity) {
        $r = $this.Client.FetchProfileRow()
        return ($r.Ok -and $r.Found)
    }

    [hashtable] Load([UserIdentity]$identity, [string]$passphrase) {
        $row = $this.Client.FetchProfileRow()
        if (-not $row.Ok) { return @{ Ok = $false; Found = $false; Error = $row.Error } }
        if (-not $row.Found) { return @{ Ok = $true; Found = $false } }

        $plain = [SetupCrypto]::Unprotect($row.Row, $passphrase)
        if ([string]::IsNullOrEmpty($plain)) { return @{ Ok = $true; Found = $true; Decrypted = $false } }
        return @{ Ok = $true; Found = $true; Decrypted = $true; Data = [ProfileData]::FromJson($plain) }
    }

    [hashtable] Save([UserIdentity]$identity, [string]$passphrase, [ProfileData]$data) {
        $prot = [SetupCrypto]::Protect($data.ToJson(), $passphrase)
        return $this.Client.UpsertProfileRow($prot)
    }
}

class LocalProfileStore : ProfileStore {
    [SetupPaths] $Paths

    LocalProfileStore([SetupPaths]$paths) {
        $this.Paths = $paths
        $this.Name = 'local'
    }

    [string] PathFor([UserIdentity]$identity) {
        return [IO.Path]::Combine($this.Paths.EnsureProfileDir(), "$($identity.Id).json")
    }

    [bool] Exists([UserIdentity]$identity) { return (Test-Path -LiteralPath $this.PathFor($identity)) }

    [hashtable] Load([UserIdentity]$identity, [string]$passphrase) {
        $path = $this.PathFor($identity)
        if (-not (Test-Path -LiteralPath $path)) { return @{ Ok = $true; Found = $false } }
        $record = $null
        try { $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
        catch { return @{ Ok = $true; Found = $true; Decrypted = $false; Error = 'corrupt' } }

        $plain = [SetupCrypto]::Unprotect($record, $passphrase)
        if ([string]::IsNullOrEmpty($plain)) { return @{ Ok = $true; Found = $true; Decrypted = $false } }
        return @{ Ok = $true; Found = $true; Decrypted = $true; Data = [ProfileData]::FromJson($plain) }
    }

    [hashtable] Save([UserIdentity]$identity, [string]$passphrase, [ProfileData]$data) {
        $prot = [SetupCrypto]::Protect($data.ToJson(), $passphrase)
        $record = [ordered]@{
            id             = $identity.Id
            v              = 1
            alg            = 'AES-256-CBC+HMAC-SHA256'
            kdf            = 'PBKDF2-SHA256'
            iterations     = $prot.iterations
            identifierType = $identity.Type
            salt           = $prot.salt
            iv             = $prot.iv
            mac            = $prot.mac
            cipher         = $prot.cipher
            updatedAt      = (Get-Date).ToString('o')
        }
        $path = $this.PathFor($identity)
        ($record | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
        return @{ Ok = $true; Path = $path }
    }

    hidden [string] GitExe() {
        $c = Get-Command git -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", '/usr/bin/git', '/usr/local/bin/git', '/opt/homebrew/bin/git')) {
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
        return $null
    }

    [void] Pull() {
        $git = $this.GitExe(); $root = $this.Paths.RepoRoot()
        if (-not $git -or -not $root) { return }
        try { & $git -C $root pull --ff-only 2>&1 | Out-Null } catch { }
    }

    [hashtable] Publish([string]$profilePath) {
        $git = $this.GitExe(); $root = $this.Paths.RepoRoot()
        if (-not $git) { return @{ Ok = $false; Reason = 'git-not-found' } }
        if (-not $root) { return @{ Ok = $false; Reason = 'not-a-git-repo' } }
        if (-not (Test-Path -LiteralPath $profilePath)) { return @{ Ok = $false; Reason = 'profile-missing' } }
        try {
            # Scoped to the single profile file so logs/keys are never staged.
            & $git -C $root add -- "$profilePath" 2>&1 | Out-Null
            & $git -C $root diff --cached --quiet -- "$profilePath" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Reason = 'no-changes' } }
            & $git -C $root commit -m 'Update encrypted user setup profile' -- "$profilePath" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = 'commit-failed' } }
            & $git -C $root push 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = 'push-failed' } }
            return @{ Ok = $true; Reason = 'pushed' }
        }
        catch { return @{ Ok = $false; Reason = $_.Exception.Message } }
    }
}

# =====================================================================
# Offline OTP (only used when Supabase isn't configured)
# =====================================================================

class OtpChallenge {
    [string] $Salt
    [string] $Hash
    [datetime] $Expires
    [int] $Attempts = 0
    [int] $MaxAttempts = 5
    [string] $Channel
    [bool] $Sent
    [string] $Method
    [string] $Error

    [bool] IsExpired() { return (Get-Date) -gt $this.Expires }
}

class OtpService {
    [SetupPaths] $Paths
    hidden [hashtable] $Config

    OtpService([SetupPaths]$paths) {
        $this.Paths = $paths
        $this.Config = $this.LoadConfig()
    }

    hidden [hashtable] LoadConfig() {
        $cfg = @{}
        $file = $this.Paths.OtpConfigFile()
        if (Test-Path -LiteralPath $file) {
            try {
                $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = [string]$p.Value }
            }
            catch { }
        }
        foreach ($k in @('SMTP_HOST', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM', 'SMTP_SSL',
                'SMS_API_URL', 'SMS_API_KEY', 'SMS_FROM', 'TWILIO_SID', 'TWILIO_TOKEN', 'TWILIO_FROM')) {
            $v = [Environment]::GetEnvironmentVariable("SETUP_OTP_$k")
            if (-not [string]::IsNullOrEmpty($v)) { $cfg[$k] = $v }
        }
        return $cfg
    }

    hidden [string] NewCode([int]$length) {
        $bytes = [SetupCrypto]::RandomBytes($length)
        $sb = [Text.StringBuilder]::new()
        foreach ($b in $bytes) { [void]$sb.Append(($b % 10).ToString()) }
        return $sb.ToString()
    }

    hidden [string] HashCode([string]$code, [string]$saltB64) {
        return [SetupCrypto]::Sha256Hex("$saltB64|$code")
    }

    hidden [hashtable] SendEmail([string]$to, [string]$code) {
        if (-not $this.Config.ContainsKey('SMTP_HOST')) { return @{ Sent = $false; Error = 'SMTP not configured' } }
        try {
            $from = if ($this.Config.ContainsKey('SMTP_FROM')) { $this.Config.SMTP_FROM } else { $this.Config.SMTP_USER }
            $port = if ($this.Config.ContainsKey('SMTP_PORT')) { [int]$this.Config.SMTP_PORT } else { 587 }
            $body = "Your System-Setup verification code is: $code`r`n`r`nIt expires in 5 minutes."
            $params = @{
                SmtpServer = $this.Config.SMTP_HOST; Port = $port; From = $from; To = $to
                Subject    = 'Your System-Setup verification code'; Body = $body
            }
            if (-not $this.Config.ContainsKey('SMTP_SSL') -or $this.Config.SMTP_SSL -ne 'false') { $params['UseSsl'] = $true }
            if ($this.Config.ContainsKey('SMTP_USER')) {
                $sec = ConvertTo-SecureString $this.Config.SMTP_PASS -AsPlainText -Force
                $params['Credential'] = [PSCredential]::new($this.Config.SMTP_USER, $sec)
            }
            Send-MailMessage @params -ErrorAction Stop -WarningAction SilentlyContinue
            return @{ Sent = $true; Method = 'email' }
        }
        catch { return @{ Sent = $false; Error = $_.Exception.Message } }
    }

    hidden [hashtable] SendSms([string]$to, [string]$code) {
        $text = "System-Setup verification code: $code (expires in 5 minutes)"
        if ($this.Config.ContainsKey('TWILIO_SID') -and $this.Config.ContainsKey('TWILIO_TOKEN') -and $this.Config.ContainsKey('TWILIO_FROM')) {
            try {
                $uri = "https://api.twilio.com/2010-04-01/Accounts/$($this.Config.TWILIO_SID)/Messages.json"
                $sec = ConvertTo-SecureString $this.Config.TWILIO_TOKEN -AsPlainText -Force
                $cred = [PSCredential]::new($this.Config.TWILIO_SID, $sec)
                Invoke-RestMethod -Uri $uri -Method Post -Credential $cred -TimeoutSec 30 `
                    -Body @{ To = $to; From = $this.Config.TWILIO_FROM; Body = $text } | Out-Null
                return @{ Sent = $true; Method = 'sms' }
            }
            catch { return @{ Sent = $false; Error = $_.Exception.Message } }
        }
        if ($this.Config.ContainsKey('SMS_API_URL')) {
            try {
                $headers = @{}
                if ($this.Config.ContainsKey('SMS_API_KEY')) { $headers['Authorization'] = "Bearer $($this.Config.SMS_API_KEY)" }
                $payload = @{ to = $to; text = $text }
                if ($this.Config.ContainsKey('SMS_FROM')) { $payload['from'] = $this.Config.SMS_FROM }
                Invoke-RestMethod -Uri $this.Config.SMS_API_URL -Method Post -Headers $headers `
                    -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30 | Out-Null
                return @{ Sent = $true; Method = 'sms' }
            }
            catch { return @{ Sent = $false; Error = $_.Exception.Message } }
        }
        return @{ Sent = $false; Error = 'SMS not configured' }
    }

    [OtpChallenge] CreateChallenge([UserIdentity]$identity) {
        $code = $this.NewCode(6)
        $salt = [Convert]::ToBase64String([SetupCrypto]::RandomBytes(16))

        $c = [OtpChallenge]::new()
        $c.Salt = $salt
        $c.Hash = $this.HashCode($code, $salt)   # only the hash is retained
        $c.Expires = (Get-Date).AddMinutes(5)
        $c.Channel = $identity.Type

        $res = if ($identity.IsEmail()) { $this.SendEmail($identity.Value, $code) } else { $this.SendSms($identity.ToE164(), $code) }
        if (-not $res.Sent -and [Environment]::GetEnvironmentVariable('SETUP_OTP_DEV') -eq '1') {
            Write-Host "[OTP DEV] code for $($identity.Value) = $code" -ForegroundColor Yellow
            $res = @{ Sent = $true; Method = 'dev' }
        }
        $c.Sent = $res.Sent
        $c.Method = if ($res.ContainsKey('Method')) { $res.Method } else { '' }
        $c.Error = if ($res.ContainsKey('Error')) { $res.Error } else { '' }
        return $c
    }

    [hashtable] Verify([OtpChallenge]$challenge, [string]$input) {
        if ($null -eq $challenge) { return @{ Ok = $false; Reason = 'no active code' } }
        if ($challenge.IsExpired()) { return @{ Ok = $false; Reason = 'code expired -- request a new one' } }
        if ($challenge.Attempts -ge $challenge.MaxAttempts) { return @{ Ok = $false; Reason = 'too many attempts' } }
        $challenge.Attempts++

        $clean = ($input -replace '\D', '')
        if ([string]::IsNullOrEmpty($clean)) { return @{ Ok = $false; Reason = 'enter the code you received' } }
        if ($this.HashCode($clean, $challenge.Salt) -eq $challenge.Hash) { return @{ Ok = $true; Reason = 'verified' } }

        $left = $challenge.MaxAttempts - $challenge.Attempts
        if ($left -le 0) { return @{ Ok = $false; Reason = 'too many attempts' } }
        return @{ Ok = $false; Reason = "incorrect code ($left attempt(s) left)" }
    }
}

# =====================================================================
# Error reporting
# =====================================================================

class ErrorReporter {
    [SupabaseConfig] $Config
    [string] $Platform
    [string] $OsVersion
    [string] $UserId
    [bool]   $Enabled = $true
    hidden [System.Collections.Generic.List[hashtable]] $Pending

    ErrorReporter([SupabaseConfig]$config) {
        $this.Config = $config
        $this.Pending = [System.Collections.Generic.List[hashtable]]::new()
        $this.Platform = if ($script:OnWindows) { 'windows' } else { 'macos' }
        try { $this.OsVersion = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim() }
        catch { $this.OsVersion = 'unknown' }
    }

    # Never let telemetry break an install: failures are swallowed and queued.
    [void] Report([string]$phase, [string]$package, [string]$message, [string]$detail) {
        if (-not $this.Enabled -or [string]::IsNullOrWhiteSpace($message)) { return }

        $row = @{
            platform   = $this.Platform
            phase      = $phase
            package    = $package
            message    = $this.Truncate($message, 1000)
            detail     = $this.Truncate($detail, 4000)
            os_version = $this.OsVersion
        }
        if ($this.UserId) { $row['user_id'] = $this.UserId }

        if (-not $this.Config -or -not $this.Config.IsEnabled()) { $this.Pending.Add($row); return }
        try {
            Invoke-RestMethod -Method Post -Uri "$($this.Config.Url)/rest/v1/setup_errors" `
                -Headers @{
                apikey         = $this.Config.Key
                'Content-Type' = 'application/json'
                Prefer         = 'return=minimal'
            } -Body ($row | ConvertTo-Json) -TimeoutSec 15 | Out-Null
        }
        catch { $this.Pending.Add($row) }
    }

    [void] ReportException([string]$phase, [string]$package, $errorRecord) {
        $msg = ''; $detail = ''
        try { $msg = $errorRecord.Exception.Message } catch { $msg = [string]$errorRecord }
        try { $detail = $errorRecord.ScriptStackTrace } catch { }
        $this.Report($phase, $package, $msg, $detail)
    }

    hidden [string] Truncate([string]$text, [int]$max) {
        if ([string]::IsNullOrEmpty($text)) { return '' }
        if ($text.Length -le $max) { return $text }
        return $text.Substring(0, $max)
    }

    [int] PendingCount() { return $this.Pending.Count }

    # Retry anything queued while the network or auth was unavailable.
    [int] Flush() {
        if ($this.Pending.Count -eq 0) { return 0 }
        if (-not $this.Config -or -not $this.Config.IsEnabled()) { return 0 }
        $sent = 0
        foreach ($row in @($this.Pending)) {
            try {
                Invoke-RestMethod -Method Post -Uri "$($this.Config.Url)/rest/v1/setup_errors" `
                    -Headers @{
                    apikey         = $this.Config.Key
                    'Content-Type' = 'application/json'
                    Prefer         = 'return=minimal'
                } -Body ($row | ConvertTo-Json) -TimeoutSec 15 | Out-Null
                [void]$this.Pending.Remove($row)
                $sent++
            }
            catch { break }
        }
        return $sent
    }
}

# =====================================================================
# Facade
# =====================================================================

class ProfileManager {
    [SetupPaths] $Paths
    [SupabaseConfig] $Config
    [SupabaseClient] $Client
    [ProfileStore] $Store
    [OtpService] $Otp
    [ErrorReporter] $Errors
    [UserIdentity] $Identity
    [OtpChallenge] $Challenge
    [bool] $Verified = $false
    [string] $LastLocalPath

    ProfileManager([string]$sharedRoot) {
        $this.Paths = [SetupPaths]::new($sharedRoot)
        $this.Config = [SupabaseConfig]::Load($this.Paths.ConfigFile())
        $this.Errors = [ErrorReporter]::new($this.Config)

        # Escape hatch for offline machines, air-gapped installs and testing
        # without burning the email quota.
        $forceOffline = [Environment]::GetEnvironmentVariable('SETUP_FORCE_OFFLINE') -eq '1'

        if ($this.Config.IsEnabled() -and -not $forceOffline) {
            $this.Client = [SupabaseClient]::new($this.Config)
            $this.Store = [SupabaseProfileStore]::new($this.Client)
        }
        else {
            $this.Store = [LocalProfileStore]::new($this.Paths)
            $this.Otp = [OtpService]::new($this.Paths)
        }
    }

    [bool] IsOnline() { return $this.Store.Name -eq 'supabase' }

    [void] Prepare() {
        if (-not $this.IsOnline()) { ([LocalProfileStore]$this.Store).Pull() }
    }

    [hashtable] BeginVerification([string]$identifier) {
        $this.Identity = [UserIdentity]::new($identifier)
        if ($this.IsOnline()) {
            $r = $this.Client.SendOtp($this.Identity)
            return @{ Ok = $r.Ok; Channel = $r.Channel; Error = $(if ($r.ContainsKey('Error')) { $r.Error } else { '' }) }
        }
        $this.Challenge = $this.Otp.CreateChallenge($this.Identity)
        return @{
            Ok      = $this.Challenge.Sent
            Channel = $this.Challenge.Channel
            Method  = $this.Challenge.Method
            Error   = $this.Challenge.Error
        }
    }

    [hashtable] CompleteVerification([string]$code) {
        if ($this.IsOnline()) {
            $r = $this.Client.VerifyOtp($this.Identity, $code)
            if ($r.Ok) { $this.Verified = $true; $this.Errors.UserId = $this.Client.UserId }
            return @{ Ok = $r.Ok; Reason = $(if ($r.ContainsKey('Error')) { $r.Error } else { '' }) }
        }
        $r = $this.Otp.Verify($this.Challenge, $code)
        if ($r.Ok) { $this.Verified = $true }
        return $r
    }

    [void] ResetChallenge() { $this.Challenge = $null }

    [bool] ProfileExists() {
        if (-not $this.Identity) { return $false }
        return $this.Store.Exists($this.Identity)
    }

    [hashtable] LoadProfile([string]$passphrase) { return $this.Store.Load($this.Identity, $passphrase) }

    [hashtable] SaveProfile([string]$passphrase, [ProfileData]$data) {
        $r = $this.Store.Save($this.Identity, $passphrase, $data)
        if ($r.Ok -and $r.ContainsKey('Path')) { $this.LastLocalPath = $r.Path }
        return $r
    }

    [hashtable] PublishIfLocal() {
        if ($this.IsOnline() -or -not $this.LastLocalPath) { return @{ Ok = $true; Reason = 'not-needed' } }
        return ([LocalProfileStore]$this.Store).Publish($this.LastLocalPath)
    }
}

# =====================================================================
# Factories -- callers avoid `using module`, which needs a static path
# =====================================================================

function Get-SetupSharedRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function New-ProfileManager {
    param([string]$SharedRoot = (Get-SetupSharedRoot))
    return [ProfileManager]::new($SharedRoot)
}

function New-ProfileData {
    param(
        [string]$Name = '',
        [string[]]$Packages = @(),
        [string[]]$Features = @(),
        [string]$DefaultShell = '1',
        [object[]]$Apps = @(),
        [object[]]$Repos = @(),
        [object[]]$Dotfiles = @(),
        [hashtable]$Tools = @{}
    )
    $p = [ProfileData]::new()
    $p.Name = $Name; $p.Packages = $Packages; $p.Features = $Features; $p.DefaultShell = $DefaultShell
    $p.Apps = $Apps; $p.Repos = $Repos; $p.Dotfiles = $Dotfiles; $p.Tools = $Tools
    return $p
}

function New-SupabaseConfigContent {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$PublishableKey)
    return [SupabaseConfig]::BuildEncryptedFile($Url, $PublishableKey)
}

function Get-SetupPaths {
    param([string]$SharedRoot = (Get-SetupSharedRoot))
    return [SetupPaths]::new($SharedRoot)
}

function New-ErrorReporter {
    param([string]$SharedRoot = (Get-SetupSharedRoot))
    return [ErrorReporter]::new([SupabaseConfig]::Load(([SetupPaths]::new($SharedRoot)).ConfigFile()))
}

Export-ModuleMember -Function New-ProfileManager, New-ProfileData, New-SupabaseConfigContent,
Get-SetupPaths, Get-SetupSharedRoot, New-ErrorReporter
