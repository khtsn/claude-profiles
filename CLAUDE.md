# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ccp` is a Claude Code profile switcher for Windows. Each profile is its own `CLAUDE_CONFIG_DIR` under `profiles\<name>`. `README.md` documents user-facing behaviour and the `--json` output contract; keep it in sync when commands or output change.

There is no build, lint, or test suite. Run the tool directly and check the output:

```powershell
powershell -NoProfile -File .\ccp.ps1 list
powershell -NoProfile -File .\ccp.ps1 usage 2 --json
```

`ccp.ps1` must work on Windows PowerShell 5.1, so avoid `&&`/`||`, ternaries and `-AsHashtable`.

## Architecture

- `ccp.ps1` is the whole implementation. It has helper functions at the top, then one `switch ($cmd)` that dispatches commands. Adding a command means adding a case there, a line in the `default` help text, and a README entry.
- `ccp.sh` is a thin Git Bash wrapper that calls `ccp.ps1` through `powershell.exe`. Its only extra job is re-reading `CLAUDE_CONFIG_DIR` into the shell after `use`, or after `rename`/`remove` deletes the active profile folder, because a child process can't change the parent shell's environment. Don't put logic in it.
- `profiles\` holds login tokens and is gitignored. `profiles\.default` stores the default profile name. `backups\` is where `ccp backup` writes by default.

## Conventions that span the file

- **Args are parsed by hand.** There is no `param()`, so claude flags like `-p` pass through `run` untouched. `$name = $args[1]` and `$rest` is everything after it. `SplitOnly` extracts `--only <name>`.
- **Profile names go through `Resolve`**, which maps `default`, a list number, or a plain name. `ProfileDir` validates the name against `$nameRe` and returns `$null` for `home`, which means `CLAUDE_CONFIG_DIR` is unset and `~/.claude` is used. Handle that `$null` anywhere you build a path. `NewProfileDir` is for names that must not exist yet.
- **Files stored per profile.**
  - `$acctFiles` lists what `backup` saves, and `restore` rejects zip entries that aren't `<valid-name>/<one of these files>`. A new per-profile file that should survive backup must be added there.
  - Notes are stored in `.ccp-note` inside the profile folder, so rename, remove and backup carry them. The note for `home` is `profiles\.home-note`.
  - Settings are written through `LoadCfg`/`SaveCfg`, which throw on invalid JSON rather than overwrite it.
- **`ccp usage --json` is a stable contract.** Scripts depend on it. Only add fields, never rename or remove them. The `Usage` function builds the object, and `UsageText` renders the human format. It calls an undocumented Anthropic endpoint, so failures map to a `status` value (`unavailable`, `expired`, `no_login`) instead of throwing.
- **Encrypted backups** use the custom `CCPENC1` format (PBKDF2, AES-256-CBC, HMAC-SHA256). The format is documented in the README, so changing it breaks existing backups.
- **Line endings.** `.gitattributes` keeps `*.sh` as LF. Keep it that way, because a CRLF in `ccp.sh` breaks Git Bash.
