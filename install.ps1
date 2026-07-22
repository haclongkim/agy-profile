<#
.SYNOPSIS
  Install / uninstall agy-profile on Windows.

.DESCRIPTION
  - Copies agy-profile.cmd + agy-profile.ps1 into the install directory
    (default: %LOCALAPPDATA%\agy-profile)
  - Asks which shells to set it up for (CMD, PowerShell, Git Bash) and wires
    up each one:
      * CMD / PowerShell share the same Windows user PATH, so either choice
        adds the install directory there (no Administrator rights needed).
      * Git Bash cannot resolve a bare command name to a .cmd file, so a
        small POSIX shim (`agy-profile`, no extension) is written next to
        the .cmd file, and a managed block is added to ~/.bashrc to put the
        install directory on bash's PATH.
  - The shell selection is remembered in the install directory, so running
    the installer again (e.g. after `git pull`, to update) reapplies the
    same setup without re-prompting.
  - Run again to update to a newer version (overwrites old files).

.EXAMPLE
  .\install.cmd                              # prompts for which shells to set up
  .\install.cmd -Shells cmd,powershell,bash  # non-interactive
  .\install.cmd -Dir D:\tools\agyp           # install to a custom directory
  .\install.cmd -Uninstall                   # uninstall
#>
[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'agy-profile'),
    [switch]$Uninstall,
    # Comma-separated: cmd, powershell, bash. Skips the interactive prompt.
    [string]$Shells
)

$ErrorActionPreference = 'Stop'
$FILES         = @('agy-profile.cmd', 'agy-profile.ps1')
$SHELLS_MARKER = 'shells.txt'
$BASHRC        = Join-Path $env:USERPROFILE '.bashrc'
# Git Bash's default shortcut runs a LOGIN shell, which reads ~/.bash_profile
# (NOT ~/.bashrc) on startup. A plain `bash` / non-login shell (e.g. most
# terminal integrations) reads ~/.bashrc instead. To work in both cases we
# put the real PATH export in ~/.bashrc and make sure ~/.bash_profile sources
# it - the same fix Git for Windows itself offers interactively when it
# detects this exact situation.
$BASH_PROFILE  = Join-Path $env:USERPROFILE '.bash_profile'
$BASH_BEGIN    = '# >>> agy-profile PATH (managed, do not edit by hand) >>>'
$BASH_END      = '# <<< agy-profile PATH (managed) <<<'

# --- PATH helpers (CMD / PowerShell share the Windows user PATH) -------------

function Get-UserPathParts {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($cur) { @($cur -split ';' | Where-Object { $_ -and $_.Trim() }) } else { @() }
}

function Set-UserPath([string[]]$parts) {
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

# --- Git Bash detection & helpers ---------------------------------------------

function Find-GitBash {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*WindowsApps*' } | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

function Convert-ToPosixPath([string]$winPath) {
    $p = $winPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') {
        return "/$($Matches[1].ToLowerInvariant())$($Matches[2])"
    }
    return $p
}

# Writes text with LF-only line endings (CRLF in a shebang / bashrc export can
# confuse strict POSIX shells such as WSL's, even though Git Bash tolerates it).
function Write-LfFile([string]$path, [string[]]$lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"))
}

function Install-BashShim {
    $shimPath = Join-Path $Dir 'agy-profile'
    Write-LfFile $shimPath @(
        '#!/bin/sh'
        '# Bare-name shim so `agy-profile` works in bash - it cannot resolve .cmd on its own.'
        'DIR="$(cd "$(dirname "$0")" && pwd)"'
        'exec "$DIR/agy-profile.cmd" "$@"'
    )
}

function Get-RawFileContent([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    $c = Get-Content $path -Raw   # -Raw returns $null for a 0-byte file
    if ($null -eq $c) { '' } else { $c }
}

function Get-ManagedBlockPattern([switch]$LeadingNewline) {
    $prefix = if ($LeadingNewline) { '\r?\n?' } else { '' }
    "(?ms)$prefix^$([regex]::Escape($BASH_BEGIN)).*?^$([regex]::Escape($BASH_END))\r?\n?"
}

# Idempotently inserts/replaces our marker-delimited block at the end of $path,
# creating the file if needed and leaving any of the user's own content intact.
function Install-ManagedBlock([string]$path, [string[]]$blockLines) {
    $cleaned = [regex]::Replace((Get-RawFileContent $path), (Get-ManagedBlockPattern), '')
    $cleaned = $cleaned.TrimEnd("`r", "`n")

    $newContent = if ($cleaned) { $cleaned + "`n`n" + ($blockLines -join "`n") + "`n" } else { ($blockLines -join "`n") + "`n" }
    [IO.File]::WriteAllText($path, $newContent)
}

function Remove-ManagedBlock([string]$path) {
    if (-not (Test-Path $path)) { return }
    $cleaned = [regex]::Replace((Get-RawFileContent $path), (Get-ManagedBlockPattern -LeadingNewline), "`n")
    [IO.File]::WriteAllText($path, $cleaned.TrimStart("`n"))
}

function Install-BashRcBlock {
    $posixDir = Convert-ToPosixPath $Dir
    Install-ManagedBlock $BASHRC @($BASH_BEGIN, "export PATH=`"`$PATH:$posixDir`"", $BASH_END)
    # ~/.bash_profile (read by LOGIN shells, e.g. Git Bash's default shortcut)
    # just needs to pull in ~/.bashrc - same fix Git for Windows itself suggests.
    Install-ManagedBlock $BASH_PROFILE @($BASH_BEGIN, 'test -f ~/.bashrc && . ~/.bashrc', $BASH_END)
}

function Remove-BashRcBlock {
    Remove-ManagedBlock $BASHRC
    Remove-ManagedBlock $BASH_PROFILE
}

# --- Shell selection -----------------------------------------------------------

function Read-ShellSelection([string]$gitBashPath) {
    $markerPath = Join-Path $Dir $SHELLS_MARKER
    if ($Shells) {
        return @($Shells -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    if (Test-Path $markerPath) {
        $prev = @(Get-Content $markerPath | Where-Object { $_.Trim() })
        Write-Host "Using the previously selected shells: $($prev -join ', ') (pass -Shells to change)."
        return $prev
    }

    Write-Host ''
    Write-Host 'Which shells should agy-profile be set up for?'
    Write-Host '  [1] CMD'
    Write-Host '  [2] PowerShell'
    if ($gitBashPath) {
        Write-Host '  [3] Git Bash (detected)'
    } else {
        Write-Host '  [3] Git Bash (not detected on this machine)'
    }
    $reply = Read-Host 'Enter numbers separated by commas, or press Enter for all detected shells'

    if (-not $reply -or $reply.Trim() -eq '') {
        $sel = @('cmd', 'powershell')
        if ($gitBashPath) { $sel += 'bash' }
        return $sel
    }
    if ($reply.Trim() -match '^(a|all)$') { return @('cmd', 'powershell', 'bash') }

    $map = @{ '1' = 'cmd'; '2' = 'powershell'; '3' = 'bash' }
    $sel = @($reply -split ',' | ForEach-Object { $map[$_.Trim()] } | Where-Object { $_ })
    if ($sel.Count -eq 0) {
        Write-Warning "Could not parse '$reply' - defaulting to CMD + PowerShell."
        return @('cmd', 'powershell')
    }
    return $sel
}

# --- Main ------------------------------------------------------------------

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
        Remove-BashRcBlock
        Write-Host "Removed the agy-profile block from ~/.bashrc and ~/.bash_profile (if present)." -ForegroundColor Green
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

    # 3. Ask which shells to wire up
    $gitBashPath = Find-GitBash
    $selection   = @(Read-ShellSelection $gitBashPath)
    Set-Content -Encoding ASCII (Join-Path $Dir $SHELLS_MARKER) $selection

    # 4. CMD / PowerShell: both read the same Windows user PATH
    if ($selection -contains 'cmd' -or $selection -contains 'powershell') {
        $parts = Get-UserPathParts
        if ($parts -notcontains $Dir) {
            Set-UserPath ($parts + $Dir)
            Write-Host "Added '$Dir' to the user PATH (used by CMD and PowerShell)." -ForegroundColor Green
        } else {
            Write-Host "PATH already contains '$Dir' - skipping the PATH step."
        }
        # Make it usable in the current session without opening a new terminal
        if (($env:Path -split ';') -notcontains $Dir) { $env:Path += ";$Dir" }
    } else {
        $parts = Get-UserPathParts
        if ($parts -contains $Dir) {
            Set-UserPath ($parts | Where-Object { $_ -ne $Dir })
            Write-Host "Neither CMD nor PowerShell selected - removed '$Dir' from the user PATH."
        }
    }

    # 5. Git Bash: bare-name shim + ~/.bashrc PATH block
    if ($selection -contains 'bash') {
        if (-not $gitBashPath) {
            Write-Warning "Git Bash was not detected, but setting it up anyway. Install Git for Windows if you plan to use it: https://git-scm.com/download/win"
        }
        Install-BashShim
        Install-BashRcBlock
        Write-Host "Set up Git Bash: shim in '$Dir', PATH block in $BASHRC and $BASH_PROFILE" -ForegroundColor Green
    } else {
        $shimPath = Join-Path $Dir 'agy-profile'
        if (Test-Path $shimPath) { Remove-Item $shimPath -Force }
        Remove-BashRcBlock
    }

    # 6. Environment check
    if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
        Write-Warning "'agy' was not found in PATH. agy-profile requires the Antigravity CLI to be installed."
    }

    Write-Host ''
    Write-Host 'Installation complete!' -ForegroundColor Green
    Write-Host 'Open a NEW terminal for your selected shell(s) (to reload PATH) and try:'
    Write-Host ''
    Write-Host '    agy-profile help'
    Write-Host ''
    Write-Host 'Set up your first profile with:  agy-profile save <name>'
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
