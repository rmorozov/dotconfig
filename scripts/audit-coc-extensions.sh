#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/coc-extensions"
audit_dir="$(mktemp -d)"
trap 'rm -rf "$audit_dir"' EXIT

{
    printf '%s\n' '{'
    printf '%s\n' '  "name": "dotconfig-coc-extension-audit",'
    printf '%s\n' '  "private": true,'
    printf '%s\n' '  "version": "0.0.0",'
    printf '%s\n' '  "dependencies": {'
    awk '
        NR > 1 {
            if (seen) {
                print ","
            }
            printf "    \"%s\": \"%s\"", $1, $2
            seen = 1
        }
        END {
            if (seen) {
                print ""
            }
        }
    ' "$MANIFEST"
    printf '%s\n' '  }'
    printf '%s\n' '}'
} > "$audit_dir/package.json"

(
    cd "$audit_dir"
    npm install         --package-lock-only         --ignore-scripts         --legacy-peer-deps         --no-audit         --no-fund
    npm audit --omit=dev --audit-level=high
)
