#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture="$test_root/repo"
mkdir -p "$fixture/scripts" "$fixture/versions" "$fixture/home/dot_vim" "$test_root/bin"
cp "$REPO_ROOT/scripts/add-vim-plugin.sh" "$REPO_ROOT/scripts/generate-vim-plugin-lock.sh" "$fixture/scripts/"
printf '%s\n' '# name repository ref commit' > "$fixture/versions/vim-plugins"
printf '%s\n' '# plugin home-relative-directory' > "$fixture/versions/vim-plugin-locations"
: > "$fixture/home/dot_vimrc"
: > "$fixture/home/dot_vimrc.local.bundles"
cat > "$test_root/bin/git" <<'GIT'
#!/usr/bin/env bash
[[ "$1" == ls-remote ]] || exit 1
printf '%s\trefs/heads/%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$3"
GIT
chmod +x "$test_root/bin/git"
export PATH="$test_root/bin:$PATH"

if bash "$fixture/scripts/add-vim-plugin.sh" demo/custom HEAD ../escape >"$test_root/output" 2>&1; then
    echo 'Unsafe plugin directory unexpectedly accepted' >&2
    exit 1
fi
test "$(wc -l < "$fixture/versions/vim-plugins")" -eq 1

bash "$fixture/scripts/add-vim-plugin.sh" demo/custom HEAD .vim/custom >/dev/null
grep -Fxq 'custom .vim/custom' "$fixture/versions/vim-plugin-locations"
grep -Fq "Plug 'demo/custom', { 'dir': '~/.vim/custom' }" "$fixture/home/dot_vimrc.local.bundles"
grep -Fq "call s:DotconfigPin('custom', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')" "$fixture/home/dot_vim/plugin-lock.vim"

if bash "$fixture/scripts/add-vim-plugin.sh" other/custom >"$test_root/output" 2>&1; then
    echo 'Duplicate plugin name unexpectedly accepted' >&2
    exit 1
fi
test "$(grep -c '^custom ' "$fixture/versions/vim-plugin-locations")" -eq 1

bash "$fixture/scripts/add-vim-plugin.sh" demo/default >/dev/null
grep -Fxq "Plug 'demo/default'" "$fixture/home/dot_vimrc.local.bundles"
test "$(grep -vc '^#' "$fixture/versions/vim-plugin-locations")" -eq 1
echo 'Vim plugin helper updates custom and default paths'
