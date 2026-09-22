#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/vim-plugins"
updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT

printf '%s\n' '# name repository ref commit' > "$updated"
while read -r name repository ref _commit; do
    [[ -n "${name:-}" && "$name" != "#" ]] || continue
    revision="$(git ls-remote "$repository" "$ref" | awk 'NR == 1 { print $1 }')"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
        echo "Could not resolve $name from $repository ($ref)" >&2
        exit 1
    }
    printf '%s %s %s %s\n' "$name" "$repository" "$ref" "$revision" >> "$updated"
done < "$MANIFEST"

mv "$updated" "$MANIFEST"
trap - EXIT
bash "$REPO_ROOT/scripts/generate-vim-plugin-lock.sh"
