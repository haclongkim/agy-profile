# agy-profile

[English](README.md) | [Tiếng Việt](README.vn.md)

> **Switch between Google accounts for the Antigravity CLI (`agy`) on Windows with a single command.**

The `agy` CLI has no multi-profile support — changing accounts means logging out and back in
by hand every time. `agy-profile` fixes that: **save an account once, switch with one command**,
while settings, trustedWorkspaces, knowledge, skills, MCP config... all stay shared.

```cmd
agy-profile save personal      # save the currently logged-in account
agy-profile switch work        # switch to another account instantly
```

## How it works

The `agy` login token is not stored in a config file — it lives in
**Windows Credential Manager** (entry `gemini:antigravity`). `agy-profile` reads/writes
that credential through the Win32 API and stores each profile as a **DPAPI-encrypted**
copy under `%USERPROFILE%\.gemini\agy-profiles\<name>\`. Switching profiles swaps exactly
one credential — no folder copying, and nothing else is touched.

Architecture details and design decisions: see [DESIGN.md](DESIGN.md).

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built into Windows) or PowerShell 7+
- [Antigravity CLI](https://antigravity.google/) (`agy`) installed
- **No Administrator rights needed**

## Installation

```powershell
git clone https://github.com/<your-username>/agy-profile.git
cd agy-profile
.\install.cmd
```

The installer copies the tool to `%LOCALAPPDATA%\agy-profile` and adds it to the user `PATH`.
Open a **new** terminal and verify:

```
agy-profile help
```

Other options:

```powershell
.\install.cmd -Dir D:\tools\agy-profile   # install to a custom directory
.\install.cmd -Uninstall                  # uninstall (saved profiles are kept)
```

**Updating:** `git pull`, then run `.\install.cmd` again.

<details>
<summary>Manual installation (without the installer)</summary>

Copy the two files `agy-profile.cmd` + `agy-profile.ps1` into any directory on your
`PATH` (both files must sit in the same folder). The quickest choice is
`%LOCALAPPDATA%\agy\bin` (agy's own folder, already on PATH) — but note that
`agy update` may clean that folder in the future.
</details>

## Getting started (example with 2 accounts)

```cmd
:: The personal account is currently logged in inside agy
agy-profile save personal

:: Log out, then log in with the work account
agy-profile logout
agy                          &:: agy will ask you to log in -> use the work account
agy-profile save work

:: From now on, switching takes one command
agy-profile switch personal
agy-profile switch work

:: Or rotate / randomize across many profiles
agy-profile next
agy-profile random
```

## Commands

| Command | Description |
|---|---|
| `agy-profile save <name>` | Save the logged-in account as profile `<name>` |
| `agy-profile switch <name>` | Switch to the account of profile `<name>` |
| `agy-profile next` | Switch to the **next** profile (round-robin, A-Z order) |
| `agy-profile random` | Switch to a **random** profile other than the current one |
| `agy-profile list` | List profiles; `*` = matches the logged-in account |
| `agy-profile current` | Show the active profile; warns if the current account was never saved |
| `agy-profile delete <name>` | Delete a saved profile (the logged-in account is not affected) |
| `agy-profile export <name> [file]` | Export a profile to a password-protected, portable file |
| `agy-profile import <file> [name]` | Import a profile from an exported file |
| `agy-profile logout` | Log out — the next `agy` run will ask you to log in again |
| `agy-profile help` | Show help |
| `-Force` flag | Skip confirmations and the running-`agy` check |
| `-Password <pwd>` flag | Non-interactive password for `export`/`import` (prefer the prompt — see below) |

Profile names may only contain letters, digits, `-` and `_`.

### Moving a profile to another machine

`save`/`switch` only ever touch a local copy encrypted with this Windows user's DPAPI
key — by design, that copy is useless on any other machine or account. To back up a
profile or move it elsewhere, use `export`/`import` instead, which re-encrypts the
profile with a **password** you choose instead of DPAPI:

```cmd
agy-profile export work work.agyprofile   :: prompts for a password (typed twice)
:: copy work.agyprofile to the other machine, e.g. via USB drive or a private channel
agy-profile import work.agyprofile        :: prompts for the password, restores the profile
```

- The password is never stored anywhere — if you lose it, the export is unrecoverable.
- Treat `.agyprofile` files as sensitive: anyone with the file **and** the password
  can log in as that account. Don't commit them to a repo or send them over a
  channel you don't trust.
- A wrong password fails closed with a clear error and writes nothing to disk.

## Built-in safety mechanisms

- **DPAPI encryption**: `credential.dpapi` files can only be decrypted by the same
  Windows user on the same machine that created them — copying them elsewhere is
  useless. No plaintext token is ever written to disk.
- **Account-loss protection**: if you `switch`/`logout` while logged in with an
  account that was **never saved**, the script backs it up to `_unsaved-<timestamp>\`
  before overwriting. To restore: rename that folder (drop the `_` prefix), then
  `agy-profile switch <new-name>`.
- **Blocked while `agy` is running**: prevents agy from refreshing a token over
  another profile mid-switch. Use `-Force` if you are sure you want to bypass.
- **State-drift detection**: `current`/`list` compare the SHA-256 hash of the real
  credential against saved copies — if you logged in manually outside the script,
  you get a warning telling you to `save` again.

## FAQ

**`current` warns "matches NO saved profile" even though I did not change accounts?**
`agy` may have refreshed the token on its own (credential contents changed → hash changed).
Run `agy-profile save <current-name> -Force` to update the saved copy.

**Is conversation history separated per profile?**
No — by design, conversation/knowledge data is shared across profiles.
Conversations from another account still show up in the list, but the server will
refuse to resume them unless they belong to the logged-in account. To separate them:
see section 5.4 in [DESIGN.md](DESIGN.md).

**Is `export`/`import` the same encryption as the local `.dpapi` files?**
No, and intentionally so. Local saves use DPAPI, which is tied to this Windows user
and machine and cannot be moved. Exports use a password-derived key (PBKDF2 + AES-256
+ HMAC-SHA256) instead, so the resulting `.agyprofile` file is portable — see section
5.3 in [DESIGN.md](DESIGN.md) for the exact construction.

**Does this work for the Antigravity IDE?**
No. This tool only manages the **CLI** (`agy.exe`) login. The IDE keeps its own state.

**What if a new `agy` version changes how the token is stored?**
The credential target is a constant at the top of `agy-profile.ps1` (`$CRED_TARGET`) —
if Google renames the credential entry, it is a one-line fix. The `current` command is
where you would notice first ("credential not found").

## Repository layout

```
agy-profile/
├── agy-profile.cmd   # entry point — run `agy-profile ...` from CMD/PowerShell
├── agy-profile.ps1   # all the logic (CredRead/CredWrite, DPAPI, hash guard)
├── install.cmd       # installer — copies to %LOCALAPPDATA%\agy-profile + PATH
├── install.ps1       # installer logic (supports -Dir, -Uninstall)
├── DESIGN.md         # design doc & investigation of agy's storage mechanism
├── README.md         # this file (English)
└── README.vn.md      # Vietnamese README
```

## Disclaimer

Personal project, not affiliated with Google. The Antigravity CLI's credential storage
mechanism may change in future versions. Tested on Windows 11 + Windows PowerShell 5.1
(July 2026). Use with your own accounts only.
