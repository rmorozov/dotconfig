#!/usr/bin/env python3
"""Inspect or reset SSSD credential caches as root without printing secrets."""

import configparser
import datetime
import errno
import importlib.util
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Only settings that decide offline login are shown; bind passwords and similar values never are.
DOMAIN_KEYS = (
    "id_provider", "auth_provider", "access_provider", "cache_credentials",
    "krb5_store_password_if_offline", "account_cache_expiration", "entry_cache_timeout",
    "use_fully_qualified_names", "ad_gpo_access_control", "krb5_ccname_template",
)
PAM_KEYS = (
    "offline_credentials_expiration", "offline_failed_login_attempts",
    "offline_failed_login_delay", "pam_cert_auth", "pam_passkey_auth",
)
TRUE = ("true", "yes", "1", "on")
# Results are a confirmed problem (warning), a hypothesis (possible), evidence that could not be gathered
# (unchecked), or a probe that ran and failed (failed); info and ok carry no judgement.
LABELS = {"possible": "possible cause", "unchecked": "not checked", "failed": "check failed"}
DOUBTS = ("unchecked", "failed")
# Kerberos and SSSD never log passwords, but a debug line may quote a config value. A value may be quoted or
# contain spaces, so shown text hides the rest of the line after any sensitive assignment.
PRIVATE_VALUE = re.compile(r"(\b\w*(?:authtok|password|passwd|secret)\w*\s*=\s*)\S.*$", re.I)


def say(level, message):
    print(f"{LABELS.get(level, level)}: {message}")


def probe(command):
    """Run a read-only command; None when it is not installed."""
    if not shutil.which(command[0]):
        return None
    return subprocess.run(command, capture_output=True, text=True, check=False)


def probe_failure(name, result):
    """Why a probe failed, keeping its exit status and one sanitized line of its output."""
    if result is None:
        return f"{name} is not installed"
    lines = [line.strip() for line in (result.stderr + "\n" + result.stdout).splitlines() if line.strip()]
    detail = PRIVATE_VALUE.sub(r"\1<hidden>", lines[0])[:160] if lines else "no output"
    return f"{name} exited {result.returncode}: {detail}"


# --- File access ----------------------------------------------------------------------------------------------
# SSSD 2.12 on Ubuntu 26.04 runs as the sssd user and accepts root or sssd as a config file's owner and group,
# with no access for others. Users and groups are read from the inspected root's own files.
SSSD_ACCOUNT = "sssd"
ACL_XATTR = "system.posix_acl_access"


@dataclass
class Identity:
    name: str
    uid: int = -1
    gids: tuple = ()
    root: bool = False
    # False when read from unit files instead of systemd, which may apply more than this parser models.
    effective: bool = False


EVERYONE = Identity("ordinary users")


def read_accounts(root):
    """Map user names to (uid, gid) and group names to (gid, members), or None without /etc/passwd."""
    passwd, group = root / "etc/passwd", root / "etc/group"
    if not passwd.is_file():
        return None
    users, groups = {}, {}
    for line in passwd.read_text(errors="replace").splitlines():
        fields = line.split(":")
        if len(fields) >= 4 and fields[2].isdigit() and fields[3].isdigit():
            users.setdefault(fields[0], (int(fields[2]), int(fields[3])))
    for line in (group.read_text(errors="replace").splitlines() if group.is_file() else []):
        fields = line.split(":")
        if len(fields) >= 4 and fields[2].isdigit():
            groups.setdefault(fields[0], (int(fields[2]), [m for m in fields[3].split(",") if m]))
    return users, groups


UNIT_DIRS = ("etc/systemd/system", "run/systemd/system", "usr/lib/systemd/system", "lib/systemd/system")


def unit_files(root, unit):
    """The unit file systemd uses and its drop-ins, in the order systemd applies them."""
    units = [root / d / unit for d in UNIT_DIRS if (root / d / unit).is_file()]
    dropins = {}
    for d in reversed(UNIT_DIRS):
        for path in (root / d / f"{unit}.d").glob("*.conf"):
            dropins[path.name] = path
    return units[:1] + [dropins[name] for name in sorted(dropins)]


def unit_values(root, unit, key, section="[Service]"):
    """Every (value, source) a unit and its drop-ins assign to key, in order; an empty value resets lists."""
    values = []
    for path in unit_files(root, unit):
        current = ""
        for line in path.read_text(errors="replace").splitlines():
            line = line.strip()
            if line.startswith("["):
                current = line
            elif current == section and re.match(rf"{key}\s*=", line):
                values.append((line.split("=", 1)[1].strip(), shown(root, path)))
    return values


def unit_user(root):
    """The User= systemd gives sssd.service; empty means root."""
    values = unit_values(root, "sssd.service", "User")
    return values[-1] if values else ("", None)


# Properties that list items: each assignment appends, and an empty one resets the list.
LIST_PROPERTIES = ("SupplementaryGroups", "ReadWritePaths", "ReadOnlyPaths", "InaccessiblePaths", "StateDirectory",
                   "LogsDirectory", "RuntimeDirectory")


def unit_properties(root, names, live, unit="sssd.service"):
    """(properties, failure) for a unit: what systemctl show reports on a live system, otherwise the unit files
    folded by this parser, which approximates systemd. CapabilityBoundingSet stays a list of raw assignments;
    list properties are lists; others are the last value, empty when unset."""
    failure = None
    if live:
        result = probe(["systemctl", "show", unit] + [f"--property={name}" for name in names])
        if result is not None and result.returncode == 0:
            shown_props = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
            props = {}
            for name in names:
                value = shown_props.get(name, "")
                props[name] = [value] if name == "CapabilityBoundingSet" else \
                    value.split() if name in LIST_PROPERTIES else value
            return props, None
        failure = probe_failure(f"systemctl show {unit}", result)
    props = {}
    for name in names:
        values = [value for value, _source in unit_values(root, unit, name)]
        if name == "CapabilityBoundingSet":
            props[name] = values
        elif name in LIST_PROPERTIES:
            items = []
            for value in values:
                items = items + value.split() if value else []
            props[name] = items
        else:
            props[name] = values[-1] if values else ""
    return props, failure


def resolve_identity(user, group, supplementary, accounts):
    """The credentials systemd gives a service: User= (a name or number), Group= or the user's primary group,
    the groups listing the user (initgroups), and SupplementaryGroups=. None when any of them cannot be resolved."""
    if user in ("", "root", "0"):
        return Identity("root", 0, (0,), root=True)
    users, groups = accounts or ({}, {})
    by_uid = {}
    for name, (uid, _gid) in users.items():
        by_uid.setdefault(uid, name)

    def group_id(value):
        if value.isdigit():
            return int(value)
        return groups[value][0] if value in groups else None

    if user.isdigit():
        uid = int(user)
        name = by_uid.get(uid, user)
    elif user in users:
        name, uid = user, users[user][0]
    else:
        return None
    primary = group_id(group) if group else users[name][1] if name in users else None
    extra = [group_id(value) for value in supplementary]
    if primary is None or None in extra:
        return None
    members = [gid for gid, names in groups.values() if name in names]
    return Identity(name, uid, tuple(dict.fromkeys([primary] + members + extra)), root=uid == 0)


def service_identity(root, accounts, live=None):
    """Who the SSSD daemon runs as, where that came from, and findings about how it was determined.
    The identity is None when it cannot be resolved."""
    # SSSD 2.11 removed the [sssd] user option; only the systemd unit sets the identity.
    live = root == Path("/") if live is None else live
    props, failure = unit_properties(root, ("User", "Group", "SupplementaryGroups"), live)
    notes = [("failed", failure)] if failure else []
    if live and not failure:
        source = "systemctl show sssd.service"
    else:
        source = unit_user(root)[1] or "the default"
    identity = resolve_identity(props["User"], props["Group"], props["SupplementaryGroups"], accounts)
    if identity is None:
        notes.append(("unchecked", f"cannot resolve the SSSD service user or its groups (User={props['User']}, "
                      f"Group={props['Group'] or 'default'}) set by {source}; its access was not checked"))
    else:
        identity.effective = live and not failure
    return identity, source, notes


def allows(st, identity, want):
    """Mode-bit access check; want is 4 for read, 1 for search, 5 for both."""
    if identity.root:
        return True
    if st.st_uid == identity.uid:
        bits = st.st_mode >> 6
    elif st.st_gid in identity.gids:
        bits = st.st_mode >> 3
    else:
        bits = st.st_mode
    return bits & want == want


# POSIX ACL entry tags from linux/posix_acl_xattr.h.
ACL_USER_OBJ, ACL_USER, ACL_GROUP_OBJ, ACL_GROUP, ACL_MASK, ACL_OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20


def parse_acl(raw):
    """(tag, permissions, id) entries of a system.posix_acl_access value; ValueError when malformed."""
    if len(raw) < 4 or (len(raw) - 4) % 8 or struct.unpack_from("<I", raw)[0] != 2:
        raise ValueError("not a POSIX ACL")
    return [struct.unpack_from("<HHI", raw, offset) for offset in range(4, len(raw), 8)]


def read_acl(path):
    """The access ACL of path, or None when it has none. Raises OSError or ValueError when it cannot be read."""
    try:
        raw = os.getxattr(path, ACL_XATTR, follow_symlinks=True)
    except AttributeError:
        # No Linux xattr API (macOS fixtures): there are no POSIX access ACLs to find.
        return None
    except OSError as exc:
        if exc.errno in (errno.ENODATA, getattr(errno, "ENOATTR", errno.ENODATA), errno.ENOTSUP):
            return None
        raise
    return parse_acl(raw)


def acl_allows(entries, st, identity, want):
    """The acl(5) access check: the owner entry, else a named user entry, else any matching group entry that
    grants all of want, else other. Named users and groups are limited by the mask."""
    perms = {tag: perm for tag, perm, _id in entries if tag in (ACL_USER_OBJ, ACL_MASK, ACL_OTHER)}
    mask = perms.get(ACL_MASK, 7)
    if st.st_uid == identity.uid:
        return perms.get(ACL_USER_OBJ, 0) & want == want
    for tag, perm, uid in entries:
        if tag == ACL_USER and uid == identity.uid:
            return perm & mask & want == want
    matched = False
    for tag, perm, gid in entries:
        if (tag == ACL_GROUP_OBJ and st.st_gid in identity.gids) or (tag == ACL_GROUP and gid in identity.gids):
            matched = True
            if perm & mask & want == want:
                return True
    return False if matched else perms.get(ACL_OTHER, 0) & want == want


def permits(path, st, identity, want):
    """Whether identity has want on path, honouring its ACL; None when the ACL cannot be read."""
    if identity.root:
        return True
    try:
        entries = read_acl(path)
    except (OSError, ValueError):
        return None
    return allows(st, identity, want) if entries is None else acl_allows(entries, st, identity, want)


def access_check(root, path, st, identity, want):
    """None when identity can search every directory down to path and has want on it. Otherwise (level, blocked,
    doubt): blocked is the directory that stops it, or None for path itself. ACLs are evaluated on every
    component, so mode bits never decide alone; when metadata or an ACL cannot be read, level is unchecked and
    doubt says why, so an incomplete calculation never reads as either allowed or denied."""
    for parent in reversed(path.parents):
        if parent != root and root not in parent.parents:
            continue
        try:
            verdict = permits(parent, parent.stat(), identity, 1)
        except OSError as exc:
            return "unchecked", parent, f"its metadata cannot be read ({exc.strerror or exc})"
        if verdict is None:
            return "unchecked", parent, "its ACL cannot be read"
        if not verdict:
            return "warning", parent, ""
    verdict = permits(path, st, identity, want)
    if verdict is None:
        return "unchecked", None, "its ACL cannot be read"
    return None if verdict else ("warning", None, "")


def shown(root, path):
    """A path as it appears on the inspected system."""
    try:
        return "/" + str(path.relative_to(root)).lstrip("./")
    except ValueError:
        return str(path)


def owner_name(accounts, uid, gid):
    users = {v[0]: k for k, v in reversed(list(accounts[0].items()))} if accounts else {}
    groups = {v[0]: k for k, v in reversed(list(accounts[1].items()))} if accounts else {}
    return f"{users.get(uid, uid)}:{groups.get(gid, gid)}"


def sssd_file_findings(root, files, identity, accounts):
    """Problems SSSD 2.12 would have with its config files, as (level, message) pairs."""
    findings = []
    owners = groups = None
    if accounts:
        users, group_table = accounts
        owners = {users[n][0] for n in ("root", SSSD_ACCOUNT) if n in users}
        groups = {group_table[n][0] for n in ("root", SSSD_ACCOUNT) if n in group_table}
    for path in files:
        rel = shown(root, path)
        try:
            st = path.stat()
        except OSError as exc:
            findings.append(("unchecked", f"{rel}: its owner and mode cannot be read ({exc.strerror or exc})"))
            continue
        mode = f"{st.st_mode & 0o777:04o}"
        if st.st_mode & 0o007:
            findings.append(("warning", f"{rel} ({mode}) is accessible to other users; SSSD refuses to start with it. "
                             f"Remove the access for others (chmod o= {rel}) rather than changing its owner"))
        if owners is not None and (st.st_uid not in owners or st.st_gid not in groups):
            findings.append(("warning", f"{rel} is owned by {owner_name(accounts, st.st_uid, st.st_gid)}; SSSD "
                             f"accepts only root or {SSSD_ACCOUNT} as its owner and group"))
        checked = access_check(root, path, st, identity, 4) if identity else None
        if checked:
            level, blocked, doubt = checked
            what = (f"enter {shown(root, blocked)} to reach {rel}" if blocked else
                    f"read {rel} ({owner_name(accounts, st.st_uid, st.st_gid)} {mode})")
            findings.append(("warning", f"the SSSD service user {identity.name} cannot {what}") if level == "warning"
                            else (level, f"whether the SSSD service user {identity.name} can {what}: {doubt}"))
    return findings


def krb5_includes(root, path, seen):
    """Yield (path, included_by, is_dir) for every file and directory krb5.conf includes, recursively."""
    if path in seen or not path.is_file():
        return
    seen.add(path)
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"\s*(include|includedir)\s+(\S.*?)\s*$", line)
        if not match:
            continue
        target = root / match.group(2).lstrip("/")
        if match.group(1) == "include":
            yield target, path, False
            yield from krb5_includes(root, target, seen)
        else:
            yield target, path, True
            if target.is_dir():
                for child in sorted(target.iterdir()):
                    # MIT reads only names of letters, digits, dashes and underscores, or ending in .conf.
                    if re.fullmatch(r"[\w-]+", child.name) or (child.name.endswith(".conf") and child.name[0] != "."):
                        yield child, target, False
                        yield from krb5_includes(root, child, seen)


def krb5_writer_findings(root, path, st, accounts):
    """Who may change a Kerberos file: root, and also sssd for the snippets SSSD generates under pubconf."""
    rel = shown(root, path)
    if st.st_mode & 0o002:
        return [("warning", f"{rel} is writable by everyone, who could redirect Kerberos")]
    if not accounts:
        return []
    users, groups = accounts
    owners, writers = {users.get("root", (0,))[0]}, {groups.get("root", (0,))[0]}
    if rel.startswith("/var/lib/sss/pubconf/"):
        # Ubuntu's sssd-krb5-common installs krb5.include.d as sssd:sssd 0775 so SSSD can write there.
        owners |= {users[SSSD_ACCOUNT][0]} if SSSD_ACCOUNT in users else set()
        writers |= {groups[SSSD_ACCOUNT][0]} if SSSD_ACCOUNT in groups else set()
    who = owner_name(accounts, st.st_uid, st.st_gid)
    if st.st_uid not in owners:
        return [("warning", f"{rel} is owned by {who}, so that account could redirect Kerberos")]
    if st.st_mode & 0o020 and st.st_gid not in writers:
        return [("warning", f"{rel} ({who} {st.st_mode & 0o777:04o}) is writable by its group, whose members could "
                 "redirect Kerberos")]
    return []


def kerberos_findings(root, identity, accounts):
    """Access problems for krb5.conf, its includes, and the machine keytab, as (level, message) pairs."""
    findings = []
    conf = root / "etc/krb5.conf"
    if not conf.exists():
        findings.append(("info", "no /etc/krb5.conf; Kerberos relies on DNS and built-in defaults"))
    else:
        entries = [(conf, None, False)]
        if conf.is_symlink():
            # The link itself is never read; its target and that target's directories are.
            target = os.readlink(conf)
            entries.append((root / target.lstrip("/") if target.startswith("/") else conf.parent / target, conf, False))
        entries += list(krb5_includes(root, conf, set()))
        pubconf = False
        for path, parent, is_dir in entries:
            rel = shown(root, path)
            if "var/lib/sss/pubconf/krb5.include.d" in str(path):
                pubconf = True
            try:
                st = path.stat()
            except FileNotFoundError:
                findings.append(("warning", f"{rel}, included from {shown(root, parent)}, is missing; "
                                 "Kerberos then fails to load its configuration"))
                continue
            except OSError as exc:
                findings.append(("unchecked", f"{rel}: its owner and mode cannot be read ({exc.strerror or exc})"))
                continue
            want = 5 if is_dir else 4
            readers = [EVERYONE] + ([identity] if identity else [])
            for reader in readers:
                checked = access_check(root, path, st, reader, want)
                if not checked:
                    continue
                level, blocked, doubt = checked
                if level != "warning":
                    findings.append((level, f"whether {reader.name} can read {rel}: {doubt}"))
                elif blocked:
                    findings.append(("warning", f"{reader.name} cannot enter {shown(root, blocked)} to read {rel}"))
                else:
                    findings.append(("warning", f"{rel} is not readable by {reader.name} "
                                     f"({owner_name(accounts, st.st_uid, st.st_gid)} {st.st_mode & 0o777:04o}); "
                                     "kinit as root works but logins and user tools fail"))
                break
            findings += krb5_writer_findings(root, path, st, accounts)
        if not pubconf:
            findings.append(("info", "krb5.conf does not include /var/lib/sss/pubconf/krb5.include.d, so Kerberos "
                             "tools miss the realm mappings and localauth plugin SSSD generates there"))
    keytab = root / "etc/krb5.keytab"
    try:
        st = keytab.stat()
    except FileNotFoundError:
        findings.append(("info", "no /etc/krb5.keytab; the AD provider needs the machine keytab to go online"))
    except OSError as exc:
        findings.append(("unchecked", f"/etc/krb5.keytab: its owner and mode cannot be read ({exc.strerror or exc})"))
    else:
        if accounts and st.st_uid != accounts[0].get("root", (0,))[0]:
            findings.append(("warning", f"/etc/krb5.keytab is owned by {owner_name(accounts, st.st_uid, st.st_gid)}, "
                             "so that account can read and replace the machine's secret keys; only root should own it"))
        group_ok = accounts is None or st.st_gid in {accounts[1][n][0] for n in ("root", SSSD_ACCOUNT)
                                                     if n in accounts[1]}
        if st.st_mode & 0o007 or (st.st_mode & 0o070 and not group_ok):
            findings.append(("warning", f"/etc/krb5.keytab ({owner_name(accounts, st.st_uid, st.st_gid)} "
                             f"{st.st_mode & 0o777:04o}) holds the machine's secret key and is readable or writable "
                             "beyond root; restrict it, for example to root:root 0600, which the packaged helpers use"))
    return findings


def load_sssd(root):
    """Merge sssd.conf and its conf.d snippets in SSSD's order: later snippets override earlier settings."""
    config = configparser.ConfigParser(interpolation=None, strict=False)
    # SSSD reads only snippets matching ^[^.].*\.conf$, so hidden backups never take effect.
    snippets = sorted(p for p in (root / "etc/sssd/conf.d").glob("*.conf") if not p.name.startswith("."))
    files = [root / "etc/sssd/sssd.conf", *snippets]
    present = []
    config.origins, config.unreadable = {}, []
    for file in files:
        if not os.path.lexists(file):
            continue
        # ConfigParser.read() skips files it cannot open, which would hide a setting SSSD may still apply.
        try:
            text = file.read_text(errors="replace")
        except OSError as exc:
            config.unreadable.append((shown(root, file), exc.strerror or str(exc)))
            continue
        present.append(file)
        single = configparser.ConfigParser(interpolation=None, strict=False)
        single.read_string(text, source=str(file))
        for section in single.sections():
            for key in single.options(section):
                config.origins[(section, key)] = shown(root, file)
        config.read_string(text, source=str(file))
    return config, present


def check_config(root, live=None):
    """Load SSSD's configuration and judge its files; raises configparser.Error when unparseable."""
    config, files = load_sssd(root)
    accounts = read_accounts(root)
    identity, source, findings = service_identity(root, accounts, live)
    findings += [("unchecked", f"{name} cannot be read ({error}); SSSD's effective settings may differ from those "
                  "shown") for name, error in config.unreadable]
    findings += sssd_file_findings(root, files, identity, accounts)
    if config.has_option("sssd", "user"):
        findings.append(("info", "[sssd] user was removed in SSSD 2.11 and no longer changes the service user; "
                         "remove it, and set the identity through sssd.service if needed"))
    return config, files, identity, source, accounts, findings


def origin(config, section, key):
    """Where a shown value was set, when that is not the main sssd.conf."""
    source = getattr(config, "origins", {}).get((section, key))
    return f"  (from {source})" if source and source != "/etc/sssd/sssd.conf" else ""


def inspect_sssd(root):
    config, files, identity, source, accounts, findings = check_config(root)
    print("SSSD configuration:")
    if not files and not config.unreadable:
        say("warning", "no /etc/sssd/sssd.conf; domain logins are not handled by SSSD")
        return [], identity, accounts, config
    print(f"  service user: {identity.name if identity else 'unknown'} (from {source})")
    if identity and not identity.root:
        names = {gid: name for name, (gid, _members) in reversed(list((accounts or ({}, {}))[1].items()))}
        print(f"  service groups: {', '.join(str(names.get(gid, gid)) for gid in identity.gids)} ("
              + ("as systemd reports them)" if identity.effective else
                 "from unit files and the account database; an approximation of what systemd applies)"))
    for level, message in findings:
        say(level, message)
    if not any(level in ("warning",) + DOUBTS for level, _ in findings):
        say("ok", "configuration files have an owner, group, and mode SSSD accepts")
    domains = [d.strip() for d in config.get("sssd", "domains", fallback="").split(",") if d.strip()]
    if not domains:
        domains = [s.split("/", 1)[1] for s in config.sections() if s.startswith("domain/")]
    pam_expiration = config.get("pam", "offline_credentials_expiration", fallback="0")
    for domain in domains:
        section = f"domain/{domain}"
        print(f"  [{section}]")
        for key in DOMAIN_KEYS:
            if config.has_option(section, key):
                print(f"    {key} = {config.get(section, key)}{origin(config, section, key)}")
        if config.get(section, "cache_credentials", fallback="false").strip().lower() not in TRUE:
            message = (f"{domain}: cache_credentials is off (the SSSD default), so a domain password is never "
                       "stored and offline login before VPN cannot work; set cache_credentials = True")
            if config.unreadable:
                say("possible", message + ". Not confirmed: an unreadable snippet may set it")
            else:
                say("warning", message)
        else:
            say("ok", f"{domain}: cache_credentials is on")
        if config.get(section, "krb5_store_password_if_offline", fallback="false").strip().lower() not in TRUE:
            say("info", f"{domain}: krb5_store_password_if_offline is off; after an offline login SSSD will not "
                "fetch a Kerberos ticket by itself once the VPN connects")
        if config.get(section, "ad_gpo_access_control", fallback="").strip().lower() == "enforcing":
            say("info", f"{domain}: GPO access control is enforcing; offline login also needs cached GPO rules")
    if config.has_section("pam"):
        print("  [pam]")
        for key in PAM_KEYS:
            if config.has_option("pam", key):
                print(f"    {key} = {config.get('pam', key)}{origin(config, 'pam', key)}")
    if pam_expiration.strip() not in ("", "0"):
        say("info", f"cached passwords expire {pam_expiration} day(s) after the last online login")
    return domains, identity, accounts, config


def inspect_kerberos(root, identity, accounts):
    print("Kerberos configuration:")
    findings = kerberos_findings(root, identity, accounts)
    for level, message in findings:
        say(level, message)
    if not any(level in ("warning",) + DOUBTS for level, _ in findings):
        say("ok", "krb5.conf and its includes are readable"
            + (" and the keytab is private" if os.path.lexists(root / "etc/krb5.keytab") else ""))


def load_platform():
    spec = importlib.util.spec_from_file_location("credentials_platform",
                                                  Path(__file__).with_name("credentials-platform.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def inspect_platform(root, config, domains, identity, accounts):
    sections, not_checked = load_platform().platform_report(root, config, domains, identity, accounts)
    for title, findings in sections:
        if findings:
            print(f"{title}:")
            for level, message in findings:
                say(level, message)
    if not_checked:
        print("Not checked:")
        for item in not_checked:
            print(f"  {item}")


def pam_auth_lines(root, name, seen=None):
    seen = seen if seen is not None else set()
    path = root / "etc/pam.d" / name
    if name in seen or not path.is_file():
        return []
    seen.add(name)
    lines = []
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("@include"):
            lines += pam_auth_lines(root, line.split()[1], seen)
        elif re.match(r"-?auth\s", line):
            lines.append(line)
    return lines


def inspect_pam(root):
    print("PAM authentication stack (gdm-password):")
    lines = pam_auth_lines(root, "gdm-password") or pam_auth_lines(root, "common-auth")
    for line in lines:
        print(f"  {line}")
    stack = [parse_pam_line(line) for line in lines]
    modules = [module for _control, module in stack]
    if "pam_sss" not in modules:
        say("warning", "pam_sss is not in the authentication stack; SSSD cannot cache domain passwords")
        return
    sss_index = modules.index("pam_sss")
    krb5_index = modules.index("pam_krb5") if "pam_krb5" in modules[:sss_index] else None
    if krb5_index is None:
        say("ok", "pam_sss handles domain passwords")
    elif success_skips(stack[krb5_index][0], krb5_index, sss_index):
        say("warning", "pam_krb5 runs before pam_sss and a success skips pam_sss, so SSSD never sees the password "
            "and caches nothing. Remove libpam-krb5 and let SSSD obtain tickets")
    else:
        say("info", "pam_krb5 runs before pam_sss but does not skip it on success; pam_sss still sees the password")


def parse_pam_line(line):
    """Split an auth line into its control field and module name."""
    rest = re.sub(r"^-?auth\s+", "", line)
    if rest.startswith("["):
        control, _, rest = rest[1:].partition("]")
    else:
        parts = rest.split(None, 1)
        control = parts[0] if parts else ""
        rest = parts[1] if len(parts) > 1 else ""
    module = re.search(r"\b(pam_\w+)\.so\b", rest)
    return control.strip(), module.group(1) if module else ""


def success_skips(control, index, target):
    """Whether a successful module at index ends the stack or jumps past target."""
    if control == "sufficient":
        return True
    if control in ("required", "requisite", "optional", "include", "substack"):
        return False
    actions = dict(item.split("=", 1) for item in control.split() if "=" in item)
    action = actions.get("success", actions.get("default", "ignore"))
    if action == "done":
        return True
    return action.isdigit() and index + int(action) >= target


def cached_passwords(db_dir):
    print("SSSD cache:")
    caches = sorted(db_dir.glob("cache_*.ldb")) if db_dir.is_dir() else []
    if not caches:
        say("warning", f"no cache files in {db_dir}; nothing is cached for offline login")
        return
    ldbsearch = shutil.which("ldbsearch")
    for cache in caches:
        modified = datetime.datetime.fromtimestamp(cache.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
        print(f"  {cache.name} (modified {modified})")
        if ldbsearch:
            # Presence filter only: the hash attribute itself is never requested.
            result = subprocess.run([ldbsearch, "-H", str(cache), "(cachedPassword=*)", "name", "lastCachedPasswordChange"],
                                    capture_output=True, text=True, check=False)
            if result.returncode != 0:
                say("info", f"cache query failed (ldbsearch exit {result.returncode}); cached password state unknown")
                continue
            users = {}
            current = None
            for line in result.stdout.splitlines():
                if line.startswith("name: "):
                    current = line[6:]
                    users[current] = "unknown time"
                elif line.startswith("lastCachedPasswordChange: ") and current:
                    users[current] = datetime.datetime.fromtimestamp(int(line.split()[1])).strftime("%Y-%m-%d %H:%M")
            for user, when in users.items():
                say("ok", f"cached password for {user} (stored {when})")
            if not users:
                say("warning", "no user in this cache has a stored password")
        else:
            count = cache.read_bytes().count(b"cachedPassword\x00")
            level = "ok" if count else "warning"
            say(level, f"about {count} user record(s) with a stored password (install ldb-tools for names)")


def domain_status(domains):
    sssctl = shutil.which("sssctl")
    if not sssctl:
        return
    print("SSSD domain status:")
    for domain in domains:
        result = subprocess.run([sssctl, "domain-status", domain, "--online"], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            say("failed", f"{domain}: {probe_failure('sssctl domain-status', result)}")
        else:
            print(f"  {domain}: {result.stdout.strip() or 'unknown'}")


def purge(root):
    sss = root / "var/lib/sss"
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = sss / "dotconfig-backup" / stamp
    live = root == Path("/")
    if live:
        subprocess.run(["systemctl", "stop", "sssd"], check=True)
    try:
        moved = 0
        for name in ("db", "mc"):
            source = sss / name
            if not source.is_dir():
                continue
            target = backup / name
            for item in source.iterdir():
                if item.is_file() and not item.is_symlink():
                    target.mkdir(parents=True, exist_ok=True, mode=0o700)
                    shutil.move(str(item), target / item.name)
                    moved += 1
        if moved:
            os.chmod(backup.parent, 0o700)
            print(f"Moved {moved} SSSD cache file(s) to {backup}")
        else:
            print("No SSSD cache files found")
    finally:
        if live:
            subprocess.run(["systemctl", "start", "sssd"], check=True)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("inspect", "purge"):
        raise ValueError("Usage: credentials-inspect.py {inspect|purge} ROOT")
    root = Path(sys.argv[2])
    if sys.argv[1] == "purge":
        purge(root)
        return
    domains, identity, accounts, config = inspect_sssd(root)
    inspect_kerberos(root, identity, accounts)
    inspect_pam(root)
    cached_passwords(root / "var/lib/sss/db")
    if root == Path("/"):
        domain_status(domains)
    inspect_platform(root, config, domains, identity, accounts)


if __name__ == "__main__":
    try:
        main()
    except configparser.Error as exc:
        # Parser messages quote the offending line, which may hold a private value.
        print(f"credentials: could not parse SSSD configuration ({type(exc).__name__})", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"credentials: {exc}", file=sys.stderr)
        sys.exit(1)
