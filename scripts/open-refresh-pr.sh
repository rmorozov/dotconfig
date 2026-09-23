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

open_pr="$(gh pr list --head "$refresh_branch" --state open --json number --jq '.[0].number // empty')"

if git diff --quiet -- "${paths[@]}"; then
    echo "No changes for $title."
    if [[ -n "$open_pr" ]]; then
        gh pr close "$open_pr" --delete-branch \
            --comment "The latest refresh matches the base branch; this proposal is no longer needed."
    fi
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch --create "$refresh_branch"
git add "${paths[@]}"
git commit -m "$title"
git push --force-with-lease origin "HEAD:$refresh_branch"

if [[ -n "$open_pr" ]]; then
    gh pr edit "$open_pr" --title "$title" --body "$body"
else
    gh pr create \
        --base "$base_branch" \
        --head "$refresh_branch" \
        --title "$title" \
        --body "$body"
fi
