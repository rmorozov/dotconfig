#!/usr/bin/env bash
# Seed fake credentials into the private proxy files and prove no dotconfig output or persisted file repeats them.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT
export HOME="$test_home/home"
export DOTCONFIG_PROXY_TEST_ROOT="$test_home/system"
state_dir="$HOME/.config/dotconfig"
mkdir -p "$state_dir" "$HOME/bin" "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d"
chmod 700 "$state_dir"
secret='Sup3r-Secret-Token-7f1c'
log="$test_home/log"

assert_no_secret() {
    # The private input files are the only places the secret may exist.
    local excludes=(--exclude=proxy.local --exclude=no-proxy.local)
    if grep -rqF "${excludes[@]}" -- "$secret" "$@"; then
        echo "Credential leaked in: $(grep -rlF "${excludes[@]}" -- "$secret" "$@" | tr '\n' ' ')" >&2
        exit 1
    fi
}

write_private() {
    printf '%s\n' "$1" > "$state_dir/proxy.local"
    printf '%s\n' "$2" > "$state_dir/no-proxy.local"
    chmod 600 "$state_dir/proxy.local" "$state_dir/no-proxy.local"
}

# Credentialed endpoints are refused without echoing the URL, loopback or not.
for endpoint in \
    "http://alice:${secret}@127.0.0.1:3128" \
    "http://alice:${secret}@proxy.corp.example:8080" \
    "http://${secret}@localhost:3128"; do
    write_private "export http_proxy='$endpoint'; export https_proxy=\"\$http_proxy\"" '.corp.example'
    if bash "$repo_root/scripts/proxy.sh" on > "$log" 2>&1; then
        echo "Credentialed proxy URL was accepted" >&2
        exit 1
    fi
    bash "$repo_root/scripts/proxy.sh" status >> "$log" 2>&1
    assert_no_secret "$log" "$HOME" "$DOTCONFIG_PROXY_TEST_ROOT"
done

# Extra private variables and malformed bypass entries stay private on a successful switch.
write_private \
    "export http_proxy='http://127.0.0.1:3129'; export https_proxy=\"\$http_proxy\"; export PROXY_PASSWORD='${secret}'" \
    "$(printf '.corp.example\nbad entry %s\n' "$secret")"
bash "$repo_root/scripts/proxy.sh" on > "$log" 2>&1
bash "$repo_root/scripts/proxy.sh" status >> "$log" 2>&1
grep -Fq 'Ignoring invalid entry in no-proxy.local' "$log"

cat > "$HOME/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/sudo-args"
EOF
chmod +x "$HOME/bin/sudo"
PATH="$HOME/bin:$PATH" bash "$repo_root/scripts/apt-get.sh" update >> "$log" 2>&1
(
    # shellcheck source=/dev/null
    source "$repo_root/home/dot_config/zsh/proxy.zsh"
    python3 "$repo_root/scripts/report.py" --role work --host-type laptop
    python3 "$repo_root/scripts/report.py" --role work --host-type laptop --json
) >> "$log" 2>&1 || true
bash "$repo_root/scripts/proxy.sh" off >> "$log" 2>&1
assert_no_secret "$log" "$HOME" "$DOTCONFIG_PROXY_TEST_ROOT"
echo 'Proxy credential hygiene tests passed.'
