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
git -C "$work" add tracked
git -C "$work" commit -m initial >/dev/null
git -C "$work" remote add origin "$remote"
git -C "$work" push origin master >/dev/null
printf '%s\n' changed > "$work/tracked"

mkdir -p "$fake_bin"
# These variables belong to the generated fake gh script, not this test process.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1 $2" == "pr list" ]]; then cat "$GH_OPEN_PR_FILE"; exit 0; fi' \
    'printf "%s\\n" "$*" >> "$GH_LOG"' \
    > "$fake_bin/gh"
chmod +x "$fake_bin/gh"
: > "$test_root/open-pr"

(
    cd "$work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked
)

git --git-dir="$remote" rev-parse --verify refs/heads/automation/test-refresh >/dev/null
grep -q '^pr create --base master --head automation/test-refresh' "$gh_log"
test "$(grep -c '^workflow run validate.yml --ref automation/test-refresh$' "$gh_log")" -eq 1

git clone --branch master "$remote" "$test_root/next-work" >/dev/null 2>&1
printf '%s\n' refreshed > "$test_root/next-work/tracked"
printf '%s\n' 42 > "$test_root/open-pr"
(
    cd "$test_root/next-work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked
)
grep -q '^pr edit 42 --title Test refresh --body Test body' "$gh_log"
test "$(grep -c '^workflow run validate.yml --ref automation/test-refresh$' "$gh_log")" -eq 2

git -C "$work" switch master >/dev/null
(
    cd "$work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GH_OPEN_PR_FILE="$test_root/open-pr" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked
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
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked
)
[[ "$(wc -l < "$gh_log")" == "$before" ]]

echo "Refresh PR cleanup passed"
