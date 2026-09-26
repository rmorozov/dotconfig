#!/usr/bin/env bash
# Intentional independent subshells test proxy mode transitions.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT
export HOME="$test_home"
mkdir -p "$HOME/.config/dotconfig" "$HOME/bin"
chmod 700 "$HOME/.config/dotconfig"
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

cat > "$HOME/.config/dotconfig/proxy.local" <<'EOF'
export http_proxy='http://secret@proxy.example:8080'
export https_proxy="$http_proxy"
export no_proxy='localhost,.internal.example'
EOF
chmod 600 "$HOME/.config/dotconfig/proxy.local"

bash "$repo_root/scripts/proxy.sh" on > "$test_home/output"
if grep -q secret "$test_home/output"; then exit 1; fi
(
    https_proxy='' no_proxy=''
    # shellcheck source=/dev/null
    source "$repo_root/home/dot_config/zsh/proxy.zsh"
    [[ "$https_proxy" == 'http://secret@proxy.example:8080' ]]
    [[ "$no_proxy" == 'localhost,.internal.example' ]]
)

cat > "$HOME/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --preserve-env=* ]] || exit 1
[[ "$http_proxy" == 'http://secret@proxy.example:8080' ]] || exit 1
printf '%s\n' "$*" > "$HOME/sudo-args"
EOF
chmod +x "$HOME/bin/sudo"
PATH="$HOME/bin:$PATH" bash "$repo_root/scripts/apt-get.sh" update
grep -q 'apt-get update' "$HOME/sudo-args"
if grep -q secret "$HOME/sudo-args"; then exit 1; fi

bash "$repo_root/scripts/proxy.sh" off > "$test_home/output"
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
echo 'Proxy switch tests passed.'
