#!/usr/bin/env bash
# Runs dotconfig creds against a real SSSD installation, as packaged, on a disposable Ubuntu machine such as a CI
# runner. It installs SSSD, writes an offline LDAP domain, and checks that the packaged service identity, helper
# metadata, directories and sandbox draw no permission or capability warnings. No domain login is tested here.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${DOTCONFIG_CREDS_LIVE_TEST:-}" == 1 ]] || {
    echo 'Refusing to reconfigure SSSD: set DOTCONFIG_CREDS_LIVE_TEST=1 on a disposable machine.' >&2
    exit 2
}
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sssd-ldap sssd-krb5 sssd-tools libpam-sss libnss-sss \
    ldb-tools krb5-user
# An unreachable LDAP domain keeps SSSD running offline without a directory or a keytab.
sudo tee /etc/sssd/sssd.conf > /dev/null <<'EOF'
[sssd]
domains = corp.example
services = nss, pam

[domain/corp.example]
id_provider = ldap
auth_provider = krb5
ldap_uri = ldap://127.0.0.1
ldap_search_base = dc=corp,dc=example
krb5_realm = CORP.EXAMPLE
krb5_server = 127.0.0.1
cache_credentials = True
EOF
# The Ubuntu 26.04 layout: the configuration readable by the sssd group only.
sudo chown root:sssd /etc/sssd/sssd.conf
sudo chmod 0640 /etc/sssd/sssd.conf
sudo systemctl restart sssd
sudo systemctl is-active sssd

echo '--- Package revisions'
dpkg-query -W -f '${Package} ${Version}\n' sssd-common sssd-krb5-common libpam-sss libkrb5-3 | sort
echo '--- dotconfig creds status'
bash "$repo_root/scripts/credentials.sh" status | tee "$out"

fail() { echo "Live check failed: $1" >&2; exit 1; }
grep -q 'service user: sssd (from systemctl show sssd.service)' "$out" || fail 'service identity not taken from systemd'
grep -q 'service groups: .*(as systemd reports them)' "$out" || fail 'service groups not taken from systemd'
grep -q '^ok: configuration files have an owner, group, and mode SSSD accepts' "$out" || fail 'root:sssd 0640 rejected'
# Anything the packaged layout itself would trigger is a false positive.
false_positive='cannot (read|enter|write|run)|is owned by|accessible to other users|lacks cap_|CapabilityBoundingSet|'
false_positive+='NoNewPrivileges|read-only|InaccessiblePaths|installs it as|not fully installed|different versions|'
false_positive+='^check failed|^not checked'
if grep -En "$false_positive" "$out"; then
    fail 'warnings above come from the packaged layout'
fi

echo '--- dotconfig creds check-logs'
bash "$repo_root/scripts/credentials.sh" check-logs --days 1 | tee "$out"
if grep -En "$false_positive|SSSD configuration is invalid" "$out"; then
    fail 'check-logs reported the packaged layout as a problem'
fi
echo 'Live credential checks passed.'
