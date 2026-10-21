#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -eq 1 ]] || {
    echo "Usage: $0 <chezmoi|homebrew|mise>" >&2
    exit 2
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/bootstrap-tools"
tool="$1"
downloader="${DOTCONFIG_DOWNLOADER:-curl}"
[[ "$downloader" == curl || "$downloader" == wget ]] || {
    echo 'Downloader must be curl or wget.' >&2; exit 2;
}
command -v "$downloader" >/dev/null || { echo "Missing bootstrap downloader: $downloader" >&2; exit 1; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

manifest_value() {
    local name="$1"
    awk -v name="$name" '$1 == name { print $2; found=1 } END { exit !found }' "$MANIFEST"
}

download() {
    local status=0 setting version
    # Bash 3.2 (macOS) treats an empty array as unset under nounset.
    local curl_options=(--silent)
    echo "Downloading $tool bootstrap with $downloader." >&2
    if [[ "${DOTCONFIG_DOWNLOAD_VERBOSE:-false}" == true ]]; then
        printf '[dotconfig] Download URL: %s\n' "$1" >&2
        printf '[dotconfig] Downloader: %s; uid: %s\n' "$(command -v "$downloader")" "$(id -u)" >&2
        version="$("$downloader" --version)"
        printf '[dotconfig] %s\n' "${version%%$'\n'*}" >&2
        # Show effective environment presence, never proxy credentials or bypass lists.
        for setting in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
            CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR WGETRC; do
            if [[ -n "${!setting:-}" ]]; then
                printf '[dotconfig] %s is set\n' "$setting" >&2
            else
                printf '[dotconfig] %s is unset/empty\n' "$setting" >&2
            fi
        done
        echo '[dotconfig] Client configuration files may also affect proxy and TLS settings.' >&2
        curl_options+=(--write-out $'\n[dotconfig] HTTP=%{http_code} remote=%{remote_ip} redirects=%{num_redirects} DNS=%{time_namelookup}s connect=%{time_connect}s TLS=%{time_appconnect}s total=%{time_total}s\n')
    fi
    if [[ "$downloader" == wget ]]; then
        wget --https-only --tries=4 --timeout=60 --output-document="$2" "$1" || status=$?
    else
    curl \
        --fail \
        --location \
        --proto '=https' \
        --retry 3 \
        --show-error \
        "${curl_options[@]}" \
        --output "$2" \
        "$1" || status=$?
    fi
    if ((status != 0)); then
        printf '[dotconfig] %s download failed: %s exited %s.\n' "$tool" "$downloader" "$status" >&2
        echo '[dotconfig] Retry with install.sh --verbose (or DOTCONFIG_DOWNLOAD_VERBOSE=true for this helper).' >&2
        echo '[dotconfig] Compare the same release URL and proxy settings as the target account; GitHub releases redirect to asset hosts.' >&2
        return "$status"
    fi
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
