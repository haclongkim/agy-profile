<#
.SYNOPSIS
  Install / uninstall agy-profile on Windows.

.DESCRIPTION
  - Copies agy-profile.cmd + agy-profile.ps1 into the install directory
    (default: %LOCALAPPDATA%\agy-profile)
  - Adds that directory to the user's PATH (no Administrator rights needed)
  - Run again to update to a newer version (overwrites old files)

.EXAMPLE
  .\install.cmd                        # default install
  .\install.cmd -Dir D:\tools\agyp     # install to a custom directory
  .\install.cmd -Uninstall             # uninstall
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
        # --- Uninstall ---
        if (Test-Path $Dir) {
            Remove-Item $Dir -Recurse -Force
            Write-Host "Removed directory: $Dir" -ForegroundColor Green
        } else {
            Write-Host "Directory $Dir does not exist - skipping."
        }
        $parts = Get-UserPathParts
        if ($parts -contains $Dir) {
            Set-UserPath ($parts | Where-Object { $_ -ne $Dir })
            Write-Host "Removed '$Dir' from the user PATH." -ForegroundColor Green
        }
        Write-Host ''
        Write-Host 'agy-profile has been uninstalled.'
        Write-Host 'Note: saved profiles under %USERPROFILE%\.gemini\agy-profiles are NOT deleted.'
        Write-Host 'If you no longer need them, delete that folder manually (saved accounts will be lost).'
        exit 0
    }

    # --- Install ---
    # 1. Verify source files sit next to the installer
    foreach ($f in $FILES) {
        if (-not (Test-Path (Join-Path $PSScriptRoot $f))) {
            throw "'$f' not found next to the installer. Run install.cmd from the fully cloned/extracted repo folder."
        }
    }

    # 2. Copy files into the install directory
    New-Item -ItemType Directory -Force $Dir | Out-Null
    foreach ($f in $FILES) {
        Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $Dir $f) -Force
    }
    Write-Host "Copied $($FILES.Count) files to: $Dir" -ForegroundColor Green

    # 3. Add to the user PATH if not already present
    $parts = Get-UserPathParts
    if ($parts -notcontains $Dir) {
        Set-UserPath ($parts + $Dir)
        Write-Host "Added '$Dir' to the user PATH." -ForegroundColor Green
    } else {
        Write-Host "PATH already contains '$Dir' - skipping the PATH step."
    }
    # Make it usable in the current session without opening a new terminal
    if (($env:Path -split ';') -notcontains $Dir) { $env:Path += ";$Dir" }

    # 4. Environment check
    if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
        Write-Warning "'agy' was not found in PATH. agy-profile requires the Antigravity CLI to be installed."
    }

    Write-Host ''
    Write-Host 'Installation complete!' -ForegroundColor Green
    Write-Host 'Open a NEW terminal (to reload PATH) and try:'
    Write-Host ''
    Write-Host '    agy-profile help'
    Write-Host ''
    Write-Host 'Set up your first profile with:  agy-profile save <name>'
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
