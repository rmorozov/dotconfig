#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

required_commands=(git python3 shellcheck zsh)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing validation dependency: $command_name" >&2
        exit 1
    }
done

while IFS= read -r action_line; do
    [[ "$action_line" =~ uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$) ]] || {
        echo "GitHub Action is not pinned to a full commit SHA: $action_line" >&2
        exit 1
    }
done < <(grep -RhE 'uses:[[:space:]]+[^[:space:]]+@' .github/workflows)

shell_scripts=(install.sh packages/install.sh scripts/*.sh)
shellcheck "${shell_scripts[@]}"
for script in "${shell_scripts[@]}"; do
    bash -n "$script"
done

bash scripts/test-editor-state.sh
bash scripts/test-bootstrap-tools.sh
bash scripts/test-first-run-bootstrap.sh
bash scripts/test-runtime-versions.sh
bash scripts/test-node-version.sh
bash scripts/test-dotconfig-review.sh
bash scripts/test-package-freshness.sh
bash scripts/test-update-runtime-versions.sh
bash scripts/test-update-bootstrap-tools.sh
bash scripts/test-mise-archive-checksum.sh
bash scripts/test-chezmoi-archive-checksum.sh
bash scripts/test-open-refresh-pr.sh
bash scripts/test-refresh-vim-bootstrap.sh

for script in home/dot_config/zsh/*.zsh; do
    zsh -n "$script"
done

bash scripts/generate-coc-extensions.sh
bash scripts/generate-native-packages.sh
bash scripts/generate-vim-plugin-lock.sh
git diff --exit-code -- \
    home/dot_vim/coc-extensions.vim \
    home/dot_vim/plugin-lock.vim \
    packages/Brewfile \
    packages/ubuntu.txt

test -s home/dot_vimrc
grep -q 'vim-bootstrap snapshot' home/dot_vimrc
grep -q 'call plug#begin' home/dot_vimrc
grep -q 'source ~/.vim/plugin-lock.vim' home/dot_vimrc
grep -q 'call plug#end' home/dot_vimrc
test -s home/dot_vim/plugin-lock.vim
test -s home/dot_vim/coc-extensions.vim

extension_count="$(grep -vc '^#' versions/coc-extensions)"
generated_extension_count="$(grep -c '@[0-9]' home/dot_vim/coc-extensions.vim)"
test "$extension_count" = "$generated_extension_count"
awk 'NR > 1 && $2 !~ /^[0-9]+\.[0-9]+\.[0-9]+/ { exit 1 }' versions/coc-extensions
awk 'NR > 1 && (NF < 2 || $2 !~ /^GHSA-/) { exit 1 }' versions/coc-extensions-disabled

overlap="$(
    comm -12 \
        <(awk 'NR > 1 { print $1 }' versions/coc-extensions | LC_ALL=C sort) \
        <(awk 'NR > 1 { print $1 }' versions/coc-extensions-disabled | LC_ALL=C sort)
)"
[[ -z "$overlap" ]] || {
    echo "CoC extensions cannot be both active and quarantined: $overlap" >&2
    exit 1
}

plugin_count="$(grep -vc '^#' versions/vim-plugins)"
lock_count="$(grep -c '^call s:DotconfigPin' home/dot_vim/plugin-lock.vim)"
test "$plugin_count" = "$lock_count"
awk 'NR > 1 && $4 !~ /^[0-9a-f]{40}$/ { exit 1 }' versions/vim-plugins

awk '
    NR == 1 { next }
    NF != 3 { exit 1 }
    $2 == "-" && $3 == "-" { exit 1 }
' packages/packages.tsv

grep -Eq '^[0-9a-f]{40}$' versions/oh-my-zsh
awk '
    BEGIN {
        required["chezmoi"] = "version"
        required["chezmoi-linux-arm64-sha256"] = "digest"
        required["chezmoi-linux-amd64-sha256"] = "digest"
        required["chezmoi-darwin-arm64-sha256"] = "digest"
        required["chezmoi-darwin-amd64-sha256"] = "digest"
        required["homebrew-installer"] = "revision"
        required["mise"] = "version"
        required["mise-linux-arm64-sha256"] = "digest"
        required["mise-linux-x64-sha256"] = "digest"
        required["mise-macos-arm64-sha256"] = "digest"
        required["mise-macos-x64-sha256"] = "digest"
    }
    NR == 1 { next }
    NF != 2 || !($1 in required) || seen[$1]++ { invalid = 1; next }
    required[$1] == "revision" && $2 !~ /^[0-9a-f]{40}$/ { invalid = 1 }
    required[$1] == "version" && $2 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { invalid = 1 }
    required[$1] == "digest" && $2 !~ /^[0-9a-f]{64}$/ { invalid = 1 }
    END {
        for (key in required) {
            if (seen[key] != 1) invalid = 1
        }
        exit invalid
    }
' versions/bootstrap-tools

if grep -RE 'curl[^|]*\|[[:space:]]*(sh|bash)' install.sh scripts .github/workflows; then
    echo "Refusing streamed remote script execution." >&2
    exit 1
fi

echo "Static validation passed"
