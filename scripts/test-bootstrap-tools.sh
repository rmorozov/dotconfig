#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin"
printf 'chezmoi 2.72.2\nmise 2026.9.12\n' > "$tmpdir/manifest"
printf '#!/bin/sh\nprintf "chezmoi version v2.72.2, commit test\\n"\n' > "$tmpdir/bin/chezmoi"
printf '#!/bin/sh\nprintf "2026.9.12 linux-x64 (test)\\n"\n' > "$tmpdir/bin/mise"
chmod +x "$tmpdir/bin/chezmoi" "$tmpdir/bin/mise"

PATH="$tmpdir/bin:$PATH" bash "$REPO_ROOT/scripts/check-bootstrap-tools.sh" "$tmpdir/manifest"

printf '#!/bin/sh\nprintf "2026.9.11 linux-x64 (test)\\n"\n' > "$tmpdir/bin/mise"
chmod +x "$tmpdir/bin/mise"
if PATH="$tmpdir/bin:$PATH" bash "$REPO_ROOT/scripts/check-bootstrap-tools.sh" "$tmpdir/manifest" > "$tmpdir/out" 2>&1; then
    echo "Expected mise version drift to fail" >&2
    exit 1
fi
grep -q 'mise drift: expected 2026.9.12, found 2026.9.11' "$tmpdir/out"

printf '#!/bin/sh\nprintf "2026.9.12 linux-x64 (test)\\n"\n' > "$tmpdir/bin/mise"
chmod +x "$tmpdir/bin/mise"
printf 'chezmoi 2.72.2\nmise 2026.9.13\n' > "$tmpdir/manifest"
if PATH="$tmpdir/bin:$PATH" bash "$REPO_ROOT/scripts/check-bootstrap-tools.sh" "$tmpdir/manifest" > "$tmpdir/out" 2>&1; then
    echo "Expected new manifest pin to reveal drift" >&2
    exit 1
fi
grep -q 'mise drift: expected 2026.9.13, found 2026.9.12' "$tmpdir/out"

echo "Bootstrap tool state tests passed"
