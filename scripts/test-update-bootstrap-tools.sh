#!/usr/bin/env bash
# The fake gh, git, and curl scripts need literal shell variables.
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/repo/scripts" "$test_root/repo/versions" "$test_root/bin" "$test_root/fixtures"
cp "$REPO_ROOT/scripts/update-bootstrap-tools.sh" "$test_root/repo/scripts/"
printf 'previous manifest\n' > "$test_root/repo/versions/bootstrap-tools"

printf '%s\n' '#!/usr/bin/env bash' \
    'case "$2" in' \
    '  repos/twpayne/chezmoi/releases/latest) printf "v2.73.0\n" ;;' \
    '  repos/jdx/mise/releases/latest) printf "v2026.9.13\n" ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$test_root/bin/gh"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%040d\tHEAD\n" 0' > "$test_root/bin/git"
printf '%s\n' '#!/usr/bin/env bash' \
    'set -eu' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --output) shift; destination="$1" ;;' \
    '    https://*) url="$1" ;;' \
    '  esac' \
    '  shift' \
    'done' \
    'case "$url" in' \
    '  *jdx/mise*) cp "$DOTCONFIG_FIXTURES/mise" "$destination" ;;' \
    '  *twpayne/chezmoi*) cp "$DOTCONFIG_FIXTURES/chezmoi" "$destination" ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$test_root/bin/curl"
chmod +x "$test_root/bin/gh" "$test_root/bin/git" "$test_root/bin/curl"

index=1
for platform in linux-arm64 linux-x64 macos-arm64 macos-x64; do
    printf '%064d  ./mise-v2026.9.13-%s.tar.gz\n' "$index" "$platform" >> "$test_root/fixtures/mise"
    index=$((index + 1))
done
for platform in linux_arm64 linux_amd64 darwin_arm64 darwin_amd64; do
    printf '%064d  chezmoi_2.73.0_%s.tar.gz\n' "$index" "$platform" >> "$test_root/fixtures/chezmoi"
    index=$((index + 1))
done

run_refresh() {
    DOTCONFIG_FIXTURES="$test_root/fixtures" PATH="$test_root/bin:$PATH" \
        bash "$test_root/repo/scripts/update-bootstrap-tools.sh"
}

run_refresh
manifest="$test_root/repo/versions/bootstrap-tools"
grep -q '^chezmoi 2.73.0$' "$manifest"
grep -q '^mise 2026.9.13$' "$manifest"
grep -q '^chezmoi-darwin-amd64-sha256 0000000000000000000000000000000000000000000000000000000000000008$' "$manifest"
cp "$manifest" "$test_root/expected"
cp "$test_root/fixtures/mise" "$test_root/fixtures/mise.good"

printf '%064d  ./mise-v2026.9.13-linux-arm64.tar.gz\n' 1 >> "$test_root/fixtures/mise"
if run_refresh > "$test_root/output" 2>&1; then
    echo "Expected duplicate checksum to fail" >&2
    exit 1
fi
grep -q 'Missing or duplicate upstream checksum for mise-v2026.9.13-linux-arm64.tar.gz' "$test_root/output"
cmp "$manifest" "$test_root/expected"

awk '$2 !~ /mise-v2026.9.13-macos-x64.tar.gz/' "$test_root/fixtures/mise.good" > "$test_root/fixtures/mise"
if run_refresh > "$test_root/output" 2>&1; then
    echo "Expected missing checksum to fail" >&2
    exit 1
fi
grep -q 'Missing or duplicate upstream checksum for mise-v2026.9.13-macos-x64.tar.gz' "$test_root/output"
cmp "$manifest" "$test_root/expected"

echo "Bootstrap refresh integrity tests passed"
