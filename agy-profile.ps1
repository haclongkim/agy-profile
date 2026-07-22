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
    [switch]$Force
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

function Protect-ToFile($cred, [string]$path) {
    $json  = @{
        userName = $cred.UserName
        comment  = $cred.Comment
        persist  = $cred.Persist
        blobB64  = [Convert]::ToBase64String($cred.Blob)
    } | ConvertTo-Json
    $plain = [Text.Encoding]::UTF8.GetBytes($json)
    $enc   = [Security.Cryptography.ProtectedData]::Protect($plain, $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($path, $enc)
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

function Invoke-Help {
    Write-Host @"
agy-profile - Account (profile) manager for the Antigravity CLI

Usage:  agy-profile <command> [name] [-Force]

  save <name>     Save the logged-in account as profile <name>
  switch <name>   Switch to the account of profile <name>
  next            Switch to the next profile (round-robin, A-Z order)
  random          Switch to a random profile other than the current one
  list            List saved profiles
  current         Show which profile is active
  delete <name>   Delete the saved copy of a profile
  logout          Log out (deletes the credential; auto-backup if unsaved)
  help            Show this help

  -Force          Skip confirmations and the running-agy check

First-time setup with 2 accounts:
  agy-profile save personal      # account 1 is currently logged in
  agy-profile logout
  agy                            # log in with account 2 inside agy
  agy-profile save work
  agy-profile switch personal    # from now on, switching is one command
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
        'logout'  { Invoke-Logout }
        'help'    { Invoke-Help }
        default   { Write-Host "Unknown command: '$Command'`n"; Invoke-Help; exit 1 }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
