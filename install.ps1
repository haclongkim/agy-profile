<#
.SYNOPSIS
  Cài đặt / gỡ cài đặt agy-profile trên Windows.

.DESCRIPTION
  - Copy agy-profile.cmd + agy-profile.ps1 vào thư mục cài đặt
    (mặc định: %LOCALAPPDATA%\agy-profile)
  - Thêm thư mục đó vào PATH của user (không cần quyền Admin)
  - Chạy lại để cập nhật phiên bản mới (ghi đè file cũ)

.EXAMPLE
  .\install.cmd                        # cài đặt mặc định
  .\install.cmd -Dir D:\tools\agyp     # cài vào thư mục tùy chọn
  .\install.cmd -Uninstall             # gỡ cài đặt
#>
[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'agy-profile'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$FILES = @('agy-profile.cmd', 'agy-profile.ps1')

function Get-UserPathParts {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($cur) { @($cur -split ';' | Where-Object { $_ -and $_.Trim() }) } else { @() }
}

function Set-UserPath([string[]]$parts) {
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

try {
    if ($Uninstall) {
        # ── Gỡ cài đặt ──
        if (Test-Path $Dir) {
            Remove-Item $Dir -Recurse -Force
            Write-Host "Đã xóa thư mục: $Dir" -ForegroundColor Green
        } else {
            Write-Host "Thư mục $Dir không tồn tại — bỏ qua."
        }
        $parts = Get-UserPathParts
        if ($parts -contains $Dir) {
            Set-UserPath ($parts | Where-Object { $_ -ne $Dir })
            Write-Host "Đã gỡ '$Dir' khỏi PATH của user." -ForegroundColor Green
        }
        Write-Host ''
        Write-Host 'Đã gỡ cài đặt agy-profile.'
        Write-Host 'Lưu ý: các profile đã lưu tại %USERPROFILE%\.gemini\agy-profiles KHÔNG bị xóa.'
        Write-Host 'Nếu không cần nữa, xóa tay thư mục đó (sẽ mất các tài khoản đã save).'
        exit 0
    }

    # ── Cài đặt ──
    # 1. Kiểm tra file nguồn nằm cạnh installer
    foreach ($f in $FILES) {
        if (-not (Test-Path (Join-Path $PSScriptRoot $f))) {
            throw "Không tìm thấy '$f' cạnh installer. Hãy chạy install.cmd từ thư mục repo đã clone/giải nén đầy đủ."
        }
    }

    # 2. Copy file vào thư mục cài đặt
    New-Item -ItemType Directory -Force $Dir | Out-Null
    foreach ($f in $FILES) {
        Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $Dir $f) -Force
    }
    Write-Host "Đã copy $($FILES.Count) file vào: $Dir" -ForegroundColor Green

    # 3. Thêm vào PATH của user nếu chưa có
    $parts = Get-UserPathParts
    if ($parts -notcontains $Dir) {
        Set-UserPath ($parts + $Dir)
        Write-Host "Đã thêm '$Dir' vào PATH của user." -ForegroundColor Green
    } else {
        Write-Host "PATH đã chứa '$Dir' — bỏ qua bước thêm PATH."
    }
    # Cho phiên hiện tại dùng được ngay, không cần mở terminal mới
    if (($env:Path -split ';') -notcontains $Dir) { $env:Path += ";$Dir" }

    # 4. Kiểm tra môi trường
    if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
        Write-Warning "Không tìm thấy 'agy' trong PATH. agy-profile cần Antigravity CLI đã được cài đặt."
    }

    Write-Host ''
    Write-Host 'Cài đặt hoàn tất!' -ForegroundColor Green
    Write-Host 'Mở terminal MỚI (để nạp PATH) rồi thử:'
    Write-Host ''
    Write-Host '    agy-profile help'
    Write-Host ''
    Write-Host 'Thiết lập profile đầu tiên:  agy-profile save <tên>'
} catch {
    Write-Host "LỖI: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
