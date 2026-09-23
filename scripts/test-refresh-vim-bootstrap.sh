#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
mkdir "$temp/bin"
cat > "$temp/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CURL_ARGS"
printf '%s\n' '" vim-bootstrap generated' 'call plug#begin()' 'source ~/.vim/plugin-lock.vim' 'call plug#end()'
CURL
chmod +x "$temp/bin/curl"
export PATH="$temp/bin:$PATH" TEST_CURL_ARGS="$temp/args"
cat > "$temp/profile" <<'PROFILE'
# Extending this file should change request parameters.
editor vim
language c
language python
plugin fzf
plugin vim-easymotion
PROFILE
printf 'previous\n' > "$temp/output"
bash "$REPO_ROOT/scripts/refresh-vim-bootstrap.sh" "$temp/profile" "$temp/output"
grep -Fxq -- '--data' "$temp/args"
grep -Fxq 'langs=c' "$temp/args"
grep -Fxq 'langs=python' "$temp/args"
grep -Fxq 'editor=vim' "$temp/args"
grep -Fxq 'additional-plugins=fzf,vim-easymotion' "$temp/args"
grep -Fxq '" vim-bootstrap snapshot; refreshed by .github/workflows/refresh-vim-bootstrap.yml' "$temp/output"

cat >> "$temp/profile" <<'PROFILE'
language python
PROFILE
if bash "$REPO_ROOT/scripts/refresh-vim-bootstrap.sh" "$temp/profile" "$temp/output" 2>/dev/null; then
    echo 'Duplicate language unexpectedly accepted' >&2
    exit 1
fi
grep -Fxq 'call plug#end()' "$temp/output"
echo 'Vim Bootstrap profile test passed'
