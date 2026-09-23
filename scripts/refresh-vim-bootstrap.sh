#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-$REPO_ROOT/versions/vim-bootstrap-profile}"
output="${2:-$REPO_ROOT/home/dot_vimrc}"

[[ -f "$profile" ]] || { echo "Missing Vim Bootstrap profile: $profile" >&2; exit 1; }
editor=""
languages=""
plugins=""
line_number=0
while read -r kind value extra || [[ -n "${kind:-}" ]]; do
    line_number=$((line_number + 1))
    [[ -z "$kind" || "$kind" == \#* ]] && continue
    if [[ -n "${extra:-}" || ! "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "Invalid Vim Bootstrap profile row $line_number" >&2
        exit 1
    fi
    case "$kind" in
        editor)
            [[ -z "$editor" && "$value" == vim ]] || { echo "Invalid or duplicate editor on row $line_number" >&2; exit 1; }
            editor="$value"
            ;;
        language)
            [[ ",$languages," != *,"$value",* ]] || { echo "Duplicate language on row $line_number" >&2; exit 1; }
            languages="${languages:+$languages,}$value"
            ;;
        plugin)
            [[ ",$plugins," != *,"$value",* ]] || { echo "Duplicate plugin on row $line_number" >&2; exit 1; }
            plugins="${plugins:+$plugins,}$value"
            ;;
        *)
            echo "Unknown Vim Bootstrap profile kind on row $line_number: $kind" >&2
            exit 1
            ;;
    esac
done < "$profile"
[[ -n "$editor" && -n "$languages" ]] || { echo "Vim Bootstrap profile needs an editor and language" >&2; exit 1; }

request=(--fail --silent --show-error --location --retry 3 'https://vim-bootstrap.com/generate.vim')
IFS=, read -r -a language_list <<< "$languages"
for language in "${language_list[@]}"; do
    request+=(--data "langs=$language")
done
request+=(--data "editor=$editor" --data "additional-plugins=$plugins")

download="$(mktemp "${output}.download.XXXXXX")"
normalized="$(mktemp "${output}.normalized.XXXXXX")"
trap 'rm -f "$download" "$normalized"' EXIT
curl "${request[@]}" > "$download"
test -s "$download"
grep -q 'vim-bootstrap' "$download"
grep -q 'call plug#begin' "$download"
grep -q 'source ~/.vim/plugin-lock.vim' "$download"
grep -q 'call plug#end' "$download"
{
    printf '%s\n' '" vim-bootstrap snapshot; refreshed by .github/workflows/refresh-vim-bootstrap.yml'
    tail -n +2 "$download"
} > "$normalized"
mv "$normalized" "$output"
