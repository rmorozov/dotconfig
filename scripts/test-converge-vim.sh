#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/home"
cat > "$test_root/bin/vim" <<'VIM'
#!/usr/bin/env bash
printf 'vim\n' >> "$TEST_LOG"
exit "${VIM_EXIT:-0}"
VIM
chmod +x "$test_root/bin/vim"
export HOME="$test_root/home" PATH="$test_root/bin:$PATH" TEST_LOG="$test_root/log"

# A successful Vim process must still fail if dependencies are incomplete.
if bash "$REPO_ROOT/scripts/converge-vim.sh" >"$test_root/output" 2>&1; then
    echo 'Editor convergence accepted missing dependencies' >&2
    exit 1
fi
grep -q 'missing: vim-plug' "$test_root/output"
grep -q 'missing: Vim plugin' "$test_root/output"
grep -q 'missing: CoC extension' "$test_root/output"

# A Vim failure must fail immediately.
: > "$test_root/log"
if VIM_EXIT=1 bash "$REPO_ROOT/scripts/converge-vim.sh" >"$test_root/output" 2>&1; then
    echo 'Editor convergence ignored Vim failure' >&2
    exit 1
fi
test "$(wc -l < "$test_root/log")" -eq 1
echo 'Vim convergence failures are reported'
