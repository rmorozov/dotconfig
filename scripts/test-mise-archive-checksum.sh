#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/scripts" "$tmpdir/versions" "$tmpdir/bin" "$tmpdir/home"
cp "$REPO_ROOT/scripts/install-bootstrap-tool.sh" "$tmpdir/scripts/"
printf 'mise 2026.9.12\nmise-linux-x64-sha256 %064d\n' 0 > "$tmpdir/versions/bootstrap-tools"

# shellcheck disable=SC2016 -- generated mock scripts must contain literal variable references
printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = -m ]; then printf "x86_64\n"; else printf "Linux\n"; fi' \
    > "$tmpdir/bin/uname"
# shellcheck disable=SC2016 -- generated mock scripts must contain literal variable references
printf '%s\n' '#!/bin/sh' \
    'while [ "$#" -gt 0 ]; do' \
    '    if [ "$1" = --output ]; then shift; destination="$1"; fi' \
    '    shift' \
    'done' \
    'printf "substituted archive" > "$destination"' \
    > "$tmpdir/bin/curl"
chmod +x "$tmpdir/bin/uname" "$tmpdir/bin/curl"

if HOME="$tmpdir/home" PATH="$tmpdir/bin:$PATH" \
    bash "$tmpdir/scripts/install-bootstrap-tool.sh" mise > "$tmpdir/out" 2>&1; then
    echo "Expected substituted archive to fail checksum validation" >&2
    exit 1
fi
test ! -e "$tmpdir/home/.local/bin/mise"

echo "Mise archive checksum rejection passed"
