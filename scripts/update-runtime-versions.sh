#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:-$REPO_ROOT/home/dot_config/mise/config.toml}"
CHANNELS_FILE="${2:-$REPO_ROOT/versions/runtime-channels}"

command -v mise >/dev/null 2>&1 || {
    echo "mise is required to resolve runtime versions" >&2
    exit 1
}

pins_file="$(mktemp)"
output="$(mktemp "${CONFIG_FILE}.XXXXXX")"
trap 'rm -f "$pins_file" "$output"' EXIT

while read -r tool selector executable version_argument extra; do
    [[ -n "$tool" && "$tool" != \#* ]] || continue
    [[ "$tool" =~ ^[a-z][a-z0-9_-]*$ && "$selector" == "$tool@"* && "$executable" =~ ^[a-z][a-z0-9_-]*$ && "$version_argument" =~ ^-{0,2}[a-z][a-z0-9-]*$ && -z "$extra" ]] || {
        echo "invalid runtime channel: $tool $selector $executable $version_argument $extra" >&2
        exit 1
    }
    version="$(mise latest "$selector")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "invalid resolved version for $tool: $version" >&2
        exit 1
    }
    printf '%s %s\n' "$tool" "$version" >> "$pins_file"
done < "$CHANNELS_FILE"

awk -v pins="$pins_file" '
    BEGIN {
        while ((getline < pins) > 0) {
            if (seen_pin[$1]++ || NF != 2) bad = 1
            version[$1] = $2
            total++
        }
        close(pins)
        if (!total || bad) exit 1
    }
    /^\[tools\]$/ { in_tools = 1; sections++; print; next }
    /^\[/ { in_tools = 0 }
    in_tools && /^[a-z][a-z0-9_-]*[[:space:]]*=/ {
        key = $1
        if (!(key in version) || seen_config[key]++) bad = 1
        else print key " = \"" version[key] "\""
        next
    }
    { print }
    END {
        for (key in version) if (seen_config[key] != 1) bad = 1
        if (sections != 1 || bad) exit 1
    }
' "$CONFIG_FILE" > "$output" || {
    echo "runtime config must contain each channel exactly once and no unmanaged tools" >&2
    exit 1
}

mv "$output" "$CONFIG_FILE"
trap - EXIT
rm -f "$pins_file"
echo "Updated runtime pins from $CHANNELS_FILE"
