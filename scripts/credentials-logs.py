#!/usr/bin/env python3
"""Search SSSD, PAM, Kerberos, and VPN logs for reasons a domain login fails, and judge what was found."""

import argparse
import bisect
import configparser
import datetime
import gzip
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
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
PRIVATE_VALUE = inspector.PRIVATE_VALUE


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
        r"password cach(ing|e) (is )?(not enabled|disabled)|cached password.*not (found|available|stored)"),
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
        r"password expired|password has expired|KRB5KDC_ERR_KEY_EXP"),
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
        r"file ownership and permissions check failed|cannot read config|failed to read .*config|"
        r"failed to load .*config|failed to parse .*config|is not allowed in section|unknown option|invalid option|"
        r"invalid section|confdb_init.*fail"),
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
        r"no servers? (available|found)|no available servers?|going offline|backend is offline|marked offline|"
        r"marked as offline"),
    "krb5-login": Rule(
        "info", "pam_krb5 accepted domain passwords",
        "pam_krb5 checked these passwords itself; if its success skips pam_sss, SSSD never sees the password",
        r"pam_krb5\([^):]*:auth\): authentication succeeds"),
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
        r"going online|backend is online|(?<!go )back online|reset(ting)? offline status|switch(ed|ing)? to online"),
    "sss-login": Rule(
        "ok", "SSSD accepted domain logins",
        "pam_sss saw these passwords, so SSSD can cache them when cache_credentials is on",
        r"pam_sss\([^):]*:auth\): authentication success"),
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
        "the session stage failed; it also runs for logins without a password (SSH keys), so this neither "
        "shows that a password was accepted nor implicates the cache",
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
        "an access rule refused the login. This stage also runs without a password check (SSH keys), so it "
        "says nothing about the password; sudo sssctl user-checks -a acct -s SERVICE USER shows the decision"),
    "pam-session": Rule(
        "warning", "A domain login failed at the session stage",
        "session setup (home directory, limits) failed; this stage does not show that a password was checked"),
    "cached-login": Rule(
        "ok", "Logins succeeded from cached credentials", "offline login worked for these attempts",
        r"authenticated with cached credentials|offline authentication succeeded"),
}
def casefolded(pattern):
    """pattern lowercased for matching lowercased text, with escapes such as \\S kept as they are. Searching
    lowercased text this way is about three times faster than re.IGNORECASE, which defeats literal scanning."""
    out, escaped = [], False
    for char in pattern:
        out.append(char if escaped else char.lower())
        escaped = not escaped and char == "\\"
    return "".join(out)


COMPILED = {key: re.compile(casefolded(rule.pattern)) for key, rule in RULES.items() if rule.pattern}
PAM_RESULT = re.compile(r"pam_sss\(([^:)]*):?(\w*)\): received for user (\S+): (\d+) \(([^)]*)\)")
BACKEND = re.compile(r"\[be\[([^\]]+)\]\]")
RESPONDERS = {"sssd", "sssd_nss", "sssd_pam", "sssd_be", "sssd_sudo", "sssd_ssh", "sssd_pac", "sssd_ifp", "sssd_kcm",
              "sssd_autofs", "sssd_secrets"}
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
    classified: bool = False


# Every rule needs one of these lowercase literals: each top-level alternative of each rule contains one, and
# test-credentials-logs.sh checks that. SSSD at a raised debug_level writes millions of lines a day, and words
# such as "server" or "online" are on most of them, so the literals are the specific phrases the rules need.
# The log files are searched for them with bytes.find, and only the lines that contain one are classified.
KEYWORDS = (
    "cached credential", "no cached ", "password cach", "cached password", "cached user entry", "too many failed",
    "password expired", "password has expired", "krb5kdc_err", "krb5krb_ap_err", "krb5_kt_", "krb5_kdc_unreach",
    "pam_sss", "pam_krb5", "watchdog", "restart critical", "killing service", "exiting the sssd", ".service:",
    "segmentation fault", "core dumped", "ownership", "cannot read config", "failed to read", "failed to load",
    "failed to parse", "not allowed in section", "unknown option", "invalid option", "invalid section",
    "confdb_init", "clock skew", "kerberos database", "key table", "keytab contains", "using keytab", "gpo-based",
    "ad_gpo_access", "authentication failed", "decrypt integrity", "any kdc", "find kdc", "could not resolve",
    "resolve server", "unable to resolve", "srv lookup", "no server", "no available server", "going offline",
    "backend is offline", "marked offline", "marked as offline", "connected as ", "cstp connected",
    "dtls connection", "vpn plugin", "vpn connection", "logout successful", "session terminated", "going online",
    "backend is online", "back online", "offline status", "to online", "apparmor", "ccache", "credential cache",
    "krb5_cc_", "pam_mkhomedir", "unable to create and initiali", "chdir to home", "no directory, logging",
    "encryption type", "enctype ", "key version number", "version of key", "p11_child", "certificate", "ocsp",
    "pcsc", "pkcs", "authenticated with cached", "offline authentication",
)
KEYWORD_BYTES = tuple(keyword.encode() for keyword in KEYWORDS)
# The rules whose pattern text names each keyword: a line is searched only with the rules its keywords select.
RULES_FOR = {keyword: tuple(key for key, rule in RULES.items()
                            if rule.pattern and keyword in re.sub(r"\\(.)", r"\1", rule.pattern).lower())
             for keyword in KEYWORDS}


def classify(event):
    low = event.text.lower()
    keys = {key for keyword in KEYWORDS if keyword in low for key in RULES_FOR[keyword]}
    if not keys and "pam_sss" not in low:
        return event
    result = PAM_RESULT.search(event.text)
    if result:
        stage, code = result.group(2), int(result.group(4))
        if stage in ("account", "session") and code:
            event.keys.add(f"pam-{stage}")
        else:
            event.keys.add(PAM_CODES.get(code, "pam-other"))
    for key in keys:
        if COMPILED[key].search(low):
            event.keys.add(key)
    event.classified = True
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
    events, seen, failures = [], set(), []
    auth_entries = 0
    for selector in JOURNAL_SELECTORS:
        command = base + ["-o", "json", "--since", f"@{int(since.timestamp())}"] + selector
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            failures.append(f"{inspector.probe_failure('journalctl', result)} (reading {' '.join(selector)})")
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
    if result.returncode != 0:
        failures.append(f"{inspector.probe_failure('journalctl --list-boots', result)}; logins are not grouped "
                        "by boot")
    try:
        for boot in json.loads(result.stdout or "[]"):
            boots.append(datetime.datetime.fromtimestamp(int(boot["first_entry"]) / 1e6, UTC))
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        boots = []
    return events, sorted(boots), auth_entries, failures


def open_log(path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", errors="replace")
    return path.open(errors="replace")


SSSD_STAMP = re.compile(r"^\((\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2}:\d{2})(?:[:.]\d+)?\):?\s*(.*)")
SSSD_OLD_STAMP = re.compile(r"^\(\w{3} (\w{3} +\d+ \d{2}:\d{2}:\d{2}) (\d{4})\)\s*(.*)")
SYSLOG_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+\S+\s+([^:\[]+)(?:\[\d+\])?:\s*(.*)")
SYSLOG_OLD = re.compile(r"^(\w{3} +\d+ \d{2}:\d{2}:\d{2})\s+\S+\s+([^:\[]+)(?:\[\d+\])?:\s*(.*)")


_MINUTES = {}


def local_time(minute, seconds, layout):
    """A local timestamp without an offset, as SSSD and classic syslog write it, in UTC. strptime and the local
    zone lookup run once per minute, not once per line."""
    start = _MINUTES.get((minute, layout))
    if start is None:
        start = _MINUTES[(minute, layout)] = datetime.datetime.strptime(minute, layout).astimezone(UTC)
    return start + datetime.timedelta(seconds=int(seconds))


def parse_sssd_line(line):
    match = SSSD_STAMP.match(line)
    if match:
        clock = match.group(2)
        return local_time(f"{match.group(1)} {clock[:-3]}", clock[-2:], "%Y-%m-%d %H:%M"), match.group(3)
    match = SSSD_OLD_STAMP.match(line)
    if match:
        clock = match.group(1)
        return local_time(f"{clock[:-3]} {match.group(2)}", clock[-2:], "%b %d %H:%M %Y"), match.group(3)
    return None, line


class Progress:
    """A one-line progress report on stderr while a large log is read; silent when stderr is not a terminal."""

    def __init__(self, label, total):
        self.label, self.total, self.shown = label, total, 0.0
        self.live = sys.stderr.isatty() and total > 4 * CHUNK

    def update(self, done):
        now = time.monotonic()
        if self.live and now - self.shown >= 0.5:
            self.shown = now
            print(f"\r  reading {self.label}: {100 * done // self.total}% of {self.total / 2**30:.1f} GiB ",
                  end="", file=sys.stderr, flush=True)

    def close(self):
        if self.live and self.shown:
            print("\r\033[K", end="", file=sys.stderr, flush=True)


CHUNK = 1 << 24


def chunks(path):
    """Yield (block, bytes of the file read so far): whole lines, lowercase-able as bytes."""
    with path.open("rb") as raw:
        handle = gzip.GzipFile(fileobj=raw) if path.suffix == ".gz" else raw
        while True:
            data = handle.read(CHUNK)
            if not data:
                break
            # Complete the last line, and end a file that stops mid-line with a newline.
            if not data.endswith(b"\n"):
                data += handle.readline()
            if not data.endswith(b"\n"):
                data += b"\n"
            yield data, raw.tell()


def line_at(block, start):
    end = block.find(b"\n", start)
    return block[start:end].decode(errors="replace")


def stamp_before(block, end, previous):
    """The timestamp of the last timed line that starts before offset end, else previous."""
    while end > 0:
        start = block.rfind(b"\n", 0, end - 1) + 1
        stamp, _text = parse_sssd_line(line_at(block, start))
        if stamp:
            return stamp
        end = start
    return previous


def window_start(block, since, previous):
    """Offset of the first line at or after since, by bisection over the lines of a block ordered by time."""
    low, high = 0, len(block)
    while low < high:
        middle = (low + high) // 2
        start = block.rfind(b"\n", 0, middle) + 1
        if (stamp_before(block, block.find(b"\n", start) + 1, previous) or since) < since:
            low = block.find(b"\n", middle) + 1
        else:
            high = start
    return low


def search_command(tool, path):
    """The command that prints offset:line for each line of path with a keyword, or None. ripgrep is about twice
    as fast as grep and reads gzip files too (offsets then count decompressed bytes, as chunks() does)."""
    found = shutil.which(tool)
    keywords = [arg for keyword in KEYWORDS for arg in ("-e", keyword)]
    if found and tool == "rg":
        zipped = ["--search-zip"] if path.suffix == ".gz" else []
        return [found, "--no-config", "-a", "-b", "-i", "-F", "--no-unicode", "--no-line-number", "--no-filename",
                "--color", "never"] + zipped + keywords + ["--", str(path)]
    if found and tool == "grep" and path.suffix != ".gz":
        return [found, "-a", "-b", "-i", "-F"] + keywords + ["--", str(path)]
    return None


def keyword_offsets(path, tools=("rg", "grep")):
    """The byte offsets of the lines of a log that contain a keyword, in order, or None when no search tool can
    tell. They search for all keywords at once, ten to twenty times faster than bytes.find per keyword."""
    command = next(filter(None, (search_command(tool, path) for tool in tools)), None)
    if command is None:
        return None
    try:
        result = subprocess.run(command, capture_output=True, check=False, env=dict(os.environ, LC_ALL="C"))
    except OSError:
        return None
    if result.returncode > 1:
        return None
    return [int(line[:line.index(b":")]) for line in result.stdout.splitlines() if b":" in line]


def keyword_starts(block, offset):
    """The starts of the lines of block from offset that contain a keyword, searched with bytes.find."""
    low = block.lower()
    starts = set()
    for keyword in KEYWORD_BYTES:
        found = low.find(keyword, offset)
        while found != -1:
            starts.add(low.rfind(b"\n", 0, found) + 1)
            end = low.find(b"\n", found)
            found = low.find(keyword, end + 1)
    return sorted(starts)


def scan_block(block, starts, source, previous):
    """Classify the lines of block that start at starts; lines without a timestamp of their own take the
    previous one."""
    events = []
    for start in starts:
        stamp, text = parse_sssd_line(line_at(block, start))
        when = stamp or stamp_before(block, start, previous)
        if when is None or not text.strip():
            continue
        event = classify(Event(when, source, text.strip()))
        if event.keys:
            events.append(event)
    return events


def read_sssd_logs(root, since):
    """Read /var/log/sssd, including rotated files; untimed lines inherit the previous timestamp. Only lines that
    contain a keyword (found by grep, else by bytes.find) are decoded and classified, and only those a rule
    matches are kept, so time and memory follow the findings, not the log volume. Returns the matched events and
    the number of lines in the window per file."""
    events, counts = [], {}
    directory = root / "var/log/sssd"
    files = sorted(directory.glob("*.log*")) if directory.is_dir() else []
    for path in files:
        info = path.stat()
        # A file last written before the window holds nothing in it, which skips most rotated logs.
        if datetime.datetime.fromtimestamp(info.st_mtime, UTC) < since:
            continue
        name = str(path.relative_to(root))
        source = re.sub(r"\.log.*$", "", path.name)
        count, previous, base = 0, None, 0
        progress = Progress(f"/{name}", info.st_size)
        offsets = keyword_offsets(path)
        for block, done in chunks(path):
            last = stamp_before(block, len(block), previous)
            if last is not None and last >= since:
                offset = window_start(block, since, previous) if previous is None or previous < since else 0
                count += block.count(b"\n", offset)
                if offsets is None:
                    starts = keyword_starts(block, offset)
                else:
                    first = bisect.bisect_left(offsets, base + offset)
                    starts = [o - base for o in offsets[first:bisect.bisect_left(offsets, base + len(block))]]
                events += scan_block(block, starts, source, previous)
            previous = last
            base += len(block)
            progress.update(done)
        progress.close()
        counts[name] = count
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
                count += 1
                event = classify(Event(when, match.group(2).strip(), match.group(3).strip()))
                if event.keys:
                    events.append(event)
        counts[str(path.relative_to(root))] = count
    return events, counts


# --- Configuration facts --------------------------------------------------------------------------------------

def sssctl_check(root):
    """Ask the installed SSSD to validate its configuration: (issues, exit code, output), or None without sssctl.
    A nonzero exit with no issues listed is a failed check, not a verdict on the configuration."""
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
    return issues, result.returncode, result


def domains_of(config):
    domains = [d.strip() for d in config.get("sssd", "domains", fallback="").split(",") if d.strip()]
    return domains or [s.split("/", 1)[1] for s in config.sections() if s.startswith("domain/")]


def pam_service_stack(root, service):
    """(bypass, has pam_sss) for a PAM service's auth stack, or None when the stack is unknown. PAM falls back to
    /etc/pam.d/other for a service without its own file."""
    name = service if (root / "etc/pam.d" / service).is_file() else "other"
    if not (root / "etc/pam.d" / name).is_file():
        return None
    stack = [inspector.parse_pam_line(line) for line in inspector.pam_auth_lines(root, name)]
    modules = [module for _control, module in stack]
    if "pam_sss" not in modules:
        return False, False
    sss = modules.index("pam_sss")
    krb5 = modules.index("pam_krb5") if "pam_krb5" in modules[:sss] else None
    return krb5 is not None and inspector.success_skips(stack[krb5][0], krb5, sss), True


def config_facts(root):
    """What the configuration says, and whether SSSD would accept it: valid, invalid, unknown, or absent.
    doubts are (level, message) results that leave the configuration's effect uncertain: an unreadable file or a
    failed probe. They turn configuration-based causes into hypotheses."""
    facts = {"state": "unknown", "reasons": [], "confirmed": False, "kerberos": [], "present": False,
             "platform": [], "not_checked": [], "accounts": inspector.read_accounts(root), "doubts": [],
             "domains": [], "realms": {}, "cache_off": [], "pam_bypass": False, "pam_sss": True, "root": root}
    config = identity = accounts = None
    try:
        config, files, identity, _source, accounts, findings = inspector.check_config(root)
        facts["present"] = bool(files) or bool(config.unreadable)
        facts["state"] = "valid" if facts["present"] else "absent"
        facts["reasons"] = [message for level, message in findings if level == "warning"]
        facts["doubts"] = [(level, message) for level, message in findings if level in inspector.DOUBTS]
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
            issues, code, result = checked
            if issues:
                facts["state"] = "invalid"
                facts["reasons"].append(f"sssctl config-check reported {len(issues)} problem(s): "
                                        + "; ".join(issues[:3]))
            elif code != 0:
                facts["doubts"].append(("failed", f"{inspector.probe_failure('sssctl config-check', result)}; "
                                        "the configuration was not validated"))
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
        facts["kerberos"] = [("unchecked", f"Kerberos files ({exc.strerror or exc})")]
    if config is not None and facts["state"] == "valid":
        domains = facts["domains"] = domains_of(config)
        for d in domains:
            section = f"domain/{d}"
            realm = config.get(section, "krb5_realm", fallback="") or config.get(section, "ad_domain", fallback="")
            facts["realms"][(realm.strip() or d).lower()] = d
        facts["cache_off"] = [d for d in domains
                              if config.get(f"domain/{d}", "cache_credentials", fallback="false").strip().lower()
                              not in inspector.TRUE]
    try:
        stack = pam_service_stack(root, "gdm-password")
        if stack is None and (root / "etc/pam.d/common-auth").is_file():
            stack = pam_service_stack(root, "common-auth")
    except OSError:
        return facts
    if stack is not None:
        facts["pam_bypass"], facts["pam_sss"] = stack
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
    """The start of the boot that when falls in; boots is sorted."""
    index = bisect.bisect_right(boots, when)
    return boots[index - 1] if index else None


def vpn_timeline(found, boots):
    """Per boot: its VPN connects and disconnects as sorted (time, key) pairs, and its last connect."""
    timeline = {}
    for key in ("vpn-up", "vpn-down"):
        for e in found.get(key, []):
            timeline.setdefault(boot_of(e.when, boots), ([], []))[0].append((e.when, key))
    for changes, last_up in timeline.values():
        changes.sort()
        last_up.append(max([t for t, key in changes if key == "vpn-up"], default=None))
    return timeline


def vpn_down_until_later(when, timeline, boots):
    """Whether the VPN was not up at this time but connected later in the same boot."""
    changes, last_up = timeline.get(boot_of(when, boots), ([], [None]))
    later_up = last_up[0] is not None and last_up[0] > when
    # Keys sort below "~", so this counts the changes at or before when.
    before = bisect.bisect_right(changes, (when, "~"))
    return later_up and (not before or changes[before - 1][1] == "vpn-down")


def offline_failures(found, boots, facts):
    """Failed domain logins with evidence that SSSD was offline, as (event, certain) pairs; PAM result 9 alone
    does not prove it. Only an unreachable line from the failure's own domain makes it certain. Evidence that
    names no domain, or VPN timing, only suggests it when several domains are configured; evidence from another
    domain does not count."""
    domains, realms = facts["domains"], facts["realms"]
    unreachable = {}
    for key in UNREACHABLE:
        for e in found.get(key, []):
            unreachable.setdefault(failure_context(e, domains, realms)[2], []).append(e.when)
    for times in unreachable.values():
        times.sort()
    failures = [(event, True) for event in found.get("no-cached-password", [])]
    timeline = vpn_timeline(found, boots)
    for event in found.get("pam-authinfo-unavail", []):
        domain = failure_context(event, domains, realms)[2]
        # The window runs from 10 minutes before to 2 minutes after, clipped to the failure's own boot.
        boot = boot_of(event.when, boots)
        later_boots = [b for b in boots if b > event.when]
        low = max([event.when - datetime.timedelta(minutes=10)] + ([boot] if boot else []))
        high = event.when + datetime.timedelta(minutes=2)
        near = [where for where, times in unreachable.items()
                if bisect.bisect_left(times, low) < (bisect.bisect_left(times, later_boots[0])
                                                     if later_boots and later_boots[0] <= high
                                                     else bisect.bisect_right(times, high))]
        before_vpn = vpn_down_until_later(event.when, timeline, boots)
        if domain is not None and domain in near:
            failures.append((event, True))
        elif before_vpn and len(domains) <= 1:
            # With one domain, the VPN timing concerns that domain.
            failures.append((event, True))
        elif None in near or (domain is None and near) or before_vpn:
            failures.append((event, False))
    return sorted(failures, key=lambda pair: pair[0].when)


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
    onlines.sort()
    episodes = []
    for up in ups:
        until = min([t for t in downs + ups if t > up], default=up + datetime.timedelta(minutes=30))
        # A reboot ends the connection even when no disconnect was logged.
        until = min([until, up + datetime.timedelta(minutes=30)] + [b for b in boots if b > up])
        first = bisect.bisect_left(failures, up + datetime.timedelta(seconds=90))
        if first < len(failures) and failures[first] < until:
            late = failures[first]
            if bisect.bisect_right(onlines, late) == bisect.bisect_left(onlines, up):
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
        say("unchecked", f"the SSSD configuration: {'; '.join(facts['reasons'])}. The judgements below do not rely "
            "on sssd.conf")
    elif facts["confirmed"]:
        say("ok", "sssctl config-check accepts the SSSD configuration")
    for level, message in facts["doubts"]:
        judged = True
        say(level, message)
    for level, message in facts["kerberos"]:
        if level in ("warning",) + inspector.DOUBTS:
            judged = True
            say(level, f"Kerberos: {message}")
    for title, level, message in facts["platform"]:
        if level in ("warning", "failed") and message not in facts["reasons"]:
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
            name = result.group(3) if result else (re.search(r"\buser=(\S+@\S+)", event.text) or [None, None])[1]
            if name and "@" in name:
                domain_users.add(name)
    clashes = sorted(u for u in domain_users
                     if u.split("@")[0] in accounts[0] and accounts[0][u.split("@")[0]][0] >= 1000)
    for user in clashes:
        say("warning", f"the local account {user.split('@')[0]} shares its name with the domain user {user}; with "
            "use_fully_qualified_names off, nsswitch order decides which one a short-name login gets")
    return bool(clashes)


REALM = re.compile(r"\brealm ['\"]?([A-Za-z0-9.-]+)", re.I)


def failure_context(event, domains, realms=None):
    """(user, PAM service, domain) of an event, each None when the logs do not say. A domain is known from the
    SSSD backend that logged it, a Kerberos realm it names, a qualified user name, or a single configured domain,
    whose trusted subdomains share its settings."""
    result = PAM_RESULT.search(event.text)
    user = result.group(3) if result else None
    service = (result.group(1) or None) if result else None
    backend = BACKEND.search(event.text)
    hint = backend.group(1) if backend else None
    if not hint and event.source.startswith("sssd_") and event.source not in RESPONDERS:
        hint = event.source[5:]
    if not hint and user and "@" in user:
        hint = user.rsplit("@", 1)[1]
    realm = REALM.search(event.text)
    if not hint and realm:
        hint = (realms or {}).get(realm.group(1).lower(), realm.group(1))
    by_name = {d.lower(): d for d in domains}
    domain = by_name.get((hint or "").lower())
    if domain is None and len(domains) == 1:
        domain = domains[0]
    return user, service, domain


def describe(failures):
    """'2 failed offline logins: alice@corp.example via gdm-password' with unknown parts left out."""
    who = sorted({(user or "an unnamed user") + (f" via {service}" if service else "")
                  for user, service, _event in failures})
    count = len(failures)
    return f"{count} failed offline login{'s' if count > 1 else ''}: {', '.join(who)}"


def explain_offline(offline, facts, krb5_logins):
    """Tie each offline failure to the configuration of its own domain and PAM service. A cause is stated only
    when the failure's context selects it; otherwise the candidate settings are printed as a hypothesis.
    Returns the failures no configuration explains."""
    root, domains = facts["root"], facts["domains"]
    contexts = [(event, *failure_context(event, domains, facts["realms"]), certain) for event, certain in offline]
    # An SSSD-side line without a PAM service duplicates a PAM failure of the same domain logged within two
    # minutes; one from another or an unknown domain is a separate failure.
    with_service = {}
    for event, _user, service, domain, _certain in contexts:
        if service and domain:
            with_service.setdefault(domain, []).append(event.when)
    for times in with_service.values():
        times.sort()

    def duplicate(event, domain):
        times = with_service.get(domain, [])
        index = bisect.bisect_left(times, event.when - datetime.timedelta(seconds=120))
        return index < len(times) and times[index] <= event.when + datetime.timedelta(seconds=120)

    contexts = [c for c in contexts if c[2] or not duplicate(c[0], c[3])]
    stacks = {}

    def stack_of(service):
        if service not in stacks:
            stacks[service] = pam_service_stack(root, service)
        return stacks[service]

    groups = {}
    for event, user, service, domain, certain in contexts:
        groups.setdefault((domain, service, certain), []).append((user, service, event))
    named = {service for _event, _user, service, _domain, _certain in contexts if service}
    named |= {name for name in platform.PAM_SERVICES if (root / "etc/pam.d" / name).is_file()}
    bypassing = sorted(name for name in named if (stack_of(name) or (False,))[0])

    results = []

    def cause(text, certain):
        if not certain:
            results.append(("possible", text + "; whether SSSD was offline for that domain is not logged, only "
                            "VPN timing or unreachable lines that name no domain, so this is a hypothesis"))
        elif facts["doubts"]:
            results.append(("possible", text + "; not confirmed, because the configuration could not be fully "
                            "checked (above)"))
        else:
            results.append(("warning", "cause: " + text))

    unexplained = []
    for (domain, service, certain), failures in sorted(groups.items(), key=lambda item: tuple(map(str, item[0]))):
        stack = stack_of(service) if service else None
        if domain and domain in facts["cache_off"]:
            cause(f"cache_credentials is off for {domain}, so SSSD never stores a password and every offline login "
                  f"to it fails ({describe(failures)}). Set cache_credentials = True in [domain/{domain}], restart "
                  "sssd, and log in once with the VPN up", certain)
        elif stack and stack[0]:
            cause(f"in {service}, pam_krb5 succeeds before pam_sss and skips it, so SSSD never sees the password "
                  f"({describe(failures)}"
                  + (f"; pam_krb5 accepted {len(krb5_logins)} login(s) in this window" if krb5_logins else "")
                  + "). Remove libpam-krb5 and let SSSD obtain tickets", certain)
        else:
            candidates = []
            if domain is None and facts["cache_off"]:
                candidates.append(f"cache_credentials is off for {', '.join(facts['cache_off'])}")
            if (service is None or stack is None) and bypassing:
                candidates.append(f"pam_krb5 skips pam_sss in {', '.join(bypassing)}")
            if candidates:
                missing = [what for what, known in (("domain", domain), ("PAM stack", stack)) if known is None]
                results.append(("possible", f"{describe(failures)}. The {' and '.join(missing)} of these logins "
                                "cannot be determined, so the configuration to blame is a hypothesis: "
                                + "; ".join(candidates)))
            else:
                unexplained += failures
    # Confirmed causes first, then hypotheses.
    for level, text in sorted(results, key=lambda result: result[0] != "warning"):
        say(level, text)
    return unexplained


def assess(found, facts, sssd_lines, offline):
    print("Assessment:")
    judged = assess_config(facts)
    sss_logins = found.get("sss-login", [])
    krb5_logins = found.get("krb5-login", [])
    if offline:
        judged = True
        unexplained = explain_offline(offline, facts, krb5_logins)
        if unexplained:
            who = f"{describe(unexplained)}, which no setting above explains"
            if krb5_logins and not sss_logins:
                say("possible", f"{who}. pam_krb5 accepted {len(krb5_logins)} login(s) and pam_sss none, so SSSD "
                    "may never have seen a password to cache. Check the PAM stack with dotconfig creds status")
            elif not sss_logins:
                say("info", f"{who}. No online login through pam_sss is logged in this window, though a password "
                    "cached earlier may still exist. If dotconfig creds status shows no cached password, log in "
                    "once with the VPN up; if it shows one, compare when it was stored with these failures")
            else:
                say("info", f"{who}. pam_sss accepted online logins (last at {stamp(sss_logins[-1].when)}) yet "
                    "offline login still found no usable password. Compare the user names, and check dotconfig "
                    "creds status for when the password was stored")
    offline_events = {id(event) for event, _certain in offline}
    online_nine = [e for e in found.get("pam-authinfo-unavail", []) if id(e) not in offline_events]
    if online_nine:
        judged = True
        who = sorted({failure_context(e, facts["domains"], facts["realms"])[0] or "an unnamed user"
                      for e in online_nine})
        say("info", f"pam_sss returned PAM result 9 {len(online_nine)} time(s) with no sign that SSSD was offline "
            f"for that user's domain ({', '.join(who)}), so the cache is not implicated; the SSSD lines around "
            "those times give the cause")
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
    auth_entries = journal_sssd = 0
    boots = []
    if journal is None:
        say("info", "journalctl not found; only log files are searched")
    else:
        journal_events, boots, auth_entries, failures = journal
        events += journal_events
        journal_sssd = sum(1 for e in journal_events if e.source.startswith("sssd"))
        print(f"  journal: {len(journal_events)} entries (SSSD units, auth facility, VPN)")
        for failure in failures:
            say("failed", f"{failure}; entries it would have returned are missing from this report")
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
        for key in (event if event.classified else classify(event)).keys:
            found.setdefault(key, []).append(event)
    print_findings(found, args.examples)

    facts = config_facts(root)
    sssd_lines = sum(sssd_counts.values()) + journal_sssd
    offline = offline_failures(found, boots, facts)
    judged = assess(found, facts, sssd_lines, offline)
    judged = assess_boots(found, boots, [event for event, _certain in offline]) or judged
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
