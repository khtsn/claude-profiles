#!/usr/bin/env bash
# ccp - Claude Code profile switcher for macOS and Linux. Each profile is its own
# CLAUDE_CONFIG_DIR (separate login, sessions, history, settings) under ./profiles/<name>.
# "home" is the stock ~/.claude. "default" (or no name) is an alias for
# whichever profile `ccp default <name>` picked; home until you pick one.
# ccp.ps1 is the Windows implementation: same profiles/ layout, settings and backup
# format, so a profile folder or a backup moves between the two. Keep them in step.
# Needs bash 3.2+ (macOS's own), jq, curl, zip/unzip, and OpenSSL 3 for encrypted backups.

die() { printf 'ccp: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die 'jq is required (macOS: brew install jq; Linux: your package manager)'

cmd=$1; name=$2   # no getopts: claude flags like -p must pass through `run` untouched
rest=("${@:3}")
self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
base=${CCP_ROOT:-$self_dir}   # keep data elsewhere (also how the tests avoid real profiles)
[ -d "$base" ] && base=$(cd "$base" && pwd -P)
root=$base/profiles
defFile=$root/.default
# Where `ccp use` saves the profile for new terminals (ccp.ps1 uses a Windows user variable).
# Holds the CLAUDE_CONFIG_DIR value; empty means home. ccp.sh reads it through `path --saved`.
useFile=$root/.use
# Names become folder names: . @ + only singly between word chars, so emails
# work but "..", leading dots (.default) and trailing dots (Windows strips them) don't.
nameRe='^[A-Za-z0-9_-]+([.@+][A-Za-z0-9_-]+)*$'
# What `backup` saves per profile: the account (login + identity) and settings, not sessions/history.
acctFiles=' .credentials.json .claude.json settings.json .ccp-note .ccp-pool-off '
# What `backup --creds` / `restore --creds` move: the login alone.
credFiles=' .credentials.json '
isMac=; [ "$(uname -s)" = Darwin ] && isMac=1

DefaultName() {
    if [ -f "$defFile" ]; then head -n 1 "$defFile" | tr -d '[:space:]'; else echo home; fi
}

Names() {   # in `ccp list` order; a profile's number is its position here
    echo home
    [ -d "$root" ] || return 0
    local d
    for d in "$root"/*/; do [ -d "$d" ] && basename "$d"; done | LC_ALL=C sort -f
}

Resolve() {   # alias, list number, or plain name -> name
    local n=$1
    if [ -z "$n" ] || [ "$n" = default ]; then DefaultName; return; fi
    if [[ $n =~ ^[0-9]+$ ]]; then
        local all count
        all=$(Names); count=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
        if [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then die "No profile #$n (ccp list shows 1-$count)"; fi
        printf '%s\n' "$all" | sed -n "${n}p"
        return
    fi
    echo "$n"
}

CheckName() {
    [[ $1 =~ $nameRe ]] || die "Bad profile name '$1' (letters, digits, - _ and single . @ + between them, e.g. me@example.com)"
}

ProfileDir() {   # empty for home = CLAUDE_CONFIG_DIR unset = ~/.claude
    [ "$1" = home ] && return 0
    CheckName "$1"
    [ -d "$root/$1" ] || die "No profile '$1'. Create it: ccp add $1"
    echo "$root/$1"
}

NewProfileDir() {   # path for a profile that must not exist yet
    local n=$1
    [ -n "$n" ] || die 'Missing new profile name'
    if [ "$n" = home ] || [ "$n" = default ]; then die "'$n' is reserved"; fi
    [[ $n =~ ^[0-9]+$ ]] && die "A name can't be only digits; numbers are list positions"
    CheckName "$n"
    [ -e "$root/$n" ] && die "Profile '$n' already exists"
    echo "$root/$n"
}

ProfilePath() {   # like ProfileDir, but home is a real path
    local d; d=$(ProfileDir "$1") || exit 1
    if [ -n "$d" ]; then echo "$d"; else echo "$HOME/.claude"; fi
}

HomeSkills() {   # a new profile starts with home's own skills: links, so they follow home's copies
    local s
    for s in "$HOME/.claude/skills"/*/; do
        s=${s%/}
        [ -d "$s" ] && [ "${s##*/}" != synced ] || continue   # synced/ is claude's own, per account
        mkdir -p "$1/skills" && ln -s "$s" "$1/skills/${s##*/}"
    done
}

HomeHooks() {   # $1 settings.json. A new profile gets home's *-axi startup hooks; home's other hooks stay home's
    local src="$HOME/.claude/settings.json" axi s
    [ -f "$src" ] || return 0
    axi=$(jq -c '[.hooks.SessionStart[]? | select((.hooks // []) != [] and all(.hooks[]; (.command // "") | test("-axi$")))]' "$src" 2>/dev/null) || return 0
    [ "$axi" = '[]' ] && return 0
    s=$(LoadCfg "$1") || exit 1
    printf '%s' "$s" | jq --argjson axi "$axi" '.hooks.SessionStart = (.hooks.SessionStart // []) + $axi' | SaveCfg "$1"
}

HomePrefs() {   # $1 settings.json. A new profile keeps home's memory and fast mode choices, where home made one
    local src="$HOME/.claude/settings.json" p s
    [ -f "$src" ] || return 0
    p=$(jq -c '{autoMemoryEnabled, fastMode} | with_entries(select(.value != null))' "$src" 2>/dev/null) || return 0
    [ "$p" = '{}' ] && return 0
    s=$(LoadCfg "$1") || exit 1
    printf '%s' "$s" | jq --argjson p "$p" '. + $p' | SaveCfg "$1"
}

NotePath() {   # a profile's note lives in its folder (so rename/remove/backup carry it); home's beside them
    local d; d=$(ProfileDir "$1") || exit 1
    if [ -n "$d" ]; then echo "$d/.ccp-note"; else echo "$root/.home-note"; fi
}

GetNote() {   # nothing when there is no note
    local f; f=$(NotePath "$1") || exit 1
    [ -f "$f" ] && sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | tr -d '\r'
    return 0
}

# Pool = the profiles `ccp pick` may hand to automation. In by default; a marker file takes one out.
PoolPath() {
    local d; d=$(ProfileDir "$1") || exit 1
    if [ -n "$d" ]; then echo "$d/.ccp-pool-off"; else echo "$root/.home-pool-off"; fi
}

InPool() { [ ! -e "$(PoolPath "$1")" ]; }

Bool() { if "$@"; then echo true; else echo false; fi; }

Retarget() {   # repoint the saved setting if it was on $1 (ccp.sh repoints this shell)
    if [ -f "$useFile" ] && [ "$(cat "$useFile")" = "$1" ]; then printf '%s' "$2" > "$useFile"; fi
}

# Permission modes = permissions.defaultMode in the profile's settings.json, the key
# claude itself reads, so they apply to plain `claude` after `ccp use` as well as `ccp run`.
modeKeys='bypass auto edits ask plan'
ModeValue() {
    case $1 in
        bypass) echo bypassPermissions ;;   # no prompts at all
        auto) echo auto ;;                  # classifier approves safe actions, blocks risky ones
        edits) echo acceptEdits ;;          # file edits without asking, prompts for the rest
        ask) echo default ;;                # stock behaviour: prompt for edits and commands
        plan) echo plan ;;                  # read-only planning
    esac
}

Mode() {   # accepts cxp's name for the read-only mode too -> a mode key
    local m=$1
    [ "$m" = readonly ] && m=plan
    case " $modeKeys " in *" $m "*) [ -n "$m" ] && { echo "$m"; return; } ;; esac
    die "Unknown mode '$m'. Use: ${modeKeys// /, } (readonly = plan)"
}

ConfigPath() { local p; p=$(ProfilePath "$1") || exit 1; echo "$p/settings.json"; }

LoadCfg() {   # settings as JSON; invalid JSON stops here: never clobber it
    if [ -s "$1" ]; then jq -e . "$1" 2>/dev/null || die "'$1' is not valid JSON; fix it by hand first"
    else echo '{}'; fi
}

SaveCfg() {   # $1 file, stdin the new JSON; written beside it first so a failure can't truncate it
    local tmp; tmp=$(mktemp "$1.XXXXXX") || exit 1
    cat > "$tmp" && mv "$tmp" "$1"
}

GetPerm() {
    local m=
    [ -f "$1" ] && m=$(LoadCfg "$1" | jq -r '.permissions.defaultMode // empty')
    [ -z "$m" ] && { echo claude-default; return; }
    local k
    for k in $modeKeys; do [ "$(ModeValue "$k")" = "$m" ] && { echo "$k"; return; }; done
    echo "custom: $m"
}

SetPerm() {
    local mode s
    mode=$(Mode "$2") || exit 1
    s=$(LoadCfg "$1") || exit 1
    # without skipDangerousModePermissionPrompt claude stops at a "bypass mode is dangerous" dialog on first start
    jq --arg v "$(ModeValue "$mode")" --argjson b "$(Bool [ "$mode" = bypass ])" \
        '.permissions = ((.permissions // {}) + {defaultMode: $v}) | if $b then .skipDangerousModePermissionPrompt = true else . end' \
        <<<"$s" | SaveCfg "$1"
}

SetKey() {   # API-key login = env.ANTHROPIC_API_KEY in the profile's settings.json, which claude loads itself
    local s; s=$(LoadCfg "$1") || exit 1
    jq --arg k "$2" '.env = ((.env // {}) + {ANTHROPIC_API_KEY: $k})' <<<"$s" | SaveCfg "$1"
}

ReadSecret() {   # $1 prompt; hidden input
    local v
    printf '%s: ' "$1" >&2
    IFS= read -rs v; printf '\n' >&2
    printf '%s' "$v"
}

# --- Login storage -------------------------------------------------------------------------
# Windows and Linux: <config dir>/.credentials.json. macOS: the login keychain, one item per
# config dir, named the way claude names it: "Claude Code-credentials" for ~/.claude, else that
# plus "-" and the first 8 hex digits of sha256(CLAUDE_CONFIG_DIR). claude reads the keychain
# first and falls back to the file, and writes refreshed logins to the keychain only.
KcAccount() {
    local u=${USER:-$(id -un)}
    if [[ $u =~ ^[a-zA-Z0-9._-]+$ ]]; then echo "$u"; else echo claude-code-user; fi
}

KcService() {   # $1 = the CLAUDE_CONFIG_DIR value, empty for home
    if [ -z "$1" ]; then echo 'Claude Code-credentials'
    else echo "Claude Code-credentials-$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; fi
}

ReadCreds() {   # profile name -> the credentials JSON, or nothing
    local d p
    d=$(ProfileDir "$1") || exit 1
    if [ -n "$isMac" ]; then
        security find-generic-password -a "$(KcAccount)" -s "$(KcService "$d")" -w 2>/dev/null && return 0
    fi
    p=$(ProfilePath "$1") || exit 1
    [ -f "$p/.credentials.json" ] && cat "$p/.credentials.json"
    return 0
}

WriteCreds() {   # profile name, file holding the credentials JSON
    local d p
    d=$(ProfileDir "$1") || exit 1
    jq -e '.claudeAiOauth' "$2" >/dev/null 2>&1 || die "'$1': the backed-up login is not valid credentials JSON"
    if [ -n "$isMac" ]; then
        # hex through `security -i` (stdin), as claude does, so the token never shows in `ps`
        local hex
        hex=$(od -An -tx1 < "$2" | tr -d ' \n')
        printf 'add-generic-password -U -a "%s" -s "%s" -X %s\n' "$(KcAccount)" "$(KcService "$d")" "$hex" |
            security -i >/dev/null || die "'$1': could not save the login to the keychain"
        return 0
    fi
    p=$(ProfilePath "$1") || exit 1
    (umask 077; cat "$2" > "$p/.credentials.json")
}

# --- Encrypted backups -----------------------------------------------------------------------
# 'CCPENC1' + salt(16) + iv(16) + AES-256-CBC(zip) + HMAC-SHA256 of all before it.
# Keys come from the password via PBKDF2-SHA256 (200000 rounds, 64 bytes: AES key + HMAC key);
# the HMAC is what detects a wrong password or tampering. Same bytes as ccp.ps1 reads and writes.
# ponytail: openssl takes the password and derived keys as arguments, so another local user could
# glimpse them in `ps` for the moment it runs. Fine on a personal machine.
magic=CCPENC1

Openssl() {   # an OpenSSL 3 (macOS's own /usr/bin/openssl is LibreSSL, which has no `kdf`)
    local o
    for o in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if "$o" kdf -keylen 1 -kdfopt digest:SHA256 -kdfopt pass:x -kdfopt salt:x -kdfopt iter:1 PBKDF2 >/dev/null 2>&1; then
            echo "$o"; return
        fi
    done
    die 'Encrypted backups need OpenSSL 3 (macOS: brew install openssl@3)'
}

AskPassword() {   # $1 = twice; $CCP_PASSWORD skips the prompt (scripts)
    if [ -n "$CCP_PASSWORD" ]; then printf '%s' "$CCP_PASSWORD"; return; fi
    local p q
    p=$(ReadSecret Password)
    [ -n "$p" ] || die 'Empty password'
    if [ -n "$1" ]; then
        q=$(ReadSecret 'Repeat password')
        [ "$p" = "$q" ] || die "Passwords don't match"
    fi
    printf '%s' "$p"
}

Hex() { od -An -tx1 | tr -d ' \n'; }
Unhex() { printf "$(sed 's/../\\x&/g')"; }
Size() { wc -c < "$1" | tr -d ' '; }

Keys() {   # password, salt hex -> 128 hex digits: AES key, then HMAC key
    "$ossl" kdf -binary -keylen 64 -kdfopt digest:SHA256 -kdfopt "pass:$1" -kdfopt "hexsalt:$2" \
        -kdfopt iter:200000 PBKDF2 | Hex
}

Hmac() { "$ossl" dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary | Hex; }   # stdin -> hex

Encrypt() {   # plain file, password, out file
    local salt iv k
    salt=$("$ossl" rand -hex 16); iv=$("$ossl" rand -hex 16)
    k=$(Keys "$2" "$salt")
    { printf '%s' "$magic"; Unhex <<<"$salt"; Unhex <<<"$iv"
      "$ossl" enc -aes-256-cbc -K "${k:0:64}" -iv "$iv" -in "$1"; } > "$3.body" || exit 1
    { cat "$3.body"; Hmac "${k:64:64}" < "$3.body" | Unhex; } > "$3"
    rm -f "$3.body"
}

IsEncrypted() { [ "$(head -c ${#magic} "$1")" = "$magic" ]; }

Decrypt() {   # encrypted file, password, out file
    local h=${#magic} size n k mac
    size=$(Size "$1")
    [ "$size" -ge $((h + 80)) ] || die 'Backup file is truncated'
    n=$((size - 32))
    k=$(Keys "$2" "$(tail -c +$((h + 1)) "$1" | head -c 16 | Hex)")
    mac=$(head -c "$n" "$1" | Hmac "${k:64:64}")
    [ "$mac" = "$(tail -c 32 "$1" | Hex)" ] || die 'Wrong password (or the backup is corrupt)'
    head -c "$n" "$1" | tail -c +$((h + 33)) |
        "$ossl" enc -d -aes-256-cbc -K "${k:0:64}" -iv "$(tail -c +$((h + 17)) "$1" | head -c 16 | Hex)" > "$3" ||
        die 'Could not decrypt the backup'
}

# --- Usage -----------------------------------------------------------------------------------
NowMs() { echo $(( $(date +%s) * 1000 )); }

LocalTime() {   # epoch seconds, date format -> local time
    if [ -n "$isMac" ]; then date -r "$1" "+$2"; else date -d "@$1" "+$2"; fi
}

Index() {   # same number `ccp list` shows
    Names | awk -v n="$1" '$0 == n { print NR; exit }'
}

# Subscription limits, from the endpoint behind claude's own /usage screen.
# ponytail: undocumented API; if it changes, this prints "unavailable" and only Usage needs fixing.
Usage() {   # profile name -> one JSON object, the shape `ccp usage --json` prints: keep it stable
    local n=$1 d p creds tok exp out code body err status=ok
    d=$(ProfileDir "$n") || exit 1
    p=$(ProfilePath "$n") || exit 1
    local obj
    # the fields after week are shared with `cxp usage --json`, so one script can rank both tools' profiles
    obj=$(jq -n --argjson idx "$(Index "$n")" --arg n "$n" --arg note "$(GetNote "$n")" --arg p "$p" \
        --argjson pool "$(Bool InPool "$n")" \
        '{index: $idx, profile: $n, note: (if $note == "" then null else $note end), status: "ok", error: null,
          five_hour: null, week: null, number: $idx, path: $p, pool: $pool, headroom_percent: null, available: false}')
    creds=$(ReadCreds "$n")
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$creds" 2>/dev/null)
    if [ -z "$tok" ]; then
        # an API-key profile can still run work; it just has no subscription window to measure
        local key
        key=$(LoadCfg "$(ConfigPath "$n")" 2>/dev/null | jq -r '.env.ANTHROPIC_API_KEY // empty' 2>/dev/null)
        jq -c --argjson a "$(Bool [ -n "$key" ])" '.status = "no_login" | .available = $a' <<<"$obj"
        return
    fi
    exp=$(jq -r '.claudeAiOauth.expiresAt // 0' <<<"$creds" 2>/dev/null)
    if [ "${exp%%.*}" -lt "$(NowMs)" ] 2>/dev/null; then
        # stale token: let claude refresh it
        if [ -n "$d" ]; then CLAUDE_CONFIG_DIR=$d claude auth status >/dev/null 2>&1 </dev/null
        else (unset CLAUDE_CONFIG_DIR; claude auth status >/dev/null 2>&1 </dev/null); fi
        creds=$(ReadCreds "$n")
        tok=$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$creds" 2>/dev/null)
    fi
    # the token goes in through a curl config on stdin, not argv, so it never shows in `ps`
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" |
        curl -sS --max-time 20 -K - -H 'anthropic-beta: oauth-2025-04-20' -w '\n%{http_code}' \
            https://api.anthropic.com/api/oauth/usage 2>&1)
    code=${out##*$'\n'}; body=${out%$'\n'*}
    if [ "$code" != 200 ]; then
        status=unavailable; err="HTTP $code"
        [ "$code" = 000 ] && err=$(printf '%s' "$body" | head -n 1 | sed 's/^curl: ([0-9]*) //')
        [ "$code" = 401 ] && status=expired
        jq -c --arg s "$status" --arg e "$err" '.status = $s | .error = $e' <<<"$obj"
        return
    fi
    jq -c --argjson u "$body" '
        def utc: sub("\\.[0-9]+"; "") |
            if test("Z$") then fromdateiso8601
            else capture("^(?<d>.*)(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$") as $c |
                ($c.d + "Z" | fromdateiso8601) - (($c.s + "1" | tonumber) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60))
            end | todate;
        # null = no window open, nothing used; resets_at can be null (window reported but no reset time yet)
        def win: if . then {percent: (.utilization // 0 | round), resets_at: (if .resets_at then (.resets_at | utc) else null end)} else null end;
        .five_hour = ($u.five_hour | win) | .week = ($u.seven_day | win)
        # the fullest open window decides how much room is left
        | .headroom_percent = ([0, 100 - ([0, (.five_hour.percent // 0), (.week.percent // 0)] | max)] | max)
        | .available = (.headroom_percent > 0)' <<<"$obj" 2>/dev/null ||
        jq -c '.status = "unavailable" | .error = "unexpected reply from the usage endpoint"' <<<"$obj"
}

UsageText() {   # one Usage object -> the human format
    local r=$1 status
    status=$(jq -r .status <<<"$r")
    case $status in
        no_login) echo 'no subscription login (API-key profile?)'; return ;;
        expired) echo "login expired; refresh it: ccp run $(jq -r .profile <<<"$r")"; return ;;
        unavailable) echo "unavailable ($(jq -r .error <<<"$r"))"; return ;;
    esac
    local w text=''
    for w in five_hour week; do
        local pct at s
        pct=$(jq -r ".$w.percent // empty" <<<"$r")
        at=$(jq -r ".$w.resets_at // empty | fromdateiso8601" <<<"$r")
        if [ -z "$pct" ]; then s=$(printf '%-23s' -)   # padded to line up with a filled window
        elif [ -z "$at" ]; then s=$(printf '%-23s' "$(printf '%3s%% (no reset time)' "$pct")")
        else s=$(printf '%3s%% (resets %s)' "$pct" "$(LocalTime "$at" '%a %H:%M')"); fi
        if [ "$w" = five_hour ]; then text="5h $s"; else text="$text   week $s"; fi
    done
    echo "$text"
}

Opts() { opts=(); [ -n "$name" ] && opts=("$name"); opts+=("${rest[@]}"); }   # everything after the command, for commands whose flags go anywhere

Has() { local x f=$1; shift; for x in "$@"; do [ "$x" = "$f" ] && return 0; done; return 1; }

ClaudeIn() {   # run claude under a profile dir (empty = home) without touching this process's setting
    if [ -n "$1" ]; then CLAUDE_CONFIG_DIR=$1 claude "${@:2}"
    else (unset CLAUDE_CONFIG_DIR; claude "${@:2}"); fi
}

Stamp() { date +%Y%m%d-%H%M%S; }

case $cmd in
    list)
        Opts
        def=$(DefaultName); i=0; rows=()
        while IFS= read -r n; do
            i=$((i + 1))
            d=$(ProfileDir "$n") || exit 1
            active=false; [ "$d" = "${CLAUDE_CONFIG_DIR-}" ] && active=true
            note=$(GetNote "$n"); perm=$(GetPerm "$(ConfigPath "$n")")
            if Has --json "${opts[@]}"; then   # same fields as `cxp list --json`; for home, run claude with CLAUDE_CONFIG_DIR unset
                rows+=("$(jq -n -c --argjson i $i --arg n "$n" --argjson a $active --argjson def "$(Bool [ "$n" = "$def" ])" \
                    --arg p "$(ProfilePath "$n")" --arg perm "$perm" --arg note "$note" --argjson pool "$(Bool InPool "$n")" \
                    '{number: $i, name: $n, active: $a, default: $def, path: $p, permissions: $perm,
                      note: (if $note == "" then null else $note end), pool: $pool}')")
                continue
            fi
            mark=' '; [ $active = true ] && mark='*'
            tag=''; [ "$n" = "$def" ] && tag=' (default)'
            line="$mark $i $n$tag [$perm]"
            InPool "$n" || line+=' [pool off]'
            [ -n "$note" ] && line+="  # $note"
            echo "$line"
        done < <(Names)
        if Has --json "${opts[@]}"; then printf '%s\n' "${rows[@]}" | jq -c -s .; fi
        ;;
    add)
        dir=$(NewProfileDir "$name") || exit 1
        key=
        if [ "${rest[0]}" = --key ] || [ "${rest[0]}" = --api-key ]; then
            key=${rest[1]}
            [ -z "$key" ] && key=$(ReadSecret 'API key')   # prompt hidden, so the key stays out of shell history
            key=$(printf '%s' "$key" | tr -d '[:space:]')
            [ -n "$key" ] || die 'No API key given, nothing created'
        fi
        mkdir -p "$dir" || exit 1
        SetPerm "$dir/settings.json" auto   # safe default; `ccp perm <name> bypass` opts out of all prompts
        HomeSkills "$dir"
        HomeHooks "$dir/settings.json"
        HomePrefs "$dir/settings.json"
        if [ -n "$key" ]; then SetKey "$dir/settings.json" "$key"; else ClaudeIn "$dir" auth login; fi
        echo "Created '$name'. Switch to it: ccp use $name"
        ;;
    use)   # ccp use [name] [--local]. A child process can't change the shell: ccp.sh applies it
        Opts
        target=; for o in "${opts[@]}"; do [ "$o" != --local ] && { target=$o; break; }; done
        name=$(Resolve "$target") || exit 1
        dir=$(ProfileDir "$name") || exit 1
        if Has --local "${opts[@]}"; then echo "Now using '$name' (this terminal only)"
        else
            mkdir -p "$root" && printf '%s' "$dir" > "$useFile"   # new terminals
            echo "Now using '$name'"
        fi
        ;;
    path)   # the profile's config folder. --env: the value CLAUDE_CONFIG_DIR needs (nothing for home);
            # --saved: the value `ccp use` saved for new terminals (exit 2 if none); ccp.sh uses both
        Opts
        if Has --saved "${opts[@]}"; then [ -f "$useFile" ] || exit 2; cat "$useFile"; echo; exit 0; fi
        target=; for o in "${opts[@]}"; do [ "$o" != --env ] && [ "$o" != --local ] && { target=$o; break; }; done
        name=$(Resolve "$target") || exit 1
        if Has --env "${opts[@]}"; then ProfileDir "$name"; else ProfilePath "$name"; fi
        ;;
    run)   # ccp run <name> [--perm <mode>] [claude args]
        name=$(Resolve "$name") || exit 1
        dir=$(ProfileDir "$name") || exit 1
        if [ "${rest[0]}" = --perm ]; then   # only as the first argument, so claude's own flags stay untouched
            m=$(Mode "${rest[1]}") || exit 1
            v=$(ModeValue "$m")
            [ "$v" = default ] && v=manual   # the CLI flag's name for settings.json's "default"
            rest=(--permission-mode "$v" "${rest[@]:2}")
        fi
        ClaudeIn "$dir" "${rest[@]}"
        exit $?   # scripts need claude's own exit code
        ;;
    pool)   # ccp pool <name> [on|off]
        name=$(Resolve "$name") || exit 1
        f=$(PoolPath "$name") || exit 1
        case ${rest[0]} in
            '') ;;
            on) rm -f "$f" ;;
            off) mkdir -p "$root" && : > "$f" ;;
            *) die 'Use: ccp pool <name> [on|off]' ;;
        esac
        if InPool "$name"; then echo "'$name' is in the pool"; else echo "'$name' is out of the pool (ccp pick skips it)"; fi
        ;;
    pick)   # ccp pick [-n <count>] [--json]: pool profiles with room left, most headroom first
        Opts
        count=1
        for ((i = 0; i < ${#opts[@]}; i++)); do
            if [ "${opts[$i]}" = -n ]; then
                [[ ${opts[$((i + 1))]} =~ ^[1-9][0-9]*$ ]] || die '-n needs a number, e.g. ccp pick -n 3'
                count=${opts[$((i + 1))]}
            fi
        done
        # out-of-pool profiles are skipped before any lookup, so their tokens are never sent
        all=$(while IFS= read -r n; do InPool "$n" && Usage "$n"; done < <(Names))
        # API-key profiles (no known headroom) go last
        rows=$(printf '%s\n' "$all" | jq -c -s --argjson c "$count" \
            'map(select(.available)) | sort_by([-(.headroom_percent // -1), .number]) | .[:$c]')
        [ "$(jq length <<<"$rows")" -gt 0 ] ||
            die 'No profile available: all are out of the pool, at their limit, or not logged in (see: ccp usage)'
        if Has --json "${opts[@]}"; then echo "$rows"; else jq -r '.[].profile' <<<"$rows"; fi
        ;;
    default)
        if [ -n "$name" ]; then
            name=$(Resolve "$name") || exit 1
            ProfileDir "$name" >/dev/null || exit 1   # must exist
            mkdir -p "$root" && echo "$name" > "$defFile"
            echo "Default is now '$name'"
        else echo "Default is '$(DefaultName)'"; fi
        ;;
    rename)
        name=$(Resolve "$name") || exit 1
        old=$(ProfileDir "$name") || exit 1
        [ -n "$old" ] || die "'home' is ~/.claude and can't be renamed"
        new=$(NewProfileDir "${rest[0]}") || exit 1
        mv "$old" "$new" || exit 1
        [ "$(DefaultName)" = "$name" ] && echo "${rest[0]}" > "$defFile"
        Retarget "$old" "$new"
        if [ -n "$isMac" ]; then   # the keychain item is keyed by the folder path: move the login with it
            if creds=$(security find-generic-password -a "$(KcAccount)" -s "$(KcService "$old")" -w 2>/dev/null); then
                tmp=$(mktemp) && printf '%s' "$creds" > "$tmp" && WriteCreds "${rest[0]}" "$tmp" &&
                    security delete-generic-password -a "$(KcAccount)" -s "$(KcService "$old")" >/dev/null 2>&1
                rm -f "$tmp"
            fi
        fi
        echo "Renamed '$name' to '${rest[0]}'"
        ;;
    remove)
        name=$(Resolve "$name") || exit 1
        dir=$(ProfileDir "$name") || exit 1
        [ -n "$dir" ] || die "'home' is ~/.claude and can't be removed"
        if ! Has -y "${rest[@]}"; then
            printf "Delete '%s' and ALL its data (login, sessions, history)? Type the name to confirm: " "$name"
            read -r ans
            [ "$ans" = "$name" ] || die 'Cancelled, nothing deleted'
        fi
        rm -rf "$dir" || exit 1
        [ -n "$isMac" ] && security delete-generic-password -a "$(KcAccount)" -s "$(KcService "$dir")" >/dev/null 2>&1
        [ "$(DefaultName)" = "$name" ] && rm -f "$defFile"   # default falls back to home
        Retarget "$dir" ''                                      # if it was active, back to home
        echo "Removed '$name'"
        ;;
    perm)
        name=$(Resolve "$name") || exit 1
        cfg=$(ConfigPath "$name") || exit 1
        if [ ${#rest[@]} -gt 0 ]; then SetPerm "$cfg" "${rest[0]}" || exit 1; fi
        echo "'$name' permissions: $(GetPerm "$cfg")"
        ;;
    note)   # ccp note <name> [text...] | --clear
        name=$(Resolve "$name") || exit 1
        f=$(NotePath "$name") || exit 1
        if Has --clear "${rest[@]}"; then
            rm -f "$f"; echo "Cleared note for '$name'"
        elif [ ${#rest[@]} -gt 0 ]; then
            text=$(printf '%s ' "${rest[@]}" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
            mkdir -p "$(dirname "$f")" && printf '%s' "$text" > "$f"
            echo "Note for '$name': $text"
        else
            note=$(GetNote "$name")
            if [ -n "$note" ]; then echo "$note"; else echo "No note for '$name'. Set one: ccp note $name <text>"; fi
        fi
        ;;
    usage)
        Opts
        who=; for o in "${opts[@]}"; do [ "$o" != --json ] && { who=$o; break; }; done
        if [ -n "$who" ]; then list=$(Resolve "$who") || exit 1; ProfileDir "$list" >/dev/null || exit 1
        else list=$(Names); fi
        if Has --json "${opts[@]}"; then   # always an array, one line, even for a single profile
            while IFS= read -r n; do Usage "$n"; done <<<"$list" | jq -c -s .
        else
            w=$(awk '{ if (length($0) > m) m = length($0) } END { print m }' <<<"$list")
            while IFS= read -r n; do
                r=$(Usage "$n")
                line="$(jq -r .index <<<"$r") $(printf "%-${w}s" "$n")  $(UsageText "$r")"
                [ "$(jq -r .pool <<<"$r")" = false ] && line+='  [pool off]'
                note=$(jq -r '.note // empty' <<<"$r")
                [ -n "$note" ] && line+="  # $note"
                echo "$line"
            done <<<"$list"
        fi
        ;;
    backup)   # ccp backup [file] [-p | --password] [--only <name>] [--creds], in any order
        Opts
        only=; file=; enc=; creds=; skip=
        for o in "${opts[@]}"; do
            if [ -n "$skip" ]; then only=$o; skip=; continue; fi
            case $o in
                --only) skip=1 ;;
                -p | --password) enc=1 ;;
                --creds) creds=1 ;;
                *) [ -z "$file" ] && file=$o ;;
            esac
        done
        [ -n "$skip" ] && die '--only needs a profile name'
        names=$(Names | tail -n +2)
        if [ -n "$only" ]; then
            n=$(Resolve "$only") || exit 1
            d=$(ProfileDir "$n") || exit 1
            [ -n "$d" ] || die "'home' is ~/.claude and isn't part of backups"
            names=$n
        fi
        files=$acctFiles; [ -n "$creds" ] && files=$credFiles
        [ -n "$enc" ] && ossl=$(Openssl)
        if [ -z "$file" ]; then
            mkdir -p "$base/backups" || exit 1
            file="$base/backups/ccp-$(Stamp)"
            [ -n "$creds" ] && file+=-creds
            file+=.zip
            [ -n "$enc" ] && file+=.enc
        fi
        case $file in /*) ;; *) file="$PWD/$file" ;; esac
        [ -e "$file" ] && die "'$file' already exists"
        umask 077   # login tokens: nothing below is readable by other users
        tmp=$(mktemp -d) || exit 1
        trap 'rm -rf "$tmp"' EXIT
        entries=(); saved=0
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            got=
            for f in $files; do
                mkdir -p "$tmp/z/$n"
                if [ "$f" = .credentials.json ]; then   # the live login: on macOS that is the keychain
                    c=$(ReadCreds "$n")
                    [ -n "$c" ] && printf '%s' "$c" > "$tmp/z/$n/$f"
                elif [ -f "$root/$n/$f" ]; then cp "$root/$n/$f" "$tmp/z/$n/$f"; fi
                [ -f "$tmp/z/$n/$f" ] && { entries+=("$n/$f"); got=1; }
            done
            if [ -n "$got" ]; then saved=$((saved + 1))
            elif [ -n "$creds" ]; then echo "Skipped '$n': no login to save (an API-key profile keeps its key in settings.json; back it up without --creds)"; fi
        done <<<"$names"
        [ ${#entries[@]} -gt 0 ] || die 'No profiles to back up'
        pw=; [ -n "$enc" ] && pw=$(AskPassword twice)
        (cd "$tmp/z" && zip -q -X -D "$tmp/b.zip" "${entries[@]}") || die 'zip failed'
        if [ -n "$enc" ]; then Encrypt "$tmp/b.zip" "$pw" "$tmp/b.enc" || exit 1; mv "$tmp/b.enc" "$file"
        else mv "$tmp/b.zip" "$file"; fi || exit 1
        what=''; [ -n "$creds" ] && what=' (logins only)'
        echo "Backed up $saved profile(s)$what to $file"
        if [ -n "$enc" ]; then echo 'Encrypted: without the password it cannot be restored.'
        else echo 'It contains login tokens: keep it private (or encrypt it: ccp backup -p).'; fi
        ;;
    restore)   # ccp restore <file> [-y] [--only <name>] [--creds]; encrypted backups are detected and ask for the password
        Opts
        only=; file=; yes=; creds=; skip=
        for o in "${opts[@]}"; do
            if [ -n "$skip" ]; then only=$o; skip=; continue; fi
            case $o in
                --only) skip=1 ;;
                -y) yes=1 ;;
                -p | --password) ;;   # encryption is detected; the flag is accepted for cxp parity
                --creds) creds=1 ;;
                *) [ -z "$file" ] && file=$o ;;
            esac
        done
        [ -n "$skip" ] && die '--only needs a profile name'
        [ -n "$file" ] || die 'Missing backup file'
        [ -f "$file" ] || die "No backup file '$file'"
        umask 077
        tmp=$(mktemp -d) || exit 1
        trap 'rm -rf "$tmp"' EXIT
        zipf=$file
        if IsEncrypted "$file"; then ossl=$(Openssl); Decrypt "$file" "$(AskPassword)" "$tmp/b.zip"; zipf=$tmp/b.zip; fi
        list=$(unzip -Z1 "$zipf" 2>/dev/null) || die "Not a ccp backup: '$file' is not a zip"
        # only <profile>/<account file> entries: nothing in the zip can land outside profiles/
        while IFS= read -r e; do
            p=${e%%/*}; f=${e#*/}
            if [ "$p" = "$e" ] || [[ $f == */* ]] || [[ $f == *\\* ]] || [[ $p == *\\* ]] ||
                [[ $acctFiles != *" $f "* ]] || ! [[ $p =~ $nameRe ]] || [[ $p =~ ^([0-9]+|home|default)$ ]]; then
                die "Not a ccp backup: unexpected entry '$e'"
            fi
        done <<<"$list"
        groups=$(sed 's|/.*||' <<<"$list" | awk '!seen[$0]++')
        if [ -n "$only" ]; then   # matched by the name inside the backup, not a local list number
            grep -qxF -- "$only" <<<"$groups" || die "No profile '$only' in this backup (it has: $(paste -sd, - <<<"$groups" | sed 's/,/, /g'))"
            groups=$only
        fi
        files=$acctFiles; [ -n "$creds" ] && files=$credFiles
        while IFS= read -r g; do
            dir=$root/$g
            want=()
            for f in $files; do grep -qxF -- "$g/$f" <<<"$list" && want+=("$f"); done
            if [ ${#want[@]} -eq 0 ]; then echo "Skipped '$g': no login in this backup"; continue; fi
            if [ -d "$dir" ] && [ -z "$yes" ]; then
                if [ -n "$creds" ]; then echo "Skipped '$g': already exists (-y overwrites its login)"
                else echo "Skipped '$g': already exists (-y overwrites its login and settings)"; fi
                continue
            fi
            mkdir -p "$dir" || exit 1
            for f in "${want[@]}"; do
                unzip -p "$zipf" "$g/$f" > "$tmp/x" || die "Could not read '$g/$f' from the backup"
                if [ "$f" = .credentials.json ]; then WriteCreds "$g" "$tmp/x" || exit 1   # keychain on macOS
                else cp "$tmp/x" "$dir/$f"; fi
            done
            if [ -n "$creds" ]; then echo "Restored login for '$g'"; else echo "Restored '$g'"; fi
        done <<<"$groups"
        ;;
    install)   # make `ccp` a command in every new terminal; safe to re-run
        chmod +x "$self_dir/ccp.bash"
        # a shell function, not just a command on PATH: a child process can't switch the shell's profile
        line="source \"$self_dir/ccp.sh\""
        shell=$(basename "${SHELL:-}")
        rcs=()
        [ "$shell" = zsh ] || [ -f "$HOME/.zshrc" ] && rcs+=(.zshrc)
        if [ "$shell" = bash ] || [ -f "$HOME/.bashrc" ]; then
            rcs+=(.bashrc)
            # macOS terminals start bash as a login shell, which reads .bash_profile and not .bashrc
            [ -n "$isMac" ] && [ "$shell" = bash ] && rcs+=(.bash_profile)
        fi
        [ ${#rcs[@]} -gt 0 ] || rcs=(.profile)
        for rc in "${rcs[@]}"; do
            if [ -f "$HOME/$rc" ] && grep -qF '/ccp.sh' "$HOME/$rc"; then echo "Already in ~/$rc"
            else printf '\n%s\n' "$line" >> "$HOME/$rc"; echo "Added to ~/$rc"; fi
        done
        echo 'Done. Open a new terminal (or source your shell rc file), then run: ccp list'
        ;;
    *)
        cat <<'EOF'
ccp install            make `ccp` a command in new bash and zsh terminals (run once)
ccp list [--json]      show profiles (* = active in this terminal)
ccp add <name>         create a profile and log in to it
ccp add <name> --key   same, but with an Anthropic API key instead of a login
                       (prompts for it; or pass it: --key sk-ant-...; --api-key works too)
ccp use [name] [--local]
                       switch (this terminal + all new ones); no name = default;
                       --local switches this terminal only
ccp run <name> [--perm <mode>] [args]
                       run claude once under a profile without switching;
                       --perm overrides the permission mode for this run only
ccp path <name>        print the profile's config folder
ccp default [name]     show / pick the default profile
ccp perm <name> [mode] show / set permissions: bypass (no prompts), auto, edits
                       (auto-accept file edits), ask, plan (read-only; also
                       accepted as readonly). New profiles get auto.
ccp usage [name]       how much of the 5-hour and weekly subscription limits each
                       profile has used, and when they reset (no name = all);
                       add --json for scripts
ccp pool <name> [on|off]
                       show / set whether `ccp pick` may choose this profile
ccp pick [-n <count>] [--json]
                       print the pool profile(s) with the most room left
ccp note <name> [text] show / set a one-line note on a profile (--clear removes it);
                       notes appear in `ccp list` and `ccp usage`
ccp rename <old> <new> rename a profile
ccp remove <name> [-y] delete a profile and all its data (-y skips the prompt)
ccp backup [file] [-p] save every profile's login + settings to a zip (default: ./backups/);
                       -p (or --password) encrypts it with a password you type
ccp restore <file> [-y] bring profiles back from a backup (-y overwrites existing ones);
                       asks for the password if the backup is encrypted
                       Both take --only <name> to save / bring back a single profile,
                       and --creds to save / bring back only the logins (no settings,
                       notes or data).
"home" is your original ~/.claude. Anywhere a name goes you can also give
"default" or the number from `ccp list` (ccp use 2).
EOF
        ;;
esac
