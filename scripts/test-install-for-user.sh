#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/repo/scripts" "$test_dir/repo/packages" "$test_dir/bin" "$test_dir/admin" "$test_dir/target"
cp "$repo_root/scripts/install-for-user.sh" "$repo_root/scripts/proxy-files.py" "$test_dir/repo/scripts/"
cp "${repo_root}/scripts/install-progress.sh" "${test_dir}/repo/scripts/"
mkdir -p "$test_dir/repo/home/dot_config/zsh"
cp "$repo_root/home/dot_config/zsh/proxy.zsh" "$test_dir/repo/home/dot_config/zsh/"
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
[[ -z \${ADMIN_PRIVATE_TOKEN+x} && -z \${DOTCONFIG_TEST_LOG+x} && -z \${PROXY_PRIVATE_TOKEN+x} ]]
# shellcheck source=/dev/null
source "\$(dirname -- "\$0")/home/dot_config/zsh/proxy.zsh"
[[ \$* == '--skip-packages --skip-shell-change --skip-plugins' || \$* == '--skip-packages --skip-shell-change --skip-plugins --verbose' ]]
printf 'user-args:%s\\n' "\$*" >> '$test_dir/log'
printf 'proxy:%s|%s|%s|%s|%s|%s|%s\\n' \
    "\${http_proxy:-none}" "\${https_proxy:-none}" "\${HTTP_PROXY:-none}" "\${HTTPS_PROXY:-none}" \
    "\${no_proxy:-none}" "\${NO_PROXY:-none}" "\${NODE_USE_ENV_PROXY:-none}" >> '$test_dir/log'
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
printf '#!/bin/sh\nexit 0\n' > "$test_dir/bin/apt-get"
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
git -C "$test_dir/repo" update-ref refs/remotes/origin/master HEAD
bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-plugins --skip-shell-change --verbose > "$test_dir/output"
grep -Fxq 'user-args:--skip-packages --skip-shell-change --skip-plugins --verbose' "$test_dir/log"
grep -q 'SUCCESS: dotconfig installation completed successfully for target' "$test_dir/output"
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
grep -q '^sudo:chsh -s /\(usr/\)\?bin/zsh target$' "$test_dir/log"
# Reject a feature-only commit before sudo/package operations.
rm -rf "$target_repo"
git -C "$test_dir/repo" checkout -qb feature
printf 'feature' > "$test_dir/repo/feature"
git -C "$test_dir/repo" add feature
git -C "$test_dir/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm feature
: > "$test_dir/log"
if bash "$test_dir/repo/scripts/install-for-user.sh" --user target > "$test_dir/output" 2>&1; then exit 1; fi
[[ ! -s "$test_dir/log" && ! -e "$target_repo" ]]
git -C "$test_dir/repo" checkout -q master
# Custom local zsh must not become the login shell.
mkdir -p "$test_dir/target/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$test_dir/target/.local/bin/zsh"
chmod +x "$test_dir/target/.local/bin/zsh"
# Administrator proxy is inherited for first-run downloads, with no private variables.
mkdir -p "$HOME/.config/dotconfig"
printf 'on\n' > "$HOME/.config/dotconfig/proxy.mode"
cat > "$HOME/.config/dotconfig/proxy.local" <<'EOF'
export http_proxy=http://127.0.0.1:3129
export https_proxy="$http_proxy"
export PROXY_PRIVATE_TOKEN=must-not-reach-target
# Output from private code must not enter env assignments.
printf 'ProfileOutputMustNotReachTarget\n'
EOF
printf '.corp.example\n' > "$HOME/.config/dotconfig/no-proxy.local"
: > "$test_dir/log"
bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-packages --skip-plugins > "$test_dir/output"
grep -Fxq 'proxy:http://127.0.0.1:3129|http://127.0.0.1:3129|http://127.0.0.1:3129|http://127.0.0.1:3129|localhost,127.0.0.1,::1,.corp.example|localhost,127.0.0.1,::1,.corp.example|1' "$test_dir/log"
if grep -q 'PROXY_PRIVATE_TOKEN\|ProfileOutputMustNotReachTarget\|sudo:chsh.*local/bin' "$test_dir/log" "$test_dir/output"; then exit 1; fi
# The target's explicit off mode overrides session proxy inheritance.
rm -rf "$target_repo"
mkdir -p "$test_dir/target/.config/dotconfig"
printf 'off\n' > "$test_dir/target/.config/dotconfig/proxy.mode"
: > "$test_dir/log"
bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-packages --skip-plugins --skip-shell-change > "$test_dir/output"
grep -Fxq 'proxy:none|none|none|none|none|none|none' "$test_dir/log"
rm "$test_dir/target/.config/dotconfig/proxy.mode"
# Refuse a shell not listed in /etc/shells before changing the login shell.
rm -rf "$target_repo"
cat > "$test_dir/bin/grep" <<'EOF'
#!/usr/bin/env bash
for arg do
    [[ "$arg" == /etc/shells ]] && exit 1
done
exec /usr/bin/grep "$@"
EOF
chmod +x "$test_dir/bin/grep"
: > "$test_dir/log"
if bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-packages --skip-plugins > "$test_dir/output" 2>&1; then exit 1; fi
[[ ! -e "$target_repo" ]]
if /usr/bin/grep -q '^sudo:chsh' "$test_dir/log"; then exit 1; fi
rm "$test_dir/bin/grep"
# Reject remote/credential-bearing proxy endpoints before installing anything.
rm -rf "$target_repo"
printf 'export http_proxy=http://alice:SecretMustNotPrint@127.0.0.1:3128\nexport https_proxy="$http_proxy"\n' > "$HOME/.config/dotconfig/proxy.local"
: > "$test_dir/log"
if bash "$test_dir/repo/scripts/install-for-user.sh" --user target --skip-packages --skip-plugins > "$test_dir/output" 2>&1; then exit 1; fi
[[ ! -s "$test_dir/log" && ! -e "$target_repo" ]]
if grep -q 'SecretMustNotPrint' "$test_dir/output"; then exit 1; fi
# Public option parsing fails cleanly before entering the privileged path.
if bash "$repo_root/install.sh" --user > "$test_dir/output" 2>&1; then exit 1; fi
echo 'Install-for-user orchestration tests passed.'
