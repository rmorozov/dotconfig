#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/home/dot_config/mise/config.toml"

command -v mise >/dev/null 2>&1 || {
    echo "missing: mise; rerun the repository installer" >&2
    exit 1
}

pins=()
in_tools=false
seen=("")
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*\[tools\][[:space:]]*$ ]]; then
        in_tools=true
        continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\[ ]]; then
        in_tools=false
    fi
    "$in_tools" || continue
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([a-z][a-z0-9_-]*)[[:space:]]*=[[:space:]]*\"([0-9]+\.[0-9]+\.[0-9]+)\"[[:space:]]*(#.*)?$ ]]; then
        tool="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
        for existing in "${seen[@]}"; do
            if [[ "$existing" == "$tool" ]]; then
                echo "duplicate runtime pin: $tool" >&2
                exit 1
            fi
        done
        seen+=("$tool")
        pins+=("$tool@$version")
    else
        echo "invalid runtime pin in $CONFIG_FILE: $line" >&2
        exit 1
    fi
done < "$CONFIG_FILE"

((${#pins[@]} > 0)) || {
    echo "no runtime pins in $CONFIG_FILE" >&2
    exit 1
}

case "${1:-}" in
    install) mise install "${pins[@]}" ;;
    status)
        failures=0
        for pin in "${pins[@]}"; do
            if mise where "$pin" >/dev/null 2>&1; then
                echo "ok: $pin installed"
            else
                echo "missing: $pin" >&2
                failures=$((failures + 1))
            fi
        done
        ((failures == 0))
        ;;
    *) echo "Usage: $0 {install|status}" >&2; exit 2 ;;
esac
