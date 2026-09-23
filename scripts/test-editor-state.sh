#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
vim_root="$test_root/vim"
coc_root="$test_root/coc"
vim_manifest="$test_root/vim-plugins"
coc_manifest="$test_root/coc-extensions"
plugin_dir="$vim_root/demo"
package_dir="$coc_root/coc-demo"

mkdir -p "$plugin_dir" "$package_dir"
git -C "$plugin_dir" init >/dev/null
git -C "$plugin_dir" config user.name test
git -C "$plugin_dir" config user.email test@example.com
printf '%s\n' test > "$plugin_dir/plugin.vim"
git -C "$plugin_dir" add plugin.vim
git -C "$plugin_dir" commit -m test >/dev/null
revision="$(git -C "$plugin_dir" rev-parse HEAD)"

printf '%s\n' \
    '# name repository ref commit' \
    "demo https://example.invalid/demo.git HEAD $revision" \
    > "$vim_manifest"
printf '%s\n' \
    '# npm package version' \
    'coc-demo 1.2.3' \
    > "$coc_manifest"
printf '%s\n' '{"name":"coc-demo","version":"1.2.3"}' > "$package_dir/package.json"

VIM_PLUGIN_MANIFEST="$vim_manifest" \
COC_EXTENSION_MANIFEST="$coc_manifest" \
VIM_PLUGIN_HOME="$vim_root" \
COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >/dev/null

printf '%s\n' '{"name":"coc-demo","version":"9.9.9"}' > "$package_dir/package.json"
if VIM_PLUGIN_MANIFEST="$vim_manifest" \
    COC_EXTENSION_MANIFEST="$coc_manifest" \
    VIM_PLUGIN_HOME="$vim_root" \
    COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >/dev/null 2>&1; then
    echo "Expected CoC version drift to fail validation." >&2
    exit 1
fi
