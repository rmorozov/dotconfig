#!/usr/bin/env python3
"""Inspect or reset SSSD credential caches as root without printing secrets."""

import configparser
import datetime
import importlib.util
import os
import re
import shutil
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


def say(level, message):
    print(f"{level}: {message}")


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


def service_identity(root, config, accounts):
    """Who the SSSD daemon runs as, and where that came from; None when the account cannot be resolved."""
    # SSSD 2.11 removed the [sssd] user option; only the systemd unit sets the identity.
    name, source = unit_user(root)
    name, source = name or "root", source or "the default"
    if name == "root" or name == "0":
        return Identity("root", root=True), source
    if accounts is None or name not in accounts[0]:
        return None, source
    users, groups = accounts
    uid, gid = users[name]
    extra = tuple(g for g, members in groups.values() if name in members)
    return Identity(name, uid, (gid,) + extra), source


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


def has_acl(path):
    try:
        return ACL_XATTR in os.listxattr(path)
    except (AttributeError, OSError):
        return False


def blocked_parent(root, path, identity):
    """The first directory between root and path that identity cannot search, or None."""
    for parent in reversed(path.parents):
        if parent == root or root in parent.parents:
            if not allows(parent.stat(), identity, 1):
                return parent
    return None


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
        st = path.stat()
        mode = f"{st.st_mode & 0o777:04o}"
        if st.st_mode & 0o007:
            findings.append(("warning", f"{rel} ({mode}) is accessible to other users; SSSD refuses to start with it. "
                             f"Remove the access for others (chmod o= {rel}) rather than changing its owner"))
        if owners is not None and (st.st_uid not in owners or st.st_gid not in groups):
            findings.append(("warning", f"{rel} is owned by {owner_name(accounts, st.st_uid, st.st_gid)}; SSSD "
                             f"accepts only root or {SSSD_ACCOUNT} as its owner and group"))
        if identity and not allows(st, identity, 4):
            findings.append(("warning", f"the SSSD service user {identity.name} cannot read {rel} "
                             f"({owner_name(accounts, st.st_uid, st.st_gid)} {mode})"
                             + ("; it has an ACL, which this check does not evaluate" if has_acl(path) else "")))
        blocked = blocked_parent(root, path, identity) if identity else None
        if blocked:
            findings.append(("warning", f"the SSSD service user {identity.name} cannot enter {shown(root, blocked)} "
                             f"to reach {rel}"))
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
            if not path.exists():
                findings.append(("warning", f"{rel}, included from {shown(root, parent)}, is missing; "
                                 "Kerberos then fails to load its configuration"))
                continue
            st = path.stat()
            want = 5 if is_dir else 4
            readers = [EVERYONE] + ([identity] if identity else [])
            for reader in readers:
                if not allows(st, reader, want):
                    note = "; it has an ACL, which this check does not evaluate" if has_acl(path) else ""
                    findings.append(("info" if note else "warning",
                                     f"{rel} is not readable by {reader.name} "
                                     f"({owner_name(accounts, st.st_uid, st.st_gid)} {st.st_mode & 0o777:04o}); "
                                     "kinit as root works but logins and user tools fail" + note))
                    break
                blocked = blocked_parent(root, path, reader)
                if blocked:
                    findings.append(("warning", f"{reader.name} cannot enter {shown(root, blocked)} to read {rel}"))
                    break
            if st.st_mode & 0o002 or (st.st_mode & 0o020 and accounts and st.st_gid != accounts[1].get("root", (0,))[0]):
                findings.append(("warning", f"{rel} is writable by non-root users, who could redirect Kerberos"))
        if not pubconf:
            findings.append(("info", "krb5.conf does not include /var/lib/sss/pubconf/krb5.include.d, so Kerberos "
                             "tools miss the realm mappings and localauth plugin SSSD generates there"))
    keytab = root / "etc/krb5.keytab"
    if not keytab.exists():
        findings.append(("info", "no /etc/krb5.keytab; the AD provider needs the machine keytab to go online"))
    else:
        st = keytab.stat()
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
    files = [root / "etc/sssd/sssd.conf", *sorted((root / "etc/sssd/conf.d").glob("*.conf"))]
    present = [f for f in files if f.is_file()]
    config.origins = {}
    for file in present:
        single = configparser.ConfigParser(interpolation=None, strict=False)
        single.read(file)
        for section in single.sections():
            for key in single.options(section):
                config.origins[(section, key)] = shown(root, file)
        config.read(file)
    return config, present


def check_config(root):
    """Load SSSD's configuration and judge its files; raises configparser.Error when unparseable."""
    config, files = load_sssd(root)
    accounts = read_accounts(root)
    identity, source = service_identity(root, config, accounts)
    findings = sssd_file_findings(root, files, identity, accounts)
    if config.has_option("sssd", "user"):
        findings.append(("info", "[sssd] user was removed in SSSD 2.11 and no longer changes the service user; "
                         "remove it, and set the identity through sssd.service if needed"))
    if identity is None:
        findings.append(("info", f"cannot resolve the SSSD service user set by {source}; its access was not checked"))
    return config, files, identity, source, accounts, findings


def origin(config, section, key):
    """Where a shown value was set, when that is not the main sssd.conf."""
    source = getattr(config, "origins", {}).get((section, key))
    return f"  (from {source})" if source and source != "/etc/sssd/sssd.conf" else ""


def inspect_sssd(root):
    config, files, identity, source, accounts, findings = check_config(root)
    print("SSSD configuration:")
    if not files:
        say("warning", "no /etc/sssd/sssd.conf; domain logins are not handled by SSSD")
        return [], identity, accounts, config
    print(f"  service user: {identity.name if identity else 'unknown'} (from {source})")
    for level, message in findings:
        say(level, message)
    if not any(level == "warning" for level, _ in findings):
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
            say("warning", f"{domain}: cache_credentials is off (the SSSD default), so a domain password is never "
                "stored and offline login before VPN cannot work; set cache_credentials = True")
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
    if not any(level == "warning" for level, _ in findings):
        say("ok", "krb5.conf and its includes are readable and the keytab is private")


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
        print(f"  {domain}: {(result.stdout or result.stderr).strip() or 'unknown'}")


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
