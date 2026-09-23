#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
vim_root="$test_root/vim"
coc_root="$test_root/coc"
vim_manifest="$test_root/vim-plugins"
vim_locations="$test_root/vim-plugin-locations"
coc_manifest="$test_root/coc-extensions"
vim_plug_manifest="$test_root/vim-plug"
vim_plug_file="$test_root/plug.vim"
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
git clone -q "$plugin_dir" "$test_root/.fzf"
printf "%s\n" "# plugin home-relative-directory" "fzf .fzf" > "$vim_locations"

printf '%s\n' \
    '# name repository ref commit' \
    "demo https://example.invalid/demo.git HEAD $revision" \
    "fzf https://example.invalid/fzf.git HEAD $revision" \
    > "$vim_manifest"
printf '%s\n' \
    '# npm package version' \
    'coc-demo 1.2.3' \
    > "$coc_manifest"
printf '%s\n' '{"name":"coc-demo","version":"1.2.3"}' > "$package_dir/package.json"
printf '%s\n' '" vim-plug test fixture' > "$vim_plug_file"
printf '%s %s\n' "$revision" "$(git hash-object "$vim_plug_file")" > "$vim_plug_manifest"
export VIM_PLUG_MANIFEST="$vim_plug_manifest" VIM_PLUG_FILE="$vim_plug_file"
export VIM_PLUGIN_LOCATIONS="$vim_locations" VIM_PLUGIN_HOMEDIR="$test_root"

VIM_PLUGIN_MANIFEST="$vim_manifest" \
COC_EXTENSION_MANIFEST="$coc_manifest" \
VIM_PLUGIN_HOME="$vim_root" \
COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >/dev/null

mv "$test_root/.fzf" "$test_root/fzf-hidden"
if VIM_PLUGIN_MANIFEST="$vim_manifest" \
    COC_EXTENSION_MANIFEST="$coc_manifest" \
    VIM_PLUGIN_HOME="$vim_root" \
    COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >"$test_root/output" 2>&1; then
    echo "Expected missing custom-location fzf to fail validation." >&2
    exit 1
fi
grep -q 'missing: Vim plugin fzf' "$test_root/output"
mv "$test_root/fzf-hidden" "$test_root/.fzf"

printf '%s\n' '" changed manager' > "$vim_plug_file"
if VIM_PLUGIN_MANIFEST="$vim_manifest" \
    COC_EXTENSION_MANIFEST="$coc_manifest" \
    VIM_PLUGIN_HOME="$vim_root" \
    COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >"$test_root/output" 2>&1; then
    echo "Expected vim-plug drift to fail validation." >&2
    exit 1
fi
grep -q 'drift: vim-plug' "$test_root/output"
rm "$vim_plug_file"
if VIM_PLUGIN_MANIFEST="$vim_manifest" \
    COC_EXTENSION_MANIFEST="$coc_manifest" \
    VIM_PLUGIN_HOME="$vim_root" \
    COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >"$test_root/output" 2>&1; then
    echo "Expected missing vim-plug to fail validation." >&2
    exit 1
fi
grep -q 'missing: vim-plug' "$test_root/output"
printf '%s\n' '" vim-plug test fixture' > "$vim_plug_file"

printf '%s\n' '{"name":"coc-demo","version":"9.9.9"}' > "$package_dir/package.json"
if VIM_PLUGIN_MANIFEST="$vim_manifest" \
    COC_EXTENSION_MANIFEST="$coc_manifest" \
    VIM_PLUGIN_HOME="$vim_root" \
    COC_EXTENSION_HOME="$coc_root" \
    bash "$REPO_ROOT/scripts/check-editor-state.sh" >/dev/null 2>&1; then
    echo "Expected CoC version drift to fail validation." >&2
    exit 1
fi
