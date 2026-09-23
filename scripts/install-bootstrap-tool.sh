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

verify_checksum() {
    local archive="$1"
    local expected="$2"
    local name="$3"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
        echo "Invalid pinned $name checksum" >&2
        return 1
    }
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
    else
        local actual
        actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
        [[ "$actual" == "$expected" ]] || {
            echo "$name checksum mismatch" >&2
            return 1
        }
    fi
}

case "$tool" in
    chezmoi)
        version="$(manifest_value chezmoi)"
        case "$(uname -s)" in
            Darwin) os=darwin ;;
            Linux) os=linux ;;
            *) echo "Unsupported chezmoi operating system: $(uname -s)" >&2; exit 1 ;;
        esac
        case "$(uname -m)" in
            arm64|aarch64) arch=arm64 ;;
            x86_64) arch=amd64 ;;
            *) echo "Unsupported chezmoi architecture: $(uname -m)" >&2; exit 1 ;;
        esac

        archive="chezmoi_${version}_${os}_${arch}.tar.gz"
        expected="$(manifest_value "chezmoi-$os-$arch-sha256")"
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
            echo "Invalid pinned chezmoi checksum for $os-$arch" >&2
            exit 1
        }
        download "https://github.com/twpayne/chezmoi/releases/download/v$version/$archive" "$tmpdir/$archive"
        verify_checksum "$tmpdir/$archive" "$expected" "chezmoi $os-$arch"
        tar -xzf "$tmpdir/$archive" -C "$tmpdir" chezmoi
        mkdir -p "$HOME/.local/bin"
        install -m 755 "$tmpdir/chezmoi" "$HOME/.local/bin/chezmoi"
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
        expected="$(manifest_value "mise-$os-$arch-sha256")"
        download "$release_url/$archive" "$tmpdir/$archive"
        verify_checksum "$tmpdir/$archive" "$expected" "mise $os-$arch"

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
