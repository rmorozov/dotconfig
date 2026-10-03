#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/repo/scripts" "$test_dir/repo/packages" "$test_dir/bin" "$test_dir/admin" "$test_dir/target"
cp "$repo_root/scripts/install-for-user.sh" "$test_dir/repo/scripts/"
export DOTCONFIG_TEST_LOG="$test_dir/log"
export ADMIN_PRIVATE_TOKEN=must-not-reach-target
export HOME="$test_dir/admin"
export PATH="$test_dir/bin:$PATH"
cat > "$test_dir/repo/packages/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'packages:%s\n' "$HOME" >> "$DOTCONFIG_TEST_LOG"
EOF
cat > "$test_dir/repo/install.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$HOME == '$test_dir/target' && \$USER == target && \$LOGNAME == target ]]
[[ -z \${ADMIN_PRIVATE_TOKEN+x} && -z \${DOTCONFIG_TEST_LOG+x} ]]
[[ \$* == '--skip-packages --skip-shell-change --skip-plugins' ]]
printf 'user-install:%s\\n' "\$HOME" >> '$test_dir/log'
EOF
cat > "$test_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '-u -- target' ]] && { echo 1234; exit; }
[[ "$*" == '-u -- root' ]] && { echo 0; exit; }
exit 1
EOF
cat > "$test_dir/bin/getent" <<EOF
#!/usr/bin/env bash
printf 'target:x:1234:1234:Target:$test_dir/target:/bin/bash\n'
EOF
cat > "$test_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
cat > "$test_dir/bin/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo:%s\\n' "\$*" >> '$test_dir/log'
case "\$1" in
    -v) exit 0 ;;
    -u) [[ \$2 == target && \$3 == -- ]]; shift 3; exec "\$@" ;;
    chsh) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/"*
git -C "$test_dir/repo" init -q -b master
git -C "$test_dir/repo" add .
git -C "$test_dir/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$test_dir/repo" remote add origin https://github.com/example/dotconfig.git
bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-plugins --skip-shell-change > "$test_dir/output"
grep -Fxq "packages:$test_dir/admin" "$test_dir/log"
grep -Fxq "user-install:$test_dir/target" "$test_dir/log"
target_repo="$test_dir/target/.local/share/dotconfig"
[[ "$(git -C "$target_repo" remote get-url origin)" == https://github.com/example/dotconfig.git ]]
[[ "$(git -C "$target_repo" symbolic-ref --short HEAD)" == master ]]
[[ "$(git -C "$target_repo" config branch.master.merge)" == refs/heads/master ]]
[[ "$(git -C "$target_repo" rev-parse HEAD)" == "$(git -C "$test_dir/repo" rev-parse HEAD)" ]]
# Existing checkout is refused before installing packages or touching its files.
: > "$test_dir/log"
if bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-plugins > "$test_dir/output" 2>&1; then exit 1; fi
if grep -q 'packages:\|user-install:\|sudo:chsh' "$test_dir/log"; then exit 1; fi
# Dirty source, unknown account, and root account are rejected.
printf change >> "$test_dir/repo/install.sh"
if bash "$test_dir/repo/scripts/install-for-user.sh" --user target > "$test_dir/output" 2>&1; then exit 1; fi
git -C "$test_dir/repo" checkout -- install.sh
if bash "$test_dir/repo/scripts/install-for-user.sh" --user missing > "$test_dir/output" 2>&1; then exit 1; fi
if bash "$test_dir/repo/scripts/install-for-user.sh" --user root > "$test_dir/output" 2>&1; then exit 1; fi
rm -rf "$target_repo"
: > "$test_dir/log"
bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-packages --skip-plugins > "$test_dir/output"
if grep -q 'packages:' "$test_dir/log"; then exit 1; fi
grep -q '^sudo:chsh -s .* target$' "$test_dir/log"
# Public option parsing fails cleanly before entering the privileged path.
if bash "$repo_root/install.sh" --user > "$test_dir/output" 2>&1; then exit 1; fi
echo 'Install-for-user orchestration tests passed.'
