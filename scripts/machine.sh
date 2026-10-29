#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/machine-status.py"

usage() {
    cat <<'EOF_USAGE'
Usage: dotconfig machine status [--sudo] [--user NAME] [--probe HOST[:PORT]]... [--boot N] [--examples N]

status  Report the health of this Ubuntu machine: failed and unloadable units and why, boot and
        login timing, journal and kernel errors, crashes, disks, memory, network, time sync,
        domain login, packages, snaps, AppArmor, batteries, and temperatures.
--sudo  Run as root through sudo to add the system journal, SMART health, AppArmor profiles,
        the firewall, the unattended-upgrades log, and the dotconfig creds checks. Without it,
        anything that needs root is listed as not checked.
--user NAME
        Inspect this account instead of the invoking one: its home, sessions, runtime
        directory, user manager, dotconfig installation, and proxy settings. Inspecting
        another account needs --sudo.
--probe HOST[:PORT]
        Test reaching HOST (port 443 by default) step by step: DNS, TCP, the proxy tunnel,
        and TLS verification. Repeat to probe several endpoints.
--boot N
        Read the journal of boot N: 0 is this boot (default), -1 the one before.
--examples N
        Log lines to quote per finding (default 1).
EOF_USAGE
}

[[ "$(uname -s)" == Linux || -n "${DOTCONFIG_MACHINE_TEST_ROOT:-}" ]] || {
    echo 'dotconfig machine status checks Ubuntu machines; on macOS it is not available yet.' >&2
    exit 1
}

case "${1:-}" in
    status)
        shift
        use_sudo=false
        options=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --sudo) use_sudo=true ;;
                --user)
                    [[ $# -ge 2 && "$2" =~ ^[A-Za-z0-9._@-]+$ ]] || { usage >&2; exit 2; }
                    options+=(--user "$2")
                    shift
                    ;;
                --probe)
                    [[ $# -ge 2 && "$2" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { usage >&2; exit 2; }
                    options+=(--probe "$2")
                    shift
                    ;;
                --boot)
                    [[ $# -ge 2 && "$2" =~ ^(0|-[1-9][0-9]*)$ ]] || { usage >&2; exit 2; }
                    options+=(--boot "$2")
                    shift
                    ;;
                --examples)
                    [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
                    options+=(--examples "$2")
                    shift
                    ;;
                *) usage >&2; exit 2 ;;
            esac
            shift
        done
        root="${DOTCONFIG_MACHINE_TEST_ROOT:-/}"
        if [[ "$use_sudo" == true && -z "${DOTCONFIG_MACHINE_TEST_ROOT:-}" && "$EUID" -ne 0 ]]; then
            exec sudo python3 "$checker" ${options[@]+"${options[@]}"} "$root"
        fi
        exec python3 "$checker" ${options[@]+"${options[@]}"} "$root"
        ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
