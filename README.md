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

## Repair after moving

Move the entire folder, including `profiles`, with Claude closed. From the new
location, preview the repairs, then apply them:

```powershell
.\ccp.ps1 repair
.\ccp.ps1 repair --apply
# If detection missed an old folder, or the old copy still exists:
.\ccp.ps1 repair --from 'F:\claude-profiles'
.\ccp.ps1 repair --from 'F:\claude-profiles' --apply
```

Only `repair` requires Python 3.11+ (`python` on PATH). Preview does not write
configuration, environment settings, or backups. `--from` can be repeated for
multiple previous locations. Automatic detection selects missing roots referenced
by known profiles; an existing old copy requires an explicit `--from`.

Repair updates hook commands in `settings.json`, plugin installation paths in
`plugins/known_marketplaces.json` and `plugins/installed_plugins.json`, matching
profile environment variables, old PATH entries, and existing `ccp.sh` source
lines in Bash startup files. It honors `CCP_ROOT` for data and uses the script's
location for shell/PATH entries. It leaves credentials, transcripts, historical
project records, and unrelated paths alone. It does not install missing shell
entries; use `install` for a first installation.

Applying refuses to run while a Claude/Codex process is detected. Close editor
integrations too. Original files and saved user environment values go under
`backups/repair-<timestamp>`; `files.json` maps each backup to its original path.
Backups may contain private configuration. If an apply fails, inspect its error
and backups before retrying; the whole repair is not a single transaction.
Restart terminals and apps afterward. Git Bash refreshes its profile variable;
start a new shell for PATH and wrapper changes.

Run isolated repair tests with `python -B .\tests\repair_test.py`.

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
| `ccp repair [--from <old-folder>] [--apply]` | Preview or repair references after moving this folder; requires Python 3.11+ |
| `ccp list [--json]` | Show profiles; `*` marks the one active in this terminal |
| `ccp add <name>` | Create a profile and log in to it |
| `ccp add <name> --key [key]` | Create a profile that uses an API key instead of a login |
| `ccp use [name] [--local]` | Switch this terminal and all new ones; no name means the default. `--local` switches this terminal only |
| `ccp run <name> [--perm <mode>] [args]` | Run `claude` once under a profile without switching |
| `ccp path <name>` | Print the profile's config folder |
| `ccp default [name]` | Show or pick the default profile |
| `ccp perm <name> [mode]` | Show or set the profile's permission mode |
| `ccp usage [name]` | Show how much of its subscription limits each profile has used |
| `ccp pool <name> [on\|off]` | Show or set whether `ccp pick` may choose this profile |
| `ccp pick [-n <count>] [--json]` | Print the pool profile with the most room left |
| `ccp note <name> [text]` | Show or set a one-line note on a profile; `--clear` removes it |
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

`ccp use work --local` changes the current terminal only and leaves the saved
setting alone, so other terminals and tools started later are not affected.

`ccp run` does not switch anything. It runs `claude` once under the named profile
and passes the remaining arguments through. Its exit code is `claude`'s.

```powershell
ccp run work -p "summarise this repo"
ccp run work --perm plan -p "review src/auth"   # read-only for this run
```

`--perm <mode>` must come straight after the name. It overrides the profile's
permission mode for that run and does not change the saved one.

## Listing for scripts

`ccp list --json` prints a one-line array:

```json
[{"number":2,"name":"work","active":false,"default":false,
  "path":"F:\\claude-profiles\\profiles\\work","permissions":"auto",
  "note":"team account","pool":true}]
```

`path` is the profile's config folder. To run `claude` under a profile yourself,
set `CLAUDE_CONFIG_DIR` to it. For `home`, leave the variable unset instead.

## Usage per account

```
> ccp usage
1 home   5h  12% (resets Tue 19:00)   week  31% (resets Fri 09:00)  # personal
2 work   5h -                         week  47% (resets Thu 22:59)  # team account
3 api    no subscription login (API-key profile?)
```

The leading number is the profile's index from `ccp list`, so `ccp usage 2` or
`ccp use 2` works straight from this output. A trailing `# ...` is the profile's
note (see below).

`ccp usage` shows every profile; `ccp usage work` shows one. The percentages are
how much of the 5-hour and weekly limits the account has used across all its
devices, with reset times in local time. `-` means no window is open, so nothing
is used.

For scripts, add `--json`. The output is always a one-line array, even for a
single profile:

```json
[{"index":2,"profile":"work","note":"team account","status":"ok","error":null,
  "five_hour":null,
  "week":{"percent":47,"resets_at":"2026-11-12T15:59:59Z"},
  "number":2,"path":"F:\\claude-profiles\\profiles\\work","pool":true,
  "headroom_percent":53,"available":true}]
```

| Field | Meaning |
| --- | --- |
| `index` | Position in `ccp list` |
| `note` | The profile's note, or `null` |
| `status` | `ok`, `no_login` (API-key profile), `expired` (login needs a refresh) or `unavailable` (request failed) |
| `error` | The error message when `status` is `unavailable`, otherwise `null` |
| `five_hour`, `week` | `percent` used (integer) and `resets_at` (UTC, ISO 8601); `null` when no window is open or `status` is not `ok` |
| `number` | Same as `index` |
| `path` | The profile's config folder |
| `pool` | Whether `ccp pick` may choose it |
| `headroom_percent` | 100 minus the fullest open window; `null` when the limits are unknown |
| `available` | `true` when the limits were read and there is room left, or for an API-key profile |

The last five fields have the same names and meaning in `cxp usage --json`, so one
script can rank Claude and Codex profiles together.

The exit code is 0 whenever the command ran, so check `status` per profile.

## Picking a profile

`ccp pick` prints the name of the profile with the most room left, so a script
does not have to rank them itself:

```powershell
ccp pick                 # the best one
ccp pick -n 3            # the best three, one per line
ccp pick --json          # same objects as `ccp usage --json`, best first
ccp run (ccp pick) -p "summarise this repo"
```

It only considers profiles that are in the pool and `available`. API-key profiles
come last, since their headroom is unknown. If nothing qualifies it prints an
error and exits with 1.

Every profile starts in the pool. Take one out to keep automation off it:

```powershell
ccp pool home off        # ccp pick never returns it
ccp pool home            # show
ccp pool home on
```

The pool only affects `ccp pick`. `ccp use` and `ccp run` still work on any
profile. Profiles out of the pool show `[pool off]` in `ccp list` and `ccp usage`.

- It sends each profile's login token to `api.anthropic.com`, the same endpoint
  Claude Code's own `/usage` screen calls. That endpoint is undocumented and may
  change; if it does, the line reads `unavailable`.
- A profile that has not been used for a while has a stale token. `ccp usage`
  asks `claude` to refresh it; if that fails you get `login expired`, and running
  `ccp run <name>` once fixes it.
- API-key profiles have no subscription limits. Their spend is in the Anthropic
  Console.

## Notes

A one-line note per profile, for remembering which account is which:

```powershell
ccp note work team account, 100 USD plan    # set (no quotes needed)
ccp note work                               # show
ccp note work --clear                       # remove
```

Notes show in `ccp list` and `ccp usage`, are included in `ccp backup`, and follow
the profile through `rename` and `remove`. `ccp note home` works too.

## Logging in with an API key

```powershell
ccp add api --key              # prompts for the key, input hidden
ccp add api --key sk-ant-...   # or pass it directly
```

`--api-key` is accepted as another spelling of `--key`.

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
| `plan` | Read-only planning. `readonly` is accepted as another name for it |

**New profiles start in `auto`.** Use `ccp perm <name> bypass` if you want no
prompts at all. Profiles created before this change keep the mode they had.

To use a different mode for one run only, see `ccp run <name> --perm <mode>` above.

## Backup and restore

A backup holds each profile's account: `.credentials.json`, `.claude.json` and
`settings.json`. Sessions and history are not included, and neither is `home`.

```powershell
ccp backup                         # all profiles -> .\backups\ccp-<date>.zip
ccp backup D:\safe\ccp.zip         # choose the file
ccp backup -p                      # encrypt with a password -> ...zip.enc (--password works too)
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

## Environment variables

| Variable | Effect |
| --- | --- |
| `CLAUDE_CONFIG_DIR` | Set by `ccp use` (per terminal, and saved for new ones unless `--local`). Unset means `home` |
| `CCP_ROOT` | Keep `profiles\` and `backups\` somewhere else instead of next to the script |
| `CCP_PASSWORD` | Backup password, to skip the prompt |

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ccp.ps1
```

The tests use a temporary `CCP_ROOT` and a fake `claude`, so they do not touch
your profiles, log in, or call the usage endpoint.

## Files

```
ccp.ps1            the tool
ccp.sh             Git Bash wrapper around ccp.ps1
tests\ccp.ps1      integration tests
profiles\<name>\   one Claude Code config directory per profile (note in .ccp-note,
                   pool opt-out in .ccp-pool-off)
profiles\.default  the name of the default profile
backups\           where `ccp backup` writes when no file is given
```

`profiles\` and `backups\` hold login tokens. Do not commit or share them.
