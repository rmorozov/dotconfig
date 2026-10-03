#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export DOTCONFIG_CREDS_TEST_ROOT="$test_dir/root"
root="$DOTCONFIG_CREDS_TEST_ROOT"
stubs="$test_dir/bin"
calls="$test_dir/calls"
mkdir -p "$root/etc/sssd/conf.d" "$root/etc/pam.d" "$root/var/lib/sss/db" "$root/var/lib/sss/mc" "$stubs"
# shellcheck disable=SC2016 # A literal crypt hash, not an expansion.
hash_value='$6$saltsalt$NotARealHashButMustNeverPrint'

cat > "$root/etc/sssd/sssd.conf" <<'EOF'
[sssd]
domains = corp.example
services = nss, pam

[domain/corp.example]
id_provider = ad
ldap_default_authtok = BindPasswordMustNeverPrint
EOF
chmod 600 "$root/etc/sssd/sssd.conf"
cat > "$root/etc/pam.d/common-auth" <<'EOF'
auth	[success=3 default=ignore]	pam_krb5.so minimum_uid=1000
auth	[success=2 default=ignore]	pam_unix.so nullok try_first_pass
auth	[success=1 default=ignore]	pam_sss.so use_first_pass
auth	requisite			pam_deny.so
EOF
printf '@include common-auth\nauth optional pam_gnome_keyring.so\n' > "$root/etc/pam.d/gdm-password"
printf 'name\0alice@corp.example\0cachedPassword\0%s\0' "$hash_value" > "$root/var/lib/sss/db/cache_corp.example.ldb"
printf 'memcache' > "$root/var/lib/sss/mc/passwd"

for tool in kdestroy sss_cache klist; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$tool" "$calls" > "$stubs/$tool"
    chmod +x "$stubs/$tool"
done
export PATH="$stubs:$PATH"
fallback_only=true
command -v ldbsearch >/dev/null 2>&1 && fallback_only=false

bash "$repo_root/scripts/credentials.sh" status > "$test_dir/status" 2>&1
grep -q 'cache_credentials is off' "$test_dir/status"
grep -q 'pam_krb5 runs before pam_sss' "$test_dir/status"
grep -q 'id_provider = ad' "$test_dir/status"
if grep -Eq 'NeverPrint|ldap_default_authtok' "$test_dir/status"; then
    echo 'Credential inspection printed a secret' >&2
    exit 1
fi

# A healthy setup reports cached passwords and no warnings.
cat >> "$root/etc/sssd/sssd.conf" <<'EOF'
cache_credentials = True
krb5_store_password_if_offline = True
EOF
sed -i.bak '/pam_krb5/d' "$root/etc/pam.d/common-auth"
bash "$repo_root/scripts/credentials.sh" status > "$test_dir/status" 2>&1
if grep -q '^warning' "$test_dir/status"; then
    cat "$test_dir/status" >&2
    exit 1
fi
grep -q 'cache_credentials is on' "$test_dir/status"
if [[ "$fallback_only" == true ]]; then
    grep -q 'about 1 user record' "$test_dir/status"
fi

# With ldb-tools, only names and timestamps are requested from the cache.
cat > "$stubs/ldbsearch" <<'EOF'
#!/usr/bin/env bash
[[ "$3" == '(cachedPassword=*)' && "$*" != *' cachedPassword'* ]] || exit 1
printf 'dn: name=alice@corp.example\nname: alice@corp.example\nlastCachedPasswordChange: 1700000000\n'
EOF
chmod +x "$stubs/ldbsearch"
bash "$repo_root/scripts/credentials.sh" status > "$test_dir/status" 2>&1
grep -q 'cached password for alice@corp.example (stored 2023-11-' "$test_dir/status"
rm "$stubs/ldbsearch"

bash "$repo_root/scripts/credentials.sh" clear > "$test_dir/clear"
grep -qx 'kdestroy -A' "$calls"
grep -qx 'sss_cache -E' "$calls"
test -f "$root/var/lib/sss/db/cache_corp.example.ldb"

if bash "$repo_root/scripts/credentials.sh" clear --purge <<< 'no' > "$test_dir/clear" 2>&1; then
    echo 'Purge ran without confirmation' >&2
    exit 1
fi
test -f "$root/var/lib/sss/db/cache_corp.example.ldb"

bash "$repo_root/scripts/credentials.sh" clear --purge --yes > "$test_dir/clear"
[[ -z "$(find "$root/var/lib/sss/db" "$root/var/lib/sss/mc" -type f)" ]]
find "$root/var/lib/sss/dotconfig-backup" -name 'cache_corp.example.ldb' | grep -q .
find "$root/var/lib/sss/dotconfig-backup" -path '*/mc/passwd' | grep -q .
[[ "$(stat -c %a "$root/var/lib/sss/dotconfig-backup" 2>/dev/null || stat -f %Lp "$root/var/lib/sss/dotconfig-backup")" == 700 ]]

bash "$repo_root/scripts/credentials.sh" status > "$test_dir/status" 2>&1
grep -q 'nothing is cached for offline login' "$test_dir/status"
if bash "$repo_root/scripts/credentials.sh" clear --yes > /dev/null 2>&1; then exit 1; fi
echo 'Credential cache tests passed.'
