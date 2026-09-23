#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="${1:-$REPO_ROOT/home/dot_config/mise/config.toml}"

awk -F '"' '
    /^[[:space:]]*\[tools\][[:space:]]*$/ { in_tools = 1; next }
    /^[[:space:]]*\[/ { in_tools = 0 }
    in_tools && /^[[:space:]]*node[[:space:]]*=/ {
        if (NF != 3 || $2 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || count++) invalid = 1
        else version = $2
    }
    END {
        if (invalid || count != 1) exit 1
        print version
    }
' "$config_file" || {
    echo "Expected one exact Node version in $config_file" >&2
    exit 1
}
