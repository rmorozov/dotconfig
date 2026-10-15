#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
inspector="$repo_root/scripts/credentials-inspect.py"
log_checker="$repo_root/scripts/credentials-logs.py"

usage() {
    cat <<'EOF'
Usage: dotconfig creds status
       dotconfig creds check-logs [--days N] [--examples N]
       dotconfig creds clear [--purge [--yes]]

status  Show what SSSD and Kerberos have cached for domain logins, without secrets.
check-logs
        Search SSSD, PAM, Kerberos, and VPN logs from the last N days (default 7)
        for known login problems and judge the likely cause. --examples sets
        how many log lines to quote per finding (default 1).
clear   Destroy your Kerberos tickets and mark SSSD identity entries stale.
        Cached passwords for offline login are kept.
--purge Also stop SSSD and move its whole cache aside, including cached passwords.
        The next domain login must then reach a domain controller (VPN up).
EOF
}

# Runs a helper script as root with the filesystem root appended to its arguments.
as_root() {
    as_root_command python3 "$@" "${DOTCONFIG_CREDS_TEST_ROOT:-/}"
}

as_root_command() {
    if [[ -n "${DOTCONFIG_CREDS_TEST_ROOT:-}" || "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

[[ "$(uname -s)" == Linux || -n "${DOTCONFIG_CREDS_TEST_ROOT:-}" ]] || {
    echo 'dotconfig creds manages SSSD on Linux; on macOS use kdestroy -A.' >&2
    exit 1
}

case "${1:-}" in
    status)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        as_root "$inspector" inspect
        echo "Kerberos tickets for $(id -un):"
        if ! command -v klist >/dev/null 2>&1; then
            echo '  klist not installed (krb5-user)'
        elif ! klist -l 2>/dev/null; then
            echo '  none'
        fi
        ;;
    check-logs)
        shift
        days=7
        examples=1
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --days|--examples)
                    [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
                    if [[ "$1" == --days ]]; then days="$2"; else examples="$2"; fi
                    shift
                    ;;
                *) usage >&2; exit 2 ;;
            esac
            shift
        done
        as_root "$log_checker" --days "$days" --examples "$examples"
        ;;
    clear)
        shift
        purge=false
        confirmed=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --purge) purge=true ;;
                --yes) confirmed=true ;;
                *) usage >&2; exit 2 ;;
            esac
            shift
        done
        [[ "$confirmed" == false || "$purge" == true ]] || { usage >&2; exit 2; }
        if [[ "$purge" == true && "$confirmed" == false ]]; then
            echo 'Purging removes cached passwords: domain login will need the VPN until the next online login.'
            read -r -p 'Type "purge" to continue: ' answer
            [[ "$answer" == purge ]] || { echo 'Purge cancelled; nothing changed.'; exit 1; }
        fi
        if command -v kdestroy >/dev/null 2>&1; then
            kdestroy -A 2>/dev/null || :
            echo 'Kerberos: destroyed your ticket caches'
        fi
        if command -v sss_cache >/dev/null 2>&1; then
            as_root_command sss_cache -E
            echo 'SSSD: marked cached users and groups stale; cached passwords kept'
        else
            echo 'SSSD: sss_cache not installed; skipping'
        fi
        if [[ "$purge" == true ]]; then
            as_root "$inspector" purge
        fi
        ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
