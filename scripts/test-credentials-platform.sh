#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'chmod -R u+rwx "$test_dir"; rm -rf "$test_dir"' EXIT
export DOTCONFIG_CREDS_TEST_ROOT="$test_dir/root"
root="$DOTCONFIG_CREDS_TEST_ROOT"
stubs="$test_dir/bin"
journal="$test_dir/journal"
mkdir -p "$root/etc/sssd/conf.d" "$root/etc/pam.d" "$root/etc/pkcs11/modules" "$root/usr/lib/systemd/system" \
    "$root/usr/libexec/sssd" "$root/var/lib/dpkg" "$root/var/lib/sss/db" "$root/var/lib/sss/mc" \
    "$root/var/lib/sss/pipes/private" "$root/var/lib/sss/pubconf/krb5.include.d" "$root/var/lib/sss/gpo_cache" \
    "$root/var/log/sssd" "$root/var/log/journal" "$root/tmp" "$stubs" "$journal"

# As in test-credentials-config.sh, the fixture names the test user root and the test group sssd.
me="$(id -u)"
touch "$root/probe"
my_group="$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_gid)' "$root/probe")"
rm "$root/probe"
printf 'root:x:%s:%s::/root:/bin/sh\nsssd:x:%s:%s::/var/lib/sss:/usr/sbin/nologin\nalice:x:1000:1000::/home/alice:/bin/bash\n' \
    "$me" "$((my_group + 1))" "$((me + 1))" "$my_group" > "$root/etc/passwd"
printf 'root:x:%s:\nsssd:x:%s:\n' "$((my_group + 1))" "$my_group" > "$root/etc/group"
printf '[Service]\nUser=sssd\n' > "$root/usr/lib/systemd/system/sssd.service"
printf '[Socket]\nListenStream=/var/lib/sss/pipes/nss\n' > "$root/usr/lib/systemd/system/sssd-nss.socket"

cat > "$root/etc/sssd/sssd.conf" <<'EOF'
[sssd]
domains = corp.example

[domain/corp.example]
id_provider = ad
cache_credentials = True
krb5_store_password_if_offline = True
EOF
chmod 640 "$root/etc/sssd/sssd.conf"
# Healthy state: private db and gpo_cache, public pipes and pubconf, all writable by the service user's group.
chmod 770 "$root/var/lib/sss/db" "$root/var/lib/sss/gpo_cache" "$root/var/lib/sss/pipes/private"
chmod 775 "$root/var/lib/sss/mc" "$root/var/lib/sss/pipes" "$root/var/lib/sss/pubconf" "$root/var/log/sssd"
chmod 1777 "$root/tmp"
# Ubuntu's sssd-krb5-common makes SSSD's generated Kerberos snippets group-writable by sssd.
chmod 775 "$root/var/lib/sss/pubconf/krb5.include.d"
for helper in krb5_child ldap_child sssd_pam; do
    printf '#!/bin/sh\n' > "$root/usr/libexec/sssd/$helper"
    chmod 750 "$root/usr/libexec/sssd/$helper"
done
printf 'auth [success=1 default=ignore] pam_sss.so\nauth requisite pam_deny.so\n' > "$root/etc/pam.d/common-auth"
printf 'account [default=bad success=ok user_unknown=ignore] pam_sss.so\n' > "$root/etc/pam.d/common-account"
printf 'session optional pam_mkhomedir.so\n' > "$root/etc/pam.d/common-session"
printf '@include common-auth\n@include common-account\n@include common-session\n' > "$root/etc/pam.d/gdm-password"
printf 'includedir /var/lib/sss/pubconf/krb5.include.d/\n[libdefaults]\n' > "$root/etc/krb5.conf"

dpkg_status() {
    : > "$root/var/lib/dpkg/status"
    while [[ $# -gt 0 ]]; do
        printf 'Package: %s\nStatus: %s\nVersion: %s\n\n' "$1" "$2" "$3" >> "$root/var/lib/dpkg/status"
        shift 3
    done
}
ok='install ok installed'
dpkg_status sssd-common "$ok" 2.12.0-1ubuntu5.5 sssd-krb5-common "$ok" 2.12.0-1ubuntu5.5 libpam-sss "$ok" 2.12.0-1ubuntu5.5

# Keytabs are written from (principal, enctype) pairs with recognizable fake key bytes that must never print.
keytab() {
    python3 - "$root/etc/krb5.keytab" "$@" <<'EOF'
import struct, sys
out = bytearray(b"\x05\x02")
for enctype in sys.argv[2:]:
    entry = struct.pack(">H", 1) + struct.pack(">H", 12) + b"CORP.EXAMPLE" + struct.pack(">H", 7) + b"LAPTOP$"
    entry += struct.pack(">IIBH", 1, 1700000000, 3, int(enctype)) + struct.pack(">H", 11) + b"KEYMATERIAL"
    entry += struct.pack(">I", 3)
    out += struct.pack(">i", len(entry)) + entry
open(sys.argv[1], "wb").write(bytes(out))
EOF
    chmod 600 "$root/etc/krb5.keytab"
}
keytab 18 17

cat > "$stubs/journalctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *--list-boots*) echo '[]' ;;
    *_TRANSPORT=*) cat "$journal/kernel" 2>/dev/null ;;
    *SYSLOG_FACILITY=*) cat "$journal/auth" 2>/dev/null ;;
    *sssd*) cat "$journal/sssd" 2>/dev/null ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "Issues identified by validators: 0\\n"\n' > "$stubs/sssctl"
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
section() {
    # Print one status section, from its title to the next title.
    awk -v title="$1:" '$0 == title {on = 1; next} /^[A-Z][A-Za-z ]*:$/ {on = 0} on' "$test_dir/out"
}

# Pure helpers: Debian version order, capability blobs, and keytab parsing.
python3 - "$repo_root/scripts/credentials-platform.py" <<'EOF'
import importlib.util, struct, sys
spec = importlib.util.spec_from_file_location("credentials_platform", sys.argv[1])
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
cmp = platform.compare_versions
assert cmp("2.12.0-1ubuntu5.2", "2.12.0-1ubuntu5.10") < 0
assert cmp("2.12.0-1ubuntu5.3", "2.12.0-1ubuntu5.3") == 0
assert cmp("2.12.0-1ubuntu5~26.04.1", "2.12.0-1ubuntu5") < 0
assert cmp("1:2.0-1", "2.12.0-1") > 0
assert cmp("2.12.1-1", "2.12.0-1ubuntu9") > 0
caps = struct.pack("<IIIII", 0x02000001, (1 << 2) | (1 << 6) | (1 << 7), 0, 0, 0)
assert platform.parse_capabilities(caps) == {2, 6, 7}
assert platform.parse_capabilities(struct.pack("<III", 0x01000000, 1 << 2, 0)) == {2}
fold = platform.fold_capability_set
needed = {"cap_dac_read_search", "cap_setuid", "cap_setgid"}
assert fold([]) == set(platform.ALL_CAPS)
assert needed <= fold(["CAP_DAC_READ_SEARCH CAP_SETUID CAP_SETGID", "CAP_CHOWN"])
assert fold(["CAP_DAC_READ_SEARCH CAP_SETUID CAP_SETGID", ""]) == set()
assert fold(["~CAP_SETUID"]) == set(platform.ALL_CAPS) - {"cap_setuid"}
assert "cap_setuid" in fold(["CAP_CHOWN", "~CAP_SETUID", "CAP_SETUID"])
assert fold(["", "CAP_CHOWN"]) == {"cap_chown"}
EOF

# A healthy Ubuntu 26.04 layout: only the missing helper capabilities (fixtures cannot set them) are flagged.
status
cp "$test_dir/out" "$test_dir/healthy"
check '^info: installed: libpam-sss 2.12.0-1ubuntu5.5, sssd-common 2.12.0-1ubuntu5.5'
section 'State directories' > "$test_dir/section"
[[ ! -s "$test_dir/section" ]] || { cat "$test_dir/out" >&2; exit 1; }
check '^info: gdm-password: auth pam_sss; account pam_sss; session pam_mkhomedir'
check '^info: keytab: 2 key(s) for 1 principal(s); types aes128-cts-hmac-sha1-96, aes256-cts-hmac-sha1-96$'
check '^info: smartcard login is off'
refute 'tickets go to FILE:/tmp/krb5cc_%U (the SSSD default) but'
refute 'KEYMATERIAL'
if python3 -c 'import os; os.getxattr' 2>/dev/null; then
    check '^warning: /usr/libexec/sssd/krb5_child lacks cap_dac_read_search, cap_setgid, cap_setuid'
else
    check 'file capabilities of /usr/libexec/sssd/krb5_child'
fi
check 'systemd unit and socket state, sssd --version, NTP sync, and mount options (live system only)'
refute 'is not fully installed'
refute 'redirect Kerberos'

# Packaging: partial installs, mixed versions, and Ubuntu fixes the upstream version hides.
dpkg_status sssd-common 'install ok half-configured' 2.12.0-1ubuntu5.1 sssd-krb5-common "$ok" 2.12.0-1ubuntu5.5 \
    libpam-krb5 "$ok" 4.11-1
status
check '^warning: sssd-common is not fully installed (install ok half-configured); finish it with sudo dpkg --configure -a'
check '^warning: SSSD packages are at different versions (2.12.0-1ubuntu5.1, 2.12.0-1ubuntu5.5)'
check '^warning: sssd-common 2.12.0-1ubuntu5.1 predates 2.12.0-1ubuntu5.2, where helper capabilities'
check '^warning: sssd-common 2.12.0-1ubuntu5.1 predates 2.12.0-1ubuntu5.3, where the PAM responder'
check '^info: libpam-krb5 is installed'
dpkg_status sssd-common "$ok" 2.12.0-1ubuntu5.5

# Helpers: ownership and mode follow the package; a drop-in can strip capabilities.
chmod 755 "$root/usr/libexec/sssd/ldap_child"
mkdir -p "$root/etc/systemd/system/sssd.service.d" "$root/etc/systemd/system/sssd-nss.service.d"
printf '[Service]\nNoNewPrivileges=yes\nCapabilityBoundingSet=CAP_DAC_READ_SEARCH\n' \
    > "$root/etc/systemd/system/sssd.service.d/harden.conf"
printf '[Service]\nUser=root\n' > "$root/usr/lib/systemd/system/sssd-nss.service"
status
check '^warning: /usr/libexec/sssd/ldap_child is root:sssd 0755; the package installs it as root:sssd 0750'
check '^warning: sssd.service sets NoNewPrivileges'
check "^warning: sssd.service's CapabilityBoundingSet removes cap_setgid, cap_setuid"
check '^info: responder services run as a different user than sssd.service: sssd-nss.service as root'
chmod 750 "$root/usr/libexec/sssd/ldap_child"
# Repeated assignments merge, and an empty one empties the set.
printf '[Service]\nCapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SETUID CAP_SETGID\n' \
    > "$root/etc/systemd/system/sssd.service.d/harden.conf"
printf '[Service]\nCapabilityBoundingSet=CAP_CHOWN\n' > "$root/etc/systemd/system/sssd.service.d/more.conf"
status
refute 'CapabilityBoundingSet removes'
printf '[Service]\nCapabilityBoundingSet=\n' > "$root/etc/systemd/system/sssd.service.d/more.conf"
status
check "^warning: sssd.service's CapabilityBoundingSet removes cap_dac_read_search, cap_setgid, cap_setuid"
# The mount sandbox: ProtectSystem=strict makes the cache read-only unless a writable path or StateDirectory
# reopens it, the most specific setting wins, and InaccessiblePaths can hide the keytab.
printf '[Service]\nProtectSystem=strict\n' > "$root/etc/systemd/system/sssd.service.d/sandbox.conf"
status
check "^warning: sssd.service's sandbox makes /var/lib/sss/db, /var/lib/sss/mc, .*, /run/sssd, /var/log/sssd read-only, so SSSD cannot update its state there"
printf '[Service]\nProtectSystem=strict\nStateDirectory=sss\nReadWritePaths=-/var/log/sssd /run/sssd\n' \
    > "$root/etc/systemd/system/sssd.service.d/sandbox.conf"
status
refute 'read-only, so SSSD'
printf '[Service]\nReadWritePaths=/var\nReadOnlyPaths=/var/lib/sss\nInaccessiblePaths=-/etc/krb5.keytab\n' \
    > "$root/etc/systemd/system/sssd.service.d/sandbox.conf"
status
check "^warning: sssd.service's sandbox makes /var/lib/sss/db, /var/lib/sss/mc, .*/var/lib/sss/keytabs read-only"
refute "/var/log/sssd read-only"
check "^warning: sssd.service's InaccessiblePaths hides /etc/krb5.keytab from SSSD"
check 'sssd.service sandbox and capabilities as systemd applies them (read from unit files, an approximation)'
# Restricting one state directory under a writable parent, or a file inside one, is still found.
printf '[Service]\nReadOnlyPaths=/var/lib/sss/db\nInaccessiblePaths=/var/lib/sss/secrets/.secrets.mkey\n' \
    > "$root/etc/systemd/system/sssd.service.d/sandbox.conf"
status
check "^warning: sssd.service's sandbox makes /var/lib/sss/db read-only, so SSSD cannot update its state there"
check "^warning: sssd.service's sandbox makes /var/lib/sss/secrets/.secrets.mkey inaccessible"
printf '[Service]\nReadOnlyPaths=/var/lib/sss\nReadWritePaths=/var/lib/sss/db /var/lib/sss/mc /var/lib/sss/secrets\n%s\n' \
    'ReadWritePaths=/var/lib/sss/pipes /var/lib/sss/pubconf /var/lib/sss/gpo_cache /var/lib/sss/keytabs' \
    > "$root/etc/systemd/system/sssd.service.d/sandbox.conf"
status
refute "sandbox makes"
rm "$root/etc/systemd/system/sssd.service.d/sandbox.conf"

# On a live system these come from systemctl show; a failed call is reported and the unit files are read.
python3 - "$repo_root/scripts/credentials-platform.py" "$root" "$stubs" <<'EOF'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("credentials_platform", sys.argv[1])
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
root, stubs = Path(sys.argv[2]), Path(sys.argv[3])
os.environ["PATH"] = f"{stubs}:{os.environ['PATH']}"
systemctl = stubs / "systemctl"
systemctl.write_text("#!/usr/bin/env bash\nprintf 'NoNewPrivileges=no\\nCapabilityBoundingSet=cap_dac_read_search "
                     "cap_setuid\\nProtectSystem=strict\\nReadWritePaths=/var/log/sssd\\nStateDirectory=\\n'\n")
systemctl.chmod(0o755)
not_checked = []
found = platform.hardening_findings(root, True, not_checked)
assert ("warning", "sssd.service's CapabilityBoundingSet removes cap_setgid, which the helpers need") in found, found
assert any("makes /var/lib/sss/db, " in message for _level, message in found), found
assert not any("/var/log/sssd" in message for _level, message in found), found
assert not_checked == [], not_checked
systemctl.write_text("#!/usr/bin/env bash\necho 'Access denied' >&2\nexit 4\n")
not_checked = []
found = platform.hardening_findings(root, True, not_checked)
# The fallback still sees the empty CapabilityBoundingSet= drop-in from the case above.
assert found[0] == ("failed", "systemctl show sssd.service exited 4: Access denied; the unit files were read "
                    "instead"), found
assert "CapabilityBoundingSet removes cap_dac_read_search" in found[1][1], found
assert len(not_checked) == 1 and "approximation" in not_checked[0], not_checked
# A responder listed in [sssd] services makes its socket fail by design; an unlisted one failing is a problem.
systemctl.write_text("#!/usr/bin/env bash\nprintf '"
                     + "\\n\\n".join(f"Id={unit}\\nActiveState=failed\\nSubState=failed\\nUnitFileState=enabled"
                                     for unit in ("sssd-nss.socket", "sssd-pam-priv.socket", "sssd-kcm.socket"))
                     + "\\n'\n")
systemctl.chmod(0o755)
found = platform.runtime_findings([], ["nss", "pam"])
assert ("info", "sssd-nss.socket: failed/failed, user root; expected, because [sssd] services lists nss, so sssd "
        "starts that responder itself") in found, found
assert any(level == "info" and message.startswith("sssd-pam-priv.socket") for level, message in found), found
assert ("warning", "sssd-kcm.socket: failed/failed, user root") in found, found
systemctl.unlink()
EOF

rm -r "$root/etc/systemd/system/sssd.service.d" "$root/usr/lib/systemd/system/sssd-nss.service"

# State directories: private ones stay private, public ones stay reachable, and the service user can write.
chmod 755 "$root/var/lib/sss/db"
chmod 700 "$root/var/lib/sss/pubconf"
chmod 750 "$root/var/lib/sss/gpo_cache"
status
check '^warning: /var/lib/sss/db is open to other users but holds cached password hashes; remove their access with chmod o= /var/lib/sss/db, not a recursive chmod'
check '^warning: ordinary users cannot enter /var/lib/sss/pubconf'
check '^warning: the SSSD service user sssd cannot write to /var/lib/sss/gpo_cache'
chmod 770 "$root/var/lib/sss/db" "$root/var/lib/sss/gpo_cache"
chmod 775 "$root/var/lib/sss/pubconf"

# Configuration hygiene: removed options, misspelled sections, inline comments, and domain lists.
cp -p "$root/etc/sssd/sssd.conf" "$test_dir/sssd.conf"
cat >> "$root/etc/sssd/sssd.conf" <<'EOF'
ipa_enable_dns_sites = true
ldap_default_authtok = InlineSecretMustNeverPrint # temporary

[nsss]
filter_users = root

[domain/old.example]
id_provider = files
EOF
status
check '^warning: ipa_enable_dns_sites in \[domain/corp.example\] (/etc/sssd/sssd.conf) is removed in SSSD 2.11'
check '^warning: ldap_default_authtok in \[domain/corp.example\] (/etc/sssd/sssd.conf) has an inline comment'
check '^warning: \[nsss\] is not an SSSD section'
check '^info: \[domain/old.example\] is not in \[sssd\] domains, so SSSD ignores it'
refute 'InlineSecretMustNeverPrint'
sed -i.bak 's/^domains = corp.example$/domains = corp.example, old.example, gone.example/' "$root/etc/sssd/sssd.conf"
status
check '^warning: \[sssd\] domains lists gone.example, which has no \[domain/gone.example\] section'
check '^warning: old.example uses id_provider = files, which SSSD 2.11 removed'
logs
check '^warning: SSSD configuration is invalid: .*gone.example'
refute 'InlineSecretMustNeverPrint'
cp -p "$test_dir/sssd.conf" "$root/etc/sssd/sssd.conf"

# Values set in snippets name their file.
printf '[domain/corp.example]\nentry_cache_timeout = 600\n' > "$root/etc/sssd/conf.d/20-cache.conf"
chmod 640 "$root/etc/sssd/conf.d/20-cache.conf"
status
check 'entry_cache_timeout = 600  (from /etc/sssd/conf.d/20-cache.conf)'
rm "$root/etc/sssd/conf.d/20-cache.conf"

# Ticket caches: SSSD 2.11+ no longer creates missing parents; KCM needs its socket.
printf '[domain/corp.example]\nkrb5_ccname_template = FILE:/srv/krb5/cc_%%U\n' > "$root/etc/sssd/conf.d/30-cc.conf"
chmod 640 "$root/etc/sssd/conf.d/30-cc.conf"
status
check '^warning: tickets go to FILE:/srv/krb5/cc_%U (\[domain/corp.example\] krb5_ccname_template) but /srv/krb5 does not exist'
printf '[domain/corp.example]\nkrb5_ccname_template = DIR:/home/%%u/.krb5/cc\n' > "$root/etc/sssd/conf.d/30-cc.conf"
status
check '^info: tickets go to DIR:/home/%u/.krb5/cc .*no longer creates missing parent directories, and each user'
rm "$root/etc/sssd/conf.d/30-cc.conf"
printf 'includedir /var/lib/sss/pubconf/krb5.include.d/\n[libdefaults]\ndefault_ccache_name = KCM:\nallow_weak_crypto = true\n' \
    > "$root/etc/krb5.conf"
status
check '^warning: tickets go to KCM (default_ccache_name in /etc/krb5.conf) but sssd-kcm.socket is not installed'
check '^info: allow_weak_crypto is on in /etc/krb5.conf'
printf '[Socket]\nListenStream=/run/.heim_org.h5l.kcm-socket\n' > "$root/usr/lib/systemd/system/sssd-kcm.socket"
status
check '^info: tickets go to KCM (default_ccache_name in /etc/krb5.conf); sssd-kcm stores them'
printf 'includedir /var/lib/sss/pubconf/krb5.include.d/\n[libdefaults]\n' > "$root/etc/krb5.conf"

# Keytab encryption types; key bytes never print.
keytab 23 16
status
check '^warning: the keytab has only RC4, DES or 3DES keys'
keytab 18 23
status
check '^info: the keytab also has RC4 or 3DES keys'
printf 'garbage' > "$root/etc/krb5.keytab"
status
check '^warning: /etc/krb5.keytab is not a readable keytab'
keytab 18
refute 'KEYMATERIAL'

# PAM: a service that checks passwords but skips domain access rules, followed through substack.
printf 'auth substack common-auth\naccount required pam_unix.so\n' > "$root/etc/pam.d/sshd"
status
check '^info: sshd: auth pam_sss; account pam_unix; session none'
check '^warning: sshd checks domain passwords but not domain access rules'
rm "$root/etc/pam.d/sshd"

# Smartcard lane.
printf '[pam]\npam_cert_auth = True\n' > "$root/etc/sssd/conf.d/40-sc.conf"
chmod 640 "$root/etc/sssd/conf.d/40-sc.conf"
printf 'module: /usr/lib/x86_64-linux-gnu/pkcs11/vendor.so\n' > "$root/etc/pkcs11/modules/vendor.module"
dpkg_status sssd-common "$ok" 2.12.0-1ubuntu5.2
status
check '^warning: pam_cert_auth is on but the CA bundle /etc/sssd/pki/sssd_auth_ca_db.pem is missing'
check '^warning: /etc/pkcs11/modules/vendor.module points at /usr/lib/x86_64-linux-gnu/pkcs11/vendor.so, which is missing'
check '^warning: this sssd-common predates the slow-smartcard PAM responder crash fix'
check '^info: a smartcard failure does not mean password login fails'
rm "$root/etc/sssd/conf.d/40-sc.conf" "$root/etc/pkcs11/modules/vendor.module"
dpkg_status sssd-common "$ok" 2.12.0-1ubuntu5.5

# Kerberos writers: sssd may own its generated snippets, but nothing else; only root may own the keytab.
cp "$root/etc/passwd" "$test_dir/passwd"
printf 'root:x:%s:0::/root:/bin/sh\nsssd:x:%s:%s::/var/lib/sss:/usr/sbin/nologin\n' "$((me + 2))" "$me" "$my_group" \
    > "$root/etc/passwd"
status
refute '/var/lib/sss/pubconf/krb5.include.d is owned by'
check '^warning: /etc/krb5.conf is owned by sssd:sssd, so that account could redirect Kerberos'
check '^warning: /etc/krb5.keytab is owned by sssd:sssd, so that account can read and replace'
printf 'root:x:%s:0::/root:/bin/sh\nsssd:x:%s:%s::/var/lib/sss:/usr/sbin/nologin\nalice:x:%s:1000::/home/alice:/bin/bash\n' \
    "$((me + 2))" "$((me + 1))" "$my_group" "$me" > "$root/etc/passwd"
status
check '^warning: /var/lib/sss/pubconf/krb5.include.d is owned by alice:sssd, so that account could redirect Kerberos'
check '^warning: /etc/krb5.keytab is owned by alice:sssd, so that account can read and replace'
cp "$test_dir/passwd" "$root/etc/passwd"
mkdir -p "$root/etc/krb5.conf.d"
chmod 775 "$root/etc/krb5.conf.d"
printf 'includedir /etc/krb5.conf.d/\nincludedir /var/lib/sss/pubconf/krb5.include.d/\n[libdefaults]\n' > "$root/etc/krb5.conf"
status
check '^warning: /etc/krb5.conf.d (root:sssd 0775) is writable by its group, whose members could redirect Kerberos'
refute '/var/lib/sss/pubconf/krb5.include.d (root:sssd 0775) is writable'
printf 'includedir /var/lib/sss/pubconf/krb5.include.d/\n[libdefaults]\n' > "$root/etc/krb5.conf"

# Logs: AppArmor denials for SSSD only, ticket cache, home, crypto and keytab failures, PAM stages, collisions.
now_us="$(python3 -c 'import time; print(int(time.time() * 1e6) - 60000000)')"
entry() {
    printf '{"__CURSOR":"%s","__REALTIME_TIMESTAMP":"%s","SYSLOG_IDENTIFIER":"%s","_TRANSPORT":"%s","SYSLOG_FACILITY":"%s","MESSAGE":%s}\n' \
        "$1" "$now_us" "$2" "$3" "$4" "$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$5")"
}
{
    entry k1 kernel kernel '' 'audit: type=1400 apparmor="DENIED" operation="open" profile="/usr/sbin/sssd" name="/opt/vendor/ca.pem" pid=42 comm="sssd_pam" requested_mask="r"'
    entry k2 kernel kernel '' 'audit: type=1400 apparmor="DENIED" operation="open" profile="firefox" name="/etc/passwd" comm="firefox"'
} > "$journal/kernel"
{
    entry a1 'gdm-password]' syslog 10 'pam_sss(gdm-password:account): received for user alice@corp.example: 6 (Permission denied)'
    entry a2 'gdm-password]' syslog 10 'pam_sss(gdm-password:session): received for user bob@corp.example: 14 (Cannot make/remove an entry for the specified session)'
    entry a3 'gdm-password]' syslog 10 'pam_mkhomedir(gdm-password:session): unable to create and initialize directory /home/bob'
} > "$journal/auth"
{
    entry s1 krb5_child stdout '' "Failed to create ccache FILE:/srv/krb5/cc_1000: No such file or directory"
    entry s2 krb5_child stdout '' 'KDC has no support for encryption type'
    entry s3 ldap_child stdout '' 'Key version number for principal in key table is incorrect'
    entry s4 p11_child stdout '' 'p11_child failed: no certificate found'
} > "$journal/sssd"
logs
check '^warning: AppArmor denied an SSSD or Kerberos process (once'
check '^warning: AppArmor profile /usr/sbin/sssd denied open on /opt/vendor/ca.pem (1 time(s))'
refute 'firefox'
check '^warning: A Kerberos ticket cache could not be created'
check '^warning: The login session could not set up the home directory'
check '^warning: Kerberos found no permitted encryption type'
check '^warning: The machine keytab is out of date'
check '^info: Smartcard authentication reported a problem'
check '^warning: A domain account was refused at the account (access) stage'
check '^warning: A domain login failed at the session stage'
check '^warning: the local account alice shares its name with the domain user alice@corp.example'
refute 'bob shares'
refute 'pam-other\|pam_sss returned another PAM error'
echo 'Credential platform tests passed.'
