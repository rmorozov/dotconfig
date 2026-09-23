#!/usr/bin/env bash
# Fake npm intentionally refers to its runtime environment.
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture="$test_root/repo"
mkdir -p "$fixture/scripts" "$fixture/versions" "$fixture/home/dot_vim" "$test_root/bin"
cp "$REPO_ROOT/scripts/reconsider-coc-extensions.sh" \
    "$REPO_ROOT/scripts/add-coc-extension.sh" \
    "$REPO_ROOT/scripts/generate-coc-extensions.sh" "$fixture/scripts/"
printf '%s\n' '# npm-package advisory reason' \
    'coc-demo GHSA-aaaa-bbbb-cccc waiting-for-fix' > "$fixture/versions/coc-extensions-disabled"
printf '%s\n' '# npm package version' > "$fixture/versions/coc-extensions"

cat > "$test_root/bin/npm" <<'NPM'
#!/usr/bin/env bash
case "$1" in
    view)
        printf 'view\n' >> "$NPM_LOG"
        # A second lookup would return a newer release that was never audited.
        if [[ "$(wc -l < "$NPM_LOG")" -gt 1 ]]; then
            printf '9.9.9\n'
        else
            printf '1.2.3\n'
        fi
        ;;
    install) exit 0 ;;
    audit) exit 0 ;;
    *) exit 1 ;;
esac
NPM
chmod +x "$test_root/bin/npm"
export PATH="$test_root/bin:$PATH" NPM_LOG="$test_root/npm-log"
bash "$fixture/scripts/reconsider-coc-extensions.sh" > "$test_root/output"
grep -Fxq 'coc-demo 1.2.3' "$fixture/versions/coc-extensions"
grep -Fq 'coc-demo@1.2.3' "$fixture/home/dot_vim/coc-extensions.vim"
test "$(wc -l < "$NPM_LOG")" -eq 1
test "$(wc -l < "$fixture/versions/coc-extensions-disabled")" -eq 1
echo 'Quarantine restore uses the audited version'
