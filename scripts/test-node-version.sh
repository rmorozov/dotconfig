#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

printf '[tools]\nnode = "24.21.0"\npython = "3.14.7"\n' > "$test_dir/config.toml"
[[ "$(bash "$REPO_ROOT/scripts/node-version.sh" "$test_dir/config.toml")" == 24.21.0 ]]

for invalid in missing duplicate alias; do
    case "$invalid" in
        missing) printf '[tools]\npython = "3.14.7"\n' > "$test_dir/config.toml" ;;
        duplicate) printf '[tools]\nnode = "24.21.0"\nnode = "24.22.0"\n' > "$test_dir/config.toml" ;;
        alias) printf '[tools]\nnode = "lts"\n' > "$test_dir/config.toml" ;;
    esac
    if bash "$REPO_ROOT/scripts/node-version.sh" "$test_dir/config.toml" >/dev/null 2>&1; then
        echo "Node pin reader accepted $invalid config" >&2
        exit 1
    fi
done

echo "Node version extraction passed"
