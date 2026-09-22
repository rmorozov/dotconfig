#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -eq 1 ]] || {
    echo "Usage: $0 <npm-package>" >&2
    exit 2
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/coc-extensions"
package_name="$1"

awk -v name="$package_name" '$1 == name { found=1 } END { exit !found }' "$MANIFEST" && {
    echo "Already configured: $package_name" >&2
    exit 1
}

version="$(npm view "$package_name" version --silent)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
    echo "Could not resolve $package_name" >&2
    exit 1
}

{
    head -n 1 "$MANIFEST"
    tail -n +2 "$MANIFEST"
    printf '%s %s\n' "$package_name" "$version"
} | { read -r header; printf '%s\n' "$header"; LC_ALL=C sort -u; } > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
bash "$REPO_ROOT/scripts/generate-coc-extensions.sh"
echo "Added $package_name@$version"
