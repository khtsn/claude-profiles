# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ccp` is a Claude Code profile switcher for Windows (`ccp.ps1`) and macOS / Linux (`ccp.bash`). Each profile is its own `CLAUDE_CONFIG_DIR` under `profiles/<name>`. The two implementations share the profile layout, settings and backup format; a change to one needs the same change in the other. `README.md` documents user-facing behaviour and the `--json` output contract; keep it in sync when commands or output change.

There is no build or lint. Run the integration tests after any change, and run the tool directly to check output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ccp.ps1
powershell -NoProfile -File .\ccp.ps1 list
powershell -NoProfile -File .\ccp.ps1 usage 2 --json
```

On macOS / Linux:

```sh
bash tests/ccp.bash
./ccp.bash list
./ccp.bash usage 2 --json
```

The tests point `CCP_ROOT` at a temp folder and put a fake `claude.cmd` on PATH. They must never call plain `ccp use` (it writes the user's saved setting) or query `home` (it would send the real login token), so they take `home` out of the pool first and use API-key profiles.

`ccp.ps1` must work on Windows PowerShell 5.1, so avoid `&&`/`||`, ternaries and `-AsHashtable`.
`ccp.bash` must work on macOS's bash 3.2: no associative arrays, `mapfile`, `${var,,}` or `coproc`, and only flags that BSD and GNU tools share. It needs `jq`; encrypted backups need OpenSSL 3 (`openssl kdf`), which `Openssl` looks for since macOS's own `openssl` is LibreSSL.

## Architecture

- `ccp.ps1` is the whole Windows implementation, and `ccp.bash` the macOS / Linux one, built the same way with the same function names. It has helper functions at the top, then one `switch ($cmd)` that dispatches commands. Adding a command means adding a case there, a line in the `default` help text, and a README entry.
- `ccp.sh` is a thin bash/zsh wrapper that calls `ccp.ps1` through `powershell.exe` in Git Bash, and `ccp.bash` elsewhere. Its only extra job is re-reading `CLAUDE_CONFIG_DIR` into the shell after `use`, or after `rename`/`remove` deletes the active profile folder, because a child process can't change the parent shell's environment. For `use --local` it asks `ccp.ps1 path --env` for the value instead of reading the saved setting. On Windows the saved setting is the user variable; on macOS / Linux it is `profiles/.use`, read through `ccp.bash path --saved` (exit 2 when nothing is saved), and sourcing `ccp.sh` applies it to each new shell. Don't put logic in it.
- `profiles\` holds login tokens and is gitignored. `profiles\.default` stores the default profile name. `backups\` is where `ccp backup` writes by default. `CCP_ROOT` moves both somewhere else.

## Conventions that span the file

- **Args are parsed by hand.** There is no `param()`, so claude flags like `-p` pass through `run` untouched. `$name = $args[1]` and `$rest` is everything after it. `SplitOnly` extracts `--only <name>`. `Opts` returns everything after the command for commands whose flags can go anywhere. `run --perm <mode>` is only recognised as the first argument after the name, so claude's own flags are never touched.
- **Profile names go through `Resolve`**, which maps `default`, a list number, or a plain name. `ProfileDir` validates the name against `$nameRe` and returns `$null` for `home`, which means `CLAUDE_CONFIG_DIR` is unset and `~/.claude` is used. Handle that `$null` anywhere you build a path. `ProfilePath` is the same but returns the real `~/.claude` for `home`. `NewProfileDir` is for names that must not exist yet.
- **Files stored per profile.**
  - `$credFiles` is the subset `backup --creds` / `restore --creds` move: the login alone.
  - `$acctFiles` lists what `backup` saves, and `restore` rejects zip entries that aren't `<valid-name>/<one of these files>`. A new per-profile file that should survive backup must be added there.
  - Notes are stored in `.ccp-note` inside the profile folder, so rename, remove and backup carry them. The note for `home` is `profiles\.home-note`.
  - A profile is in the pool unless the empty marker `.ccp-pool-off` exists in its folder (`profiles\.home-pool-off` for `home`). `pick` filters on the pool before calling `Usage`, so an out-of-pool profile's token is never sent.
  - Settings are written through `LoadCfg`/`SaveCfg`, which throw on invalid JSON rather than overwrite it.
- **macOS logins live in the Keychain.** claude reads the login-keychain item `Claude Code-credentials` (home) or `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>` before `.credentials.json`, and saves refreshed logins only there. In `ccp.bash`, `ReadCreds`/`WriteCreds` are the only way to touch a login: `usage`, `backup` and `restore` go through them, and `rename`/`remove` move or delete the item. The hash is of the exact `CLAUDE_CONFIG_DIR` string, which is why paths are resolved with `pwd -P` and `ccp` always sets the variable itself. `WriteCreds` passes the token hex-encoded on `security -i` stdin, never in argv.
- **`ccp usage --json` is a stable contract.** Scripts depend on it. Only add fields, never rename or remove them. `number`, `path`, `pool`, `headroom_percent` and `available` are shared with `cxp usage --json` in the sibling `codex-profiles` tool, and `list --json` mirrors `cxp list --json`; keep the names and meaning identical in both. The `Usage` function builds the object, and `UsageText` renders the human format. It calls an undocumented Anthropic endpoint, so failures map to a `status` value (`unavailable`, `expired`, `no_login`) instead of throwing.
- **Flag and mode aliases match `cxp`.** `--key`/`--api-key`, `-p`/`--password`, and the mode `plan`/`readonly` (`Mode` maps it) are accepted in both tools.
- **Encrypted backups** use the custom `CCPENC1` format (PBKDF2, AES-256-CBC, HMAC-SHA256). The format is documented in the README, so changing it breaks existing backups.
- **Line endings.** `.gitattributes` keeps `*.sh` and `*.bash` as LF. Keep it that way, because a CRLF breaks Git Bash and bash on macOS / Linux.
