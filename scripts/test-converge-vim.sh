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
# A fully pinned fixture should allow convergence to finish.
mkdir -p "$test_root/plugins/demo" "$test_root/coc/coc-demo"
git -C "$test_root/plugins/demo" init -q
git -C "$test_root/plugins/demo" config user.name test
git -C "$test_root/plugins/demo" config user.email test@example.com
printf 'plugin\n' > "$test_root/plugins/demo/plugin.vim"
git -C "$test_root/plugins/demo" add plugin.vim
git -C "$test_root/plugins/demo" commit -qm test
revision="$(git -C "$test_root/plugins/demo" rev-parse HEAD)"
printf '# name repository ref commit\ndemo local HEAD %s\n' "$revision" > "$test_root/vim-plugins"
printf '# npm package version\ncoc-demo 1.2.3\n' > "$test_root/coc-extensions"
printf '%s\n' '{"name":"coc-demo","version":"1.2.3"}' > "$test_root/coc/coc-demo/package.json"
printf 'manager\n' > "$test_root/plug.vim"
printf '%s %s\n' "$revision" "$(git hash-object "$test_root/plug.vim")" > "$test_root/vim-plug"
export VIM_PLUGIN_MANIFEST="$test_root/vim-plugins" VIM_PLUGIN_HOME="$test_root/plugins"
export COC_EXTENSION_MANIFEST="$test_root/coc-extensions" COC_EXTENSION_HOME="$test_root/coc"
export VIM_PLUG_MANIFEST="$test_root/vim-plug" VIM_PLUG_FILE="$test_root/plug.vim"
bash "$REPO_ROOT/scripts/converge-vim.sh" >"$test_root/output"
grep -q 'Editor dependencies match committed pins' "$test_root/output"
echo 'Vim convergence verifies installed pins'
