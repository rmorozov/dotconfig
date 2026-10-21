#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/repo/scripts" "$test_dir/repo/versions" "$test_dir/bin" "$test_dir/archive/mise/bin"
cp "$repo_root/scripts/install-bootstrap-tool.sh" "$test_dir/repo/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$test_dir/archive/chezmoi"
cp "$test_dir/archive/chezmoi" "$test_dir/archive/mise/bin/mise"
tar -czf "$test_dir/chezmoi.tar.gz" -C "$test_dir/archive" chezmoi
tar -czf "$test_dir/mise.tar.gz" -C "$test_dir/archive" mise
for tool in chezmoi mise; do
    if command -v sha256sum >/dev/null; then
        digest="$(sha256sum "$test_dir/$tool.tar.gz" | awk '{print $1}')"
    else
        digest="$(shasum -a 256 "$test_dir/$tool.tar.gz" | awk '{print $1}')"
    fi
    arch=amd64
    [[ "$tool" != mise ]] || arch=x64
    printf '%s 1.2.3\n%s-linux-%s-sha256 %s\n' "$tool" "$tool" "$arch" "$digest" >> "$test_dir/repo/versions/bootstrap-tools"
done
cat > "$test_dir/bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = -m ]; then echo x86_64; else echo Linux; fi
EOF
cat > "$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "${0##*/}" >> "$DOTCONFIG_TEST_DOWNLOAD_LOG"
destination=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) shift; destination="$1" ;;
        --output-document=*) destination="${1#*=}" ;;
    esac
    shift
done
[[ -n "$destination" ]]
cp "$DOTCONFIG_TEST_ARCHIVE" "$destination"
EOF
cp "$test_dir/bin/curl" "$test_dir/bin/wget"
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export DOTCONFIG_TEST_DOWNLOAD_LOG="$test_dir/log"
for downloader in curl wget; do
    for tool in chezmoi mise; do
        export HOME="$test_dir/$downloader-$tool"
        export DOTCONFIG_TEST_ARCHIVE="$test_dir/$tool.tar.gz"
        : > "$test_dir/log"
        DOTCONFIG_DOWNLOADER="$downloader" bash "$test_dir/repo/scripts/install-bootstrap-tool.sh" "$tool" > "$test_dir/out" 2>&1
        [[ "$(cat "$test_dir/log")" == "$downloader" ]]
        expected="$test_dir/archive/chezmoi"
        [[ "$tool" != mise ]] || expected="$test_dir/archive/mise/bin/mise"
        cmp "$HOME/.local/bin/$tool" "$expected"
        [[ -x "$HOME/.local/bin/$tool" ]]
        rm "$HOME/.local/bin/$tool"
        export DOTCONFIG_TEST_ARCHIVE="$test_dir/bad.tar.gz"
        printf 'not the pinned archive' > "$DOTCONFIG_TEST_ARCHIVE"
        if DOTCONFIG_DOWNLOADER="$downloader" bash "$test_dir/repo/scripts/install-bootstrap-tool.sh" "$tool" > "$test_dir/out" 2>&1; then
            echo 'An invalid checksum was accepted' >&2; exit 1
        fi
        [[ ! -e "$HOME/.local/bin/$tool" ]]
    done
done
: > "$test_dir/log"
if DOTCONFIG_DOWNLOADER=invalid bash "$test_dir/repo/scripts/install-bootstrap-tool.sh" chezmoi > "$test_dir/out" 2>&1; then exit 1; fi
[[ ! -s "$test_dir/log" ]]
for args in '--downloader invalid' '--downloader'; do
    # shellcheck disable=SC2086
    if bash "$repo_root/install.sh" $args > "$test_dir/out" 2>&1; then exit 1; fi
done
echo 'Bootstrap downloader tests passed.'
