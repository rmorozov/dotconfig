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

# sssctl's own verdict counts as evidence, with private values hidden.
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 1\\n[rule/allowed_domain_options]: Attribute '"'"'ldap_default_authtok = SecretMustNeverPrint'"'"' is not allowed\\n\\n"\nexit 1\n' \
    > "$stubs/sssctl"
logs
check '^warning: SSSD configuration is invalid: sssctl config-check reported 1 problem(s): \[rule/allowed_domain_options\]'
refute 'SecretMustNeverPrint'
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 0\\n"\n' > "$stubs/sssctl"

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
