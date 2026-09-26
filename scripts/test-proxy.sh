#!/usr/bin/env bash
# Intentional independent subshells test proxy mode transitions.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT
export HOME="$test_home"
mkdir -p "$HOME/.config/dotconfig" "$HOME/bin"
export DOTCONFIG_PROXY_TEST_ROOT="$test_home/system"
mkdir -p "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d"
chmod 700 "$HOME/.config/dotconfig"
printf 'custom-registry=https://registry.example\n' > "$HOME/.npmrc"
bash "$repo_root/scripts/proxy.sh" on > "$test_home/output"
(
    http_proxy='' https_proxy='' no_proxy=''
    # shellcheck source=/dev/null
    source "$repo_root/home/dot_config/zsh/proxy.zsh"
    [[ "$http_proxy" == 'http://127.0.0.1:3128' ]]
    [[ "$https_proxy" == "$http_proxy" ]]
    [[ "$no_proxy" == *'localhost'* ]]
)
[[ "$(bash "$repo_root/scripts/proxy.sh" status)" == *'listener not checked'* ]]
grep -q 'http_proxy="http://127.0.0.1:3128"' "$DOTCONFIG_PROXY_TEST_ROOT/etc/environment"
grep -q 'Acquire::https::Proxy "http://127.0.0.1:3128";' "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d/10-proxy.conf"
grep -q '^https-proxy=http://127.0.0.1:3128$' "$HOME/.npmrc"

cat > "$HOME/.config/dotconfig/proxy.local" <<'EOF'
export http_proxy='http://127.0.0.1:3129'
export https_proxy="$http_proxy"
export no_proxy='localhost,.internal.example'
EOF
chmod 600 "$HOME/.config/dotconfig/proxy.local"

bash "$repo_root/scripts/proxy.sh" on > "$test_home/output"
if grep -q '127.0.0.1:3129' "$test_home/output"; then exit 1; fi
(
    https_proxy='' no_proxy=''
    # shellcheck source=/dev/null
    source "$repo_root/home/dot_config/zsh/proxy.zsh"
    [[ "$https_proxy" == 'http://127.0.0.1:3129' ]]
    [[ "$no_proxy" == 'localhost,.internal.example' ]]
)

cat > "$HOME/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --preserve-env=* ]] || exit 1
[[ "$http_proxy" == 'http://127.0.0.1:3129' ]] || exit 1
printf '%s\n' "$*" > "$HOME/sudo-args"
EOF
chmod +x "$HOME/bin/sudo"
PATH="$HOME/bin:$PATH" bash "$repo_root/scripts/apt-get.sh" update
grep -q 'apt-get update' "$HOME/sudo-args"
if grep -q '127.0.0.1:3129' "$HOME/sudo-args"; then exit 1; fi

bash "$repo_root/scripts/proxy.sh" off > "$test_home/output"
[[ ! -e "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d/10-proxy.conf" ]]
[[ ! -e "$DOTCONFIG_PROXY_TEST_ROOT/etc/environment" ]]
grep -Fxq 'custom-registry=https://registry.example' "$HOME/.npmrc"
if grep -q '^https-proxy=' "$HOME/.npmrc"; then exit 1; fi
(
    export http_proxy='http://inherited.example' HTTPS_PROXY='http://inherited.example'
    # shellcheck source=/dev/null
    source "$repo_root/home/dot_config/zsh/proxy.zsh"
    [[ -z "${http_proxy+x}" && -z "${HTTPS_PROXY+x}" ]]
)
cat > "$HOME/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == apt-get && "$2" == update ]] || exit 1
[[ -z "${http_proxy+x}" ]] || exit 1
EOF
chmod +x "$HOME/bin/sudo"
PATH="$HOME/bin:$PATH" bash "$repo_root/scripts/apt-get.sh" update
[[ "$(bash "$repo_root/scripts/proxy.sh" status)" == 'Proxy: off' ]]

# Leave pre-existing settings untouched on both transitions.
printf 'HTTPS_PROXY="http://127.0.0.1:9999"\n' > "$DOTCONFIG_PROXY_TEST_ROOT/etc/environment"
printf 'Acquire::http::Proxy "http://127.0.0.1:9999";\n' > "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d/20-existing.conf"
printf 'https-proxy=http://127.0.0.1:9999\n' >> "$HOME/.npmrc"
bash "$repo_root/scripts/proxy.sh" on > "$test_home/output"
if grep -q 'dotconfig proxy begin' "$DOTCONFIG_PROXY_TEST_ROOT/etc/environment" "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d/10-proxy.conf" "$HOME/.npmrc" 2>/dev/null; then exit 1; fi
bash "$repo_root/scripts/proxy.sh" off > "$test_home/output"
grep -q '127.0.0.1:9999' "$DOTCONFIG_PROXY_TEST_ROOT/etc/environment"
grep -q '127.0.0.1:9999' "$DOTCONFIG_PROXY_TEST_ROOT/etc/apt/apt.conf.d/20-existing.conf"
grep -q '127.0.0.1:9999' "$HOME/.npmrc"
echo 'Proxy switch tests passed.'
