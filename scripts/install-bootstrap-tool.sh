#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -eq 1 ]] || {
    echo "Usage: $0 <chezmoi|homebrew|mise>" >&2
    exit 2
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/bootstrap-tools"
tool="$1"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

manifest_value() {
    local name="$1"
    awk -v name="$name" '$1 == name { print $2; found=1 } END { exit !found }' "$MANIFEST"
}

download() {
    curl \
        --fail \
        --location \
        --proto '=https' \
        --retry 3 \
        --show-error \
        --silent \
        --output "$2" \
        "$1"
    test -s "$2"
}

case "$tool" in
    chezmoi)
        version="$(manifest_value chezmoi)"
        installer_revision="$(manifest_value chezmoi-installer)"
        installer="$tmpdir/chezmoi-install.sh"
        download \
            "https://raw.githubusercontent.com/twpayne/chezmoi/$installer_revision/assets/scripts/install.sh" \
            "$installer"
        mkdir -p "$HOME/.local/bin"
        sh "$installer" -b "$HOME/.local/bin" -t "v$version"
        ;;
    homebrew)
        [[ "$(uname -s)" == Darwin ]] || {
            echo "Homebrew bootstrap is supported only on macOS." >&2
            exit 1
        }
        installer_revision="$(manifest_value homebrew-installer)"
        installer="$tmpdir/homebrew-install.sh"
        download \
            "https://raw.githubusercontent.com/Homebrew/install/$installer_revision/install.sh" \
            "$installer"
        NONINTERACTIVE=1 /bin/bash "$installer"
        ;;
    mise)
        version="$(manifest_value mise)"
        case "$(uname -s)" in
            Darwin) os=macos ;;
            Linux) os=linux ;;
            *) echo "Unsupported mise operating system: $(uname -s)" >&2; exit 1 ;;
        esac
        case "$(uname -m)" in
            arm64|aarch64) arch=arm64 ;;
            x86_64) arch=x64 ;;
            *) echo "Unsupported mise architecture: $(uname -m)" >&2; exit 1 ;;
        esac

        archive="mise-v$version-$os-$arch.tar.gz"
        release_url="https://github.com/jdx/mise/releases/download/v$version"
        download "$release_url/$archive" "$tmpdir/$archive"
        download "$release_url/SHASUMS256.txt" "$tmpdir/SHASUMS256.txt"
        expected="$(
            awk -v archive="$archive" '
                {
                    filename = $2
                    sub(/^\.\//, "", filename)
                    if (filename == archive) {
                        print $1
                        found = 1
                    }
                }
                END { exit !found }
            ' "$tmpdir/SHASUMS256.txt"
        )"
        if command -v sha256sum >/dev/null 2>&1; then
            printf '%s  %s\n' "$expected" "$tmpdir/$archive" | sha256sum -c -
        else
            actual="$(shasum -a 256 "$tmpdir/$archive" | awk '{ print $1 }')"
            [[ "$actual" == "$expected" ]] || {
                echo "mise checksum mismatch" >&2
                exit 1
            }
        fi

        tar -xzf "$tmpdir/$archive" -C "$tmpdir"
        mkdir -p "$HOME/.local/bin"
        install -m 755 "$tmpdir/mise/bin/mise" "$HOME/.local/bin/mise"
        ;;
    *)
        echo "Unknown bootstrap tool: $tool" >&2
        exit 2
        ;;
esac

echo "Installed pinned $tool bootstrap."
