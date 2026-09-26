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

body_file="$(mktemp)"
trap 'rm -- "$body_file"' EXIT
{
    printf '%s\n\n' "$body"
    echo "### Changed files"
    echo '```text'
    git diff --stat HEAD^ HEAD -- "${paths[@]}"
    echo '```'

    pin_diff="$(git diff --unified=0 HEAD^ HEAD -- \
        versions/ home/dot_config/mise/config.toml packages/packages.tsv \
        | awk '/^\+\+\+|^---/ { next } /^\+|^-/ { if (++count <= 80) print } END { if (count > 80) print "... additional pin changes omitted; inspect the PR diff" }')"
    if [[ -n "$pin_diff" ]]; then
        echo
        echo "### Pin changes"
        echo '```diff'
        printf '%s\n' "$pin_diff"
        echo '```'
    fi
    echo
    echo "Review the full diff and platform validation before merging."
} > "$body_file"

if [[ -n "$open_pr" ]]; then
    gh pr edit "$open_pr" --title "$title" --body-file "$body_file"
else
    gh pr create \
        --base "$base_branch" \
        --head "$refresh_branch" \
        --title "$title" \
        --body-file "$body_file"
fi

# GITHUB_TOKEN-created PR events require manual approval. A workflow_dispatch
# explicitly runs the same platform validation on the proposed commit.
gh workflow run validate.yml --ref "$refresh_branch"

# The advisory check exists for every PR, so branch protection can require it.
# GITHUB_TOKEN-authored PR events may await approval; dispatch it on this branch.
gh workflow run security-audit.yml --ref "$refresh_branch"
