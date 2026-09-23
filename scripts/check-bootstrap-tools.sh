#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${1:-$REPO_ROOT/versions/bootstrap-tools}"
failures=0

for tool in chezmoi mise; do
    expected="$(awk -v tool="$tool" '$1 == tool { print $2; found=1 } END { exit !found }' "$manifest")"

    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing: $tool (expected $expected)" >&2
        failures=$((failures + 1))
        continue
    fi

    version_output="$("$tool" --version)" || {
        echo "unable to read $tool version" >&2
        failures=$((failures + 1))
        continue
    }
    case "$tool" in
        chezmoi)
            if [[ "$version_output" =~ ^chezmoi[[:space:]]+version[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
                actual="${BASH_REMATCH[1]}"
            else
                actual=""
            fi
            ;;
        mise)
            if [[ "$version_output" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
                actual="${BASH_REMATCH[1]}"
            else
                actual=""
            fi
            ;;
    esac

    if [[ -z "$actual" ]]; then
        echo "unrecognized $tool version: $version_output" >&2
        failures=$((failures + 1))
    elif [[ "$actual" != "$expected" ]]; then
        echo "$tool drift: expected $expected, found $actual ($(command -v "$tool"))" >&2
        failures=$((failures + 1))
    else
        echo "ok: $tool $actual ($(command -v "$tool"))"
    fi
done

((failures == 0))
