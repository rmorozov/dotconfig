#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export DOTCONFIG_MACHINE_TEST_ROOT="$test_dir/root"
root="$DOTCONFIG_MACHINE_TEST_ROOT"
stubs="$test_dir/bin"
mkdir -p "$root/etc/sssd" "$root/proc/sys/kernel" "$root/proc/self" "$root/proc/pressure" "$root/run" \
    "$root/var/crash" "$root/var/log/apt" "$root/var/log/unattended-upgrades" "$root/usr/lib/update-notifier" \
    "$root/sys/module/apparmor/parameters" "$root/sys/class/power_supply/BAT0" "$root/sys/class/thermal/thermal_zone0" \
    "$stubs"

printf 'PRETTY_NAME="Ubuntu 26.04.1 LTS"\nID=ubuntu\nVERSION_ID="26.04"\n' > "$root/etc/os-release"
printf '6.20.0-14-generic\n' > "$root/proc/sys/kernel/osrelease"
printf '95400.25 20000.00\n' > "$root/proc/uptime"
printf '12928\n' > "$root/proc/sys/kernel/tainted"
printf '/dev/nvme0n1p2 / ext4 ro,relatime 0 0\n/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n' > "$root/proc/self/mounts"
printf 'MemTotal: 16000000 kB\nMemAvailable: 1200000 kB\nSwapTotal: 4000000 kB\nSwapFree: 1000000 kB\n' \
    > "$root/proc/meminfo"
printf 'some avg10=1.00 avg60=2.00 avg300=9.00 total=1\nfull avg10=0.50 avg60=4.00 avg300=6.50 total=1\n' \
    > "$root/proc/pressure/memory"
touch "$root/run/reboot-required" "$root/var/crash/_usr_bin_gnome-shell.1000.crash"
printf 'linux-image-6.20.0-15-generic\n' > "$root/run/reboot-required.pkgs"
printf 'Start-Date: 2026-10-28  09:12:01\nCommandline: apt upgrade\nEnd-Date: 2026-10-28  09:13:10\n' \
    > "$root/var/log/apt/history.log"
printf '2026-10-28 06:30:01,123 WARNING Package linux-firmware is kept back\n' \
    > "$root/var/log/unattended-upgrades/unattended-upgrades.log"
printf '#!/usr/bin/env bash\nprintf "12;3" >&2\n' > "$root/usr/lib/update-notifier/apt-check"
chmod +x "$root/usr/lib/update-notifier/apt-check"
printf 'Y\n' > "$root/sys/module/apparmor/parameters/enabled"
printf '45000000\n' > "$root/sys/class/power_supply/BAT0/energy_full"
printf '80000000\n' > "$root/sys/class/power_supply/BAT0/energy_full_design"
printf '71\n' > "$root/sys/class/power_supply/BAT0/capacity"
printf 'Discharging\n' > "$root/sys/class/power_supply/BAT0/status"
printf '412\n' > "$root/sys/class/power_supply/BAT0/cycle_count"
printf '93000\n' > "$root/sys/class/thermal/thermal_zone0/temp"
printf 'x86_pkg_temp\n' > "$root/sys/class/thermal/thermal_zone0/type"
printf '[sssd]\ndomains = corp.example\nservices = nss, pam\n\n[domain/corp.example]\nid_provider = ad\n' \
    > "$root/etc/sssd/sssd.conf"
chmod 600 "$root/etc/sssd/sssd.conf"

# Update and next-boot readiness: stale lists, a stalled unattended-upgrades stamp, two kernels, a nearly full /boot.
# Load and limits: CPU and I/O pressure, cgroup memory and task limit events, a nearly full file table.
python3 - "$root" <<'EOF'
import email.utils, os, sys, time
from pathlib import Path

root = Path(sys.argv[1])
def write(relative, text="", days_old=0, size=0):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)
        if size:
            handle.truncate(size)
    stamp = time.time() - days_old * 86400
    os.utime(path, (stamp, stamp))

def released(days_ago, valid_days=None):
    def stamp(days):
        return email.utils.formatdate(time.time() - days * 86400, usegmt=True)
    text = f"Origin: Ubuntu\nDate: {stamp(days_ago)}\n"
    if valid_days is not None:
        text += f"Valid-Until: {stamp(-valid_days)}\n"
    return text + "\nsignature\n"
# File times of lists are publication dates, so they are set old on purpose; only the stamps record refreshes.
write("var/lib/apt/lists/archive.ubuntu.com_ubuntu_dists_resolute_InRelease", released(40), days_old=40)
write("var/lib/apt/lists/security.ubuntu.com_ubuntu_dists_resolute-security_InRelease", released(1), days_old=1)
write("var/lib/apt/lists/ppa.launchpadcontent.net_team_tool_ubuntu_dists_resolute_InRelease", released(10, -3),
      days_old=10)
write("var/lib/apt/periodic/update-success-stamp", days_old=10)
write("var/lib/apt/periodic/update-stamp", days_old=2)
write("var/lib/apt/periodic/unattended-upgrades-stamp", days_old=5)
write("etc/apt/apt.conf.d/20auto-upgrades", 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n')
for kernel in ("6.20.0-14-generic", "6.20.0-15-generic"):
    write(f"boot/vmlinuz-{kernel}", size=15 * 1024 * 1024)
write("boot/initrd.img-6.20.0-14-generic", size=90 * 1024 * 1024)
write("proc/pressure/cpu", "some avg10=50.00 avg60=45.00 avg300=42.00 total=1\n")
write("proc/pressure/io", "some avg10=9.00 avg60=8.00 avg300=7.00 total=1\nfull avg10=6.00 avg60=6.00 avg300=6.00 total=1\n")
# memory.events adds up the subtree, so slices repeat their children; the .local files count each cgroup once.
def cgroup(relative, local, total=None):
    write(f"sys/fs/cgroup/{relative}/memory.events.local", local)
    write(f"sys/fs/cgroup/{relative}/memory.events", total or local)
cgroup("system.slice", "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n", "max 6\noom 1\noom_kill 1\n")
cgroup("system.slice/backupd.service", "low 0\nhigh 0\nmax 4\noom 1\noom_kill 1\n")
cgroup("system.slice/cups.service", "low 0\nhigh 0\nmax 2\noom 0\noom_kill 0\n")
# A victim of the global OOM killer: no limit of its own was reached.
cgroup("user.slice", "max 0\noom 0\noom_kill 0\n", "max 0\noom 0\noom_kill 1\n")
cgroup("user.slice/user-1000.slice/user@1000.service/app.slice/app-code.scope", "max 0\noom 0\noom_kill 1\n")
# Kernels without .local files: only the leaf is counted, not its parent again.
write("sys/fs/cgroup/legacy.slice/memory.events", "max 0\noom 0\noom_kill 1\n")
write("sys/fs/cgroup/legacy.slice/old.service/memory.events", "max 0\noom 0\noom_kill 1\n")
write("sys/fs/cgroup/system.slice/cups.service/pids.events", "max 0\n")
write("sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/pids.events", "max 3\n")
write("sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/build.scope/pids.events", "max 3\n")
write("proc/sys/fs/file-nr", "900000\t0\t1000000\n")
write("proc/loadavg", "0.50 0.40 0.30 2/1200 9999\n")
write("proc/sys/kernel/pid_max", "4194304\n")
write("proc/sys/kernel/threads-max", "126000\n")
EOF

# A journal for this boot (0) and the one before (-1), which ended mid-session without a shutdown.
python3 - "$test_dir/journal.json" <<'EOF'
import json, sys

entries = []
def log(boot, second, message, **fields):
    entry = {"_BOOT": str(boot), "__MONOTONIC_TIMESTAMP": str(int(second * 1e6)), "PRIORITY": "6",
             "MESSAGE": message}
    entry.update({key: str(value) for key, value in fields.items()})
    entries.append(entry)

log(-1, 1, "systemd 259 running in system mode", _PID=1)
log(-1, 7000, "wlp0s20f3: disconnected from corp-wifi", SYSLOG_IDENTIFIER="NetworkManager")
log(0, 1, "systemd 259 running in system mode", _PID=1)
log(0, 0.5, "Direct firmware load for i915/mtl_gsc_1.bin failed with error -2", _TRANSPORT="kernel", PRIORITY=4)
log(0, 0.6, "Loading of unsigned module is rejected", _TRANSPORT="kernel", PRIORITY=3)
log(0, 0.65, "example: module verification failed: signature and/or required key missing - tainting kernel",
    _TRANSPORT="kernel", PRIORITY=4)
log(0, 0.7, "ACPI BIOS Error (bug): Could not resolve symbol [\\_SB.PC00.XHCI.RHUB.HS01._PLD]", _TRANSPORT="kernel",
    PRIORITY=3)
log(0, 0.8, "probe of 0000:00:1f.5 failed with error -110", _TRANSPORT="kernel", PRIORITY=3,
    SYSLOG_IDENTIFIER="mysterious-driver")
log(0, 3000, "Out of memory: Killed process 4242 (chrome) total-vm:9000000kB", _TRANSPORT="kernel", PRIORITY=3)
log(0, 3001, 'audit: type=1400 apparmor="DENIED" operation="open" profile="snap.firefox.firefox" name="/etc/x"',
    _TRANSPORT="audit", PRIORITY=5)
log(0, 9, "Startup finished in 6.1s (firmware) + 2.0s (loader) + 1.5s (kernel) + 3.2s (initrd) + 75.0s (userspace) "
    "= 1min 27.8s.", MESSAGE_ID="b07a249cd024414a82dd00cd181378ff", USERSPACE_USEC=75000000, _PID=1)
log(0, 20, "pam_unix(gdm-launch-environment:session): session opened for user gdm-greeter(uid=60578) by (uid=0)",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="gdm-launch-environment]")
# A first login whose desktop never came up; the later login reaches graphical-session.target.
log(0, 30, "pam_unix(gdm-password:session): session opened for user alice@corp.example(uid=1000) by (uid=0)",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="gdm-password]")
log(0, 35, "pam_unix(gdm-password:session): session closed for user alice@corp.example",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="gdm-password]")
for second in (40, 45):
    log(0, second, "pam_sss(gdm-password:auth): received for user alice@corp.example: 9 (Authentication service "
        "cannot retrieve authentication info)", SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="gdm-password]")
log(0, 60, "pam_sss(gdm-password:auth): authentication success; logname= uid=0 user=alice@corp.example",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="gdm-password]")
log(0, 60.2, "pam_unix(gdm-password:session): session opened for user alice@corp.example(uid=1000) by (uid=0)",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="gdm-password]")
log(0, 63, "Startup finished in 2.5s.", MESSAGE_ID="eed00a68ffd84e31882105fd973abdd1", USERSPACE_USEC=2500000,
    _SYSTEMD_UNIT="user@1000.service", _UID=1000)
log(0, 105, "Reached target graphical-session.target - Current graphical user session.",
    MESSAGE_ID="39f53479d3a045ac8e11786248231fbf", USER_UNIT="graphical-session.target",
    _SYSTEMD_UNIT="user@1000.service", _UID=1000)
for second in (200, 201, 202):
    log(0, second, f"Failed to mount /mnt/share{second}: Permission denied", SYSLOG_IDENTIFIER="mount.cifs",
        PRIORITY=3, _SYSTEMD_UNIT="mnt-share.mount")
log(0, 209, '{"api_token": "QuotedMustNeverPrint", "error": "request failed"}', SYSLOG_IDENTIFIER="backupd",
    PRIORITY=3, _SYSTEMD_UNIT="backupd.service")
log(0, 209.5, "{'password': 'Escaped\\' MustNeverPrint', 'user': 'svc'}", SYSLOG_IDENTIFIER="backupd",
    PRIORITY=3, _SYSTEMD_UNIT="backupd.service")
log(0, 210, "Connection to backup.corp.example failed; api_token=TokenMustNeverPrint", SYSLOG_IDENTIFIER="backupd",
    PRIORITY=3, _SYSTEMD_UNIT="backupd.service")
log(0, 211, "backupd.service: Main process exited, code=exited, status=1/FAILURE", _SYSTEMD_UNIT="init.scope",
    UNIT="backupd.service", PRIORITY=4, _PID=1)
log(0, 12, "refused.service: Service has no ExecStart=, ExecStop=, or SuccessAction=. Refusing.", PRIORITY=3, _PID=1)
log(0, 13, "/etc/systemd/system/odd.service:5: Unknown key name 'Foo' in section 'Service', ignoring.", PRIORITY=4,
    _PID=1)
log(0, 250, "VFS: file-max limit 1000000 reached", _TRANSPORT="kernel", PRIORITY=4)
log(0, 260, "W: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/resolute/InRelease  Temporary failure "
    "resolving 'archive.ubuntu.com'", _SYSTEMD_UNIT="apt-daily.service", PRIORITY=4, SYSLOG_IDENTIFIER="apt.systemd.daily")
log(0, 300, "kernel panic in compositor", SYSLOG_IDENTIFIER="gnome-shell", PRIORITY=2, _UID=1000)
log(0, 301, "Process 5555 (gnome-shell) of user 1000 dumped core.", MESSAGE_ID="fc2e22bc6ee647b6b90729ab34a250b1",
    COREDUMP_COMM="gnome-shell", COREDUMP_UID=1000, COREDUMP_PID=5555, PRIORITY=2,
    SYSLOG_IDENTIFIER="systemd-coredump")
log(0, 25, "Process 4444 (gnome-shell) of user 60578 dumped core.", MESSAGE_ID="fc2e22bc6ee647b6b90729ab34a250b1",
    COREDUMP_COMM="gnome-shell", COREDUMP_UID=60578, PRIORITY=2, SYSLOG_IDENTIFIER="systemd-coredump")
for second, message in (
        (61, "Registered Authentication Agent for unix-session:2 (system bus name :1.50 [/usr/bin/gnome-shell])"),
        (62, "Registered Authentication Agent for unix-session:3 (system bus name :1.51 [/usr/bin/gnome-shell])"),
        (300, "Unregistered Authentication Agent for unix-session:2 (system bus name :1.50)"),
        (301, "Unregistered Authentication Agent for unix-session:3 (system bus name :1.51)"),
        (302, "Registered Authentication Agent for unix-session:3 (system bus name :1.52 [/usr/bin/gnome-shell])"),
        (310, "Error compiling script /etc/polkit-1/rules.d/60-broken.rules: SyntaxError: unterminated string"),
        (320, "Operator of unix-session:3 FAILED to authenticate to gain authorization for action "
              "org.freedesktop.NetworkManager.settings.modify.system for unix-process:4242:1234 [nm-connection-editor] "
              "(owned by unix-user:alice@corp.example)"),
        (330, "Operator of unix-session:3 successfully authenticated as unix-user:alice@corp.example to gain "
              "TEMPORARY authorization for action org.freedesktop.packagekit.package-install for "
              "system-bus-name::1.101 [/usr/bin/gnome-software] (owned by unix-user:alice@corp.example)")):
    log(0, second, message, SYSLOG_IDENTIFIER="polkitd", PRIORITY=5)
log(0, 400, "Killed /user.slice/user-1000.slice/app-code.scope due to memory pressure",
    SYSLOG_IDENTIFIER="systemd-oomd")
log(0, 500, "Sync failed: network unreachable", SYSLOG_IDENTIFIER="sync-agent", PRIORITY=3,
    _SYSTEMD_USER_UNIT="sync-agent.service", _UID=1000)
log(0, 502, "bob backup: destination full", SYSLOG_IDENTIFIER="bob-backup", _SYSTEMD_USER_UNIT="bob-backup.service",
    _UID=4001)
# Domain stages: SSH authenticates but the access rules refuse the account; cockpit authenticates, opens the
# session, then pam_systemd fails to register it.
log(0, 600, "pam_sss(sshd:auth): authentication success; logname= uid=0 euid=0 tty=ssh ruser= rhost=10.0.0.7 "
    "user=alice@corp.example", SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="sshd", _PID=100)
log(0, 600.1, "pam_sss(sshd:account): Access denied for user alice@corp.example: 6 (Permission denied)",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="sshd", _PID=100)
log(0, 700, "pam_sss(cockpit:auth): authentication success; logname= uid=0 user=alice@corp.example",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="cockpit-session", _PID=300)
log(0, 700.1, "pam_unix(cockpit:session): session opened for user alice@corp.example(uid=1000) by (uid=0)",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="cockpit-session", _PID=300)
log(0, 700.2, "pam_systemd(cockpit:session): Failed to create session: Connection timed out",
    SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="cockpit-session", _PID=300)
# Two concurrent remote-desktop logins of alice (processes 500 and 501) and another account's failure (600) in
# between: neither of alice's logins failed. vnc logs without a process, so its failure stays unattributed.
for second, pid, message in (
        (800, 500, "pam_sss(grd:auth): authentication success; logname= uid=0 user=alice@corp.example"),
        (800.05, 501, "pam_sss(grd:auth): authentication success; logname= uid=0 user=alice@corp.example"),
        (800.1, 501, "pam_unix(grd:session): session opened for user alice@corp.example(uid=1000) by (uid=0)"),
        (800.15, 500, "pam_unix(grd:session): session opened for user alice@corp.example(uid=1000) by (uid=0)"),
        (800.2, 600, "pam_systemd(grd:session): Failed to create session: Connection timed out")):
    log(0, second, message, SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="grd", _PID=pid)
for second, message in (
        (900, "pam_sss(vnc:auth): authentication success; logname= uid=0 user=alice@corp.example"),
        (900.1, "pam_unix(vnc:session): session opened for user alice@corp.example(uid=1000) by (uid=0)"),
        (900.2, "pam_systemd(vnc:session): Failed to create session: Connection timed out")):
    log(0, second, message, SYSLOG_FACILITY=10, SYSLOG_IDENTIFIER="vnc")
for second in (950, 951):
    log(0, second, "mmap cache of type group is full, if you see this message often please consider increasing "
        "of cache size", SYSLOG_IDENTIFIER="sssd_nss", PRIORITY=2)
for second, message, fields in (
        (220, "Failed to create file chooser implementation: Timeout was reached",
         dict(SYSLOG_IDENTIFIER="xdg-desktop-por", _SYSTEMD_USER_UNIT="xdg-desktop-portal.service")),
        (221, "spa.alsa: hw:0: snd_pcm_open failed: Device or resource busy",
         dict(SYSLOG_IDENTIFIER="wireplumber", _SYSTEMD_USER_UNIT="wireplumber.service", PRIORITY=3)),
        (222, "JS ERROR: Extension dash-to-dock@micxgx.gmail.com: TypeError: this._box is null",
         dict(SYSLOG_IDENTIFIER="gnome-shell")),
        (223, "dconf-WARNING: failed to commit changes to dconf: Permission denied",
         dict(SYSLOG_IDENTIFIER="gnome-control-c")),
        (224, "database disk image is malformed", dict(SYSLOG_IDENTIFIER="localsearch-3",
                                                        _SYSTEMD_USER_UNIT="localsearch-3.service")),
        (225, "Could not add monitor for /home/alice/secret-plan: Too many open files",
         dict(SYSLOG_IDENTIFIER="localsearch-3", _SYSTEMD_USER_UNIT="localsearch-3.service")),
        (226, "Could not process '/home/alice/secret-plan.odt': Timeout was reached",
         dict(SYSLOG_IDENTIFIER="localsearch-extractor-3")),
        (227, 'Disallowed syscall "socket" caught in sandbox', dict(SYSLOG_IDENTIFIER="localsearch-extractor-3")),
        (228, 'Disallowed syscall "socket" caught in sandbox', dict(SYSLOG_IDENTIFIER="localsearch-extractor-3"))):
    log(0, second, message, **dict(dict(PRIORITY=4, _UID=1000), **fields))
log(0, 229, "Process 7777 (localsearch-ext) of user 1000 dumped core.", MESSAGE_ID="fc2e22bc6ee647b6b90729ab34a250b1",
    COREDUMP_COMM="localsearch-ext", COREDUMP_UID=1000, PRIORITY=2, SYSLOG_IDENTIFIER="systemd-coredump")
log(0, 250, "PM: suspend exit", _TRANSPORT="kernel")
log(0, 250.5, "System returned from sleep operation 'suspend'.", SYSLOG_IDENTIFIER="systemd-sleep")
log(0, 255, "i915 0000:00:02.0: [drm] *ERROR* GT0: GUC: load failed", _TRANSPORT="kernel", PRIORITY=3)
log(0, 1500, "Failed to put system to sleep. System resumed again: Device or resource busy",
    SYSLOG_IDENTIFIER="systemd-sleep", PRIORITY=3)
log(0, 2000, "PM: suspend exit", _TRANSPORT="kernel")
log(0, 501, "root decoy for sync-agent", SYSLOG_IDENTIFIER="sync-agent", _SYSTEMD_USER_UNIT="sync-agent.service",
    _UID=0)
with open(sys.argv[1], "w") as handle:
    json.dump(entries, handle)
EOF

cat > "$stubs/journalctl" <<EOF
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if "--disk-usage" in args:
    print("Archived and active journals take up 1.2G in the file system.")
    sys.exit(0)
if "--list-boots" in args:
    print("[]")
    sys.exit(0)
entries = json.load(open("$test_dir/journal.json"))
boot, limit, priority, units = "0", None, 7, {}
groups = [{}]
user_scope = "--user" in args
i = 0
while i < len(args):
    arg = args[i]
    if arg in ("-b", "-n", "-p", "-u", "--user-unit", "-o", "--since"):
        value = args[i + 1]
        i += 1
        if arg == "-b": boot = value
        elif arg == "-n": limit = int(value)
        elif arg == "-p": priority = int(value.split("..")[-1])
        elif arg == "-u": units["unit"] = value
        elif arg == "--user-unit": units["user-unit"] = value
    elif arg == "+":
        groups.append({})
    elif "=" in arg and not arg.startswith("-"):
        key, value = arg.split("=", 1)
        groups[-1].setdefault(key, []).append(value)
    i += 1
if boot not in ("0", "-1"):
    print("Data from the specified boot (" + boot + ") is not available: No such boot ID in journal", file=sys.stderr)
    sys.exit(1)
system = os.environ.get("JOURNAL_DENY") != "1"
def keep(entry):
    if entry["_BOOT"] != boot or int(entry["PRIORITY"]) > priority:
        return False
    if (user_scope or not system) and entry.get("_UID") != "1000":
        return False
    if "unit" in units and units["unit"] not in (entry.get("_SYSTEMD_UNIT"), entry.get("UNIT")):
        return False
    # Like journalctl, --user-unit also matches the caller's own UID, which is 0 under sudo.
    if "user-unit" in units and (units["user-unit"] not in (entry.get("_SYSTEMD_USER_UNIT"), entry.get("USER_UNIT"))
                                 or entry.get("_UID") != os.environ.get("JOURNAL_CALLER_UID", "0")):
        return False
    return any(all(entry.get(key) in values for key, values in group.items()) for group in groups)
chosen = sorted((e for e in entries if keep(e)), key=lambda e: float(e["__MONOTONIC_TIMESTAMP"]))
if limit:
    chosen = chosen[-limit:]
for entry in chosen:
    print(json.dumps(entry))
EOF

cat > "$stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"show -p Id -p ActiveState -p NRestarts --no-pager display-manager.service") printf 'Id=gdm.service\nActiveState=active\nNRestarts=1\n' ;;
    *"show -p LoadState -p ActiveState -p NRestarts --no-pager polkit.service") printf 'LoadState=loaded\nActiveState=active\nNRestarts=0\n' ;;
    *"show --no-pager --timestamp=unix"*) exec python3 "$(dirname "$0")/../units.py" "$@" ;;
    is-system-running) echo degraded ;;
    "is-active user@"*) echo active ;;
    *"-M alice@corp.example@ show-environment") printf 'XDG_CURRENT_DESKTOP=ubuntu:GNOME\nDCONF_PROFILE=corp-desktop\nXDG_CONFIG_DIRS=/etc/company:/etc/xdg\n' ;;
    *"-M carol@ show-environment") cat "$(dirname "$0")/../manager-env" ;;
    *"-M bob@"*"--failed"*) echo "bob-backup.service loaded failed failed Bob backup" ;;
    *"show"*"bob-backup.service"*) printf 'Description=Bob backup\nResult=exit-code\nExecMainCode=1\nExecMainStatus=2\nLoadState=loaded\n' ;;
    *"-M bob@"*) ;;
    "is-active sssd.service") echo inactive; exit 3 ;;
    *"--user"*"--failed"*) echo "sync-agent.service loaded failed failed Sync agent" ;;
    *"--failed"*) echo "backupd.service loaded failed failed Backup daemon" ;;
    *"--user"*"--state="*) ;;
    *"--state=bad-setting"*)
        echo "broken.service bad-setting inactive dead broken.service"
        echo "plymouth-quit-wait.service not-found inactive dead plymouth-quit-wait.service"
        echo "gone.service not-found active running gone.service"
        ;;
    *"--user"*"--type=service"*) echo "pipewire.service loaded active running PipeWire" ;;
    *"--type=service"*)
        echo "NetworkManager.service loaded active running Network Manager"
        echo "cups.service loaded active running CUPS"
        ;;
    *"show"*"broken.service"*) printf 'LoadState=bad-setting\nLoadError=org.freedesktop.systemd1.BadSetting "Unit broken.service has a bad unit file setting."\n' ;;
    *"show"*"backupd.service"*)
        printf 'Description=Backup daemon\nResult=exit-code\nExecMainCode=1\nExecMainStatus=1\nLoadState=loaded\nLoadError=\nNRestarts=5\n' ;;
    *"show"*"sync-agent.service"*) printf 'Description=Sync agent\nResult=start-limit-hit\nExecMainStatus=0\nLoadState=loaded\n' ;;
    *"show"*"-pNRestarts"*"NetworkManager.service"*) printf 'Id=NetworkManager.service\nNRestarts=4\n\nId=cups.service\nNRestarts=0\n' ;;
    *"show"*"-pNRestarts"*"pipewire.service"*) printf 'Id=pipewire.service\nNRestarts=1\n' ;;
    *) exit 0 ;;
esac
EOF
cat > "$stubs/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    time) printf 'Startup finished in 1.5s (kernel) + 75.0s (userspace) = 76.5s\ngraphical.target reached after 74.1s in userspace.\n' ;;
    *"--user"*blame*) printf '  30.5s tracker-miner-fs-3.service\n   2.1s gnome-keyring-daemon.service\n' ;;
    *blame*) printf '  60.012s NetworkManager-wait-online.service\n   5.300s snapd.seeded.service\n   1.002s apparmor.service\n' ;;
esac
EOF
cat > "$stubs/df" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *-i* ]]; then
    printf 'Filesystem Type Inodes IUsed IFree IUse%% Mounted on\n/dev/nvme0n1p2 ext4 1000 950 50 95%% /\n'
else
    printf 'Filesystem Type 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/nvme0n1p2 ext4 500000000 460000000 40000000 92%% /\n'
    printf '/dev/nvme0n1p1 vfat 1000000 850000 150000 85%% /boot/efi\n'
    printf '/dev/loop3 squashfs 100 100 0 100%% /snap/core/1\n'
    printf 'tmpfs tmpfs 100 99 1 99%% /run\n'
    printf 'tmpfs tmpfs 1000 500 500 50%% /dev/shm\n'
    printf 'tmpfs tmpfs 100 99 1 99%% /sys/fs/cgroup\n'
    printf '/dev/nvme0n1p3 ext4 1000000 900000 100000 90%% /boot\n'
fi
EOF
cat > "$stubs/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *general*) echo "connected (site only):limited" ;;
    *--active*) printf 'corp-wifi:802-11-wireless:wlp0s20f3\n'
        [[ -e "$(dirname "$0")/../no-vpn" ]] || printf 'corp-vpn:vpn:wlp0s20f3\n' ;;
esac
EOF
cat > "$stubs/smartctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    --scan) printf '/dev/nvme0 -d nvme # /dev/nvme0, NVMe device\n/dev/sda -d sat # /dev/sda, ATA device\n' ;;
    *"-d nvme /dev/nvme0") echo '{"smart_status": {"passed": false}, "nvme_smart_health_information_log": {"critical_warning": 4, "percentage_used": 97, "available_spare": 12, "available_spare_threshold": 10, "media_errors": 3, "num_err_log_entries": 40}}' ;;
    *"-d sat /dev/sda") echo '{"smart_status": {"passed": true}, "ata_smart_attributes": {"table": [{"id": 5, "raw": {"value": 12}}, {"id": 9, "raw": {"value": 5000}}, {"id": 199, "raw": {"value": 2}}]}}' ;;
    *) echo "unexpected smartctl $*" >&2; exit 1 ;;
esac
EOF
# quota -p: grace as a number, 0 when not in grace, so each row has eight numeric fields after the filesystem.
cat > "$stubs/quota" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" -p "* ]] || { echo "quota called without -p: $*" >&2; exit 3; }
echo "Disk quotas for user alice@corp.example (uid 1000):"
echo "     Filesystem  blocks   quota   limit   grace   files   quota   limit   grace"
echo " /dev/nvme0n1p4  950000*  900000 1000000 1793500000     100       0       0       0"
echo "      /dev/sda1      100    1000    2000       0     950*     900    1000 1793500000"
echo "      /dev/sdb1      100    1000    2000       0      10     100     200       0"
echo "      /dev/sdc1    1900*    1000    2000 1793500000    950*     900    1000 1793500000"
echo "   server:/home  950000*  900000 1000000 1793500000     100       0       0       0"
exit 1
EOF
printf '#!/usr/bin/env bash\nprintf "nvidia/580.95, 6.20.0-14-generic, x86_64: installed\\nnvidia/580.95: added\\n"\n' > "$stubs/dkms"
cat > "$stubs/snap" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    changes) printf 'ID   Status  Spawn               Ready               Summary\n41   Done    today at 09:00 UTC  today at 09:01 UTC  Auto-refresh snap "firefox"\n42   Error   today at 10:00 UTC  today at 10:05 UTC  Auto-refresh snap "code"\n' ;;
    warnings) printf 'last-occurrence:  today at 10:05 UTC\nwarning: |\n  snap "code" has running apps; refresh is inhibited\n' ;;
esac
EOF
# Accounts as NSS returns them. carol is the runner's own uid, so files the test creates belong to her; her home
# is not derived from her name. bob's uid owns nothing here, so his files read as another account's.
me="$(id -u)"
real_id="$(command -v id)"
cat > "$stubs/getent" <<EOF
#!/usr/bin/env bash
# Only the domain account comes from SSSD.
if [[ "\$1" == -s ]]; then [[ "\$2 \$4" == "sss alice@corp.example" ]] || exit 2; shift 2; fi
case "\$2" in
    alice@corp.example) echo "alice@corp.example:*:1000:1000:Alice:/home/alice:/bin/zsh" ;;
    carol) echo "carol:x:$me:$me:Carol:/home/carol-home:/bin/zsh" ;;
    bob) echo "bob:x:4001:4001::/home/bob:/bin/bash" ;;
    sudo) echo "sudo:x:27:dave" ;;
    *) exit 2 ;;
esac
EOF
cat > "$stubs/id" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "-G alice@corp.example") echo "1000 27" ;;
    "-G carol") echo "$me 27" ;;
    "-G bob") echo "4001" ;;
    *) exec "$real_id" "\$@" ;;
esac
EOF
cat > "$stubs/loginctl" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
    "list-users "*) printf "1000 alice@corp.example no active\\n4001 bob yes lingering\\n" ;;
    "show-user 1000") if [[ "\$*" == "show-user 1000 -p Sessions" ]]; then echo "Sessions=2 3"
        else echo "Failed to get user: User ID 1000 is not logged in or lingering" >&2; exit 1; fi ;;
    "show-session 2") printf "Service=gdm-password\nType=wayland\n" ;;
    "show-session 3") printf "Service=%s\nType=wayland\n" "\$(cat "$test_dir/session3")" ;;
    "show-user $me") printf "Sessions=4 7\\nState=active\\nLinger=no\\nRuntimePath=/run/user/$me\\n" ;;
    "show-user "*) echo "Failed to get user: User ID \$2 is not logged in or lingering" >&2; exit 1 ;;
    "show-session 4") printf "Type=wayland\\nClass=user\\nState=active\\nActive=yes\\nRemote=no\\nService=gdm-password\\nSeat=seat0\\n" ;;
    "show-session 7") printf "Type=tty\\nClass=user\\nState=online\\nActive=no\\nRemote=yes\\nService=sshd\\nSeat=\\n" ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "default via 10.0.0.1 dev wlp0s20f3"\n' > "$stubs/ip"
cat > "$stubs/busctl" <<'EOF'
#!/usr/bin/env bash
state="$(dirname "$0")/.."
case "$*" in
    *" list "*) [[ -e "$state/no-bus" ]] && { echo "Failed to connect to bus: No such file or directory" >&2; exit 1; }
        echo "org.freedesktop.DBus 1 systemd alice - - - -"
        echo "org.freedesktop.secrets 2345 gnome-keyring-d alice :1.20 user@1000.service - -" ;;
    *"--auto-start=no get-property org.freedesktop.secrets"*) cat "$state/keyring-locked" ;;
    *"--auto-start=no call org.freedesktop.LocalSearch3 "*GetStatus) echo 's "Crawling"' ;;
    *"--auto-start=no call org.freedesktop.LocalSearch3 "*GetProgress) echo 'd 0.42' ;;
    *"--auto-start=no call org.freedesktop.LocalSearch3 "*GetPauseDetails) cat "$state/index-pause" ;;
    *) exit 1 ;;
esac
EOF
cat > "$stubs/gsettings" <<'EOF'
#!/usr/bin/env bash
file="$(dirname "$0")/../gsettings-$2"
env > "$(dirname "$0")/../gsettings-env"
[[ "$1" == list-recursively && -e "$file" ]] || { echo "No such schema \u201c$2\u201d" >&2; exit 1; }
cat "$file"
EOF
printf '#!/usr/bin/env bash\necho "GNOME Shell 50.1"\n' > "$stubs/gnome-shell"
cat > "$stubs/resolvectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"_ldap._tcp.dc._msdcs.corp.example"*)
        printf '_ldap._tcp.dc._msdcs.corp.example IN SRV 0 100 389 dc1.corp.example\n'
        printf '_ldap._tcp.dc._msdcs.corp.example IN SRV 0 100 389 dc2.corp.example\n-- link: vpn0\n' ;;
    domain) cat "$(dirname "$0")/../link-domains" ;;
    *"query"*) echo "_kerberos._tcp.corp.example: resolve call failed: No appropriate name servers or networks for name found" >&2
        exit 1 ;;
    *) printf 'Global:\nLink 3 (wlp0s20f3): 10.0.0.1\nLink 9 (vpn0): 10.8.0.53\n' ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "NTP=yes\\nNTPSynchronized=no\\n"\n' > "$stubs/timedatectl"
printf '#!/usr/bin/env bash\necho "The following packages are only half configured:"\necho " libfoo1  library"\n' \
    > "$stubs/dpkg"
printf '#!/usr/bin/env bash\necho linux-firmware\n' > "$stubs/apt-mark"
printf '#!/usr/bin/env bash\necho "SecureBoot enabled"\n' > "$stubs/mokutil"
printf '#!/usr/bin/env bash\nprintf "120 profiles are loaded.\\n110 profiles are in enforce mode.\\n10 profiles are in complain mode.\\n2 processes are unconfined but have a profile defined.\\n"\n' \
    > "$stubs/aa-status"
printf '#!/usr/bin/env bash\necho "Status: active"\n' > "$stubs/ufw"
printf '#!/usr/bin/env bash\necho "dmesg: read kernel buffer failed: Operation not permitted" >&2\nexit 1\n' > "$stubs/dmesg"
cat > "$stubs/sssctl" <<'EOF'
#!/usr/bin/env bash
state="$(dirname "$0")/.."
case "$1" in
    domain-list) echo corp.example ;;
    domain-status) cat "$state/sssd-state" ;;
    user-checks) printf 'user: %s\naction: acct\nservice: %s\n\ntesting pam_acct_mgmt\n\n' "$2" "$6"
        cat "$state/acct" >&2 ;;
    *) printf "Issues identified by validators: 0\n" ;;
esac
EOF
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"
export USER=alice@corp.example
# The test controls every proxy setting it reads.
unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY SSL_CERT_FILE

# Expected units as systemctl would report them, a profile, overrides and fstab mounts.
python3 - "$test_dir" "$root" <<'EOF'
import json, os, sys, time
from pathlib import Path
test_dir, root = Path(sys.argv[1]), Path(sys.argv[2])
now = int(time.time())
loaded = {"LoadState": "loaded", "UnitFileState": "enabled", "ActiveState": "active", "SubState": "running",
          "Type": "simple", "Result": "success", "ConditionResult": "yes", "TriggeredBy": ""}
def unit(**changes):
    return dict(loaded, **changes)
units = {
    "systemd-timesyncd.service": unit(LoadState="masked", UnitFileState="masked", ActiveState="inactive"),
    "chrony.service": unit(),
    "on-demand.socket": unit(SubState="listening"),
    "dead.socket": unit(ActiveState="inactive", SubState="dead"),
    "masked.socket": unit(LoadState="masked", UnitFileState="masked", ActiveState="inactive"),
    "dead-socket.service": unit(ActiveState="inactive", SubState="dead", TriggeredBy="dead.socket"),
    "masked-trigger.service": unit(UnitFileState="disabled", ActiveState="inactive", SubState="dead",
                                   TriggeredBy="masked.socket"),
    "disabled-by-socket.service": unit(UnitFileState="disabled", ActiveState="inactive", SubState="dead",
                                       TriggeredBy="on-demand.socket"),
    "ssh.socket": unit(UnitFileState="disabled", ActiveState="inactive", SubState="dead"),
    "ssh.service": unit(),
    "NetworkManager.service": unit(),
    "display-manager.service": unit(Id="gdm.service", UnitFileState="alias"),
    "sssd.service": unit(UnitFileState="disabled", ActiveState="inactive", SubState="dead"),
    "apt-daily.timer": unit(SubState="waiting", LastTriggerUSec=f"@{now - 86400}"),
    "apt-daily-upgrade.timer": unit(SubState="waiting", LastTriggerUSec=f"@{now - 5 * 86400}"),
    "e2scrub_all.timer": unit(SubState="waiting", LastTriggerUSec="n/a"),
    "fstrim.timer": unit(LoadState="masked", UnitFileState="masked", ActiveState="inactive"),
    "logrotate.timer": unit(SubState="waiting", LastTriggerUSec=f"@{now - 5 * 86400}"),
    "systemd-tmpfiles-clean.timer": unit(ActiveState="inactive", SubState="dead"),
    "setup-once.service": unit(Type="oneshot", ActiveState="inactive", SubState="dead"),
    "on-demand.service": unit(ActiveState="inactive", SubState="dead", TriggeredBy="on-demand.socket"),
    "needs-dock.service": unit(ActiveState="inactive", SubState="dead", ConditionResult="no"),
    "user:px.service": unit(ActiveState="inactive", SubState="dead"),
    "user:xdg-desktop-portal.service": unit(),
    "user:xdg-desktop-portal-gnome.service": unit(ActiveState="failed", SubState="failed", Result="exit-code"),
    "user:pipewire.service": unit(),
    "user:pipewire-pulse.service": unit(),
    "user:wireplumber.service": unit(ActiveState="inactive", SubState="dead"),
    "user:pulseaudio.service": unit(),
    "user:localsearch-3.service": unit(NRestarts="4", ActiveEnterTimestamp=f"@{now - 8 * 3600}"),
    "user:proxydetox.service": unit(),
}
(test_dir / "units.json").write_text(json.dumps(units))
(test_dir / "units.py").write_text("""import json, sys
from pathlib import Path
units = json.loads((Path(__file__).parent / "units.json").read_text())
scope = "user:" if "--user" in sys.argv else ""
names = [arg for arg in sys.argv[1:] if not arg.startswith("-") and arg not in ("show",) and "@" not in arg]
blocks = []
for name in names:
    props = units.get(scope + name) or {"LoadState": "not-found", "ActiveState": "inactive"}
    blocks.append("\\n".join(f"{key}={value}" for key, value in dict({"Id": name}, **props).items()))
print("\\n\\n".join(blocks))
""")
(test_dir / "sssd-state").write_text("Online status: Offline\n")
(test_dir / "acct").write_text("pam_acct_mgmt: Permission denied\n")
(test_dir / "link-domains").write_text("Global: \nLink 3 (wlp0s20f3): \nLink 9 (vpn0): ~corp.example\n")
home = root / "home/alice"
(home / ".config/chezmoi").mkdir(parents=True, exist_ok=True)
(home / ".config/chezmoi/chezmoi.toml").write_text('[data]\n    machineRole = "work"\n    hostType = "laptop"\n')
(home / ".config/dotconfig").mkdir(parents=True, exist_ok=True)
(home / ".config/dotconfig/proxy.mode").write_text("on\n")
(home / ".config/dotconfig/machine-expect").write_text(
    "require --user px.service\nrequire setup-once.service\nrequire on-demand.service\n"
    "require dead-socket.service\nrequire masked-trigger.service\nrequire disabled-by-socket.service\n"
    "require ignored.service\n"
    "require needs-dock.service max-age=fortnight\nrequire needs-dock.service\nmount /srv/backup\n")
(root / "etc/dotconfig").mkdir(parents=True, exist_ok=True)
(root / "etc/dotconfig/machine-expect").write_text("# Local policy\nignore ignored.service\n"
                                                    "ignore-mount /mnt/scratch\n")
(home / "data").mkdir(parents=True, exist_ok=True)
for directory, name, program in (("usr/share/wayland-sessions", "ubuntu", "/usr/bin/gnome-session"),
                                 ("usr/share/xsessions", "oldwm", "/usr/bin/oldwm")):
    (root / directory).mkdir(parents=True, exist_ok=True)
    (root / directory / f"{name}.desktop").write_text(f"[Desktop Entry]\nName={name}\nExec={program}\n")
(root / "usr/bin").mkdir(parents=True, exist_ok=True)
(root / "usr/bin/gnome-session").write_text("")
def put(relative, text="", size=0, days_old=0):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if size:
        os.truncate(path, size)
    if days_old:
        stamp = time.time() - days_old * 86400
        os.utime(path, (stamp, stamp))
for program in ("usr/bin/gnome-shell", "usr/libexec/xdg-desktop-portal", "usr/libexec/localsearch-3"):
    put(program)
put("usr/share/xdg-desktop-portal/portals/gnome.portal", "[portal]\nDBusName=org.freedesktop.impl.portal.desktop.gnome\n"
    "Interfaces=org.freedesktop.impl.portal.FileChooser;org.freedesktop.impl.portal.ScreenCast;\nUseIn=gnome\n")
put("usr/share/xdg-desktop-portal/portals/gtk.portal", "[portal]\nDBusName=org.freedesktop.impl.portal.desktop.gtk\n"
    "Interfaces=org.freedesktop.impl.portal.FileChooser;org.freedesktop.impl.portal.Settings;\n")
# The session's XDG_CONFIG_DIRS puts a company override ahead of the distribution's file.
put("usr/share/xdg-desktop-portal/ubuntu-portals.conf", "[preferred]\ndefault=gnome;gtk;\n")
put("etc/company/xdg-desktop-portal/gnome-portals.conf",
    "[preferred]\ndefault=gnome;gtk;\norg.freedesktop.impl.portal.Secret=kwallet\n"
    "org.freedesktop.impl.portal.ScreenCast=gtk\norg.freedesktop.impl.portal.FileChooser=kwallet;gtk\n"
    "org.freedesktop.impl.portal.Inhibit=none\n")
put("home/alice/.local/share/gnome-shell/extensions/dash-to-dock@micxgx.gmail.com/metadata.json",
    '{"uuid": "dash-to-dock@micxgx.gmail.com", "shell-version": ["49", "50"]}')
put("usr/share/gnome-shell/extensions/old@example.com/metadata.json", '{"shell-version": ["46", "47.1"]}')
(test_dir / "gsettings-org.gnome.shell").write_text(
    "org.gnome.shell enabled-extensions ['dash-to-dock@micxgx.gmail.com', 'old@example.com', 'gone@example.com']\n"
    "org.gnome.shell disable-user-extensions false\norg.gnome.shell disable-extension-version-validation false\n")
(test_dir / "gsettings-org.freedesktop.Tracker3.Miner.Files").write_text("\n".join(
    "org.freedesktop.Tracker3.Miner.Files " + line for line in (
        "index-recursive-directories ['&DESKTOP', '&DOCUMENTS', '/srv/projects', '$HOME/secret-client-project', '&SECRET-thing']",
        "index-single-directories ['$HOME']", "ignored-directories ['po', 'CVS', 'node_modules']",
        "ignored-files @as []", "enable-monitors true", "crawling-interval -1", "low-disk-space-limit 100")) + "\n")
(test_dir / "index-pause").write_text("asas 0 0\n")
(root / "home/alice/.config/dconf").mkdir(parents=True, exist_ok=True)
# The session's DCONF_PROFILE selects corp-desktop; the default profile must not be read.
put("etc/dconf/profile/corp-desktop", "user-db:user\nsystem-db:corp\n")
put("etc/dconf/profile/user", "user-db:user\nsystem-db:decoy\n")
put("etc/dconf/db/decoy.d/00-decoy", "[org/decoy]\nkey=1\n")
put("etc/dconf/db/corp", days_old=3)
put("etc/dconf/db/corp.d/00-screensaver", "[org/gnome/desktop/screensaver]\nlock-enabled=true\n")
put("etc/dconf/db/corp.d/locks/screensaver",
    "# Locked by IT\n/org/gnome/desktop/screensaver/lock-enabled\n/org/gnome/desktop/session/idle-delay\n")
put("etc/xdg/autostart/good.desktop", "[Desktop Entry]\nType=Application\nExec=gnome-session --autostart\n")
put("etc/xdg/autostart/kde-only.desktop", "[Desktop Entry]\nExec=/usr/bin/plasma-thing\nOnlyShowIn=KDE;\n")
put("etc/xdg/autostart/tryexec.desktop", "[Desktop Entry]\nTryExec=not-installed\nExec=not-installed --go\n")
put("etc/xdg/autostart/hidden.desktop", "[Desktop Entry]\nExec=/usr/bin/gone\n")
put("home/alice/.config/autostart/hidden.desktop", "[Desktop Entry]\nExec=/usr/bin/gone\nHidden=true\n")
put("home/alice/.config/autostart/broken-app.desktop",
    "# Added by the app\n[Desktop Entry]\nExec=env FOO=1 /opt/broken/app --tray\n\n[Desktop Action quit]\nExec=gnome-session\n")
put("home/alice/.cache/tracker3/files/meta.db", size=3 * 2 ** 20)
put("proc/sys/fs/inotify/max_user_watches", "1000\n")
put("proc/4242/status", "Name:\tcode\nUid:\t1000\t1000\t1000\t1000\n")
put("proc/4242/fdinfo/7", "pos:\t0\nflags:\t00\n" + "inotify wd:1 ino:2 sdev:3 mask:fce ignored_mask:0\n" * 950)
(root / "proc/4242/fd").mkdir(parents=True, exist_ok=True)
os.symlink("anon_inode:inotify", root / "proc/4242/fd/7")
os.symlink("/dev/null", root / "proc/4242/fd/0")
# A child that inherited the same inotify instance shows its watches again.
put("proc/4244/status", "Name:\tcode-helper\nUid:\t1000\t1000\t1000\t1000\n")
put("proc/4244/fdinfo/3", "inotify wd:1 ino:2 sdev:3 mask:fce ignored_mask:0\n" * 950)
(root / "proc/4244/fd").mkdir(parents=True, exist_ok=True)
os.symlink("anon_inode:inotify", root / "proc/4244/fd/3")
put("proc/4343/status", "Name:\tother\nUid:\t4001\t4001\t4001\t4001\n")
put("proc/4343/fdinfo/3", "inotify wd:1 ino:2 sdev:3 mask:fce ignored_mask:0\n" * 500)
(root / "proc/4343/fd").mkdir(parents=True, exist_ok=True)
os.symlink("anon_inode:inotify", root / "proc/4343/fd/3")
(root / "var/lib/AccountsService/users").mkdir(parents=True, exist_ok=True)
(root / "var/lib/AccountsService/users/alice@corp.example").write_text("[User]\nSession=plasma\n")
pam = root / "etc/pam.d"
pam.mkdir(parents=True, exist_ok=True)
(pam / "common-auth").write_text("auth [success=2 default=ignore] pam_unix.so nullok\n"
                                 "auth [success=1 default=ignore] pam_sss.so use_first_pass\n"
                                 "auth requisite pam_deny.so\nauth required pam_permit.so\n")
(pam / "common-session").write_text("session required pam_unix.so\nsession optional pam_sss.so\n")
(pam / "gdm-password").write_text("@include common-auth\nauth optional pam_gnome_keyring.so\n"
                                  "@include common-session\nsession optional pam_gnome_keyring.so auto_start\n")
(pam / "polkit-1").write_text("@include common-auth\n@include common-session\n")
for directory, name, body in (("usr/share/polkit-1/rules.d", "40-ubuntu.rules", '"unix-group:sudo", "unix-group:admin"'),
                              ("etc/polkit-1/rules.d", "50-corp.rules", '"unix-group:linux-admins@corp.example"')):
    (root / directory).mkdir(parents=True, exist_ok=True)
    (root / directory / name).write_text("polkit.addAdminRule(function(action, subject) {\n    return [" + body
                                         + "];\n});\n")
(root / "etc/polkit-1/localauthority/50-local.d").mkdir(parents=True, exist_ok=True)
(root / "etc/polkit-1/localauthority/50-local.d/old.pkla").write_text("[old]\nIdentity=unix-user:*\n")
(root / "home/alice/.local/share/keyrings").mkdir(parents=True, exist_ok=True)
(root / "home/alice/.local/share/keyrings/login.keyring").write_text("")
(test_dir / "keyring-locked").write_text("b true\n")
(test_dir / "session3").write_text("gdm-smartcard\n")
(root / "etc/nsswitch.conf").write_text("passwd: files sss\ngroup: files sss\nsudoers: files sss\n")
(root / "etc/fstab").write_text(
    "/dev/nvme0n1p2 / ext4 defaults 0 1\n/dev/nvme0n1p1 /boot/efi vfat umask=0077 0 1\n"
    "UUID=1234 /home/alice/data ext4 defaults,nofail 0 2\n//nas/share /mnt/share cifs noauto 0 0\n"
    "/swapfile none swap sw 0 0\n/dev/sdb1 /mnt/scratch ext4 defaults 0 2\n")
EOF

check() {
    grep -q -- "$1" "$test_dir/out" || { cat "$test_dir/out" >&2; echo "Missing: $1" >&2; exit 1; }
}
refute() {
    if grep -q -- "$1" "$test_dir/out"; then cat "$test_dir/out" >&2; echo "Unexpected: $1" >&2; exit 1; fi
}
# Every problem names what to run next.
next_steps() {
    local missing
    missing="$(grep -E '^(warning|earlier|recovered): ' "$test_dir/out" | grep -vE 'see: |run: |to rule it out: |try: ' || :)"
    [[ -z "$missing" ]] || { echo "Problems without a next step:" >&2; echo "$missing" >&2; exit 1; }
}
run_status() {
    status=0
    bash "$repo_root/scripts/machine.sh" status "$@" > "$test_dir/out" 2>&1 || status=$?
    next_steps
}

# With sudo: everything is visible.
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=1 SUDO_USER=alice@corp.example SUDO_UID=1000
run_status --sudo --examples 2
[[ "$status" == 1 ]] || { cat "$test_dir/out" >&2; echo "expected exit 1, got $status" >&2; exit 1; }
check '^ok: Ubuntu 26.04.1 LTS'
check '^info: profile: work laptop (from ~/.config/chezmoi/chezmoi.toml); features: SSSD, dotconfig proxy$'
check "^warning: ~/.config/dotconfig/machine-expect:8: cannot read 'require needs-dock.service max-age=fortnight'"
check '^warning: sssd.service is disabled, so it does not start at boot (serves domain accounts and logins); run: systemctl enable --now sssd.service'
check '^warning: fstrim.timer is masked, so it never starts'
check '^warning: systemd-tmpfiles-clean.timer is inactive, so what it schedules never runs'
check '^warning: logrotate.timer last ran 5 days ago, expected at least every 2 (keeps logs from filling the disk)'
check '^warning: e2scrub_all.timer has never run although the machine has been up'
check '^warning: needs-dock.service was skipped: a start condition was not met'
check '^warning: px.service is inactive (dead) although it is expected to run (required by ~/.config/dotconfig/machine-expect); see: systemctl --user status px.service'
check '^warning: /home/alice/data is expected to be mounted (/etc/fstab: UUID=1234, ext4, nofail) but is not; its directory is writable, so files written there land on the parent filesystem'
check '^warning: /srv/backup is expected to be mounted (~/.config/dotconfig/machine-expect) but is not; nothing is mounted there; see: findmnt /srv/backup, journalctl -u srv-backup.mount'
refute '^warning: apt-daily[a-z-]*.timer \(is\|last\|has\)'
refute 'setup-once.service'
refute 'on-demand.service'
refute 'NetworkManager.service is'
refute 'display-manager.service'
refute 'timesyncd'
refute 'chrony'
refute 'ignored.service'
refute 'disabled-by-socket.service'
check '^warning: dead-socket.service is inactive and what would start it on demand is not running: dead.socket (inactive)'
check '^warning: masked-trigger.service is disabled, so it does not start at boot, and what would start it is not running: masked.socket (masked)'
refute '/mnt/share is expected'
refute '/mnt/scratch is expected'
refute 'proxydetox'
check '^Domain login (alice@corp.example):'
check '^ok: SSSD serves alice@corp.example: uid 1000, home /home/alice'
check '^warning: SSSD is offline for corp.example although vpn0 routes its DNS; hypotheses: the controllers are not reachable'
check '^warning: alice@corp.example is not authorized to log in through gdm-password now: Permission denied'
check '^ok: last login of alice@corp.example through gdm-password at 1 min 0 s after the kernel started: authentication, authorization and session setup succeeded'
check '^info: 2 failed attempts through gdm-password before that, the last one 9: SSSD could not reach the domain'
check '^earlier: last login of alice@corp.example through sshd at .*: authentication succeeded, then authorization refused it (6: the access rules'
check '^ok: last login of alice@corp.example through grd at .*: authentication, authorization and session setup succeeded'
check '^ok: last login of alice@corp.example through vnc at .*: authentication, authorization and session setup succeeded'
check '^info: a session failure through vnc at .* names no account and process, so it may or may not belong to this login'
refute 'through grd at .*session setup failed'
check '^earlier: last login of alice@corp.example through cockpit at .*: authenticated and authorized, but session setup failed: Failed to create session: Connection timed out'
refute 'discovery:'
check "^earlier: SSSD's in-memory group cache filled up 2 times this boot, so lookups fall back to the slower SSSD socket; raise memcache_size_group in \\[nss\\] of sssd.conf and set ignore_group_members = True"
check '^info: sudo also asks SSSD for its rules (nsswitch: sudoers: files sss); if the domain defines none, sudo_provider = none'
refute 'resolving the groups of'
check '^Desktop session (alice@corp.example):'
check '^recovered: display manager: gdm.service, active, restarted 1 time this boot; the login screen went away each time'
check '^warning: session oldwm: its program /usr/bin/oldwm is missing; choosing it at the login screen returns straight to it'
refute 'session ubuntu: its program'
check '^warning: alice@corp.example last chose session plasma, which is no longer installed'
check '^recovered: alice@corp.example logged in by password at 30.0 s after the kernel started, but the session ended 5 s later before the desktop was ready'
check "^earlier: alice@corp.example's desktop crashed 1 time this boot, last at .* (gnome-shell); see: coredumpctl info 5555"
check "^earlier: the login screen's Shell crashed 1 time this boot (greeter account, not a user session)"
check '^info: the default keyring is locked, as expected after a smart card login'
check '^warning: /home/alice/.local/share/keyrings is owned by [a-z0-9 ]*, not alice@corp.example'
check '^Administrator authorization (polkit, for alice@corp.example):'
check '^ok: polkit is running$'
check '^info: administrator identity unix-group:admin (from 40-ubuntu.rules) does not resolve through NSS; it offers nobody'
check '^warning: administrator identity unix-group:linux-admins@corp.example (from 50-corp.rules) does not resolve through NSS: nobody can be offered for it; is SSSD offline?'
check '^ok: alice@corp.example is an administrator for polkit and authenticates with their own password'
check '^info: polkit authenticates through: pam_unix.so, pam_sss.so, pam_deny.so, pam_permit.so (domain accounts through pam_sss)'
check '^warning: 1 legacy .pkla file (e.g. old.pkla) without polkitd-pkla installed'
check '^warning: session 2: its authentication agent unregistered at .* and did not register again'
check '^ok: session 3: an authentication agent is registered (it re-registered after going away)'
check '^earlier: polkit reported 1 rule error this boot'
check '^earlier: org.freedesktop.NetworkManager.settings.modify.system: authentication failed 1 time this boot'
check '^info: org.freedesktop.packagekit.package-install: authorized 1 time this boot'
refute 'failed screen unlock'
check '^Desktop components (alice@corp.example):'
check '^info: xdg-desktop-portal-gnome.service has failed (see Services): screenshots, screen sharing and file choosers'
check '^warning: PipeWire runs without its session manager WirePlumber'
check '^warning: PulseAudio and pipewire-pulse are both running'
check '^info: sound services logged 1 error this boot, last: spa.alsa: hw:0: snd_pcm_open failed'
check '^warning: portal configuration /etc/company/xdg-desktop-portal/gnome-portals.conf: org.freedesktop.impl.portal.Secret has no usable backend (kwallet is not installed), so that portal fails'
check '^warning: portal configuration /etc/company/xdg-desktop-portal/gnome-portals.conf: org.freedesktop.impl.portal.ScreenCast has no usable backend (gtk does not implement it)'
check '^info: portals switched off on purpose by /etc/company/xdg-desktop-portal/gnome-portals.conf (none): org.freedesktop.impl.portal.Inhibit$'
refute 'FileChooser has no usable backend'
refute 'default has no usable backend'
refute 'ubuntu-portals.conf'
check '^earlier: xdg-desktop-portal reported 1 backend failure this boot, last at .*: Failed to create file chooser'
check '^info: 1 enabled extension not installed: gone@example.com$'
check '^warning: 1 enabled extension not declared for GNOME Shell 50, so the Shell skips it: old@example.com (declares 46, 47)'
check '^earlier: Shell extension dash-to-dock@micxgx.gmail.com logged 1 error this boot, last: JS ERROR'
check '^warning: /home/alice/.config/dconf is owned by [a-z0-9 ]*, not alice@corp.example: settings changes are lost'
check '^earlier: settings failed to save 1 time this boot'
check '^warning: dconf policy corp: /etc/dconf/db/corp.d changed after it was compiled'
check '^info: 2 settings locked by system policy corp (e.g. /org/gnome/desktop/screensaver/lock-enabled)'
refute 'dconf policy decoy'
check '^warning: autostart entry broken-app.desktop (user): its program /opt/broken/app is missing, so it fails at every login; if it is no longer wanted, run: rm /home/alice/.config/autostart/broken-app.desktop'
refute 'autostart entry (good|kde-only|tryexec|hidden)'
check '^info: 2 resumes from sleep this boot'
check '^earlier: suspend or resume failed 1 time this boot, last at .*: Failed to put system to sleep'
check '^earlier: after 1 of them the graphics driver reported errors within two minutes, e.g. i915 0000:00:02.0: \[drm\] \*ERROR\*'
check "^earlier: alice@corp.example's Shell crashed within two minutes after 1 resume, together with graphics errors"
check '^File indexing (LocalSearch, for alice@corp.example):'
check '^info: indexes &DESKTOP, &DOCUMENTS, 3 other folders with subfolders, and [$]HOME without'
refute 'secret-client-project'
refute 'SECRET-thing'
check '^info: exclusions: 3 folder patterns, 0 file patterns'
check '^recovered: localsearch-3.service restarted 4 times this boot: it keeps crashing'
check '^info: the indexer is busy: Crawling, 42% done, 8 h after it started; one look cannot tell slow from stuck'
check '^earlier: indexer: database errors (1 this boot); .*rebuilding it removes only the index: localsearch reset'
check '^earlier: indexer: out of inotify watches (1 this boot)'
check '^earlier: indexer: extraction timeouts (1 this boot)'
check '^earlier: indexer: extractor crashes (3 this boot)'
check '^warning: /home/alice/.cache/tracker3/files is owned by [a-z0-9 ]*, not alice@corp.example'
check "^warning: alice@corp.example's programs hold at least 950 of 1000 inotify watches"
refute 'secret-plan'
refute 'srv/projects'
check '^warning: systemd reports the system degraded'
check '^warning: kernel tainted: D kernel died recently (oops or BUG); W kernel warning; O out-of-tree module; E unsigned module'
check '^warning: reboot required by linux-image-6.20.0-15-generic'
check '^earlier: the boot before this one ended without a clean shutdown.*disconnected from corp-wifi'
check '^info: Startup finished in 6.1s (firmware)'
check '^earlier: userspace took 1 min 15 s to start'
check '^info: graphical.target reached after 74.1s in userspace'
check '^info: slowest units this boot: NetworkManager-wait-online.service (60.012s), snapd.seeded.service (5.300s)'
check '^info: login screen appeared 20.0 s after the kernel started'
check '^info: alice@corp.example logged in through gdm-password 30.0 s after the kernel started; no graphical session start recorded$'
check '^earlier: alice@corp.example logged in through gdm-password 1 min 0 s after the kernel started; user services started in 2.5 s; desktop session ready 44.8 s after the password was accepted'
check '^info: slowest user units: tracker-miner-fs-3.service (30.5s)'
check '^recovered: 2 failed password attempts through gdm-password before alice@corp.example logged in'
check '^info: domain logins go through SSSD'
check '^warning: backupd.service failed (Backup daemon): its main process exited with an error, exited 1 (generic failure), restarted 5 times first'
check '^    log: {"api_token": <hidden>, "error": "request failed"}'
check "^    log: {'password': <hidden>, 'user': 'svc'}"
check '^    log: Connection to backup.corp.example failed; api_token=<hidden>'
check '^warning: sync-agent.service failed (Sync agent): it restarted too often and was stopped'
check '^    log: Sync failed: network unreachable'
refute 'root decoy'
check '^  user units of alice@corp.example (uid 1000):'
check '^  user units of bob (uid 4001):'
check '^warning: bob-backup.service failed (Bob backup): its main process exited with an error, exited 2 (invalid arguments)'
check '^    log: bob backup: destination full'
check '^warning: broken.service did not load: bad-setting (org.freedesktop.systemd1.BadSetting'
check '^warning: gone.service is active but its unit file is gone'
check '^warning: refused.service was refused: Service has no ExecStart='
check "^info: /etc/systemd/system/odd.service: 1 setting ignored, e.g. Unknown key name 'Foo'"
check '^info: 1 system unit referenced but not installed (usually optional): plymouth-quit-wait.service'
check '^earlier: NetworkManager.service was restarted 4 times this boot'
check '^info: pipewire.service was restarted 1 time this boot'
refute 'cups.service was restarted'
check '^earlier: gnome-shell: 1 error (1 critical)'
check '^info: mount.cifs: 3 errors'
check '    e.g. Failed to mount /mnt/share202: Permission denied (x3)'
check '^earlier: gnome-shell crashed 2 times this boot; see: coredumpctl info gnome-shell'
check '^info: 1 crash report in /var/crash: _usr_bin_gnome-shell.1000.crash'
check '^earlier: the kernel OOM killer ended processes (1 time this boot): chrome'
check '^earlier: the kernel refused to load an unsigned or untrusted module'
check '^info: modules loaded without a valid signature and tainted the kernel (E); allowed because signatures are not enforced (1 time this boot): example'
check '^info: firmware files not found (drivers often try several versions) (1 time this boot): i915/mtl_gsc_1.bin'
check '^info: AppArmor denied access (1 time this boot): snap.firefox.firefox'
check '^info: ACPI firmware errors'
check '^info: 1 other kernel error'
check '    e.g. mysterious-driver: probe of'
check '^warning: /: 92% of space used (38.1 GiB free)'
check '^info: /boot/efi: 85% of space used (146 MiB free)'
check '^warning: /: 95% of inodes used (50 inodes left)'
check '^warning: / is mounted read-only'
check '^warning: /dev/nvme0: SMART health FAILED'
refute '/snap/core'
check '^warning: /run: 99% of space in memory (tmpfs) used'
refute '/dev/shm:'
refute '/sys/fs/cgroup:'
check '^warning: quota for alice@corp.example on /dev/nvme0n1p4: space over its soft limit'
check '^warning: quota for alice@corp.example on /dev/sda1: files over its soft limit'
refute 'on /dev/sda1: space'
refute '/dev/sdb1'
check '^warning: quota for alice@corp.example on /dev/sdc1: space over its soft limit'
check '^warning: quota for alice@corp.example on /dev/sdc1: files over its soft limit'
check '^warning: quota for alice@corp.example on server:/home: space over its soft limit'
refute 'quota called without -p'
check '^warning: /dev/nvme0: NVMe critical warning: reliability degraded by media or internal errors'
check '^info: /dev/nvme0: 97% of its rated endurance used'
check '^warning: /dev/nvme0: available spare 12% (threshold 10%)'
check '^warning: /dev/nvme0: 3 media and data integrity errors'
check '^info: /dev/nvme0: 40 error log entries'
check '^warning: /dev/sda: 12 reallocated sectors'
check '^info: /dev/sda: 2 interface CRC errors'
check '^info: /dev/sda: overall SMART health still reads passed'
refute 'unexpected smartctl'
check '^warning: runnable tasks waited for a CPU 42.00% of the last 5 minutes'
check '^info: all non-idle tasks waited for I/O 6.00% of the last 5 minutes'
check '^earlier: system.slice/backupd.service: the kernel killed 1 process at its own memory limit (MemoryMax)'
check '^info: system.slice/cups.service reached its memory limit 2 times'
check '^earlier: user.slice/user-1000.slice/user@1000.service/app.slice/app-code.scope: the OOM killer ended 1 process here; it did not reach its own limit'
check '^earlier: legacy.slice/old.service: the OOM killer ended 1 process here'
refute '^warning: system.slice: '
refute '^warning: user.slice: '
refute '^warning: legacy.slice: '
check '^earlier: user.slice/user-1000.slice/user@1000.service/app.slice/build.scope: 3 process starts refused at its task limit (TasksMax) or an enclosing one'
refute '^warning: user.slice/user-1000.slice/user@1000.service/app.slice: 3 process'
check '^warning: 90% of the kernel file handle table (fs.file-max) in use'
check '^earlier: the kernel ran out of file handles (fs.file-max) (1 time this boot)'
refute 'process and thread limit'
check '^warning: APT last refreshed its package lists successfully 10 days ago but tried 2 days ago: refreshes are failing'
check '^info: repository archive.ubuntu.com/ubuntu/dists/resolute: last published 40 days ago'
check '^warning: repository ppa.launchpadcontent.net/team/tool/ubuntu/dists/resolute: metadata expired 3 days ago (Valid-Until)'
refute 'repository security.ubuntu.com'
check '^earlier: the daily APT refresh failed to fetch 1 time this boot'
check '^warning: unattended upgrades last ran 5 days ago'
check '^warning: DKMS module nvidia is not installed for kernel 6.20.0-15-generic; that kernel boots without it'
check '^warning: /boot has 97 MiB free but a kernel and its initrd take about 105 MiB'
check '^warning: 7% of 15.3 GiB memory available'
check '^info: 75% of swap used'
check '^warning: processes stalled on memory 6.50% of the last 5 minutes'
check '^earlier: systemd-oomd killed 1 unit for memory pressure'
check '^warning: NetworkManager connected (site only), connectivity limited'
check '^info: VPN active: corp-vpn'
check '^info: DNS servers: 10.0.0.1, 10.8.0.53'
check '^warning: clock not synchronized with NTP; Kerberos refuses tickets'
check '^warning: sssd is inactive; domain logins fail'
check '^  dotconfig creds status:'
check '^  dotconfig creds check-logs --days 2:'
check '^warning: dpkg reports half-installed or unconfigured packages (libfoo1)'
refute 'systemd-coredump: '
check '^info: 12 package updates pending, 3 of them security updates'
check '^info: held packages: linux-firmware'
check '^earlier: 1 snap change failed recently'
check '^    e.g. Auto-refresh snap "code"'
check '^info: SecureBoot enabled'
check '^ok: AppArmor is enabled'
check '^info: last package change: 2026-10-28  09:12:01'
check '^info: Archived and active journals take up 1.2G'
check '^info: AppArmor: 120 profiles loaded, 110 enforcing, 10 in complain mode'
check '^info: 2 processes started before their AppArmor profile loaded'
check '^info: firewall (ufw): active'
check '^earlier: unattended-upgrades logged 1 error or warning'
check '^warning: BAT0: 71% discharging, holds 56% of its design capacity, 412 cycles'
check '^warning: running hot: x86_pkg_temp 93 °C'
check '^Summary: problems found: [0-9]* current, [0-9]* earlier not seen to recover, [0-9]* earlier and recovered$'
refute 'check failed'
refute 'MustNeverPrint'
refute 'not checked'

# Without sudo and outside the adm group: root-only and system-journal checks are listed, not failed.
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=0 JOURNAL_DENY=1
unset SUDO_USER SUDO_UID
run_status
check '^not checked: how the previous boot ended: the system journal is not readable by this account; run dotconfig machine status --sudo'
check '^not checked: login timeline: needs the system journal (see above)'
check '^info: your user services started in 2.5 s'
check '^not checked: SMART health needs root'
check '^not checked: SSSD caches and login logs need root'
check '^not checked: AppArmor profiles, firewall, and unattended-upgrades log need root'
check '^not checked: kernel log: needs the system journal'
check '^earlier: gnome-shell: 1 error (1 critical)'
check '^warning: sync-agent.service failed'
refute 'mount.cifs'
refute 'dotconfig creds check-logs --days'
check '^not checked: SSSD online state and authorization need root; run: dotconfig machine status --sudo'
check '^not checked: login stages: needs the system journal (see above)'
check '^not checked: graphical logins: needs the system journal (see above)'
check '^not checked: polkit agents, rule errors and outcomes: needs the system journal (see above)'
check '^not checked: resume from sleep: needs the system journal (see above)'
check '^info: portals: no desktop name for alice@corp.example (no graphical session)'
check '^info: settings of alice@corp.example are read from the default locations'
refute 'autostart entry kde-only'
check '^warning: sssd.service is disabled'
check '^Summary: problems found: [0-9]* current, [0-9]* earlier not seen to recover, [0-9]* earlier and recovered; [0-9]* not checked (need --sudo, or not applicable)$'
refute 'check failed'

# SSSD online and the account authorized; discovery, asked for, finds the controllers through the VPN and reports
# the Kerberos record that does not resolve.
printf 'Online status: Online\n' > "$test_dir/sssd-state"
printf 'pam_acct_mgmt: Success\n' > "$test_dir/acct"
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=1 SUDO_USER=alice@corp.example SUDO_UID=1000
unset JOURNAL_DENY
run_status --sudo --probe-domain
check '^ok: SSSD is online for corp.example$'
check '^ok: alice@corp.example is authorized to log in through gdm-password now (account check, no password)'
check '^ok: discovery: _ldap._tcp.dc._msdcs.corp.example lists 2 servers (answered through vpn0)'
check '^warning: discovery: _kerberos._tcp.corp.example does not resolve'
XDG_CONFIG_HOME=/caller/config DCONF_PROFILE=caller DBUS_SESSION_BUS_ADDRESS=unix:path=/caller/bus run_status --sudo
for expected in HOME=/home/alice DCONF_PROFILE=corp-desktop XDG_CONFIG_DIRS=/etc/company:/etc/xdg; do
    grep -qx "$expected" "$test_dir/gsettings-env" || { echo "gsettings ran without $expected" >&2; exit 1; }
done
if grep -q 'caller' "$test_dir/gsettings-env"; then
    echo 'gsettings inherited the caller environment' >&2
    exit 1
fi
mv "$root/etc/company/xdg-desktop-portal/gnome-portals.conf" "$test_dir/gnome-portals.conf.saved"
for pid in 4242 4244; do
    python3 -c 'import sys; open(sys.argv[1], "w").write("inotify wd:1 ino:2 sdev:3 mask:fce\n" * 500)' \
        "$root/proc/$pid/fdinfo/$([[ $pid == 4242 ]] && echo 7 || echo 3)"
done
printf 'gdm-password\n' > "$test_dir/session3"
printf 'asas 1 "gnome-software" 1 "Installing updates"\n' > "$test_dir/index-pause"
run_status --sudo
check '^info: indexing is paused by gnome-software (Installing updates); a pause is deliberate, not a fault'
check '^ok: portals for ubuntu:gnome: /usr/share/xdg-desktop-portal/ubuntu-portals.conf chooses gnome;gtk; by default'
check "^info: inotify watches of alice@corp.example's programs: between 500 and 1000 of 1000 (descriptors shared"
mv "$test_dir/gnome-portals.conf.saved" "$root/etc/company/xdg-desktop-portal/gnome-portals.conf"
check '^warning: the default keyring stayed locked after a password login; hypotheses: its password differs from the login password'
cp "$root/etc/pam.d/gdm-password" "$test_dir/gdm-password.saved"
printf '@include common-auth\n@include common-session\n' > "$root/etc/pam.d/gdm-password"
run_status --sudo
check '^warning: the default keyring is locked and the gdm-password PAM path does not include pam_gnome_keyring in auth'
mv "$test_dir/gdm-password.saved" "$root/etc/pam.d/gdm-password"
printf 'b false\n' > "$test_dir/keyring-locked"
run_status --sudo
check '^ok: the Secret Service (gnome-keyring-d) is running and its default collection is unlocked'
touch "$test_dir/no-bus"
sed -i.bak "s/index-recursive-directories .*/index-recursive-directories @as []/; s/index-single-directories .*/index-single-directories @as []/" \
    "$test_dir/gsettings-org.freedesktop.Tracker3.Miner.Files"
run_status --sudo
check '^info: no folders are set to be indexed: indexing is turned off deliberately, not a fault'
refute 'indexer: database errors'
mv "$test_dir/gsettings-org.freedesktop.Tracker3.Miner.Files.bak" "$test_dir/gsettings-org.freedesktop.Tracker3.Miner.Files"
check '^info: keyring: no session bus for alice@corp.example'
rm "$test_dir/no-bus"
DOTCONFIG_MACHINE_SLOW_GROUPS=0 run_status --sudo
check '^warning: resolving the groups of alice@corp.example took [0-9.]* s; sudo and logins wait that long'
DOTCONFIG_MACHINE_SLOW_GROUPS=0 run_status --sudo --user carol
check '^info: carol is not a domain account (SSSD does not serve it)'
refute 'resolving the groups of'
refute 'authorized to log in'
printf 'Online status: Offline\n' > "$test_dir/sssd-state"
: > "$test_dir/acct"
touch "$test_dir/no-vpn"
printf 'Link 3 (wlp0s20f3): corp.example\n' > "$test_dir/link-domains"
run_status --sudo
check '^warning: SSSD is offline for corp.example although wlp0s20f3 routes its DNS'
check '^check failed: authorization of alice@corp.example: sssctl user-checks printed no pam_acct_mgmt verdict'
rm "$test_dir/no-vpn"
printf 'pam_acct_mgmt: Success\n' > "$test_dir/acct"
printf 'Link 9 (vpn0): other.example\n' > "$test_dir/link-domains"
run_status --sudo
check '^warning: SSSD is offline for corp.example and no connected network routes its DNS; connected VPN: corp-vpn, which does not route it either'
cp "$root/etc/dotconfig/machine-expect" "$test_dir/machine-expect.saved"
printf 'offline-ok corp.example\n' >> "$root/etc/dotconfig/machine-expect"
run_status --sudo
check '^info: SSSD is offline for corp.example, which machine-expect allows (offline-ok)'
mv "$test_dir/machine-expect.saved" "$root/etc/dotconfig/machine-expect"
sed -i.bak 's/"laptop"/"server"/' "$root/home/alice/.config/chezmoi/chezmoi.toml"
run_status --sudo
check '^info: profile: work server'
refute 'ssh.socket'
refute 'ssh.service'
mv "$root/home/alice/.config/chezmoi/chezmoi.toml.bak" "$root/home/alice/.config/chezmoi/chezmoi.toml"

# A previous boot is read from the journal; current-only timing is skipped.
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=1 SUDO_USER=alice@corp.example
unset JOURNAL_DENY
run_status --boot -1
check '^Journal sections read boot -1'
check '^info: no earlier boot in the journal'
check '^info: no graphical or console login recorded in this boot'
refute 'slowest units this boot'

# Within a day of boot, stale lists and an old unattended-upgrades stamp are expected: the daily jobs have not run yet.
printf '3600.00 1000.00\n' > "$root/proc/uptime"
cp -p "$root/var/lib/apt/periodic/update-success-stamp" "$root/var/lib/apt/periodic/update-stamp"
run_status --sudo
check '^info: APT last refreshed its package lists successfully 10 days ago; the daily refresh runs within hours of boot'
check '^info: unattended upgrades last ran 5 days ago; they run within hours of boot'
printf '95400.25 20000.00\n' > "$root/proc/uptime"

# A fresh successful refresh is not contradicted by old, unchanged repository metadata.
touch "$root/var/lib/apt/periodic/update-success-stamp" "$root/var/lib/apt/periodic/update-stamp"
run_status --sudo
refute 'APT last refreshed'
check '^info: repository archive.ubuntu.com/ubuntu/dists/resolute: last published 40 days ago'

# A diagnostic that is installed but fails, and a delegated credential check that times out, leave the
# assessment incomplete instead of reading as healthy.
cp "$stubs/timedatectl" "$test_dir/timedatectl"
printf '#!/usr/bin/env bash\necho "Failed to query server: Connection timed out" >&2\nexit 1\n' > "$stubs/timedatectl"
export DOTCONFIG_MACHINE_CREDS_TIMEOUT=0.01
run_status --sudo
unset DOTCONFIG_MACHINE_CREDS_TIMEOUT
check '^check failed: clock synchronization: timedatectl exited 1: Failed to query server: Connection timed out'
check '^check failed: dotconfig creds status did not finish within 0.01 s; domain login health is not assessed'
check '^check failed: dotconfig creds check-logs --days 2 did not finish within 0.01 s'
check '^Summary: problems found: [0-9]* current, [0-9]* earlier not seen to recover, [0-9]* earlier and recovered; assessment incomplete: 3 checks failed$'
cp "$test_dir/timedatectl" "$stubs/timedatectl"

# The verdict keeps problems, failed diagnostics, and expected limits apart.
verdict() {
    python3 - "$repo_root/scripts/machine-status.py" "$1" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("machine_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
text, status = module.summary(json.loads(sys.argv[2]))
print(f"{status} {text}")
PYEOF
}
[[ "$(verdict '{}')" == '0 healthy within the checked scope' ]]
[[ "$(verdict '{"unchecked": 2, "ok": 5}')" == '0 healthy within the checked scope; 2 not checked (need --sudo, or not applicable)' ]]
[[ "$(verdict '{"failed": 1}')" == '3 assessment incomplete: 1 check failed; no problems found in what was checked' ]]
[[ "$(verdict '{"warning": 2, "failed": 1, "unchecked": 1}')" == '1 problems found: 2 current; assessment incomplete: 1 check failed; 1 not checked (need --sudo, or not applicable)' ]]
# An incident not seen to recover still counts as a problem; one that recovered leaves the machine healthy now.
[[ "$(verdict '{"earlier": 1, "recovered": 2}')" == '1 problems found: 1 earlier not seen to recover, 2 earlier and recovered' ]]
[[ "$(verdict '{"recovered": 2, "unchecked": 1}')" == '0 healthy within the checked scope; 2 earlier and recovered; 1 not checked (need --sudo, or not applicable)' ]]
[[ "$(verdict '{"recovered": 1, "failed": 1}')" == '3 assessment incomplete: 1 check failed; no problems found in what was checked; 1 earlier and recovered' ]]

# The account, its session, installation and proxy environment, for a target named with --user. /etc/environment
# disagrees with itself and points at a missing CA file; the user manager lacks https_proxy; the configured local
# proxy is not running.
printf 'LANG=C.UTF-8\nHTTP_PROXY=http://127.0.0.1:3128\nhttp_proxy=http://127.0.0.1:3129\nXDG_CONFIG_HOME=/home/carol-home/.config/\nXDG_CACHE_HOME=/var/tmp/carol-cache\n' > "$test_dir/manager-env"
closed_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 - "$root" "$repo_root" "$me" "$closed_port" <<'EOF'
import importlib.util, os, sys
from pathlib import Path

root, repo, uid, port = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
spec = importlib.util.spec_from_file_location("machine_status", repo / "scripts/machine-status.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = root / "home/carol-home"
for relative in module.managed_targets():
    (home / relative).parent.mkdir(parents=True, exist_ok=True)
    (home / relative).write_text("managed\n")
(home / ".local/bin/old-tool").symlink_to(home / ".local/bin/removed-tool")
(home / ".zshrc.local").write_text("export SECRET=1\n")
os.chmod(home / ".zshrc.local", 0o644)
state = home / ".config/dotconfig"
state.mkdir(parents=True, exist_ok=True)
(state / "proxy.mode").write_text("on\n")
(state / "proxy.local").write_text(f"export https_proxy='http://proxyuser:SecretMustNeverPrint@127.0.0.1:{port}'\n")
(home / ".local/share/chezmoi/.git").mkdir(parents=True)
(home / ".local/share/chezmoi/.git/HEAD").write_text("ref: refs/heads/master\n")
runtime = root / f"run/user/{uid}"
runtime.mkdir(parents=True)
os.chmod(runtime, 0o700)
(runtime / "bus").write_text("")
(root / "etc/environment").write_text(
    'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"\n# dotconfig proxy begin\n'
    f'http_proxy="http://127.0.0.1:{port}"\nhttps_proxy="http://127.0.0.1:{port}"\n'
    'HTTPS_PROXY="http://10.0.0.9:8080"\nSSL_CERT_FILE="/etc/ssl/corp-ca.pem"\n# dotconfig proxy end\n')
(home / ".config/chezmoi").mkdir(parents=True)
(home / ".config/chezmoi/chezmoi.toml").write_text('sourceDir = "~/code/dotconfig"\n')
(home / "code/dotconfig/.git").mkdir(parents=True)
# bob's dotconfig command was rendered from a checkout outside chezmoi's default, which holds a decoy.
bob = root / "home/bob"
(bob / ".local/share/chezmoi/.git").mkdir(parents=True)
(bob / ".local/share/chezmoi/.git/config").write_text("[core]\n")
(bob / ".local/bin").mkdir(parents=True)
(bob / ".local/bin/dotconfig").write_text('#!/usr/bin/env bash\nSOURCE_DIR="/home/bob/src/dotconfig/home"\n')
(bob / "src/dotconfig/home").mkdir(parents=True)
(bob / "src/dotconfig/.git").mkdir()
for name in ("config", "HEAD"):
    (bob / "src/dotconfig/.git" / name).write_text("x\n")
(bob / ".zshrc").write_text("managed\n")
EOF
run_status --sudo --user carol
check '^Account and session (carol):'
check '^warning: XDG_CACHE_HOME=/var/tmp/carol-cache does not exist; programs that honor it lose the files dotconfig put in ~/.cache'
refute 'XDG_CONFIG_HOME'
check "^info: uid $me, home /home/carol-home, shell /bin/zsh, 2 groups"
check '^info: session 4: wayland user session on seat0 through gdm-password, active$'
check '^info: session 7: tty user session through sshd, online, remote$'
check '^info: one user manager and user bus serve all of these sessions'
refute 'runtime directory'
refute 'no user D-Bus socket'
check '^Installation (carol):'
check '^info: dotconfig checkout: /home/carol-home/code/dotconfig (from ~/.config/chezmoi/chezmoi.toml)$'
check '^warning: ~/.local/bin/old-tool is a broken symlink'
check '^warning: ~/.zshrc.local is readable or writable by other users'
refute 'is owned by'
refute 'in the dotconfig repository belongs\? to another account'
check '^info: dotconfig proxy is on (http://127.0.0.1:[0-9]*)$'
check "^warning: the user manager: http_proxy=http://127.0.0.1:3129 but HTTP_PROXY=http://127.0.0.1:3128"
check '^warning: the user manager has no https_proxy although dotconfig proxy is on: desktop apps and user services connect directly'
check "^warning: /etc/environment: https_proxy=http://127.0.0.1:$closed_port but HTTPS_PROXY=http://10.0.0.9:8080"
check '^warning: /etc/environment: SSL_CERT_FILE=/etc/ssl/corp-ca.pem does not exist'
check '^info: environments inspected: the user manager, /etc/environment$'
check "^warning: nothing listens on 127.0.0.1:$closed_port"
refute 'SecretMustNeverPrint'
refute 'proxyuser'

# Another account: files and a repository it does not own, and no session.
run_status --sudo --user bob
check '^warning: home /home/bob is owned by [a-z0-9 ]*, not bob'
check '^info: bob has no session and no running user manager'
check '^warning: ~/.zshrc is owned by [a-z0-9 ]*, not bob; updates as bob cannot replace it'
check '^info: dotconfig checkout: /home/bob/src/dotconfig (from ~/.local/bin/dotconfig)$'
check '^warning: 2 files in the dotconfig repository belong to another account'
run_status --sudo --user nobody-here
check '^warning: NSS does not resolve nobody-here'
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=0
run_status --user bob
check '^not checked: bob is another account; its session, files and environment need --sudo'
check "^not checked: bob's files need --sudo"
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=1

# Probes take the route of each inspected environment and name the stage that failed. The fake proxy splits its
# answer across writes, so a reader that stops at the first one misreads it; in tunnel mode it then serves TLS
# with a certificate only one environment trusts.
# The name goes in subjectAltName: verifiers need not fall back to the common name (macOS builds do not).
printf '[req]\ndistinguished_name = dn\nx509_extensions = ext\n[dn]\n[ext]\nsubjectAltName = DNS:localhost\nbasicConstraints = critical,CA:TRUE\n' \
    > "$test_dir/tls.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -config "$test_dir/tls.cnf" \
    -keyout "$test_dir/tls.key" -out "$test_dir/tls.pem" > /dev/null 2>&1
mkdir -p "$root/etc/ssl"
cp "$test_dir/tls.pem" "$root/etc/ssl/test-ca.pem"
cat > "$test_dir/fake-proxy.py" <<'EOF'
import socket, ssl, sys, threading, time
mode, port_file, cert, key = sys.argv[1:5]
status = b"HTTP/1.1 407 Proxy Authentication Required" if mode == "407" else b"HTTP/1.1 200 Connection established"
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen()
open(port_file, "w").write(str(server.getsockname()[1]))
def serve(client):
    with client:
        # The listener check connects and leaves without asking anything.
        if not client.recv(4096):
            return
        for part in (status[:10], status[10:] + b"\r\nVia: 1.1 fake\r", b"\n", b"\r\n"):
            client.sendall(part)
            time.sleep(0.05)
        if mode == "tunnel":
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            try:
                with context.wrap_socket(client, server_side=True) as tls:
                    tls.recv(1)
            except (ssl.SSLError, OSError):
                pass
while True:
    threading.Thread(target=serve, args=(server.accept()[0],), daemon=True).start()
EOF
fake_proxy() {
    rm -f "$test_dir/port"
    python3 "$test_dir/fake-proxy.py" "$1" "$test_dir/port" "$test_dir/tls.pem" "$test_dir/tls.key" &
    proxy_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$test_dir/port" ]] && break; sleep 0.2; done
    proxy_port="$(cat "$test_dir/port")"
}
dotconfig_state="$root/home/carol-home/.config/dotconfig"

# Every environment and the dotconfig setting agree, so one probe covers them all.
fake_proxy 407
printf 'on\n' > "$dotconfig_state/proxy.mode"
printf "export https_proxy='http://127.0.0.1:%s'\n" "$proxy_port" > "$dotconfig_state/proxy.local"
printf 'https_proxy=http://127.0.0.1:%s\n' "$proxy_port" > "$test_dir/manager-env"
printf 'https_proxy="http://127.0.0.1:%s"\n' "$proxy_port" > "$root/etc/environment"
run_status --sudo --user carol --probe localhost
kill "$proxy_pid"
check '^ok: a proxy listens on 127.0.0.1:'
check '^warning: probe localhost:443 (the user manager, /etc/environment): proxy answered HTTP/1.1 407 Proxy Authentication Required; the proxy wants authentication'
refute 'which no inspected environment uses'

# Unmanaged by dotconfig, both environments use a proxy of their own; only the user manager trusts the
# certificate, through its SSL_CERT_FILE. The diagnostic's own SSL_CERT_FILE is not borrowed.
fake_proxy tunnel
rm "$dotconfig_state/proxy.mode"
printf 'https_proxy=http://127.0.0.1:%s\nSSL_CERT_FILE=/etc/ssl/test-ca.pem\nCURL_CA_BUNDLE=/etc/ssl/test-ca.pem\n' "$proxy_port" > "$test_dir/manager-env"
printf 'https_proxy="http://127.0.0.1:%s"\n' "$proxy_port" > "$root/etc/environment"
SSL_CERT_FILE="$test_dir/tls.pem" run_status --sudo --user carol --probe localhost
kill "$proxy_pid"
check '^info: dotconfig proxy is unmanaged'
check '^ok: probe localhost:443 (the user manager): TLS verified (TLS.*) through proxy 127.0.0.1$'
check '^info: probe localhost:443 (the user manager): verified with OpenSSL.s SSL_CERT_FILE and SSL_CERT_DIR; tools that read CURL_CA_BUNDLE=/etc/ssl/test-ca.pem use those instead'
check '^warning: probe localhost:443 (/etc/environment): certificate not trusted'

# A trust file the account cannot read fails TLS for it. Root reads anything, so this needs an unprivileged runner.
if [[ "$me" != 0 ]]; then
    chmod 000 "$root/etc/ssl/test-ca.pem"
    run_status --sudo --user carol --probe localhost
    chmod 644 "$root/etc/ssl/test-ca.pem"
    check '^warning: probe localhost:443 (the user manager): SSL_CERT_FILE=/etc/ssl/test-ca.pem is not readable by carol, so TLS fails here'
fi

# The dotconfig setting, which no environment uses yet, is probed under its own label with its own bypass list;
# the user manager connects directly.
printf 'on\n' > "$dotconfig_state/proxy.mode"
printf "export https_proxy='http://127.0.0.1:%s'\nexport no_proxy='.invalid'\n" "$closed_port" > "$dotconfig_state/proxy.local"
printf 'LANG=C.UTF-8\n' > "$test_dir/manager-env"
rm "$root/etc/environment"
run_status --sudo --user carol --probe "127.0.0.1:$closed_port" --probe nonexistent.invalid
check "^warning: probe 127.0.0.1:$closed_port (the user manager): TCP connection to 127.0.0.1:$closed_port failed"
check "^warning: probe 127.0.0.1:$closed_port (the dotconfig proxy setting, which no inspected environment uses yet): TCP connection to 127.0.0.1:$closed_port failed"
check '^warning: probe nonexistent.invalid:443 (the user manager): DNS for nonexistent.invalid failed'
check '^warning: probe nonexistent.invalid:443 (the dotconfig proxy setting, which no inspected environment uses yet): DNS for nonexistent.invalid failed'

# DNS is asked once, within its deadline: connecting reuses those addresses, so a second lookup never happens.
python3 - "$repo_root" "$root" <<'EOF'
import contextlib, importlib.util, io, socket, sys, threading
from pathlib import Path
spec = importlib.util.spec_from_file_location("machine_status", Path(sys.argv[1]) / "scripts/machine-status.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen()
threading.Thread(target=lambda: server.accept()[0].close(), daemon=True).start()
real, calls = socket.getaddrinfo, []
def lookup(*args, **kwargs):
    calls.append(args)
    if len(calls) > 1:
        raise socket.gaierror("second lookup")
    return real(*args, **kwargs)
socket.getaddrinfo = lookup
machine = module.Machine(sys.argv[2], 0)
route = dict.fromkeys(module.PROXY_KEYS + module.CA_KEYS, "")
out = io.StringIO()
with contextlib.redirect_stdout(out):
    module.probe_endpoint(machine, f"localhost:{server.getsockname()[1]}", ["test"], route)
assert len(calls) == 1, calls
assert "TLS handshake failed" in out.getvalue(), out.getvalue()
EOF

# Arguments are validated before anything runs.
for bad in "--boot 1" "--boot x" "--examples 0" "--bogus" "--user" "--user a;b" "--probe" "--probe http://x"; do
    # shellcheck disable=SC2086 # Each case is a word list.
    if bash "$repo_root/scripts/machine.sh" status $bad > "$test_dir/out" 2>&1; then
        echo "accepted: $bad" >&2
        exit 1
    fi
    check '^Usage: dotconfig machine status'
done

# The command that reads another account's settings on a real machine (root /): through runuser, in an environment
# made only of the account's own values, whatever the caller exported.
XDG_CONFIG_HOME=/caller/config DCONF_PROFILE=caller DBUS_SESSION_BUS_ADDRESS=unix:path=/caller/bus \
    python3 - "$repo_root/scripts/machine-status.py" <<'EOF'
import importlib.util, sys
from pathlib import Path
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("machine_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
machine = SimpleNamespace(privileged=True, root=Path("/"), uid=1000, user="alice", reach=True,
                          target={"home": "/srv/home/alice"})
command = module.as_account(machine, ["gsettings", "list-recursively", "org.gnome.shell"],
                            {"XDG_CONFIG_HOME": "/srv/alice-config", "DCONF_PROFILE": "corp", "LANG": "C"})
assert command[:6] == ["runuser", "-u", "alice", "--", "env", "-i"], command
assert command[-3:] == ["gsettings", "list-recursively", "org.gnome.shell"], command
variables = command[6:-3]
for expected in ("HOME=/srv/home/alice", "XDG_CONFIG_HOME=/srv/alice-config", "DCONF_PROFILE=corp",
                 "XDG_RUNTIME_DIR=/run/user/1000", "USER=alice"):
    assert expected in variables, (expected, variables)
assert not any("caller" in value or value.startswith(("DBUS_", "LANG=")) for value in variables), variables
machine.uid = 0
assert module.as_account(machine, ["true"], {})[:2] == ["env", "-i"]
machine.reach = False
assert module.as_account(machine, ["true"], {}) is None
EOF

echo 'machine status tests passed'
