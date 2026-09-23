#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
remote="$test_root/upstream"
revision_file="$test_root/oh-my-zsh-pin"
git init -q "$remote"
git -C "$remote" config user.name test
git -C "$remote" config user.email test@example.com

plugin_names="$(zsh -f -c '
    source "$1"
    source "$2"
    source "$3"
    print -l -- "${plugins[@]}"
' -- "$REPO_ROOT/home/dot_config/zsh/common.zsh" \
    "$REPO_ROOT/home/dot_config/zsh/linux.zsh" \
    "$REPO_ROOT/home/dot_config/zsh/darwin.zsh")"
while IFS= read -r plugin; do
    mkdir -p "$remote/plugins/$plugin"
    touch "$remote/plugins/$plugin/$plugin.plugin.zsh"
done <<< "$plugin_names"
git -C "$remote" add plugins
git -C "$remote" commit -qm complete
expected="$(git -C "$remote" rev-parse HEAD)"
printf 'previous\n' > "$revision_file"

OH_MY_ZSH_REPOSITORY="$remote" OH_MY_ZSH_REVISION_FILE="$revision_file" \
    bash "$REPO_ROOT/scripts/update-oh-my-zsh.sh" >/dev/null
test "$(cat "$revision_file")" = "$expected"

rm "$remote/plugins/systemd/systemd.plugin.zsh"
git -C "$remote" add -u
git -C "$remote" commit -qm missing-plugin
if OH_MY_ZSH_REPOSITORY="$remote" OH_MY_ZSH_REVISION_FILE="$revision_file" \
    bash "$REPO_ROOT/scripts/update-oh-my-zsh.sh" >"$test_root/output" 2>&1; then
    echo 'Missing configured plugin unexpectedly accepted' >&2
    exit 1
fi
grep -q 'missing configured plugin: systemd' "$test_root/output"
test "$(cat "$revision_file")" = "$expected"
echo 'Oh My Zsh plugin refresh test passed'
