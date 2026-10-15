#!/usr/bin/env python3
"""Ubuntu 26.04 and SSSD 2.12 platform checks for dotconfig creds: packages, helpers, state, PAM, Kerberos.

Every check reads the inspected root's own files, so fixtures can exercise it. Checks that need the running
system (systemd state, NTP, mounts) run only against / and otherwise land in the "not checked" list. Nothing
here prints key material, password hashes, PINs, or configuration values that may be private.
"""

import importlib.util
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path

_spec = importlib.util.spec_from_file_location("credentials_inspect", Path(__file__).with_name("credentials-inspect.py"))
inspector = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(inspector)
shown, allows, EVERYONE = inspector.shown, inspector.allows, inspector.EVERYONE

# --- Packages -------------------------------------------------------------------------------------------------

PACKAGES = ("sssd", "sssd-common", "sssd-ad", "sssd-ad-common", "sssd-krb5", "sssd-krb5-common", "sssd-tools",
            "sssd-kcm", "libpam-sss", "libnss-sss", "libsss-certmap0", "libkrb5-3", "krb5-user", "krb5-config",
            "libpam-krb5", "apparmor")
SSSD_SOURCE = ("sssd", "sssd-common", "sssd-ad", "sssd-ad-common", "sssd-krb5", "sssd-krb5-common", "sssd-tools",
               "sssd-kcm", "libpam-sss", "libnss-sss", "libsss-certmap0")
# Ubuntu fixes that the upstream version alone does not reveal.
UBUNTU_FIXES = (
    ("2.12.0-1ubuntu5.2", "helper capabilities are set before the daemon restarts (LP #2155002)"),
    ("2.12.0-1ubuntu5.3", "the PAM responder no longer crashes on slow smartcards (USN-8672-1)"),
)


def read_dpkg_status(root):
    """Map package name to (version, status) from the root's dpkg database, or None without one."""
    status = root / "var/lib/dpkg/status"
    if not status.is_file():
        return None
    packages = {}
    for paragraph in status.read_text(errors="replace").split("\n\n"):
        fields = dict(re.findall(r"^([\w-]+):\s*(.*)$", paragraph, re.M))
        if fields.get("Package") in PACKAGES:
            packages[fields["Package"]] = (fields.get("Version", "?"), fields.get("Status", "?"))
    return packages


def _order(char):
    if not char or char.isdigit():
        return 0
    if char == "~":
        return -1
    return ord(char) if char.isalpha() else ord(char) + 256


def _compare_part(a, b):
    """dpkg's verrevcmp for one upstream or revision string."""
    i = j = 0
    while i < len(a) or j < len(b):
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac, bc = _order(a[i] if i < len(a) else ""), _order(b[j] if j < len(b) else "")
            if ac != bc:
                return ac - bc
            i, j = i + 1, j + 1
        start_i, start_j = i, j
        while i < len(a) and a[i].isdigit():
            i += 1
        while j < len(b) and b[j].isdigit():
            j += 1
        diff = int(a[start_i:i] or 0) - int(b[start_j:j] or 0)
        if diff:
            return diff
    return 0


def compare_versions(a, b):
    """Negative, zero, or positive as Debian version a sorts before, equal to, or after b."""
    def split(version):
        epoch, _, rest = version.rpartition(":") if ":" in version else ("0", "", version)
        upstream, _, revision = rest.rpartition("-") if "-" in rest else (rest, "", "0")
        return int(epoch or 0), upstream, revision
    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    return (ea - eb) or _compare_part(ua, ub) or _compare_part(ra, rb)


def package_findings(root):
    packages = read_dpkg_status(root)
    if packages is None:
        return [], ["installed package versions (no dpkg database)"]
    findings = []
    lines = [f"{name} {version}" for name, (version, _status) in sorted(packages.items())]
    findings.append(("info", "installed: " + (", ".join(lines) if lines else "no SSSD or Kerberos packages")))
    for name, (version, status) in sorted(packages.items()):
        if status.split()[-1:] != ["installed"] or not status.startswith("install"):
            findings.append(("warning", f"{name} is not fully installed ({status}); finish it with "
                             "sudo dpkg --configure -a before trusting other results"))
    versions = {packages[name][0] for name in SSSD_SOURCE if name in packages}
    if len(versions) > 1:
        findings.append(("warning", f"SSSD packages are at different versions ({', '.join(sorted(versions))}); "
                         "a partial upgrade mixes binaries and helpers"))
    common = packages.get("sssd-common", (None,))[0]
    if common and common.startswith("2.12.0-"):
        for fixed, what in UBUNTU_FIXES:
            if compare_versions(common, fixed) < 0:
                findings.append(("warning", f"sssd-common {common} predates {fixed}, where {what}; update it"))
    if "libpam-krb5" in packages:
        findings.append(("info", "libpam-krb5 is installed; see the PAM checks for whether it bypasses pam_sss"))
    return findings, []


# --- Service units and helpers --------------------------------------------------------------------------------

UNITS = ("sssd.service", "sssd-nss.socket", "sssd-pam.socket", "sssd-pam-priv.socket", "sssd-kcm.socket",
         "sssd-nss.service", "sssd-pam.service", "sssd-kcm.service")
HELPER_DIR = "usr/libexec/sssd"
# Capability numbers from linux/capability.h.
CAPS = {2: "cap_dac_read_search", 6: "cap_setgid", 7: "cap_setuid"}
ALL_CAPS = frozenset(f"cap_{name}" for name in (
    "chown dac_override dac_read_search fowner fsetid kill setgid setuid setpcap linux_immutable net_bind_service "
    "net_broadcast net_admin net_raw ipc_lock ipc_owner sys_module sys_rawio sys_chroot sys_ptrace sys_pacct "
    "sys_admin sys_boot sys_nice sys_resource sys_time sys_tty_config mknod lease audit_write audit_control "
    "setfcap mac_override mac_admin syslog wake_alarm block_suspend audit_read perfmon bpf checkpoint_restore"
).split())
HELPERS = {"krb5_child": {2, 6, 7}, "ldap_child": {2}, "sssd_pam": {2}}


def file_capabilities(path):
    """Permitted capability numbers from security.capability, None when unset, or 'unknown' when unreadable."""
    try:
        raw = os.getxattr(path, "security.capability")
    except AttributeError:
        return "unknown"
    except OSError as exc:
        return None if exc.errno in (61, 93) else "unknown"  # ENODATA, ENOATTR
    return parse_capabilities(raw)


def parse_capabilities(raw):
    """Decode a vfs_cap_data blob (revision 1, 2, or 3) into permitted capability numbers."""
    if len(raw) < 12:
        return set()
    _magic, low = struct.unpack_from("<II", raw)
    high = struct.unpack_from("<I", raw, 12)[0] if len(raw) >= 20 else 0
    mask = low | high << 32
    return {bit for bit in range(64) if mask >> bit & 1}


def fold_capability_set(values):
    """CapabilityBoundingSet as systemd builds it: the first assignment or an empty one replaces the set, later
    ones are OR-ed in, and ~ inverts that one assignment's list."""
    state = set(ALL_CAPS)
    for value in values:
        invert = value.startswith("~")
        names = {name.lower() for name in value.lstrip("~").split()}
        current = set(ALL_CAPS) - names if invert else names
        if not current or state == ALL_CAPS:
            state = current
        else:
            state |= current
    return state


def hardening(root, live):
    """(NoNewPrivileges on, bounding set) for sssd.service, from systemd itself on a live system."""
    if live:
        result = run(["systemctl", "show", "-p", "NoNewPrivileges", "-p", "CapabilityBoundingSet", "sssd.service"])
        if result is not None and result.returncode == 0:
            props = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
            if "CapabilityBoundingSet" in props:
                return (props.get("NoNewPrivileges") == "yes",
                        {name.lower() for name in props["CapabilityBoundingSet"].split()})
    no_new = [v for v, _ in inspector.unit_values(root, "sssd.service", "NoNewPrivileges")]
    bounding = [v for v, _ in inspector.unit_values(root, "sssd.service", "CapabilityBoundingSet")]
    return bool(no_new) and no_new[-1].lower() in inspector.TRUE, fold_capability_set(bounding)


def service_findings(root, identity, accounts, live):
    findings, not_checked = [], []
    responders = {}
    for unit in UNITS[1:]:
        values = inspector.unit_values(root, unit, "User", "[Service]" if unit.endswith(".service") else "[Socket]")
        if values:
            responders[unit] = values[-1][0] or "root"
    main_user = identity.name if identity else None
    differing = {u: n for u, n in responders.items() if u.endswith(".service") and main_user and n != main_user}
    if differing:
        findings.append(("info", "responder services run as a different user than sssd.service: "
                         + ", ".join(f"{u} as {n}" for u, n in sorted(differing.items()))))
    if identity and not identity.root:
        no_new, allowed = hardening(root, live)
        if no_new:
            findings.append(("warning", "sssd.service sets NoNewPrivileges, so the helpers' file capabilities are "
                             "ignored and krb5_child cannot read the keytab or switch users"))
        missing = {CAPS[c] for caps in HELPERS.values() for c in caps} - allowed
        if missing:
            findings.append(("warning", f"sssd.service's CapabilityBoundingSet removes {', '.join(sorted(missing))}, "
                             "which the helpers need"))
        findings += helper_findings(root, identity, accounts, not_checked)
    elif identity:
        findings.append(("info", "SSSD runs as root, so helper capabilities are not needed"))
    else:
        not_checked.append("helper ownership and capabilities (the SSSD service user is unknown)")
    if live:
        findings += runtime_findings(not_checked)
    else:
        not_checked.append("systemd unit and socket state, sssd --version, NTP sync, and mount options "
                           "(live system only)")
    return findings, not_checked


def helper_findings(root, identity, accounts, not_checked):
    findings = []
    users, groups = accounts if accounts else ({}, {})
    expected_owner = users.get("root", (0,))[0]
    expected_group = groups.get(inspector.SSSD_ACCOUNT, (None,))[0]
    for name, needed in HELPERS.items():
        path = root / HELPER_DIR / name
        if not path.exists():
            findings.append(("info", f"{shown(root, path)} is missing"))
            continue
        st = path.stat()
        mode = st.st_mode & 0o7777
        if accounts and (st.st_uid != expected_owner or st.st_gid != expected_group or mode != 0o750):
            findings.append(("warning", f"{shown(root, path)} is {inspector.owner_name(accounts, st.st_uid, st.st_gid)}"
                             f" {mode:04o}; the package installs it as root:{inspector.SSSD_ACCOUNT} 0750. "
                             "Reinstall sssd-common and sssd-krb5-common rather than changing it by hand"))
        elif not allows(st, identity, 1):
            findings.append(("warning", f"the SSSD service user {identity.name} cannot run {shown(root, path)}"))
        caps = file_capabilities(path)
        if caps == "unknown":
            not_checked.append(f"file capabilities of {shown(root, path)}")
            continue
        missing = needed - (caps or set())
        if missing:
            findings.append(("warning", f"{shown(root, path)} lacks {', '.join(CAPS[c] for c in sorted(missing))}; "
                             "an interrupted upgrade or a copy without xattrs drops them. Reinstall sssd-common and "
                             "sssd-krb5-common; do not widen keytab access instead"))
    return findings


def run(command):
    if not shutil.which(command[0]):
        return None
    return subprocess.run(command, capture_output=True, text=True, check=False)


def runtime_findings(not_checked):
    findings = []
    result = run(["systemctl", "show", "-p", "Id,ActiveState,SubState,UnitFileState,User,DropInPaths", *UNITS])
    if result is None:
        not_checked.append("systemd unit state (no systemctl)")
    else:
        for block in result.stdout.strip().split("\n\n"):
            props = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
            if props.get("UnitFileState") in ("", None) and props.get("ActiveState") == "inactive":
                continue
            unit = props.get("Id", "?")
            state = f"{props.get('ActiveState')}/{props.get('SubState')}"
            extra = f", drop-ins {props['DropInPaths']}" if props.get("DropInPaths") else ""
            level = "warning" if props.get("ActiveState") == "failed" else "info"
            findings.append((level, f"{unit}: {state}, user {props.get('User') or 'root'}{extra}"))
    result = run(["sssd", "--version"])
    if result is not None:
        findings.append(("info", f"sssd --version: {result.stdout.strip() or result.stderr.strip()}"))
    result = run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    if result is None:
        not_checked.append("NTP sync (no timedatectl)")
    elif result.stdout.strip() == "no":
        findings.append(("warning", "the clock is not NTP-synchronized; Kerberos fails beyond 5 minutes of skew"))
    try:
        mounts = [line.split() for line in Path("/proc/self/mounts").read_text().splitlines()]
        holding = [m for m in mounts if ("/" + HELPER_DIR + "/").startswith(m[1].rstrip("/") + "/")]
        best = max(holding, key=lambda m: len(m[1]))
        if "nosuid" in best[3].split(","):
            findings.append(("warning", f"{best[1]} is mounted nosuid, so the helpers' file capabilities are ignored"))
    except (OSError, ValueError, IndexError):
        not_checked.append("mount options for the SSSD helpers")
    return findings


# --- State and runtime directories ----------------------------------------------------------------------------
# (path, who must reach it, whether others must be kept out, why). The service user needs read, write and search.
STATE_DIRS = (
    ("var/lib/sss/db", "service", True, "holds cached password hashes"),
    ("var/lib/sss/secrets", "service", True, "holds stored secrets"),
    ("var/lib/sss/mc", "everyone", False, "memory caches every process reads for fast lookups"),
    ("var/lib/sss/pipes", "everyone", False, "responder sockets every process connects to"),
    ("var/lib/sss/pipes/private", "service", True, "privileged sockets"),
    ("var/lib/sss/pubconf", "everyone", False, "Kerberos snippets and KDC hints for every client"),
    ("var/lib/sss/gpo_cache", "service", True, "cached GPO rules for offline access checks"),
    ("run/sssd", "service", False, "runtime state"),
    ("var/log/sssd", "service", False, "logs"),
)


def state_findings(root, identity):
    findings = []
    for rel, reach, private, why in STATE_DIRS:
        path = root / rel
        if not path.is_dir():
            if rel == "var/lib/sss/pipes":
                findings.append(("info", f"/{rel} is missing ({why}); SSSD has not run or was purged"))
            continue
        st = path.stat()
        if st.st_mode & 0o002:
            findings.append(("warning", f"/{rel} is writable by everyone ({why})"))
        if private and st.st_mode & 0o007:
            findings.append(("warning", f"/{rel} is open to other users but {why}; remove their access with "
                             f"chmod o= /{rel}, not a recursive chmod"))
        if reach == "everyone" and not allows(st, EVERYONE, 1):
            findings.append(("warning", f"ordinary users cannot enter /{rel}, the {why}"))
        if identity and not identity.root and not allows(st, identity, 7):
            findings.append(("warning", f"the SSSD service user {identity.name} cannot write to /{rel} ({why})"))
    return findings


# --- Configuration hygiene ------------------------------------------------------------------------------------

SECTIONS = ("sssd", "nss", "pam", "sudo", "autofs", "ssh", "pac", "ifp", "kcm", "session_recording")
SECTION_PREFIXES = ("domain/", "application/", "prompting/", "certmap/")
REMOVED_OPTIONS = {
    "ipa_enable_dns_sites": "removed in SSSD 2.11",
    "ad_allow_remote_domain_local_groups": "removed in SSSD 2.11",
    "ipa_dyndns_update": "a legacy IPA dynamic DNS option; use dyndns_update",
    "ipa_dyndns_ttl": "a legacy IPA dynamic DNS option; use dyndns_ttl",
    "ipa_dyndns_iface": "a legacy IPA dynamic DNS option; use dyndns_iface",
}


def hygiene_findings(root, config):
    """Stale options, unknown sections, inline comments, and domain lists; values are never printed."""
    findings = []
    listed = [d.strip() for d in config.get("sssd", "domains", fallback="").split(",") if d.strip()]
    for section in config.sections():
        if section not in SECTIONS and not section.startswith(SECTION_PREFIXES):
            findings.append(("warning", f"[{section}] is not an SSSD section; check its spelling"))
        if section.startswith("domain/") and listed and section[7:] not in listed:
            findings.append(("info", f"[{section}] is not in [sssd] domains, so SSSD ignores it"))
        for key in config.options(section):
            source = getattr(config, "origins", {}).get((section, key), "sssd.conf")
            if key in REMOVED_OPTIONS:
                findings.append(("warning", f"{key} in [{section}] ({source}) is {REMOVED_OPTIONS[key]}"))
            if re.search(r"\s[#;]", config.get(section, key, raw=True)):
                findings.append(("warning", f"{key} in [{section}] ({source}) has an inline comment, which SSSD "
                                 "reads as part of the value; move the comment to its own line"))
    for domain in listed:
        if not config.has_section(f"domain/{domain}"):
            findings.append(("warning", f"[sssd] domains lists {domain}, which has no [domain/{domain}] section"))
        elif config.get(f"domain/{domain}", "id_provider", fallback="").strip() == "files":
            findings.append(("warning", f"{domain} uses id_provider = files, which SSSD 2.11 removed; local users "
                             "come from NSS files directly"))
    return findings


def invalid_reasons(findings):
    """Hygiene problems that stop SSSD from loading a domain, as opposed to ones it tolerates."""
    return [m for level, m in findings if level == "warning" and ("no [domain/" in m or "id_provider = files" in m)]


# --- Kerberos ticket caches, crypto, and keytab ---------------------------------------------------------------

def krb5_relation(root, name):
    """The first value of a [libdefaults] relation across krb5.conf and its includes, as MIT reads it."""
    conf = root / "etc/krb5.conf"
    files = [conf] + [p for p, _parent, is_dir in inspector.krb5_includes(root, conf, set()) if not is_dir]
    for path in files:
        if not path.is_file():
            continue
        section = ""
        for line in path.read_text(errors="replace").splitlines():
            line = line.split("#", 1)[0].strip()
            if line.startswith("["):
                section = line
            elif section == "[libdefaults]" and re.match(rf"{name}\s*=", line):
                return line.split("=", 1)[1].strip(), shown(root, path)
    return None, None


def ccache_findings(root, config, domains, live):
    findings = []
    default, source = krb5_relation(root, "default_ccache_name")
    templates = []
    for domain in domains or [None]:
        own = config.get(f"domain/{domain}", "krb5_ccname_template", fallback="").strip() if domain else ""
        if own:
            templates.append((own, f"[domain/{domain}] krb5_ccname_template"))
        elif default:
            templates.append((default, f"default_ccache_name in {source}"))
        else:
            templates.append(("FILE:/tmp/krb5cc_%U", "the SSSD default"))
    for template, origin in dict(reversed(templates)).items():
        kind, _, location = template.partition(":") if re.match(r"^[A-Z]+:", template) else ("FILE", "", template)
        if kind == "KCM":
            if not inspector.unit_files(root, "sssd-kcm.socket"):
                findings.append(("warning", f"tickets go to KCM ({origin}) but sssd-kcm.socket is not installed"))
            else:
                findings.append(("info", f"tickets go to KCM ({origin}); sssd-kcm stores them"))
            continue
        if kind not in ("FILE", "DIR"):
            findings.append(("info", f"tickets go to a {kind} cache ({origin})"))
            continue
        # A FILE cache is created in its directory; a DIR collection is itself created inside its parent.
        parent = os.path.dirname(location.rstrip("/"))
        if "%" in parent:
            note = "systemd-logind creates it at login" if parent.startswith("/run/user/") else \
                "each user's copy must already exist"
            findings.append(("info", f"tickets go to {template} ({origin}); SSSD 2.11+ no longer creates missing "
                             f"parent directories, and {note}"))
            continue
        path = root / parent.lstrip("/")
        if not path.is_dir():
            findings.append(("warning", f"tickets go to {template} ({origin}) but {parent} does not exist, and SSSD "
                             "2.11+ no longer creates it"))
        elif not allows(path.stat(), EVERYONE, 3):
            findings.append(("warning", f"users cannot create ticket caches in {parent} ({origin})"))
    weak, weak_source = krb5_relation(root, "allow_weak_crypto")
    if weak and weak.lower() in inspector.TRUE:
        findings.append(("info", f"allow_weak_crypto is on in {weak_source}; prefer AES keys over re-enabling "
                         "RC4 or 3DES"))
    return findings


ENCTYPES = {1: "des-cbc-crc", 3: "des-cbc-md5", 16: "des3-cbc-sha1", 17: "aes128-cts-hmac-sha1-96",
            18: "aes256-cts-hmac-sha1-96", 19: "aes128-cts-hmac-sha256-128", 20: "aes256-cts-hmac-sha384-192",
            23: "rc4-hmac", 24: "rc4-hmac-exp"}
WEAK = {1, 3, 16, 23, 24}


def keytab_entries(data):
    """(principal, kvno, enctype) for each keytab entry. Key bytes are skipped, never kept."""
    if len(data) < 2 or data[0] != 5 or data[1] not in (1, 2):
        raise ValueError("not a keytab")
    order = ">" if data[1] == 2 else "<"
    entries, offset = [], 2
    while offset + 4 <= len(data):
        size = struct.unpack_from(order + "i", data, offset)[0]
        offset += 4
        if size <= 0:
            offset += -size
            continue
        entry, offset = data[offset:offset + size], offset + size
        pos = 0
        count = struct.unpack_from(order + "H", entry, pos)[0] - (1 if data[1] == 1 else 0)
        pos += 2
        names = []
        for _ in range(count + 1):
            length = struct.unpack_from(order + "H", entry, pos)[0]
            names.append(entry[pos + 2:pos + 2 + length].decode(errors="replace"))
            pos += 2 + length
        pos += 4 if data[1] == 2 else 0  # name type
        _timestamp, kvno, enctype = struct.unpack_from(order + "IBH", entry, pos)
        pos += 7
        if size - (pos + 2 + struct.unpack_from(order + "H", entry, pos)[0]) >= 4:
            kvno = struct.unpack_from(order + "I", entry, size - 4)[0] or kvno
        realm, components = names[0], names[1:]
        entries.append((f"{'/'.join(components)}@{realm}", kvno, enctype))
    return entries


def keytab_findings(root):
    path = root / "etc/krb5.keytab"
    if not path.is_file():
        return []
    try:
        entries = keytab_entries(path.read_bytes())
    except (ValueError, struct.error, IndexError):
        return [("warning", "/etc/krb5.keytab is not a readable keytab; rejoin the domain or refresh it with adcli")]
    if not entries:
        return [("warning", "/etc/krb5.keytab has no keys")]
    types = sorted({e[2] for e in entries})
    names = ", ".join(ENCTYPES.get(t, f"enctype {t}") for t in types)
    principals = len({e[0] for e in entries})
    findings = [("info", f"keytab: {len(entries)} key(s) for {principals} principal(s); types {names}")]
    if all(t in WEAK for t in types):
        findings.append(("warning", "the keytab has only RC4, DES or 3DES keys, which Ubuntu 26.04's Kerberos no "
                         "longer allows by default; have the domain issue AES keys (for example adcli update "
                         "--computer-password-lifetime=0 after enabling AES on the computer account) rather than "
                         "re-enabling weak crypto"))
    elif any(t in WEAK for t in types):
        findings.append(("info", "the keytab also has RC4 or 3DES keys; they are unused unless weak crypto is "
                         "re-enabled"))
    return findings


# --- PAM services ---------------------------------------------------------------------------------------------

PAM_SERVICES = ("gdm-password", "gdm-smartcard", "login", "sshd", "su", "sudo")


def pam_stack(root, name, stage, seen=None):
    """Module names a service runs for one stage, following @include, include, and substack."""
    seen = seen if seen is not None else set()
    path = root / "etc/pam.d" / name
    if (name, stage) in seen or not path.is_file():
        return []
    seen.add((name, stage))
    modules = []
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("@include"):
            modules += pam_stack(root, line.split()[1], stage, seen)
            continue
        match = re.match(r"-?(\w+)\s+(\[[^\]]*\]|\S+)\s+(\S+)", line)
        if not match or match.group(1) != stage:
            continue
        if match.group(2) in ("include", "substack"):
            modules += pam_stack(root, match.group(3), stage, seen)
        else:
            module = re.search(r"(pam_\w+)\.so", match.group(3))
            modules.append(module.group(1) if module else match.group(3))
    return modules


def pam_findings(root):
    findings = []
    for service in PAM_SERVICES:
        if not (root / "etc/pam.d" / service).is_file():
            continue
        stages = {stage: pam_stack(root, service, stage) for stage in ("auth", "account", "session")}
        summary = "; ".join(f"{stage} " + (", ".join(m for m in mods if m in ("pam_sss", "pam_krb5", "pam_unix",
                                                                                "pam_mkhomedir")) or "none")
                            for stage, mods in stages.items())
        findings.append(("info", f"{service}: {summary}"))
        if "pam_sss" in stages["auth"] and "pam_sss" not in stages["account"]:
            findings.append(("warning", f"{service} checks domain passwords but not domain access rules: pam_sss "
                             "is missing from its account stage"))
    return findings


# --- Smartcard ------------------------------------------------------------------------------------------------

def smartcard_findings(root, config, identity, packages):
    if config.get("pam", "pam_cert_auth", fallback="false").strip().lower() not in inspector.TRUE:
        return [("info", "smartcard login is off (pam_cert_auth)")]
    findings = []
    ca_db = config.get("pam", "pam_cert_db_path", fallback="/etc/sssd/pki/sssd_auth_ca_db.pem").strip()
    path = root / ca_db.lstrip("/")
    if not path.is_file():
        findings.append(("warning", f"pam_cert_auth is on but the CA bundle {ca_db} is missing"))
    elif identity and not allows(path.stat(), identity, 4):
        findings.append(("warning", f"the SSSD service user {identity.name} cannot read the CA bundle {ca_db}"))
    for module in sorted((root / "etc/pkcs11/modules").glob("*.module")):
        if identity and not allows(module.stat(), identity, 4):
            findings.append(("warning", f"the SSSD service user {identity.name} cannot read {shown(root, module)}"))
        target = re.search(r"^module:\s*(\S+)", module.read_text(errors="replace"), re.M)
        if target and target.group(1).startswith("/") and not (root / target.group(1).lstrip("/")).exists():
            findings.append(("warning", f"{shown(root, module)} points at {target.group(1)}, which is missing"))
    if not (root / "etc/pam.d/gdm-smartcard").is_file():
        findings.append(("info", "no gdm-smartcard PAM service; the login screen offers no smartcard login"))
    version = (packages or {}).get("sssd-common", (None,))[0]
    if version and version.startswith("2.12.0-") and compare_versions(version, "2.12.0-1ubuntu5.3") < 0:
        findings.append(("warning", "this sssd-common predates the slow-smartcard PAM responder crash fix "
                         "(2.12.0-1ubuntu5.3, USN-8672-1)"))
    findings.append(("info", "a smartcard failure does not mean password login fails; check both separately"))
    return findings


# --- Entry point ----------------------------------------------------------------------------------------------

def platform_report(root, config, domains, identity, accounts):
    """All platform checks as ordered (title, findings) sections, plus what could not be checked."""
    live = root == Path("/")
    packages_found, not_checked = package_findings(root)
    services, more = service_findings(root, identity, accounts, live)
    not_checked += more
    sections = [
        ("Packages", packages_found),
        ("Service and helpers", services),
        ("State directories", state_findings(root, identity)),
        ("Configuration hygiene", hygiene_findings(root, config) if config is not None else []),
        ("Kerberos caches and keys", (ccache_findings(root, config, domains, live) if config is not None else [])
         + keytab_findings(root)),
        ("PAM services", pam_findings(root)),
        ("Smartcard", smartcard_findings(root, config, identity, read_dpkg_status(root))
         if config is not None else []),
    ]
    if identity is not None and not identity.root:
        not_checked.append("AppArmor confinement (see dotconfig creds check-logs for denials)")
    return sections, not_checked
