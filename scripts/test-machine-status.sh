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
    COREDUMP_COMM="gnome-shell", PRIORITY=2, SYSLOG_IDENTIFIER="systemd-coredump")
log(0, 400, "Killed /user.slice/user-1000.slice/app-code.scope due to memory pressure",
    SYSLOG_IDENTIFIER="systemd-oomd")
log(0, 500, "Sync failed: network unreachable", SYSLOG_IDENTIFIER="sync-agent", PRIORITY=3,
    _SYSTEMD_USER_UNIT="sync-agent.service", _UID=1000)
log(0, 502, "bob backup: destination full", SYSLOG_IDENTIFIER="bob-backup", _SYSTEMD_USER_UNIT="bob-backup.service",
    _UID=1001)
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
    is-system-running) echo degraded ;;
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
    *--active*) printf 'corp-wifi:802-11-wireless:wlp0s20f3\ncorp-vpn:vpn:wlp0s20f3\n' ;;
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
printf '#!/usr/bin/env bash\nprintf "1000 alice@corp.example no active\\n1001 bob yes lingering\\n"\n' > "$stubs/loginctl"
printf '#!/usr/bin/env bash\necho "default via 10.0.0.1 dev wlp0s20f3"\n' > "$stubs/ip"
printf '#!/usr/bin/env bash\necho "Global:"\necho "Link 3 (wlp0s20f3): 10.0.0.1"\necho "Link 9 (vpn0): 10.8.0.53"\n' \
    > "$stubs/resolvectl"
printf '#!/usr/bin/env bash\nprintf "NTP=yes\\nNTPSynchronized=no\\n"\n' > "$stubs/timedatectl"
printf '#!/usr/bin/env bash\necho "The following packages are only half configured:"\necho " libfoo1  library"\n' \
    > "$stubs/dpkg"
printf '#!/usr/bin/env bash\necho linux-firmware\n' > "$stubs/apt-mark"
printf '#!/usr/bin/env bash\necho "SecureBoot enabled"\n' > "$stubs/mokutil"
printf '#!/usr/bin/env bash\nprintf "120 profiles are loaded.\\n110 profiles are in enforce mode.\\n10 profiles are in complain mode.\\n2 processes are unconfined but have a profile defined.\\n"\n' \
    > "$stubs/aa-status"
printf '#!/usr/bin/env bash\necho "Status: active"\n' > "$stubs/ufw"
printf '#!/usr/bin/env bash\necho "dmesg: read kernel buffer failed: Operation not permitted" >&2\nexit 1\n' > "$stubs/dmesg"
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 0\\n"\n' > "$stubs/sssctl"
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"
export USER=alice@corp.example

check() {
    grep -q -- "$1" "$test_dir/out" || { cat "$test_dir/out" >&2; echo "Missing: $1" >&2; exit 1; }
}
refute() {
    if grep -q -- "$1" "$test_dir/out"; then cat "$test_dir/out" >&2; echo "Unexpected: $1" >&2; exit 1; fi
}
run_status() {
    status=0
    bash "$repo_root/scripts/machine.sh" status "$@" > "$test_dir/out" 2>&1 || status=$?
}

# With sudo: everything is visible.
export DOTCONFIG_MACHINE_TEST_PRIVILEGED=1 SUDO_USER=alice@corp.example SUDO_UID=1000
run_status --sudo --examples 2
[[ "$status" == 1 ]] || { cat "$test_dir/out" >&2; echo "expected exit 1, got $status" >&2; exit 1; }
check '^ok: Ubuntu 26.04.1 LTS'
check '^warning: systemd reports the system degraded'
check '^warning: kernel tainted: D kernel died recently (oops or BUG); W kernel warning; O out-of-tree module; E unsigned module'
check '^warning: reboot required by linux-image-6.20.0-15-generic'
check '^warning: the boot before this one ended without a clean shutdown.*disconnected from corp-wifi'
check '^info: Startup finished in 6.1s (firmware)'
check '^warning: userspace took 1 min 15 s to start'
check '^info: graphical.target reached after 74.1s in userspace'
check '^info: slowest units this boot: NetworkManager-wait-online.service (60.012s), snapd.seeded.service (5.300s)'
check '^info: login screen appeared 20.0 s after the kernel started'
check '^info: alice@corp.example logged in through gdm-password 30.0 s after the kernel started; no graphical session start recorded$'
check '^warning: alice@corp.example logged in through gdm-password 1 min 0 s after the kernel started; user services started in 2.5 s; desktop session ready 44.8 s after the password was accepted'
check '^info: slowest user units: tracker-miner-fs-3.service (30.5s)'
check '^warning: 2 failed password attempts through gdm-password before alice@corp.example logged in'
check '^info: domain logins go through SSSD'
check '^warning: backupd.service failed (Backup daemon): its main process exited with an error, exited 1 (generic failure), restarted 5 times first'
check '^    log: {"api_token": <hidden>, "error": "request failed"}'
check "^    log: {'password': <hidden>, 'user': 'svc'}"
check '^    log: Connection to backup.corp.example failed; api_token=<hidden>'
check '^warning: sync-agent.service failed (Sync agent): it restarted too often and was stopped'
check '^    log: Sync failed: network unreachable'
refute 'root decoy'
check '^  user units of alice@corp.example (uid 1000):'
check '^  user units of bob (uid 1001):'
check '^warning: bob-backup.service failed (Bob backup): its main process exited with an error, exited 2 (invalid arguments)'
check '^    log: bob backup: destination full'
check '^warning: broken.service did not load: bad-setting (org.freedesktop.systemd1.BadSetting'
check '^warning: gone.service is active but its unit file is gone'
check '^warning: refused.service was refused: Service has no ExecStart='
check "^info: /etc/systemd/system/odd.service: 1 setting ignored, e.g. Unknown key name 'Foo'"
check '^info: 1 system unit referenced but not installed (usually optional): plymouth-quit-wait.service'
check '^warning: NetworkManager.service was restarted 4 times this boot'
check '^info: pipewire.service was restarted 1 time this boot'
refute 'cups.service was restarted'
check '^warning: gnome-shell: 1 error (1 critical)'
check '^info: mount.cifs: 3 errors'
check '    e.g. Failed to mount /mnt/share202: Permission denied (x3)'
check '^warning: gnome-shell crashed 1 time this boot; see: coredumpctl info gnome-shell'
check '^info: 1 crash report in /var/crash: _usr_bin_gnome-shell.1000.crash'
check '^warning: the kernel OOM killer ended processes (1 time): chrome'
check '^warning: the kernel refused to load an unsigned or untrusted module'
check '^info: modules loaded without a valid signature and tainted the kernel (E); allowed because signatures are not enforced (1 time): example'
check '^info: firmware files not found (drivers often try several versions) (1 time): i915/mtl_gsc_1.bin'
check '^info: AppArmor denied access (1 time): snap.firefox.firefox'
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
check '^warning: system.slice/backupd.service: the kernel killed 1 process at its own memory limit (MemoryMax)'
check '^info: system.slice/cups.service reached its memory limit 2 times'
check '^warning: user.slice/user-1000.slice/user@1000.service/app.slice/app-code.scope: the OOM killer ended 1 process here; it did not reach its own limit'
check '^warning: legacy.slice/old.service: the OOM killer ended 1 process here'
refute '^warning: system.slice: '
refute '^warning: user.slice: '
refute '^warning: legacy.slice: '
check '^warning: user.slice/user-1000.slice/user@1000.service/app.slice/build.scope: 3 process starts refused at its task limit (TasksMax) or an enclosing one'
refute '^warning: user.slice/user-1000.slice/user@1000.service/app.slice: 3 process'
check '^warning: 90% of the kernel file handle table (fs.file-max) in use'
check '^warning: the kernel ran out of file handles (fs.file-max) (1 time)'
refute 'process and thread limit'
check '^warning: APT last refreshed its package lists successfully 10 days ago but tried 2 days ago: refreshes are failing'
check '^info: repository archive.ubuntu.com/ubuntu/dists/resolute: last published 40 days ago'
check '^warning: repository ppa.launchpadcontent.net/team/tool/ubuntu/dists/resolute: metadata expired 3 days ago (Valid-Until)'
refute 'repository security.ubuntu.com'
check '^warning: the daily APT refresh failed to fetch 1 time this boot'
check '^warning: unattended upgrades last ran 5 days ago'
check '^warning: DKMS module nvidia is not installed for kernel 6.20.0-15-generic; that kernel boots without it'
check '^warning: /boot has 97 MiB free but a kernel and its initrd take about 105 MiB'
check '^warning: 7% of 15.3 GiB memory available'
check '^info: 75% of swap used'
check '^warning: processes stalled on memory 6.50% of the last 5 minutes'
check '^warning: systemd-oomd killed 1 unit for memory pressure'
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
check '^warning: 1 snap change failed recently'
check '^    e.g. Auto-refresh snap "code"'
check '^info: SecureBoot enabled'
check '^ok: AppArmor is enabled'
check '^info: last package change: 2026-10-28  09:12:01'
check '^info: Archived and active journals take up 1.2G'
check '^info: AppArmor: 120 profiles loaded, 110 enforcing, 10 in complain mode'
check '^info: 2 processes started before their AppArmor profile loaded'
check '^info: firewall (ufw): active'
check '^warning: unattended-upgrades logged 1 error or warning'
check '^warning: BAT0: 71% discharging, holds 56% of its design capacity, 412 cycles'
check '^warning: running hot: x86_pkg_temp 93 °C'
check '^Summary: problems found: [0-9]* warnings$'
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
check '^warning: gnome-shell: 1 error (1 critical)'
check '^warning: sync-agent.service failed'
refute 'mount.cifs'
refute 'dotconfig creds check-logs --days'
check '^Summary: problems found: [0-9]* warnings; [0-9]* not checked (need --sudo, or not applicable)$'
refute 'check failed'

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
check '^Summary: problems found: [0-9]* warnings; assessment incomplete: 3 checks failed$'
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
[[ "$(verdict '{"warning": 2, "failed": 1, "unchecked": 1}')" == '1 problems found: 2 warnings; assessment incomplete: 1 check failed; 1 not checked (need --sudo, or not applicable)' ]]

# Arguments are validated before anything runs.
for bad in "--boot 1" "--boot x" "--examples 0" "--bogus"; do
    # shellcheck disable=SC2086 # Each case is a word list.
    if bash "$repo_root/scripts/machine.sh" status $bad > "$test_dir/out" 2>&1; then
        echo "accepted: $bad" >&2
        exit 1
    fi
    check '^Usage: dotconfig machine status'
done

echo "machine status tests passed"
