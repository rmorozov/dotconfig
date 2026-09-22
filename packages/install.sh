#!/usr/bin/env bash

set -Eeuo pipefail

PACKAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE=install

case "${1:-}" in
    "") ;;
    --check|--dry-run) MODE=check ;;
    *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

case "$(uname -s)" in
    Darwin)
        if ! command -v brew >/dev/null 2>&1; then
            echo "missing: Homebrew" >&2
            exit 1
        fi
        if [[ "$MODE" == check ]]; then
            brew bundle check --file "$PACKAGE_DIR/Brewfile"
        else
            brew bundle --file "$PACKAGE_DIR/Brewfile"
        fi
        ;;
    Linux)
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "The Linux package baseline currently supports Ubuntu/Debian only." >&2
            exit 1
        fi
        mapfile -t packages < <(sed -E '/^[[:space:]]*(#|$)/d' "$PACKAGE_DIR/ubuntu.txt")
        if [[ "$MODE" == check ]]; then
            missing=()
            for package_name in "${packages[@]}"; do
                dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null |
                    grep -q '^ii ' || missing+=("$package_name")
            done
            if (("${#missing[@]}" > 0)); then
                printf 'missing Ubuntu packages: %s\n' "${missing[*]}" >&2
                exit 1
            fi
            echo "Ubuntu package baseline is satisfied."
        else
            sudo apt-get update
            sudo apt-get install -y "${packages[@]}"
        fi
        ;;
    *)
        echo "Unsupported operating system: $(uname -s)" >&2
        exit 1
        ;;
esac
