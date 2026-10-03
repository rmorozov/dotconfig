#!/usr/bin/env bash
# Shared installer messages. Deliberately avoid shell tracing or environment dumps.
install_stage='initialization'
install_started=$SECONDS
install_stage_started=$SECONDS
install_verbose=${install_verbose:-false}

install_failure() {
    local status="$1" line="$2"
    printf '\n[dotconfig] FAILED: %s (exit %s, line %s, elapsed %ss).\n' \
        "$install_stage" "$status" "$line" "$((SECONDS - install_started))" >&2
    echo '[dotconfig] Installation did not complete. Review the error output above and fix this stage before retrying.' >&2
    echo '[dotconfig] If configuration was deployed, open a new Zsh session and run dotconfig doctor for further checks.' >&2
    exit "$status"
}
trap 'install_failure "$?" "$LINENO"' ERR

install_step() {
    if "$install_verbose"; then
        printf '[dotconfig] Finished %s in %ss.\n' "$install_stage" "$((SECONDS - install_stage_started))" >&2
    fi
    install_stage="$1"
    install_stage_started=$SECONDS
    printf '[dotconfig] %s\n' "$install_stage" >&2
}

install_details() {
    "$install_verbose" || return 0
    printf '[dotconfig] Platform: %s / %s; home: %s\n' "$(uname -s)" "$(uname -m)" "$HOME" >&2
    printf '[dotconfig] Checkout: %s\n' "$1" >&2
}

install_success() {
    if "$install_verbose"; then
        printf '[dotconfig] Finished %s in %ss.\n' "$install_stage" "$((SECONDS - install_stage_started))" >&2
    fi
    printf '\n[dotconfig] SUCCESS: %s (elapsed %ss).\n' "$1" "$((SECONDS - install_started))"
    echo '[dotconfig] Open a new Zsh session and run dotconfig doctor to check the installed configuration.'
}
