#!/usr/bin/env bash
# Integration checks for ccp.bash with isolated profiles (CCP_ROOT) and a fake claude.
# Nothing here logs in, calls the usage endpoint, or touches ~/.claude: home is taken out of
# the pool first, and the test profiles are API-key profiles, which need no lookup.
# On macOS the --creds checks use a throwaway keychain item, deleted at the end. Run: bash tests/ccp.bash
script=$(cd "$(dirname "$0")/.." && pwd -P)/ccp.bash
fixture=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ccp-test-XXXXXX")" && pwd -P)
isMac=; [ "$(uname -s)" = Darwin ] && isMac=1
svc() { echo "Claude Code-credentials-$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; }
cleanup() {
    [ -n "$isMac" ] && for d in "$fixture"/profiles/*/; do
        security delete-generic-password -a "$USER" -s "$(svc "${d%/}")" >/dev/null 2>&1
    done
    rm -rf "$fixture"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ccp() { "$script" "$@"; }

mkdir -p "$fixture/bin"
# fake claude: records the profile it ran under and its arguments, then fails with 7
printf '#!/bin/sh\necho "[${CLAUDE_CONFIG_DIR-}] $*" > "%s/ran"\nexit 7\n' "$fixture" > "$fixture/bin/claude"
chmod +x "$fixture/bin/claude"
export PATH="$fixture/bin:$PATH" CCP_ROOT=$fixture
unset CLAUDE_CONFIG_DIR CCP_PASSWORD
a=$fixture/profiles/a

ccp pool home off >/dev/null
[ -f "$fixture/profiles/.home-pool-off" ] || fail 'CCP_ROOT ignored: home pool marker is not in the fixture'

# add: both spellings of the key flag, and the safe default mode
mkdir -p "$fixture/home/.claude/skills/demo" "$fixture/home/.claude/skills/synced"
HOME=$fixture/home ccp add a --key sk-ant-test-a >/dev/null
ccp add b --api-key sk-ant-test-b >/dev/null
[ "$(jq -r .env.ANTHROPIC_API_KEY "$a/settings.json")" = sk-ant-test-a ] || fail 'add --key did not store the key'
[ "$(jq -r .env.ANTHROPIC_API_KEY "$fixture/profiles/b/settings.json")" = sk-ant-test-b ] || fail 'add --api-key did not store the key'
[ "$(jq -r .permissions.defaultMode "$a/settings.json")" = auto ] || fail 'New profiles should start in auto'
[ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$a/settings.json")" = false ] || fail 'New profiles should not skip the bypass warning'
[ "$(readlink "$a/skills/demo")" = "$fixture/home/.claude/skills/demo" ] || fail 'add did not link the home skill'
[ ! -e "$a/skills/synced" ] || fail 'add should leave synced/ out'

# list --json
listed=$(ccp list --json)
[ "$(jq -r '[.[].name] | join(",")' <<<"$listed")/$(jq -r '[.[].number] | join(",")' <<<"$listed")" = home,a,b/1,2,3 ] || fail 'List JSON order / numbers wrong'
[ "$(jq -r '.[1] | "\(.path),\(.permissions)"' <<<"$listed")" = "$a,auto" ] || fail 'List JSON path / permissions wrong'
[ "$(jq -r '"\(.[0].pool),\(.[1].pool)"' <<<"$listed")" = false,true ] || fail 'List JSON pool wrong'
[ "$(jq '.[1].note' <<<"$listed")" = null ] || fail 'A missing note should be null in JSON'
ccp note a team account >/dev/null
[ "$(ccp list --json | jq -r '.[1].note')" = 'team account' ] || fail 'List JSON omitted note'
[ "$(ccp path 2)" = "$a" ] && [ "$(ccp path a --env)" = "$a" ] || fail 'path wrong'
[ -z "$(ccp path home --env)" ] || fail 'path --env should print nothing for home'

# usage --json: old fields kept, shared fields added
u=$(ccp usage a --json)
[ "$(jq -r '"\(length),\(.[0].index),\(.[0].profile),\(.[0].status)"' <<<"$u")" = 1,2,a,no_login ] || fail 'Usage JSON contract changed'
[ "$(jq -r '.[0] | "\(.number),\(.path),\(.pool)"' <<<"$u")" = "2,$a,true" ] || fail 'Usage JSON shared fields wrong'
[ "$(jq -r '.[0] | "\(.available),\(.headroom_percent)"' <<<"$u")" = true,null ] || fail 'API-key profile should be available with unknown headroom'
mkdir "$fixture/profiles/c"   # no login at all
[ "$(ccp usage c --json | jq '.[0].available')" = false ] || fail 'A profile without a login should not be available'

# pool + pick
[ "$(ccp pick)" = a ] || fail 'pick should return the first available pool profile'
[ "$(ccp pick -n 5 | paste -sd, -)" = a,b ] || fail 'pick -n should list every available pool profile, not home or c'
ccp pool a off >/dev/null
[ "$(ccp pick)" = b ] || fail 'pick ignored pool off'
ccp list | grep -q 'a \[auto\] \[pool off\]' || fail 'list does not show pool off'
[ "$(ccp pick --json | jq -r '"\(length),\(.[0].profile),\(.[0].available)"')" = 1,b,true ] || fail 'pick --json wrong'
ccp pool b off >/dev/null
ccp pick >/dev/null 2>&1; [ $? = 1 ] || fail 'pick with an empty pool should fail'
ccp pool b on >/dev/null

# run: profile isolation, exit code, --perm
ccp run a -p hi; [ $? = 7 ] || fail 'run did not pass on the exit code'
[ "$(cat "$fixture/ran")" = "[$a] -p hi" ] || fail 'run changed the arguments or the profile'
[ -z "${CLAUDE_CONFIG_DIR-}" ] || fail 'run changed this terminal'
ccp run a --perm readonly -p hi
[ "$(cat "$fixture/ran")" = "[$a] --permission-mode plan -p hi" ] || fail 'run --perm readonly wrong'
ccp run a --perm ask -p hi
[ "$(cat "$fixture/ran")" = "[$a] --permission-mode manual -p hi" ] || fail 'run --perm ask wrong'
[ "$(jq -r .permissions.defaultMode "$a/settings.json")" = auto ] || fail 'run --perm changed the saved mode'
rm "$fixture/ran"
ccp run a --perm nonsense -p hi 2>/dev/null; [ $? = 1 ] && [ ! -f "$fixture/ran" ] || fail 'run with a bad --perm should fail before starting claude'

# perm: readonly is plan
ccp perm a readonly >/dev/null
[ "$(ccp list --json | jq -r '.[1].permissions')" = plan ] || fail 'perm readonly should set plan'

# use: --local saves nothing; plain use saves under CCP_ROOT; rename / remove repoint it
ccp use a --local >/dev/null
ccp path --saved >/dev/null; [ $? = 2 ] || fail 'use --local changed the saved setting'
ccp use b >/dev/null
[ "$(ccp path --saved)" = "$fixture/profiles/b" ] || fail 'use did not save the profile'
for sh in bash zsh; do   # the shell wrapper switches this shell
    command -v $sh >/dev/null || continue
    got=$($sh -c "source '$(dirname "$script")/ccp.sh'; ccp use a --local >/dev/null; echo \"\$CLAUDE_CONFIG_DIR\"")
    [ "$got" = "$a" ] || fail "ccp.sh under $sh: use --local did not set CLAUDE_CONFIG_DIR ($got)"
    got=$($sh -c "source '$(dirname "$script")/ccp.sh'; echo \"\$CLAUDE_CONFIG_DIR\"")
    [ "$got" = "$fixture/profiles/b" ] || fail "ccp.sh under $sh: new shells did not start on the saved profile"
    got=$($sh -c "source '$(dirname "$script")/ccp.sh'; ccp use home >/dev/null; echo \"[\${CLAUDE_CONFIG_DIR-unset}]\"")
    [ "$got" = '[unset]' ] || fail "ccp.sh under $sh: use home did not unset CLAUDE_CONFIG_DIR"
    ccp use b >/dev/null
done
ccp rename b b2 >/dev/null
[ "$(ccp path --saved)" = "$fixture/profiles/b2" ] || fail 'rename did not repoint the saved setting'
ccp remove b2 -y >/dev/null
[ "$(ccp path --saved)" = '' ] || fail 'remove did not send the saved setting back to home'

# backup (--password spelling, default folder under CCP_ROOT) keeps key, note and pool
export CCP_PASSWORD=test-password
ccp backup --password >/dev/null
file=$(ls "$fixture"/backups/*.zip.enc)
[ "$(wc -l <<<"$file" | tr -d ' ')" = 1 ] || fail 'backup --password did not write an encrypted file under CCP_ROOT'
ccp remove a -y >/dev/null
ccp restore "$file" --only a >/dev/null
[ "$(ccp list --json | jq -r '.[1] | "\(.name),\(.note),\(.pool),\(.permissions)"')" = 'a,team account,false,plan' ] || fail 'Backup lost note, pool or settings'
CCP_PASSWORD=wrong ccp restore "$file" -y >/dev/null 2>&1 && fail 'A wrong password should be rejected'

# --creds: only the login goes in and comes back; on macOS it lives in the keychain
mkdir "$fixture/profiles/k"
k=$fixture/profiles/k
login='{"claudeAiOauth":{"accessToken":"tok-1","refreshToken":"r","expiresAt":1}}'
if [ -n "$isMac" ]; then
    printf 'add-generic-password -U -a "%s" -s "%s" -X %s\n' "$USER" "$(svc "$k")" "$(printf '%s' "$login" | od -An -tx1 | tr -d ' \n')" | security -i
    echo '{"claudeAiOauth":{"accessToken":"stale-file"}}' > "$k/.credentials.json"   # the keychain wins, as in claude
else
    echo "$login" > "$k/.credentials.json"
fi
echo '{"theme":"dark"}' > "$k/settings.json"
ccp backup --creds --only k "$fixture/creds.zip" >/dev/null
[ "$(unzip -Z1 "$fixture/creds.zip")" = k/.credentials.json ] || fail 'backup --creds saved more than the login'
[ "$(unzip -p "$fixture/creds.zip" k/.credentials.json | jq -r .claudeAiOauth.accessToken)" = tok-1 ] || fail 'backup --creds did not take the live login'
ccp remove k -y >/dev/null
if [ -n "$isMac" ]; then security find-generic-password -a "$USER" -s "$(svc "$k")" >/dev/null 2>&1 && fail 'remove left the keychain login behind'; fi
ccp restore "$fixture/creds.zip" --creds >/dev/null
if [ -n "$isMac" ]; then got=$(security find-generic-password -a "$USER" -s "$(svc "$k")" -w); else got=$(cat "$k/.credentials.json"); fi
[ "$(jq -r .claudeAiOauth.accessToken <<<"$got")" = tok-1 ] || fail 'restore --creds did not bring the login back'
[ ! -f "$k/settings.json" ] || fail 'restore --creds brought back settings'
ccp restore "$fixture/creds.zip" --creds | grep -q 'Skipped' || fail 'restore --creds should not overwrite without -y'
ccp restore "$file" --only a --creds | grep -q "Skipped 'a': no login" || fail 'restore --creds of an API-key profile should skip it'
echo 'PASS: CCP_ROOT, add flags, auto default, home skills, list JSON, path, usage shared fields, pool, pick, run --perm, exit code,'
echo '      use / --local / saved setting, wrapper (bash, zsh), rename, remove, backup, wrong password, --creds'
