<#
.SYNOPSIS
  agy-profile — Quản lý tài khoản (profile) cho Antigravity CLI (agy.exe)

.DESCRIPTION
  Lưu và chuyển đổi nhanh tài khoản đăng nhập của Antigravity CLI.
  Token đăng nhập của agy nằm trong Windows Credential Manager
  (target: gemini:antigravity). Script này đọc/ghi credential đó,
  lưu bản sao mã hóa DPAPI trên đĩa cho từng profile.
  Mọi dữ liệu khác (settings, knowledge, skills, MCP config...) dùng chung.

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

# ─── Cấu hình ────────────────────────────────────────────────────────────────
$CRED_TARGET       = 'gemini:antigravity'
$CLI_DIR           = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
$PROFILES_DIR      = Join-Path $env:USERPROFILE '.gemini\agy-profiles'
$ACTIVE_FILE       = Join-Path $PROFILES_DIR '_active.txt'
# File gắn với tài khoản, được backup/restore theo từng profile
$PER_PROFILE_FILES = @('cache\default_project_id.txt')

Add-Type -AssemblyName System.Security

# ─── P/Invoke: Windows Credential Manager ────────────────────────────────────
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

# ─── Helper ──────────────────────────────────────────────────────────────────

function Test-ProfileName([string]$n) {
    if (-not $n) { throw "Thiếu tên profile. Dùng: agy-profile $Command <tên>" }
    if ($n -notmatch '^[a-zA-Z0-9_-]+$') {
        throw "Tên profile chỉ được chứa chữ không dấu, số, '-' và '_'."
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

# Profile người dùng đặt tên (bỏ qua thư mục _unsaved-*, _active.txt...)
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
        throw "Không giải mã được '$path'. File DPAPI chỉ dùng được bởi đúng user Windows đã tạo ra nó."
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

# Nếu credential hiện tại chưa khớp profile nào đã lưu (kể cả _unsaved-*) → tự backup
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
    Write-Warning "Tài khoản đang đăng nhập chưa được save — đã tự backup vào: $dir"
    Write-Warning "Khôi phục lại bằng cách đổi tên thư mục đó (bỏ tiền tố '_') rồi: agy-profile switch <tên>"
}

function Confirm-Action([string]$question) {
    if ($Force) { return $true }
    $ans = Read-Host "$question (y/N)"
    return ($ans -match '^[yY]')
}

# ─── Lệnh ────────────────────────────────────────────────────────────────────

function Invoke-Save {
    Test-ProfileName $Name
    $cred = Get-CurrentCred
    if ($null -eq $cred -or $cred.Blob.Length -eq 0) {
        throw "Không tìm thấy credential '$CRED_TARGET'. Hãy đăng nhập agy trước, rồi mới save."
    }
    $dir = Get-ProfileDir $Name
    if (Test-Path (Join-Path $dir 'credential.dpapi')) {
        if (-not (Confirm-Action "Profile '$Name' đã tồn tại. Ghi đè?")) {
            Write-Host 'Đã hủy.'; return
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
    Write-Host "Đã lưu tài khoản hiện tại thành profile '$Name'." -ForegroundColor Green
}

function Invoke-Switch {
    param([string]$TargetName = $Name)
    Test-ProfileName $TargetName
    $dir      = Get-ProfileDir $TargetName
    $credFile = Join-Path $dir 'credential.dpapi'
    if (-not (Test-Path $credFile)) {
        throw "Profile '$TargetName' không tồn tại. Xem danh sách: agy-profile list"
    }

    if (-not $Force) {
        $proc = @(Get-Process -Name agy -ErrorAction SilentlyContinue)
        if ($proc.Count -gt 0) {
            throw "agy đang chạy (PID: $(($proc | ForEach-Object Id) -join ', ')). Đóng agy trước khi switch, hoặc thêm -Force."
        }
    }

    $target  = Read-ProfileMeta $dir
    $current = Get-CurrentCred
    if ($current -and $target -and (Get-BlobHash $current.Blob) -eq $target.blobSha256 -and -not $Force) {
        Write-Host "Đang ở profile '$TargetName' rồi — không cần chuyển."
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
            Remove-Item $dst -Force   # tránh dùng nhầm project id của tài khoản khác
        }
    }

    Set-Content -Encoding ASCII $ACTIVE_FILE $TargetName
    $who = if ($data.userName) { " ($($data.userName))" } else { '' }
    Write-Host "Đã chuyển sang profile '$TargetName'$who." -ForegroundColor Green
}

# Tên profile đang active: ưu tiên so hash credential thực tế, fallback _active.txt
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
        throw "Chưa có profile nào. Lưu tài khoản đang đăng nhập bằng: agy-profile save <tên>"
    }
    $names   = @($profiles | ForEach-Object Name)
    $idx     = [array]::IndexOf($names, [string](Get-ActiveProfileName))
    $nextIdx = ($idx + 1) % $names.Count           # idx = -1 (không rõ active) → về profile đầu
    Write-Host "next → '$($names[$nextIdx])' ($($nextIdx + 1)/$($names.Count) theo thứ tự A-Z)"
    Invoke-Switch $names[$nextIdx]
}

function Invoke-Random {
    $profiles = @(Get-SavedProfiles | Sort-Object Name)
    if ($profiles.Count -eq 0) {
        throw "Chưa có profile nào. Lưu tài khoản đang đăng nhập bằng: agy-profile save <tên>"
    }
    $active     = Get-ActiveProfileName
    $candidates = @($profiles | Where-Object { $_.Name -ne $active })
    if ($candidates.Count -eq 0) {
        Write-Host "Chỉ có duy nhất profile '$active' — không có profile khác để chuyển ngẫu nhiên."
        return
    }
    $pick = ($candidates | Get-Random).Name
    Write-Host "random → '$pick' (chọn từ $($candidates.Count) profile khác profile hiện tại)"
    Invoke-Switch $pick
}

function Invoke-List {
    $profiles = Get-SavedProfiles
    if ($profiles.Count -eq 0) {
        Write-Host "Chưa có profile nào. Lưu tài khoản đang đăng nhập bằng: agy-profile save <tên>"
        return
    }
    $cred    = Get-CurrentCred
    $curHash = if ($cred) { Get-BlobHash $cred.Blob } else { $null }
    Write-Host "Profile đã lưu ('*' = trùng tài khoản đang đăng nhập):"
    foreach ($p in $profiles) {
        $meta = Read-ProfileMeta $p.FullName
        $mark = if ($meta -and $meta.blobSha256 -eq $curHash) { '*' } else { ' ' }
        "  {0} {1,-20} {2}" -f $mark, $p.Name, $meta.savedAt
    }
    if (-not $cred) {
        Write-Warning "Hiện chưa đăng nhập tài khoản nào (credential '$CRED_TARGET' không tồn tại)."
    }
}

function Invoke-Current {
    $cred = Get-CurrentCred
    if (-not $cred) {
        Write-Host "Chưa đăng nhập (không có credential '$CRED_TARGET')."
        return
    }
    $hash  = Get-BlobHash $cred.Blob
    $match = $null
    foreach ($p in Get-SavedProfiles) {
        $meta = Read-ProfileMeta $p.FullName
        if ($meta -and $meta.blobSha256 -eq $hash) { $match = $meta; break }
    }
    if ($match) {
        Write-Host "Profile đang active: $($match.name)" -ForegroundColor Green
    } else {
        $active = if (Test-Path $ACTIVE_FILE) { (Get-Content $ACTIVE_FILE).Trim() } else { '(chưa ghi nhận)' }
        Write-Warning "Đang đăng nhập một tài khoản CHƯA khớp profile nào đã lưu (lần switch cuối: $active)."
        Write-Warning "Nếu đây là tài khoản mới hoặc token vừa được refresh, hãy chạy: agy-profile save <tên>"
    }
}

function Invoke-Delete {
    Test-ProfileName $Name
    $dir = Get-ProfileDir $Name
    if (-not (Test-Path $dir)) { throw "Profile '$Name' không tồn tại." }
    if (-not (Confirm-Action "Xóa bản lưu của profile '$Name'? (tài khoản đang đăng nhập không bị ảnh hưởng)")) {
        Write-Host 'Đã hủy.'; return
    }
    Remove-Item $dir -Recurse -Force
    if ((Test-Path $ACTIVE_FILE) -and ((Get-Content $ACTIVE_FILE).Trim() -eq $Name)) {
        Remove-Item $ACTIVE_FILE -Force
    }
    Write-Host "Đã xóa profile '$Name'." -ForegroundColor Green
}

function Invoke-Logout {
    $cred = Get-CurrentCred
    if (-not $cred) { Write-Host 'Không có credential nào để xóa.'; return }
    if (-not (Confirm-Action "Xóa credential hiện tại? Lần chạy agy tới sẽ phải đăng nhập lại.")) {
        Write-Host 'Đã hủy.'; return
    }
    Backup-IfUnsaved $cred
    [CredMan]::Delete($CRED_TARGET) | Out-Null
    if (Test-Path $ACTIVE_FILE) { Remove-Item $ACTIVE_FILE -Force }
    Write-Host "Đã đăng xuất. Chạy 'agy' để đăng nhập tài khoản khác, rồi 'agy-profile save <tên>' để lưu." -ForegroundColor Green
}

function Invoke-Help {
    Write-Host @"
agy-profile - Quản lý tài khoản (profile) cho Antigravity CLI

Cách dùng:  agy-profile <lệnh> [tên] [-Force]

  save <tên>      Lưu tài khoản đang đăng nhập thành profile <tên>
  switch <tên>    Chuyển sang tài khoản của profile <tên>
  next            Chuyển sang profile kế tiếp (vòng tròn, theo thứ tự A-Z)
  random          Chuyển ngẫu nhiên sang một profile khác profile hiện tại
  list            Liệt kê profile đã lưu
  current         Cho biết đang ở profile nào
  delete <tên>    Xóa bản lưu của một profile
  logout          Đăng xuất (xóa credential hiện tại, có tự backup nếu chưa save)
  help            Hướng dẫn này

  -Force          Bỏ qua xác nhận và kiểm tra agy đang chạy

Thiết lập lần đầu với 2 tài khoản:
  agy-profile save personal      # đang đăng nhập tài khoản 1
  agy-profile logout
  agy                            # đăng nhập tài khoản 2 trong agy
  agy-profile save work
  agy-profile switch personal    # từ nay chuyển qua lại chỉ 1 lệnh
"@
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

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
        default   { Write-Host "Lệnh không hợp lệ: '$Command'`n"; Invoke-Help; exit 1 }
    }
} catch {
    Write-Host "LỖI: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
