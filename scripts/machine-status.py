#!/usr/bin/env python3
"""Ubuntu 26.04 machine health for dotconfig machine status: what failed, why, and how long boot and login took.

Everything here is read-only and runs unprivileged. A check that needs root or the system journal says so as
"not checked" instead of failing or calling sudo. Files under /proc, /sys, /etc, /run and /var are read from the
inspected root so fixtures can exercise them; commands are found on PATH. Log lines are quoted with values of
settings named like passwords or secrets hidden, but they can include user and host names.
"""

import argparse
import glob
import json
import os
import pwd
import re
import shutil
import subprocess
from pathlib import Path

LABELS = {"unchecked": "not checked", "failed": "check failed"}
# A sensitive key, bare or quoted as in JSON or Python reprs, and its value: a quoted value up to its closing quote,
# escaped quotes included, else the rest of the line, since an unquoted value may contain spaces.
PRIVATE_VALUE = re.compile(r"""((?:\\?["'])?\b\w*(?:authtok|password|passwd|secret|token)\w*(?:\\?["'])?\s*[=:]\s*)"""
                           r"""(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S.*$)""", re.I)
COUNTS = {}

# Journal message IDs from systemd's catalog.
SYSTEM_STARTUP = "b07a249cd024414a82dd00cd181378ff"
USER_STARTUP = "eed00a68ffd84e31882105fd973abdd1"
UNIT_STARTED = "39f53479d3a045ac8e11786248231fbf"
COREDUMP = "fc2e22bc6ee647b6b90729ab34a250b1"

GRAPHICAL_PAM = re.compile(r"^(gdm-(?!launch-environment)\S+|login|sddm|lightdm)$")
SLOW_LOGIN_SECONDS = 30


def say(level, message):
    COUNTS[level] = COUNTS.get(level, 0) + 1
    print(f"{LABELS.get(level, level)}: {message}")


def section(title):
    print(f"\n{title}:")


def run(command, timeout=60):
    """Run a read-only command; None when it is not installed. A timeout reads as exit status 124."""
    if not shutil.which(command[0]):
        return None
    try:
        return subprocess.run(command, capture_output=True, text=True, errors="replace", check=False,
                              timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(command, 124, "", f"timed out after {timeout} s")


def failure(name, result):
    if result is None:
        return f"{name} is not installed"
    lines = [line.strip() for line in (result.stderr + "\n" + result.stdout).splitlines() if line.strip()]
    return f"{name} exited {result.returncode}: {clean(lines[0]) if lines else 'no output'}"


def clean(text, limit=200):
    text = PRIVATE_VALUE.sub(r"\1<hidden>", " ".join(str(text).split()))
    return text if len(text) <= limit else text[:limit - 3] + "..."


def seconds(usec):
    value = usec / 1e6
    if value >= 60:
        return f"{int(value // 60)} min {value % 60:.0f} s"
    return f"{value:.1f} s"


def plural(count, word):
    return f"{count} {word}" + ("" if count == 1 else "s")


def invoking_uid(user):
    """The UID of the account that ran sudo; None when unknown."""
    if os.environ.get("SUDO_UID", "").isdigit():
        return int(os.environ["SUDO_UID"])
    try:
        return pwd.getpwnam(user).pw_uid
    except (KeyError, TypeError):
        return None


class Machine:
    def __init__(self, root, boot):
        self.root = Path(root)
        self.boot = boot
        self.system_journal = None
        override = os.environ.get("DOTCONFIG_MACHINE_TEST_PRIVILEGED")
        self.privileged = override == "1" if override is not None else os.geteuid() == 0
        self.user = os.environ.get("SUDO_USER") if self.privileged else None
        self.user = self.user or os.environ.get("USER") or ""
        self.uid = invoking_uid(self.user) if self.privileged else os.getuid()
        self.kernel_entries = None
        self.hinted = False

    def path(self, relative):
        return self.root / relative

    def read(self, relative):
        try:
            return self.path(relative).read_text(errors="replace")
        except OSError:
            return None

    def journal(self, *args, user=False):
        """Journal entries as dicts for this boot, oldest first; None when journalctl is missing or fails."""
        command = ["journalctl", "--no-pager", "-q", "-o", "json", "-b", str(self.boot)]
        result = run(command + (["--user"] if user else []) + list(args))
        if result is None or (result.returncode not in (0, 1) and not result.stdout):
            return None
        entries = []
        for line in result.stdout.splitlines():
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            message = entry.get("MESSAGE")
            if isinstance(message, list):
                entry["MESSAGE"] = bytes(value & 0xFF for value in message).decode(errors="replace")
            elif not isinstance(message, str):
                entry["MESSAGE"] = ""
            entries.append(entry)
        return entries

    def sees_system_journal(self):
        """Whether the system journal is readable: PID 1 logs in every boot, but only root, adm and
        systemd-journal members see it."""
        if self.system_journal is None:
            entries = self.journal("-n", "1", "_PID=1")
            self.system_journal = bool(entries)
        return self.system_journal

    def journal_hint(self):
        if self.privileged:
            return "the journal has no system entries for this boot; is systemd-journald running?"
        if self.hinted:
            return "needs the system journal (see above)"
        self.hinted = True
        return ("the system journal is not readable by this account; run dotconfig machine status --sudo, or add "
                "the account to the adm group (sudo usermod -aG adm $USER, then log in again)")

    def user_flags(self):
        """systemctl flags that reach the invoking user's manager, also from root under sudo."""
        if not self.privileged:
            return ["--user"]
        return ["--user", "-M", f"{self.user}@"] if self.user and self.user != "root" else None


# --- System -----------------------------------------------------------------------------------------------------

TAINT = {0: ("P", "proprietary module", False), 1: ("F", "module force-loaded", False),
         4: ("M", "machine check exception (hardware error)", True), 5: ("B", "bad page referenced", True),
         7: ("D", "kernel died recently (oops or BUG)", True), 9: ("W", "kernel warning", False),
         10: ("C", "staging driver", False), 12: ("O", "out-of-tree module", False),
         13: ("E", "unsigned module", False), 14: ("L", "soft lockup", True), 15: ("K", "live patched", False)}


def check_system(machine):
    section("System")
    release = dict(re.findall(r'^(\w+)="?([^"\n]*)"?$', machine.read("etc/os-release") or "", re.M))
    name = release.get("PRETTY_NAME", "unknown OS")
    if release.get("ID") != "ubuntu" or not release.get("VERSION_ID", "").startswith("26.04"):
        say("info", f"{name}; these checks target Ubuntu 26.04")
    else:
        say("ok", name)
    kernel = (machine.read("proc/sys/kernel/osrelease") or "").strip()
    uptime = (machine.read("proc/uptime") or "").split()
    if kernel or uptime:
        say("info", "kernel " + (kernel or "unknown") + (f", up {seconds(float(uptime[0]) * 1e6)}" if uptime else ""))

    result = run(["systemctl", "is-system-running"])
    state = result.stdout.strip() if result else ""
    if result is None:
        say("unchecked", "systemd state: systemctl is not installed")
    elif state == "running":
        say("ok", "systemd reports the system running")
    elif state in ("starting", "initializing"):
        say("info", f"systemd is still {state}; boot has not finished")
        pending_jobs()
    elif state == "degraded":
        say("warning", "systemd reports the system degraded: at least one unit failed (see Services)")
    else:
        say("warning", f"systemd reports the system {state or 'in an unknown state'}")

    tainted = (machine.read("proc/sys/kernel/tainted") or "0").strip()
    if tainted.isdigit() and int(tainted):
        flags = [TAINT[bit] for bit in sorted(TAINT) if int(tainted) >> bit & 1]
        serious = [f"{flag} {text}" for flag, text, bad in flags if bad]
        other = [f"{flag} {text}" for flag, text, bad in flags if not bad]
        if serious:
            say("warning", "kernel tainted: " + "; ".join(serious + other))
        else:
            say("info", "kernel tainted: " + "; ".join(other or [f"value {tainted}"]))

    if machine.path("run/reboot-required").exists():
        packages = sorted(set((machine.read("run/reboot-required.pkgs") or "").split()))
        say("warning", "reboot required" + (f" by {', '.join(packages[:8])}" if packages else ""))
    check_previous_shutdown(machine)


CLEAN_SHUTDOWN = re.compile(r"Journal stopped|Reached target .*(shutdown\.target|final\.target|Power-?Off|Reboot|"
                            r"System Shutdown)|Stopping Journal Service|systemd-shutdown|Shutting down\.|"
                            r"journal: Journal stopped", re.I)


def check_previous_shutdown(machine):
    if not machine.sees_system_journal():
        say("unchecked", "how the previous boot ended: " + machine.journal_hint())
        return
    previous = machine.boot - 1
    result = run(["journalctl", "--no-pager", "-q", "-o", "json", "-b", str(previous), "-n", "60"])
    if result is None or result.returncode != 0 or not result.stdout.strip():
        say("info", "no earlier boot in the journal")
        return
    entries = []
    for line in result.stdout.splitlines():
        try:
            entries.append(json.loads(line))
        except ValueError:
            continue
    messages = [entry.get("MESSAGE") if isinstance(entry.get("MESSAGE"), str) else "" for entry in entries]
    if any(CLEAN_SHUTDOWN.search(message) for message in messages):
        say("ok", "the boot before this one shut down cleanly")
        return
    last = clean(messages[-1], 120) if messages else "nothing"
    if any(re.search(r"PM: suspend entry|Reached target .*Sleep|Starting .*[Ss]uspend", m) for m in messages[-15:]):
        say("warning", f"the boot before this one ended while suspending or suspended (last message: {last})")
    else:
        say("warning", "the boot before this one ended without a clean shutdown: a crash, freeze, power loss, or "
                       f"forced power-off (last message: {last})")


# --- Boot and login timing --------------------------------------------------------------------------------------

def check_timing(machine):
    section("Boot and login timing")
    startup = machine.journal("MESSAGE_ID=" + SYSTEM_STARTUP)
    analyze = run(["systemd-analyze", "time"]) if machine.boot == 0 else None
    if startup:
        say("info", clean(startup[-1]["MESSAGE"].rstrip(".")))
        userspace = int(startup[-1].get("USERSPACE_USEC") or 0)
        if userspace > 60e6:
            say("warning", f"userspace took {seconds(userspace)} to start"
                + ("; the slowest units are below" if machine.boot == 0 else ""))
    elif analyze is not None and analyze.returncode == 0:
        for line in analyze.stdout.strip().splitlines():
            say("info", clean(line.rstrip(".")))
    elif analyze is not None and "not yet finished" in analyze.stdout + analyze.stderr:
        say("info", "boot has not finished yet")
    elif not machine.sees_system_journal():
        say("unchecked", "boot time: " + machine.journal_hint())
    else:
        say("info", "no startup time recorded for this boot")
    if analyze is not None and analyze.returncode == 0:
        for line in analyze.stdout.splitlines():
            if "reached after" in line:
                say("info", clean(line.strip().rstrip(".")))

    if machine.boot == 0:
        slowest = blame(["systemd-analyze", "blame", "--no-pager"], 5)
        if slowest:
            say("info", "slowest units this boot: " + ", ".join(slowest))
    check_logins(machine)


def blame(command, count):
    result = run(command)
    if result is None or result.returncode != 0:
        return []
    slowest = []
    for line in result.stdout.splitlines()[:count]:
        parts = line.split()
        if len(parts) >= 2:
            slowest.append(f"{parts[-1]} ({' '.join(parts[:-1])})")
    return slowest


SESSION_OPENED = re.compile(r"pam_unix\(([^:]+):session\): session opened for user ([^\s(]+)(?:\(uid=(\d+)\))?")
AUTH_FAILURE = re.compile(r"pam_\w+\(([^:]+):auth\): (?:authentication failure|received for user .*: "
                          r"(?!0 )\d+ \()")


def check_logins(machine):
    if not machine.sees_system_journal():
        say("unchecked", "login timeline: " + machine.journal_hint())
        user_startup(machine)
        return
    auth = machine.journal("SYSLOG_FACILITY=10", "SYSLOG_FACILITY=4") or []
    startups = machine.journal("MESSAGE_ID=" + USER_STARTUP) or []
    graphical = machine.journal("MESSAGE_ID=" + UNIT_STARTED, "USER_UNIT=graphical-session.target") or []
    greeter = next((e for e in auth if (SESSION_OPENED.search(e["MESSAGE"]) or [None, ""])[1]
                    == "gdm-launch-environment"), None)
    if greeter:
        say("info", f"login screen appeared {seconds(monotonic(greeter))} after the kernel started")

    logins, failures, domain = [], {}, False
    for entry in auth:
        message = entry["MESSAGE"]
        domain = domain or "pam_sss(" in message
        failed = AUTH_FAILURE.search(message)
        if failed:
            failures[failed.group(1)] = failures.get(failed.group(1), 0) + 1
            continue
        opened = SESSION_OPENED.search(message)
        if opened and GRAPHICAL_PAM.match(opened.group(1)):
            logins.append((entry, opened.group(1), opened.group(2), opened.group(3), failures.pop(opened.group(1), 0)))
    if not logins:
        say("info", "no graphical or console login recorded in this boot")
    used = set()
    for index, (entry, service, user, uid, failed_before) in enumerate(logins):
        start = monotonic(entry)
        unit = f"user@{uid}.service" if uid else None
        # Events after the next login of the same account belong to that login, not to this one.
        end = next((monotonic(later[0]) for later in logins[index + 1:] if later[3] == uid), float("inf"))

        def first(events):
            found = next((e for e in events if e.get("_SYSTEMD_UNIT") == unit and start <= monotonic(e) < end
                          and id(e) not in used), None)
            if found is not None:
                used.add(id(found))
            return found
        ready, manager = first(graphical), first(startups)
        text = f"{user} logged in through {service} {seconds(start)} after the kernel started"
        if manager and manager.get("USERSPACE_USEC"):
            text += f"; user services started in {seconds(int(manager['USERSPACE_USEC']))}"
        if ready:
            took = monotonic(ready) - start
            text += f"; desktop session ready {seconds(took)} after the password was accepted"
            say("warning" if took > SLOW_LOGIN_SECONDS * 1e6 else "info", text)
            flags = machine.user_flags()
            if took > SLOW_LOGIN_SECONDS * 1e6 and machine.boot == 0 and user == machine.user and flags:
                slowest = blame(["systemd-analyze"] + flags + ["blame", "--no-pager"], 5)
                if slowest:
                    say("info", "slowest user units: " + ", ".join(slowest))
        else:
            say("info", text + ("; no graphical session start recorded" if service.startswith("gdm") else ""))
        if failed_before:
            say("warning", f"{plural(failed_before, 'failed password attempt')} through {service} before {user} "
                           "logged in")
    if domain:
        say("info", "domain logins go through SSSD; for cached passwords and offline-login causes run: "
                    "dotconfig creds status and dotconfig creds check-logs")


def user_startup(machine):
    startups = machine.journal("MESSAGE_ID=" + USER_STARTUP, user=True) or []
    if startups and startups[-1].get("USERSPACE_USEC"):
        say("info", f"your user services started in {seconds(int(startups[-1]['USERSPACE_USEC']))}")


def monotonic(entry):
    return int(entry.get("__MONOTONIC_TIMESTAMP") or 0)


# --- Services ---------------------------------------------------------------------------------------------------

def user_managers(machine):
    """(name, uid, systemctl flags) for each user manager to inspect: under sudo every running one, from
    loginctl (logged-in and lingering accounts); otherwise only the caller's own."""
    if not machine.privileged:
        return [(machine.user, machine.uid, ["--user"])]
    result = run(["loginctl", "list-users", "--no-legend", "--no-pager"])
    managers = []
    if result is not None and result.returncode == 0:
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0].isdigit():
                managers.append((parts[1], int(parts[0]), ["--user", "-M", f"{parts[1]}@"]))
    if not managers and machine.user_flags():
        managers.append((machine.user, machine.uid, machine.user_flags()))
    return managers


def check_services(machine):
    section("Services")
    units_of(machine, "system", [], None)
    managers = user_managers(machine)
    if not managers:
        say("unchecked", "user units: no running user manager found; run through sudo from your own account")
    for name, uid, flags in managers:
        if machine.privileged:
            print(f"  user units of {name} (uid {uid}):")
        units_of(machine, "user", flags, uid)


def units_of(machine, scope, flag, uid):
    result = run(["systemctl"] + flag + ["list-units", "--failed", "--all", "--no-legend", "--plain", "--no-pager"])
    if result is None or result.returncode != 0:
        say("unchecked" if scope == "user" else "failed", f"failed {scope} units: {failure('systemctl', result)}")
        return
    units = [line.split()[0] for line in result.stdout.splitlines() if line.split()]
    if not units:
        say("ok", f"no failed {scope} units")
    for unit in units:
        explain_failed(machine, unit, flag, uid)
    reported = unit_file_problems(machine) if scope == "system" else set()
    load_problems(scope, flag, reported)
    restarts(scope, flag)


def unit_properties(flag, units, names):
    result = run(["systemctl"] + flag + ["show", "--no-pager"] + ["-p" + name for name in names] + list(units))
    if result is None or result.returncode != 0:
        return []
    blocks = []
    for block in result.stdout.strip().split("\n\n"):
        blocks.append(dict(line.split("=", 1) for line in block.splitlines() if "=" in line))
    return blocks


def explain_failed(machine, unit, flag, uid):
    props = (unit_properties(flag, [unit], ["Description", "Result", "ExecMainCode", "ExecMainStatus",
                                            "LoadState", "LoadError", "NRestarts", "InactiveEnterTimestamp"])
             or [{}])[0]
    why = []
    if props.get("LoadState") not in (None, "", "loaded"):
        why.append(f"load state {props['LoadState']}" + (f" ({props['LoadError']})" if props.get("LoadError") else ""))
    result = props.get("Result", "")
    if result and result != "success":
        why.append(RESULTS.get(result, f"result {result}"))
    status = props.get("ExecMainStatus", "0")
    if status not in ("", "0"):
        code = {"1": "exited", "2": "killed by signal", "3": "dumped core"}.get(props.get("ExecMainCode", ""), "status")
        why.append(f"{code} {status}" + (f" ({EXIT_CODES[status]})" if code == "exited" and status in EXIT_CODES
                                          else ""))
    if props.get("NRestarts", "0") not in ("", "0"):
        why.append(f"restarted {props['NRestarts']} times first")
    description = props.get("Description", "")
    say("warning", f"{unit} failed" + (f" ({description})" if description and description != unit else "")
        + (": " + ", ".join(why) if why else ""))
    for line in unit_log(machine, unit, bool(flag), uid):
        print(f"    log: {line}")


RESULTS = {"exit-code": "its main process exited with an error", "signal": "its main process was killed",
           "core-dump": "its main process crashed and dumped core", "timeout": "it timed out",
           "watchdog": "its watchdog timed out", "start-limit-hit": "it restarted too often and was stopped",
           "resources": "systemd could not set it up (missing file, user, or directory)",
           "oom-kill": "the kernel or systemd-oomd killed it for memory", "protocol": "it broke the service protocol",
           "exec-condition": "its ExecCondition failed", "dependency": "a unit it needs failed"}
EXIT_CODES = {"1": "generic failure", "2": "invalid arguments", "3": "not implemented", "4": "insufficient privilege",
              "5": "not installed", "6": "not configured", "7": "not running", "200": "chdir", "203": "exec failed",
              "217": "user", "226": "namespace", "227": "no new privileges", "243": "credentials"}


def unit_log(machine, unit, user, uid):
    """The unit's last own log lines in this boot, else systemd's lines about it. A user unit is matched for the
    invoking account explicitly: journalctl --user-unit adds the caller's UID, which is 0 under sudo."""
    if not user:
        entries = machine.journal("-u", unit, "-n", "30") or []
    elif uid is None:
        return []
    else:
        uid = str(uid)
        entries = machine.journal("-n", "30", "_SYSTEMD_USER_UNIT=" + unit, "_UID=" + uid, "+",
                                  "USER_UNIT=" + unit, "_UID=" + uid, "+",
                                  "COREDUMP_USER_UNIT=" + unit, "COREDUMP_UID=" + uid,
                                  user=not machine.privileged) or []
    own = [e for e in entries if e.get("_SYSTEMD_UNIT") == unit or e.get("_SYSTEMD_USER_UNIT") == unit]
    chosen = own or [e for e in entries if not re.match(r"(Consumed|Starting|Started|Stopped|Stopping) ", e["MESSAGE"])]
    return [clean(e["MESSAGE"], 160) for e in chosen[-3:]]


def pending_jobs():
    """The start jobs that hold up the end of boot: the running ones are what the waiting ones wait for."""
    result = run(["systemctl", "list-jobs", "--no-legend", "--plain", "--no-pager"])
    if result is None or result.returncode != 0:
        return
    rows = [line.split() for line in result.stdout.splitlines() if len(line.split()) >= 4]
    running = [row[1] for row in rows if row[3] == "running"]
    if rows:
        say("info", f"{plural(len(rows), 'job')} pending" + (", running: " + ", ".join(running[:6]) if running else ""))


UNIT_FILE_PROBLEM = re.compile(r"^(/\S+?\.(?:service|socket|timer|mount|automount|path|target|slice|swap)):\d+: (.+)$|"
                               r"^([\w@.\\:-]+\.(?:service|socket|timer|mount|automount|path|target|slice|swap)): "
                               r"(.*(?:Refusing|bad unit file setting|fatal error|Unit configuration).*)$")


def unit_file_problems(machine):
    """Unit files systemd refused or only partly understood, from its own log: a unit with a bad setting is
    unloaded again soon after, so list-units alone misses it."""
    entries = [e for e in machine.journal("_PID=1", "-p", "0..4") or []]
    files, refused = {}, {}
    for entry in entries:
        matched = UNIT_FILE_PROBLEM.match(entry["MESSAGE"])
        if not matched:
            continue
        if matched.group(1):
            files.setdefault(matched.group(1), []).append(matched.group(2))
        else:
            refused[matched.group(3)] = matched.group(4)
    for unit, reason in sorted(refused.items()):
        say("warning", f"{unit} was refused: {clean(reason, 160)}")
    for path, problems in sorted(files.items()):
        say("info", f"{path}: {plural(len(problems), 'setting')} ignored, e.g. {clean(problems[-1], 120)}")
    return set(refused)


def load_problems(scope, flag, reported=()):
    result = run(["systemctl"] + flag + ["list-units", "--all", "--no-legend", "--plain", "--no-pager",
                                         "--state=bad-setting,error,not-found"])
    if result is None or result.returncode != 0:
        return
    rows = [line.split(None, 4) for line in result.stdout.splitlines() if line.split()]
    broken = [row[0] for row in rows if len(row) > 1 and row[1] in ("bad-setting", "error")]
    missing = [row[0] for row in rows if len(row) > 3 and row[1] == "not-found" and row[2] != "inactive"]
    absent = [row[0] for row in rows if len(row) > 1 and row[1] == "not-found" and row[0] not in missing]
    for unit in [unit for unit in broken if unit not in reported]:
        props = (unit_properties(flag, [unit], ["LoadState", "LoadError"]) or [{}])[0]
        say("warning", f"{unit} did not load: {props.get('LoadState', 'error')}"
            + (f" ({props['LoadError']})" if props.get("LoadError") else "") + f"; run: systemd-analyze verify {unit}")
    for unit in missing:
        say("warning", f"{unit} is active but its unit file is gone")
    if absent:
        say("info", f"{plural(len(absent), f'{scope} unit')} referenced but not installed (usually optional): "
            + ", ".join(absent[:8]) + (" ..." if len(absent) > 8 else ""))


def restarts(scope, flag):
    result = run(["systemctl"] + flag + ["list-units", "--type=service", "--no-legend", "--plain", "--no-pager"])
    if result is None or result.returncode != 0:
        return
    units = [line.split()[0] for line in result.stdout.splitlines() if line.split()]
    if not units:
        return
    restarted = [(p.get("Id", "?"), int(p["NRestarts"])) for p in unit_properties(flag, units, ["Id", "NRestarts"])
                 if p.get("NRestarts", "0").isdigit() and int(p["NRestarts"]) > 0]
    for unit, count in sorted(restarted, key=lambda item: -item[1]):
        say("warning" if count >= 3 else "info", f"{unit} was restarted {plural(count, 'time')} this boot")


# --- Journal ----------------------------------------------------------------------------------------------------

def normalized(message):
    return re.sub(r"\d+", "#", re.sub(r"\b(0x)?[0-9a-f]{6,}\b", "#", message.lower()))


def check_journal(machine, examples):
    section("Journal errors")
    if not machine.sees_system_journal():
        say("unchecked", "system errors: " + machine.journal_hint() + "; only your own processes are shown")
    entries = machine.journal("-p", "0..3")
    if entries is None:
        say("failed", "journalctl is not installed or failed")
        return
    groups = {}
    for entry in entries:
        if entry.get("_TRANSPORT") in ("kernel", "audit") or entry.get("MESSAGE_ID") == COREDUMP:
            continue
        name = (entry.get("SYSLOG_IDENTIFIER") or entry.get("_COMM") or entry.get("_SYSTEMD_UNIT") or "?").rstrip("]")
        group = groups.setdefault(name, {"count": 0, "critical": 0, "messages": {}})
        group["count"] += 1
        group["critical"] += int(entry.get("PRIORITY", "3")) <= 2
        key = normalized(entry["MESSAGE"])
        group["messages"][key] = (group["messages"].get(key, (0, ""))[0] + 1, entry["MESSAGE"])
    if not groups and machine.sees_system_journal():
        say("ok", "no errors logged this boot")
    ranked = sorted(groups.items(), key=lambda item: (-item[1]["critical"], -item[1]["count"]))
    for name, group in ranked[:12]:
        top = sorted(group["messages"].values(), key=lambda item: -item[0])[:examples]
        say("warning" if group["critical"] else "info",
            f"{name}: {plural(group['count'], 'error')}" + (f" ({group['critical']} critical)" if group["critical"]
                                                             else ""))
        for count, message in top:
            print(f"    e.g. {clean(message, 160)}" + (f" (x{count})" if count > 1 else ""))
    if len(ranked) > 12:
        say("info", f"{len(ranked) - 12} more programs logged errors; see: journalctl -b {machine.boot} -p err")
    check_crashes(machine)


def check_crashes(machine):
    dumps = machine.journal("MESSAGE_ID=" + COREDUMP) or []
    programs = {}
    for entry in dumps:
        name = entry.get("COREDUMP_COMM") or Path(entry.get("COREDUMP_EXE", "?")).name
        programs[name] = programs.get(name, 0) + 1
    for name, count in sorted(programs.items(), key=lambda item: -item[1]):
        say("warning", f"{name} crashed {plural(count, 'time')} this boot; see: coredumpctl info {name}")
    crashes = sorted(glob.glob(str(machine.path("var/crash/*.crash"))))
    if crashes:
        names = [Path(path).name for path in crashes]
        say("info", f"{plural(len(names), 'crash report')} in /var/crash: " + ", ".join(names[:6])
            + (" ..." if len(names) > 6 else ""))


# --- Kernel -----------------------------------------------------------------------------------------------------

KERNEL_RULES = (
    ("oom", "warning", "the kernel OOM killer ended processes", r"Out of memory: Killed process|oom-kill:"),
    ("module", "warning", "the kernel refused to load an unsigned or untrusted module; with Secure Boot, DKMS "
                          "modules load only once their signing key is enrolled (sudo mokutil --import)",
     r"Loading of (unsigned module|module with unavailable key) is rejected|Lockdown: .*unsigned module|"
     r"Key was rejected by service"),
    ("module-unsigned", "info", "modules loaded without a valid signature and tainted the kernel (E); allowed "
                                "because signatures are not enforced",
     r"module verification failed: signature and/or required key missing"),
    ("io", "warning", "disk I/O errors; check the drive with sudo smartctl -a",
     r"I/O error, dev \S+|Buffer I/O error|blk_update_request: .*error|critical medium error"),
    ("fs", "warning", "filesystem errors; an fsck may be needed",
     r"EXT4-fs (error|warning)|BTRFS (error|critical|warning)|XFS \(.*\): (Corruption|.*error)|"
     r"Remounting filesystem read-only|FAT-fs .*error"),
    ("nvme", "warning", "NVMe controller timeouts or resets",
     r"nvme\S*: .*(timeout|controller is down|resetting controller|I/O \d+ QID \d+ timeout)"),
    ("ata", "warning", "SATA link errors or resets", r"ata\d+(\.\d+)?: (exception Emask|failed command|"
                                                     r"hard resetting link|SError:)"),
    ("oops", "warning", "kernel bug or warning with a stack trace",
     r"\bBUG: |Oops: |general protection fault|kernel BUG at|WARNING: CPU: \d+ PID|------------\[ cut here"),
    ("hung", "warning", "tasks hung in the kernel", r"blocked for more than \d+ seconds|soft lockup|hard LOCKUP|"
                                                    r"rcu_(sched|preempt) detected stalls"),
    ("gpu", "warning", "graphics driver errors or GPU hangs",
     r"(i915|amdgpu|nouveau|nvidia|xe)\b.*(\*ERROR\*|GPU HANG|GPU hang|ring \S+ timeout|failed to|reset)"),
    ("thermal", "warning", "the CPU overheated or was throttled",
     r"temperature above threshold|cpu clock throttled|critical temperature|thermal.*shutdown"),
    ("mce", "warning", "hardware errors reported by the CPU", r"Machine check|\bMCE\b|Hardware Error"),
    ("firmware-failed", "warning", "a driver could not load its firmware (linux-firmware may be outdated)",
     r"(failed to load|could not load|unable to load|no suitable) (the )?firmware|firmware: failed to load"),
    ("firmware", "info", "firmware files not found (drivers often try several versions)",
     r"Direct firmware load for \S+ failed"),
    ("segfault", "info", "programs crashed in user space", r"\S+\[\d+\]: segfault at|traps: \S+\[\d+\] "),
    ("apparmor", "info", "AppArmor denied access", r'apparmor="DENIED"'),
    ("usb", "info", "USB devices failed to enumerate",
     r"usb \S+: (device descriptor read|device not accepting address|unable to enumerate|can't set config)"),
    ("acpi", "info", "ACPI firmware errors (usually harmless BIOS bugs)", r"ACPI (BIOS )?(Error|Warning)"),
)
KERNEL_PATTERNS = tuple((key, level, title, re.compile(pattern)) for key, level, title, pattern in KERNEL_RULES)


def kernel_messages(machine):
    """(priority, message) pairs for this boot from the journal, else from dmesg for the current boot."""
    if machine.kernel_entries is not None:
        return machine.kernel_entries
    entries = machine.journal("_TRANSPORT=kernel", "_TRANSPORT=audit") if machine.sees_system_journal() else None
    if entries:
        # journald splits a "name: " prefix of a /dev/kmsg line into SYSLOG_IDENTIFIER; dmesg shows it whole.
        machine.kernel_entries = [(int(e.get("PRIORITY", "6")), kernel_text(e)) for e in entries]
        return machine.kernel_entries
    machine.kernel_entries = []
    if machine.boot != 0:
        return machine.kernel_entries
    result = run(["dmesg", "-r", "--notime"])
    if result is not None and result.returncode == 0:
        for line in result.stdout.splitlines():
            matched = re.match(r"<(\d+)>(.*)", line)
            if matched:
                machine.kernel_entries.append((int(matched.group(1)) & 7, matched.group(2)))
    return machine.kernel_entries


def kernel_text(entry):
    name = entry.get("SYSLOG_IDENTIFIER", "kernel")
    if entry.get("_TRANSPORT") == "kernel" and name not in ("kernel", "") and \
            not entry["MESSAGE"].startswith(name + ":"):
        return f"{name}: {entry['MESSAGE']}"
    return entry["MESSAGE"]


def check_kernel(machine, examples):
    section("Kernel")
    messages = kernel_messages(machine)
    if not messages:
        say("unchecked", "kernel log: " + (machine.journal_hint() if not machine.sees_system_journal() else
                                           "no kernel messages") + "; dmesg is restricted to root on Ubuntu")
        return
    found, other = {}, {}
    for priority, message in messages:
        for key, level, title, pattern in KERNEL_PATTERNS:
            if pattern.search(message):
                found.setdefault(key, []).append(message)
                break
        else:
            if priority <= 3:
                key = normalized(message)
                other[key] = (other.get(key, (0, ""))[0] + 1, message)
    for key, level, title, _pattern in KERNEL_PATTERNS:
        if key in found:
            lines = found[key]
            detail = kernel_detail(key, lines)
            say(level, f"{title} ({plural(len(lines), 'time')})" + (f": {detail}" if detail else ""))
            for message in lines[-examples:]:
                print(f"    e.g. {clean(message, 160)}")
    if other:
        top = sorted(other.values(), key=lambda item: -item[0])
        say("info", f"{plural(sum(count for count, _ in top), 'other kernel error')}")
        for count, message in top[:max(examples, 5)]:
            print(f"    e.g. {clean(message, 160)}" + (f" (x{count})" if count > 1 else ""))
    if not found and not other:
        say("ok", "no kernel errors or known problems this boot")


def kernel_detail(key, lines):
    patterns = {"oom": r"Killed process \d+ \(([^)]+)\)", "module-unsigned": r"^(\S+): module verification", "firmware": r"Direct firmware load for (\S+)",
                "segfault": r"(\S+)\[\d+\]: segfault", "apparmor": r'profile="([^"]+)"',
                "io": r"dev (\w+)", "fs": r"\((\w+)\)"}
    if key not in patterns:
        return ""
    names = []
    for line in lines:
        matched = re.search(patterns[key], line)
        if matched and matched.group(1) not in names:
            names.append(matched.group(1))
    return ", ".join(names[:6]) + (" ..." if len(names) > 6 else "")


# --- Storage and memory ----------------------------------------------------------------------------------------

SKIP_FS = ("tmpfs", "devtmpfs", "squashfs", "overlay", "efivarfs", "ramfs", "fuse.snapfuse", "nsfs", "fuse.portal")


def check_storage(machine):
    section("Storage")
    for inodes in (False, True):
        result = run(["df", "-P", "-T"] + (["-i"] if inodes else []))
        if result is None or result.returncode not in (0, 1):
            say("failed", failure("df", result))
            return
        full = []
        for line in result.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 7 or parts[1] in SKIP_FS or parts[6].startswith("/snap/"):
                continue
            used = parts[5].rstrip("%")
            if used.isdigit() and int(used) >= 80:
                full.append((int(used), parts[6], parts[4]))
        for used, mount, free in sorted(full, reverse=True):
            what = "inodes" if inodes else "space"
            if inodes or not free.isdigit():
                free_text = f"{free} inodes left" if inodes else f"{free} free"
            elif int(free) >= 1024 * 1024:
                free_text = f"{int(free) / 1024 / 1024:.1f} GiB free"
            else:
                free_text = f"{int(free) // 1024} MiB free"
            say("warning" if used >= 90 else "info", f"{mount}: {used}% of {what} used ({free_text})")
        if not full and not inodes:
            say("ok", "all filesystems have at least 20% space free")
    mounts = machine.read("proc/self/mounts") or ""
    for line in mounts.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] in ("/", "/home", "/var", "/boot", "/boot/efi") and \
                "ro" in parts[3].split(","):
            say("warning", f"{parts[1]} is mounted read-only; the kernel may have remounted it after errors")
    smart(machine)


def smart(machine):
    if not machine.privileged:
        say("unchecked", "SMART health needs root; run: dotconfig machine status --sudo")
        return
    scan = run(["smartctl", "--scan"])
    if scan is None:
        say("unchecked", "SMART health: smartctl is not installed (sudo apt install smartmontools)")
        return
    for line in scan.stdout.splitlines():
        device = line.split()[0] if line.split() else ""
        if not device.startswith("/dev/"):
            continue
        result = run(["smartctl", "-H", "-j", device])
        try:
            passed = json.loads(result.stdout).get("smart_status", {}).get("passed")
        except (ValueError, AttributeError):
            passed = None
        if passed is True:
            say("ok", f"{device}: SMART health passed")
        elif passed is False:
            say("warning", f"{device}: SMART health FAILED; back up now and see: sudo smartctl -a {device}")
        else:
            say("unchecked", f"{device}: SMART health unknown ({failure('smartctl', result)})")


def check_memory(machine):
    section("Memory")
    info = {}
    for line in (machine.read("proc/meminfo") or "").splitlines():
        parts = line.replace(":", " ").split()
        if len(parts) >= 2 and parts[1].isdigit():
            info[parts[0]] = int(parts[1])
    if info.get("MemTotal"):
        available = info.get("MemAvailable", 0) * 100 // info["MemTotal"]
        text = f"{available}% of {info['MemTotal'] / 1024 / 1024:.1f} GiB memory available"
        say("warning" if available < 10 else "ok", text)
    if info.get("SwapTotal"):
        used = (info["SwapTotal"] - info.get("SwapFree", 0)) * 100 // info["SwapTotal"]
        if used >= 50:
            say("warning" if used >= 90 else "info", f"{used}% of swap used")
    elif "SwapTotal" in info:
        say("info", "no swap configured")
    pressure = machine.read("proc/pressure/memory") or ""
    matched = re.search(r"^full avg10=[\d.]+ avg60=[\d.]+ avg300=([\d.]+)", pressure, re.M)
    if matched and float(matched.group(1)) >= 5:
        say("warning", f"processes stalled on memory {matched.group(1)}% of the last 5 minutes")
    oomd = [e for e in machine.journal("SYSLOG_IDENTIFIER=systemd-oomd") or []
            if re.search(r"Killed|killed", e["MESSAGE"])]
    if oomd:
        say("warning", f"systemd-oomd killed {plural(len(oomd), 'unit')} for memory pressure this boot")
        print(f"    e.g. {clean(oomd[-1]['MESSAGE'], 160)}")


# --- Network, time, and domain login ---------------------------------------------------------------------------

def check_network(machine):
    section("Network and time")
    result = run(["nmcli", "-t", "-f", "STATE,CONNECTIVITY", "general"])
    if result is None or result.returncode != 0:
        say("unchecked", "NetworkManager state: " + failure("nmcli", result))
    else:
        state, _, connectivity = result.stdout.strip().partition(":")
        if state.startswith("connected") and connectivity in ("full", "unknown", ""):
            say("ok", f"NetworkManager {state}" + (f", connectivity {connectivity}" if connectivity else ""))
        else:
            say("warning", f"NetworkManager {state or 'unknown'}, connectivity {connectivity or 'unknown'}"
                + ("; a captive portal may need a login" if connectivity == "portal" else ""))
        active = run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active"])
        if active is not None and active.returncode == 0:
            vpns = [line.split(":")[0] for line in active.stdout.splitlines()
                    if re.search(r":(vpn|wireguard|tun)(:|$)", line)]
            say("info", "VPN active: " + ", ".join(vpns) if vpns else "no VPN connection active")
    route = run(["ip", "-o", "route", "show", "default"])
    if route is not None and route.returncode == 0 and not route.stdout.strip():
        say("warning", "no default route; nothing outside the local network is reachable")
    dns = run(["resolvectl", "dns"])
    if dns is not None and dns.returncode == 0:
        servers = sorted({server for line in dns.stdout.splitlines() for server in line.partition(":")[2].split()})
        say("info" if servers else "warning", "DNS servers: " + ", ".join(servers) if servers else
            "no DNS servers configured")
    time = run(["timedatectl", "show", "-p", "NTPSynchronized", "-p", "NTP"])
    if time is not None and time.returncode == 0:
        values = dict(line.split("=", 1) for line in time.stdout.splitlines() if "=" in line)
        if values.get("NTPSynchronized") == "yes":
            say("ok", "clock synchronized with NTP")
        else:
            say("warning", "clock not synchronized with NTP" + (" (NTP is off)" if values.get("NTP") == "no" else "")
                + "; Kerberos refuses tickets when the clock is off by more than 5 minutes")
    check_domain(machine)


def check_domain(machine):
    if not machine.path("etc/sssd/sssd.conf").exists() and not machine.path("etc/sssd").is_dir():
        return
    result = run(["systemctl", "is-active", "sssd.service"])
    state = result.stdout.strip() if result else ""
    if state == "active":
        say("ok", "sssd is running")
    elif result is not None:
        say("warning", f"sssd is {state or 'not running'}; domain logins fail; see: systemctl status sssd")
    if not machine.privileged:
        say("unchecked", "SSSD caches and login logs need root; run: dotconfig machine status --sudo")
        return
    days = 7
    uptime = (machine.read("proc/uptime") or "").split()
    if machine.boot == 0 and uptime:
        days = max(1, -(-int(float(uptime[0])) // 86400))
    scripts = Path(__file__).resolve().parent
    for title, command in (("dotconfig creds status", [scripts / "credentials-inspect.py", "inspect"]),
                           (f"dotconfig creds check-logs --days {days}",
                            [scripts / "credentials-logs.py", "--days", str(days)])):
        print(f"  {title}:")
        result = subprocess.run(["python3"] + [str(part) for part in command] + [str(machine.root)],
                                capture_output=True, text=True, errors="replace", check=False)
        for line in (result.stdout + result.stderr).splitlines():
            level = line.partition(":")[0]
            if level in ("warning", "possible cause"):
                COUNTS["warning"] = COUNTS.get("warning", 0) + 1
            print(f"    {line}" if line.strip() else "")


# --- Packages and security --------------------------------------------------------------------------------------

def check_packages(machine):
    section("Packages and security")
    audit = run(["dpkg", "--audit"])
    if audit is not None and audit.returncode == 0:
        if audit.stdout.strip():
            names = [line.split()[0] for line in audit.stdout.splitlines() if line[:1].isspace() and line.split()]
            say("warning", "dpkg reports half-installed or unconfigured packages"
                + (f" ({', '.join(names[:8])})" if names else "") + "; run: sudo dpkg --configure -a")
        else:
            say("ok", "no half-installed packages")
    updates = run([str(machine.path("usr/lib/update-notifier/apt-check"))])
    if updates is not None:
        matched = re.search(r"(\d+);(\d+)", updates.stderr + updates.stdout)
        if matched:
            pending, security = int(matched.group(1)), int(matched.group(2))
            if pending:
                say("info", f"{plural(pending, 'package update')} pending, {security} of them security updates")
            else:
                say("ok", "all packages are up to date")
    held = run(["apt-mark", "showhold"])
    if held is not None and held.stdout.split():
        say("info", "held packages: " + ", ".join(held.stdout.split()[:10]))
    check_snaps()
    secure = run(["mokutil", "--sb-state"])
    if secure is not None and secure.stdout.strip():
        say("info", clean(secure.stdout.strip().splitlines()[0]))
    enabled = (machine.read("sys/module/apparmor/parameters/enabled") or "").strip()
    if enabled == "Y":
        say("ok", "AppArmor is enabled")
    elif enabled:
        say("warning", "AppArmor is disabled; Ubuntu snaps and confined services rely on it")
    check_history(machine)
    if not machine.privileged:
        say("unchecked", "AppArmor profiles, firewall, and unattended-upgrades log need root; run: "
                         "dotconfig machine status --sudo")
        return
    profiles = run(["aa-status"])
    if profiles is not None and profiles.returncode in (0, 2, 3):
        counts = dict((what, int(number)) for number, what in
                      re.findall(r"^(\d+) (profiles are in complain mode|profiles are in enforce mode|"
                                 r"processes are unconfined but have a profile defined|profiles are loaded)",
                                 profiles.stdout, re.M))
        say("info", f"AppArmor: {counts.get('profiles are loaded', 0)} profiles loaded, "
                    f"{counts.get('profiles are in enforce mode', 0)} enforcing, "
                    f"{counts.get('profiles are in complain mode', 0)} in complain mode")
        unconfined = counts.get("processes are unconfined but have a profile defined", 0)
        if unconfined:
            say("info", f"{unconfined} process{'es' if unconfined != 1 else ''} started before their AppArmor "
                        "profile loaded; restarting them confines them")
    firewall = run(["ufw", "status"])
    if firewall is not None and firewall.returncode == 0:
        say("info", "firewall (ufw): " + firewall.stdout.strip().splitlines()[0].partition(":")[2].strip())
    log = machine.read("var/log/unattended-upgrades/unattended-upgrades.log")
    if log is not None:
        problems = [line for line in log.splitlines() if re.search(r"\b(ERROR|WARNING)\b", line)]
        if problems:
            say("warning", f"unattended-upgrades logged {plural(len(problems), 'error or warning')} since its log "
                           "was rotated; see /var/log/unattended-upgrades/unattended-upgrades.log")
            print(f"    e.g. {clean(problems[-1], 160)}")
        else:
            say("ok", "unattended-upgrades logged no errors since its log was rotated")


def check_history(machine):
    history = machine.read("var/log/apt/history.log") or ""
    starts = re.findall(r"^Start-Date: (.+)$", history, re.M)
    if starts:
        say("info", f"last package change: {starts[-1].strip()}")
    usage = run(["journalctl", "--disk-usage"])
    if usage is not None and usage.returncode == 0 and usage.stdout.strip():
        say("info", clean(usage.stdout.strip().splitlines()[-1].rstrip(".")))


def check_snaps():
    changes = run(["snap", "changes"])
    if changes is None or changes.returncode != 0:
        return
    lines = changes.stdout.splitlines()
    summary = lines[0].find("Summary") if lines else -1
    errors = [line[summary:] if summary > 0 else line for line in lines[1:]
              if len(line.split()) > 1 and line.split()[1] in ("Error", "Undone")]
    if errors:
        say("warning", f"{plural(len(errors), 'snap change')} failed recently; see: snap changes")
        print(f"    e.g. {clean(errors[-1], 160)}")
    warnings = run(["snap", "warnings", "--unicode=never"])
    if warnings is not None and warnings.returncode == 0:
        texts = re.findall(r"^warning:\s*\|?\s*(.+)$", warnings.stdout, re.M)
        for text in texts[:3]:
            say("info", "snap warning: " + clean(text, 160))


# --- Hardware ---------------------------------------------------------------------------------------------------

def check_hardware(machine):
    section("Hardware")
    printed = False
    for battery in sorted(glob.glob(str(machine.path("sys/class/power_supply/BAT*")))):
        values = {}
        for name in ("energy_full", "energy_full_design", "charge_full", "charge_full_design", "capacity",
                     "status", "cycle_count"):
            try:
                values[name] = Path(battery, name).read_text().strip()
            except OSError:
                pass
        full = values.get("energy_full") or values.get("charge_full")
        design = values.get("energy_full_design") or values.get("charge_full_design")
        text = f"{Path(battery).name}: {values.get('capacity', '?')}% {values.get('status', '').lower()}".rstrip()
        level = "info"
        if full and design and full.isdigit() and design.isdigit() and int(design):
            health = int(full) * 100 // int(design)
            text += f", holds {health}% of its design capacity"
            level = "warning" if health < 60 else "info"
        if values.get("cycle_count", "0") not in ("", "0"):
            text += f", {values['cycle_count']} cycles"
        say(level, text)
        printed = True
    hot = []
    for zone in sorted(glob.glob(str(machine.path("sys/class/thermal/thermal_zone*")))):
        try:
            temperature = int(Path(zone, "temp").read_text().strip()) / 1000
            kind = Path(zone, "type").read_text().strip()
        except (OSError, ValueError):
            continue
        if temperature >= 90:
            hot.append(f"{kind} {temperature:.0f} °C")
    if hot:
        say("warning", "running hot: " + ", ".join(hot))
    elif glob.glob(str(machine.path("sys/class/thermal/thermal_zone*"))):
        say("ok", "all thermal zones below 90 °C")
        printed = True
    if not printed and not hot:
        say("info", "no battery or thermal sensors found")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--boot", type=int, default=0, help="journal boot offset: 0 this boot, -1 the one before")
    parser.add_argument("--examples", type=int, default=1, help="log lines to quote per finding")
    parser.add_argument("root", nargs="?", default="/")
    args = parser.parse_args()
    machine = Machine(args.root, args.boot)
    if args.boot != 0:
        print(f"Journal sections read boot {args.boot}; disk, memory, network, and unit state are current.")
    check_system(machine)
    check_timing(machine)
    check_services(machine)
    check_journal(machine, args.examples)
    check_kernel(machine, args.examples)
    check_storage(machine)
    check_memory(machine)
    check_network(machine)
    check_packages(machine)
    check_hardware(machine)
    warnings = COUNTS.get("warning", 0)
    unchecked = COUNTS.get("unchecked", 0) + COUNTS.get("failed", 0)
    print(f"\nSummary: {plural(warnings, 'warning')}" + (f", {unchecked} not checked" if unchecked else ""))
    return 1 if warnings else 0


if __name__ == "__main__":
    raise SystemExit(main())
