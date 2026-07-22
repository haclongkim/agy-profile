# Design: `agy-profile` — Account (profile) switcher for the Antigravity CLI

> Design document for a Windows script pair (`agy-profile.cmd` + `agy-profile.ps1`)
> that saves and quickly switches the **login account** of the Antigravity CLI
> (`agy.exe`), while **keeping all other data** (settings, knowledge, skills,
> MCP config...) shared between accounts.

---

## 1. Field investigation (performed on a real machine, 2026-07-22)

### 1.1 Where the CLI state lives

```
%USERPROFILE%\.gemini\
├── antigravity-cli\              <- * state folder of agy.exe (the CLI)
│   ├── settings.json             <- theme, trustedWorkspaces        -> SHARED
│   ├── jetski_state.pbtxt        <- onboarding, migrations (does NOT hold tokens)
│   ├── installation_id           <- machine id                      -> SHARED
│   ├── conversation_summaries.db <- conversation index              (see 5.3)
│   ├── cache\
│   │   ├── default_project_id.txt     <- account-bound              -> PER PROFILE
│   │   ├── conversation_metadata.json <- conversation metadata      (see 5.3)
│   │   └── onboarding.json
│   ├── conversations\  brain\  knowledge\  builtin\skills\  ...    -> SHARED
├── antigravity\                  <- IDE-agent side state (NOT touched)
├── antigravity-ide\              <- IDE state (NOT touched)
└── config\                       <- shared infrastructure (NOT touched)
```

### 1.2 Where the login lives — the key finding

The login token is **not in any file** under `.gemini`. It lives in
**Windows Credential Manager**:

```
Target : LegacyGeneric:target=gemini:antigravity
User   : antigravity
Type   : Generic (persistence: Local machine)
```

-> **Changing accounts = swapping this credential blob** (+ a couple of small
account-bound cache files). No folder needs to be copied or moved at all.

## 2. Requirements

- **Switch only the login identity.** Everything else — settings, trustedWorkspaces,
  knowledge, skills, MCP config, brain — is shared across profiles.
- One command to save the current account, one to switch: `agy-profile save work`,
  `agy-profile switch personal`
- No Administrator rights, no modification of `agy.exe`
- Tokens stored on disk must be **DPAPI-encrypted** (only the current user on this
  machine can decrypt them)

**Out of scope:** profiles for the Antigravity IDE; syncing profiles across machines
(DPAPI intentionally prevents this).

## 3. Core mechanism: swapping the Credential Manager entry

```
                    +------------------------------------------+
                    |  Windows Credential Manager               |
   switch work ---> |  gemini:antigravity  = <blob of "work">   | <-- read by agy.exe
                    +------------------------------------------+
                                      ^
                                      | CredWrite (overwrite)
        %USERPROFILE%\.gemini\agy-profiles\
        ├── _active.txt
        ├── work\
        │   ├── credential.dpapi        <- CredRead blob, DPAPI-encrypted
        │   └── default_project_id.txt  <- copy of the account-bound cache file
        └── personal\
            ├── credential.dpapi
            └── default_project_id.txt
```

- **`save <name>`**: `CredRead("gemini:antigravity")` -> DPAPI-encrypt
  (`ProtectedData.Protect`, scope `CurrentUser`) -> write `credential.dpapi`;
  also back up that account's `cache\default_project_id.txt`.
- **`switch <name>`**: decrypt `credential.dpapi` -> `CredWrite` overwrites
  `gemini:antigravity`; copy back `default_project_id.txt`; update `_active.txt`.
- Shared files are **never touched** — matching the "keep everything else" requirement.

### Why not junction-swap the whole state folder (the earlier design)?

The first draft proposed junction-swapping the entire state directory. Rejected
because: (1) the token is not inside the folder, so swapping the folder **cannot
change the account**; (2) it contradicts the requirement to share settings/knowledge;
(3) it is far more complex and riskier than swapping a single credential.

## 4. Command-line interface

```
agy-profile <command> [args]

  save <name>       Save the currently logged-in account as profile <name>
                    (overwrites if it exists, with confirmation)
  switch <name>     Switch to the account of profile <name>
  next              Switch to the next profile (round-robin, A-Z order)
  random            Switch to a random profile other than the current one
  list              List profiles, marking (*) the active one
  current           Name of the active profile (+ warning if the real credential
                    was changed outside the script, see 5.2)
  delete <name>     Delete a saved profile (does not affect the logged-in account)
  logout            Delete the current credential (CredDelete) -> agy returns to
                    a logged-out state
  help              Usage help
```

### First-time setup flow

```cmd
:: personal account currently logged in
agy-profile save personal

:: log in with the work account: delete the old cred, then log in again inside agy
agy-profile logout
agy                          :: -> agy asks for login -> use the work account
agy-profile save work

:: from now on, switching back and forth is a single command
agy-profile switch personal
agy-profile switch work
```

## 5. Technical design

### 5.1 File layout: `.cmd` wrapper + `.ps1` core

Plain CMD **cannot call** the `CredRead`/`CredWrite`/DPAPI APIs, so the tool is split
into two files kept in the same folder:

- **`agy-profile.cmd`** — user-facing entry point, does exactly one thing:
  ```bat
  @echo off
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-profile.ps1" %*
  ```
- **`agy-profile.ps1`** — all the logic (~300 lines):
  - `Add-Type` P/Invoke block for `advapi32.dll`: `CredRead`, `CredWrite`,
    `CredDelete`, `CredFree` (standard pattern, ~60 lines of inline C#)
  - DPAPI via `[System.Security.Cryptography.ProtectedData]::Protect/Unprotect`
    with scope `CurrentUser`
  - `param($Command, $Name)` + `switch ($Command)` dispatch

Centralized constants at the top of the file:

```powershell
$CRED_TARGET       = 'gemini:antigravity'
$CLI_DIR           = "$env:USERPROFILE\.gemini\antigravity-cli"
$PROFILES_DIR      = "$env:USERPROFILE\.gemini\agy-profiles"
$PER_PROFILE_FILES = @('cache\default_project_id.txt')   # extensible, see 5.3
```

### 5.2 Safety & correctness

| Risk | Mitigation |
|---|---|
| Token readable on disk | Always DPAPI-encrypted with scope `CurrentUser`; `credential.dpapi` is useless if copied to another machine/user |
| Swapping while `agy` is running (it may refresh/rewrite the token mid-session) | Blocked via `Get-Process agy`; override with `-Force` |
| `_active.txt` lying (user manually logged into another account outside the script) | `save` stores a SHA-256 of the blob; `current`/`switch` compare the real blob hash against the active profile -> warn "credential changed, `save` again before switching" |
| `switch` overwriting an account that was never saved | Before overwriting, if the current blob matches no profile's hash -> auto-backup to `_unsaved-<timestamp>\` first |
| Invalid profile names | Whitelist `^[a-zA-Z0-9_-]+$`, blocks path traversal |
| A newer `agy` version renaming the cred target | The target is a single constant; `current` reports a clear "credential not found" instead of a confusing error |

### 5.3 Open question: should conversation data be shared?

`conversations\`, `conversation_summaries.db`, and `cache\conversation_metadata.json`
are local data but **tied to the server-side account**. Sharing them can mix the
conversation lists of two accounts (harmless for local security, but noisy; the
server refuses to resume conversations that don't belong to the logged-in account).

- **v1**: share everything (matches the current requirement), observe real-world behavior.
- **If it gets noisy**: add the three items above to `$PER_PROFILE_FILES` (the
  per-profile backup/restore mechanism already exists — it's one config line,
  no architectural change).

## 6. Test plan (manual)

1. `save personal` -> `credential.dpapi` appears (binary content, no token leak) + hash
2. `logout` -> opening `agy` asks for login again -> log in with account 2 -> `save work`
3. `switch personal` -> open `agy` -> correct account 1, no re-login needed;
   `settings.json`/trustedWorkspaces/knowledge intact
4. `switch work` while `agy` is open -> blocked; passes with `-Force`
5. Manually log in with account 3 (unsaved) -> `switch personal` -> account 3 gets
   auto-backed up to `_unsaved-*` with a warning
6. Copy `credential.dpapi` to another Windows user -> decryption fails (DPAPI by design)
7. `delete work` -> current login unchanged; `list` no longer shows `work`

## 7. Roadmap

| Phase | Content |
|---|---|
| **v1 (MVP)** | `save / switch / list / current / logout` + DPAPI + hash guard + auto-backup of unsaved accounts |
| **v1.1** | `delete`, `next`, `random`, `-Force`, colored output, running-`agy` check |
| **v2** | Optional `-WithConversations` (separate conversation data per profile, see 5.3); `agyp work -- <agy command>` alias to run one command under a given profile and switch back |
| **Watch** | New `agy` versions may change the token storage mechanism (renamed cred target, or a move to files) -> the `current` command is the early-detection point |

---

*The investigation in section 1 was performed directly on a Windows 11 machine on
2026-07-22 with `agy.exe` under `%LOCALAPPDATA%\agy\bin`. The earlier design
(junction-swapping the whole folder) has been replaced — see section 3.*
