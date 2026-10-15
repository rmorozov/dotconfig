#!/usr/bin/env python3
"""Search SSSD, PAM, Kerberos, and VPN logs for reasons a domain login fails, and judge what was found."""

import argparse
import configparser
import contextlib
import datetime
import gzip
import importlib.util
import io
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

_spec = importlib.util.spec_from_file_location("credentials_inspect", Path(__file__).with_name("credentials-inspect.py"))
inspector = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(inspector)
say = inspector.say

LEVELS = ("warning", "info", "ok")
# Kerberos and SSSD never log passwords, but a debug line may quote a config value; examples hide these.
PRIVATE_VALUE = re.compile(r"(\b\w*(?:authtok|password|passwd|secret)\w*\s*=\s*)\S+", re.I)


@dataclass
class Rule:
    level: str
    title: str
    meaning: str
    pattern: str = ""


RULES = {
    "pam-offline-failure": Rule(
        "warning", "Domain login failed: no domain controller and no usable cached password",
        "the offline-login failure itself; SSSD was offline and had no stored password to check against"),
    "no-cached-password": Rule(
        "warning", "SSSD had no cached password for an offline login",
        "a password is stored only when cache_credentials is on and pam_sss sees the password at an online login",
        r"cached credentials? (are |is )?not available|no cached (credentials|password)|"
        r"password (caching|cache) (is )?(not enabled|disabled)|cached password.*not (found|available|stored)"),
    "cache-too-old": Rule(
        "warning", "Cached password expired",
        "offline_credentials_expiration passed since the last online login; log in once with the VPN up",
        r"cached user entry is too old|cached credentials? (have )?expired"),
    "lockout": Rule(
        "warning", "Offline login delayed after failed attempts",
        "offline_failed_login_attempts was reached; wait offline_failed_login_delay minutes or log in online",
        r"too many failed logins"),
    "pam-user-unknown": Rule(
        "warning", "SSSD did not know the user at login",
        "offline, SSSD knows only cached users; also check the name typed (alice or alice@corp.example) "
        "matches use_fully_qualified_names"),
    "pam-denied": Rule(
        "warning", "SSSD refused an account after checking it",
        "an access rule (access_provider, GPO, simple_allow_users) denied the login, not the password"),
    "pam-system-error": Rule(
        "warning", "SSSD reported a system error to PAM",
        "SSSD failed internally while checking a password; the SSSD lines around the same time give the cause"),
    "account-expired": Rule("warning", "Domain account expired", "the domain administrators must extend it"),
    "password-expired": Rule(
        "warning", "Domain password expired", "change the password while connected to the VPN",
        r"password (has )?expired|KRB5KDC_ERR_KEY_EXP"),
    "pam-other": Rule("info", "pam_sss returned another PAM error", "the PAM error text on the example names it"),
    "pam-bad-password": Rule(
        "info", "SSSD rejected a password",
        "a mistyped password, or one changed at the domain since it was cached; the cache keeps the old one "
        "until the next online login"),
    "sssd-down": Rule(
        "warning", "pam_sss could not reach SSSD",
        "sssd was not running at login time; check systemctl status sssd",
        r"pam_sss\([^)]*\):.*(connection refused|request to sssd failed)"),
    "sssd-crash": Rule(
        "warning", "SSSD crashed, hung, or was restarted",
        "a restarting SSSD can lose its online state or miss a login; the lines just before give the cause, "
        "often DNS timeouts",
        r"terminated by own watchdog|could not restart critical service|killing service|exiting the sssd|"
        r"sssd\S*\.service: (main process exited|failed with result)|segmentation fault|core dumped"),
    "config-error": Rule(
        "warning", "SSSD rejected part of its configuration", "run sudo sssctl config-check",
        r"file ownership and permissions check failed|cannot read config|failed to (read|load|parse) .*config|"
        r"is not allowed in section|unknown option|invalid (option|section)|confdb_init.*fail"),
    "clock-skew": Rule(
        "warning", "Kerberos clock skew",
        "the clock differs from the domain by more than 5 minutes; Kerberos refuses tickets until time syncs",
        r"clock skew too great|KRB5KRB_AP_ERR_SKEW"),
    "principal-unknown": Rule(
        "warning", "Kerberos did not know the user",
        "the principal SSSD built does not exist; check the realm and name case",
        r"not found in kerberos database|KRB5KDC_ERR_C_PRINCIPAL_UNKNOWN"),
    "keytab": Rule(
        "warning", "Machine keytab problem",
        "SSSD authenticates the machine with /etc/krb5.keytab before it can go online; rejoin the domain if broken",
        r"key table entry not found|keytab contains no suitable keys|failed to initiali[sz]e credentials using keytab"),
    "gpo": Rule(
        "warning", "GPO access control failed",
        "with ad_gpo_access_control = enforcing, an offline login also needs cached GPO rules",
        r"gpo-based access control failed|ad_gpo_access\S*.*(denied|fail)"),
    "krb5-bad-password": Rule(
        "info", "Kerberos rejected a password", "a mistyped password, or one changed at the domain",
        r"pre-?authentication failed|decrypt integrity check failed|KRB5KDC_ERR_PREAUTH_FAILED"),
    "kdc-unreachable": Rule(
        "info", "Kerberos could not reach a KDC",
        "expected while the VPN is down; a problem only if it continues after the VPN connects",
        r"cannot contact any kdc|cannot find kdc|unable to reach any kdc|KRB5_KDC_UNREACH"),
    "dc-unreachable": Rule(
        "info", "SSSD could not reach a domain controller",
        "expected while the VPN is down; SSSD then answers from its cache",
        r"could not resolve|failed to resolve server|unable to resolve|srv lookup.*(fail|timeout)|"
        r"no (available )?servers? (available|found)|going offline|backend is offline|marked (as )?offline"),
    "krb5-login": Rule(
        "info", "pam_krb5 accepted domain passwords",
        "pam_krb5 checked these passwords itself; if its success skips pam_sss, SSSD never sees the password",
        r"pam_krb5\([^)]*\): authentication succeeds"),
    "krb5-pam-failure": Rule(
        "info", "pam_krb5 rejected a login", "usually the KDC being unreachable before the VPN is up",
        r"pam_krb5\([^)]*\): authentication failure"),
    "vpn-up": Rule(
        "info", "VPN connected", "the domain controller should be reachable after this",
        r"connected as \S+, using|cstp connected|established dtls connection|vpn plugin: state changed: started|"
        r"vpn connection.*(activated|ip config get\) complete)"),
    "vpn-down": Rule(
        "info", "VPN disconnected", "SSSD should fall back to its cache after this",
        r"vpn plugin: state changed: stopped|vpn connection.*(disconnected|deactivat)|logout successful|"
        r"session terminated by server"),
    "sssd-online": Rule(
        "ok", "SSSD went online", "SSSD reached a domain controller",
        r"going online|backend is online|back online|reset(ting)? offline status|switch(ed|ing)? to online"),
    "sss-login": Rule(
        "ok", "SSSD accepted domain logins",
        "pam_sss saw these passwords, so SSSD can cache them when cache_credentials is on",
        r"pam_sss\([^)]*\): authentication success"),
    "cached-login": Rule(
        "ok", "Logins succeeded from cached credentials", "offline login worked for these attempts",
        r"authenticated with cached credentials|offline authentication succeeded"),
}
COMPILED = {key: re.compile(rule.pattern, re.I) for key, rule in RULES.items() if rule.pattern}
PAM_RESULT = re.compile(r"pam_sss\([^)]*\): received for user (\S+): (\d+) \(([^)]*)\)")
PAM_CODES = {4: "pam-system-error", 6: "pam-denied", 7: "pam-bad-password", 9: "pam-offline-failure",
             10: "pam-user-unknown", 12: "password-expired", 13: "account-expired"}
OFFLINE_FAILURES = ("pam-offline-failure", "no-cached-password", "pam-user-unknown")
UNREACHABLE = ("kdc-unreachable", "dc-unreachable")
VPN_SOURCE = re.compile(r"vpn|openconnect", re.I)


@dataclass
class Event:
    when: datetime.datetime
    source: str
    text: str
    keys: set = field(default_factory=set)


def classify(event):
    result = PAM_RESULT.search(event.text)
    if result:
        event.keys.add(PAM_CODES.get(int(result.group(2)), "pam-other"))
    for key, pattern in COMPILED.items():
        if pattern.search(event.text):
            event.keys.add(key)
    return event


# --- Collection -----------------------------------------------------------------------------------------------

JOURNAL_SELECTORS = (
    ["-u", "sssd*"],
    ["SYSLOG_FACILITY=4", "SYSLOG_FACILITY=10"],
    ["SYSLOG_IDENTIFIER=openconnect", "SYSLOG_IDENTIFIER=nm-openconnect-service", "SYSLOG_IDENTIFIER=NetworkManager",
     "+", "_COMM=openconnect"],
)


def journal_text(value):
    if isinstance(value, list):
        return bytes(value).decode(errors="replace")
    return str(value or "")


def read_journal(root, since):
    """Return the journal events and boot list, or None when journalctl is unavailable."""
    journalctl = shutil.which("journalctl")
    if not journalctl:
        return None
    base = [journalctl, "--no-pager"] + ([] if root == Path("/") else [f"--root={root}"])
    events, seen = [], set()
    auth_entries = 0
    for selector in JOURNAL_SELECTORS:
        command = base + ["-o", "json", "--since", since.strftime("%Y-%m-%d %H:%M:%S")] + selector
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        for line in result.stdout.splitlines():
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            cursor = entry.get("__CURSOR")
            if cursor in seen:
                continue
            seen.add(cursor)
            source = journal_text(entry.get("SYSLOG_IDENTIFIER") or entry.get("_COMM") or entry.get("_SYSTEMD_UNIT"))
            text = journal_text(entry.get("MESSAGE"))
            if source == "NetworkManager" and not VPN_SOURCE.search(text):
                continue
            if entry.get("SYSLOG_FACILITY") in ("4", "10"):
                auth_entries += 1
            when = datetime.datetime.fromtimestamp(int(entry.get("__REALTIME_TIMESTAMP", 0)) / 1e6)
            events.append(Event(when, source, text))
    boots = []
    result = subprocess.run(base + ["--list-boots", "-o", "json"], capture_output=True, text=True, check=False)
    try:
        for boot in json.loads(result.stdout or "[]"):
            boots.append(datetime.datetime.fromtimestamp(int(boot["first_entry"]) / 1e6))
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        boots = []
    return events, sorted(boots), auth_entries


def open_log(path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", errors="replace")
    return path.open(errors="replace")


SSSD_STAMP = re.compile(r"^\((\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2}:\d{2})(?:[:.]\d+)?\):?\s*(.*)")
SSSD_OLD_STAMP = re.compile(r"^\(\w{3} (\w{3} +\d+ \d{2}:\d{2}:\d{2}) (\d{4})\)\s*(.*)")
SYSLOG_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\S*\s+\S+\s+([^:\[]+)(?:\[\d+\])?:\s*(.*)")
SYSLOG_OLD = re.compile(r"^(\w{3} +\d+ \d{2}:\d{2}:\d{2})\s+\S+\s+([^:\[]+)(?:\[\d+\])?:\s*(.*)")


def parse_sssd_line(line):
    match = SSSD_STAMP.match(line)
    if match:
        return datetime.datetime.strptime(f"{match.group(1)} {match.group(2)}", "%Y-%m-%d %H:%M:%S"), match.group(3)
    match = SSSD_OLD_STAMP.match(line)
    if match:
        return datetime.datetime.strptime(f"{match.group(1)} {match.group(2)}", "%b %d %H:%M:%S %Y"), match.group(3)
    return None, line


def read_sssd_logs(root, since):
    """Read /var/log/sssd, including rotated files; untimed lines inherit the previous timestamp."""
    events, counts = [], {}
    directory = root / "var/log/sssd"
    files = sorted(directory.glob("*.log*")) if directory.is_dir() else []
    for path in files:
        source = re.sub(r"\.log.*$", "", path.name)
        count = 0
        when = None
        with open_log(path) as handle:
            for line in handle:
                stamp, text = parse_sssd_line(line.rstrip("\n"))
                when = stamp or when
                if when is None or when < since or not text.strip():
                    continue
                events.append(Event(when, source, text.strip()))
                count += 1
        counts[str(path.relative_to(root))] = count
    return events, counts


def read_auth_log(root, since):
    events, counts = [], {}
    now = datetime.datetime.now()
    for path in sorted((root / "var/log").glob("auth.log*")):
        count = 0
        with open_log(path) as handle:
            for line in handle:
                match = SYSLOG_ISO.match(line)
                if match:
                    when = datetime.datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
                else:
                    match = SYSLOG_OLD.match(line)
                    if not match:
                        continue
                    when = datetime.datetime.strptime(f"{now.year} {match.group(1)}", "%Y %b %d %H:%M:%S")
                    if when > now:
                        when = when.replace(year=now.year - 1)
                if when < since:
                    continue
                events.append(Event(when, match.group(2).strip(), match.group(3).strip()))
                count += 1
        counts[str(path.relative_to(root))] = count
    return events, counts


# --- Configuration facts --------------------------------------------------------------------------------------

def config_facts(root):
    """What sssd.conf and PAM say about the two usual causes, or None when unreadable."""
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            config, files = inspector.load_sssd(root)
            lines = inspector.pam_auth_lines(root, "gdm-password") or inspector.pam_auth_lines(root, "common-auth")
    except (configparser.Error, OSError):
        return None
    domains = [d.strip() for d in config.get("sssd", "domains", fallback="").split(",") if d.strip()]
    if not domains:
        domains = [s.split("/", 1)[1] for s in config.sections() if s.startswith("domain/")]
    cache_off = [d for d in domains
                 if config.get(f"domain/{d}", "cache_credentials", fallback="false").strip().lower()
                 not in inspector.TRUE]
    stack = [inspector.parse_pam_line(line) for line in lines]
    modules = [module for _control, module in stack]
    bypass = False
    if "pam_sss" in modules and "pam_krb5" in modules[:modules.index("pam_sss")]:
        krb5 = modules.index("pam_krb5")
        bypass = inspector.success_skips(stack[krb5][0], krb5, modules.index("pam_sss"))
    return {"present": bool(files), "domains": domains, "cache_off": cache_off,
            "pam_bypass": bypass, "pam_sss": "pam_sss" in modules}


# --- Reporting ------------------------------------------------------------------------------------------------

def stamp(when):
    return when.strftime("%Y-%m-%d %H:%M")


def example(event, width=220):
    text = PRIVATE_VALUE.sub(r"\1<hidden>", event.text)
    if len(text) > width:
        text = text[:width - 3] + "..."
    return f"{event.when.strftime('%Y-%m-%d %H:%M:%S')} {event.source}: {text}"


def print_findings(found, examples):
    print("Findings:")
    if not found:
        say("info", "no known SSSD, PAM, Kerberos, or VPN patterns in this window")
        return
    order = sorted(found, key=lambda key: (LEVELS.index(RULES[key].level), found[key][0].when))
    for key in order:
        rule, events = RULES[key], found[key]
        span = stamp(events[0].when) if len(events) == 1 else f"{stamp(events[0].when)} to {stamp(events[-1].when)}"
        times = "once" if len(events) == 1 else f"{len(events)} times"
        say(rule.level, f"{rule.title} ({times}, {span})")
        print(f"  why: {rule.meaning}")
        for event in events[-examples:]:
            print(f"  e.g. {example(event)}")


def boot_of(when, boots):
    current = None
    for start in boots:
        if start <= when:
            current = start
    return current


def assess_boots(found, boots):
    """Per boot: did domain login fail before the VPN came up, and succeed after?"""
    if not boots:
        return False
    stories = {}
    for key in OFFLINE_FAILURES + ("vpn-up", "sss-login", "cached-login"):
        for event in found.get(key, []):
            boot = boot_of(event.when, boots)
            if boot:
                stories.setdefault(boot, {}).setdefault(key, []).append(event.when)
    failed_first = recovered = 0
    for story in stories.values():
        failures = sorted(t for key in OFFLINE_FAILURES for t in story.get(key, []))
        vpn = min(story.get("vpn-up", []), default=None)
        if failures and (vpn is None or failures[0] < vpn):
            failed_first += 1
            if vpn and any(t > vpn for t in story.get("sss-login", [])):
                recovered += 1
    if failed_first:
        message = f"in {failed_first} of {len(stories)} boot(s) with login activity, domain login failed before the VPN connected"
        if recovered:
            message += f"; in {recovered} of them it then succeeded once the VPN was up"
        say("warning", message + ". That is the missing cached password, not a network fault")
    return bool(failed_first)


def assess_vpn(found):
    """SSSD still unreachable well after the VPN connected points at DNS or routing over the VPN."""
    ups = [e.when for e in found.get("vpn-up", [])]
    downs = [e.when for e in found.get("vpn-down", [])]
    onlines = [e.when for e in found.get("sssd-online", [])]
    failures = sorted(e.when for key in UNREACHABLE for e in found.get(key, []))
    episodes = []
    for up in ups:
        until = min([t for t in downs + ups if t > up], default=up + datetime.timedelta(minutes=30))
        until = min(until, up + datetime.timedelta(minutes=30))
        late = [t for t in failures if up + datetime.timedelta(seconds=90) <= t < until]
        if late and not any(up <= t <= late[0] for t in onlines):
            episodes.append(up)
    if episodes:
        say("warning", f"after the VPN connected (last at {stamp(episodes[-1])}), SSSD or Kerberos still could not "
            f"reach the domain ({len(episodes)} time(s)). Check that resolvectl status lists the domain on the VPN "
            "link, then sudo sssctl domain-status <domain>; sudo systemctl kill -s USR2 sssd forces SSSD to retry")
    return bool(episodes)


def assess(found, facts, sssd_lines):
    print("Assessment:")
    offline = sorted((e for key in OFFLINE_FAILURES for e in found.get(key, [])), key=lambda e: e.when)
    sss_logins = found.get("sss-login", [])
    krb5_logins = found.get("krb5-login", [])
    judged = False
    if offline:
        judged = True
        if facts and facts["cache_off"]:
            say("warning", f"cause: cache_credentials is off for {', '.join(facts['cache_off'])}, so SSSD never "
                "stores a password and every offline login fails. Set cache_credentials = True in the domain "
                "section, restart sssd, and log in once with the VPN up")
        elif facts and facts["pam_bypass"]:
            say("warning", "cause: pam_krb5 succeeds before pam_sss and skips it, so SSSD never sees the password"
                + (f" (pam_krb5 accepted {len(krb5_logins)} login(s) in this window)" if krb5_logins else "")
                + ". Remove libpam-krb5 and let SSSD obtain tickets")
        elif krb5_logins and not sss_logins:
            say("warning", f"likely cause: pam_krb5 accepted {len(krb5_logins)} login(s) and pam_sss none, so SSSD "
                "never saw a password to cache. Check the PAM stack with dotconfig creds status")
        elif not sss_logins:
            say("warning", "no online login through pam_sss in this window, so SSSD had nothing to cache. Log in to "
                "the domain account once with the VPN up, then check dotconfig creds status for a cached password")
        else:
            say("info", f"pam_sss accepted online logins (last at {stamp(sss_logins[-1].when)}) yet offline login "
                "still found no usable password. Compare the user name in both examples above, and check "
                "dotconfig creds status for when the password was stored")
    elif facts and (facts["cache_off"] or facts["pam_bypass"]):
        judged = True
        say("info", "the configuration cannot cache passwords (see dotconfig creds status), though no failing "
            "offline login is logged in this window")
    if "cached-login" in found:
        judged = True
        say("ok", f"offline login from cached credentials worked {len(found['cached-login'])} time(s), "
            f"last at {stamp(found['cached-login'][-1].when)}")
    if facts and facts["present"] and not facts["pam_sss"]:
        judged = True
        say("warning", "pam_sss is not in the login PAM stack, so SSSD takes no part in domain logins")
    if not sssd_lines:
        judged = True
        say("info", "SSSD logged nothing in this window. Its default debug_level records only serious failures; "
            "run sudo sssctl debug-level 6, reproduce the login, run this again, then sudo sssctl debug-level 0x0070")
    return judged


def main():
    parser = argparse.ArgumentParser(prog="dotconfig creds check-logs")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--examples", type=int, default=1)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    if args.days < 1 or args.examples < 1:
        parser.error("--days and --examples must be at least 1")
    root = args.root
    since = datetime.datetime.now() - datetime.timedelta(days=args.days)

    print(f"Logs searched since {stamp(since)}:")
    events = []
    journal = read_journal(root, since)
    auth_entries = 0
    boots = []
    if journal is None:
        say("info", "journalctl not found; only log files are searched")
    else:
        journal_events, boots, auth_entries = journal
        events += journal_events
        print(f"  journal: {len(journal_events)} entries (SSSD units, auth facility, VPN)")
        if not (root / "var/log/journal").is_dir():
            say("info", "the journal is not kept across reboots, so logins from earlier boots are lost; "
                "sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald keeps it")
    sssd_events, sssd_counts = read_sssd_logs(root, since)
    events += sssd_events
    for name, count in sssd_counts.items():
        print(f"  /{name}: {count} lines")
    if not sssd_counts:
        say("info", "no /var/log/sssd logs; SSSD may log to the journal only")
    if not auth_entries:
        # rsyslog duplicates the journal's auth lines, so the file is read only when the journal lacks them.
        auth_events, auth_counts = read_auth_log(root, since)
        events += auth_events
        for name, count in auth_counts.items():
            print(f"  /{name}: {count} lines")

    found = {}
    for event in sorted(events, key=lambda e: e.when):
        for key in classify(event).keys:
            found.setdefault(key, []).append(event)
    print_findings(found, args.examples)

    facts = config_facts(root)
    sssd_lines = len(sssd_events) + sum(1 for e in events if e.source.startswith("sssd"))
    judged = assess(found, facts, sssd_lines)
    judged = assess_boots(found, boots) or judged
    judged = assess_vpn(found) or judged
    if not judged and not any(RULES[key].level == "warning" for key in found):
        say("ok", "no sign of a domain login problem in this window")


if __name__ == "__main__":
    try:
        main()
    except OSError as exc:
        print(f"credentials: {exc}", file=sys.stderr)
        sys.exit(1)
