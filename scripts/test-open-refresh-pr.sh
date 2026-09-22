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
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1 $2" == "pr view" ]]; then exit 1; fi' \
    'printf "%s\\n" "$*" >> "$GH_LOG"' \
    > "$fake_bin/gh"
chmod +x "$fake_bin/gh"

(
    cd "$work"
    PATH="$fake_bin:$PATH" \
    GH_LOG="$gh_log" \
    GITHUB_REF_NAME=master \
        bash "$REPO_ROOT/scripts/open-refresh-pr.sh" \
            automation/test-refresh \
            "Test refresh" \
            "Test body" \
            tracked
)

git --git-dir="$remote" rev-parse --verify refs/heads/automation/test-refresh >/dev/null
grep -q '^pr create --base master --head automation/test-refresh' "$gh_log"
