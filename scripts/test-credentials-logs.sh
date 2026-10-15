#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export DOTCONFIG_CREDS_TEST_ROOT="$test_dir/root"
root="$DOTCONFIG_CREDS_TEST_ROOT"
stubs="$test_dir/bin"
journal="$test_dir/journal"
mkdir -p "$root/etc/sssd" "$root/etc/pam.d" "$root/var/log/sssd" "$root/var/log/journal" "$root/var/lib/sss/pipes" \
    "$root/tmp" "$stubs" "$journal"
chmod 1777 "$root/tmp"

cat > "$root/etc/sssd/sssd.conf" <<'EOF'
[sssd]
domains = corp.example
services = nss, pam

[domain/corp.example]
id_provider = ad
EOF
chmod 600 "$root/etc/sssd/sssd.conf"
printf 'auth [success=2 default=ignore] pam_unix.so nullok\nauth [success=1 default=ignore] pam_sss.so use_first_pass\nauth requisite pam_deny.so\n' \
    > "$root/etc/pam.d/common-auth"
printf 'account [default=bad success=ok user_unknown=ignore] pam_sss.so\n' > "$root/etc/pam.d/common-account"
printf '@include common-auth\n@include common-account\n' > "$root/etc/pam.d/gdm-password"

# Two boots: in each, login fails before the VPN; in the second, SSSD stays unreachable after it connects.
python3 - "$root" "$journal" <<'EOF'
import datetime, gzip, json, sys
from pathlib import Path

root, journal = Path(sys.argv[1]), Path(sys.argv[2])
now = datetime.datetime.now().replace(microsecond=0)
boot1, boot2 = now - datetime.timedelta(days=2), now - datetime.timedelta(hours=1)
def at(boot, minutes):
    return boot + datetime.timedelta(minutes=minutes)

entries = {"auth": [], "sssd": [], "vpn": []}
def log(kind, when, ident, message, facility=None):
    entry = {"__CURSOR": f"c{len(sum(entries.values(), []))}-{kind}", "__REALTIME_TIMESTAMP": str(int(when.timestamp() * 1e6)),
             "SYSLOG_IDENTIFIER": ident, "MESSAGE": message}
    if facility:
        entry["SYSLOG_FACILITY"] = facility
    entries[kind].append(entry)

failure = "pam_sss(gdm-password:auth): received for user alice@corp.example: 9 (Authentication service cannot retrieve authentication info)"
for boot in (boot1, boot2):
    log("auth", at(boot, 1), "gdm-password]", failure, "10")
    log("vpn", at(boot, 3), "nm-openconnect-service", "Connected as 10.8.0.5, using SSL, with DTLS in progress")
log("auth", at(boot1, 4), "gdm-password]", "pam_sss(gdm-password:auth): authentication success; logname= uid=0 euid=0 tty=/dev/tty1 ruser= rhost= user=alice@corp.example", "10")
log("sssd", at(boot2, 0), "systemd", "sssd.service: Main process exited, code=killed, status=6/ABRT")
for kind in entries:
    (journal / kind).write_text("".join(json.dumps(e) + "\n" for e in entries[kind]))
(journal / "boots").write_text(json.dumps([{"boot_id": "a", "first_entry": int(boot1.timestamp() * 1e6)},
                                           {"boot_id": "b", "first_entry": int(boot2.timestamp() * 1e6)}]))

def sssd(when, text):
    return f"({when:%Y-%m-%d} {when.hour:2d}:{when:%M:%S}:000123): {text}\n"
old = now - datetime.timedelta(days=30)
(root / "var/log/sssd/sssd_corp.example.log").write_text(
    sssd(old, "[be[corp.example]] [sysdb_cache_auth] (0x0040): Too many failed logins.")
    + sssd(at(boot2, 1), "[be[corp.example]] [sysdb_cache_auth] (0x0400): Cached credentials not available.")
    + "   untimed continuation line\n"
    + sssd(at(boot2, 9), "[be[corp.example]] [fo_resolve_service_done] (0x0020): Failed to resolve server 'dc1.corp.example': Timeout")
    + sssd(at(boot2, 10), "[be[corp.example]] [confdb] (0x0010): Unknown option ldap_default_authtok = SecretMustNeverPrint"))
(root / "var/log/sssd/krb5_child.log").write_text(
    sssd(at(boot2, 12), "[krb5_child[4242]] [get_and_save_tgt] (0x0020): 1765328228: [-1765328228][Cannot contact any KDC for realm 'CORP.EXAMPLE']")
    + sssd(at(boot2, 13), "[krb5_child[4243]] [get_and_save_tgt] (0x0020): Clock skew too great"))
with gzip.open(root / "var/log/sssd/sssd.log.2.gz", "wt") as handle:
    handle.write(sssd(at(boot1, 30), "[sssd] [mt_svc_exit_handler] (0x0010): Child [123] ('corp.example':'%BE_corp.example') was terminated by own WATCHDOG"))
EOF

cat > "$stubs/journalctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *--list-boots*) cat "$journal/boots" ;;
    *SYSLOG_FACILITY=*) cat "$journal/auth" ;;
    *sssd*) cat "$journal/sssd" ;;
    *openconnect*) cat "$journal/vpn" ;;
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

bash "$repo_root/scripts/credentials.sh" check-logs > "$test_dir/out" 2>&1
check '^warning: Domain login failed: SSSD could not check the password (2 times'
check '^warning: SSSD had no cached password for an offline login (once'
check 'e.g. .* gdm-password\]: pam_sss(gdm-password:auth): received for user alice@corp.example: 9'
check '^warning: cause: cache_credentials is off for corp.example'
check '^warning: in 2 of 2 boot(s) with a VPN connection, domain login failed while SSSD was offline before the VPN connected; in 1 of them'
check '^warning: after the VPN connected .* still could not reach the domain (1 time'
check '^warning: Kerberos clock skew'
check '^warning: SSSD crashed, hung, or was restarted (2 times'
check '^ok: SSSD accepted domain logins'
check 'ldap_default_authtok = <hidden>'
check '/var/log/sssd/sssd.log.2.gz: 1 lines'
refute 'SecretMustNeverPrint'
refute 'Too many failed logins'
refute 'untimed continuation'

# The PAM stack is blamed when the configuration caches passwords but pam_krb5 skips pam_sss.
printf 'cache_credentials = True\n' >> "$root/etc/sssd/sssd.conf"
printf 'auth sufficient pam_krb5.so minimum_uid=1000\n' | cat - "$root/etc/pam.d/common-auth" > "$test_dir/pam"
cp "$test_dir/pam" "$root/etc/pam.d/common-auth"
bash "$repo_root/scripts/credentials.sh" check-logs --examples 2 > "$test_dir/out" 2>&1
check '^warning: cause: in gdm-password, pam_krb5 succeeds before pam_sss and skips it'
refute 'cause: cache_credentials'
[[ "$(grep -c 'e.g. .*received for user' "$test_dir/out")" == 2 ]] || { cat "$test_dir/out" >&2; exit 1; }

# A healthy window: an online login and an offline login from the cache, nothing else.
sed -i.bak '/pam_krb5/d' "$root/etc/pam.d/common-auth"
rm -f "$root"/var/log/sssd/*
now_us="$(python3 -c 'import time; print(int(time.time() * 1e6) - 60000000)')"
printf '{"__CURSOR":"h1","__REALTIME_TIMESTAMP":"%s","SYSLOG_IDENTIFIER":"gdm-password]","SYSLOG_FACILITY":"10","MESSAGE":"pam_sss(gdm-password:auth): authentication success; user=alice@corp.example"}\n' \
    "$now_us" > "$journal/auth"
printf '{"__CURSOR":"h2","__REALTIME_TIMESTAMP":"%s","SYSLOG_IDENTIFIER":"gdm-password]","SYSLOG_FACILITY":"10","MESSAGE":"Authenticated with cached credentials, your cached password will expire at: never"}\n' \
    "$now_us" >> "$journal/auth"
: > "$journal/sssd"
: > "$journal/vpn"
bash "$repo_root/scripts/credentials.sh" check-logs --days 1 > "$test_dir/out" 2>&1
refute '^warning'
check '^ok: offline login from cached credentials worked 1 time'
check '^info: SSSD logged nothing in this window'

# Scenarios below write the journal from "kind|minutes from now|identifier|message" lines.
cat > "$test_dir/journal.py" <<'EOF'
import datetime, json, sys
from pathlib import Path

out, boots, lines = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
now = datetime.datetime.now(datetime.timezone.utc)
def usec(minutes):
    return int((now + datetime.timedelta(minutes=float(minutes))).timestamp() * 1e6)
files = {"auth": [], "sssd": [], "vpn": []}
for number, line in enumerate(lines):
    kind, minutes, ident, message = line.split("|", 3)
    entry = {"__CURSOR": f"s{number}", "__REALTIME_TIMESTAMP": str(usec(minutes)), "SYSLOG_IDENTIFIER": ident,
             "MESSAGE": message}
    if kind == "auth":
        entry["SYSLOG_FACILITY"] = "10"
    files[kind].append(json.dumps(entry) + "\n")
for kind, entries in files.items():
    (out / kind).write_text("".join(entries))
(out / "boots").write_text(json.dumps([{"first_entry": usec(b)} for b in boots.split(",")]))
EOF
unavailable='pam_sss(gdm-password:auth): received for user alice@corp.example: 9 (Authentication service cannot retrieve authentication info)'
unknown='pam_sss(gdm-password:auth): received for user typo@corp.example: 10 (User not known to the underlying authentication module)'

# A reboot ends a VPN episode, so the next boot's pre-VPN failures are not blamed on VPN DNS. The offline failure
# has no online login in the window, but a password cached before the window may exist.
python3 "$test_dir/journal.py" "$journal" -180,-177 \
    'vpn|-179|nm-openconnect-service|Connected as 10.8.0.5, using SSL' \
    'sssd|-175|sssd_be|Failed to resolve server dc1.corp.example: Timeout' \
    "auth|-175|gdm-password]|$unavailable"
bash "$repo_root/scripts/credentials.sh" check-logs > "$test_dir/out" 2>&1
check '^warning: Domain login failed: SSSD could not check the password (once'
check '^info: 1 failed offline login: alice@corp.example via gdm-password, which no setting above explains. No online login through pam_sss is logged in this window, though a password cached earlier may still exist'
refute 'after the VPN connected'
refute 'boot(s) with a VPN connection'
refute '^warning: cause'
refute 'nothing to cache'

# An online machine with an unknown user and a PAM result 9 does not implicate the cache.
python3 "$test_dir/journal.py" "$journal" -60 "auth|-59|gdm-password]|$unknown" "auth|-58|gdm-password]|$unavailable"
bash "$repo_root/scripts/credentials.sh" check-logs > "$test_dir/out" 2>&1
check '^warning: SSSD did not know the user at login'
check '^info: pam_sss returned PAM result 9 1 time(s) with no sign that SSSD was offline'
refute 'boot(s) with a VPN connection'
refute 'cached earlier'

# ISO auth.log times keep their offset. With no auth entries in the journal the file is read; in a UTC process a
# +03:00 line from before the window stays out, and a -05:00 line inside it prints in UTC.
: > "$journal/auth"
python3 - "$root/var/log/auth.log" > "$test_dir/inside" <<'EOF'
import datetime, sys
utc = datetime.timezone.utc
now = datetime.datetime.now(utc).replace(microsecond=0)
outside = (now - datetime.timedelta(days=1, hours=2)).astimezone(datetime.timezone(datetime.timedelta(hours=3)))
inside = (now - datetime.timedelta(hours=2)).astimezone(datetime.timezone(datetime.timedelta(hours=-5)))
line = "{} laptop gdm-password]: pam_sss(gdm-password:auth): received for user {}@corp.example: 7 (Authentication failure)\n"
with open(sys.argv[1], "w") as handle:
    handle.write(line.format(f"{outside:%Y-%m-%dT%H:%M:%S}.000123+03:00", "outside"))
    handle.write(line.format(f"{inside:%Y-%m-%dT%H:%M:%S}.000123-05:00", "inside"))
print(inside.astimezone(utc).strftime("%Y-%m-%d %H:%M:%S"))
EOF
TZ=UTC bash "$repo_root/scripts/credentials.sh" check-logs --days 1 > "$test_dir/out" 2>&1
check '/var/log/auth.log: 1 lines'
check "e.g. $(cat "$test_dir/inside") gdm-password\\]: pam_sss(gdm-password:auth): received for user inside@"
refute 'outside@corp.example'
rm "$root/var/log/auth.log"

# Examples hide the whole remainder of a sensitive assignment, quoted or not.
python3 - "$repo_root/scripts/credentials-logs.py" <<'EOF'
import datetime, importlib.util, sys
spec = importlib.util.spec_from_file_location("credentials_logs", sys.argv[1])
logs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logs)
when = datetime.datetime.now(logs.UTC)
for text in ('Unknown option ldap_default_authtok = "two word secret"', "Unknown option krb5_password = two word secret",
             "Unknown option ldap_default_authtok='quoted value' trailing"):
    shown = logs.example(logs.Event(when, "sssd", text))
    assert shown.split("=", 1)[1].strip() == "<hidden>", shown
EOF

# Causes are scoped: each failure is explained only by its own domain's cache setting and its own PAM service's
# stack. A short name with two domains and a service without a PAM file leave only a hypothesis.
cp "$root/etc/sssd/sssd.conf" "$test_dir/sssd.conf"
cat > "$root/etc/sssd/sssd.conf" <<'EOF'
[sssd]
domains = corp.example, lab.example
services = nss, pam

[domain/corp.example]
id_provider = ad
cache_credentials = True

[domain/lab.example]
id_provider = ad
cache_credentials = False
EOF
printf 'auth sufficient pam_krb5.so minimum_uid=1000\n@include common-auth\n@include common-account\n' \
    > "$root/etc/pam.d/sshd"
failed() { echo "pam_sss($1:auth): received for user $2: 9 (Authentication service cannot retrieve authentication info)"; }
offline='sssd_be|Failed to resolve server dc1.corp.example: Timeout'
python3 "$test_dir/journal.py" "$journal" -60 \
    "sssd|-51|$offline" "auth|-50|gdm-password]|$(failed gdm-password bob@lab.example)" \
    "sssd|-41|$offline" "auth|-40|sshd|$(failed sshd alice@corp.example)" \
    "sssd|-31|$offline" "auth|-30|gdm-password]|$(failed gdm-password alice@corp.example)" \
    "sssd|-21|$offline" "auth|-20|su|$(failed su carol)"
bash "$repo_root/scripts/credentials.sh" check-logs > "$test_dir/out" 2>&1
check '^warning: cause: cache_credentials is off for lab.example, .*(1 failed offline login: bob@lab.example via gdm-password)'
check '^warning: cause: in sshd, pam_krb5 succeeds before pam_sss and skips it, .*(1 failed offline login: alice@corp.example via sshd)'
check '^possible cause: 1 failed offline login: carol via su. The domain and PAM stack of these logins cannot be determined, so the configuration to blame is a hypothesis: cache_credentials is off for lab.example; pam_krb5 skips pam_sss in sshd'
refute 'cause: .*alice@corp.example via gdm-password'
refute 'cause: cache_credentials.*alice'
refute 'cause: in sshd.*bob'
refute 'cause: in gdm-password'
cp "$test_dir/sssd.conf" "$root/etc/sssd/sssd.conf"
rm "$root/etc/pam.d/sshd"

# Without journal persistence or SSSD log files, the report says what it could not see.
rmdir "$root/var/log/journal"
rmdir "$root/var/log/sssd"
bash "$repo_root/scripts/credentials.sh" check-logs > "$test_dir/out" 2>&1
check 'journal is not kept across reboots'
check 'no /var/log/sssd logs'

for bad in '--days' '--days 0' '--days x' '--bogus'; do
    # shellcheck disable=SC2086 # Each case is a separate argument list.
    if bash "$repo_root/scripts/credentials.sh" check-logs $bad > /dev/null 2>&1; then
        echo "check-logs accepted: $bad" >&2
        exit 1
    fi
done
echo 'Credential log check tests passed.'
