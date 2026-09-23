#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VIM_MANIFEST="${VIM_PLUGIN_MANIFEST:-$REPO_ROOT/versions/vim-plugins}"
COC_MANIFEST="${COC_EXTENSION_MANIFEST:-$REPO_ROOT/versions/coc-extensions}"
VIM_ROOT="${VIM_PLUGIN_HOME:-$HOME/.vim/plugged}"
COC_ROOT="${COC_EXTENSION_HOME:-${COC_DATA_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/coc}/extensions/node_modules}"
failures=0

while read -r name _repository _ref expected; do
    [[ -n "${name:-}" && "$name" != "#" ]] || continue
    plugin_dir="$VIM_ROOT/$name"

    if [[ ! -d "$plugin_dir/.git" ]]; then
        echo "missing: Vim plugin $name" >&2
        failures=$((failures + 1))
        continue
    fi

    if ! actual="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null)"; then
        echo "invalid: Vim plugin repository $name" >&2
        failures=$((failures + 1))
    elif [[ "$actual" != "$expected" ]]; then
        echo "drift: Vim plugin $name expected $expected, found $actual" >&2
        failures=$((failures + 1))
    else
        echo "ok: Vim plugin $name@$actual"
    fi
done < "$VIM_MANIFEST"

while read -r package_name expected; do
    [[ -n "${package_name:-}" && "$package_name" != "#" ]] || continue
    package_json="$COC_ROOT/$package_name/package.json"

    if [[ ! -f "$package_json" ]]; then
        echo "missing: CoC extension $package_name@$expected" >&2
        failures=$((failures + 1))
        continue
    fi

    actual="$(
        sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$package_json" |
            head -n 1
    )"
    if [[ -z "$actual" ]]; then
        echo "invalid: CoC extension metadata $package_name" >&2
        failures=$((failures + 1))
    elif [[ "$actual" != "$expected" ]]; then
        echo "drift: CoC extension $package_name expected $expected, found $actual" >&2
        failures=$((failures + 1))
    else
        echo "ok: CoC extension $package_name@$actual"
    fi
done < "$COC_MANIFEST"

if ((failures > 0)); then
    echo "$failures editor dependency check(s) need attention" >&2
    exit 1
fi

echo "Editor dependencies match committed pins."
