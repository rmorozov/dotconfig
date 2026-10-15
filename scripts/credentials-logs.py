#!/usr/bin/env python3
"""Search SSSD, PAM, Kerberos, and VPN logs for reasons a domain login fails, and judge what was found."""

import argparse
import configparser
import datetime
import gzip
import importlib.util
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
_spec = importlib.util.spec_from_file_location("credentials_platform", Path(__file__).with_name("credentials-platform.py"))
platform = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(platform)

LEVELS = ("warning", "info", "ok")
UTC = datetime.timezone.utc
# Kerberos and SSSD never log passwords, but a debug line may quote a config value. A value may be quoted or
# contain spaces, so examples hide the rest of the line after any sensitive assignment.
PRIVATE_VALUE = re.compile(r"(\b\w*(?:authtok|password|passwd|secret)\w*\s*=\s*)\S.*$", re.I)


@dataclass
class Rule:
    level: str
    title: str
    meaning: str
    pattern: str = ""


RULES = {
    "pam-authinfo-unavail": Rule(
        "warning", "Domain login failed: SSSD could not check the password",
        "PAM result 9: SSSD could neither ask a domain controller nor use a cached password. Offline that usually "
        "means no usable cached password; online it means a backend fault, given in the SSSD lines nearby"),
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
    "apparmor-denied": Rule(
        "warning", "AppArmor denied an SSSD or Kerberos process",
        "confinement, not account policy, refused the operation; add a rule under /etc/apparmor.d/local/ for "
        "the named profile instead of disabling AppArmor",
        r"apparmor=\"DENIED\""),
    "ccache-create": Rule(
        "warning", "A Kerberos ticket cache could not be created",
        "SSSD 2.11+ no longer creates missing parent directories for FILE and DIR caches; the user needs write "
        "and search access to the parent (see dotconfig creds status, Kerberos caches)",
        r"(cannot|can't|failed to|unable to) (create|open|initiali[sz]e|store)\S*.*(ccache|credential cache)|"
        r"ccache.*no such file or directory|krb5_cc_(initialize|resolve|store_cred)\S*.*fail"),
    "home-failure": Rule(
        "warning", "The login session could not set up the home directory",
        "the password was accepted; the session stage failed, so this is not a cached-password problem",
        r"pam_mkhomedir.*(unable|fail|error|cannot)|unable to create and initiali[sz]e directory|"
        r"could not chdir to home directory|no directory, logging in with home"),
    "enctype": Rule(
        "warning", "Kerberos found no permitted encryption type",
        "Ubuntu 26.04 dropped RC4 and 3DES from the defaults; have the domain issue AES keys for the account and "
        "machine rather than re-enabling weak crypto",
        r"kdc has no support for encryption type|KRB5KDC_ERR_ETYPE_NOSUPP|no supported encryption types|"
        r"enctype \S+ not (permitted|supported)|bad encryption type"),
    "keytab-kvno": Rule(
        "warning", "The machine keytab is out of date",
        "the machine account's password changed but the keytab holds old keys; refresh it with adcli update or "
        "rejoin the domain",
        r"key version number for principal in key table is incorrect|KRB5KRB_AP_ERR_BADKEYVER|"
        r"KRB5_KT_KVNONOTFOUND|specified version of key is not available"),
    "smartcard": Rule(
        "info", "Smartcard authentication reported a problem",
        "the smartcard path (p11_child, certificates, PC/SC) failed; this does not mean password login fails",
        r"p11_child.*(error|fail)|no certificate (found|matched)|certificate.*(revoked|expired|not valid|"
        r"verification failed)|\bocsp\b.*(fail|error)|pcsc.*(fail|error)|pkcs#?11.*(fail|error)"),
    "pam-account": Rule(
        "warning", "A domain account was refused at the account (access) stage",
        "the password was fine but an access rule refused the login; sudo sssctl user-checks -a acct -s "
        "gdm-password USER shows the decision"),
    "pam-session": Rule(
        "warning", "A domain login failed at the session stage",
        "authentication and access passed; session setup (home directory, limits) failed"),
    "cached-login": Rule(
        "ok", "Logins succeeded from cached credentials", "offline login worked for these attempts",
        r"authenticated with cached credentials|offline authentication succeeded"),
}
COMPILED = {key: re.compile(rule.pattern, re.I) for key, rule in RULES.items() if rule.pattern}
PAM_RESULT = re.compile(r"pam_sss\([^:)]*:?(\w*)\): received for user (\S+): (\d+) \(([^)]*)\)")
APPARMOR = re.compile(r'apparmor="DENIED"')
APPARMOR_FIELDS = re.compile(r'(operation|profile|name|comm|requested_mask)="([^"]*)"')
SSSD_PROCESS = re.compile(r"sssd|krb5_child|ldap_child|p11_child|selinux_child|gpo_child|proxy_child", re.I)
PAM_CODES = {4: "pam-system-error", 6: "pam-denied", 7: "pam-bad-password", 9: "pam-authinfo-unavail",
             10: "pam-user-unknown", 12: "password-expired", 13: "account-expired"}
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
        stage, code = result.group(1), int(result.group(3))
        if stage in ("account", "session") and code:
            event.keys.add(f"pam-{stage}")
        else:
            event.keys.add(PAM_CODES.get(code, "pam-other"))
    for key, pattern in COMPILED.items():
        if pattern.search(event.text):
            event.keys.add(key)
    return event


# --- Collection -----------------------------------------------------------------------------------------------

JOURNAL_SELECTORS = (
    ["-u", "sssd*"],
    ["SYSLOG_FACILITY=4", "SYSLOG_FACILITY=10"],
    ["_TRANSPORT=kernel", "_TRANSPORT=audit"],
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
        command = base + ["-o", "json", "--since", f"@{int(since.timestamp())}"] + selector
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
            if entry.get("_TRANSPORT") in ("kernel", "audit") and not (APPARMOR.search(text)
                                                                        and SSSD_PROCESS.search(text)):
                continue
            if entry.get("SYSLOG_FACILITY") in ("4", "10"):
                auth_entries += 1
            when = datetime.datetime.fromtimestamp(int(entry.get("__REALTIME_TIMESTAMP", 0)) / 1e6, UTC)
            events.append(Event(when, source, text))
    boots = []
    result = subprocess.run(base + ["--list-boots", "-o", "json"], capture_output=True, text=True, check=False)
    try:
        for boot in json.loads(result.stdout or "[]"):
            boots.append(datetime.datetime.fromtimestamp(int(boot["first_entry"]) / 1e6, UTC))
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        boots = []
    return events, sorted(boots), auth_entries


def open_log(path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", errors="replace")
    return path.open(errors="replace")


SSSD_STAMP = re.compile(r"^\((\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2}:\d{2})(?:[:.]\d+)?\):?\s*(.*)")
SSSD_OLD_STAMP = re.compile(r"^\(\w{3} (\w{3} +\d+ \d{2}:\d{2}:\d{2}) (\d{4})\)\s*(.*)")
SYSLOG_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+\S+\s+([^:\[]+)(?:\[\d+\])?:\s*(.*)")
SYSLOG_OLD = re.compile(r"^(\w{3} +\d+ \d{2}:\d{2}:\d{2})\s+\S+\s+([^:\[]+)(?:\[\d+\])?:\s*(.*)")


def local_time(text, layout):
    """Parse a timestamp written without an offset, which SSSD and classic syslog write in local time."""
    return datetime.datetime.strptime(text, layout).astimezone(UTC)


def parse_sssd_line(line):
    match = SSSD_STAMP.match(line)
    if match:
        return local_time(f"{match.group(1)} {match.group(2)}", "%Y-%m-%d %H:%M:%S"), match.group(3)
    match = SSSD_OLD_STAMP.match(line)
    if match:
        return local_time(f"{match.group(1)} {match.group(2)}", "%b %d %H:%M:%S %Y"), match.group(3)
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


def parse_iso(text):
    """RFC 3339 syslog time; the offset is kept so archived or travelled logs order correctly."""
    text = re.sub(r"Z$", "+00:00", text)
    text = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", text)
    # A naive value is local time; astimezone() assumes that for naive datetimes.
    return datetime.datetime.fromisoformat(text).astimezone(UTC)


def read_auth_log(root, since):
    events, counts = [], {}
    now = datetime.datetime.now()
    for path in sorted((root / "var/log").glob("auth.log*")):
        count = 0
        with open_log(path) as handle:
            for line in handle:
                match = SYSLOG_ISO.match(line)
                if match:
                    try:
                        when = parse_iso(match.group(1))
                    except ValueError:
                        continue
                else:
                    match = SYSLOG_OLD.match(line)
                    if not match:
                        continue
                    when = datetime.datetime.strptime(f"{now.year} {match.group(1)}", "%Y %b %d %H:%M:%S")
                    if when > now:
                        when = when.replace(year=now.year - 1)
                    when = when.astimezone(UTC)
                if when < since:
                    continue
                events.append(Event(when, match.group(2).strip(), match.group(3).strip()))
                count += 1
        counts[str(path.relative_to(root))] = count
    return events, counts


# --- Configuration facts --------------------------------------------------------------------------------------

def sssctl_check(root):
    """Ask the installed SSSD to validate its configuration: (issues, exit code), or None without sssctl."""
    sssctl = shutil.which("sssctl")
    if not sssctl:
        return None
    result = subprocess.run([sssctl, "config-check", "-c", str(root / "etc/sssd/sssd.conf"),
                             "-s", str(root / "etc/sssd/conf.d")], capture_output=True, text=True, check=False)
    output = (result.stdout + result.stderr).splitlines()
    issues, collecting = [], False
    for line in output:
        if re.match(r"Issues identified by validators:\s*\d+", line):
            collecting = True
        elif collecting and line.strip() and not re.match(r"Messages generated|Used configuration", line):
            issues.append(PRIVATE_VALUE.sub(r"\1<hidden>", line.strip()))
        elif collecting and not line.strip():
            collecting = False
    return issues, result.returncode


def domains_of(config):
    domains = [d.strip() for d in config.get("sssd", "domains", fallback="").split(",") if d.strip()]
    return domains or [s.split("/", 1)[1] for s in config.sections() if s.startswith("domain/")]


def config_facts(root):
    """What the configuration says, and whether SSSD would accept it: valid, invalid, unknown, or absent."""
    facts = {"state": "unknown", "reasons": [], "confirmed": False, "kerberos": [], "present": False,
             "platform": [], "not_checked": [], "accounts": inspector.read_accounts(root),
             "domains": [], "cache_off": [], "pam_bypass": False, "pam_sss": True}
    config = identity = accounts = None
    try:
        config, files, identity, _source, accounts, findings = inspector.check_config(root)
        facts["present"] = bool(files)
        facts["state"] = "valid" if files else "absent"
        facts["reasons"] = [message for level, message in findings if level == "warning"]
        if facts["reasons"]:
            facts["state"] = "invalid"
    except configparser.Error as exc:
        # Parser messages quote the offending line, which may hold a private value.
        facts["state"], facts["present"] = "invalid", True
        facts["reasons"] = [f"it cannot be parsed ({type(exc).__name__})"]
    except OSError as exc:
        facts["reasons"] = [f"it cannot be read ({exc.strerror or exc})"]
    if facts["present"]:
        checked = sssctl_check(root)
        if checked is not None:
            issues, code = checked
            if issues or code != 0:
                facts["state"] = "invalid"
                facts["reasons"].append(f"sssctl config-check reported {len(issues) or 'a'} problem(s)"
                                        + (": " + "; ".join(issues[:3]) if issues else f" (exit {code})"))
            elif facts["state"] == "valid":
                facts["confirmed"] = True
    if config is not None:
        try:
            sections, facts["not_checked"] = platform.platform_report(root, config, domains_of(config), identity,
                                                                      accounts)
            facts["platform"] = [(title, level, message) for title, found in sections for level, message in found]
            hygiene = dict(sections).get("Configuration hygiene", [])
            stopping = platform.invalid_reasons(hygiene)
            if stopping and facts["state"] in ("valid", "unknown"):
                facts["state"] = "invalid"
            facts["reasons"] += stopping
        except OSError as exc:
            facts["not_checked"] = [f"platform checks ({exc.strerror or exc})"]
    try:
        facts["kerberos"] = inspector.kerberos_findings(root, identity, accounts)
    except OSError as exc:
        facts["kerberos"] = [("info", f"Kerberos files could not be checked ({exc.strerror or exc})")]
    if config is not None and facts["state"] == "valid":
        domains = facts["domains"] = domains_of(config)
        facts["cache_off"] = [d for d in domains
                              if config.get(f"domain/{d}", "cache_credentials", fallback="false").strip().lower()
                              not in inspector.TRUE]
    try:
        lines = inspector.pam_auth_lines(root, "gdm-password") or inspector.pam_auth_lines(root, "common-auth")
    except OSError:
        return facts
    stack = [inspector.parse_pam_line(line) for line in lines]
    modules = [module for _control, module in stack]
    if "pam_sss" in modules and "pam_krb5" in modules[:modules.index("pam_sss")]:
        krb5 = modules.index("pam_krb5")
        facts["pam_bypass"] = inspector.success_skips(stack[krb5][0], krb5, modules.index("pam_sss"))
    facts["pam_sss"] = "pam_sss" in modules or not lines
    return facts


# --- Reporting ------------------------------------------------------------------------------------------------

def stamp(when):
    return when.astimezone().strftime("%Y-%m-%d %H:%M")


def example(event, width=220):
    text = PRIVATE_VALUE.sub(r"\1<hidden>", event.text)
    if len(text) > width:
        text = text[:width - 3] + "..."
    return f"{event.when.astimezone().strftime('%Y-%m-%d %H:%M:%S')} {event.source}: {text}"


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


def vpn_down_until_later(when, found, boots):
    """Whether the VPN was not up at this time but connected later in the same boot."""
    boot = boot_of(when, boots)
    same_boot = [(e.when, key) for key in ("vpn-up", "vpn-down") for e in found.get(key, [])
                 if boot_of(e.when, boots) == boot]
    before = [key for t, key in sorted(same_boot) if t <= when]
    later_up = any(t > when and key == "vpn-up" for t, key in same_boot)
    return later_up and (not before or before[-1] == "vpn-down")


def offline_failures(found, boots):
    """Failed domain logins with evidence that SSSD was offline; PAM result 9 alone does not prove it."""
    unreachable = [e.when for key in UNREACHABLE for e in found.get(key, [])]
    failures = list(found.get("no-cached-password", []))
    for event in found.get("pam-authinfo-unavail", []):
        near = any(event.when - datetime.timedelta(minutes=10) <= t <= event.when + datetime.timedelta(minutes=2)
                   and boot_of(t, boots) == boot_of(event.when, boots) for t in unreachable)
        if near or vpn_down_until_later(event.when, found, boots):
            failures.append(event)
    return sorted(failures, key=lambda e: e.when)


def assess_boots(found, boots, offline):
    """Per boot: did domain login fail before the VPN came up, and succeed after?"""
    if not boots:
        return False
    with_vpn = {boot_of(e.when, boots) for e in found.get("vpn-up", [])}
    failed_first = recovered = 0
    for boot in sorted(b for b in with_vpn if b):
        first_vpn = min(e.when for e in found["vpn-up"] if boot_of(e.when, boots) == boot)
        if any(boot_of(e.when, boots) == boot and e.when < first_vpn for e in offline):
            failed_first += 1
            if any(boot_of(e.when, boots) == boot and e.when > first_vpn for e in found.get("sss-login", [])):
                recovered += 1
    if failed_first:
        message = (f"in {failed_first} of {len(with_vpn)} boot(s) with a VPN connection, domain login failed while "
                   "SSSD was offline before the VPN connected")
        if recovered:
            message += f"; in {recovered} of them it then succeeded once the VPN was up"
        say("warning", message + ". That points at a missing or unusable cached password, not a network fault")
    return bool(failed_first)


def assess_vpn(found, boots):
    """SSSD still unreachable well after the VPN connected points at DNS or routing over the VPN."""
    ups = [e.when for e in found.get("vpn-up", [])]
    downs = [e.when for e in found.get("vpn-down", [])]
    onlines = [e.when for e in found.get("sssd-online", [])]
    failures = sorted(e.when for key in UNREACHABLE for e in found.get(key, []))
    episodes = []
    for up in ups:
        until = min([t for t in downs + ups if t > up], default=up + datetime.timedelta(minutes=30))
        # A reboot ends the connection even when no disconnect was logged.
        until = min([until, up + datetime.timedelta(minutes=30)] + [b for b in boots if b > up])
        late = [t for t in failures if up + datetime.timedelta(seconds=90) <= t < until]
        if late and not any(up <= t <= late[0] for t in onlines):
            episodes.append(up)
    if episodes:
        say("warning", f"after the VPN connected (last at {stamp(episodes[-1])}), SSSD or Kerberos still could not "
            f"reach the domain ({len(episodes)} time(s)). Check that resolvectl status lists the domain on the VPN "
            "link, then sudo sssctl domain-status <domain>; sudo systemctl kill -s USR2 sssd forces SSSD to retry")
    return bool(episodes)


def assess_config(facts):
    """Configuration problems come first: the judgements after them assume the configuration SSSD runs with."""
    judged = False
    if facts["state"] == "invalid":
        judged = True
        say("warning", f"SSSD configuration is invalid: {'; '.join(facts['reasons'])}. SSSD may refuse to start or "
            "run without it, so fix this first; the judgements below do not rely on sssd.conf")
    elif facts["state"] == "unknown":
        judged = True
        say("info", f"SSSD configuration could not be checked: {'; '.join(facts['reasons'])}. The judgements below "
            "do not rely on sssd.conf")
    elif facts["confirmed"]:
        say("ok", "sssctl config-check accepts the SSSD configuration")
    for level, message in facts["kerberos"]:
        if level == "warning":
            judged = True
            say(level, f"Kerberos: {message}")
    for title, level, message in facts["platform"]:
        if level == "warning" and message not in facts["reasons"]:
            judged = True
            say(level, f"{title}: {message}")
    return judged


def assess_apparmor(found):
    denials = {}
    for event in found.get("apparmor-denied", []):
        fields = dict(APPARMOR_FIELDS.findall(event.text))
        key = (fields.get("profile", "?"), fields.get("operation", "?"), fields.get("name", "?"))
        denials[key] = denials.get(key, 0) + 1
    for (profile, operation, name), count in sorted(denials.items(), key=lambda item: -item[1])[:5]:
        say("warning", f"AppArmor profile {profile} denied {operation} on {name} ({count} time(s)); a "
            "Permission denied from SSSD at those times is confinement, not an account rule")
    return bool(denials)


def assess_name_collisions(found, accounts):
    """A local account with a domain user's short name decides some logins by nsswitch order alone."""
    if not accounts:
        return False
    domain_users = set()
    for events in found.values():
        for event in events:
            result = PAM_RESULT.search(event.text)
            name = result.group(2) if result else (re.search(r"\buser=(\S+@\S+)", event.text) or [None, None])[1]
            if name and "@" in name:
                domain_users.add(name)
    clashes = sorted(u for u in domain_users
                     if u.split("@")[0] in accounts[0] and accounts[0][u.split("@")[0]][0] >= 1000)
    for user in clashes:
        say("warning", f"the local account {user.split('@')[0]} shares its name with the domain user {user}; with "
            "use_fully_qualified_names off, nsswitch order decides which one a short-name login gets")
    return bool(clashes)


def assess(found, facts, sssd_lines, offline):
    print("Assessment:")
    judged = assess_config(facts)
    sss_logins = found.get("sss-login", [])
    krb5_logins = found.get("krb5-login", [])
    if offline:
        judged = True
        if facts["cache_off"]:
            say("warning", f"cause: cache_credentials is off for {', '.join(facts['cache_off'])}, so SSSD never "
                "stores a password and every offline login fails. Set cache_credentials = True in the domain "
                "section, restart sssd, and log in once with the VPN up")
        elif facts["pam_bypass"]:
            say("warning", "cause: pam_krb5 succeeds before pam_sss and skips it, so SSSD never sees the password"
                + (f" (pam_krb5 accepted {len(krb5_logins)} login(s) in this window)" if krb5_logins else "")
                + ". Remove libpam-krb5 and let SSSD obtain tickets")
        elif krb5_logins and not sss_logins:
            say("warning", f"likely cause: pam_krb5 accepted {len(krb5_logins)} login(s) and pam_sss none, so SSSD "
                "never saw a password to cache. Check the PAM stack with dotconfig creds status")
        elif not sss_logins:
            say("info", "no online login through pam_sss is logged in this window, though a password cached "
                "earlier may still exist. If dotconfig creds status shows no cached password, log in once with "
                "the VPN up; if it shows one, compare when it was stored with these failures")
        else:
            say("info", f"pam_sss accepted online logins (last at {stamp(sss_logins[-1].when)}) yet offline login "
                "still found no usable password. Compare the user name in both examples above, and check "
                "dotconfig creds status for when the password was stored")
    elif found.get("pam-authinfo-unavail"):
        judged = True
        say("info", f"pam_sss returned PAM result 9 {len(found['pam-authinfo-unavail'])} time(s) with no sign that "
            "SSSD was offline, so the cache is not implicated; the SSSD lines around those times give the cause")
    if not offline and (facts["cache_off"] or facts["pam_bypass"]):
        judged = True
        say("info", "the configuration cannot cache passwords (see dotconfig creds status), though no failing "
            "offline login is logged in this window")
    if "cached-login" in found:
        judged = True
        say("ok", f"offline login from cached credentials worked {len(found['cached-login'])} time(s), "
            f"last at {stamp(found['cached-login'][-1].when)}")
    if facts["present"] and not facts["pam_sss"]:
        judged = True
        say("warning", "pam_sss is not in the login PAM stack, so SSSD takes no part in domain logins")
    judged = assess_apparmor(found) or judged
    judged = assess_name_collisions(found, facts["accounts"]) or judged
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
    since = datetime.datetime.now(UTC) - datetime.timedelta(days=args.days)

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
    offline = offline_failures(found, boots)
    judged = assess(found, facts, sssd_lines, offline)
    judged = assess_boots(found, boots, offline) or judged
    judged = assess_vpn(found, boots) or judged
    if not judged and not any(RULES[key].level == "warning" for key in found):
        say("ok", "no sign of a domain login problem in this window")
    if facts["not_checked"]:
        print("Not checked:")
        for item in facts["not_checked"]:
            print(f"  {item}")


if __name__ == "__main__":
    try:
        main()
    except OSError as exc:
        print(f"credentials: {exc}", file=sys.stderr)
        sys.exit(1)
