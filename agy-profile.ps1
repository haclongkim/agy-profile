<#
.SYNOPSIS
  agy-profile - Account (profile) manager for the Antigravity CLI (agy.exe)

.DESCRIPTION
  Save and quickly switch between login accounts of the Antigravity CLI.
  The agy login token lives in Windows Credential Manager
  (target: gemini:antigravity). This script reads/writes that credential
  and stores a DPAPI-encrypted copy on disk for each profile.
  Everything else (settings, knowledge, skills, MCP config...) stays shared.

.EXAMPLE
  agy-profile save work
  agy-profile switch personal
  agy-profile list
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Command = 'help',
    [Parameter(Position = 1)] [string]$Name,
    [Parameter(Position = 2)] [string]$Path,
    [switch]$Force,
    # Non-interactive password for export/import. Prefer the interactive prompt -
    # a value passed here can end up in shell history or process listings.
    [string]$Password
)

$ErrorActionPreference = 'Stop'

# --- Configuration -----------------------------------------------------------
$CRED_TARGET       = 'gemini:antigravity'
$CLI_DIR           = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
$PROFILES_DIR      = Join-Path $env:USERPROFILE '.gemini\agy-profiles'
$ACTIVE_FILE       = Join-Path $PROFILES_DIR '_active.txt'
# Account-bound files, backed up/restored per profile
$PER_PROFILE_FILES = @('cache\default_project_id.txt')

Add-Type -AssemblyName System.Security

# --- P/Invoke: Windows Credential Manager ------------------------------------
if (-not ('CredMan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class CredManData {
    public string UserName;
    public string Comment;
    public uint Persist;
    public byte[] Blob;
}

public static class CredMan {
    private const uint CRED_TYPE_GENERIC = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static CredManData Read(string target) {
        IntPtr pcred;
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out pcred)) return null;
        try {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(pcred, typeof(CREDENTIAL));
            CredManData d = new CredManData();
            d.UserName = Marshal.PtrToStringUni(c.UserName);
            d.Comment  = Marshal.PtrToStringUni(c.Comment);
            d.Persist  = c.Persist;
            d.Blob     = new byte[c.CredentialBlobSize];
            if (c.CredentialBlobSize > 0)
                Marshal.Copy(c.CredentialBlob, d.Blob, 0, (int)c.CredentialBlobSize);
            return d;
        } finally { CredFree(pcred); }
    }

    public static void Write(string target, string userName, string comment, uint persist, byte[] blob) {
        CREDENTIAL c = new CREDENTIAL();
        c.Type       = CRED_TYPE_GENERIC;
        c.TargetName = Marshal.StringToCoTaskMemUni(target);
        c.UserName   = userName == null ? IntPtr.Zero : Marshal.StringToCoTaskMemUni(userName);
        c.Comment    = comment  == null ? IntPtr.Zero : Marshal.StringToCoTaskMemUni(comment);
        int len = blob == null ? 0 : blob.Length;
        c.CredentialBlobSize = (uint)len;
        c.CredentialBlob     = len == 0 ? IntPtr.Zero : Marshal.AllocCoTaskMem(len);
        if (len > 0) Marshal.Copy(blob, 0, c.CredentialBlob, len);
        c.Persist = persist;
        try {
            if (!CredWrite(ref c, 0))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally {
            Marshal.FreeCoTaskMem(c.TargetName);
            if (c.UserName       != IntPtr.Zero) Marshal.FreeCoTaskMem(c.UserName);
            if (c.Comment        != IntPtr.Zero) Marshal.FreeCoTaskMem(c.Comment);
            if (c.CredentialBlob != IntPtr.Zero) Marshal.FreeCoTaskMem(c.CredentialBlob);
        }
    }

    public static bool Delete(string target) {
        return CredDelete(target, CRED_TYPE_GENERIC, 0);
    }
}
'@
}

# --- Helpers -----------------------------------------------------------------

function Test-ProfileName([string]$n) {
    if (-not $n) { throw "Missing profile name. Usage: agy-profile $Command <name>" }
    if ($n -notmatch '^[a-zA-Z0-9_-]+$') {
        throw "Profile names may only contain letters, digits, '-' and '_'."
    }
}

function Get-ProfileDir([string]$n) { Join-Path $PROFILES_DIR $n }

function Get-BlobHash([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-CurrentCred { [CredMan]::Read($CRED_TARGET) }

# User-named profiles (skips _unsaved-* folders, _active.txt, ...)
function Get-SavedProfiles {
    if (-not (Test-Path $PROFILES_DIR)) { return @() }
    @(Get-ChildItem $PROFILES_DIR -Directory |
        Where-Object { $_.Name -notlike '_*' -and (Test-Path (Join-Path $_.FullName 'credential.dpapi')) })
}

function Read-ProfileMeta([string]$dirPath) {
    $p = Join-Path $dirPath 'meta.json'
    if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { $null }
}

function Protect-JsonToFile([string]$json, [string]$path) {
    $plain = [Text.Encoding]::UTF8.GetBytes($json)
    $enc   = [Security.Cryptography.ProtectedData]::Protect($plain, $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($path, $enc)
}

function Protect-ToFile($cred, [string]$path) {
    $json = @{
        userName = $cred.UserName
        comment  = $cred.Comment
        persist  = $cred.Persist
        blobB64  = [Convert]::ToBase64String($cred.Blob)
    } | ConvertTo-Json
    Protect-JsonToFile $json $path
}

function Unprotect-FromFile([string]$path) {
    $enc = [IO.File]::ReadAllBytes($path)
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'CurrentUser')
    } catch {
        throw "Could not decrypt '$path'. DPAPI files can only be used by the same Windows user that created them."
    }
    [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
}

# --- Password-based crypto for export/import (portable, NOT tied to DPAPI) ---
# DPAPI keys are bound to this Windows user + machine, so exported files use a
# password-derived key instead: PBKDF2-SHA256 -> AES-256-CBC, encrypt-then-MAC
# with HMAC-SHA256. Layout: "AGYP1"(5) + salt(16) + iv(16) + hmacTag(32) + ciphertext
$EXPORT_MAGIC      = 'AGYP1'
$EXPORT_KDF_ITERS  = 200000
$EXPORT_HEADER_LEN = 5 + 16 + 16 + 32   # magic + salt + iv + tag

function Get-ByteRange([byte[]]$arr, [int]$start, [int]$count) {
    $out = New-Object byte[] $count
    [Array]::Copy($arr, $start, $out, 0, $count)
    return $out
}

function Test-BytesEqual([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    return $diff -eq 0
}

function ConvertFrom-SecureStringPlain($secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-PasswordTwice([string]$prompt) {
    if ($Password) { return $Password }
    $p1 = ConvertFrom-SecureStringPlain (Read-Host -AsSecureString $prompt)
    $p2 = ConvertFrom-SecureStringPlain (Read-Host -AsSecureString "Confirm $prompt")
    if ($p1 -ne $p2) { throw 'Passwords do not match.' }
    if ($p1.Length -lt 8) { throw 'Password must be at least 8 characters.' }
    return $p1
}

function Read-PasswordOnce([string]$prompt) {
    if ($Password) { return $Password }
    ConvertFrom-SecureStringPlain (Read-Host -AsSecureString $prompt)
}

function Get-PasswordKeys([string]$password, [byte[]]$salt) {
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes(
        $password, $salt, $EXPORT_KDF_ITERS, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $material = $kdf.GetBytes(64)   # first 32 bytes = AES key, last 32 = HMAC key
        return @{ EncKey = Get-ByteRange $material 0 32; MacKey = Get-ByteRange $material 32 32 }
    } finally { $kdf.Dispose() }
}

function Protect-WithPassword([byte[]]$plainBytes, [string]$password) {
    $rng  = [Security.Cryptography.RandomNumberGenerator]::Create()
    $salt = New-Object byte[] 16; $rng.GetBytes($salt)
    $iv   = New-Object byte[] 16; $rng.GetBytes($iv)
    $keys = Get-PasswordKeys $password $salt

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys.EncKey; $aes.IV = $iv
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $cipherBytes = $aes.CreateEncryptor().TransformFinalBlock($plainBytes, 0, $plainBytes.Length)

    $hmac = New-Object Security.Cryptography.HMACSHA256(, $keys.MacKey)
    $tag  = $hmac.ComputeHash($salt + $iv + $cipherBytes)

    [Text.Encoding]::ASCII.GetBytes($EXPORT_MAGIC) + $salt + $iv + $tag + $cipherBytes
}

function Unprotect-WithPassword([byte[]]$blob, [string]$password) {
    if ($blob.Length -lt $EXPORT_HEADER_LEN) {
        throw 'File is too short to be a valid agy-profile export.'
    }
    $magic = [Text.Encoding]::ASCII.GetString((Get-ByteRange $blob 0 5))
    if ($magic -ne $EXPORT_MAGIC) {
        throw 'Unrecognized file format (bad header). Is this really an .agyprofile export?'
    }
    $salt        = Get-ByteRange $blob 5 16
    $iv          = Get-ByteRange $blob 21 16
    $tag         = Get-ByteRange $blob 37 32
    $cipherBytes = Get-ByteRange $blob $EXPORT_HEADER_LEN ($blob.Length - $EXPORT_HEADER_LEN)

    $keys = Get-PasswordKeys $password $salt
    $hmac = New-Object Security.Cryptography.HMACSHA256(, $keys.MacKey)
    $expectedTag = $hmac.ComputeHash($salt + $iv + $cipherBytes)
    if (-not (Test-BytesEqual $expectedTag $tag)) {
        throw 'Wrong password, or the file is corrupted.'
    }

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys.EncKey; $aes.IV = $iv
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    try {
        $aes.CreateDecryptor().TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
    } catch {
        throw 'Wrong password, or the file is corrupted.'
    }
}

function Write-ProfileMeta([string]$dir, [string]$profileName, $cred) {
    @{
        name       = $profileName
        userName   = $cred.UserName
        blobSha256 = Get-BlobHash $cred.Blob
        savedAt    = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $dir 'meta.json')
}

# If the current credential matches no saved profile (incl. _unsaved-*), back it up
function Backup-IfUnsaved($cred) {
    if ($null -eq $cred) { return }
    $hash = Get-BlobHash $cred.Blob
    $allDirs = @(Get-ChildItem $PROFILES_DIR -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $allDirs) {
        $meta = Read-ProfileMeta $d.FullName
        if ($meta -and $meta.blobSha256 -eq $hash) { return }
    }
    $ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $PROFILES_DIR "_unsaved-$ts"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Protect-ToFile $cred (Join-Path $dir 'credential.dpapi')
    Write-ProfileMeta $dir "_unsaved-$ts" $cred
    Write-Warning "The logged-in account was never saved - backed it up to: $dir"
    Write-Warning "To restore it, rename that folder (drop the '_' prefix), then run: agy-profile switch <name>"
}

function Confirm-Action([string]$question) {
    if ($Force) { return $true }
    $ans = Read-Host "$question (y/N)"
    return ($ans -match '^[yY]')
}

# --- Commands ----------------------------------------------------------------

function Invoke-Save {
    Test-ProfileName $Name
    $cred = Get-CurrentCred
    if ($null -eq $cred -or $cred.Blob.Length -eq 0) {
        throw "Credential '$CRED_TARGET' not found. Log in with agy first, then save."
    }
    $dir = Get-ProfileDir $Name
    if (Test-Path (Join-Path $dir 'credential.dpapi')) {
        if (-not (Confirm-Action "Profile '$Name' already exists. Overwrite?")) {
            Write-Host 'Cancelled.'; return
        }
    }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Protect-ToFile $cred (Join-Path $dir 'credential.dpapi')
    foreach ($rel in $PER_PROFILE_FILES) {
        $src = Join-Path $CLI_DIR $rel
        if (Test-Path $src) {
            $dst = Join-Path $dir "files\$rel"
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            Copy-Item $src $dst -Force
        }
    }
    Write-ProfileMeta $dir $Name $cred
    Set-Content -Encoding ASCII $ACTIVE_FILE $Name
    Write-Host "Saved the current account as profile '$Name'." -ForegroundColor Green
}

function Invoke-Switch {
    param([string]$TargetName = $Name)
    Test-ProfileName $TargetName
    $dir      = Get-ProfileDir $TargetName
    $credFile = Join-Path $dir 'credential.dpapi'
    if (-not (Test-Path $credFile)) {
        throw "Profile '$TargetName' does not exist. See: agy-profile list"
    }

    if (-not $Force) {
        $proc = @(Get-Process -Name agy -ErrorAction SilentlyContinue)
        if ($proc.Count -gt 0) {
            throw "agy is running (PID: $(($proc | ForEach-Object Id) -join ', ')). Close agy before switching, or add -Force."
        }
    }

    $target  = Read-ProfileMeta $dir
    $current = Get-CurrentCred
    if ($current -and $target -and (Get-BlobHash $current.Blob) -eq $target.blobSha256 -and -not $Force) {
        Write-Host "Already on profile '$TargetName' - nothing to do."
        Set-Content -Encoding ASCII $ACTIVE_FILE $TargetName
        return
    }

    if ($current) { Backup-IfUnsaved $current }

    $data = Unprotect-FromFile $credFile
    [CredMan]::Write($CRED_TARGET, $data.userName, $data.comment, [uint32]$data.persist,
        [Convert]::FromBase64String($data.blobB64))

    foreach ($rel in $PER_PROFILE_FILES) {
        $src = Join-Path $dir "files\$rel"
        $dst = Join-Path $CLI_DIR $rel
        if (Test-Path $src) {
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            Copy-Item $src $dst -Force
        } elseif (Test-Path $dst) {
            Remove-Item $dst -Force   # avoid reusing another account's project id
        }
    }

    Set-Content -Encoding ASCII $ACTIVE_FILE $TargetName
    $who = if ($data.userName) { " ($($data.userName))" } else { '' }
    Write-Host "Switched to profile '$TargetName'$who." -ForegroundColor Green
}

# Active profile name: prefer matching the real credential hash, fall back to _active.txt
function Get-ActiveProfileName {
    $cred = Get-CurrentCred
    if ($cred) {
        $hash = Get-BlobHash $cred.Blob
        foreach ($p in Get-SavedProfiles) {
            $meta = Read-ProfileMeta $p.FullName
            if ($meta -and $meta.blobSha256 -eq $hash) { return $p.Name }
        }
    }
    if (Test-Path $ACTIVE_FILE) { return (Get-Content $ACTIVE_FILE).Trim() }
    return $null
}

function Invoke-Next {
    $profiles = @(Get-SavedProfiles | Sort-Object Name)
    if ($profiles.Count -eq 0) {
        throw "No profiles yet. Save the current account with: agy-profile save <name>"
    }
    $names   = @($profiles | ForEach-Object Name)
    $idx     = [array]::IndexOf($names, [string](Get-ActiveProfileName))
    $nextIdx = ($idx + 1) % $names.Count           # idx = -1 (active unknown) -> first profile
    Write-Host "next -> '$($names[$nextIdx])' ($($nextIdx + 1)/$($names.Count) in A-Z order)"
    Invoke-Switch $names[$nextIdx]
}

function Invoke-Random {
    $profiles = @(Get-SavedProfiles | Sort-Object Name)
    if ($profiles.Count -eq 0) {
        throw "No profiles yet. Save the current account with: agy-profile save <name>"
    }
    $active     = Get-ActiveProfileName
    $candidates = @($profiles | Where-Object { $_.Name -ne $active })
    if ($candidates.Count -eq 0) {
        Write-Host "Only one profile ('$active') exists - no other profile to switch to."
        return
    }
    $pick = ($candidates | Get-Random).Name
    Write-Host "random -> '$pick' (picked from $($candidates.Count) profiles other than the current one)"
    Invoke-Switch $pick
}

function Invoke-List {
    $profiles = Get-SavedProfiles
    if ($profiles.Count -eq 0) {
        Write-Host "No profiles yet. Save the current account with: agy-profile save <name>"
        return
    }
    $cred    = Get-CurrentCred
    $curHash = if ($cred) { Get-BlobHash $cred.Blob } else { $null }
    Write-Host "Saved profiles ('*' = matches the logged-in account):"
    foreach ($p in $profiles) {
        $meta = Read-ProfileMeta $p.FullName
        $mark = if ($meta -and $meta.blobSha256 -eq $curHash) { '*' } else { ' ' }
        "  {0} {1,-20} {2}" -f $mark, $p.Name, $meta.savedAt
    }
    if (-not $cred) {
        Write-Warning "Not logged in to any account (credential '$CRED_TARGET' does not exist)."
    }
}

function Invoke-Current {
    $cred = Get-CurrentCred
    if (-not $cred) {
        Write-Host "Not logged in (credential '$CRED_TARGET' does not exist)."
        return
    }
    $hash  = Get-BlobHash $cred.Blob
    $match = $null
    foreach ($p in Get-SavedProfiles) {
        $meta = Read-ProfileMeta $p.FullName
        if ($meta -and $meta.blobSha256 -eq $hash) { $match = $meta; break }
    }
    if ($match) {
        Write-Host "Active profile: $($match.name)" -ForegroundColor Green
    } else {
        $active = if (Test-Path $ACTIVE_FILE) { (Get-Content $ACTIVE_FILE).Trim() } else { '(not recorded)' }
        Write-Warning "The logged-in account matches NO saved profile (last switch: $active)."
        Write-Warning "If this is a new account or the token was refreshed, run: agy-profile save <name>"
    }
}

function Invoke-Delete {
    Test-ProfileName $Name
    $dir = Get-ProfileDir $Name
    if (-not (Test-Path $dir)) { throw "Profile '$Name' does not exist." }
    if (-not (Confirm-Action "Delete the saved copy of profile '$Name'? (the logged-in account is not affected)")) {
        Write-Host 'Cancelled.'; return
    }
    Remove-Item $dir -Recurse -Force
    if ((Test-Path $ACTIVE_FILE) -and ((Get-Content $ACTIVE_FILE).Trim() -eq $Name)) {
        Remove-Item $ACTIVE_FILE -Force
    }
    Write-Host "Deleted profile '$Name'." -ForegroundColor Green
}

function Invoke-Logout {
    $cred = Get-CurrentCred
    if (-not $cred) { Write-Host 'No credential to delete.'; return }
    if (-not (Confirm-Action "Delete the current credential? The next agy run will require logging in again.")) {
        Write-Host 'Cancelled.'; return
    }
    Backup-IfUnsaved $cred
    [CredMan]::Delete($CRED_TARGET) | Out-Null
    if (Test-Path $ACTIVE_FILE) { Remove-Item $ACTIVE_FILE -Force }
    Write-Host "Logged out. Run 'agy' to log in with another account, then 'agy-profile save <name>' to save it." -ForegroundColor Green
}

function Invoke-Export {
    param([string]$ProfileName = $Name, [string]$OutFile = $Path)
    Test-ProfileName $ProfileName
    $dir      = Get-ProfileDir $ProfileName
    $credFile = Join-Path $dir 'credential.dpapi'
    if (-not (Test-Path $credFile)) {
        throw "Profile '$ProfileName' does not exist. See: agy-profile list"
    }
    if (-not $OutFile) { $OutFile = Join-Path (Get-Location) "$ProfileName.agyprofile" }

    if ((Test-Path $OutFile) -and -not (Confirm-Action "File '$OutFile' already exists. Overwrite?")) {
        Write-Host 'Cancelled.'; return
    }

    $data = Unprotect-FromFile $credFile

    $filesMap = @{}
    foreach ($rel in $PER_PROFILE_FILES) {
        $src = Join-Path $dir "files\$rel"
        if (Test-Path $src) {
            $filesMap[$rel] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($src))
        }
    }

    $payload = @{
        formatVersion = 1
        profileName   = $ProfileName
        exportedAt    = (Get-Date).ToString('s')
        userName      = $data.userName
        comment       = $data.comment
        persist       = $data.persist
        blobB64       = $data.blobB64
        files         = $filesMap
    } | ConvertTo-Json -Depth 5 -Compress

    $password  = Read-PasswordTwice "Password to protect this export"
    $encrypted = Protect-WithPassword ([Text.Encoding]::UTF8.GetBytes($payload)) $password
    [IO.File]::WriteAllBytes($OutFile, $encrypted)

    Write-Host "Exported profile '$ProfileName' to: $OutFile" -ForegroundColor Green
    Write-Warning 'Keep the password safe - it cannot be recovered from the file.'
    Write-Warning 'Anyone who obtains this file AND the password can log in as this account.'
}

function Invoke-Import {
    param([string]$File = $Name, [string]$OverrideName = $Path)
    if (-not $File) { throw "Missing file path. Usage: agy-profile import <file> [name]" }
    if (-not (Test-Path $File)) { throw "File not found: $File" }

    $password   = Read-PasswordOnce "Password for this export"
    $blob       = [IO.File]::ReadAllBytes($File)
    $plainBytes = Unprotect-WithPassword $blob $password
    $payload    = [Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json

    $targetName = if ($OverrideName) { $OverrideName } else { $payload.profileName }
    Test-ProfileName $targetName

    $dir = Get-ProfileDir $targetName
    if (Test-Path (Join-Path $dir 'credential.dpapi')) {
        if (-not (Confirm-Action "Profile '$targetName' already exists. Overwrite?")) {
            Write-Host 'Cancelled.'; return
        }
    }
    New-Item -ItemType Directory -Force $dir | Out-Null

    $credJson = @{
        userName = $payload.userName
        comment  = $payload.comment
        persist  = $payload.persist
        blobB64  = $payload.blobB64
    } | ConvertTo-Json
    Protect-JsonToFile $credJson (Join-Path $dir 'credential.dpapi')

    if ($payload.files) {
        foreach ($prop in $payload.files.PSObject.Properties) {
            $dst = Join-Path $dir "files\$($prop.Name)"
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            [IO.File]::WriteAllBytes($dst, [Convert]::FromBase64String($prop.Value))
        }
    }

    $credForMeta = [PSCustomObject]@{
        UserName = $payload.userName
        Blob     = [Convert]::FromBase64String($payload.blobB64)
    }
    Write-ProfileMeta $dir $targetName $credForMeta

    Write-Host "Imported profile '$targetName' from: $File" -ForegroundColor Green
    Write-Host "This does not change your current login. Switch to it with: agy-profile switch $targetName"
}

function Invoke-Help {
    Write-Host @"
agy-profile - Account (profile) manager for the Antigravity CLI

Usage:  agy-profile <command> [name] [path] [-Force] [-Password <pwd>]

  save <name>          Save the logged-in account as profile <name>
  switch <name>        Switch to the account of profile <name>
  next                 Switch to the next profile (round-robin, A-Z order)
  random               Switch to a random profile other than the current one
  list                 List saved profiles
  current              Show which profile is active
  delete <name>        Delete the saved copy of a profile
  export <name> [file] Export a profile to a password-protected .agyprofile file
                        (default file: .\<name>.agyprofile in the current folder)
  import <file> [name] Import a profile from a .agyprofile file
                        (default name: the one it was exported with)
  logout               Log out (deletes the credential; auto-backup if unsaved)
  help                 Show this help

  -Force               Skip confirmations and the running-agy check
  -Password <pwd>      Non-interactive password for export/import (avoid when
                        possible - it can leak via shell history / process list)

First-time setup with 2 accounts:
  agy-profile save personal      # account 1 is currently logged in
  agy-profile logout
  agy                            # log in with account 2 inside agy
  agy-profile save work
  agy-profile switch personal    # from now on, switching is one command

Move a profile to another machine:
  agy-profile export work work.agyprofile   # prompts for a password
  # copy work.agyprofile to the other machine, then:
  agy-profile import work.agyprofile
"@
}

# --- Dispatch ----------------------------------------------------------------

try {
    New-Item -ItemType Directory -Force $PROFILES_DIR | Out-Null
    switch ($Command.ToLowerInvariant()) {
        'save'    { Invoke-Save }
        'switch'  { Invoke-Switch }
        'next'    { Invoke-Next }
        'random'  { Invoke-Random }
        'list'    { Invoke-List }
        'current' { Invoke-Current }
        'delete'  { Invoke-Delete }
        'export'  { Invoke-Export }
        'import'  { Invoke-Import }
        'logout'  { Invoke-Logout }
        'help'    { Invoke-Help }
        default   { Write-Host "Unknown command: '$Command'`n"; Invoke-Help; exit 1 }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
