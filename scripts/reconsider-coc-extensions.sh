#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISABLED="$REPO_ROOT/versions/coc-extensions-disabled"
updated="$(mktemp)"
audit_root="$(mktemp -d)"
trap 'rm -f "$updated"; rm -rf "$audit_root"' EXIT

head -n 1 "$DISABLED" > "$updated"

while read -r package_name advisory reason; do
    [[ -n "${package_name:-}" && "$package_name" != "#" ]] || continue

    version="$(npm view "$package_name" version --silent)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
        echo "Could not resolve $package_name" >&2
        exit 1
    }
    package_dir="$audit_root/${package_name//\//_}"
    mkdir -p "$package_dir"
    printf '{"name":"dotconfig-quarantine-check","private":true,"version":"0.0.0","dependencies":{"%s":"%s"}}\n' \
        "$package_name" "$version" > "$package_dir/package.json"

    if (
        cd "$package_dir"
        npm install \
            --package-lock-only \
            --ignore-scripts \
            --legacy-peer-deps \
            --no-audit \
            --no-fund >/dev/null
        npm audit --omit=dev --audit-level=high >/dev/null
    ); then
        echo "$package_name@$version no longer has a high-severity npm advisory; restoring it for review."
        bash "$REPO_ROOT/scripts/add-coc-extension.sh" "$package_name" "$version"
    else
        printf '%s %s %s\n' "$package_name" "$advisory" "$reason" >> "$updated"
        echo "$package_name@$version remains quarantined ($advisory)."
    fi
done < "$DISABLED"

mv "$updated" "$DISABLED"
trap - EXIT
rm -rf "$audit_root"
