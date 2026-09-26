#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
remote="$test_root/remote.git"
work="$test_root/work"
fake_bin="$test_root/bin"
gh_log="$test_root/gh.log"

git init --bare "$remote" >/dev/null
git init "$work" >/dev/null
git -C "$work" config user.name test
git -C "$work" config user.email test@example.com
git -C "$work" branch -M master
printf '%s\n' initial > "$work/tracked"
mkdir -p "$work/versions"
printf '%s\n' 'tool 1.0.0' > "$work/versions/test-pin"
printf '%s\n' 'coc-example 1.0.0' > "$work/versions/coc-extensions"
mkdir -p "$work/home/dot_config/mise"
printf '[tools]\nnode = "24.0.0"\ngo = "1.0.0"\n' > "$work/home/dot_config/mise/config.toml"
git -C "$work" add tracked versions/test-pin versions/coc-extensions home/dot_config/mise/config.toml
git -C "$work" commit -m initial >/dev/null
git -C "$work" remote add origin "$remote"
git -C "$work" push origin master >/dev/null
printf '%s\n' changed > "$work/tracked"
printf '%s\n' 'tool 1.1.0' > "$work/versions/test-pin"

mkdir -p "$fake_bin"
# These variables belong to the generated fake gh script, not this test process.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1 $2" == "pr list" ]]; then cat "$GH_OPEN_PR_FILE"; exit 0; fi' \
    'printf "%s\\n" "$*" >> "$GH_LOG"' \
    'while (($#)); do if [[ "$1" == --body-file ]]; then cat "$2" > "$GH_BODY_FILE"; break; fi; shift; done' \
    > "$fake_bin/gh"
chmod +x "$fake_bin/gh"
: > "$test_root/open-pr"

(
    cd "$work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GH_BODY_FILE="$test_root/body" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked versions/test-pin
)

git --git-dir="$remote" rev-parse --verify refs/heads/automation/test-refresh >/dev/null
grep -q '^pr create --base master --head automation/test-refresh' "$gh_log"
grep -q '^Test body$' "$test_root/body"
grep -q '^### Changed files$' "$test_root/body"
grep -q '^### Pin changes$' "$test_root/body"
grep -q '^+tool 1.1.0$' "$test_root/body"
grep -Eq '^ tracked +\| ' "$test_root/body"
grep -q '^Review the full diff and platform validation before merging\.$' "$test_root/body"
test "$(grep -c '^workflow run validate.yml --ref automation/test-refresh$' "$gh_log")" -eq 1
if grep -q '^workflow run security-audit.yml' "$gh_log"; then
    echo "Unrelated refresh unexpectedly dispatched the advisory audit" >&2
    exit 1
fi

git clone --branch master "$remote" "$test_root/next-work" >/dev/null 2>&1
printf '%s\n' refreshed > "$test_root/next-work/tracked"
printf '%s\n' 'tool 1.2.0' > "$test_root/next-work/versions/test-pin"
printf '%s\n' 42 > "$test_root/open-pr"
(
    cd "$test_root/next-work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GH_BODY_FILE="$test_root/body" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked versions/test-pin
)
grep -q '^pr edit 42 --title Test refresh --body-file ' "$gh_log"
grep -q '^### Changed files$' "$test_root/body"
grep -q '^+tool 1.2.0$' "$test_root/body"
test "$(grep -c '^workflow run validate.yml --ref automation/test-refresh$' "$gh_log")" -eq 2
if grep -q '^workflow run security-audit.yml' "$gh_log"; then
    echo "Unrelated refresh update unexpectedly dispatched the advisory audit" >&2
    exit 1
fi

git -C "$work" switch master >/dev/null
(
    cd "$work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GH_BODY_FILE="$test_root/body" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked versions/test-pin
)
grep -q '^pr close 42 --delete-branch --comment ' "$gh_log"
test "$(grep -c '^workflow run validate.yml --ref automation/test-refresh$' "$gh_log")" -eq 2

: > "$test_root/open-pr"
before="$(wc -l < "$gh_log")"
(
    cd "$work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GH_BODY_FILE="$test_root/body" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked versions/test-pin
)
[[ "$(wc -l < "$gh_log")" == "$before" ]]

for refresh_case in coc node go; do
    case "$refresh_case" in
        coc) path=versions/coc-extensions; new_value='coc-example 1.1.0' ;;
        node) path=home/dot_config/mise/config.toml; new_value='[tools]
node = "24.1.0"
go = "1.0.0"' ;;
        go) path=home/dot_config/mise/config.toml; new_value='[tools]
node = "24.0.0"
go = "1.1.0"' ;;
    esac
    git clone --branch master "$remote" "$test_root/$refresh_case-work" >/dev/null 2>&1
    printf '%s\n' "$new_value" > "$test_root/$refresh_case-work/$path"
    (
        cd "$test_root/$refresh_case-work"
        PATH="$fake_bin:$PATH" \
        GH_LOG="$gh_log" \
        GH_OPEN_PR_FILE="$test_root/open-pr" \
        GH_BODY_FILE="$test_root/body" \
        GITHUB_REF_NAME=master \
            bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
                "automation/test-$refresh_case" \
                "Test $refresh_case refresh" \
                "Test body" \
                "$path"
    )
    grep -q "^workflow run validate.yml --ref automation/test-$refresh_case$" "$gh_log"
done
test "$(grep -c '^workflow run security-audit.yml --ref automation/test-' "$gh_log")" -eq 2
grep -q '^workflow run security-audit.yml --ref automation/test-coc$' "$gh_log"
grep -q '^workflow run security-audit.yml --ref automation/test-node$' "$gh_log"
if grep -q '^workflow run security-audit.yml --ref automation/test-go$' "$gh_log"; then
    echo "Go-only refresh unexpectedly dispatched the advisory audit" >&2
    exit 1
fi

echo "Refresh PR cleanup passed"
