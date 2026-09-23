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
chezmoi_installer="$(git ls-remote https://github.com/twpayne/chezmoi.git HEAD | awk '{ print $1 }')"
homebrew_installer="$(git ls-remote https://github.com/Homebrew/install.git HEAD | awk '{ print $1 }')"

[[ "$chezmoi_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$mise_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$chezmoi_installer" =~ ^[0-9a-f]{40}$ ]]
[[ "$homebrew_installer" =~ ^[0-9a-f]{40}$ ]]

checksums="$(mktemp)"
trap 'rm -f "$updated" "$checksums"' EXIT
curl --fail --location --proto '=https' --retry 3 --show-error --silent \
    --output "$checksums" \
    "https://github.com/jdx/mise/releases/download/v$mise_version/SHASUMS256.txt"
test -s "$checksums"

mise_checksum() {
    local archive="$1"
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
    ' "$checksums")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "Invalid upstream mise checksum for $archive" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

linux_arm64="$(mise_checksum "mise-v$mise_version-linux-arm64.tar.gz")"
linux_x64="$(mise_checksum "mise-v$mise_version-linux-x64.tar.gz")"
macos_arm64="$(mise_checksum "mise-v$mise_version-macos-arm64.tar.gz")"
macos_x64="$(mise_checksum "mise-v$mise_version-macos-x64.tar.gz")"

printf '%s\n' \
    '# component version-or-revision-or-sha256' \
    "chezmoi $chezmoi_version" \
    "chezmoi-installer $chezmoi_installer" \
    "homebrew-installer $homebrew_installer" \
    "mise $mise_version" \
    "mise-linux-arm64-sha256 $linux_arm64" \
    "mise-linux-x64-sha256 $linux_x64" \
    "mise-macos-arm64-sha256 $macos_arm64" \
    "mise-macos-x64-sha256 $macos_x64" \
    > "$updated"

mv "$updated" "$MANIFEST"
rm -f "$checksums"
trap - EXIT
