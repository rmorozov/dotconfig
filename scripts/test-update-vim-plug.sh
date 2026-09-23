#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
remote="$test_root/remote"
git init -q "$remote"
git -C "$remote" config user.name test
git -C "$remote" config user.email test@example.com
printf '%s\n' 'function! plug#begin(...)' 'endfunction' 'function! plug#end()' 'endfunction' > "$remote/plug.vim"
git -C "$remote" add plug.vim
git -C "$remote" commit -qm initial

mkdir "$test_root/bin"
cat > "$test_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
while (( $# > 0 )); do
    if [[ "$1" == --output ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
if [[ "${BAD_DOWNLOAD:-0}" == 1 ]]; then
    printf 'invalid\n' > "$output"
else
    cp "$FIXTURE" "$output"
fi
CURL
chmod +x "$test_root/bin/curl"
export PATH="$test_root/bin:$PATH" FIXTURE="$remote/plug.vim"
printf 'previous\n' > "$test_root/plug.vim"
printf '%s\n' '0000000000000000000000000000000000000000 0000000000000000000000000000000000000000' > "$test_root/pin"
printf '%s\n' 'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim' > "$test_root/vimrc"
export VIM_PLUG_REPOSITORY="$remote" VIM_PLUG_TARGET="$test_root/plug.vim" \
    VIM_PLUG_MANIFEST="$test_root/pin" VIM_PLUG_SNAPSHOT="$test_root/vimrc"
bash "$REPO_ROOT/scripts/update-vim-plug.sh" >/dev/null
revision="$(git -C "$remote" rev-parse HEAD)"
read -r actual_revision blob < "$test_root/pin"
test "$actual_revision" = "$revision"
test "$blob" = "$(git hash-object "$test_root/plug.vim")"
grep -Fq "/$revision/plug.vim" "$test_root/vimrc"

printf 'new commit\n' >> "$remote/plug.vim"
git -C "$remote" add plug.vim
git -C "$remote" commit -qm next
export BAD_DOWNLOAD=1
if bash "$REPO_ROOT/scripts/update-vim-plug.sh" >"$test_root/output" 2>&1; then
    echo 'Malformed vim-plug source unexpectedly accepted' >&2
    exit 1
fi
test "$(awk '{ print $1 }' "$test_root/pin")" = "$revision"
test "$(git hash-object "$test_root/plug.vim")" = "$blob"
unset BAD_DOWNLOAD

# A snapshot validation failure must leave all committed files untouched.
printf 'invalid fallback\n' > "$test_root/vimrc"
if bash "$REPO_ROOT/scripts/update-vim-plug.sh" >"$test_root/output" 2>&1; then
    echo 'Invalid snapshot unexpectedly accepted' >&2
    exit 1
fi
test "$(awk '{ print $1 }' "$test_root/pin")" = "$revision"
test "$(git hash-object "$test_root/plug.vim")" = "$blob"

printf 'https://raw.githubusercontent.com/junegunn/vim-plug/%s/plug.vim\n' "$revision" > "$test_root/vimrc"
bash "$REPO_ROOT/scripts/update-vim-plug.sh" >/dev/null
next_revision="$(git -C "$remote" rev-parse HEAD)"
test "$(awk '{ print $1 }' "$test_root/pin")" = "$next_revision"
grep -Fq "/$next_revision/plug.vim" "$test_root/vimrc"

# Repair a stale URL even when the downloaded source has not changed.
printf 'https://raw.githubusercontent.com/junegunn/vim-plug/%s/plug.vim\n' "$revision" > "$test_root/vimrc"
bash "$REPO_ROOT/scripts/update-vim-plug.sh" >/dev/null
grep -Fq "/$next_revision/plug.vim" "$test_root/vimrc"

# Advancing upstream HEAD for an unrelated file must leave the pin stable.
printf 'docs\n' > "$remote/README"
git -C "$remote" add README
git -C "$remote" commit -qm docs
bash "$REPO_ROOT/scripts/update-vim-plug.sh" >/dev/null
test "$(awk '{ print $1 }' "$test_root/pin")" = "$next_revision"
echo 'vim-plug refresh staging and retry passed'
