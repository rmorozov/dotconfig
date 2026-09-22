#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -eq 3 ]] || {
    echo "Usage: $0 <capability> <homebrew-formula|-> <ubuntu-package|->" >&2
    exit 2
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/packages/packages.tsv"
capability="$1"
homebrew="$2"
ubuntu="$3"

for value in "$capability" "$homebrew" "$ubuntu"; do
    [[ "$value" =~ ^[A-Za-z0-9@+_.-]+$ ]] || {
        echo "Invalid package field: $value" >&2
        exit 2
    }
done

[[ "$homebrew" != "-" || "$ubuntu" != "-" ]] || {
    echo "At least one platform package is required." >&2
    exit 2
}

awk -v name="$capability" '$1 == name { found=1 } END { exit !found }' "$MANIFEST" && {
    echo "Capability already configured: $capability" >&2
    exit 1
}

{
    head -n 1 "$MANIFEST"
    tail -n +2 "$MANIFEST"
    printf '%s %s %s\n' "$capability" "$homebrew" "$ubuntu"
} | {
    read -r header
    printf '%s\n' "$header"
    LC_ALL=C sort -u
} > "$MANIFEST.tmp"

mv "$MANIFEST.tmp" "$MANIFEST"
bash "$REPO_ROOT/scripts/generate-native-packages.sh"
echo "Added $capability (Homebrew: $homebrew, Ubuntu: $ubuntu)"
