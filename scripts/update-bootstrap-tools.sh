#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/bootstrap-tools"
updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT

for command_name in curl gh git; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing update dependency: $command_name" >&2
        exit 1
    }
done

chezmoi_version="$(gh api repos/twpayne/chezmoi/releases/latest --jq '.tag_name | ltrimstr("v")')"
mise_version="$(gh api repos/jdx/mise/releases/latest --jq '.tag_name | ltrimstr("v")')"
homebrew_installer="$(git ls-remote https://github.com/Homebrew/install.git HEAD | awk '{ print $1 }')"

[[ "$chezmoi_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$mise_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$homebrew_installer" =~ ^[0-9a-f]{40}$ ]]

checksums="$(mktemp)"
chezmoi_checksums="$(mktemp)"
trap 'rm -f "$updated" "$checksums" "$chezmoi_checksums"' EXIT
curl --fail --location --proto '=https' --retry 3 --show-error --silent \
    --output "$checksums" \
    "https://github.com/jdx/mise/releases/download/v$mise_version/SHASUMS256.txt"
test -s "$checksums"
curl --fail --location --proto '=https' --retry 3 --show-error --silent \
    --output "$chezmoi_checksums" \
    "https://github.com/twpayne/chezmoi/releases/download/v$chezmoi_version/chezmoi_${chezmoi_version}_checksums.txt"
test -s "$chezmoi_checksums"

release_checksum() {
    local archive="$1"
    local checksum_file="$2"
    local digest
    digest="$(awk -v archive="$archive" '
        {
            filename = $2
            sub(/^\.\//, "", filename)
            if (filename == archive) {
                print $1
                count++
            }
        }
        END { exit (count != 1) }
    ' "$checksum_file")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "Invalid upstream checksum for $archive" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

linux_arm64="$(release_checksum "mise-v$mise_version-linux-arm64.tar.gz" "$checksums")"
linux_x64="$(release_checksum "mise-v$mise_version-linux-x64.tar.gz" "$checksums")"
macos_arm64="$(release_checksum "mise-v$mise_version-macos-arm64.tar.gz" "$checksums")"
macos_x64="$(release_checksum "mise-v$mise_version-macos-x64.tar.gz" "$checksums")"

chezmoi_linux_arm64="$(release_checksum "chezmoi_${chezmoi_version}_linux_arm64.tar.gz" "$chezmoi_checksums")"
chezmoi_linux_amd64="$(release_checksum "chezmoi_${chezmoi_version}_linux_amd64.tar.gz" "$chezmoi_checksums")"
chezmoi_darwin_arm64="$(release_checksum "chezmoi_${chezmoi_version}_darwin_arm64.tar.gz" "$chezmoi_checksums")"
chezmoi_darwin_amd64="$(release_checksum "chezmoi_${chezmoi_version}_darwin_amd64.tar.gz" "$chezmoi_checksums")"

printf '%s\n' \
    '# component version-or-revision-or-sha256' \
    "chezmoi $chezmoi_version" \
    "chezmoi-linux-arm64-sha256 $chezmoi_linux_arm64" \
    "chezmoi-linux-amd64-sha256 $chezmoi_linux_amd64" \
    "chezmoi-darwin-arm64-sha256 $chezmoi_darwin_arm64" \
    "chezmoi-darwin-amd64-sha256 $chezmoi_darwin_amd64" \
    "homebrew-installer $homebrew_installer" \
    "mise $mise_version" \
    "mise-linux-arm64-sha256 $linux_arm64" \
    "mise-linux-x64-sha256 $linux_x64" \
    "mise-macos-arm64-sha256 $macos_arm64" \
    "mise-macos-x64-sha256 $macos_x64" \
    > "$updated"

mv "$updated" "$MANIFEST"
rm -f "$checksums" "$chezmoi_checksums"
trap - EXIT
