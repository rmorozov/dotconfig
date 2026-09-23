#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/mise" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == latest ]] || exit 1
case "$2" in
    node@lts) echo 24.22.0 ;;
    go@latest) echo 1.28.0 ;;
    python@3.14) echo "${TEST_PYTHON_VERSION:-3.14.8}" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/mise"
export PATH="$test_dir/bin:$PATH"

cp "$REPO_ROOT/home/dot_config/mise/config.toml" "$test_dir/config.toml"
cp "$REPO_ROOT/versions/runtime-channels" "$test_dir/channels"
bash "$REPO_ROOT/scripts/update-runtime-versions.sh" "$test_dir/config.toml" "$test_dir/channels"
grep -Fxq 'node = "24.22.0"' "$test_dir/config.toml"
grep -Fxq 'go = "1.28.0"' "$test_dir/config.toml"
grep -Fxq 'python = "3.14.8"' "$test_dir/config.toml"

for failure in missing duplicate invalid_version invalid_command; do
    cp "$REPO_ROOT/home/dot_config/mise/config.toml" "$test_dir/config.toml"
    cp "$REPO_ROOT/versions/runtime-channels" "$test_dir/channels"
    case "$failure" in
        missing) sed -i.bak '/^go = /d' "$test_dir/config.toml" ;;
        duplicate) printf 'go = "1.0.0"\n' >> "$test_dir/config.toml" ;;
        invalid_version) export TEST_PYTHON_VERSION=latest ;;
        invalid_command) sed -i.bak 's/^go go@latest go version$/go go@latest go/' "$test_dir/channels" ;;
    esac
    cp "$test_dir/config.toml" "$test_dir/before"
    if bash "$REPO_ROOT/scripts/update-runtime-versions.sh" "$test_dir/config.toml" "$test_dir/channels" > "$test_dir/log" 2>&1; then
        echo "Updater accepted $failure" >&2
        exit 1
    fi
    cmp "$test_dir/before" "$test_dir/config.toml"
    unset TEST_PYTHON_VERSION
done

echo "Runtime refresh integrity tests passed"
