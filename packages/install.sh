#!/usr/bin/env bash

set -Eeuo pipefail

PACKAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--dry-run]" >&2
    exit 2
fi

case "$(uname -s)" in
    Darwin)
        if ! command -v brew >/dev/null 2>&1; then
            echo "Homebrew is required before applying the macOS package baseline." >&2
            exit 1
        fi
        if "$DRY_RUN"; then
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
        if "$DRY_RUN"; then
            printf 'Ubuntu packages: %s\n' "${packages[*]}"
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
