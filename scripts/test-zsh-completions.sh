#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/repo/scripts" "$test_dir/repo/versions" "$test_dir/repo/home/dot_config/zsh" \
    "$test_dir/upstream/functions" "$test_dir/upstream/completions" "$test_dir/upstream/plugins/git" "$test_dir/home"
cp "$repo_root/scripts/install-oh-my-zsh.sh" "$repo_root/scripts/check-zsh-completions.sh" "$test_dir/repo/scripts/"
cp "$repo_root/home/dot_config/zsh/"*.zsh "$test_dir/repo/home/dot_config/zsh/"
printf '#compdef fixture\n' > "$test_dir/upstream/functions/_fixture"
printf '#compdef fixture\n' > "$test_dir/upstream/completions/_fixture2"
printf '#compdef git\n' > "$test_dir/upstream/plugins/git/_git"
git -C "$test_dir/upstream" init -q
git -C "$test_dir/upstream" add .
git -C "$test_dir/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$test_dir/upstream" rev-parse HEAD > "$test_dir/repo/versions/oh-my-zsh"
export HOME="$test_dir/home"
export OH_MY_ZSH_REPOSITORY="$test_dir/upstream"
export OH_MY_ZSH_HOME="$HOME/.oh-my-zsh"
unset ZSH_CUSTOM

# A permissive caller and shared Git setting must not create writable completions.
(
    umask 0002
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.sharedRepository GIT_CONFIG_VALUE_0=group \
        bash "$test_dir/repo/scripts/install-oh-my-zsh.sh" > "$test_dir/output" 2>&1
)
grep -q 'Zsh completion permissions: OK' "$test_dir/output"
[[ -z "$(find "$OH_MY_ZSH_HOME/functions" "$OH_MY_ZSH_HOME/completions" "$OH_MY_ZSH_HOME/plugins" \
    \( -perm -020 -o -perm -002 \) -print)" ]]

# Existing managed directories and files are repaired without following symlinks.
mkdir "$test_dir/external"
chmod 0777 "$test_dir/external"
ln -s "$test_dir/external" "$OH_MY_ZSH_HOME/unmanaged-link"
chmod g+w "$OH_MY_ZSH_HOME" "$OH_MY_ZSH_HOME/functions" "$OH_MY_ZSH_HOME/functions/_fixture"
bash "$test_dir/repo/scripts/install-oh-my-zsh.sh" > "$test_dir/output" 2>&1
[[ -z "$(find "$OH_MY_ZSH_HOME/functions" -perm -020 -print)" ]]
[[ -n "$(find "$test_dir/external" -perm -002 -print)" ]]

# Leave custom plugin code untouched, but fail the same audit used by status/doctor.
mkdir -p "$OH_MY_ZSH_HOME/custom/plugins/git"
printf '#compdef git\n' > "$OH_MY_ZSH_HOME/custom/plugins/git/_git"
chmod 0777 "$OH_MY_ZSH_HOME/custom/plugins/git"
if bash "$test_dir/repo/scripts/install-oh-my-zsh.sh" > "$test_dir/output" 2>&1; then
    echo 'Insecure custom completions unexpectedly accepted' >&2; exit 1
fi
grep -Fq "$OH_MY_ZSH_HOME/custom/plugins/git" "$test_dir/output"
grep -q 'Zsh completion audit failed' "$test_dir/output"
[[ -n "$(find "$OH_MY_ZSH_HOME/custom/plugins/git" -perm -002 -print)" ]]
chmod go-w "$OH_MY_ZSH_HOME/custom/plugins/git"
bash "$test_dir/repo/scripts/check-zsh-completions.sh" > "$test_dir/output" 2>&1

# Shared parents are reported, never chmodded automatically.
chmod o+w "$OH_MY_ZSH_HOME/custom/plugins"
if bash "$test_dir/repo/scripts/check-zsh-completions.sh" > "$test_dir/output" 2>&1; then
    echo 'Insecure completion parent unexpectedly accepted' >&2; exit 1
fi
grep -Fq "$OH_MY_ZSH_HOME/custom/plugins" "$test_dir/output"
[[ -n "$(find "$OH_MY_ZSH_HOME/custom/plugins" -prune -perm -002 -print)" ]]
chmod go-w "$OH_MY_ZSH_HOME/custom/plugins"

# Refuse to repair an installation root that redirects outside the managed tree.
ln -s "$OH_MY_ZSH_HOME" "$test_dir/linked-install"
if OH_MY_ZSH_HOME="$test_dir/linked-install" bash "$test_dir/repo/scripts/install-oh-my-zsh.sh" > "$test_dir/output" 2>&1; then
    echo 'Symlinked installation root unexpectedly accepted' >&2; exit 1
fi
grep -q 'Refusing a symlinked' "$test_dir/output"
if OH_MY_ZSH_HOME="$HOME" bash "$test_dir/repo/scripts/install-oh-my-zsh.sh" > "$test_dir/output" 2>&1; then
    echo 'Broad HOME installation root unexpectedly accepted' >&2; exit 1
fi
grep -q 'dedicated installation directory' "$test_dir/output"

# A caller that wants private files keeps its stricter mask.
(
    umask 0077
    OH_MY_ZSH_HOME="$HOME/private-oh-my-zsh" bash "$test_dir/repo/scripts/install-oh-my-zsh.sh" > "$test_dir/output" 2>&1
)
[[ -z "$(find "$HOME/private-oh-my-zsh/functions" \( -perm -040 -o -perm -004 \) -print)" ]]
echo 'Zsh completion installation permissions and audit tests passed.'
