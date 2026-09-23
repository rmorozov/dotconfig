#!/usr/bin/env bash
# Generated mock scripts intentionally use literal variable references.
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/scripts" "$tmpdir/versions" "$tmpdir/bin" "$tmpdir/home"
cp "$REPO_ROOT/scripts/install-bootstrap-tool.sh" "$tmpdir/scripts/"
printf 'chezmoi 2.72.2\nchezmoi-linux-amd64-sha256 %064d\n' 0 > "$tmpdir/versions/bootstrap-tools"

printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = -m ]; then printf "x86_64\n"; else printf "Linux\n"; fi' \
    > "$tmpdir/bin/uname"
printf '%s\n' '#!/bin/sh' \
    'while [ "$#" -gt 0 ]; do' \
    '    if [ "$1" = --output ]; then shift; destination="$1"; fi' \
    '    shift' \
    'done' \
    'printf "substituted archive" > "$destination"' \
    > "$tmpdir/bin/curl"
chmod +x "$tmpdir/bin/uname" "$tmpdir/bin/curl"

if HOME="$tmpdir/home" PATH="$tmpdir/bin:$PATH" \
    bash "$tmpdir/scripts/install-bootstrap-tool.sh" chezmoi > "$tmpdir/out" 2>&1; then
    echo "Expected substituted chezmoi archive to fail checksum validation" >&2
    exit 1
fi
test ! -e "$tmpdir/home/.local/bin/chezmoi"

echo "Chezmoi archive checksum rejection passed"
