#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'chmod -R u+rwx "$test_dir"; rm -rf "$test_dir"' EXIT
export DOTCONFIG_CREDS_TEST_ROOT="$test_dir/root"
root="$DOTCONFIG_CREDS_TEST_ROOT"
stubs="$test_dir/bin"
mkdir -p "$root/etc/sssd/conf.d" "$root/etc/pam.d" "$root/etc/krb5.conf.d" "$root/var/log/journal" \
    "$root/usr/lib/systemd/system" "$stubs"

# Test files belong to the current user, so the fixture's account database names that user root and its group
# sssd: a file created here reads as root:sssd, and the sssd service user reaches it only through the group.
# BSD gives new files their directory's group, so read the group a new file actually gets.
me="$(id -u)"
touch "$root/probe"
my_group="$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_gid)' "$root/probe")"
rm "$root/probe"
accounts() {
    printf 'root:x:%s:%s::/root:/bin/sh\nsssd:x:%s:%s::/var/lib/sss:/usr/sbin/nologin\n' \
        "$1" "$((my_group + 1))" "$((me + 1))" "$my_group" > "$root/etc/passwd"
    printf 'root:x:%s:\nsssd:x:%s:\n' "$((my_group + 1))" "$my_group" > "$root/etc/group"
}
accounts "$me"
printf '[Service]\nUser=sssd\nGroup=sssd\n' > "$root/usr/lib/systemd/system/sssd.service"

cat > "$root/etc/sssd/sssd.conf" <<'EOF'
[sssd]
domains = corp.example
services = nss, pam

[domain/corp.example]
id_provider = ad
cache_credentials = False
EOF
chmod 640 "$root/etc/sssd/sssd.conf"
# A later snippet overrides the main file, as in SSSD.
printf '[domain/corp.example]\ncache_credentials = True\n' > "$root/etc/sssd/conf.d/50-cache.conf"
chmod 640 "$root/etc/sssd/conf.d/50-cache.conf"
printf 'auth [success=1 default=ignore] pam_sss.so\nauth requisite pam_deny.so\n' > "$root/etc/pam.d/common-auth"
printf 'includedir /etc/krb5.conf.d/\nincludedir /var/lib/sss/pubconf/krb5.include.d/\n[libdefaults]\n' > "$root/etc/krb5.conf"
mkdir -p "$root/var/lib/sss/pubconf/krb5.include.d"
printf '[realms]\n' > "$root/etc/krb5.conf.d/corp"
chmod 644 "$root/etc/krb5.conf" "$root/etc/krb5.conf.d/corp"
printf 'keytab' > "$root/etc/krb5.keytab"
chmod 600 "$root/etc/krb5.keytab"

# Offline login failures that, with a valid configuration, implicate the cache settings.
cat > "$stubs/journalctl" <<EOF
#!/usr/bin/env bash
now="\$(python3 -c 'import time; print(int(time.time() * 1e6))')"
case "\$*" in
    *--list-boots*) echo '[]' ;;
    *SYSLOG_FACILITY=*)
        printf '{"__CURSOR":"a","__REALTIME_TIMESTAMP":"%s","SYSLOG_IDENTIFIER":"gdm-password]","SYSLOG_FACILITY":"10","MESSAGE":"pam_sss(gdm-password:auth): received for user alice: 9 (Authentication service cannot retrieve authentication info)"}\n' "\$((now - 120000000))"
        printf '{"__CURSOR":"b","__REALTIME_TIMESTAMP":"%s","SYSLOG_IDENTIFIER":"sssd_be","MESSAGE":"Cached credentials not available."}\n' "\$((now - 120000000))"
        ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 0\\n\\nMessages generated during configuration merging: 0\\n"\n' \
    > "$stubs/sssctl"
chmod +x "$stubs/journalctl" "$stubs/sssctl"
export PATH="$stubs:$PATH"

check() {
    grep -q -- "$1" "$test_dir/out" || { cat "$test_dir/out" >&2; echo "Missing: $1" >&2; exit 1; }
}
refute() {
    if grep -q -- "$1" "$test_dir/out"; then cat "$test_dir/out" >&2; echo "Unexpected: $1" >&2; exit 1; fi
}
status() {
    bash "$repo_root/scripts/credentials.sh" status > "$test_dir/out" 2>&1
}
logs() {
    bash "$repo_root/scripts/credentials.sh" check-logs > "$test_dir/out" 2>&1
}

# Ubuntu 26.04's root:sssd 0640 is valid, and the snippet turns cache_credentials on.
status
check 'service user: sssd (from /usr/lib/systemd/system/sssd.service)'
check '^ok: configuration files have an owner, group, and mode SSSD accepts'
check '^ok: corp.example: cache_credentials is on'
check '^ok: krb5.conf and its includes are readable and the keytab is private'
refute 'accessible to other users'
logs
check '^ok: sssctl config-check accepts the SSSD configuration'
refute 'SSSD configuration is invalid'
refute 'cause: cache_credentials'

# Others may not read the configuration; the advice keeps the owner.
chmod 644 "$root/etc/sssd/conf.d/50-cache.conf"
status
check '^warning: /etc/sssd/conf.d/50-cache.conf (0644) is accessible to other users.*chmod o='
chmod 640 "$root/etc/sssd/conf.d/50-cache.conf"

# An owner other than root or sssd makes the configuration invalid, and the cache judgement is withheld.
accounts "$((me + 2))"
status
check "^warning: /etc/sssd/sssd.conf is owned by $me:sssd; SSSD accepts only root or sssd"
sed -i.bak '/cache_credentials/d' "$root/etc/sssd/conf.d/50-cache.conf"
logs
check '^warning: SSSD configuration is invalid: /etc/sssd/sssd.conf is owned by'
refute 'cause: cache_credentials'
assessment_line() { grep -n "$1" "$test_dir/out" | head -1 | cut -d: -f1; }
[[ "$(assessment_line 'SSSD configuration is invalid')" -eq "$(( $(assessment_line '^Assessment:') + 1 ))" ]] \
    || { cat "$test_dir/out" >&2; echo 'Configuration verdict is not first' >&2; exit 1; }
accounts "$me"
logs
check '^warning: cause: cache_credentials is off for corp.example'

# Uncertainty is reported, never turned into a cause: an unreadable snippet may hold the setting SSSD applies.
ln -s 60-loop.conf "$root/etc/sssd/conf.d/60-loop.conf"
status
check '^not checked: /etc/sssd/conf.d/60-loop.conf cannot be read'
refute '^ok: configuration files have an owner'
logs
check '^not checked: /etc/sssd/conf.d/60-loop.conf cannot be read'
check '^possible cause: cache_credentials is off for corp.example.*not confirmed'
refute '^warning: cause'
rm "$root/etc/sssd/conf.d/60-loop.conf"

# A failed probe keeps its exit status and a sanitized reason, and is not a verdict on the configuration.
cp "$stubs/sssctl" "$test_dir/sssctl.ok"
printf '#!/usr/bin/env bash\necho "sssctl: cannot read ldap_default_authtok = ProbeSecret" >&2\nexit 3\n' > "$stubs/sssctl"
logs
check '^check failed: sssctl config-check exited 3: sssctl: cannot read ldap_default_authtok = <hidden>; the configuration was not validated'
check '^possible cause: cache_credentials is off for corp.example'
refute 'SSSD configuration is invalid'
refute 'ProbeSecret'
cp "$test_dir/sssctl.ok" "$stubs/sssctl"
cp "$stubs/journalctl" "$test_dir/journalctl.ok"
printf '#!/usr/bin/env bash\necho "Failed to open journal: Permission denied" >&2\nexit 1\n' > "$stubs/journalctl"
logs
check '^check failed: journalctl exited 1: Failed to open journal: Permission denied (reading -u sssd\*); entries'
check '^check failed: journalctl --list-boots exited 1'
cp "$test_dir/journalctl.ok" "$stubs/journalctl"
printf 'cache_credentials = True\n' >> "$root/etc/sssd/conf.d/50-cache.conf"

# The service user must be able to enter the directories and read the files; root can always.
chmod 700 "$root/etc/sssd"
status
check '^warning: the SSSD service user sssd cannot enter /etc/sssd to reach /etc/sssd/sssd.conf'
chmod 750 "$root/etc/sssd"
chmod 600 "$root/etc/sssd/sssd.conf"
status
check '^warning: the SSSD service user sssd cannot read /etc/sssd/sssd.conf (root:sssd 0600)'
printf '[Service]\nUser=\n' > "$test_dir/override.conf"
mkdir -p "$root/etc/systemd/system/sssd.service.d"
cp "$test_dir/override.conf" "$root/etc/systemd/system/sssd.service.d/root.conf"
status
check 'service user: root (from /etc/systemd/system/sssd.service.d/root.conf)'
refute 'cannot read /etc/sssd/sssd.conf'
rm -r "$root/etc/systemd/system/sssd.service.d"
chmod 640 "$root/etc/sssd/sssd.conf"

# Group= replaces the primary group and SupplementaryGroups= adds groups, with an empty value resetting the list.
# /etc/sssd is opened for search here so the file itself, not its directory, decides.
dropin="$root/etc/systemd/system/sssd.service.d"
mkdir -p "$dropin"
chmod 751 "$root/etc/sssd"
printf '[Service]\nGroup=root\n' > "$dropin/10-group.conf"
status
check 'service groups: root (from unit files and the account database; an approximation'
check '^warning: the SSSD service user sssd cannot read /etc/sssd/sssd.conf (root:sssd 0640)'
printf '[Service]\nSupplementaryGroups=sssd\n' > "$dropin/20-extra.conf"
status
check 'service groups: root, sssd ('
refute 'cannot read /etc/sssd/sssd.conf'
printf '[Service]\nSupplementaryGroups=\n' > "$dropin/30-reset.conf"
status
check '^warning: the SSSD service user sssd cannot read /etc/sssd/sssd.conf'

# An ACL may grant what mode bits deny, so effective access is reported as not checked rather than denied.
if python3 - "$root/etc/sssd/sssd.conf" "$((me + 1))" <<'PY' 2>/dev/null
import os, struct, sys
# POSIX ACL xattr: version 2, then (tag, perm, id) for user::rw-, user:SERVICE:r--, group::r--, mask::r--, other::---.
entries = [(0x01, 6, 0xFFFFFFFF), (0x02, 4, int(sys.argv[2])), (0x04, 4, 0xFFFFFFFF), (0x10, 4, 0xFFFFFFFF),
           (0x20, 0, 0xFFFFFFFF)]
os.setxattr(sys.argv[1], "system.posix_acl_access",
            struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *entry) for entry in entries))
PY
then
    status
    check '^not checked: whether the SSSD service user sssd can read /etc/sssd/sssd.conf (root:sssd 0640): mode bits deny it, but an ACL is present'
    refute '^warning: the SSSD service user sssd cannot read /etc/sssd/sssd.conf'
    logs
    check '^not checked: whether the SSSD service user sssd can read /etc/sssd/sssd.conf'
    refute 'invalid: .*cannot read /etc/sssd/sssd.conf'
    python3 -c 'import os, sys; os.removexattr(sys.argv[1], "system.posix_acl_access")' "$root/etc/sssd/sssd.conf"
    chmod 640 "$root/etc/sssd/sssd.conf"
else
    echo 'Skipping the ACL case: this filesystem does not accept POSIX ACLs.'
fi
rm "$dropin"/*.conf
chmod 750 "$root/etc/sssd"

# Numeric identities resolve through the account database; an unknown one leaves access unchecked.
printf '[Service]\nUser=%s\nGroup=%s\n' "$((me + 1))" "$my_group" > "$dropin/10-numeric.conf"
status
check 'service user: sssd (from /etc/systemd/system/sssd.service.d/10-numeric.conf)'
check 'service groups: sssd ('
refute 'cannot read /etc/sssd/sssd.conf'
printf '[Service]\nUser=nosuchuser\n' > "$dropin/10-numeric.conf"
status
check '^not checked: cannot resolve the SSSD service user or its groups (User=nosuchuser'
check 'helper ownership and capabilities (the SSSD service user is unknown)'
refute '^ok: configuration files have an owner'
refute 'cannot read /etc/sssd/sssd.conf'
logs
refute 'SSSD configuration is invalid'
rm -r "$dropin"

# On a live system the credentials come from systemctl show; when it fails, the failure is kept and the unit
# files are read instead.
python3 - "$repo_root/scripts/credentials-inspect.py" "$root" "$stubs" "$((me + 1))" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("credentials_inspect", sys.argv[1])
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)
root, stubs, uid = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
accounts = inspector.read_accounts(root)
os.environ["PATH"] = f"{stubs}:{os.environ['PATH']}"
systemctl = stubs / "systemctl"
systemctl.write_text(f"#!/usr/bin/env bash\nprintf 'User={uid}\\nGroup=\\nSupplementaryGroups=root\\n'\n")
systemctl.chmod(0o755)
identity, source, notes = inspector.service_identity(root, accounts, live=True)
assert (identity.name, identity.effective, source, notes) == ("sssd", True, "systemctl show sssd.service", []), \
    (identity, source, notes)
assert identity.gids == (accounts[1]["sssd"][0], accounts[1]["root"][0]), identity
systemctl.write_text("#!/usr/bin/env bash\necho 'Failed to connect to bus: No such file or directory' >&2\nexit 1\n")
identity, source, notes = inspector.service_identity(root, accounts, live=True)
assert notes == [("failed", "systemctl show sssd.service exited 1: Failed to connect to bus: No such file or "
                  "directory")], notes
assert (identity.name, identity.effective, source) == ("sssd", False, "/usr/lib/systemd/system/sssd.service"), \
    (identity, source)
systemctl.unlink()
PY

# The [sssd] user option was removed in 2.11: it is reported as stale and does not change the service user.
cp -p "$root/etc/sssd/sssd.conf" "$root/etc/sssd/sssd.conf.bak"
python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("[sssd]\n", "[sssd]\nuser = root\n", 1))' \
    "$root/etc/sssd/sssd.conf"
status
check 'service user: sssd (from /usr/lib/systemd/system/sssd.service)'
check '^info: \[sssd\] user was removed in SSSD 2.11'
mv "$root/etc/sssd/sssd.conf.bak" "$root/etc/sssd/sssd.conf"

# sssctl's own verdict counts as evidence, with private values hidden.
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 1\\n[rule/allowed_domain_options]: Attribute '"'"'ldap_default_authtok = SecretMustNeverPrint'"'"' is not allowed\\n\\n"\nexit 1\n' \
    > "$stubs/sssctl"
logs
check '^warning: SSSD configuration is invalid: sssctl config-check reported 1 problem(s): \[rule/allowed_domain_options\]'
refute 'SecretMustNeverPrint'
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 0\\n"\n' > "$stubs/sssctl"

# SSSD ignores hidden snippets, so neither a hidden override nor a broken hidden backup counts.
printf '[domain/corp.example]\ncache_credentials = False\n' > "$root/etc/sssd/conf.d/.backup.conf"
printf 'not a section line\n' > "$root/etc/sssd/conf.d/.broken.conf"
chmod 644 "$root/etc/sssd/conf.d/.backup.conf" "$root/etc/sssd/conf.d/.broken.conf"
status
check '^ok: corp.example: cache_credentials is on'
refute '.backup.conf\|.broken.conf'
logs
refute 'SSSD configuration is invalid'
rm "$root/etc/sssd/conf.d/.backup.conf" "$root/etc/sssd/conf.d/.broken.conf"

# A malformed snippet cannot be parsed; check-logs reports it instead of failing.
printf 'not a section line\n' > "$root/etc/sssd/conf.d/90-broken.conf"
chmod 640 "$root/etc/sssd/conf.d/90-broken.conf"
logs
check '^warning: SSSD configuration is invalid: it cannot be parsed (MissingSectionHeaderError)'
rm "$root/etc/sssd/conf.d/90-broken.conf"

# krb5.conf includes must be readable by ordinary users, not just root; the keytab must stay private.
chmod 600 "$root/etc/krb5.conf.d/corp"
status
check '^warning: /etc/krb5.conf.d/corp is not readable by ordinary users (root:sssd 0600); kinit as root works'
chmod 644 "$root/etc/krb5.conf.d/corp"
chmod 700 "$root/etc/krb5.conf.d"
status
check '^warning: /etc/krb5.conf.d is not readable by ordinary users'
chmod 755 "$root/etc/krb5.conf.d"
printf 'include /etc/krb5.missing\n' >> "$root/etc/krb5.conf"
status
check '^warning: /etc/krb5.missing, included from /etc/krb5.conf, is missing'
logs
check '^warning: Kerberos: /etc/krb5.missing, included from /etc/krb5.conf, is missing'
sed -i.bak '/krb5.missing/d' "$root/etc/krb5.conf"
chmod 644 "$root/etc/krb5.keytab"
status
check '^warning: /etc/krb5.keytab (root:sssd 0644) holds the machine.s secret key'
refute 'keytab.*0644.*chmod 644'
chmod 600 "$root/etc/krb5.keytab"
status
refute 'krb5.keytab (root'
echo 'Credential configuration tests passed.'
