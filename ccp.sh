# ccp for bash and zsh: Git Bash on Windows, and macOS / Linux. `ccp install` adds
# `source "<this folder>/ccp.sh"` to your shell's rc file.
# Thin wrapper over the implementation (ccp.ps1 on Windows, ccp.bash elsewhere); it only adds
# what a child process can't do: updating CLAUDE_CONFIG_DIR in this shell after `use`.
if [ -n "$ZSH_VERSION" ]; then eval 'CCP_DIR=${${(%):-%x}:A:h}'
else CCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; fi
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) CCP_WIN=1; CCP_DIR="$(cygpath -w "$CCP_DIR")" ;;
    *) CCP_WIN= ;;
esac

_ccp() {
    if [ -n "$CCP_WIN" ]; then powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CCP_DIR\\ccp.ps1" "$@"
    else "$CCP_DIR/ccp.bash" "$@"; fi
}

_ccp_saved() {   # what `ccp use` saved for new terminals; fails if nothing was saved
    if [ -n "$CCP_WIN" ]; then
        powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR','User')" | tr -d '\r'
    else _ccp path --saved 2>/dev/null; fi
}

_ccp_set() {
    CLAUDE_CONFIG_DIR="$1"
    if [ -n "$CLAUDE_CONFIG_DIR" ]; then export CLAUDE_CONFIG_DIR; else unset CLAUDE_CONFIG_DIR; fi
}

ccp() {
    _ccp "$@" || return
    local v
    case " $* " in *" --local "*) local in_local=1 ;; *) local in_local= ;; esac
    if [ "$1" = use ] && [ -n "$in_local" ]; then
        # this shell only: ask ccp what the variable should be (nothing for home)
        shift
        v="$(_ccp path --env "$@" | tr -d '\r')" || return
    # after use, or when rename/remove took this shell's profile folder away
    elif [ "$1" = use ] || { [ "$1" = repair ] && [[ " $* " == *" --apply "* ]]; } || { [ -n "$CLAUDE_CONFIG_DIR" ] && [ ! -d "$CLAUDE_CONFIG_DIR" ]; }; then
        # read back what `use` just persisted, so "default"/no-name resolve in one place
        v="$(_ccp_saved)"
    else
        return 0
    fi
    _ccp_set "$v"
}

# New terminals start on the profile `ccp use` saved (Windows does this through a user variable).
if [ -z "$CCP_WIN" ] && _ccp_saved_v="$(_ccp_saved)"; then _ccp_set "$_ccp_saved_v"; fi
unset _ccp_saved_v
