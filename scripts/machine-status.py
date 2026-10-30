#!/usr/bin/env python3
"""Ubuntu 26.04 machine health for dotconfig machine status: what failed, why, and how long boot and login took.

Everything here is read-only and runs unprivileged. A check that needs root or the system journal says so as
"not checked" instead of failing or calling sudo. Files under /proc, /sys, /etc, /run and /var are read from the
inspected root so fixtures can exercise them; commands are found on PATH. Log lines are quoted with values of
settings named like passwords or secrets hidden, but they can include user and host names.
"""

import argparse
import ast
import email.utils
import glob
import json
import os
import pwd
import re
import importlib.util
import shlex
import shutil
import socket
import ssl
import stat
import subprocess
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

_spec = importlib.util.spec_from_file_location("credentials_inspect", Path(__file__).with_name("credentials-inspect.py"))
inspector = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(inspector)

# A problem is current state ("warning"), a logged incident not seen to clear ("earlier"), or one that cleared
# afterwards ("recovered"); the summary and exit status count them apart.
LABELS = {"unchecked": "not checked", "failed": "check failed"}
PROBLEMS = ("warning", "earlier", "recovered")
# Text that already tells the reader what to run next.
NEXT_MARKERS = ("see: ", "run: ", "to rule it out: ", "try: ")
# A sensitive key, bare or quoted as in JSON or Python reprs, and its value: a quoted value up to its closing quote,
# escaped quotes included, else the rest of the line, since an unquoted value may contain spaces.
PRIVATE_VALUE = re.compile(r"""((?:\\?["'])?\b\w*(?:authtok|password|passwd|secret|token)\w*(?:\\?["'])?\s*[=:]\s*)"""
                           r"""(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S.*$)""", re.I)
COUNTS = {}
FINDINGS = []
SECTION = [""]

# Journal message IDs from systemd's catalog.
SYSTEM_STARTUP = "b07a249cd024414a82dd00cd181378ff"
USER_STARTUP = "eed00a68ffd84e31882105fd973abdd1"
UNIT_STARTED = "39f53479d3a045ac8e11786248231fbf"
COREDUMP = "fc2e22bc6ee647b6b90729ab34a250b1"

GRAPHICAL_PAM = re.compile(r"^(gdm-(?!launch-environment)\S+|login|sddm|lightdm)$")
SLOW_LOGIN_SECONDS = 30
CREDS_TIMEOUT = float(os.environ.get("DOTCONFIG_MACHINE_CREDS_TIMEOUT", "300"))
# Resolving one account's groups longer than this makes every login, sudo and file-access check wait.
SLOW_GROUPS = float(os.environ.get("DOTCONFIG_MACHINE_SLOW_GROUPS", "2"))


def say(level, message, past=False, recovered=None, next_step=None, where=None, indent=""):
    """Print one finding. past: the evidence is a logged event (this boot or the one before), not current state;
    recovered: the condition was seen to clear afterwards (True), or not; next_step: the command to look further,
    added when the message does not already name one; where: what reported it, when not the section itself."""
    if next_step and level == "warning" and not any(marker in message for marker in NEXT_MARKERS):
        message += f"; see: {next_step}"
    if level == "warning" and past:
        level = "recovered" if recovered else "earlier"
    COUNTS[level] = COUNTS.get(level, 0) + 1
    FINDINGS.append((level, where or SECTION[0], message))
    print(f"{indent}{LABELS.get(level, level)}: {message}")


def incident(message, recovered=None, next_step=None):
    """A problem known from the logs: something that happened, which may or may not still hold."""
    say("warning", message, past=True, recovered=recovered, next_step=next_step)


def section(title):
    SECTION[0] = title
    print(f"\n{title}:")


def run(command, timeout=60):
    """Run a read-only command; None when it is not installed. A timeout reads as exit status 124."""
    if not shutil.which(command[0]):
        return None
    try:
        return subprocess.run(command, capture_output=True, text=True, errors="replace", check=False,
                              timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        # The full command, so a stalled query can be rerun by hand.
        return subprocess.CompletedProcess(command, 124, "", f"timed out after {timeout} s: {shlex.join(command)}")


def failure(name, result):
    if result is None:
        return f"{name} is not installed"
    lines = [line.strip() for line in (result.stderr + "\n" + result.stdout).splitlines() if line.strip()]
    return f"{name} exited {result.returncode}: {clean(lines[0]) if lines else 'no output'}"


def broken(what, name, result, ok=(0,)):
    """Report a diagnostic that is installed but did not work, so the assessment is marked incomplete. True when
    result is usable; False when the tool is missing (not applicable here) or failed."""
    if result is None:
        return False
    if result.returncode in ok:
        return True
    say("failed", f"{what}: {failure(name, result)}")
    return False


def clean(text, limit=200):
    text = PRIVATE_VALUE.sub(r"\1<hidden>", " ".join(str(text).split()))
    return text if len(text) <= limit else text[:limit - 3] + "..."


def seconds(usec):
    value = usec / 1e6
    if value >= 60:
        return f"{int(value // 60)} min {value % 60:.0f} s"
    return f"{value:.1f} s"


# How long a restarted service must have stayed up since its last start before it counts as recovered.
STABLE = 600


def uptime_seconds(machine):
    value = (machine.read("proc/uptime") or "").split()
    return float(value[0]) if value else None


def up_since_boot(props, uptime):
    """Seconds a unit has been active, from its monotonic start time; None when that is unknown."""
    entered = props.get("ActiveEnterTimestampMonotonic", "")
    if uptime is None or not entered.isdigit() or int(entered) == 0:
        return None
    return max(0.0, uptime - int(entered) / 1e6)


def restart_outcome(props, up_for):
    """(past, recovered, note) for a unit that restarted. A unit restarting now is a current problem; one that runs
    counts as recovered only after STABLE seconds up, since a crash loop is also active between crashes."""
    state, sub = props.get("ActiveState", ""), props.get("SubState", "")
    if sub == "auto-restart" or state in ("activating", "deactivating"):
        return False, None, f"; it is restarting now ({sub or state})"
    if state != "active":
        return True, False, f"; it is {state or 'not running'} now"
    if up_for is None:
        return True, False, "; it runs now, but how long it has stayed up is unknown"
    if up_for < STABLE:
        return True, False, f"; it runs, but only {seconds(up_for * 1e6)} since its last start"
    return True, True, f"; it has run {seconds(up_for * 1e6)} since its last start"


def owner_label(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return f"uid {uid}"


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


def resolve_account(name):
    """The account as NSS resolves it, the way login sees it: name, uid, gid, home, shell and all group ids.
    Domain accounts come from SSSD here, so the home is never guessed from the login name."""
    if not name:
        return None
    result = run(["getent", "passwd", name])
    if result is None or result.returncode != 0:
        return None
    fields = result.stdout.strip().split("\n")[0].split(":")
    if len(fields) < 7 or not fields[2].isdigit() or not fields[3].isdigit():
        return None
    started = time.monotonic()
    groups = run(["id", "-G", fields[0]])
    took = time.monotonic() - started
    gids = tuple(int(g) for g in groups.stdout.split() if g.isdigit()) if groups and groups.returncode == 0 else ()
    return {"name": fields[0], "uid": int(fields[2]), "gid": int(fields[3]), "home": fields[5], "shell": fields[6],
            "gids": gids or (int(fields[3]),), "groups_took": took}


class Machine:
    def __init__(self, root, boot, target=None):
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
        self.journal_failures = set()
        self.free_kib = {}
        self.vpns = None
        self.rules = None
        self.user_entries = None
        self.manager_environment = None
        self.settings_noted = False
        self.invoker = self.user
        # The account the user-level checks inspect: --user, else whoever ran the command (through sudo or not).
        self.target = resolve_account(target or self.user)
        if self.target:
            self.user, self.uid = self.target["name"], self.target["uid"]
        elif target:
            self.user, self.uid = target, None
        # Without root, another account's files, manager and environment are out of reach.
        self.reach = self.privileged or self.user == self.invoker

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
        result = run(command + (["--user"] if user else []) + list(args), timeout=120)
        if result is None:
            return None
        if result.returncode not in (0, 1) and not result.stdout:
            if "No such boot" not in result.stderr and "not available" not in result.stderr:
                key = failure("journalctl", result)
                if key not in self.journal_failures:
                    self.journal_failures.add(key)
                    say("failed", "journal query: " + key)
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

    def expectations(self):
        """The override files, read (and their mistakes reported) once."""
        if self.rules is None:
            self.rules = expectation_overrides(self)
        return self.rules

    def user_log(self):
        """The account's own warnings and errors this boot, from its processes; empty when out of reach."""
        if self.user_entries is None:
            reachable = self.uid is not None and self.reach
            self.user_entries = (self.journal("-p", "4", f"_UID={self.uid}", user=not self.privileged) or []
                                 if reachable else [])
        return self.user_entries

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
        say("warning", "systemd reports the system degraded: at least one unit failed (see Services)",
            next_step="systemctl --failed")
    elif not state:
        say("failed", "systemd state: " + failure("systemctl", result))
    else:
        say("warning", f"systemd reports the system {state}", next_step="systemctl list-jobs")

    tainted = (machine.read("proc/sys/kernel/tainted") or "0").strip()
    if tainted.isdigit() and int(tainted):
        flags = [TAINT[bit] for bit in sorted(TAINT) if int(tainted) >> bit & 1]
        serious = [f"{flag} {text}" for flag, text, bad in flags if bad]
        other = [f"{flag} {text}" for flag, text, bad in flags if not bad]
        if serious:
            say("warning", "kernel tainted: " + "; ".join(serious + other), next_step="journalctl -b -k -p warning")
        else:
            say("info", "kernel tainted: " + "; ".join(other or [f"value {tainted}"]))

    if machine.path("run/reboot-required").exists():
        packages = sorted(set((machine.read("run/reboot-required.pkgs") or "").split()))
        say("warning", "reboot required" + (f" by {', '.join(packages[:8])}" if packages else ""),
            next_step="cat /run/reboot-required.pkgs")
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
        incident(f"the boot before this one ended while suspending or suspended (last message: {last})",
            next_step="journalctl -b -1 -n 50")
    else:
        incident("the boot before this one ended without a clean shutdown: a crash, freeze, power loss, or "
                       f"forced power-off (last message: {last})", next_step="journalctl -b -1 -n 50")


# --- Boot and login timing --------------------------------------------------------------------------------------

def check_timing(machine):
    section("Boot and login timing")
    startup = machine.journal("MESSAGE_ID=" + SYSTEM_STARTUP)
    analyze = run(["systemd-analyze", "time"]) if machine.boot == 0 else None
    if startup:
        say("info", clean(startup[-1]["MESSAGE"].rstrip(".")))
        userspace = int(startup[-1].get("USERSPACE_USEC") or 0)
        if userspace > 60e6:
            incident(f"userspace took {seconds(userspace)} to start"
                + ("; the slowest units are below" if machine.boot == 0 else ""),
                    next_step="systemd-analyze critical-chain")
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
            say("warning" if took > SLOW_LOGIN_SECONDS * 1e6 else "info", text, past=True,
                next_step=f"systemd-analyze --user blame, as {user}")
            flags = machine.user_flags()
            if took > SLOW_LOGIN_SECONDS * 1e6 and machine.boot == 0 and user == machine.user and flags:
                slowest = blame(["systemd-analyze"] + flags + ["blame", "--no-pager"], 5)
                if slowest:
                    say("info", "slowest user units: " + ", ".join(slowest))
        else:
            say("info", text + ("; no graphical session start recorded" if service.startswith("gdm") else ""))
        if failed_before:
            incident(f"{plural(failed_before, 'failed password attempt')} through {service} before {user} "
                     "logged in", recovered=True, next_step=f"journalctl -b {machine.boot} SYSLOG_FACILITY=10")
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
    if broken("running user managers", "loginctl", result):
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
        # Unprivileged, a missing user bus means no user manager to ask, not a broken check.
        expected = scope == "user" and not machine.privileged
        say("unchecked" if expected else "failed", f"failed {scope} units: {failure('systemctl', result)}")
        return
    units = [line.split()[0] for line in result.stdout.splitlines() if line.split()]
    if not units:
        say("ok", f"no failed {scope} units")
    for unit in units:
        explain_failed(machine, unit, flag, uid)
    reported = unit_file_problems(machine) if scope == "system" else set()
    load_problems(scope, flag, reported)
    restarts(machine, scope, flag)


def unit_properties(flag, units, names):
    result = run(["systemctl"] + flag + ["show", "--no-pager"] + ["-p" + name for name in names] + list(units))
    if not broken("unit properties", "systemctl show", result):
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
        + (": " + ", ".join(why) if why else ""), next_step=f"systemctl{' --user' if flag else ''} status {unit}")
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
    if not broken("pending jobs", "systemctl list-jobs", result):
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
        say("warning", f"{unit} was refused: {clean(reason, 160)}", next_step=f"systemctl cat {unit}")
    for path, problems in sorted(files.items()):
        say("info", f"{path}: {plural(len(problems), 'setting')} ignored, e.g. {clean(problems[-1], 120)}")
    return set(refused)


def load_problems(scope, flag, reported=()):
    result = run(["systemctl"] + flag + ["list-units", "--all", "--no-legend", "--plain", "--no-pager",
                                         "--state=bad-setting,error,not-found"])
    if not broken(f"{scope} units that did not load", "systemctl list-units", result):
        return
    rows = [line.split(None, 4) for line in result.stdout.splitlines() if line.split()]
    unloaded = [row[0] for row in rows if len(row) > 1 and row[1] in ("bad-setting", "error")]
    missing = [row[0] for row in rows if len(row) > 3 and row[1] == "not-found" and row[2] != "inactive"]
    absent = [row[0] for row in rows if len(row) > 1 and row[1] == "not-found" and row[0] not in missing]
    for unit in [unit for unit in unloaded if unit not in reported]:
        props = (unit_properties(flag, [unit], ["LoadState", "LoadError"]) or [{}])[0]
        say("warning", f"{unit} did not load: {props.get('LoadState', 'error')}"
            + (f" ({props['LoadError']})" if props.get("LoadError") else "") + f"; run: systemd-analyze verify {unit}")
    for unit in missing:
        say("warning", f"{unit} is active but its unit file is gone", next_step="sudo systemctl daemon-reload")
    if absent:
        say("info", f"{plural(len(absent), f'{scope} unit')} referenced but not installed (usually optional): "
            + ", ".join(absent[:8]) + (" ..." if len(absent) > 8 else ""))


def restarts(machine, scope, flag):
    result = run(["systemctl"] + flag + ["list-units", "--type=service", "--no-legend", "--plain", "--no-pager"])
    if not broken(f"{scope} service restarts", "systemctl list-units", result):
        return
    units = [line.split()[0] for line in result.stdout.splitlines() if line.split()]
    if not units:
        return
    restarted = [p for p in unit_properties(flag, units, ["Id", "NRestarts", "ActiveState", "SubState",
                                                          "ActiveEnterTimestampMonotonic"])
                 if p.get("NRestarts", "0").isdigit() and int(p["NRestarts"]) > 0]
    user = " --user" if "--user" in flag else ""
    uptime = uptime_seconds(machine)
    for props in sorted(restarted, key=lambda p: -int(p["NRestarts"])):
        unit, count = props.get("Id", "?"), int(props["NRestarts"])
        past, recovered, note = restart_outcome(props, up_since_boot(props, uptime))
        say("warning" if count >= 3 or not past else "info", f"{unit} was restarted {plural(count, 'time')} this boot"
            + note, past=past, recovered=recovered, next_step=f"journalctl -b{user} -u {unit}")


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
                                                             else "") + " this boot", past=True,
            next_step=f"journalctl -b {machine.boot} -p err -t {name}")
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
        incident(f"{name} crashed {plural(count, 'time')} this boot; see: coredumpctl info {name}")
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
    ("firmware-failed", "warning", "a driver could not load its firmware (hypothesis: linux-firmware is outdated)",
     r"(failed to load|could not load|unable to load|no suitable) (the )?firmware|firmware: failed to load"),
    ("firmware", "info", "firmware files not found (drivers often try several versions)",
     r"Direct firmware load for \S+ failed"),
    ("segfault", "info", "programs crashed in user space", r"\S+\[\d+\]: segfault at|traps: \S+\[\d+\] "),
    ("apparmor", "info", "AppArmor denied access", r'apparmor="DENIED"'),
    ("usb", "info", "USB devices failed to enumerate",
     r"usb \S+: (device descriptor read|device not accepting address|unable to enumerate|can't set config)"),
    ("files", "warning", "the kernel ran out of file handles (fs.file-max)", r"VFS: file-max limit \d+ reached"),
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
            say(level, f"{title} ({plural(len(lines), 'time')} this boot)" + (f": {detail}" if detail else ""),
                past=True, next_step=f"journalctl -b {machine.boot} -k -p warning")
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

SKIP_FS = ("devtmpfs", "squashfs", "overlay", "efivarfs", "ramfs", "fuse.snapfuse", "nsfs", "fuse.portal")
# A full tmpfs here breaks logins, sockets, shared memory or temporary files even when every disk has room.
TMPFS_WATCHED = re.compile(r"^(/run|/run/user/\d+|/run/lock|/dev/shm|/tmp|/var/tmp)$")


def check_storage(machine):
    section("Storage")
    for inodes in (False, True):
        result = run(["df", "-P", "-T"] + (["-i"] if inodes else []))
        if result is None or result.returncode not in (0, 1):
            say("failed", failure("df", result))
            return
        full, tmpfs = [], set()
        for line in result.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 7 or parts[1] in SKIP_FS or parts[6].startswith("/snap/") or \
                    (parts[1] == "tmpfs" and not TMPFS_WATCHED.match(parts[6])):
                continue
            used = parts[5].rstrip("%")
            if parts[1] == "tmpfs":
                tmpfs.add(parts[6])
            if not inodes and parts[4].isdigit():
                machine.free_kib[parts[6]] = int(parts[4])
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
            memory = " in memory (tmpfs)" if mount in tmpfs else ""
            say("warning" if used >= 90 else "info", f"{mount}: {used}% of {what}{memory} used ({free_text})",
                next_step=f"du -xh -d 2 {mount} | sort -h | tail")
        if not full and not inodes:
            say("ok", "all filesystems have at least 20% space free")
    mounts = machine.read("proc/self/mounts") or ""
    for line in mounts.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] in ("/", "/home", "/var", "/boot", "/boot/efi") and \
                "ro" in parts[3].split(","):
            say("warning", f"{parts[1]} is mounted read-only; hypothesis: the kernel remounted it after errors; see: "
                           f"journalctl -b -k --grep {parts[1]}")
    quotas(machine)
    smart(machine)


QUOTA_FIELD = re.compile(r"^\d+\*?$")


def quotas(machine):
    """Disk quotas of the invoking account: a user over quota cannot write even on a filesystem with room."""
    # -p prints grace times as numbers (0 when not in grace), so every row has the same eight numeric fields
    # after the filesystem, which may be a local device or an NFS export such as server:/home.
    command = ["quota", "-w", "-v", "-p"] + (["-u", machine.user] if machine.privileged and machine.user else [])
    result = run(command)
    if result is None:
        return
    # quota exits 1 when a limit is exceeded, which the table below shows.
    if not broken("disk quotas", "quota", result, ok=(0, 1)):
        return
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 9 or not all(QUOTA_FIELD.match(part) for part in parts[1:]):
            continue
        for what, offset in (("space", 1), ("files", 5)):
            used, soft, hard = parts[offset:offset + 3]
            over = used.endswith("*")
            used, limit = int(used.rstrip("*")), int(hard) or int(soft)
            percent = used * 100 // limit if limit else 0
            if over or percent >= 90:
                say("warning", f"quota for {machine.user or 'this account'} on {parts[0]}: {what} "
                    + ("over its soft limit" if over else f"at {percent}% of its limit")
                    + "; writes there will fail at the hard limit", next_step=f"quota -s -u {machine.user}")


def smart(machine):
    if not machine.privileged:
        say("unchecked", "SMART health needs root; run: dotconfig machine status --sudo")
        return
    scan = run(["smartctl", "--scan"])
    if scan is None:
        say("unchecked", "SMART health: smartctl is not installed (sudo apt install smartmontools)")
        return
    if not broken("SMART device scan", "smartctl --scan", scan):
        return
    for line in scan.stdout.splitlines():
        # Keep the scan's device type (-d nvme, -d sat, ...): some devices answer only with it.
        words = line.split("#")[0].split()
        device = words[0] if words else ""
        if not device.startswith("/dev/"):
            continue
        result = run(["smartctl", "-H", "-A", "-j"] + words[1:] + [device])
        try:
            report = json.loads(result.stdout)
            passed = report.get("smart_status", {}).get("passed")
        except (ValueError, AttributeError):
            report, passed = {}, None
        details = smart_details(report)
        for level, text in details:
            say(level, f"{device}: {text}", next_step=f"sudo smartctl -a {device}")
        if passed is True and not any(level == "warning" for level, _ in details):
            say("ok", f"{device}: SMART health passed")
        elif passed is True:
            say("info", f"{device}: overall SMART health still reads passed; the indicators above matter more")
        elif passed is False:
            say("warning", f"{device}: SMART health FAILED; back up now and see: sudo smartctl -a {device}")
        elif result is not None and result.returncode & 3:
            # Bits 0 and 1: the command line was rejected or the device could not be opened.
            say("failed", f"{device}: SMART health: {failure('smartctl', result)}")
        else:
            say("unchecked", f"{device}: does not report SMART health ({failure('smartctl', result)})")


NVME_WARNINGS = {0: "spare capacity below threshold", 1: "temperature out of range",
                 2: "reliability degraded by media or internal errors", 3: "media switched to read-only",
                 4: "volatile memory backup failed", 5: "persistent memory region read-only"}
ATA_ATTRIBUTES = {5: ("warning", "reallocated sectors"), 187: ("warning", "uncorrectable errors reported"),
                  196: ("warning", "reallocation events"), 197: ("warning", "sectors pending reallocation"),
                  198: ("warning", "offline uncorrectable sectors"),
                  199: ("info", "interface CRC errors (often a cable or connector)")}


def smart_details(report):
    """Indicators that fail long before the overall SMART verdict does, as (level, text)."""
    details = []
    nvme = report.get("nvme_smart_health_information_log") or {}
    if nvme:
        critical = int(nvme.get("critical_warning") or 0)
        for bit, text in NVME_WARNINGS.items():
            if critical >> bit & 1:
                details.append(("warning", f"NVMe critical warning: {text}"))
        used = nvme.get("percentage_used")
        if isinstance(used, int) and used >= 80:
            details.append(("warning" if used >= 100 else "info", f"{used}% of its rated endurance used"))
        spare, threshold = nvme.get("available_spare"), nvme.get("available_spare_threshold")
        if isinstance(spare, int) and isinstance(threshold, int) and spare <= threshold + 10:
            details.append(("warning", f"available spare {spare}% (threshold {threshold}%)"))
        if nvme.get("media_errors"):
            details.append(("warning", f"{nvme['media_errors']} media and data integrity errors"))
        if nvme.get("num_err_log_entries"):
            details.append(("info", f"{nvme['num_err_log_entries']} error log entries (often harmless driver probes)"))
    for attribute in (report.get("ata_smart_attributes") or {}).get("table", []):
        known = ATA_ATTRIBUTES.get(attribute.get("id"))
        raw = (attribute.get("raw") or {}).get("value")
        if known and isinstance(raw, int) and raw > 0:
            details.append((known[0], f"{raw} {known[1]}"))
    return details


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
        say("warning" if available < 10 else "ok", text, next_step="ps -eo pid,rss,comm --sort=-rss | head")
    if info.get("SwapTotal"):
        used = (info["SwapTotal"] - info.get("SwapFree", 0)) * 100 // info["SwapTotal"]
        if used >= 50:
            say("warning" if used >= 90 else "info", f"{used}% of swap used")
    elif "SwapTotal" in info:
        say("info", "no swap configured")
    pressure = machine.read("proc/pressure/memory") or ""
    matched = re.search(r"^full avg10=[\d.]+ avg60=[\d.]+ avg300=([\d.]+)", pressure, re.M)
    if matched and float(matched.group(1)) >= 5:
        say("warning", f"processes stalled on memory {matched.group(1)}% of the last 5 minutes",
            next_step="journalctl -b -u systemd-oomd")
    oomd = [e for e in machine.journal("SYSLOG_IDENTIFIER=systemd-oomd") or []
            if re.search(r"Killed|killed", e["MESSAGE"])]
    if oomd:
        incident(f"systemd-oomd killed {plural(len(oomd), 'unit')} for memory pressure this boot",
                 next_step="journalctl -b -u systemd-oomd")
        print(f"    e.g. {clean(oomd[-1]['MESSAGE'], 160)}")


def check_load(machine):
    """Stalls and exhausted limits that leave memory looking fine: CPU and I/O pressure, cgroup memory and task
    limits, and the kernel file and process tables. Busy alone is not a fault; waiting is."""
    section("Load and limits")
    for resource, line, warn, note in (("cpu", "some", 40, 20), ("io", "full", 10, 5)):
        matched = re.search(rf"^{line} avg10=[\d.]+ avg60=[\d.]+ avg300=([\d.]+)",
                            machine.read(f"proc/pressure/{resource}") or "", re.M)
        if matched and float(matched.group(1)) >= note:
            stalled = "runnable tasks waited for a CPU" if resource == "cpu" else "all non-idle tasks waited for I/O"
            say("warning" if float(matched.group(1)) >= warn else "info",
                f"{stalled} {matched.group(1)}% of the last 5 minutes",
                    next_step="top -o %CPU" if resource == "cpu" else "sudo iotop -o")
    memory = cgroup_events(machine, "memory")
    for unit, counts in memory:
        killed = int(counts.get("oom_kill", "0"))
        # "max" and "oom" count this cgroup's own limit; oom_kill alone also counts victims of the global OOM
        # killer or of an enclosing slice's limit.
        own = int(counts.get("oom", "0")) or int(counts.get("max", "0"))
        if killed and own:
            incident(f"{unit}: the kernel killed {plural(killed, 'process')} at its own memory limit "
                           "(MemoryMax)", next_step="journalctl -b -k --grep oom-kill")
        elif killed:
            incident(f"{unit}: the OOM killer ended {plural(killed, 'process')} here; it did not reach its "
                           "own limit, so system memory or an enclosing slice ran out",
                               next_step="journalctl -b -k --grep oom-kill")
        elif counts.get("max", "0") != "0":
            say("info", f"{unit} reached its memory limit {plural(int(counts['max']), 'time')}")
    for unit, counts in cgroup_events(machine, "pids"):
        if counts.get("max", "0") != "0":
            incident(f"{unit}: {plural(int(counts['max']), 'process start')} refused at its task limit "
                           "(TasksMax) or an enclosing one", next_step=f"systemctl status {Path(unit).name}")
    if not memory and not glob.glob(str(machine.path("sys/fs/cgroup/**/memory.events")), recursive=True) and \
            machine.path("sys/fs/cgroup").is_dir():
        say("info", "no cgroup memory accounting found")
    files = (machine.read("proc/sys/fs/file-nr") or "").split()
    if len(files) == 3 and files[0].isdigit() and files[2].isdigit() and int(files[2]):
        used = int(files[0]) * 100 // int(files[2])
        if used >= 80:
            say("warning", f"{used}% of the kernel file handle table (fs.file-max) in use",
                next_step="cat /proc/sys/fs/file-nr; sudo lsof -n | wc -l")
    tasks = (machine.read("proc/loadavg") or "").split()
    limit = min(int(value) for value in ((machine.read("proc/sys/kernel/pid_max") or "").strip(),
                                         (machine.read("proc/sys/kernel/threads-max") or "").strip(), "4194304")
                if value.isdigit())
    if len(tasks) >= 4 and "/" in tasks[3] and tasks[3].split("/")[1].isdigit():
        used = int(tasks[3].split("/")[1]) * 100 // limit
        if used >= 80:
            say("warning", f"{used}% of the process and thread limit in use",
                next_step="ps -eo nlwp,pid,comm --sort=-nlwp | head")


def cgroup_events(machine, controller):
    """(cgroup name, counters) with events counted once. memory.events and pids.events add up a whole subtree,
    so the per-cgroup .local files are used where the kernel has them; without them, only leaf cgroups count."""
    events = sorted(glob.glob(str(machine.path(f"sys/fs/cgroup/**/{controller}.events")), recursive=True))
    found = []
    for path in events:
        directory = Path(path).parent
        local = directory / f"{controller}.events.local"
        if local.exists():
            counts = cgroup_counts(local)
        elif any(other != path and Path(other).parent.is_relative_to(directory) for other in events):
            continue
        else:
            counts = cgroup_counts(path)
        if any(value != "0" for value in counts.values()):
            found.append((cgroup_name(machine, path), counts))
    return found


def cgroup_counts(path):
    try:
        return dict(line.split() for line in Path(path).read_text().splitlines() if len(line.split()) == 2)
    except OSError:
        return {}


def cgroup_name(machine, path):
    """The unit or slice a cgroup file belongs to, like system.slice/backupd.service."""
    relative = Path(path).parent.relative_to(machine.path("sys/fs/cgroup"))
    return str(relative) or "the root cgroup"


# --- Account and session ---------------------------------------------------------------------------------------

def identity(machine):
    target = machine.target
    return inspector.Identity(target["name"], target["uid"], target["gids"], root=target["uid"] == 0, effective=True)


def home_path(machine):
    """The target's home as a path under the inspected root."""
    return machine.path(machine.target["home"].lstrip("/"))


def check_account(machine):
    section(f"Account and session ({machine.user or 'unknown'})")
    if not machine.target:
        say("warning", f"NSS does not resolve {machine.user or 'the invoking account'}: logins and file ownership for "
                       "it fail; for a domain account check sssd and the domain connection",
            next_step=f"getent passwd {machine.user or '$USER'}; sssctl domain-status")
        return
    target = machine.target
    say("info", f"uid {target['uid']}, home {target['home']}, shell {target['shell']}, "
                f"{plural(len(target['gids']), 'group')}")
    if not machine.reach:
        say("unchecked", f"{target['name']} is another account; its session, files and environment need --sudo")
        return
    home = home_path(machine)
    try:
        st = home.stat()
    except FileNotFoundError:
        say("warning", f"home {target['home']} does not exist; a first login creates it only with pam_mkhomedir",
            next_step="getent passwd " + target["name"])
        st = None
    except OSError as exc:
        say("failed", f"home {target['home']}: {exc.strerror or exc}")
        st = None
    if st is not None:
        if st.st_uid != target["uid"]:
            say("warning", f"home {target['home']} is owned by {owner_label(st.st_uid)}, not {target['name']}",
                next_step=f"ls -ld {target['home']}")
        blocked = inspector.access_check(machine.root, home, st, identity(machine), 3)
        if blocked:
            level, where, doubt = blocked
            where = "/" + str(where.relative_to(machine.root)) if where else target["home"]
            say("unchecked" if level == "unchecked" else "warning",
                f"{target['name']} cannot " + ("reach" if where != target["home"] else "write") + " their home: "
                + (doubt if doubt else f"{where} denies it"), next_step=f"namei -l {target['home']}")
    sessions(machine)
    xdg_overrides(machine, target)


XDG_DEFAULTS = (("XDG_CONFIG_HOME", ".config"), ("XDG_DATA_HOME", ".local/share"), ("XDG_STATE_HOME", ".local/state"),
                ("XDG_CACHE_HOME", ".cache"))


def xdg_overrides(machine, target):
    """dotconfig installs into the default XDG directories, so an override in the user manager hides its files."""
    flags = machine.user_flags()
    result = run(["systemctl"] + flags + ["show-environment"]) if flags else None
    if result is None or result.returncode != 0:
        return
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    for key, default in XDG_DEFAULTS:
        value = values.get(key)
        if not value or value.rstrip("/") == f"{target['home'].rstrip('/')}/{default}":
            continue
        if not value.startswith("/"):
            say("warning", f"{key}={value} is not absolute; the XDG specification says to ignore it, but some programs "
                           "resolve it against their working directory", next_step="systemctl --user show-environment")
        elif not (machine.root / value.lstrip("/")).is_dir():
            say("warning", f"{key}={value} does not exist; programs that honor it lose the files dotconfig put in "
                           f"~/{default}", next_step="systemctl --user show-environment")
        else:
            say("info", f"{key}={value} overrides ~/{default}; programs that honor it do not read what dotconfig "
                        "installs there")


def sessions(machine):
    uid = machine.uid
    user = run(["loginctl", "show-user", str(uid), "-p", "Sessions", "-p", "State", "-p", "Linger",
                "-p", "RuntimePath"])
    if user is None:
        say("unchecked", "sessions: loginctl is not installed")
        return
    if user.returncode != 0:
        say("info", f"{machine.user} has no session and no running user manager; per-session checks do not apply")
        return
    values = dict(line.split("=", 1) for line in user.stdout.splitlines() if "=" in line)
    ids = values.get("Sessions", "").split()
    for session in ids:
        result = run(["loginctl", "show-session", session, "-p", "Type", "-p", "Class", "-p", "State",
                      "-p", "Active", "-p", "Remote", "-p", "Service", "-p", "Seat"])
        if not broken(f"session {session}", "loginctl show-session", result):
            continue
        info = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        where = f" on {info['Seat']}" if info.get("Seat") else ""
        how = f" through {info['Service']}" if info.get("Service") else ""
        remote = ", remote" if info.get("Remote") == "yes" else ""
        say("info", f"session {session}: {info.get('Type', '?')} {info.get('Class', '?')} session{where}{how}, "
                    f"{info.get('State', '?')}{remote}")
    if not ids:
        say("info", f"{machine.user} has no session; the user manager runs because of "
                    + ("lingering" if values.get("Linger") == "yes" else "a recent logout"))
    runtime = machine.path((values.get("RuntimePath") or f"/run/user/{uid}").lstrip("/"))
    try:
        st = runtime.stat()
    except OSError:
        say("warning", f"runtime directory {runtime} is missing; sockets, the user bus and Wayland cannot start",
            next_step=f"loginctl user-status {machine.user}")
        return
    if st.st_uid != uid or stat.S_IMODE(st.st_mode) != 0o700:
        say("warning", f"runtime directory {runtime} has owner uid {st.st_uid} and mode "
                       f"{stat.S_IMODE(st.st_mode):o}; it must be the user's own with mode 700",
            next_step=f"ls -ld {runtime}; loginctl user-status {machine.user}")
    if not (runtime / "bus").exists():
        say("warning", "no user D-Bus socket; desktop apps and systemctl --user cannot reach the user manager",
            next_step=f"systemctl status user@{uid}.service")
    manager = run(["systemctl", "is-active", f"user@{uid}.service"])
    if manager is not None and manager.stdout.strip() not in ("active", "reloading"):
        say("warning", f"user@{uid}.service is {manager.stdout.strip() or 'not running'}; see: "
                       f"systemctl status user@{uid}.service")
    if len(ids) > 1:
        say("info", "one user manager and user bus serve all of these sessions; user-unit findings are per user, "
                    "not per session")


# --- Installation ----------------------------------------------------------------------------------------------

CHEZMOI_PREFIXES = ("private_", "readonly_", "empty_", "executable_", "symlink_", "exact_", "create_", "modify_",
                    "encrypted_", "literal_")


def managed_targets():
    """Home-relative paths of the files this repository manages, from chezmoi source names."""
    repo = Path(__file__).resolve().parents[1]
    source = repo / ((repo / ".chezmoiroot").read_text().strip() if (repo / ".chezmoiroot").exists() else "")
    targets = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if not path.is_file() or any(part.startswith(".chezmoi") for part in relative.parts):
            continue
        parts = []
        for part in relative.parts:
            changed = True
            while changed:
                changed = False
                for prefix in CHEZMOI_PREFIXES:
                    if part.startswith(prefix):
                        part, changed = part[len(prefix):], True
            if part.startswith("dot_"):
                part = "." + part[4:]
            parts.append(part[:-5] if part.endswith(".tmpl") else part)
        targets.append(Path(*parts))
    return targets


def check_installation(machine):
    if not machine.target:
        return
    section(f"Installation ({machine.user})")
    if not machine.reach:
        say("unchecked", f"{machine.user}'s files need --sudo")
        return
    home, uid, who = home_path(machine), machine.uid, identity(machine)
    if not home.is_dir():
        return
    missing, foreign = [], []
    for relative in managed_targets():
        path = home / relative
        if not os.path.lexists(path):
            missing.append(str(relative))
            continue
        if path.is_symlink() and not path.exists():
            say("warning", f"~/{relative} is a broken symlink", next_step=f"ls -l ~/{relative}")
            continue
        st = path.lstat()
        if st.st_uid != uid:
            foreign.append((str(relative), st.st_uid))
        parent = path.parent
        if parent != home and parent.stat().st_uid != uid:
            foreign.append((str(relative.parent) + "/", parent.stat().st_uid))
        blocked = inspector.access_check(machine.root, parent, parent.stat(), who, 3)
        if blocked and blocked[0] == "warning":
            say("warning", f"{machine.user} cannot replace ~/{relative}: its directory is not writable for them, so "
                           "dotconfig apply fails", next_step=f"namei -l ~/{relative}")
    for relative, owner in sorted(set(foreign)):
        say("warning", f"~/{relative} is owned by {owner_label(owner)}, not "
                       f"{machine.user}; updates as {machine.user} cannot replace it; run: sudo chown "
                       f"{machine.user} ~/{relative}")
    if missing:
        say("info", f"{plural(len(missing), 'managed file')} not applied yet: {', '.join(missing[:5])}"
            + (" ..." if len(missing) > 5 else "") + "; see: dotconfig status")
    elif not foreign:
        say("ok", f"all {len(managed_targets())} managed files exist and belong to {machine.user}")
    for directory in (".local/bin", ".config/dotconfig", ".config/zsh"):
        for path in sorted((home / directory).glob("*")) if (home / directory).is_dir() else []:
            if path.is_symlink() and not path.exists():
                say("warning", f"~/{directory}/{path.name} is a broken symlink",
                    next_step=f"ls -l ~/{directory}/{path.name}")
    private = [home / ".zshrc.local"] + sorted(home.glob(".zshrc.*.local")) + \
        sorted((home / ".config/dotconfig").glob("*.local"))
    for path in private:
        if path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o077:
            say("warning", f"~/{path.relative_to(home)} is readable or writable by other users; run: "
                           f"chmod 600 ~/{path.relative_to(home)}")
    repository(machine, home)
    completions(machine, home)


def chezmoi_configs(home):
    """chezmoi's own configuration files, not backups or editor copies beside them."""
    return [path for path in sorted((home / ".config/chezmoi").glob("chezmoi.*"))
            if path.suffix in (".toml", ".yaml", ".yml", ".json", ".jsonc")]


def checkout(machine, home):
    """The account's own dotconfig checkout and where that came from: the source directory its installed
    dotconfig command was rendered with, else chezmoi's sourceDir setting, else chezmoi's default. The same
    lookup runs on a fixture root and on the real machine."""
    candidates = []
    command = home / ".local/bin/dotconfig"
    try:
        matched = re.search(r"^SOURCE_DIR=(.+)$", command.read_text(errors="replace"), re.M)
        if matched:
            candidates.append((shlex.split(matched.group(1))[0], "~/.local/bin/dotconfig"))
    except (OSError, ValueError, IndexError):
        pass
    for config in chezmoi_configs(home):
        try:
            matched = re.search(r"""^\s*"?sourceDir"?\s*[=:]\s*["']?([^"'\n,]+)""", config.read_text(errors="replace"), re.M)
        except OSError:
            continue
        if matched:
            candidates.append((matched.group(1).strip(), f"~/.config/chezmoi/{config.name}"))
    candidates.append((machine.target["home"].rstrip("/") + "/.local/share/chezmoi", "the chezmoi default"))
    for value, source in candidates:
        if value.startswith("~/"):
            value = machine.target["home"].rstrip("/") + value[1:]
        if not value.startswith("/"):
            continue
        path = machine.path(value.lstrip("/"))
        # The source directory can sit below the repository root (.chezmoiroot).
        for repo in [path] + list(path.parents):
            if repo == machine.root or machine.root not in repo.parents:
                break
            if (repo / ".git").exists():
                return repo, source
    return None, None


def repository(machine, home):
    """Files in the dotconfig checkout that the account cannot rewrite, usually left by a sudo git command."""
    repo, source = checkout(machine, home)
    if repo is None:
        say("info", f"no dotconfig checkout found for {machine.user}")
        return
    say("info", f"dotconfig checkout: {inspector.shown(machine.root, repo)} (from {source})")
    if not (repo / ".git").is_dir():
        return
    foreign, examples = 0, []
    for count, path in enumerate((repo / ".git").rglob("*")):
        if count > 50000:
            break
        try:
            owner = path.lstat().st_uid
        except OSError:
            continue
        if owner != machine.uid:
            foreign += 1
            if len(examples) < 2:
                examples.append(str(path.relative_to(repo)))
    if foreign:
        say("warning", f"{plural(foreign, 'file')} in the dotconfig repository {'belongs' if foreign == 1 else 'belong'} to another account (often after "
                       f"sudo git); git pull as {machine.user} fails on them, e.g. {', '.join(examples)}",
            next_step=f"find {repo} ! -user {machine.user}")


def completions(machine, home):
    """compaudit judges ownership against the account that runs it, so it runs as the target, never as root."""
    omz = home / ".oh-my-zsh"
    if not omz.is_dir():
        return
    script = Path(__file__).with_name("check-zsh-completions.sh")
    command = ["bash", str(script), str(omz)]
    if machine.privileged and machine.uid != 0 and machine.root == Path("/"):
        command = ["runuser", "-u", machine.user, "--", "env", f"HOME={machine.target['home']}"] + command
    elif machine.privileged and machine.root == Path("/"):
        return
    result = run(command, timeout=60)
    if result is None:
        say("unchecked", "Zsh completion permissions: bash or runuser is not installed")
    elif result.returncode == 0:
        say("ok", "Zsh completion directories pass compaudit")
    elif "Zsh completion audit failed" in result.stderr:
        paths = [line for line in result.stderr.splitlines() if line.startswith("/")]
        say("warning", f"Zsh completion audit failed for {plural(len(paths), 'path')}"
            + (f", e.g. {paths[0]}" if paths else "") + "; Zsh then asks before loading completions",
            next_step="zsh -ic compaudit")
    else:
        say("failed", "Zsh completion audit: " + failure("check-zsh-completions.sh", result))


# --- Proxy and TLS ---------------------------------------------------------------------------------------------

PROXY_KEYS = ("http_proxy", "https_proxy", "no_proxy")
CA_KEYS = ("SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "GIT_SSL_CAINFO",
           "NODE_EXTRA_CA_CERTS")
DEFAULT_PROXY = "http://127.0.0.1:3128"


def userinfo(url):
    """The credentials part of a proxy URL, to compare and never to print; "" when there is none."""
    try:
        netloc = urlsplit(url).netloc
    except ValueError:
        return ""
    return netloc.rsplit("@", 1)[0] if "@" in netloc else ""


def redact(url):
    """A proxy URL without its credentials."""
    try:
        parts = urlsplit(url)
        if parts.username or parts.password:
            return parts._replace(netloc=parts.netloc.rsplit("@", 1)[1]).geturl()
    except ValueError:
        return "<unparsable URL>"
    return url


def proxy_contexts(machine):
    """(label, consequence, variables) for each environment a program of the target can inherit."""
    contexts = []
    if not machine.privileged and machine.user == machine.invoker:
        contexts.append(("this shell", "commands run from this shell", dict(os.environ)))
    flags = machine.user_flags() if machine.reach else None
    result = run(["systemctl"] + flags + ["show-environment"]) if flags else None
    if result is not None and result.returncode == 0:
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        contexts.append(("the user manager", "desktop apps and user services", values))
    elif flags:
        say("unchecked", "user manager environment: " + failure("systemctl show-environment", result))
    environment = machine.read("etc/environment")
    if environment is not None:
        values = {}
        for line in environment.splitlines():
            matched = re.match(r"^\s*(?:export\s+)?(\w+)=(.*)$", line)
            if matched:
                values[matched.group(1)] = matched.group(2).strip().strip("\"'")
        contexts.append(("/etc/environment", "new login sessions", values))
    return contexts


def check_proxy(machine, probes):
    section("Proxy and TLS")
    configured, endpoint, bypass = "unmanaged", DEFAULT_PROXY, ""
    if machine.target and machine.reach:
        state = home_path(machine) / ".config/dotconfig"
        mode = (state / "proxy.mode")
        try:
            configured = mode.read_text().strip() or "unmanaged"
        except OSError:
            pass
        try:
            local = (state / "proxy.local").read_text()
            matched = re.search(r"https_proxy=[\"']?([^\"'\s]+)", local)
            endpoint = matched.group(1) if matched else endpoint
            matched = re.search(r"no_proxy=[\"']?([^\"'\s]+)", local)
            bypass = matched.group(1) if matched else ""
        except OSError:
            pass
        say("info", f"dotconfig proxy is {configured}" + (f" ({redact(endpoint)})" if configured == "on" else ""))
    elif machine.target:
        say("unchecked", f"{machine.user}'s proxy setting needs --sudo")
    contexts = proxy_contexts(machine)
    for label, consequence, values in contexts:
        lower = {key: values.get(key) for key in PROXY_KEYS}
        upper = {key: values.get(key.upper()) for key in PROXY_KEYS}
        for key in ("http_proxy", "https_proxy"):
            if lower[key] and upper[key] and lower[key] != upper[key]:
                say("warning", f"{label}: {key}={redact(lower[key])} but {key.upper()}={redact(upper[key])}; tools "
                               "that read different cases go to different proxies", next_step="dotconfig proxy status")
        if lower["no_proxy"] and upper["no_proxy"] and lower["no_proxy"] != upper["no_proxy"]:
            say("info", f"{label}: no_proxy and NO_PROXY differ, so bypasses depend on the tool")
        https = lower["https_proxy"] or upper["https_proxy"]
        if configured == "on" and not https:
            say("warning", f"{label} has no https_proxy although dotconfig proxy is on: {consequence} connect "
                           "directly and fail where only the proxy is allowed", next_step="dotconfig proxy status")
        elif configured == "on" and https.rstrip("/") != endpoint.rstrip("/"):
            proxy_match(label, https, endpoint)
        elif configured == "off" and https:
            say("warning", f"{label} still sets https_proxy={redact(https)} although dotconfig proxy is off",
                next_step="dotconfig proxy status")
        for key in CA_KEYS:
            if values.get(key):
                ca_file(machine, label, key, values[key])
    if contexts:
        say("info", "environments inspected: " + ", ".join(label for label, _, _ in contexts))
    if configured == "on":
        listener(endpoint)
    routes = probe_routes(contexts, configured, endpoint, bypass) if probes else []
    for probe in probes:
        for labels, route in routes:
            probe_endpoint(machine, probe, labels, route)


def proxy_match(label, https, endpoint):
    """An environment's proxy against proxy.local's: the redacted URLs hide the credentials, so those are compared
    apart, and never printed."""
    ours, theirs = userinfo(endpoint), userinfo(https)
    if redact(https).rstrip("/") != redact(endpoint).rstrip("/"):
        say("warning", f"{label} uses proxy {redact(https)}, not the configured {redact(endpoint)}",
            next_step="dotconfig proxy status")
    elif ours and not theirs:
        say("info", f"{label} uses the configured proxy {redact(https)} without the credentials in proxy.local")
    elif theirs and theirs != ours:
        say("warning", f"{label} uses the configured proxy {redact(https)} with "
            + ("other credentials than proxy.local" if ours else "credentials that proxy.local does not set")
            + "; the proxy may refuse them", next_step="dotconfig proxy status")
    else:
        say("ok", f"{label} uses the configured proxy {redact(https)}")


def ca_file(machine, label, key, value):
    path = machine.path(value.lstrip("/"))
    if not path.exists():
        say("warning", f"{label}: {key}={value} does not exist; TLS fails for tools that use it",
            next_step=f"ls -l {value}")
    elif machine.target:
        blocked = inspector.access_check(machine.root, path, path.stat(), identity(machine), 4)
        if blocked and blocked[0] == "warning":
            say("warning", f"{label}: {key}={value} is not readable by {machine.user}", next_step=f"namei -l {value}")


def listener(endpoint):
    try:
        parts = urlsplit(endpoint)
        host, port = parts.hostname, parts.port or (443 if parts.scheme == "https" else 80)
    except ValueError:
        say("warning", "the configured proxy URL cannot be parsed", next_step="dotconfig proxy status")
        return
    if host not in ("127.0.0.1", "localhost", "::1"):
        say("info", f"proxy {host}:{port} is remote and not contacted without --probe")
        return
    try:
        with socket.create_connection((host, port), timeout=2):
            say("ok", f"a proxy listens on {host}:{port}")
    except OSError as exc:
        say("warning", f"nothing listens on {host}:{port} ({exc.strerror or exc}); with the proxy on, every proxied "
                       "connection fails until the local proxy (Px, cntlm-gss) runs",
                           next_step="dotconfig proxy status")


def resolve(host, port, timeout=5):
    """getaddrinfo with a deadline; (addrinfo entries, error). The entries are reused to connect, so DNS is asked
    once and only within this deadline."""
    found = {}

    def lookup():
        try:
            found["addresses"] = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except OSError as exc:
            found["error"] = exc
    worker = threading.Thread(target=lookup, daemon=True)
    worker.start()
    worker.join(timeout)
    if worker.is_alive():
        return None, f"no answer within {timeout} s"
    if "error" in found:
        return None, str(found["error"])
    return found["addresses"], None


def connect(addresses, timeout=5):
    """A TCP connection to the first resolved address that answers, all attempts sharing one deadline."""
    deadline = time.monotonic() + timeout
    error = OSError("no address")
    for index, (family, kind, proto, _, address) in enumerate(addresses):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock = socket.socket(family, kind, proto)
        # Later addresses keep a share of the deadline, so one silent address cannot use it all.
        sock.settimeout(max(remaining / (len(addresses) - index), 0.5))
        try:
            sock.connect(address)
            return sock, None
        except OSError as exc:
            sock.close()
            error = exc
    return None, error


def response_header(sock, timeout=5, limit=16384):
    """The proxy's complete response header to CONNECT; tunnel data starts only after its blank line."""
    deadline, data = time.monotonic() + timeout, b""
    while b"\r\n\r\n" not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise OSError(f"no complete response header within {timeout} s")
        if len(data) > limit:
            raise OSError(f"response header longer than {limit} bytes")
        sock.settimeout(remaining)
        chunk = sock.recv(4096)
        if not chunk:
            raise OSError("connection closed before the response header ended")
        data += chunk
    header, _, rest = data.partition(b"\r\n\r\n")
    return header.decode("latin-1", "replace"), rest


def bypassed(host, no_proxy):
    for entry in no_proxy.split(","):
        entry = entry.strip().lower()
        if entry == "*":
            return True
        entry = entry[2:] if entry.startswith("*.") else entry.lstrip(".")
        if entry and (host.lower() == entry or host.lower().endswith("." + entry)):
            return True
    return False


def probe_routes(contexts, configured, endpoint, bypass):
    """(labels, values) for each distinct proxy, bypass and trust setting the account's programs would use, so
    each probe takes the route of a real environment and says which."""
    routes = []
    for label, _, values in contexts:
        route = {key: values.get(key) or values.get(key.upper()) or "" for key in PROXY_KEYS}
        route.update({key: values.get(key, "") for key in CA_KEYS})
        for labels, known in routes:
            if known == route:
                labels.append(label)
                break
        else:
            routes.append(([label], route))
    if configured == "on" and not any(route["https_proxy"].rstrip("/") == endpoint.rstrip("/") for _, route in routes):
        route = dict.fromkeys(PROXY_KEYS + CA_KEYS, "")
        route.update(https_proxy=endpoint, no_proxy=bypass)
        routes.append((["the dotconfig proxy setting, which no inspected environment uses yet"], route))
    if not routes:
        routes.append((["a direct connection, as no environment was inspected"], dict.fromkeys(PROXY_KEYS + CA_KEYS, "")))
    return routes


def trust(machine, route, name):
    """A verifying TLS context from this route's own SSL_CERT_FILE and SSL_CERT_DIR (OpenSSL's variables), else
    OpenSSL's built-in locations, never this diagnostic process's environment. None when the account cannot
    read what it is told to trust."""
    defaults = ssl.get_default_verify_paths()
    cafile = machine.path(route["SSL_CERT_FILE"].lstrip("/")) if route["SSL_CERT_FILE"] else None
    capath = machine.path(route["SSL_CERT_DIR"].lstrip("/")) if route["SSL_CERT_DIR"] else None
    for key, path, want in (("SSL_CERT_FILE", cafile, 4), ("SSL_CERT_DIR", capath, 5)):
        if path is None:
            continue
        if not path.exists():
            say("warning", f"{name}: {key}={route[key]} does not exist, so TLS fails here",
                next_step="dotconfig proxy status")
            return None
        if machine.target:
            blocked = inspector.access_check(machine.root, path, path.stat(), identity(machine), want)
            if blocked and blocked[0] == "warning":
                say("warning", f"{name}: {key}={route[key]} is not readable by {machine.user}, so TLS fails here",
                    next_step=f"namei -l {route[key]}")
                return None
    if cafile is None and capath is None:
        cafile = defaults.openssl_cafile if os.path.isfile(defaults.openssl_cafile) else None
        capath = defaults.openssl_capath if os.path.isdir(defaults.openssl_capath) else None
    if cafile is None and capath is None:
        say("unchecked", f"{name}: no trusted certificate locations found to verify with")
        return None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    try:
        context.load_verify_locations(cafile=str(cafile) if cafile else None, capath=str(capath) if capath else None)
    except (ssl.SSLError, OSError) as exc:
        say("warning", f"{name}: the trusted certificates cannot be loaded ({clean(str(exc), 120)})",
            next_step=f"openssl x509 -noout -subject -in {cafile}" if cafile else f"ls -l {capath}")
        return None
    return context


def probe_endpoint(machine, probe, labels, route):
    """DNS, TCP, proxy CONNECT and a verified TLS handshake, each bounded, so a failure names its stage."""
    host, _, port = probe.rpartition(":") if probe.count(":") == 1 else (probe, "", "443")
    port = int(port) if port.isdigit() else 443
    name = f"probe {host}:{port} ({', '.join(labels)})"
    proxy = route["https_proxy"] if not bypassed(host, route["no_proxy"]) else ""
    try:
        via = urlsplit(proxy) if proxy else None
        connect_host, connect_port = (via.hostname, via.port or 80) if via else (host, port)
    except ValueError:
        say("warning", f"{name}: the proxy URL {redact(proxy)} cannot be parsed", next_step="dotconfig proxy status")
        return
    if via and via.scheme != "http":
        say("unchecked", f"{name}: probing through a {via.scheme} proxy is not supported")
        return
    others = [f"{key}={route[key]}" for key in CA_KEYS[2:] if route[key]]
    if others:
        say("info", f"{name}: verified with OpenSSL's SSL_CERT_FILE and SSL_CERT_DIR; tools that read "
                    f"{', '.join(others)} use those instead, which this probe does not exercise")
    context = trust(machine, route, name)
    if context is None:
        return
    addresses, error = resolve(connect_host, connect_port)
    if error:
        say("warning", f"{name}: DNS for {connect_host} failed ({error})", next_step=f"resolvectl query {connect_host}")
        return
    raw, error = connect(addresses)
    if raw is None:
        say("warning", f"{name}: TCP connection to {connect_host}:{connect_port} failed ({error.strerror or error})",
            next_step=f"nc -vz {connect_host} {connect_port}")
        return
    with raw:
        if via:
            try:
                raw.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
                header, early = response_header(raw)
            except OSError as exc:
                say("warning", f"{name}: the proxy did not answer CONNECT ({exc.strerror or exc})",
                    next_step=f"curl -v -x {redact(proxy)} https://{host}:{port}/")
                return
            status = header.split("\r\n", 1)[0]
            code = status.split()[1] if len(status.split()) > 1 else "?"
            if not code.startswith("2"):
                hint = {"407": "the proxy wants authentication: a Kerberos ticket (kinit) or its own credentials",
                        "403": "the proxy policy refuses this destination",
                        "502": "the proxy could not reach the destination"}.get(code, "the proxy refused the tunnel")
                say("warning", f"{name}: proxy answered {clean(status, 80)}; {hint}",
                    next_step="klist" if code == "407" else f"curl -v -x {redact(proxy)} https://{host}:{port}/")
                return
            if early:
                say("warning", f"{name}: the proxy sent data before the TLS handshake began; it does not tunnel",
                    next_step=f"curl -v -x {redact(proxy)} https://{host}:{port}/")
                return
        raw.settimeout(5)
        try:
            with context.wrap_socket(raw, server_hostname=host) as tls:
                say("ok", f"{name}: TLS verified ({tls.version()})" + (f" through proxy {via.hostname}" if via else ""))
        except ssl.SSLCertVerificationError as exc:
            say("warning", f"{name}: certificate not trusted ({exc.verify_message}); hypotheses: a TLS-inspecting "
                           "proxy whose CA this environment does not trust, or a server misconfiguration",
                next_step=f"openssl s_client -connect {host}:{port} -servername {host} -showcerts"
                          + (f" -proxy {via.hostname}:{connect_port}" if via else ""))
        except (ssl.SSLError, OSError) as exc:
            say("warning", f"{name}: TLS handshake failed ({clean(str(exc), 120)})",
                next_step=f"openssl s_client -connect {host}:{port} -servername {host}"
                          + (f" -proxy {via.hostname}:{connect_port}" if via else ""))


# --- Expected units and mounts ------------------------------------------------------------------------------------

DAY = 86400
# (alternatives, scope, applies to profile, required, maximum age of a timer's last run in seconds, why). Built-in
# expectations hold only where the unit is installed; required ones also flag a missing unit.
EXPECTED_UNITS = (
    (("systemd-timesyncd.service", "chrony.service"), "system", lambda p: True, False, None,
     "keeps the clock in sync; Kerberos refuses tickets on a skewed clock"),
    (("NetworkManager.service",), "system", lambda p: p["hostType"] in ("laptop", "desktop"), False, None,
     "manages Wi-Fi, wired and VPN connections"),
    (("display-manager.service",), "system", lambda p: p["hostType"] in ("laptop", "desktop"), False, None,
     "shows the login screen"),
    (("ssh.socket", "ssh.service"), "system", lambda p: p["hostType"] == "server", False, None,
     "accepts remote logins"),
    (("sssd.service",), "system", lambda p: p["sssd"], True, None, "serves domain accounts and logins"),
    # The local proxy, where installed: proxydetox (as a user or a system service), Px or cntlm.
    (("proxydetox.service", "px.service"), "user", lambda p: p["proxy"], False, None,
     "the local proxy dotconfig sends traffic through"),
    (("proxydetox.service", "cntlm.service"), "system", lambda p: p["proxy"], False, None,
     "the local proxy dotconfig sends traffic through"),
    # Package freshness itself is judged under Packages, from APT's own stamps.
    (("apt-daily.timer",), "system", lambda p: True, False, None, "refreshes package lists"),
    (("apt-daily-upgrade.timer",), "system", lambda p: True, False, None, "installs security updates"),
    (("fstrim.timer",), "system", lambda p: True, False, 8 * DAY, "trims SSDs weekly"),
    (("logrotate.timer",), "system", lambda p: True, False, 2 * DAY, "keeps logs from filling the disk"),
    (("systemd-tmpfiles-clean.timer",), "system", lambda p: True, False, 2 * DAY, "cleans temporary files"),
    (("e2scrub_all.timer",), "system", lambda p: True, False, 8 * DAY, "checks ext4 metadata on LVM weekly"),
)
DURATION = re.compile(r"^(\d+)([smhdw])$")
UNIT_FIELDS = ["Id", "LoadState", "UnitFileState", "ActiveState", "SubState", "Type", "Result", "ConditionResult",
               "TriggeredBy", "LastTriggerUSec"]


def profile(machine):
    """Machine role and host type from the account's chezmoi data, and the dotconfig features in use."""
    values = {"machineRole": "unknown", "hostType": "unknown", "source": None}
    home = home_path(machine) if machine.target and machine.reach else None
    for config in chezmoi_configs(home) if home else []:
        try:
            text = config.read_text(errors="replace")
        except OSError:
            continue
        for key in ("machineRole", "hostType"):
            matched = re.search(rf"""^\s*"?{key}"?\s*[=:]\s*["']?(\w+)""", text, re.M)
            if matched:
                values[key], values["source"] = matched.group(1), f"~/.config/chezmoi/{config.name}"
    values["sssd"] = machine.path("etc/sssd/sssd.conf").exists()
    try:
        values["proxy"] = bool(home) and (home / ".config/dotconfig/proxy.mode").read_text().strip() == "on"
    except OSError:
        values["proxy"] = False
    return values


def expectation_overrides(machine):
    """require [--user] UNIT [max-age=7d] | ignore UNIT | mount PATH | ignore-mount PATH | offline-ok DOMAIN, one per
    line, from
    /etc/dotconfig/machine-expect and then the account's ~/.config/dotconfig/machine-expect."""
    files = [("/etc/dotconfig/machine-expect", machine.path("etc/dotconfig/machine-expect"))]
    if machine.target and machine.reach:
        files.append(("~/.config/dotconfig/machine-expect", home_path(machine) / ".config/dotconfig/machine-expect"))
    rules = {"require": [], "ignore": set(), "mount": [], "ignore-mount": set(), "offline-ok": set()}
    for label, path in files:
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for number, line in enumerate(lines, 1):
            words = line.split("#", 1)[0].split()
            if not words:
                continue
            verb, rest = words[0], words[1:]
            scope = "user" if "--user" in rest else "system"
            rest = [word for word in rest if word != "--user"]
            age = next((word.split("=", 1)[1] for word in rest if word.startswith("max-age=")), None)
            names = [word for word in rest if not word.startswith("max-age=")]
            matched = DURATION.match(age) if age else None
            if verb not in rules or len(names) != 1 or (age and not matched):
                say("warning", f"{label}:{number}: cannot read '{clean(line, 80)}'; expected require [--user] UNIT "
                               "[max-age=7d], ignore UNIT, mount PATH, ignore-mount PATH or offline-ok DOMAIN",
                                   next_step=f"cat {label}")
                continue
            if verb == "require":
                seconds_ = int(matched.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": DAY, "w": 7 * DAY}[matched.group(2)] \
                    if matched else None
                rules["require"].append(((names[0],), scope, seconds_, label))
            elif verb in ("ignore", "ignore-mount", "offline-ok"):
                rules[verb].add(names[0].rstrip("/") or "/")
            else:
                rules["mount"].append((names[0].rstrip("/") or "/", label))
    return rules


def show_units(flags, names, fields, what):
    """systemctl show blocks matched to names by position: an alias such as display-manager.service reports
    the unit it points to as its Id. None when the query fails."""
    result = run(["systemctl"] + flags + ["show", "--no-pager", "--timestamp=unix"]
                 + ["-p" + name for name in fields] + list(names))
    if not broken(what, "systemctl show", result):
        return None
    blocks = [dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
              for block in result.stdout.strip().split("\n\n")]
    if len(blocks) != len(names):
        say("failed", f"{what}: systemctl show answered {len(blocks)} of {len(names)} units")
        return None
    return dict(zip(names, blocks))


def check_expected(machine):
    section("Expected services, timers and mounts")
    values = profile(machine)
    rules = machine.expectations()
    say("info", f"profile: {values['machineRole']} {values['hostType']}"
        + (f" (from {values['source']})" if values["source"] else " (no chezmoi data found)")
        + "; features: " + (", ".join(name for name, on in (("SSSD", values["sssd"]), ("dotconfig proxy", values["proxy"]))
                                     if on) or "none"))
    wanted = [(names, scope, required, age, why) for names, scope, applies, required, age, why in EXPECTED_UNITS
              if applies(values) and not any(name in rules["ignore"] for name in names)]
    wanted += [(names, scope, True, age, f"required by {label}") for names, scope, age, label in rules["require"]
               if names[0] not in rules["ignore"]]
    now = time.time()
    uptime = float((machine.read("proc/uptime") or "0").split()[0] or 0)
    problems = 0
    for scope in ("system", "user"):
        group = [entry for entry in wanted if entry[1] == scope]
        if not group:
            continue
        flags = [] if scope == "system" else machine.user_flags()
        if flags is None or (scope == "user" and not machine.reach):
            say("unchecked", f"expected user units of {machine.user}: their user manager is out of reach "
                             "(another account needs --sudo)")
            continue
        names = [name for entry in group for name in entry[0]]
        found = show_units(flags, names, UNIT_FIELDS, f"expected {scope} units")
        if found is None:
            continue
        # The sockets, paths and timers that start units on demand, to see whether they are live.
        sources = sorted({source for props in found.values() for source in props.get("TriggeredBy", "").split()})
        triggers = (show_units(flags, sources, ["Id", "LoadState", "UnitFileState", "ActiveState", "SubState"],
                               f"expected {scope} units")
                    if sources else {}) or {}
        for alternatives, _, required, age, why in group:
            installed = [found[name] for name in alternatives
                         if found[name].get("LoadState") not in (None, "", "not-found")]
            if not installed:
                if required:
                    say("warning", f"{' or '.join(alternatives)} is required ({why}) but not installed",
                        next_step=f"apt-file search {alternatives[0]}")
                    problems += 1
                continue
            # Alternatives provide one capability: it is missing only when none of them provides it.
            findings = [unit_expectation(props, why, age, now, uptime, scope, triggers) for props in installed]
            if all(findings):
                for finding in findings:
                    say("warning", finding)
                problems += 1
    problems += expected_mounts(machine, rules)
    if not problems:
        say("ok", "expected services, timers and mounts are in place")


def live_sources(props, triggers):
    """The units that would start this one on demand and are running now: a listening socket, a watching path,
    a waiting timer. (live, dead) lists of names with their state."""
    live, dead = [], []
    for name in props.get("TriggeredBy", "").split():
        source = triggers.get(name, {})
        state = "masked" if "masked" in (source.get("LoadState"), source.get("UnitFileState")) \
            else source.get("ActiveState") or "unknown"
        (live if state == "active" else dead).append(f"{name} ({source.get('SubState') or state})"
                                                     if state == "active" else f"{name} ({state})")
    return live, dead


def unit_expectation(props, why, age, now, uptime, scope, triggers):
    """The finding for one expected unit, or None when it provides what is expected. A oneshot that finished, or a
    unit whose socket, path or timer is live, is not inactive."""
    unit, state, sub = props.get("Id", "?"), props.get("ActiveState", ""), props.get("SubState", "")
    user = " --user" if scope == "user" else ""
    hint = f"systemctl{user} status {unit}"
    live, dead = live_sources(props, triggers)
    if props.get("LoadState") == "masked" or props.get("UnitFileState") == "masked":
        return f"{unit} is masked, so it never starts ({why}); see: {hint}"
    if state == "failed":
        return None  # Reported with its reason under Services.
    if state in ("active", "reloading", "activating") and not unit.endswith(".timer"):
        return None
    if props.get("UnitFileState") == "disabled" and not live:
        return (f"{unit} is disabled, so it does not start at boot" + (f", and what would start it is not running: "
                f"{', '.join(dead)}" if dead else "") + f" ({why}); run: systemctl{user} enable --now {unit}")
    if props.get("ConditionResult") == "no":
        return f"{unit} was skipped: a start condition was not met ({why}); see: {hint}"
    if unit.endswith(".timer"):
        if state != "active":
            return f"{unit} is {state or 'not running'}, so what it schedules never runs ({why}); see: {hint}"
        last = props.get("LastTriggerUSec", "").lstrip("@")
        # A persistent timer catches up soon after boot, so a long power-off is not a missed run.
        if age and uptime > min(age, DAY):
            if not last.isdigit() or int(last) == 0:
                return (f"{unit} has never run although the machine has been up {seconds(uptime * 1e6)} ({why}); "
                        f"see: {hint}")
            since = now - int(last)  # --timestamp=unix: seconds, as @N
            if since > age:
                return (f"{unit} last ran {since / DAY:.0f} days ago, expected at least every {age / DAY:.0f} "
                        f"({why}); see: {hint}")
        return None
    if props.get("Type") == "oneshot" and props.get("Result") == "success":
        return None
    if live:
        return None  # Started on demand by a live socket, path or timer.
    if dead:
        return (f"{unit} is {state or 'not running'} and what would start it on demand is not running: "
                f"{', '.join(dead)} ({why}); see: {hint}")
    return f"{unit} is {state or 'not running'}{f' ({sub})' if sub else ''} although it is expected to run ({why}); see: {hint}"


def fstab_entries(machine):
    entries = []
    for line in (machine.read("etc/fstab") or "").splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) < 4 or fields[2] == "swap" or not fields[1].startswith("/"):
            continue
        options = fields[3].split(",")
        if "noauto" in options and "x-systemd.automount" not in options:
            continue
        entries.append((fields[1].replace("\\040", " ").rstrip("/") or "/", fields[0], fields[2], options))
    return entries


def expected_mounts(machine, rules):
    """A mount that is expected but absent hides nothing: its directory stays writable on the parent filesystem,
    so programs fill the wrong disk instead of failing."""
    mounted = {fields[1].replace("\\040", " ") for fields in
               (line.split() for line in (machine.read("proc/self/mounts") or "").splitlines()) if len(fields) > 2}
    wanted = [(point, f"/etc/fstab: {spec}, {kind}" + (", nofail" if "nofail" in options else ""))
              for point, spec, kind, options in fstab_entries(machine)]
    wanted += [(point, label) for point, label in rules["mount"]]
    if machine.target:
        home = machine.target["home"].rstrip("/")
        auto = machine.read("etc/auto.master") or ""
        for line in auto.splitlines():
            fields = line.split("#", 1)[0].split()
            if fields and fields[0].startswith("/") and (home == fields[0] or home.startswith(fields[0].rstrip("/") + "/")):
                wanted.append((fields[0].rstrip("/"), f"/etc/auto.master, holds the home of {machine.user}"))
    problems, seen = 0, set()
    for point, origin in wanted:
        if point in seen or point in rules["ignore-mount"] or point in mounted:
            continue
        seen.add(point)
        directory = machine.path(point.lstrip("/"))
        consequence = "nothing is mounted there"
        if directory.is_dir():
            try:
                writable = directory.stat().st_mode & 0o222
            except OSError:
                writable = 0
            if writable:
                consequence = "its directory is writable, so files written there land on the parent filesystem"
        say("warning", f"{point} is expected to be mounted ({origin}) but is not; {consequence}; "
                       f"see: findmnt {point}, journalctl -u {systemd_escape_path(point)}.mount")
        problems += 1
    return problems


def systemd_escape_path(path):
    if path == "/":
        return "-"
    return "".join(c if c.isalnum() or c in "_." else "-" if c == "/" else f"\\x{ord(c):02x}"
                   for c in path.strip("/"))


# --- Network, time, and domain login ---------------------------------------------------------------------------

def check_network(machine):
    section("Network and time")
    result = run(["nmcli", "-t", "-f", "STATE,CONNECTIVITY", "general"])
    if result is None:
        say("unchecked", "NetworkManager state: nmcli is not installed")
    elif result.returncode == 8:
        say("warning", "NetworkManager is not running; Wi-Fi, VPN and connectivity are unmanaged",
            next_step="systemctl status NetworkManager.service")
    elif broken("NetworkManager state", "nmcli", result):
        state, _, connectivity = result.stdout.strip().partition(":")
        if state.startswith("connected") and connectivity in ("full", "unknown", ""):
            say("ok", f"NetworkManager {state}" + (f", connectivity {connectivity}" if connectivity else ""))
        else:
            say("warning", f"NetworkManager {state or 'unknown'}, connectivity {connectivity or 'unknown'}"
                + ("; a captive portal may need a login" if connectivity == "portal" else ""),
                    next_step="nmcli general status; nmcli device")
        active = run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active"])
        if broken("active connections", "nmcli", active):
            vpns = [line.split(":")[0] for line in active.stdout.splitlines()
                    if re.search(r":(vpn|wireguard|tun)(:|$)", line)]
            say("info", "VPN active: " + ", ".join(vpns) if vpns else "no VPN connection active")
            machine.vpns = vpns
    route = run(["ip", "-o", "route", "show", "default"])
    if broken("default route", "ip route", route) and not route.stdout.strip():
        say("warning", "no default route; nothing outside the local network is reachable",
            next_step="ip route; nmcli device")
    dns = run(["resolvectl", "dns"])
    if broken("DNS servers", "resolvectl", dns):
        servers = sorted({server for line in dns.stdout.splitlines() for server in line.partition(":")[2].split()})
        say("info" if servers else "warning", "DNS servers: " + ", ".join(servers) if servers else
            "no DNS servers configured")
    time = run(["timedatectl", "show", "-p", "NTPSynchronized", "-p", "NTP"])
    if broken("clock synchronization", "timedatectl", time):
        values = dict(line.split("=", 1) for line in time.stdout.splitlines() if "=" in line)
        if values.get("NTPSynchronized") == "yes":
            say("ok", "clock synchronized with NTP")
        else:
            say("warning", "clock not synchronized with NTP" + (" (NTP is off)" if values.get("NTP") == "no" else "")
                + "; Kerberos refuses tickets when the clock is off by more than 5 minutes",
                    next_step="timedatectl timesync-status")
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
    # The status helper reads configuration as it is now; the log helper reports what happened, so its problems are
    # earlier incidents.
    levels = {"warning": "warning", "possible cause": "warning", "check failed": "failed", "not checked": "unchecked"}
    for title, command, past, next_step in (
            ("dotconfig creds status", [scripts / "credentials-inspect.py", "inspect"], False,
             "sudo sssctl config-check"),
            (f"dotconfig creds check-logs --days {days}", [scripts / "credentials-logs.py", "--days", str(days)], True,
             f"sudo dotconfig creds check-logs --days {days} --examples 5")):
        print(f"  {title}:")
        result = run(["python3"] + [str(part) for part in command] + [str(machine.root)], timeout=CREDS_TIMEOUT)
        for line in (result.stdout + result.stderr).splitlines():
            label, _, text = line.partition(": ")
            level = levels.get(label)
            if level and text:
                say(level, ("hypothesis: " if label == "possible cause" else "") + text, past=past,
                    next_step=next_step, where=f"{SECTION[0]} ({title})", indent="    ")
            else:
                print(f"    {line}" if line.strip() else "")
        if result.returncode == 124:
            say("failed", f"{title} did not finish within {CREDS_TIMEOUT:g} s; domain login health is not assessed")
        elif result.returncode != 0:
            say("failed", f"{title} exited {result.returncode}; its findings above are incomplete")


# --- Domain login for the inspected account ------------------------------------------------------------------------

PAM_CODES = {"4": "a system error inside SSSD", "6": "the access rules (access_provider, GPO) refuse this account",
             "7": "a wrong password or a rejected credential", "9": "SSSD could not reach the domain and has no "
             "cached password to fall back on", "10": "the domain does not know this account",
             "13": "the account or its password expired", "17": "Kerberos credentials could not be set up"}


def pam_events(machine, name):
    """The account's PAM events this boot, oldest first, as (entry, service, stage, outcome, detail)."""
    quoted = re.escape(name)
    patterns = (
        ("auth", "ok", re.compile(rf"pam_\w+\(([^:]+):auth\): authentication success;.*\buser={quoted}(?:\s|$)")),
        ("auth", "failed", re.compile(rf"pam_\w+\(([^:]+):auth\): authentication failure;.*\buser={quoted}(?:\s|$)")),
        ("auth", "failed", re.compile(rf"pam_sss\(([^:]+):auth\): received for user {quoted}: (?!0 )(\d+) \((.*)\)")),
        ("account", "denied", re.compile(rf"pam_\w+\(([^:]+):account\): (?:Access denied for user {quoted}: "
                                         rf"(\d+) \((.*)\)|.*\b{quoted}\b.*(expired|denied).*)")),
        ("session", "ok", re.compile(rf"pam_unix\(([^:]+):session\): session opened for user {quoted}[(\s]")),
        ("session", "failed", re.compile(r"pam_(?:systemd|mkhomedir)\(([^:]+):session\): (.*(?:[Ff]ail|[Uu]nable).*)")),
    )
    events = []
    for entry in machine.journal("SYSLOG_FACILITY=10", "SYSLOG_FACILITY=4") or []:
        for stage, outcome, pattern in patterns:
            matched = pattern.search(entry["MESSAGE"])
            if matched:
                groups = [group for group in matched.groups()[1:] if group]
                events.append((entry, matched.group(1), stage, outcome, groups))
                break
    return events


def when(entry):
    realtime = entry.get("__REALTIME_TIMESTAMP")
    if realtime and realtime.isdigit():
        return time.strftime("%H:%M:%S", time.localtime(int(realtime) / 1e6))
    return f"{seconds(monotonic(entry))} after the kernel started"


def login_stages(machine, name):
    """The latest login attempt per PAM service, split into authentication, authorization (account) and session
    setup, so a refused account is not mistaken for a wrong password and a failed session for either."""
    if not machine.sees_system_journal():
        say("unchecked", "login stages: " + machine.journal_hint())
        return
    attempts, unattributed = {}, []
    for entry, service, stage, outcome, detail in pam_events(machine, name):
        history = attempts.setdefault(service, [])
        pid = entry.get("_PID")
        # One PAM transaction runs in one process: events of another process belong to another attempt.
        mine = [attempt for attempt in history if attempt["pid"] == pid] if pid else history
        last = mine[-1] if mine else None
        if stage == "session" and outcome == "failed":
            # These lines do not name the account: they count only from the process of its own attempt.
            if pid and last and last.get("auth") != "failed" and last.get("account") != "denied":
                last.update(session="failed", session_detail=detail, closed=True)
            elif not pid and history and monotonic(entry) - monotonic(history[-1]["entry"]) < 30e6:
                unattributed.append((service, entry))
            continue
        # Several modules log one failed password (pam_unix, then pam_sss with its code): one attempt.
        same_failure = (last and stage == "auth" and outcome == "failed" and last.get("auth") == "failed"
                        and monotonic(entry) - monotonic(last["entry"]) < 2e6)
        if not same_failure and (stage == "auth" or last is None or last["closed"]):
            last = {"entry": entry, "closed": False, "pid": pid}
            history.append(last)
        last[stage] = outcome
        last[stage + "_detail"] = last.get(stage + "_detail") or detail
        last["closed"] = stage == "session" or outcome in ("failed", "denied")
    attempts = {service: history for service, history in attempts.items() if history}
    if not attempts:
        say("info", f"no login of {name} recorded in this boot")
        return
    for service, history in attempts.items():
        attempt = history[-1]
        failed = [earlier for earlier in history[:-1] if earlier.get("auth") == "failed"
                  or earlier.get("account") == "denied"]
        attempt["earlier"] = len(failed)
        codes = [(earlier.get("auth_detail") or earlier.get("account_detail") or [""])[0] for earlier in failed]
        attempt["earlier_code"] = codes[-1] if codes else ""
    for service, attempt in sorted(((service, history[-1]) for service, history in attempts.items()),
                                   key=lambda item: monotonic(item[1]["entry"])):
        text = f"last login of {name} through {service} at {when(attempt['entry'])}: "
        auth, account, session = attempt.get("auth"), attempt.get("account"), attempt.get("session")
        code = (attempt.get("auth_detail") or attempt.get("account_detail") or [""])[0]
        if auth == "failed":
            incident(text + "authentication failed" + (f" ({code}: {PAM_CODES[code]})" if code in PAM_CODES
                                                              else ""),
                     next_step=f"journalctl -b SYSLOG_FACILITY=10 --grep {name}")
        elif account == "denied":
            incident(text + "authentication " + ("succeeded" if auth else "not logged")
                + ", then authorization refused it" + (f" ({code}: {PAM_CODES[code]})" if code in PAM_CODES else "")
                + "; see: sudo sssctl user-checks " + name, next_step=f"journalctl -b SYSLOG_FACILITY=10 --grep {name}")
        elif session == "failed":
            incident(text + "authenticated and authorized, but session setup failed: "
                + clean((attempt.get("session_detail") or [""])[0], 120), next_step="journalctl -b -u systemd-logind")
        elif session == "ok":
            say("ok", text + ("authentication, authorization and session setup succeeded" if auth
                              else "session opened (authenticated without a password, e.g. an SSH key)"))
        else:
            say("info", text + "authentication succeeded, no session opened after it (still logging in, cancelled, "
                               "or a screen unlock)")
        doubt = [entry for other, entry in unattributed if other == service
                 and 0 <= monotonic(entry) - monotonic(attempt["entry"]) < 30e6]
        if doubt:
            say("info", f"a session failure through {service} at {when(doubt[-1])} names no account and process, so "
                        f"it may or may not belong to this login: {clean(doubt[-1]['MESSAGE'], 120)}")
        if attempt.get("earlier"):
            code = attempt["earlier_code"]
            say("info", f"{plural(attempt['earlier'], 'failed attempt')} through {service} before that"
                + (f", the last one {code}: {PAM_CODES[code]}" if code in PAM_CODES else ""))


def domain_names(machine):
    if machine.privileged:
        result = run(["sssctl", "domain-list"], timeout=20)
        if result is not None and result.returncode == 0:
            return [line.strip() for line in result.stdout.splitlines() if line.strip()]
    text = machine.read("etc/sssd/sssd.conf") or ""
    return re.findall(r"^\s*\[domain/([^\]]+)\]", text, re.M)


def check_domain_login(machine, probe_domain):
    configured = machine.path("etc/sssd/sssd.conf").exists() or machine.path("etc/sssd").is_dir()
    if not configured or not machine.target:
        return
    name = machine.target["name"]
    section(f"Domain login ({name})")
    source = run(["getent", "-s", "sss", "passwd", name])
    if source is None or source.returncode != 0:
        say("info", f"{name} is not a domain account (SSSD does not serve it); the domain stages below do not apply "
                    "to it" if source is not None else "NSS source: getent is not installed")
        domain_account = False
    else:
        domain_account = True
        say("ok", f"SSSD serves {name}: uid {machine.target['uid']}, home {machine.target['home']}")
        if len(machine.target["gids"]) <= 1:
            say("warning", f"only the primary group of {name} resolves; hypothesis: SSSD is offline without cached "
                           "group memberships, or group lookups fail (see: id " + name + ", sssctl user-show " + name + ")")
    domains = domain_names(machine)
    if not machine.privileged:
        say("unchecked", "SSSD online state and authorization need root; run: dotconfig machine status --sudo")
    for domain in domains if machine.privileged else []:
        status = run(["sssctl", "domain-status", domain, "-o"], timeout=20)
        if not broken(f"SSSD state of {domain}", "sssctl domain-status", status):
            continue
        online = re.search(r"Online status:\s*(\w+)", status.stdout)
        state = online.group(1).lower() if online else "unknown"
        found = discovery(domain) if probe_domain else None
        if state == "online":
            say("ok", f"SSSD is online for {domain}")
        elif state != "offline":
            say("info", f"SSSD reports {domain} as {state}")
        elif domain in machine.expectations()["offline-ok"]:
            say("info", f"SSSD is offline for {domain}, which machine-expect allows (offline-ok): logins use cached "
                        "credentials where cache_credentials is on (see: dotconfig creds status)")
        else:
            offline(machine, domain, found)
    if probe_domain and not domains:
        say("unchecked", "domain discovery: no SSSD domain name is readable (sssd.conf needs root)")
    if domain_account and machine.privileged:
        service = "gdm-password" if machine.path("etc/pam.d/gdm-password").exists() else "login"
        check = run(["sssctl", "user-checks", name, "-a", "acct", "-s", service], timeout=30)
        # sssctl prints the PAM verdict on stderr, and exits 0 after a denial as well.
        verdict = re.search(r"^pam_acct_mgmt:\s*(.+)$", check.stderr + "\n" + check.stdout, re.M) if check else None
        if check is None:
            pass
        elif verdict and verdict.group(1).strip().lower() == "success":
            say("ok", f"{name} is authorized to log in through {service} now (account check, no password)")
        elif verdict:
            say("warning", f"{name} is not authorized to log in through {service} now: "
                           f"{clean(verdict.group(1), 100)}; access_provider or GPO rules refuse it",
                               next_step=f"sudo sssctl user-checks {name} -a acct -s {service}")
        elif check.returncode != 0:
            say("failed", f"authorization of {name}: {failure('sssctl user-checks', check)}")
        else:
            say("failed", f"authorization of {name}: sssctl user-checks printed no pam_acct_mgmt verdict")
    lookup_cost(machine, name, domain_account)
    login_stages(machine, name)


MEMCACHE_FULL = re.compile(r"mmap cache of type (\w+) is full")


def lookup_cost(machine, name, domain_account):
    """Slow identity lookups: every login, sudo and file-access check waits on them, and sssd_be burns CPU
    expanding large nested groups."""
    took = machine.target.get("groups_took", 0)
    if domain_account and took > SLOW_GROUPS:
        say("warning", f"resolving the groups of {name} took {took:.1f} s; sudo and logins wait that long each time "
                       "the cache misses. Hypothesis: large nested domain groups; ignore_group_members = True in the "
                       "[domain/...] section stops SSSD from fetching every member (see: time id -G " + name + ")")
    full = {}
    for entry in machine.journal("SYSLOG_IDENTIFIER=sssd_nss", "+", "_COMM=sssd_nss") or []:
        matched = MEMCACHE_FULL.search(entry["MESSAGE"])
        if matched:
            full[matched.group(1)] = full.get(matched.group(1), 0) + 1
    for kind, count in sorted(full.items()):
        incident(f"SSSD's in-memory {kind} cache filled up {plural(count, 'time')} this boot, so lookups fall "
                       f"back to the slower SSSD socket; raise memcache_size_{kind} in [nss] of sssd.conf"
                       + (" and set ignore_group_members = True for the domain, which keeps group entries small"
                          if kind in ("group", "initgroups") else ""), next_step="journalctl -b -t sssd_nss")
    sudoers = re.search(r"^\s*sudoers:\s*(.+)$", machine.read("etc/nsswitch.conf") or "", re.M)
    if sudoers and "sss" in sudoers.group(1).split():
        say("info", f"sudo also asks SSSD for its rules (nsswitch: sudoers: {sudoers.group(1).strip()}); if the "
                    "domain defines none, sudo_provider = none in the [domain/...] section saves that lookup")


def link_domains():
    """{link: DNS domains} from systemd-resolved: a network that routes a domain's names says it serves it."""
    result = run(["resolvectl", "domain"], timeout=10)
    links = {}
    for line in (result.stdout if result is not None and result.returncode == 0 else "").splitlines():
        matched = re.match(r"^Link \d+ \(([^)]+)\):\s*(.*)$", line)
        if matched:
            links[matched.group(1)] = [entry.lstrip("~").rstrip(".").lower() for entry in matched.group(2).split()
                                       if entry.lstrip("~").rstrip(".")]
    return links


def offline(machine, domain, found):
    """Offline is expected only by policy or away from the domain's network. A network that routes the domain's
    DNS, or controllers that are discoverable, say SSSD should be reaching it; any VPN alone does not."""
    serving = sorted(link for link, names in link_domains().items()
                     if any(domain.lower() == name or domain.lower().endswith("." + name) for name in names))
    retry = ("sudo systemctl kill -s USR2 sssd asks it to go online; see: sssctl domain-status " + domain + " -a")
    if serving or found:
        evidence = (f"{', '.join(serving)} routes its DNS" if serving else "") + (" and " if serving and found else "") \
            + ("its controllers are discoverable" if found else "")
        say("warning", f"SSSD is offline for {domain} although {evidence}; hypotheses: the controllers are not "
                       "reachable from this network (routing, firewall, a VPN that is up but not passing traffic), "
                       f"LDAP or Kerberos ports are blocked, or SSSD has not retried yet ({retry})",
            next_step=f"sssctl domain-status {domain}; sudo sssctl logs-fetch")
        return
    vpns = f"; connected VPN: {', '.join(machine.vpns)}, which does not route it either" if machine.vpns else ""
    say("warning", f"SSSD is offline for {domain} and no connected network routes its DNS{vpns}; logins use cached "
                   "credentials where cache_credentials is on. Expected away from the domain network, a fault on it: "
                   "check with dotconfig machine status --sudo --probe-domain; if offline is normal here, add "
                   f"offline-ok {domain} to /etc/dotconfig/machine-expect", next_step="sssctl domain-status " + domain)


def discovery(domain):
    """The SRV records clients use to find controllers, asked once each and bounded; answering link included,
    which tells whether the VPN's DNS served them. True when any controller is listed."""
    listed = False
    for record in (f"_ldap._tcp.dc._msdcs.{domain}", f"_kerberos._tcp.{domain}"):
        result = run(["resolvectl", "query", "-t", "SRV", "--legend=no", record], timeout=10)
        if result is None:
            say("unchecked", "domain discovery: resolvectl is not installed")
            return None
        if result.returncode != 0:
            say("warning", f"discovery: {record} does not resolve ({failure('resolvectl', result)}); clients "
                           "cannot find the domain controllers through the current DNS",
                               next_step=f"resolvectl query -t SRV {record}")
            continue
        targets = re.findall(r"IN SRV \d+ \d+ \d+ (\S+)", result.stdout) or re.findall(r"\d+ \d+ \d+ (\S+)", result.stdout)
        link = re.search(r"-- link: (\S+)", result.stdout)
        say("ok" if targets else "warning", f"discovery: {record} lists {plural(len(targets), 'server')}"
            + (f" (answered through {link.group(1)})" if link else ""))
        listed = listed or bool(targets)
    return listed


# --- Desktop session and keyring --------------------------------------------------------------------------------

GRAPHICAL_PATHS = {"gdm-password": "password", "gdm-smartcard": "smart card", "gdm-fingerprint": "fingerprint",
                   "gdm-autologin": "automatic login"}
SESSION_CLOSED = re.compile(r"pam_unix\(([^:]+):session\): session closed for user ([^\s(]+)")
QUICK_EXIT_SECONDS = 60


def pam_stack(machine, service, depth=0, seen=None):
    """The PAM lines a service runs, with @include, include and substack followed, as (type, control, module,
    file). Order is kept; whether a jump skips a line is not evaluated."""
    seen = set() if seen is None else seen
    if depth > 8 or service in seen:
        return []
    seen.add(service)
    # Linux-PAM reads /etc/pam.d first, then the vendor directory packages may install to instead.
    text = machine.read(f"etc/pam.d/{service}")
    text = text if text is not None else machine.read(f"usr/lib/pam.d/{service}")
    if text is None:
        return []
    lines = []
    for raw in text.splitlines():
        words = raw.split("#", 1)[0].split()
        if not words:
            continue
        if words[0] == "@include" and len(words) > 1:
            lines += pam_stack(machine, words[1], depth + 1, seen)
            continue
        kind = words[0].lstrip("-")
        if len(words) < 3:
            continue
        control = words[1]
        if control.startswith("["):
            # A bracketed control can span words: [success=1 default=ignore]
            end = next((i for i, word in enumerate(words[1:], 1) if word.endswith("]")), 1)
            control, words = " ".join(words[1:end + 1]), [words[0], " ".join(words[1:end + 1])] + words[end + 1:]
        if control in ("include", "substack"):
            lines += [line for line in pam_stack(machine, words[2], depth + 1, seen) if line[0] == kind]
            continue
        lines.append((kind, control, Path(words[2]).name, service))
    return lines


def modules(stack, kind):
    return [module for line_kind, _, module, _ in stack if line_kind == kind]


def greeter_uids(entries):
    return {opened.group(3) for opened in (SESSION_OPENED.search(e["MESSAGE"]) for e in entries)
            if opened and opened.group(1) == "gdm-launch-environment" and opened.group(3)}


def check_desktop(machine):
    """Login screen, the account's graphical logins and its keyring, told apart: the greeter's failures are not
    the user's, and authentication succeeding does not mean a desktop came up."""
    manager = run(["systemctl", "show", "-p", "Id", "-p", "ActiveState", "-p", "SubState", "-p", "NRestarts", "-p",
                   "ActiveEnterTimestampMonotonic", "--no-pager", "display-manager.service"])
    values = dict(line.split("=", 1) for line in (manager.stdout if manager else "").splitlines() if "=" in line)
    if not manager or manager.returncode != 0 or values.get("Id", "display-manager.service") == "display-manager.service":
        return
    section(f"Desktop session ({machine.user})")
    restarts = int(values.get("NRestarts") or 0)
    past, recovered, note = restart_outcome(values, up_since_boot(values, uptime_seconds(machine)))
    say("warning" if restarts else "info", f"display manager: {values['Id']}, {values.get('ActiveState', '?')}"
        + (f", restarted {plural(restarts, 'time')} this boot; the login screen went away each time{note}"
           if restarts else ""), past=past, recovered=recovered, next_step=f"journalctl -b -u {values['Id']}")
    session_definitions(machine)
    if not machine.sees_system_journal():
        say("unchecked", "graphical logins: " + machine.journal_hint())
    else:
        graphical_logins(machine)
    keyring(machine)
    desktop_components(machine)


def session_definitions(machine):
    """Each installed desktop session's program: a missing one returns to the login screen when chosen."""
    chosen = None
    if machine.target and machine.privileged:
        account = machine.read(f"var/lib/AccountsService/users/{machine.target['name']}") or ""
        matched = re.search(r"^(?:Session|XSession)=(\S+)", account, re.M)
        chosen = matched.group(1) if matched else None
    names = []
    for directory in ("usr/share/wayland-sessions", "usr/share/xsessions"):
        for entry in sorted(glob.glob(str(machine.path(directory) / "*.desktop"))):
            text = Path(entry).read_text(errors="replace")
            name = Path(entry).stem
            names.append(name)
            program = re.search(r"^(?:TryExec|Exec)=(\S+)", text, re.M)
            if program and not executable(machine, program.group(1)):
                say("warning", f"session {name}: its program {program.group(1)} is missing; choosing it at the "
                               "login screen returns straight to it",
                                   next_step="ls /usr/share/wayland-sessions /usr/share/xsessions")
    if chosen and chosen not in names:
        say("warning", f"{machine.user} last chose session {chosen}, which is no longer installed; the login screen "
                       "falls back or fails (installed: " + ", ".join(names or ["none"]) + ")",
                           next_step=f"sudo cat /var/lib/AccountsService/users/{machine.user}")
    elif chosen:
        say("info", f"{machine.user} logs in to session {chosen}")


def executable(machine, program):
    if program.startswith("/"):
        return machine.path(program.lstrip("/")).exists()
    return any(machine.path(f"{directory}/{program}".lstrip("/")).exists()
               for directory in ("/usr/bin", "/usr/sbin", "/bin", "/usr/local/bin", "/usr/libexec"))


def graphical_logins(machine):
    """Per graphical login of the account: which path (password, smart card, fingerprint, automatic), whether
    the session lasted, and screen-unlock failures while a session was open."""
    name, uid = machine.user, str(machine.uid)
    auth = machine.journal("SYSLOG_FACILITY=10", "SYSLOG_FACILITY=4") or []
    greeters = greeter_uids(auth)
    ready = [e for e in machine.journal("MESSAGE_ID=" + UNIT_STARTED, "USER_UNIT=graphical-session.target") or []
             if e.get("_UID") == uid]
    opened, quick, unlock_failures = [], [], {}
    for entry in auth:
        message = entry["MESSAGE"]
        started = SESSION_OPENED.search(message)
        if started and started.group(1) in GRAPHICAL_PATHS and started.group(2) == name:
            opened.append([entry, started.group(1), None])
            continue
        closed = SESSION_CLOSED.search(message)
        if closed and closed.group(1) in GRAPHICAL_PATHS and closed.group(2) == name:
            for login in reversed(opened):
                if login[1] == closed.group(1) and login[2] is None:
                    login[2] = entry
                    break
            continue
        failed = AUTH_FAILURE.search(message)
        if failed and failed.group(1) in GRAPHICAL_PATHS and re.search(rf"\buser[= ]{re.escape(name)}\b", message):
            # A failure while one of the account's graphical sessions is open is a screen unlock.
            if any(login[2] is None for login in opened):
                unlock_failures[failed.group(1)] = unlock_failures.get(failed.group(1), 0) + 1
    for entry, service, closed in opened:
        start = monotonic(entry)
        lasted = (monotonic(closed) - start) / 1e6 if closed else None
        desktop = any(start <= monotonic(e) and (closed is None or monotonic(e) <= monotonic(closed)) for e in ready)
        if lasted is not None and lasted < QUICK_EXIT_SECONDS and not desktop:
            quick.append((entry, service, lasted))
    for entry, service, lasted in quick:
        later = any(monotonic(e) > monotonic(entry) for e in ready)
        incident(f"{name} logged in by {GRAPHICAL_PATHS[service]} at {when(entry)}, but the session ended "
                       f"{lasted:.0f} s later before the desktop was ready, back to the login screen; see: "
                       f"journalctl -b _UID={uid} --since around then, and the Shell crashes below"
                 + ("; a later login reached the desktop" if later else ""), recovered=later)
    for service, count in sorted(unlock_failures.items()):
        say("warning" if count > 2 else "info",
            f"{plural(count, 'failed screen unlock')} by {GRAPHICAL_PATHS[service]} while {name} was logged in",
            past=True, next_step=f"journalctl -b SYSLOG_FACILITY=10 --grep {service}")
    if opened and not quick:
        paths = sorted({GRAPHICAL_PATHS[service] for _, service, _ in opened})
        say("ok", f"{plural(len(opened), 'graphical login')} of {name} by {', '.join(paths)} this boot; none ended "
                  "before the desktop was ready")
    elif not opened:
        say("info", f"no graphical login of {name} recorded in this boot")
    shell_crashes(machine, uid, greeters)


def shell_crashes(machine, uid, greeters):
    """Shell crashes split by whose they were: the login screen's (a greeter account) or the user's session."""
    dumps = [e for e in machine.journal("MESSAGE_ID=" + COREDUMP) or []
             if (e.get("COREDUMP_COMM") or "") in ("gnome-shell", "mutter", "Xwayland", "gdm-session-wor")]
    mine = [e for e in dumps if e.get("COREDUMP_UID") == uid]
    login_screen = [e for e in dumps if e.get("COREDUMP_UID") in greeters]
    if mine:
        times = [monotonic(e) for e in mine]
        loop = len(mine) >= 3 and times[-1] - times[-3] < 600e6
        incident(f"{machine.user}'s desktop crashed {plural(len(mine), 'time')} this boot"
            + (", three within ten minutes: a crash loop" if loop else "") + f", last at {when(mine[-1])} "
            f"({mine[-1].get('COREDUMP_COMM')}); see: coredumpctl info {mine[-1].get('COREDUMP_PID', '')}".rstrip())
    if login_screen:
        incident(f"the login screen's Shell crashed {plural(len(login_screen), 'time')} this boot (greeter "
                       "account, not a user session); see: coredumpctl list gnome-shell")


def keyring(machine):
    """The Secret Service in the account's session: who provides it, whether its default collection is unlocked,
    whether the login path unlocks it, and whether its storage is usable. No secret is read and nothing is unlocked
    or started: queries never auto-start a service."""
    flags = machine.user_flags() if machine.reach else None
    if not flags:
        say("unchecked", f"keyring of {machine.user}: their session bus needs --sudo")
        return
    bus = ["busctl"] + flags + ["--no-pager"]
    names = run(bus + ["list", "--no-legend"], timeout=10)
    if names is None:
        say("unchecked", "keyring: busctl is not installed")
        return
    if names.returncode != 0:
        say("info", f"keyring: no session bus for {machine.user} ({failure('busctl', names)}); not applicable while "
                    "they are logged out")
        return
    row = next((line.split() for line in names.stdout.splitlines()
                if line.split() and line.split()[0] == "org.freedesktop.secrets"), None)
    if row is None:
        say("warning", "no Secret Service provider (org.freedesktop.secrets) on the session bus: browsers, VPN "
                       "and mail clients cannot store passwords (gnome-keyring or KeePassXC provide it)",
            next_step="systemctl --user status gnome-keyring-daemon.service")
        return
    if len(row) < 3 or row[1] == "-":
        say("info", "the Secret Service is not running yet; it starts on first use (not started here)")
        return
    provider = row[2]
    locked = run(bus + ["--auto-start=no", "get-property", "org.freedesktop.secrets",
                        "/org/freedesktop/secrets/aliases/default", "org.freedesktop.Secret.Collection", "Locked"],
                 timeout=10)
    if locked is None or locked.returncode != 0:
        say("info", f"the Secret Service ({provider}) has no default collection; the first application that stores a "
                    "secret asks to create one")
        state = None
    else:
        state = locked.stdout.strip().endswith("true")
    login = last_graphical_login(machine)
    stack = pam_stack(machine, login) if login else []
    unlocks = "pam_gnome_keyring.so" in modules(stack, "auth")
    if state is False:
        say("ok", f"the Secret Service ({provider}) is running and its default collection is unlocked")
    elif state:
        if login in ("gdm-smartcard", "gdm-fingerprint", "gdm-autologin"):
            say("info", f"the default keyring is locked, as expected after a {GRAPHICAL_PATHS[login]} login (no "
                        "password was given to unlock it); it unlocks on first use with its own password")
        elif login and not unlocks:
            say("warning", f"the default keyring is locked and the {login} PAM path does not include "
                           "pam_gnome_keyring in auth, so a password login cannot unlock it",
                               next_step=f"grep -r keyring /etc/pam.d/{login}")
        else:
            say("warning", "the default keyring stayed locked after a password login; hypotheses: its password "
                           "differs from the login password (common after a domain password change made "
                           "elsewhere), or the unlock failed (see: journalctl --user -b -u gnome-keyring-daemon)")
    if login and login not in ("gdm-smartcard", "gdm-fingerprint", "gdm-autologin") and not unlocks and state is not True:
        say("info", f"the {login} PAM path has no pam_gnome_keyring auth line; the keyring is unlocked separately "
                    "(control flow inside the stack is not evaluated)")
    keyring_storage(machine)


def last_graphical_login(machine):
    """The PAM service of the account's newest graphical session, from loginctl."""
    user = run(["loginctl", "show-user", str(machine.uid), "-p", "Sessions"])
    services = []
    for session in (user.stdout.partition("=")[2].split() if user and user.returncode == 0 else []):
        result = run(["loginctl", "show-session", session, "-p", "Service", "-p", "Type"])
        info = dict(line.split("=", 1) for line in (result.stdout if result else "").splitlines() if "=" in line)
        if info.get("Service") in GRAPHICAL_PATHS:
            services.append(info["Service"])
    return services[-1] if services else None


def keyring_storage(machine):
    home = machine.target["home"].rstrip("/")
    data = (proxy_values_env(machine).get("XDG_DATA_HOME") or f"{home}/.local/share").rstrip("/")
    path = machine.path(f"{data}/keyrings".lstrip("/"))
    try:
        st = path.stat()
    except OSError:
        say("info", f"no keyring storage yet at {data}/keyrings; it is created with the first keyring")
        return
    if st.st_uid != machine.uid:
        say("warning", f"{data}/keyrings is owned by {owner_label(st.st_uid)}, not {machine.user}: the keyring cannot "
                       f"save or open its files ; run: sudo chown -R {machine.user} {data}/keyrings")
        return
    blocked = inspector.access_check(machine.root, path, st, identity(machine), 7)
    if blocked and blocked[0] == "warning":
        say("warning", f"{machine.user} cannot read and write {data}/keyrings, so keyrings cannot be opened or saved",
            next_step=f"ls -ld {data}/keyrings")
    foreign = [entry.name for entry in path.iterdir() if entry.lstat().st_uid != machine.uid]
    if foreign:
        say("warning", f"{plural(len(foreign), 'keyring file')} in {data}/keyrings belong to another account, e.g. "
                       f"{foreign[0]}; that keyring cannot be opened",
            next_step=f"sudo chown -R {machine.user} {data}/keyrings")


def proxy_values_env(machine):
    """The account's user-manager environment, for the XDG paths its session uses; read once."""
    if machine.manager_environment is None:
        flags = machine.user_flags()
        result = run(["systemctl"] + flags + ["show-environment"]) if flags else None
        machine.manager_environment = {} if result is None or result.returncode != 0 else \
            dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return machine.manager_environment


# The variables that decide which settings store gsettings and dconf read.
SETTINGS_ENVIRONMENT = ("XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS", "DCONF_PROFILE",
                        "GSETTINGS_BACKEND", "GSETTINGS_SCHEMA_DIR")


def as_account(machine, command, environment):
    """The command run as the inspected account in an environment built from scratch: its home, runtime directory
    and the settings variables of its user manager, and nothing of the caller's (config home, dconf profile,
    session bus). Under sudo it runs through runuser, without it only for oneself. None when out of reach."""
    if machine.uid is None or not machine.target or not machine.reach:
        return None
    variables = [f"HOME={machine.target['home']}", f"USER={machine.user}", f"LOGNAME={machine.user}",
                 "PATH=" + os.environ.get("PATH", "/usr/bin:/bin"), f"XDG_RUNTIME_DIR=/run/user/{machine.uid}"]
    variables += [f"{name}={environment[name]}" for name in SETTINGS_ENVIRONMENT if environment.get(name)]
    command = ["env", "-i"] + variables + command
    if machine.privileged and machine.root == Path("/") and machine.uid != 0:
        return ["runuser", "-u", machine.user, "--"] + command
    return command


def gvariant(text):
    """A gsettings value as Python: booleans, numbers, strings and lists of them."""
    text = re.sub(r"^(?:@\w+|u?int(?:16|32|64)|byte|double|objectpath) ", "", text.strip())
    if text in ("true", "false"):
        return text == "true"
    try:
        return ast.literal_eval(text)
    except (ValueError, SyntaxError):
        return text


def gsettings(machine, schema):
    """The account's values of one settings schema, read from its dconf database (no session bus needed). None
    when gsettings is missing, the schema is not installed, or the account is out of reach."""
    environment = proxy_values_env(machine) if machine.reach else {}
    if not environment and not machine.settings_noted:
        machine.settings_noted = True
        say("info", f"settings of {machine.user} are read from the default locations: their user manager's "
                    "environment (XDG paths, DCONF_PROFILE) is not available")
    command = as_account(machine, ["gsettings", "list-recursively", schema], environment)
    result = run(command, timeout=20) if command else None
    if result is None or result.returncode != 0:
        return None
    values = {}
    for line in result.stdout.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[0] == schema:
            values[parts[1]] = gvariant(parts[2])
    return values


def config_home(machine, environment):
    return (environment.get("XDG_CONFIG_HOME") or f"{machine.target['home'].rstrip('/')}/.config").rstrip("/")


# --- Desktop components -----------------------------------------------------------------------------------------

COMPONENT_UNITS = {
    "xdg-desktop-portal.service": "sandboxed and Flatpak applications get no file chooser, screen sharing or link "
                                  "opening",
    "xdg-desktop-portal-gnome.service": "screenshots, screen sharing and file choosers through the GNOME backend fail",
    "xdg-desktop-portal-gtk.service": "file choosers and settings through the GTK backend fail",
    "pipewire.service": "no sound, camera or screen sharing",
    "pipewire-pulse.service": "applications that use PulseAudio have no sound",
    "wireplumber.service": "no audio or video devices appear: no sound and no camera",
    "pulseaudio.service": "",
}
SOUND_UNITS = ("pipewire.service", "pipewire-pulse.service", "wireplumber.service")
PORTAL_FAILURE = re.compile(r"(?i)no skeleton|failed to (?:create|load|start|register)\b.*(?:implementation|backend|"
                            r"portal)|backend .*(?:failed|not found|timed out)|could not find .*backend|"
                            r"Timeout was reached")
EXTENSION_ERROR = re.compile(r"(?:Extension|Error loading extension|Could not load extension) ([\w.+-]+@[\w.+-]+)")
DCONF_FAILURE = re.compile(r"(?i)dconf.*(?:failed to commit|unable to (?:open|create|write)|permission denied|"
                           r"could not (?:open|write))")
GPU_ERROR = re.compile(r"(?i)\b(i915|xe|amdgpu|radeon|nouveau|nvidia(?:-modeset)?)\b.*(?:\*ERROR\*|GPU hang|hang on|"
                       r"ring \S+ timeout|timed out|failed|reset)")
RESUMED = re.compile(r"PM: (?:suspend|hibernation) exit|System returned from sleep|PM: resume\b")
SLEEP_FAILED = re.compile(r"(?i)Failed to put system to sleep|PM: Some devices failed to (?:suspend|resume)|"
                          r"Freezing (?:of tasks|user space processes) failed|PM: (?:suspend|hibernation) .*failed|"
                          r"error during resume")
SHELL_PROGRAMS = ("gnome-shell", "mutter", "Xwayland")
RESUME_WINDOW = 120e6


def desktop_components(machine):
    """Desktop pieces that fail on their own while login works: portals, sound, Shell extensions, settings storage
    and policy, autostart entries, and what follows a resume from sleep."""
    section(f"Desktop components ({machine.user})")
    environment = proxy_values_env(machine) if machine.reach else {}
    desktops = [part.lower() for part in (environment.get("XDG_CURRENT_DESKTOP") or "").split(":") if part]
    flags = machine.user_flags() if machine.reach else None
    found = None
    if not flags:
        say("unchecked", f"portal and sound services of {machine.user}: their user manager needs --sudo")
    else:
        found = show_units(flags, list(COMPONENT_UNITS), ["Id", "LoadState", "ActiveState", "SubState", "Result"],
                           "portal and sound services")
    log = machine.user_log() if machine.target else []
    if found:
        sound(found, log)
    if machine.target:
        portals(machine, environment, desktops, found or {}, log)
        shell_extensions(machine, environment, log)
        dconf_health(machine, environment, log)
        autostart(machine, environment, desktops)
    if machine.sees_system_journal():
        resumes(machine)
    else:
        say("unchecked", "resume from sleep: " + machine.journal_hint())


def installed_units(found):
    return {name: props for name, props in found.items() if props.get("LoadState") not in (None, "", "not-found")}


def running(props):
    return (props or {}).get("ActiveState") in ("active", "activating", "reloading")


def sound(found, log):
    """PipeWire with its PulseAudio server and session manager. Failed units are counted under Services; here they
    are only explained."""
    units = installed_units(found)
    for name, props in units.items():
        if props.get("ActiveState") == "failed" and COMPONENT_UNITS[name]:
            say("info", f"{name} has failed (see Services): {COMPONENT_UNITS[name]}")
    if running(units.get("pipewire.service")) and "wireplumber.service" in units \
            and not running(units["wireplumber.service"]) and units["wireplumber.service"].get("ActiveState") != "failed":
        say("warning", "PipeWire runs without its session manager WirePlumber, so no audio or video devices appear; "
                       "run: systemctl --user start wireplumber.service",
                           next_step="systemctl --user status wireplumber.service")
    if running(units.get("pulseaudio.service")) and running(units.get("pipewire-pulse.service")):
        say("warning", "PulseAudio and pipewire-pulse are both running and compete for the sound server, so sound "
                       "works in some applications only; Ubuntu uses pipewire-pulse; run: systemctl --user mask "
                       "pulseaudio.service pulseaudio.socket", next_step="pactl info")
    present = [name for name in SOUND_UNITS if name in units]
    errors = [e for e in log if (e.get("_SYSTEMD_USER_UNIT") in present or e.get("SYSLOG_IDENTIFIER") in
                                 ("pipewire", "pipewire-pulse", "wireplumber")) and int(e.get("PRIORITY", "6")) <= 3]
    if errors:
        say("info", f"sound services logged {plural(len(errors), 'error')} this boot, last: "
                    f"{clean(errors[-1]['MESSAGE'], 160)}")
    if present and all(running(units[name]) for name in present):
        say("ok", "sound and screen sharing: " + ", ".join(name.rsplit(".", 1)[0] for name in present) + " running")
    elif present and not any(running(units[name]) or units[name].get("ActiveState") == "failed" for name in present):
        say("info", "PipeWire is not running; it starts with the first application that uses sound")


def portals(machine, environment, desktops, found, log):
    """Which portal backend serves the session: the portals.conf that applies to the desktop, the backends it
    names, and the backend failures xdg-desktop-portal logged."""
    if not executable(machine, "/usr/libexec/xdg-desktop-portal"):
        return
    config_dirs, data_dirs = portal_directories(machine, environment)
    backends = installed_backends(machine, environment, data_dirs)
    if not backends:
        say("warning", "xdg-desktop-portal is installed without any backend, so sandboxed applications get no file "
                       "chooser or screen sharing (Ubuntu's are xdg-desktop-portal-gnome and -gtk)",
            next_step="apt policy xdg-desktop-portal-gnome xdg-desktop-portal-gtk")
        return
    if not desktops:
        say("info", f"portals: no desktop name for {machine.user} (no graphical session), so which backend applies is "
                    "not checked; installed: " + ", ".join(backends))
    else:
        config = None
        for directory in config_dirs:
            for name in [f"{desktop}-portals.conf" for desktop in desktops] + ["portals.conf"]:
                text = machine.read(f"{directory}/{name}".lstrip("/"))
                if text is not None:
                    config = (f"{directory}/{name}", text)
                    break
            if config:
                break
        if config:
            preferred = re.split(r"^\[preferred\]\s*$", config[1], flags=re.M)
            choices = dict(re.findall(r"^([\w.-]+)\s*=\s*(.*)$", preferred[1].split("\n[")[0], re.M)) \
                if len(preferred) > 1 else {}
            unusable, disabled = portal_routes(choices, backends)
            for key, reasons in unusable:
                say("warning", f"portal configuration {config[0]}: {key} has no usable backend ({'; '.join(reasons)}), "
                               "so that portal fails", next_step="journalctl --user -b -u xdg-desktop-portal.service")
            if disabled:
                say("info", f"portals switched off on purpose by {config[0]} (none): {', '.join(disabled)}")
            if not unusable:
                say("ok", f"portals for {':'.join(desktops)}: {config[0]} chooses "
                    + (choices.get("default") or "per interface") + " by default, and each interface it routes "
                    f"explicitly has an installed backend that declares it (installed: {', '.join(backends)})")
        elif any(set(desktops) & used_in(text) for text in backends.values()):
            say("ok", f"portals for {':'.join(desktops)}: chosen by the backends' UseIn (no portals.conf)")
        else:
            say("warning", f"no portal backend is configured for desktop {':'.join(desktops)} (no portals.conf, no "
                           "matching UseIn), so sandboxed applications get no file chooser or screen sharing",
                next_step="ls /usr/share/xdg-desktop-portal/portals")
    failures = [e for e in log if ((e.get("_SYSTEMD_USER_UNIT") or "").startswith("xdg-desktop-portal")
                                   or (e.get("SYSLOG_IDENTIFIER") or "").startswith("xdg-desktop-por"))
                and PORTAL_FAILURE.search(e["MESSAGE"])]
    if failures:
        incident(f"xdg-desktop-portal reported {plural(len(failures), 'backend failure')} this boot, last at "
                       f"{when(failures[-1])}: {clean(failures[-1]['MESSAGE'], 160)}; see: journalctl --user -b "
                       "-u 'xdg-desktop-portal*'")


def portal_directories(machine, environment):
    """Where portals.conf is looked for, highest precedence first, and the data directories, as the portals.conf
    documentation orders them: config home, XDG_CONFIG_DIRS, /etc, data home, XDG_DATA_DIRS, /usr/share."""
    home = machine.target["home"].rstrip("/")
    data_home = (environment.get("XDG_DATA_HOME") or f"{home}/.local/share").rstrip("/")
    config_dirs = [d for d in (environment.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":") if d]
    data_dirs = [d for d in (environment.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]
    searched = [config_home(machine, environment)] + config_dirs + ["/etc", data_home] + data_dirs + ["/usr/share"]
    return (list(dict.fromkeys(f"{d.rstrip('/')}/xdg-desktop-portal" for d in searched)),
            list(dict.fromkeys(d.rstrip("/") for d in data_dirs + ["/usr/share"])))


def installed_backends(machine, environment, data_dirs):
    """Backend name to its .portal text: from XDG_DESKTOP_PORTAL_DIR when set, else the data directories (the
    first file of a name wins)."""
    directories = [environment["XDG_DESKTOP_PORTAL_DIR"]] if environment.get("XDG_DESKTOP_PORTAL_DIR") else \
        [f"{d}/xdg-desktop-portal/portals" for d in data_dirs]
    backends = {}
    for directory in directories:
        for entry in sorted(glob.glob(str(machine.path(directory.lstrip("/")) / "*.portal"))):
            backends.setdefault(Path(entry).stem, Path(entry).read_text(errors="replace"))
    return backends


def interfaces(text):
    matched = re.search(r"^Interfaces=(.*)$", text, re.M)
    return {name.strip() for name in matched.group(1).split(";") if name.strip()} if matched else set()


def portal_routes(choices, backends):
    """Evaluate portals.conf [preferred]: each explicitly routed interface takes the first listed backend that is
    installed and declares it ("*" any that does, "none" none on purpose). The default list is only checked for an
    installed backend, since which interfaces it must serve depends on the caller. Returns (unusable, disabled)."""
    unusable, disabled = [], []
    for key, value in choices.items():
        names = [name.strip() for name in value.split(";") if name.strip()]
        if not names:
            continue
        if key == "default":
            if not any(name in ("*", "none") or name in backends for name in names):
                unusable.append((key, [f"{name} is not installed" for name in names]))
            continue
        if not key.startswith("org.freedesktop.impl.portal."):
            continue
        reasons = []
        for name in names:
            if name == "none":
                disabled.append(key)
                break
            if name == "*":
                if any(key in interfaces(text) for text in backends.values()):
                    break
                reasons.append("no installed backend declares it")
            elif name not in backends:
                reasons.append(f"{name} is not installed")
            elif key not in interfaces(backends[name]):
                reasons.append(f"{name} does not implement it")
            else:
                break
        else:
            unusable.append((key, reasons))
    return unusable, disabled


def used_in(text):
    """The desktops a backend's .portal file says it serves (the pre-portals.conf way of choosing)."""
    matched = re.search(r"^UseIn=(.*)$", text, re.M)
    return {name.strip().lower() for name in matched.group(1).split(";") if name.strip()} if matched else set()


def shell_major(machine):
    result = run(["gnome-shell", "--version"], timeout=10)
    matched = re.search(r"(\d+)\.", result.stdout) if result and result.returncode == 0 else None
    return matched.group(1) if matched else None


def shell_extensions(machine, environment, log):
    """Enabled Shell extensions: missing, not declared for the running Shell (the Shell skips them after an
    upgrade), or logging errors this boot."""
    if not executable(machine, "/usr/bin/gnome-shell"):
        return
    settings = gsettings(machine, "org.gnome.shell")
    if settings is None:
        say("unchecked", f"Shell extensions of {machine.user}: their settings cannot be read (gsettings missing, or "
                         "the account is out of reach without --sudo)")
        return
    if settings.get("disable-user-extensions") is True:
        say("info", "user extensions are turned off (org.gnome.shell disable-user-extensions)")
        return
    enabled = [uuid for uuid in settings.get("enabled-extensions") or [] if isinstance(uuid, str)]
    data = (environment.get("XDG_DATA_HOME") or f"{machine.target['home'].rstrip('/')}/.local/share").rstrip("/")
    version = shell_major(machine)
    validate = settings.get("disable-extension-version-validation") is not True
    missing, outdated = [], []
    for uuid in enabled:
        meta = next((machine.read(f"{directory}/gnome-shell/extensions/{uuid}/metadata.json".lstrip("/"))
                     for directory in (data, "/usr/local/share", "/usr/share")
                     if machine.path(f"{directory}/gnome-shell/extensions/{uuid}/metadata.json".lstrip("/")).exists()),
                    None)
        if meta is None:
            missing.append(uuid)
            continue
        try:
            declared = [str(value).split(".")[0] for value in json.loads(meta).get("shell-version", [])]
        except (ValueError, AttributeError):
            declared = []
        if version and validate and version not in declared:
            outdated.append(f"{uuid} (declares {', '.join(declared) or 'none'})")
    if missing:
        say("info", f"{plural(len(missing), 'enabled extension')} not installed: {', '.join(missing)}")
    if outdated:
        say("warning", f"{plural(len(outdated), 'enabled extension')} not declared for GNOME Shell {version}, so the "
                       f"Shell skips {'it' if len(outdated) == 1 else 'them'}: {'; '.join(outdated)}; update them or "
                       "run: gnome-extensions disable UUID", next_step="gnome-extensions list --enabled --details")
    errors = {}
    for entry in log:
        if (entry.get("SYSLOG_IDENTIFIER") or entry.get("_COMM")) != "gnome-shell":
            continue
        matched = EXTENSION_ERROR.search(entry["MESSAGE"])
        if matched:
            errors.setdefault(matched.group(1), []).append(entry)
    for uuid, entries in sorted(errors.items()):
        incident(f"Shell extension {uuid} logged {plural(len(entries), 'error')} this boot, last: "
                       f"{clean(entries[-1]['MESSAGE'], 160)}; to rule it out: gnome-extensions disable {uuid}")
    if enabled and not (missing or outdated or errors):
        say("ok", f"{plural(len(enabled), 'enabled Shell extension')} installed"
            + (f", declared for GNOME Shell {version}" if version and validate else "") + ", no errors this boot")


def dconf_health(machine, environment, log):
    """Whether settings can be saved, and the system policy that locks them or has not been compiled."""
    directory = f"{config_home(machine, environment)}/dconf"
    path = machine.path(directory.lstrip("/"))
    try:
        st = path.stat()
    except OSError:
        st = None
    if st and st.st_uid != machine.uid:
        say("warning", f"{directory} is owned by {owner_label(st.st_uid)}, not {machine.user}: settings changes are "
                       f"lost at logout ; run: sudo chown -R {machine.user} {directory}")
    elif st:
        blocked = inspector.access_check(machine.root, path, st, identity(machine), 7)
        if blocked and blocked[0] == "warning":
            say("warning", f"{machine.user} cannot write {directory}: settings changes are lost at logout",
                next_step=f"ls -ld {directory}")
    failures = [e for e in log if DCONF_FAILURE.search(e["MESSAGE"])]
    if failures:
        incident(f"settings failed to save {plural(len(failures), 'time')} this boot, last at "
                       f"{when(failures[-1])}: {clean(failures[-1]['MESSAGE'], 160)}",
                           next_step="journalctl --user -b --grep dconf")
    chosen = environment.get("DCONF_PROFILE") or "user"
    profile = machine.read(chosen.lstrip("/") if chosen.startswith("/") else f"etc/dconf/profile/{chosen}") or ""
    for name in re.findall(r"^system-db:(\S+)", profile, re.M):
        keyfiles, compiled = machine.path(f"etc/dconf/db/{name}.d"), machine.path(f"etc/dconf/db/{name}")
        sources = [entry for entry in keyfiles.rglob("*") if entry.is_file()] if keyfiles.is_dir() else []
        if sources and (not compiled.exists()
                        or max(entry.stat().st_mtime for entry in sources) > compiled.stat().st_mtime):
            say("warning", f"dconf policy {name}: /etc/dconf/db/{name}.d changed after it was compiled, so its "
                           "defaults and locks are not in effect; run: sudo dconf update")
        locks = [line.strip() for entry in sorted((keyfiles / "locks").glob("*")) if entry.is_file()
                 for line in entry.read_text(errors="replace").splitlines() if line.strip().startswith("/")]
        if locks:
            say("info", f"{plural(len(locks), 'setting')} locked by system policy {name} (e.g. {locks[0]}); users "
                        "cannot change them")


def autostart(machine, environment, desktops):
    """Login autostart entries that apply to this desktop and point to a program that is not installed. An
    entry whose TryExec is missing is skipped by design, so it is not reported."""
    user_directory = f"{config_home(machine, environment)}/autostart"
    entries = {}
    for scope, directory in (("system", "/etc/xdg/autostart"), ("user", user_directory)):
        for entry in sorted(glob.glob(str(machine.path(directory.lstrip("/")) / "*.desktop"))):
            entries[Path(entry).name] = (scope, Path(entry))
    problems = []
    for name, (scope, path) in sorted(entries.items()):
        try:
            text = path.read_text(errors="replace")
        except OSError:
            problems.append((scope, name, f"{machine.user} cannot read it"))
            continue
        main = re.search(r"^\[Desktop Entry\][^\n]*\n(.*?)(?=^\[|\Z)", text, re.M | re.S)
        fields = dict(re.findall(r"^([A-Za-z0-9-]+)=(.*)$", main.group(1) if main else text, re.M))
        if fields.get("Hidden", "").lower() == "true" or fields.get("X-GNOME-Autostart-enabled", "").lower() == "false":
            continue
        only = {d.lower() for d in fields.get("OnlyShowIn", "").split(";") if d}
        hidden_in = {d.lower() for d in fields.get("NotShowIn", "").split(";") if d}
        # Without a desktop name an OnlyShowIn entry may not apply, so it is left out rather than guessed.
        if (only and not only & set(desktops)) or hidden_in & set(desktops):
            continue
        if fields.get("TryExec") and not executable(machine, fields["TryExec"]):
            continue
        try:
            words = shlex.split(fields.get("Exec", ""))
        except ValueError:
            words = fields.get("Exec", "").split()
        while words and (words[0] == "env" or re.match(r"^\w+=", words[0])):
            words.pop(0)
        if not words:
            problems.append((scope, name, "it has no Exec line"))
        elif not executable(machine, words[0]):
            problems.append((scope, name, f"its program {words[0]} is missing"))
    for scope, name, why in problems:
        say("warning", f"autostart entry {name} ({scope}): {why}, so it fails at every login"
            + (f"; if it is no longer wanted, run: rm {user_directory}/{name}" if scope == "user" else ""),
                next_step=f"cat {path}")
    if entries and not problems:
        count = len(entries)
        say("ok", f"{count} autostart entr{'y' if count == 1 else 'ies'} checked: each one that applies points to an installed "
                  "program")


def resumes(machine):
    """Resumes from sleep this boot, and what went wrong right after them: graphics driver errors, Shell crashes
    and failed unlocks within two minutes are correlated, not proven, causes of a broken desktop after resume."""
    entries = machine.journal("_TRANSPORT=kernel", "+", "SYSLOG_IDENTIFIER=systemd-sleep") or []
    failed = [e for e in entries if SLEEP_FAILED.search(e["MESSAGE"])]
    if failed:
        incident(f"suspend or resume failed {plural(len(failed), 'time')} this boot, last at {when(failed[-1])}: "
                       f"{clean(kernel_text(failed[-1]), 160)}", next_step="journalctl -b -t systemd-sleep")
    times = []
    for entry in entries:
        if RESUMED.search(entry["MESSAGE"]) and (not times or monotonic(entry) - times[-1] > 30e6):
            times.append(monotonic(entry))
    if not times:
        if not failed:
            say("info", "the machine did not resume from sleep this boot")
        return
    uid = str(machine.uid)
    gpu = [e for e in entries if e.get("_TRANSPORT") == "kernel" and int(e.get("PRIORITY", "6")) <= 4
           and GPU_ERROR.search(kernel_text(e))]
    crashes = [e for e in machine.journal("MESSAGE_ID=" + COREDUMP) or []
               if e.get("COREDUMP_UID") == uid and (e.get("COREDUMP_COMM") or "") in SHELL_PROGRAMS]
    unlocks = []
    for entry in machine.journal("SYSLOG_FACILITY=10", "SYSLOG_FACILITY=4") or []:
        denied = AUTH_FAILURE.search(entry["MESSAGE"])
        if denied and denied.group(1) in GRAPHICAL_PATHS \
                and re.search(rf"\buser[= ]{re.escape(machine.user)}\b", entry["MESSAGE"]):
            unlocks.append(entry)

    def followed(events):
        return [t for t in times if any(t <= monotonic(e) <= t + RESUME_WINDOW for e in events)]
    after_gpu, after_crash, after_unlock = followed(gpu), followed(crashes), followed(unlocks)
    say("info", f"{plural(len(times), 'resume')} from sleep this boot")
    if after_gpu:
        first = next(e for e in gpu if any(t <= monotonic(e) <= t + RESUME_WINDOW for t in after_gpu))
        incident(f"after {len(after_gpu)} of them the graphics driver reported errors within two minutes, e.g. "
                       f"{clean(kernel_text(first), 160)}; a black, frozen or garbled screen after resume likely "
                       "comes from this (hypothesis); see: journalctl -b -k -p warning")
    if after_crash:
        incident(f"{machine.user}'s Shell crashed within two minutes after {plural(len(after_crash), 'resume')}"
            + (", together with graphics errors: the driver is the likely cause (hypothesis)"
               if set(after_crash) & set(after_gpu) else "") + "; see: coredumpctl list gnome-shell")
    if after_unlock:
        say("info", f"unlocking failed right after {plural(len(after_unlock), 'resume')} (a mistyped password, or an "
                    "unreachable domain before the network came back)")
    if not (after_gpu or after_crash or failed):
        say("ok", "no graphics errors or Shell crashes followed a resume")


# --- Authorization (polkit) -------------------------------------------------------------------------------------

POLKIT_AGENT = re.compile(r"(Registered|Unregistered) Authentication Agent for unix-session:(\S+)")
POLKIT_OUTCOME = re.compile(r"Operator of unix-session:(\S+) (successfully authenticated|FAILED to authenticate)"
                            r".* for action ([\w.-]+)")
POLKIT_RULE_ERROR = re.compile(r"(Error (?:compiling|evaluating|loading)[^:]*:?.*|.*\b(?:TypeError|ReferenceError|"
                               r"SyntaxError)\b.*)")
ADMIN_IDENTITY = re.compile(r"unix-(group|user):([A-Za-z0-9._@\\-]+)")


def check_polkit(machine):
    """Administrator prompts: the authority, the session's agent, who may authenticate as administrator, the PAM
    path polkit uses, rule errors, and recent outcomes. Nothing is checked by asking polkit for a decision."""
    unit = run(["systemctl", "show", "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", "-p", "NRestarts",
                "-p", "ActiveEnterTimestampMonotonic", "--no-pager", "polkit.service"])
    values = dict(line.split("=", 1) for line in (unit.stdout if unit else "").splitlines() if "=" in line)
    if not unit or values.get("LoadState") in (None, "not-found"):
        return
    section(f"Administrator authorization (polkit, for {machine.user})")
    state, restarts = values.get("ActiveState", "?"), int(values.get("NRestarts") or 0)
    if restarts:
        past, recovered, note = restart_outcome(values, up_since_boot(values, uptime_seconds(machine)))
        say("warning", f"polkit was restarted {plural(restarts, 'time')} this boot{note}", past=past,
            recovered=recovered, next_step="journalctl -b -u polkit.service")
    if state == "active":
        if not restarts:
            say("ok", "polkit is running")
    elif state == "failed":
        say("warning", "polkit has failed: no prompt for administrator actions can appear",
            next_step="systemctl status polkit.service")
    else:
        say("info", f"polkit is {state}; it starts on the first authorization request")
    admins(machine)
    stack = pam_stack(machine, "polkit-1")
    if machine.path("etc/pam.d/polkit-1").exists() or machine.path("usr/lib/pam.d/polkit-1").exists():
        auth = modules(stack, "auth")
        say("info", "polkit authenticates through: " + (", ".join(dict.fromkeys(auth)) or "no auth modules")
            + (" (domain accounts through pam_sss)" if "pam_sss.so" in auth else ""))
        if not auth:
            say("warning", "the polkit-1 PAM service has no auth lines, so no administrator can authenticate",
            next_step="dpkg -S polkit-1 | grep pam.d; dpkg --verify polkitd")
    else:
        say("warning", "no polkit-1 PAM service (/etc/pam.d or /usr/lib/pam.d): polkit falls back to PAM's 'other' "
                       "service, which usually denies", next_step="dpkg --verify polkitd")
    pkla(machine)
    if not machine.sees_system_journal():
        say("unchecked", "polkit agents, rule errors and outcomes: " + machine.journal_hint())
        return
    entries = machine.journal("SYSLOG_IDENTIFIER=polkitd", "+", "_COMM=polkitd") or []
    agents(machine, entries)
    errors = [e for e in entries if POLKIT_RULE_ERROR.search(e["MESSAGE"])]
    if errors:
        incident(f"polkit reported {plural(len(errors), 'rule error')} this boot; a rule that fails to load or "
                       "throws stops applying, and later rules decide instead", next_step="journalctl -b -t polkitd")
        print(f"    e.g. {clean(errors[-1]['MESSAGE'], 160)}")
    outcomes = {}
    for entry in entries:
        matched = POLKIT_OUTCOME.search(entry["MESSAGE"])
        if matched:
            key = ("authorized" if matched.group(2).startswith("success") else "authentication failed", matched.group(3))
            outcomes[key] = outcomes.get(key, 0) + 1
    for (outcome, action), count in sorted(outcomes.items()):
        say("warning" if outcome == "authentication failed" else "info",
            f"{action}: {outcome} {plural(count, 'time')} this boot", past=True,
            next_step="journalctl -b -t polkitd")


def admins(machine):
    """Who polkit asks for when an action needs an administrator, resolved through NSS like polkit does."""
    identities = []
    for directory in ("etc/polkit-1/rules.d", "usr/share/polkit-1/rules.d"):
        for rule in sorted(glob.glob(str(machine.path(directory) / "*.rules"))):
            text = Path(rule).read_text(errors="replace")
            for block in re.findall(r"addAdminRule\s*\(\s*function[^{]*\{(.*?)\}\s*\)", text, re.S):
                identities += [(kind, name, Path(rule).name) for kind, name in ADMIN_IDENTITY.findall(block)]
    if not identities:
        say("info", "no administrator rule found; polkit then asks for root's password")
        return
    gids = set(machine.target["gids"]) if machine.target else set()
    member, offered, unresolved = False, [], []
    for kind, name, rule in dict.fromkeys(identities):
        result = run(["getent", "group" if kind == "group" else "passwd", name])
        if result is None or result.returncode != 0:
            # Ubuntu's default rule names groups that many machines never create; a domain name that does not
            # resolve is the case that loses administrators.
            domain = "@" in name or "\\" in name
            unresolved.append(name)
            say("warning" if domain else "info", f"administrator identity unix-{kind}:{name} (from {rule}) does not "
                "resolve through NSS" + (": nobody can be offered for it; is SSSD offline?" if domain else
                                         "; it offers nobody"), next_step=f"getent {kind} {name}")
            continue
        fields = result.stdout.strip().split(":")
        if kind == "group":
            if len(fields) > 2 and fields[2].isdigit() and int(fields[2]) in gids:
                member = True
            offered += [user for user in (fields[3].split(",") if len(fields) > 3 else []) if user]
        else:
            member = member or name == machine.user
            offered.append(name)
    if len(unresolved) == len(dict.fromkeys(identities)):
        say("warning", "no administrator identity resolves, so administrator prompts cannot be answered",
            next_step="getent group sudo; pkaction --verbose --action-id org.freedesktop.policykit.exec")
    elif member:
        say("ok", f"{machine.user} is an administrator for polkit and authenticates with their own password")
    else:
        say("info", f"{machine.user} is not a polkit administrator; prompts offer "
            + (", ".join(sorted(set(offered))[:5]) if offered else "the members of "
               + ", ".join(f"unix-{kind}:{name}" for kind, name, _ in dict.fromkeys(identities))
               + " (members not listed by NSS, e.g. with ignore_group_members)"))


def pkla(machine):
    files = glob.glob(str(machine.path("etc/polkit-1/localauthority") / "**" / "*.pkla"), recursive=True)
    files += glob.glob(str(machine.path("var/lib/polkit-1/localauthority") / "**" / "*.pkla"), recursive=True)
    if not files:
        return
    if machine.path("var/lib/dpkg/info/polkitd-pkla.list").exists():
        say("info", f"{plural(len(files), 'legacy .pkla file')} applied through polkitd-pkla")
    else:
        say("warning", f"{plural(len(files), 'legacy .pkla file')} (e.g. {Path(files[0]).name}) without polkitd-pkla "
                       "installed: polkit reads only JavaScript rules, so these are ignored",
                           next_step="apt policy polkitd-pkla")


def agents(machine, entries):
    """Per session of the account: the last agent event. A session without one is unknown, not agent-less:
    registrations are not always logged."""
    user = run(["loginctl", "show-user", str(machine.uid), "-p", "Sessions"])
    sessions = user.stdout.partition("=")[2].split() if user and user.returncode == 0 else []
    if not sessions:
        say("info", f"{machine.user} has no session, so no authentication agent applies")
        return
    last = {}
    for entry in entries:
        matched = POLKIT_AGENT.search(entry["MESSAGE"])
        if matched:
            last.setdefault(matched.group(2), []).append((matched.group(1), entry))
    for session in sessions:
        events = last.get(session, [])
        if not events:
            say("info", f"session {session}: no authentication agent event logged; whether prompts can appear "
                        "there is unknown")
        elif events[-1][0] == "Unregistered":
            say("warning", f"session {session}: its authentication agent unregistered at {when(events[-1][1])} and did "
                           "not register again; administrator prompts cannot appear there (the Shell provides the "
                           "agent; logging out and in restores it)", next_step="journalctl -b -t polkitd")
        else:
            recovered = any(kind == "Unregistered" for kind, _ in events)
            say("ok", f"session {session}: an authentication agent is registered"
                + (" (it re-registered after going away)" if recovered else ""))


# --- File indexing ----------------------------------------------------------------------------------------------

# (name, miner program, its user unit, bus name, process name prefixes, command to rebuild the index)
INDEXERS = (("LocalSearch", "/usr/libexec/localsearch-3", "localsearch-3.service", "org.freedesktop.LocalSearch3",
             ("localsearch",), "localsearch reset"),
            ("Tracker 3", "/usr/libexec/tracker-miner-fs-3", "tracker-miner-fs-3.service",
             "org.freedesktop.Tracker3.Miner.Files", ("tracker-miner-f", "tracker-extract", "tracker3"),
             "tracker3 reset --filesystem"))
INDEX_SCHEMA = "org.freedesktop.Tracker3.Miner.Files"
MINER_PATH = "/org/freedesktop/Tracker3/Miner/Files"
MINER_INTERFACE = "org.freedesktop.Tracker3.Miner"
# Message kinds are counted, never quoted: the indexer's messages name the files it was working on.
INDEX_RULES = (
    ("database", "warning", "database errors",
     r"(?i)database disk image is malformed|SQLITE_CORRUPT|\bcorrupt|unable to open database|database is locked|"
     r"could not (?:open|create) (?:the )?database",
     "the index database is damaged or unusable, so search misses files; rebuilding it removes only the index: "
     "{reset}"),
    ("watches", "warning", "out of inotify watches",
     r"(?i)inotify (?:watch )?limit|upper limit on inotify watches|max_user_watches|too many open files|"
     r"could not (?:add|set up) (?:a )?monitor",
     "changes in some folders go unnoticed until the next crawl; raise fs.inotify.max_user_watches (sysctl) or "
     "exclude large folders"),
    ("timeout", "warning", "extraction timeouts",
     r"(?i)(?:extract\w*|metadata)\b.*(?:timed? ?out|timeout)|Timeout was reached",
     "those files are indexed by name only"),
    ("crash", "warning", "extractor crashes",
     r"(?i)extract\w*\b.*(?:crash|died|killed|exited|terminated)|Disallowed syscall",
     "the indexer skips a file that crashed the extractor, so repeated crashes mean many such files or a broken "
     "extractor module; see: journalctl --user -b -u {unit}"),
    ("space", "info", "paused for low disk space",
     r"(?i)low disk space|No space left on device",
     "indexing pauses deliberately when the disk is nearly full"),
)
INDEX_PATTERNS = tuple((key, level, title, re.compile(pattern), advice)
                       for key, level, title, pattern, advice in INDEX_RULES)
BUSY_HOURS = 6
# Location tokens printed as they are; any other value is a folder name and only counted.
INDEX_ALIASES = ("$HOME", "&DESKTOP", "&DOCUMENTS", "&DOWNLOAD", "&MUSIC", "&PICTURES", "&PUBLIC_SHARE",
                 "&TEMPLATES", "&VIDEOS")


def check_indexing(machine):
    """The account's file indexer, discovered from what is installed: its settings, whether it runs, what it is
    doing (asked over D-Bus only when it is already running, never started), what it logged, and whether its
    database and the kernel's watch limit let it work. File names never appear: only counts and folder aliases."""
    found = next((entry for entry in INDEXERS if executable(machine, entry[1])), None)
    if not found or not machine.target:
        return
    name, _, unit, bus_name, programs, reset = found
    section(f"File indexing ({name}, for {machine.user})")
    settings = gsettings(machine, INDEX_SCHEMA)
    if index_settings(settings):
        return
    flags = machine.user_flags() if machine.reach else None
    if not flags:
        say("unchecked", f"indexer of {machine.user}: their user manager needs --sudo")
    else:
        units = show_units(flags, [unit], ["Id", "LoadState", "UnitFileState", "ActiveState", "SubState", "Result",
                                           "NRestarts", "ActiveEnterTimestamp"], "indexer")
        if units and miner_unit(unit, units[unit]):
            started = units[unit].get("ActiveEnterTimestamp", "").lstrip("@")
            miner_status(flags, bus_name, int(started) if started.isdigit() else None)
    index_log(machine, unit, programs, reset)
    index_cache(machine, settings or {})
    watches(machine)


def index_settings(settings):
    """Report what the indexer is set to cover; True when it is set to cover nothing, a deliberate choice."""
    if settings is None:
        say("unchecked", f"indexing settings: gsettings could not read {INDEX_SCHEMA}")
        return False
    recursive = [path for path in settings.get("index-recursive-directories") or [] if isinstance(path, str)]
    single = [path for path in settings.get("index-single-directories") or [] if isinstance(path, str)]
    if not recursive and not single:
        say("info", "no folders are set to be indexed: indexing is turned off deliberately, not a fault")
        return True

    def describe(paths):
        aliases = [path for path in paths if path in INDEX_ALIASES]
        others = len(paths) - len(aliases)
        return ", ".join(aliases + ([plural(others, "other folder")] if others else []))
    say("info", f"indexes {describe(recursive) or 'no folder'} with subfolders"
        + (f", and {describe(single)} without" if single else ""))
    ignored, files = settings.get("ignored-directories") or [], settings.get("ignored-files") or []
    say("info", f"exclusions: {plural(len(ignored), 'folder pattern')}, {plural(len(files), 'file pattern')}")
    if settings.get("enable-monitors") is False:
        say("info", "watching for changes is off (enable-monitors): new files are found only by the next crawl")
    if settings.get("crawling-interval") == -2:
        say("info", "crawling is off (crawling-interval -2): only changes seen while running are indexed")
    return False


def miner_unit(unit, props):
    """The indexer's unit state; True when it is running."""
    state, restarts = props.get("ActiveState", ""), int(props.get("NRestarts") or 0)
    hint = f"see: systemctl --user status {unit}"
    if "masked" in (props.get("LoadState"), props.get("UnitFileState")):
        say("info", f"{unit} is masked: indexing is disabled deliberately; search finds only what was indexed before")
    elif props.get("LoadState") in (None, "", "not-found"):
        say("warning", f"{unit} is not known to the user manager although the indexer is installed; {hint}")
    elif state == "failed":
        reason = RESULTS.get(props.get("Result", ""), props.get("Result") or "unknown reason")
        say("warning", f"{unit} has failed ({reason}): new and changed files do not appear in search; {hint}")
    elif restarts >= 3:
        started = props.get("ActiveEnterTimestamp", "").lstrip("@")
        up_for = time.time() - int(started) if started.isdigit() and int(started) else None
        past, recovered, note = restart_outcome(props, up_for)
        say("warning", f"{unit} restarted {plural(restarts, 'time')} this boot: it crashed repeatedly{note}; {hint}",
            past=past, recovered=recovered)
        return props.get("ActiveState") == "active"
    elif running(props):
        return True
    else:
        say("info", f"{unit} is {state or 'not running'}; it starts with the desktop session")
    return False


def miner_status(flags, bus_name, started):
    """Status, progress and pauses from the running miner. One look cannot tell a slow indexer from a stuck
    one, so a long busy spell is reported with how to compare over time, not as a fault."""
    call = ["busctl"] + flags + ["--no-pager", "--auto-start=no", "call", bus_name, MINER_PATH, MINER_INTERFACE]
    status = run(call + ["GetStatus"], timeout=10)
    if status is None:
        say("unchecked", "indexer status: busctl is not installed")
        return
    if status.returncode != 0:
        say("info", f"indexer status: not available over D-Bus ({failure('busctl', status)})")
        return
    quoted = re.search(r'"(.*)"', status.stdout)
    text = quoted.group(1) if quoted else status.stdout.strip()
    progress = run(call + ["GetProgress"], timeout=10)
    value = None
    if progress and progress.returncode == 0 and len(progress.stdout.split()) == 2:
        try:
            value = float(progress.stdout.split()[1])
        except ValueError:
            value = None
    pause = run(call + ["GetPauseDetails"], timeout=10)
    reasons = re.findall(r'"([^"]*)"', pause.stdout) if pause and pause.returncode == 0 else []
    if reasons:
        half = len(reasons) // 2
        say("info", f"indexing is paused by {', '.join(reasons[:half])} ({'; '.join(reasons[half:])}); a pause is "
                    "deliberate, not a fault")
    elif text.lower() == "idle" or (value is not None and value >= 1):
        say("ok", "the indexer is running and idle: everything set to be indexed is indexed")
    else:
        busy = time.time() - started if started else 0
        say("info", f"the indexer is busy: {text}" + (f", {value:.0%} done" if value is not None else "")
            + (f", {busy / 3600:.0f} h after it started; one look cannot tell slow from stuck: run this again later "
               "and compare the progress" if busy > BUSY_HOURS * 3600 else ""))


def index_log(machine, unit, programs, reset):
    """What the indexer and its extractor logged this boot, by kind, with crashes from coredumps."""
    if not machine.reach:
        say("unchecked", f"indexer log of {machine.user}: needs --sudo")
        return
    mine = [e for e in machine.user_log() if e.get("_SYSTEMD_USER_UNIT") == unit
            or (e.get("SYSLOG_IDENTIFIER") or e.get("_COMM") or "").startswith(programs)]
    counts = {}
    for entry in mine:
        for key, _, _, pattern, _ in INDEX_PATTERNS:
            if pattern.search(entry["MESSAGE"]):
                counts[key] = counts.get(key, 0) + 1
                break
    uid = str(machine.uid)
    dumps = [e for e in machine.journal("MESSAGE_ID=" + COREDUMP) or []
             if e.get("COREDUMP_UID") == uid and (e.get("COREDUMP_COMM") or "").startswith(programs)]
    if dumps:
        counts["crash"] = counts.get("crash", 0) + len(dumps)
    for key, level, title, _, advice in INDEX_PATTERNS:
        if counts.get(key):
            say(level, f"indexer: {title} ({counts[key]} this boot); " + advice.format(unit=unit, reset=reset),
                past=True, next_step=f"journalctl --user -b -u {unit}")
    if not counts:
        say("ok", "the indexer logged no database, watch, timeout or crash problems this boot")


def index_cache(machine, settings):
    """The index database: present, owned and writable by the account, and the free space the indexer needs."""
    environment = proxy_values_env(machine) if machine.reach else {}
    cache = (environment.get("XDG_CACHE_HOME") or f"{machine.target['home'].rstrip('/')}/.cache").rstrip("/")
    shown = f"{cache}/tracker3/files"
    path = machine.path(shown.lstrip("/"))
    try:
        st = path.stat()
    except OSError:
        say("info", f"no index database yet at {shown}; it is created when the indexer first runs")
        return
    if st.st_uid != machine.uid:
        say("warning", f"{shown} is owned by {owner_label(st.st_uid)}, not {machine.user}: the indexer cannot update "
                       f"its database ; run: sudo chown -R {machine.user} {cache}/tracker3")
        return
    blocked = inspector.access_check(machine.root, path, st, identity(machine), 7)
    if blocked and blocked[0] == "warning":
        say("warning", f"{machine.user} cannot write {shown}: the indexer cannot update its database",
            next_step=f"ls -ld {shown}")
        return
    size = sum(entry.stat().st_size for entry in path.glob("meta.db*") if entry.is_file())
    say("info", f"index database: {size / 2 ** 20:.0f} MiB in {shown}")
    limit = settings.get("low-disk-space-limit")
    if isinstance(limit, int) and not isinstance(limit, bool) and limit >= 0:
        try:
            fs = os.statvfs(path)
        except OSError:
            return
        free = fs.f_bavail * 100 / fs.f_blocks if fs.f_blocks else 100
        if free < limit:
            say("info", f"the indexer pauses below {limit}% free space and {shown} has {free:.1f}% free, so indexing "
                        "is paused deliberately until space is freed")


def watches(machine):
    """inotify watches held by the account's processes against the per-user limit; the indexer and editors stop
    seeing changes when it runs out."""
    maximum = (machine.read("proc/sys/fs/inotify/max_user_watches") or "").strip()
    if not maximum.isdigit() or not machine.reach:
        return
    # A descriptor duplicated or inherited across fork shows the same instance's watches again, and nothing here
    # tells shared instances apart, so the total is an upper bound; the largest single instance is a sure minimum.
    used, largest = 0, 0
    for status in machine.path("proc").glob("[0-9]*/status"):
        try:
            matched = re.search(r"^Uid:\s+(\d+)", status.read_text(errors="replace"), re.M)
            if not matched or int(matched.group(1)) != machine.uid:
                continue
            for fd in (status.parent / "fd").iterdir():
                if os.readlink(fd) == "anon_inode:inotify":
                    info = (status.parent / "fdinfo" / fd.name).read_text(errors="replace")
                    count = sum(1 for line in info.splitlines() if line.startswith("inotify wd:"))
                    used, largest = used + count, max(largest, count)
        except OSError:
            continue
    limit = int(maximum)
    span = f"{largest} of {limit}" if used == largest else f"between {largest} and {used} of {limit}"
    if largest >= limit * 0.9:
        say("warning", f"{machine.user}'s programs hold at least {largest} of {limit} inotify watches: the indexer and "
                       "editors stop seeing changes; raise fs.inotify.max_user_watches (sysctl) or close what watches "
                       "most", next_step="inotify-info (apt install inotify-info)")
    elif used >= limit * 0.9:
        say("info", f"inotify watches of {machine.user}'s programs: {span} (descriptors shared between processes "
                    "count once per process), so they may be near the limit; see whether changes go unnoticed")
    else:
        say("info", f"inotify watches: {span} in use by {machine.user}'s programs")


# --- Packages and security --------------------------------------------------------------------------------------

def check_packages(machine):
    section("Packages and security")
    audit = run(["dpkg", "--audit"])
    if broken("package consistency", "dpkg --audit", audit):
        if audit.stdout.strip():
            names = [line.split()[0] for line in audit.stdout.splitlines() if line[:1].isspace() and line.split()]
            say("warning", "dpkg reports half-installed or unconfigured packages"
                + (f" ({', '.join(names[:8])})" if names else "") + "; run: sudo dpkg --configure -a")
        else:
            say("ok", "no half-installed packages")
    updates = run([str(machine.path("usr/lib/update-notifier/apt-check"))])
    if broken("pending updates", "apt-check", updates):
        matched = re.search(r"(\d+);(\d+)", updates.stderr + updates.stdout)
        if not matched:
            say("failed", "pending updates: apt-check printed no update counts")
        else:
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
        say("warning", "AppArmor is disabled; Ubuntu snaps and confined services rely on it",
            next_step="sudo aa-status; cat /proc/cmdline")
    check_readiness(machine)
    check_history(machine)
    if not machine.privileged:
        say("unchecked", "AppArmor profiles, firewall, and unattended-upgrades log need root; run: "
                         "dotconfig machine status --sudo")
        return
    profiles = run(["aa-status"])
    # aa-status exits 1 when AppArmor is off and 2 when no policy is loaded; both are reported above or below.
    if broken("AppArmor profiles", "aa-status", profiles, ok=(0, 1, 2)) and profiles.returncode == 0:
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
    if broken("firewall", "ufw status", firewall):
        say("info", "firewall (ufw): " + firewall.stdout.strip().splitlines()[0].partition(":")[2].strip())
    log = machine.read("var/log/unattended-upgrades/unattended-upgrades.log")
    if log is not None:
        problems = [line for line in log.splitlines() if re.search(r"\b(ERROR|WARNING)\b", line)]
        if problems:
            incident(f"unattended-upgrades logged {plural(len(problems), 'error or warning')} since its log "
                           "was rotated; see: /var/log/unattended-upgrades/unattended-upgrades.log")
            print(f"    e.g. {clean(problems[-1], 160)}")
        else:
            say("ok", "unattended-upgrades logged no errors since its log was rotated")


def check_readiness(machine):
    """Whether updates still arrive and the next boot has what it needs; package consistency alone shows neither."""
    now = time.time()
    uptime = (machine.read("proc/uptime") or "").split()
    # The daily jobs run within hours of boot, so a machine just back from days powered off is stale but fine.
    settled = not uptime or float(uptime[0]) >= 86400
    # apt.systemd.daily touches update-stamp when it tries a refresh and update-success-stamp when it succeeds.
    # The lists' own file times are the servers' publication dates, so they say nothing about refreshes.
    attempted, succeeded = (stamp_age(machine, f"var/lib/apt/periodic/{name}", now)
                            for name in ("update-stamp", "update-success-stamp"))
    if succeeded is not None and succeeded >= 7:
        text = f"APT last refreshed its package lists successfully {succeeded:.0f} days ago"
        if attempted is not None and attempted < succeeded - 1:
            say("warning", f"{text} but tried {attempted:.0f} days ago: refreshes are failing "
                           "(see: systemctl status apt-daily.service)")
        elif settled:
            say("warning", f"{text}; refreshes are failing or disabled (see: systemctl status apt-daily.timer)")
        else:
            say("info", f"{text}; the daily refresh runs within hours of boot")
    elif succeeded is None and attempted is not None:
        say("info", "APT has no record of a successful automatic refresh")
    for path in sorted(glob.glob(str(machine.path("var/lib/apt/lists/*InRelease")))):
        repository_dates(path, now)
    refresh = [e for e in machine.journal("_SYSTEMD_UNIT=apt-daily.service", "-p", "0..4") or []
               if re.search(r"Failed to fetch|Some index files failed|Temporary failure resolving|"
                            r"Could not (connect|resolve)|NO_PUBKEY|is not signed", e["MESSAGE"])]
    if refresh:
        incident(f"the daily APT refresh failed to fetch {plural(len(refresh), 'time')} this boot",
            next_step="journalctl -b -u apt-daily.service")
        print(f"    e.g. {clean(refresh[-1]['MESSAGE'], 160)}")
    periodic = machine.read("etc/apt/apt.conf.d/20auto-upgrades") or ""
    stamp = machine.path("var/lib/apt/periodic/unattended-upgrades-stamp")
    if re.search(r'Unattended-Upgrade\s+"0"', periodic):
        say("info", "unattended upgrades are disabled (/etc/apt/apt.conf.d/20auto-upgrades)")
    elif stamp.exists() and (now - stamp.stat().st_mtime) / 86400 >= 3:
        say("warning" if settled else "info",
            f"unattended upgrades last ran {(now - stamp.stat().st_mtime) / 86400:.0f} days ago; "
            + ("security updates are not being applied (see: systemctl status apt-daily-upgrade.timer)" if settled
               else "they run within hours of boot"))
    kernels = sorted(Path(path).name[len("vmlinuz-"):] for path in glob.glob(str(machine.path("boot/vmlinuz-*"))))
    dkms = run(["dkms", "status"])
    if kernels and broken("DKMS modules", "dkms status", dkms):
        built = {}
        for line in dkms.stdout.splitlines():
            matched = re.match(r"^([^,/\s]+)[/,]\s*([^,\s]+)(?:,\s*([^,\s]+))?.*:\s*(\S+)", line.strip())
            if matched:
                name, kernel, state = matched.group(1), matched.group(3), matched.group(4)
                built.setdefault(name, {})
                if kernel:
                    built[name][kernel] = state
        for name, states in sorted(built.items()):
            missing = [kernel for kernel in kernels if states.get(kernel) != "installed"]
            if missing:
                say("warning", f"DKMS module {name} is not installed for kernel {', '.join(missing)}; that kernel "
                               f"boots without it (see: dkms status, sudo dkms autoinstall -k {missing[-1]})")
    if "/boot" in machine.free_kib and kernels:
        need = (largest(machine, "boot/vmlinuz-*") + largest(machine, "boot/initrd.img-*")) // 1024
        if need and machine.free_kib["/boot"] < need * 1.2:
            say("warning", f"/boot has {machine.free_kib['/boot'] // 1024} MiB free but a kernel and its initrd "
                           f"take about {need // 1024} MiB; the next kernel update may fail"
                           "; run: sudo apt autoremove --purge, which removes old kernels",
                               next_step="dpkg -l 'linux-image-*'")


def stamp_age(machine, relative, now):
    path = machine.path(relative)
    return (now - path.stat().st_mtime) / 86400 if path.exists() else None


def repository_dates(path, now):
    """Each repository on its own: an expired Valid-Until makes APT refuse it, and a long-unchanged Date means
    the source or mirror stopped publishing (or the repository is simply frozen)."""
    try:
        header = Path(path).read_text(errors="replace").split("\n\n", 1)[0]
    except OSError:
        return
    name = Path(path).name.replace("_InRelease", "").replace("_", "/")
    fields = dict(re.findall(r"^(Date|Valid-Until): (.+)$", header, re.M))
    dates = {}
    for key, value in fields.items():
        try:
            dates[key] = email.utils.parsedate_to_datetime(value.strip()).timestamp()
        except (TypeError, ValueError):
            continue
    if dates.get("Valid-Until") and dates["Valid-Until"] < now:
        say("warning", f"repository {name}: metadata expired {(now - dates['Valid-Until']) / 86400:.0f} days ago "
                       "(Valid-Until); APT refuses it until a refresh succeeds", next_step="sudo apt update")
    elif dates.get("Date") and (now - dates["Date"]) / 86400 >= 30:
        say("info", f"repository {name}: last published {(now - dates['Date']) / 86400:.0f} days ago (a frozen "
                    "repository, or a source or mirror that stopped updating)")


def largest(machine, pattern):
    sizes = [os.path.getsize(path) for path in glob.glob(str(machine.path(pattern)))]
    return max(sizes) if sizes else 0


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
    if changes is None or "no changes found" in changes.stderr + changes.stdout:
        return
    if not broken("snap changes", "snap changes", changes):
        return
    lines = changes.stdout.splitlines()
    summary = lines[0].find("Summary") if lines else -1
    errors = [line[summary:] if summary > 0 else line for line in lines[1:]
              if len(line.split()) > 1 and line.split()[1] in ("Error", "Undone")]
    if errors:
        incident(f"{plural(len(errors), 'snap change')} failed recently; see: snap changes")
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
        say(level, text, next_step=f"upower -i $(upower -e | grep {Path(battery).name})")
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
        say("warning", "running hot: " + ", ".join(hot), next_step="sensors")
    elif glob.glob(str(machine.path("sys/class/thermal/thermal_zone*"))):
        say("ok", "all thermal zones below 90 °C")
        printed = True
    if not printed and not hot:
        say("info", "no battery or thermal sensors found")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--boot", type=int, default=0, help="journal boot offset: 0 this boot, -1 the one before")
    parser.add_argument("--examples", type=int, default=1, help="log lines to quote per finding")
    parser.add_argument("--user", help="account whose installation, session and environment are inspected")
    parser.add_argument("--probe", action="append", default=[], metavar="HOST[:PORT]",
                        help="also test DNS, connection, proxy and TLS to this endpoint (bounded, verification kept)")
    parser.add_argument("--probe-domain", action="store_true",
                        help="also look up the DNS records clients use to find the domain controllers")
    parser.add_argument("root", nargs="?", default="/")
    args = parser.parse_args()
    machine = Machine(args.root, args.boot, args.user)
    if args.boot != 0:
        print(f"Journal sections read boot {args.boot}; disk, memory, network, and unit state are current.")
    check_system(machine)
    check_account(machine)
    check_timing(machine)
    check_services(machine)
    check_expected(machine)
    check_journal(machine, args.examples)
    check_kernel(machine, args.examples)
    check_storage(machine)
    check_memory(machine)
    check_load(machine)
    check_network(machine)
    check_domain_login(machine, args.probe_domain)
    check_desktop(machine)
    check_polkit(machine)
    check_indexing(machine)
    check_proxy(machine, args.probe)
    check_installation(machine)
    check_packages(machine)
    check_hardware(machine)
    digest()
    text, status = summary(COUNTS)
    print(f"\nSummary: {text}")
    return status


def digest():
    """Current problems again, together, then where the earlier incidents are: the report above is long, and
    what still holds is what to act on first."""
    current = [(where, message) for level, where, message in FINDINGS if level == "warning"]
    earlier = {}
    for level, where, _ in FINDINGS:
        if level in ("earlier", "recovered"):
            earlier[where] = earlier.get(where, 0) + 1
    if current:
        section("Needs attention now")
        for where, message in current:
            print(f"  - {where}: {clean(message, 160)}")
    if earlier:
        print("\nEarlier incidents (lines marked earlier or recovered above): "
              + ", ".join(f"{count} in {where}" for where, count in earlier.items()))


def summary(counts):
    """The verdict and exit status: 1 problems found, 3 assessment incomplete (a diagnostic failed) without
    problems, 0 healthy within the checked scope. Not checked items are expected limits, not failures."""
    warnings, earlier, recovered, failed, unchecked = (counts.get(level, 0) for level in
                                                       ("warning", "earlier", "recovered", "failed", "unchecked"))
    incomplete = f"assessment incomplete: {plural(failed, 'check')} failed" if failed else ""
    limits = f"{unchecked} not checked (need --sudo, or not applicable)" if unchecked else ""
    history = ", ".join(part for part in (f"{earlier} earlier not seen to recover" if earlier else "",
                                          f"{recovered} earlier and recovered" if recovered else "") if part)
    if warnings or earlier:
        found = ", ".join(part for part in (f"{warnings} current" if warnings else "", history) if part)
        return "; ".join(part for part in (f"problems found: {found}", incomplete, limits) if part), 1
    if failed:
        return "; ".join(part for part in (incomplete, "no problems found in what was checked", history, limits)
                         if part), 3
    return "; ".join(part for part in ("healthy within the checked scope", history, limits) if part), 0


if __name__ == "__main__":
    raise SystemExit(main())
