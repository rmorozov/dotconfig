#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -ge 4 ]] || {
    echo "Usage: $0 <branch> <title> <body> <path> [path ...]" >&2
    exit 2
}

refresh_branch="$1"
title="$2"
body="$3"
shift 3
paths=("$@")
base_branch="${GITHUB_REF_NAME:-master}"

[[ "$refresh_branch" =~ ^automation/[A-Za-z0-9._/-]+$ ]] || {
    echo "Refresh branch must be under automation/: $refresh_branch" >&2
    exit 2
}

if git diff --quiet -- "${paths[@]}"; then
    echo "No changes for $title."
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch --create "$refresh_branch"
git add "${paths[@]}"
git commit -m "$title"
git push --force-with-lease origin "HEAD:$refresh_branch"

if gh pr view "$refresh_branch" >/dev/null 2>&1; then
    gh pr edit "$refresh_branch" --title "$title" --body "$body"
else
    gh pr create \
        --base "$base_branch" \
        --head "$refresh_branch" \
        --title "$title" \
        --body "$body"
fi
