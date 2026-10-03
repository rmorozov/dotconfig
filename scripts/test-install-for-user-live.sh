#!/usr/bin/env bash
# Disposable Linux account verifies the actual sudo boundary; no package downloads.
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
target_home="$(mktemp -d)"
target_user="dotcfg-test-$RANDOM-$$"
created=false
cleanup() {
    if "$created"; then sudo userdel "$target_user"; fi
    sudo rm -rf "$target_home"
    rm -rf "$test_dir"
}
trap cleanup EXIT
sudo useradd --no-create-home --home-dir "$target_home" --shell /bin/bash "$target_user"
created=true
sudo chown "$target_user:" "$target_home"
# Prove the target cannot obtain administrative access.
if sudo -u "$target_user" -- sudo -n true 2>/dev/null; then
    echo 'Disposable target unexpectedly has sudo access.' >&2; exit 1;
fi
mkdir -p "$test_dir/repo/scripts"
cp "$repo_root/scripts/install-for-user.sh" "$test_dir/repo/scripts/"
cat > "$test_dir/repo/install.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -z "${ADMIN_PRIVATE_TOKEN+x}" ]]
[[ "$*" == '--skip-packages --skip-shell-change --skip-plugins' ]]
[[ "$(id -un)" == "$USER" && "$LOGNAME" == "$USER" ]]
id -u > "$HOME/setup-uid"
EOF
git -C "$test_dir/repo" init -q -b master
git -C "$test_dir/repo" add .
git -C "$test_dir/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$test_dir/repo" remote add origin https://github.com/example/dotconfig.git
ADMIN_PRIVATE_TOKEN=must-not-reach-target bash "$test_dir/repo/scripts/install-for-user.sh" \
    --user "$target_user" --skip-packages --skip-shell-change --skip-plugins
[[ "$(sudo cat "$target_home/setup-uid")" == "$(id -u "$target_user")" ]]
[[ -z "$(sudo find "$target_home" ! -user "$target_user" -print)" ]]
sudo -u "$target_user" -- git -C "$target_home/.local/share/dotconfig" status --porcelain
echo 'Real non-sudo account installation boundary passed.'
