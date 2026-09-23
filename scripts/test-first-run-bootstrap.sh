#!/usr/bin/env bash
# Mock scripts intentionally contain literal references to their runtime variables.
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/repo/scripts" "$tmpdir/repo/packages" "$tmpdir/repo/home/dot_config/mise" "$tmpdir/bin" "$tmpdir/home"
cp "$REPO_ROOT/install.sh" "$tmpdir/repo/install.sh"
cp "$REPO_ROOT/scripts/manage-runtime-versions.sh" "$tmpdir/repo/scripts/"
cp "$REPO_ROOT/home/dot_config/mise/config.toml" "$tmpdir/repo/home/dot_config/mise/"

printf '%s\n' '#!/bin/sh' 'printf "Darwin\n"' > "$tmpdir/bin/uname"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$tmpdir/bin/brew"

printf '%s\n' '#!/bin/bash' \
    'printf "bootstrap:%s\n" "$1" >> "$DOTCONFIG_TEST_LOG"' \
    'mkdir -p "$HOME/.local/bin"' \
    'case "$1" in' \
    '  chezmoi) printf "%s\n" "#!/bin/sh" "printf \"chezmoi:init\\n\" >> \"\$DOTCONFIG_TEST_LOG\"" > "$HOME/.local/bin/chezmoi" ;;' \
    '  mise) printf "%s\n" "#!/bin/sh" "printf \"mise:install\\n\" >> \"\$DOTCONFIG_TEST_LOG\"" > "$HOME/.local/bin/mise" ;;' \
    '  *) exit 1 ;;' \
    'esac' \
    'chmod +x "$HOME/.local/bin/$1"' \
    > "$tmpdir/repo/scripts/install-bootstrap-tool.sh"
printf '%s\n' '#!/bin/sh' 'printf "package\n" >> "$DOTCONFIG_TEST_LOG"' \
    > "$tmpdir/repo/packages/install.sh"
printf '%s\n' '#!/bin/sh' 'printf "shell\n" >> "$DOTCONFIG_TEST_LOG"' \
    > "$tmpdir/repo/scripts/install-oh-my-zsh.sh"
chmod +x "$tmpdir/bin/uname" "$tmpdir/bin/brew"

DOTCONFIG_TEST_LOG="$tmpdir/log" HOME="$tmpdir/home" \
    PATH="$tmpdir/bin:/usr/bin:/bin" \
    bash "$tmpdir/repo/install.sh" --skip-plugins --skip-shell-change

printf '%s\n' \
    'bootstrap:chezmoi' \
    'bootstrap:mise' \
    'package' \
    'chezmoi:init' \
    'mise:install' \
    'shell' \
    > "$tmpdir/expected"
diff -u "$tmpdir/expected" "$tmpdir/log"

echo "First-run bootstrap order passed"
