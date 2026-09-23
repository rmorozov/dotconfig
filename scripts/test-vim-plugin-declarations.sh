#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
vimrc="$test_root/vimrc"
bundles="$test_root/bundles"
manifest="$test_root/manifest"
printf "%s\n" \
    "Plug 'example/one'" \
    "if isdirectory('/some/path')" \
    "  Plug '/some/path' | Plug 'example/two'" \
    "else" \
    "  Plug 'example/two'" \
    "endif" > "$vimrc"
printf "Plug 'example/three'\n" > "$bundles"
printf '%s\n' \
    '# name repository ref commit' \
    'one https://example.invalid/one HEAD aaaa' \
    'two https://example.invalid/two HEAD bbbb' \
    'three https://example.invalid/three HEAD cccc' > "$manifest"
python3 "$REPO_ROOT/scripts/check-vim-plugin-declarations.py" "$vimrc" "$bundles" "$manifest" >/dev/null

sed -i.bak "/^three /d" "$manifest"
if python3 "$REPO_ROOT/scripts/check-vim-plugin-declarations.py" "$vimrc" "$bundles" "$manifest" >"$test_root/out" 2>&1; then
    echo 'Unpinned Plug declaration unexpectedly accepted' >&2
    exit 1
fi
grep -q 'Declared Vim plugin has no pin: three' "$test_root/out"

printf 'orphan https://example.invalid/orphan HEAD dddd\n' >> "$manifest"
if python3 "$REPO_ROOT/scripts/check-vim-plugin-declarations.py" "$vimrc" "$bundles" "$manifest" >"$test_root/out" 2>&1; then
    echo 'Unused plugin pin unexpectedly accepted' >&2
    exit 1
fi
grep -q 'Pinned Vim plugin has no declaration: orphan' "$test_root/out"
echo 'Vim declaration parity test passed'
