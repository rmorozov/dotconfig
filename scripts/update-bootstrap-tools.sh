#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/bootstrap-tools"
updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT

for command_name in gh git; do
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

printf '%s\n' \
    '# component version-or-revision' \
    "chezmoi $chezmoi_version" \
    "chezmoi-installer $chezmoi_installer" \
    "homebrew-installer $homebrew_installer" \
    "mise $mise_version" \
    > "$updated"

mv "$updated" "$MANIFEST"
trap - EXIT
