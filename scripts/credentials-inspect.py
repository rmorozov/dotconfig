#!/usr/bin/env python3
"""Inspect or reset SSSD credential caches as root without printing secrets."""

import configparser
import datetime
import os
import re
import shutil
import subprocess
import sys
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


def load_sssd(root):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    files = [root / "etc/sssd/sssd.conf", *sorted((root / "etc/sssd/conf.d").glob("*.conf"))]
    present = [f for f in files if f.is_file()]
    for file in present:
        if file.stat().st_mode & 0o077:
            say("warning", f"{file.relative_to(root)} is readable by other users; SSSD refuses to start with it")
        config.read(file)
    return config, present


def inspect_sssd(root):
    config, files = load_sssd(root)
    print("SSSD configuration:")
    if not files:
        say("warning", "no /etc/sssd/sssd.conf; domain logins are not handled by SSSD")
        return []
    domains = [d.strip() for d in config.get("sssd", "domains", fallback="").split(",") if d.strip()]
    if not domains:
        domains = [s.split("/", 1)[1] for s in config.sections() if s.startswith("domain/")]
    pam_expiration = config.get("pam", "offline_credentials_expiration", fallback="0")
    for domain in domains:
        section = f"domain/{domain}"
        print(f"  [{section}]")
        for key in DOMAIN_KEYS:
            if config.has_option(section, key):
                print(f"    {key} = {config.get(section, key)}")
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
                print(f"    {key} = {config.get('pam', key)}")
    if pam_expiration.strip() not in ("", "0"):
        say("info", f"cached passwords expire {pam_expiration} day(s) after the last online login")
    return domains


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
    domains = inspect_sssd(root)
    inspect_pam(root)
    cached_passwords(root / "var/lib/sss/db")
    if root == Path("/"):
        domain_status(domains)


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
