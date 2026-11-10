# ccp for Git Bash. `ccp.ps1 install` adds this to ~/.bashrc:  source "F:/claude-profiles/ccp.sh"
# Thin wrapper over ccp.ps1 (one implementation); only adds what a child
# process can't do: updating CLAUDE_CONFIG_DIR in this shell after `use`.
CCP_DIR="$(cygpath -w "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"

ccp() {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CCP_DIR\\ccp.ps1" "$@" || return
    # after use, or when rename/remove took this shell's profile folder away
    if [ "$1" = use ] || { [ -n "$CLAUDE_CONFIG_DIR" ] && [ ! -d "$CLAUDE_CONFIG_DIR" ]; }; then
        # read back what `use` just persisted, so "default"/no-name resolve in one place
        CLAUDE_CONFIG_DIR="$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR','User')" | tr -d '\r')"
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then export CLAUDE_CONFIG_DIR; else unset CLAUDE_CONFIG_DIR; fi
    fi
}
