#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"

cat > "$test_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_OS"
EOF
cat > "$test_dir/bin/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_COMMAND_LOG"
printf '%s\n' 'git (2.50) < 2.51'
EOF
cat > "$test_dir/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_COMMAND_LOG"
printf '%s\n' \
    'Inst git [2.49] (2.50 Ubuntu:26.04 [amd64])' \
    'Inst unrelated [1] (2 Ubuntu:26.04 [amd64])'
EOF
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export TEST_COMMAND_LOG="$test_dir/command.log"

export TEST_OS=Darwin
bash "$REPO_ROOT/packages/install.sh" --outdated > "$test_dir/output"
grep -q '^outdated --verbose --formula ' "$TEST_COMMAND_LOG"
grep -q ' git ' "$TEST_COMMAND_LOG"
grep -q 'git (2.50) < 2.51' "$test_dir/output"

export TEST_OS=Linux
bash "$REPO_ROOT/packages/install.sh" --outdated > "$test_dir/output"
grep -Fxq -- '-s upgrade' "$TEST_COMMAND_LOG"
grep -q '^Inst git ' "$test_dir/output"
if grep -q unrelated "$test_dir/output"; then
    echo "Unmanaged package included in baseline update report" >&2
    exit 1
fi
grep -q 'APT metadata may be stale' "$test_dir/output"

echo "Package freshness reports passed"
