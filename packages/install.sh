#!/usr/bin/env bash

set -Eeuo pipefail

PACKAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$PACKAGE_DIR/../home/dot_config/zsh/proxy.zsh"

MODE=install

case "${1:-}" in
    "") ;;
    --check|--dry-run) MODE=check ;;
    --outdated) MODE=outdated ;;
    --plan) MODE=plan ;;
    *) echo "Usage: $0 [--check|--outdated|--plan]" >&2; exit 2 ;;
esac

case "$(uname -s)" in
    Darwin)
        if ! command -v brew >/dev/null 2>&1; then
            echo "missing: Homebrew" >&2
            exit 1
        fi
        if [[ "$MODE" == outdated || "$MODE" == plan ]]; then
            formulae=()
            while IFS= read -r formula; do
                formulae+=("$formula")
            done < <(awk 'NR > 1 && $2 != "-" { print $2 }' "$PACKAGE_DIR/packages.tsv")
            if [[ "$MODE" == plan ]]; then
                echo "Brewfile satisfaction (missing formulae):"
                brew bundle check --verbose --file "$PACKAGE_DIR/Brewfile" || true
                echo
            fi
            updates="$(brew outdated --verbose --formula "${formulae[@]}")" || exit 1
            if [[ -n "$updates" ]]; then
                printf 'Available baseline formula updates:\n%s\n' "$updates"
            else
                echo "No baseline formula updates in current Homebrew metadata."
            fi
            if [[ "$MODE" == plan ]]; then
                echo "Homebrew may also update dependencies; review its prompts when applying."
                echo "Metadata may be stale; refresh it with: brew update"
            fi
        elif [[ "$MODE" == check ]]; then
            brew bundle check --file "$PACKAGE_DIR/Brewfile"
        else
            brew bundle --file "$PACKAGE_DIR/Brewfile"
        fi
        ;;
    Linux)
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "The Linux package baseline currently supports Ubuntu/Debian only." >&2
            exit 1
        fi
        packages=()
        while IFS= read -r package_name; do
            [[ "$package_name" =~ ^[[:space:]]*(#|$) ]] && continue
            packages+=("$package_name")
        done < "$PACKAGE_DIR/ubuntu.txt"
        if [[ "$MODE" == plan ]]; then
            echo "Simulated install/upgrade of the baseline and its dependencies:"
            LC_ALL=C apt-get -s install "${packages[@]}"
            echo "APT metadata may be stale; refresh it with: sudo apt-get update"
        elif [[ "$MODE" == outdated ]]; then
            simulation="$(LC_ALL=C apt-get -s upgrade)" || exit 1
            updates="$(awk '
                NR == FNR { if (NR > 1 && $3 != "-") baseline[$3] = 1; next }
                $1 == "Inst" && ($2 in baseline) { print $0 }
            ' "$PACKAGE_DIR/packages.tsv" <(printf '%s\n' "$simulation"))"
            if [[ -n "$updates" ]]; then
                printf 'Available baseline package updates:\n%s\n' "$updates"
            else
                echo "No baseline package updates in cached apt metadata."
            fi
            echo "APT metadata may be stale; refresh it with: sudo apt-get update"
        elif [[ "$MODE" == check ]]; then
            missing=()
            for package_name in "${packages[@]}"; do
                dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null |
                    grep -q '^ii ' || missing+=("$package_name")
            done
            if (("${#missing[@]}" > 0)); then
                printf 'missing Ubuntu packages: %s\n' "${missing[*]}" >&2
                exit 1
            fi
            echo "Ubuntu package baseline is satisfied."
        else
            update_status=0
            bash "$PACKAGE_DIR/../scripts/apt-get.sh" update || update_status=$?
            if ((update_status != 0)); then
                echo "WARNING: APT refresh returned $update_status; trying installation with cached package lists. Updates may be stale." >&2
            fi
            install_status=0
            bash "$PACKAGE_DIR/../scripts/apt-get.sh" install -y "${packages[@]}" || install_status=$?
            if ((install_status != 0)); then
                echo "WARNING: APT installation returned $install_status; checking installed baseline and dpkg state." >&2
                if ! bash "$PACKAGE_DIR/install.sh" --check; then
                    echo 'APT failed and the package baseline is incomplete; installation cannot continue.' >&2
                    exit "$install_status"
                fi
                audit_status=0
                audit_output="$(LC_ALL=C dpkg --audit 2>&1)" || audit_status=$?
                if ((audit_status != 0)) || [[ -n "$audit_output" ]]; then
                    printf 'APT failed and dpkg state needs attention (audit exit %s):\n%s\n' "$audit_status" "$audit_output" >&2
                    echo 'Resolve the package-manager errors before continuing installation.' >&2
                    exit "$install_status"
                fi
                echo 'WARNING: Continuing because all baseline packages are fully installed and dpkg audit is clean. APT errors still need investigation; requested upgrades are not guaranteed.' >&2
            fi
        fi
        ;;
    *)
        echo "Unsupported operating system: $(uname -s)" >&2
        exit 1
        ;;
esac
