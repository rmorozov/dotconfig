#!/usr/bin/env bash
# Runs dotconfig machine status on a real Ubuntu 26.04 machine, such as a CI runner, after seeding problems it must
# report: a failed service, a unit with a bad setting, journal and kernel errors, and a real PAM login session that
# starts a user manager. This checks the report against real systemd, journal, and PAM formats; the injected kernel,
# journal and auth lines are written with logger and /dev/kmsg, so only their parsing is checked, not their source.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${DOTCONFIG_MACHINE_LIVE_TEST:-}" == 1 ]] || {
    echo 'Refusing to seed failures: set DOTCONFIG_MACHINE_LIVE_TEST=1 on a disposable machine.' >&2
    exit 2
}
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
user=dotconfig-live

check() {
    grep -q -- "$1" "$out" || { echo "Missing: $1" >&2; exit 1; }
}
report() {
    local status=0
    "$@" > "$out" 2>&1 || status=$?
    cat "$out"
    [[ "$status" == 0 || "$status" == 1 || "$status" == 3 ]] || { echo "machine status exited $status" >&2; exit 1; }
    check '^Summary: '
    # Every problem names what to run next.
    if grep -E '^(warning|earlier|recovered): ' "$out" | grep -vE 'see: |run: |to rule it out: |try: '; then
        echo 'problems above have no next step' >&2
        exit 1
    fi
    if grep -q 'Traceback' "$out"; then
        echo 'machine status crashed' >&2
        exit 1
    fi
}

id "$user" >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash "$user"

# Each failing process lives a moment after it logs: journald reads a sender's unit from its cgroup, and a process
# that exits first leaves its lines without one.
sudo systemd-run --unit=dotconfig-live-fail --description='dotconfig live failure' \
    sh -c 'echo "live failure: cannot read /etc/dotconfig-live.conf" >&2; sleep 1; exit 3'
printf '[Unit]\nDescription=dotconfig live bad setting\n[Service]\nType=simple\n' |
    sudo tee /etc/systemd/system/dotconfig-live-bad.service > /dev/null
sudo systemctl daemon-reload
sudo systemctl start dotconfig-live-bad.service 2>/dev/null || :

# Expectations: a required unit installed but never enabled, a condition that skips another, and a declared mount
# that is absent while its directory is writable.
printf '[Unit]\nDescription=dotconfig live required\n[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' |
    sudo tee /etc/systemd/system/dotconfig-live-off.service > /dev/null
printf '[Unit]\nDescription=dotconfig live skipped\nConditionPathExists=/nonexistent/dotconfig\n[Service]\nExecStart=/bin/true\n' |
    sudo tee /etc/systemd/system/dotconfig-live-skip.service > /dev/null
sudo systemctl daemon-reload
sudo systemctl start dotconfig-live-skip.service
sudo mkdir -p /etc/dotconfig /mnt/dotconfig-live
sudo chmod 1777 /mnt/dotconfig-live
printf 'require dotconfig-live-off.service\nrequire dotconfig-live-skip.service\nmount /mnt/dotconfig-live\n' |
    sudo tee /etc/dotconfig/machine-expect > /dev/null

for count in 1 2 3; do
    logger -p user.err -t dotconfig-live "injected journal error $count"
done
logger -p user.crit -t dotconfig-live-crit 'injected critical error'
for count in 1 2 3; do
    printf '<3>dotconfig-live: injected kernel error %s\n' "$count" | sudo tee /dev/kmsg > /dev/null
done
printf '<3>Out of memory: Killed process 4242 (dotconfig-live) total-vm:1000kB\n' | sudo tee /dev/kmsg > /dev/null
logger -p authpriv.notice -t login \
    "pam_unix(login:auth): authentication failure; logname= uid=0 euid=0 tty=/dev/tty3 ruser= rhost=  user=$user"
# A real PAM session through the login service: pam_systemd registers it and starts the user manager.
sudo systemd-run --wait --quiet -p PAMName=login -p User="$user" /bin/sleep 3
# A failed unit in the account's own user manager, kept running by lingering, for the --sudo user-unit lookup.
uid="$(id -u "$user")"
sudo loginctl enable-linger "$user"
sudo systemctl start "user@$uid.service"
sudo systemd-run --user -M "$user@" --unit=dotconfig-live-user-fail \
    sh -c 'echo "user failure: cannot reach sync server" >&2; sleep 1; exit 4'
sleep 2

report bash "$repo_root/scripts/machine.sh" status
report bash "$repo_root/scripts/machine.sh" status --sudo --examples 2

check '^ok: Ubuntu 26.04'
# A fresh runner may still be starting, so either state is accepted.
grep -Eq '^(warning: systemd reports the system degraded|info: systemd is still starting)' "$out" ||
    { echo 'Missing: systemd state' >&2; exit 1; }
grep -Eq '^info: (Startup finished in |boot has not finished yet)' "$out" || { echo 'Missing: startup time' >&2; exit 1; }
check '^warning: dotconfig-live-fail.service failed (dotconfig live failure): its main process exited with an error, exited 3'
check '    log: live failure: cannot read /etc/dotconfig-live.conf'
check '^warning: dotconfig-live-bad.service was refused: Service has no ExecStart='
check '^info: dotconfig-live: 3 errors'
check '^earlier: dotconfig-live-crit: 1 error (1 critical)'
check '^earlier: the kernel OOM killer ended processes .*dotconfig-live'
check '    e.g. dotconfig-live: injected kernel error 3 (x3)'
check "^info: $user logged in through login .*; user services started in "
check "^recovered: 1 failed password attempt through login before $user logged in"
check '^ok: no half-installed packages'
check '^warning: dotconfig-live-off.service is disabled, so it does not start at boot'
check '^warning: dotconfig-live-skip.service was skipped: a start condition was not met'
check '^warning: /mnt/dotconfig-live is expected to be mounted (/etc/dotconfig/machine-expect) but is not; its directory is writable'
if grep -q '^not checked: .*needs root' "$out"; then
    echo 'The --sudo run still skipped root-only checks' >&2
    exit 1
fi
# As if the account itself had run --sudo: its user manager and its own user-unit journal records are inspected.
report sudo env SUDO_USER="$user" SUDO_UID="$uid" bash "$repo_root/scripts/machine.sh" status --sudo
check '^warning: dotconfig-live-user-fail.service failed .*: its main process exited with an error, exited 4'
check '    log: user failure: cannot reach sync server'
# Another account by name, plus a real endpoint taken step by step through DNS, TCP and TLS.
report bash "$repo_root/scripts/machine.sh" status --sudo --user "$user" --probe github.com
check "^Account and session ($user):"
check "^info: uid $uid, home "
check '^ok: probe github.com:443 (.*): TLS verified'
# polkit ships on the hosted image: its section reads the real rules, PAM service and journal format.
if systemctl cat polkit.service > /dev/null 2>&1; then
    check '^Administrator authorization (polkit, for '
    check '^info: polkit authenticates through: '
fi
# The indexer, when installed: real gsettings output for its schema, read as the account, and its user unit.
if [[ -x /usr/libexec/localsearch-3 ]]; then
    check '^File indexing (LocalSearch, for '
    check '^info: indexes .* with subfolders'
    grep -Eq '^info: exclusions: [0-9]+ folder patterns?, [0-9]+ file patterns?$' "$out" ||
        { echo 'Missing: indexer exclusions' >&2; exit 1; }
fi
echo 'machine status live tests passed'
