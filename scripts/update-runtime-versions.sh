#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="${1:-home/dot_config/mise/config.toml}"

command -v mise >/dev/null 2>&1 || {
    echo "mise is required to resolve runtime versions" >&2
    exit 1
}

node_version="$(mise latest node@lts)"
go_version="$(mise latest go@latest)"
python_version="$(mise latest python@3.14)"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

awk \
    -v node="$node_version" \
    -v go="$go_version" \
    -v python="$python_version" '
    /^node = / { print "node = \"" node "\""; next }
    /^go = / { print "go = \"" go "\""; next }
    /^python = / { print "python = \"" python "\""; next }
    { print }
' "$CONFIG_FILE" > "$output"

mv "$output" "$CONFIG_FILE"
trap - EXIT

printf 'Pinned node=%s go=%s python=%s\n' \
    "$node_version" "$go_version" "$python_version"
