#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/packages/packages.tsv"
BREWFILE="$REPO_ROOT/packages/Brewfile"
UBUNTU_FILE="$REPO_ROOT/packages/ubuntu.txt"
brew_output="$(mktemp)"
ubuntu_output="$(mktemp)"
trap 'rm -f "$brew_output" "$ubuntu_output"' EXIT

{
    echo "# Generated from packages/packages.tsv; do not edit by hand."
    echo "# Shared command-line baseline for macOS."
    while read -r _capability homebrew _ubuntu; do
        [[ "$_capability" != "#" && -n "${homebrew:-}" && "$homebrew" != "-" ]] || continue
        printf 'brew "%s"\n' "$homebrew"
    done < "$MANIFEST"
} > "$brew_output"

{
    echo "# Generated from packages/packages.tsv; do not edit by hand."
    echo "# Shared command-line baseline for Ubuntu."
    while read -r _capability _homebrew ubuntu; do
        [[ "$_capability" != "#" && -n "${ubuntu:-}" && "$ubuntu" != "-" ]] || continue
        printf '%s\n' "$ubuntu"
    done < "$MANIFEST"
} > "$ubuntu_output"

mv "$brew_output" "$BREWFILE"
mv "$ubuntu_output" "$UBUNTU_FILE"
trap - EXIT
