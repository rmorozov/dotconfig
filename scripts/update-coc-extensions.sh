#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/coc-extensions"
updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT

printf '%s\n' '# npm package version' > "$updated"
while read -r package_name _version; do
    [[ -n "${package_name:-}" && "$package_name" != "#" ]] || continue
    version="$(npm view "$package_name" version --silent)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
        echo "Could not resolve $package_name" >&2
        exit 1
    }
    printf '%s %s\n' "$package_name" "$version" >> "$updated"
done < "$MANIFEST"

mv "$updated" "$MANIFEST"
trap - EXIT
bash "$REPO_ROOT/scripts/generate-coc-extensions.sh"
