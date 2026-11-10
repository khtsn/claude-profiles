# ccp — Claude Code profile switcher

Keep several Claude Code accounts on one Windows machine and switch between them.

Each profile is its own `CLAUDE_CONFIG_DIR`: a separate login, sessions, history,
settings and plugins, stored in `profiles\<name>` next to the script. Nothing is
shared between profiles, and your original `~/.claude` is left alone.

## Requirements

- Windows with PowerShell 5.1 or later (PowerShell 7 works too)
- The `claude` CLI on your PATH
- Optional: Git Bash, if you want `ccp` there as well

## Install

Put this folder wherever you want to keep it, then run once from PowerShell:

```powershell
F:\claude-profiles\ccp.ps1 install
```

This makes `ccp` a command:

- **PowerShell**: adds this folder to your user PATH.
- **Git Bash**: adds a `source ".../ccp.sh"` line to `~/.bashrc` (only if Git or a
  `.bashrc` is present). Open a new Git Bash, or run `source ~/.bashrc`.

It is safe to re-run. cmd.exe is not supported.

To uninstall, remove the folder from your user PATH and delete the `ccp.sh` line
from `~/.bashrc`. If a profile is active, run `ccp use home` first.

## Quick start

```powershell
ccp add work            # create a profile and log in through the browser
ccp add api --key       # create a profile that uses an Anthropic API key
ccp list                # see what you have
ccp use work            # switch to it
claude                  # now runs as "work"
ccp use home            # back to your original ~/.claude
```

## Commands

| Command | What it does |
| --- | --- |
| `ccp install` | Make `ccp` a command in PowerShell and Git Bash |
| `ccp list` | Show profiles; `*` marks the one active in this terminal |
| `ccp add <name>` | Create a profile and log in to it |
| `ccp add <name> --key [key]` | Create a profile that uses an API key instead of a login |
| `ccp use [name]` | Switch this terminal and all new ones; no name means the default |
| `ccp run <name> [args]` | Run `claude` once under a profile without switching |
| `ccp default [name]` | Show or pick the default profile |
| `ccp perm <name> [mode]` | Show or set the profile's permission mode |
| `ccp usage [name]` | Show how much of its subscription limits each profile has used |
| `ccp rename <old> <new>` | Rename a profile |
| `ccp remove <name> [-y]` | Delete a profile and all its data |
| `ccp backup [file] [-p] [--only <name>]` | Save logins and settings to a file |
| `ccp restore <file> [-y] [--only <name>]` | Bring profiles back from a backup |

Running `ccp` with no arguments prints a short version of this table.

## Naming profiles

Wherever a command takes a name you can give:

- the profile name, e.g. `work` or `me@example.com`
- its number from `ccp list`, e.g. `ccp use 2`
- `home`, which is your original `~/.claude`
- `default`, which is whichever profile `ccp default <name>` picked (`home` until
  you pick one)

Names may contain letters, digits, `-`, `_`, and single `.`, `@` or `+` between
them, so email addresses work. `home` and `default` are reserved, and a name
cannot be only digits.

## Switching

`ccp use` sets `CLAUDE_CONFIG_DIR` in the current terminal and as a user
environment variable, so new terminals and apps pick it up. Terminals that were
already open keep the profile they had.

`ccp run` does not switch anything. It runs `claude` once under the named profile
and passes the remaining arguments through:

```powershell
ccp run work -p "summarise this repo"
```

## Usage per account

```
> ccp usage
home   5h  12% (resets Tue 19:00)   week  31% (resets Fri 09:00)
work   5h -                         week  47% (resets Thu 22:59)
api    no subscription login (API-key profile?)
```

`ccp usage` shows every profile; `ccp usage work` shows one. The percentages are
how much of the 5-hour and weekly limits the account has used across all its
devices, with reset times in local time. `-` means no window is open, so nothing
is used.

For scripts, add `--json`. The output is always a one-line array, even for a
single profile:

```json
[{"profile":"work","status":"ok","error":null,
  "five_hour":null,
  "week":{"percent":47,"resets_at":"2026-11-12T15:59:59Z"}}]
```

| Field | Meaning |
| --- | --- |
| `status` | `ok`, `no_login` (API-key profile), `expired` (login needs a refresh) or `unavailable` (request failed) |
| `error` | The error message when `status` is `unavailable`, otherwise `null` |
| `five_hour`, `week` | `percent` used (integer) and `resets_at` (UTC, ISO 8601); `null` when no window is open or `status` is not `ok` |

The exit code is 0 whenever the command ran, so check `status` per profile. For
example, to pick the profile with the most weekly headroom:

```powershell
ccp usage --json | ConvertFrom-Json | ForEach-Object { $_ } |
    Where-Object status -eq ok | Sort-Object { $_.week.percent } | Select-Object -First 1 -ExpandProperty profile
```

- It sends each profile's login token to `api.anthropic.com`, the same endpoint
  Claude Code's own `/usage` screen calls. That endpoint is undocumented and may
  change; if it does, the line reads `unavailable`.
- A profile that has not been used for a while has a stale token. `ccp usage`
  asks `claude` to refresh it; if that fails you get `login expired`, and running
  `ccp run <name>` once fixes it.
- API-key profiles have no subscription limits. Their spend is in the Anthropic
  Console.

## Logging in with an API key

```powershell
ccp add api --key              # prompts for the key, input hidden
ccp add api --key sk-ant-...   # or pass it directly
```

The key is stored in plain text as `env.ANTHROPIC_API_KEY` in the profile's
`settings.json`, which Claude Code reads itself. Claude Code may ask once to
confirm that you want to use the key.

To change the key later, edit that `settings.json`, or remove and re-add the
profile.

## Permission modes

`ccp perm <name> <mode>` sets `permissions.defaultMode` in the profile's
`settings.json`, so it applies to plain `claude` as well as `ccp run`.

| Mode | Behaviour |
| --- | --- |
| `bypass` | No permission prompts at all |
| `auto` | A classifier approves safe actions and blocks risky ones |
| `edits` | File edits without asking, prompts for everything else |
| `ask` | Claude Code's stock behaviour: prompts for edits and commands |
| `plan` | Read-only planning |

**New profiles start in `bypass`.** Change it with `ccp perm <name> ask` if you
want prompts.

## Backup and restore

A backup holds each profile's account: `.credentials.json`, `.claude.json` and
`settings.json`. Sessions and history are not included, and neither is `home`.

```powershell
ccp backup                         # all profiles -> .\backups\ccp-<date>.zip
ccp backup D:\safe\ccp.zip         # choose the file
ccp backup -p                      # encrypt with a password -> ...zip.enc
ccp backup --only work -p          # a single profile

ccp restore D:\safe\ccp.zip        # profiles that already exist are skipped
ccp restore D:\safe\ccp.zip -y     # overwrite existing logins and settings
ccp restore backup.zip.enc --only work
```

Things to know:

- **Backups contain login tokens.** An unencrypted backup is an ordinary zip that
  anyone can open, so keep it private or use `-p`.
- **Encrypted backups** ask for the password twice when saving. `ccp restore`
  detects them and asks for it. There is no recovery if you forget the password.
- An encrypted backup is not a password-protected zip, so 7-Zip and Explorer
  cannot open it; only `ccp restore` can. It is the zip encrypted with AES-256-CBC
  and authenticated with HMAC-SHA256, with keys derived from the password by
  PBKDF2-SHA256 (200,000 iterations).
- For scripts, set `CCP_PASSWORD` in the environment and no prompt appears.
- `--only` on restore takes the profile name as stored in the backup, not a list
  number.

## Files

```
ccp.ps1            the tool
ccp.sh             Git Bash wrapper around ccp.ps1
profiles\<name>\   one Claude Code config directory per profile
profiles\.default  the name of the default profile
backups\           where `ccp backup` writes when no file is given
```

`profiles\` and `backups\` hold login tokens. Do not commit or share them.
