#!/usr/bin/env bash
# Move the b967ec9-era home files out of chezmoi's way without losing local edits.
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
apply=false
install_args=()
usage() {
    cat <<'HELP'
Usage: bash scripts/migrate-legacy.sh [--apply] [installer skip options]

Preview migration from the b967ec9 installer; --apply backs up and installs.
Run as the account being migrated, from a separate current checkout.
Options: --verbose, --skip-packages, --skip-plugins, --skip-shell-change, --help.
HELP
}
for arg in "$@"; do
    case "$arg" in
        --apply) apply=true ;;
        -v|--verbose) install_args+=(--verbose) ;;
        --skip-packages|--skip-plugins|--skip-shell-change) install_args+=("$arg") ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "${HOME:-}" && -d "$HOME" && -w "$HOME" ]] || {
    echo 'A writable HOME is required.' >&2; exit 1;
}
backup="$HOME/.local/state/dotconfig/migrations/b967ec9"
if [[ -e "$backup" || -L "$backup" ]]; then
    echo "Migration already prepared: $backup" >&2
    if [[ -f "$backup/complete" ]]; then
        echo 'Migration completed; use dotconfig doctor or dotconfig sync.' >&2
    elif [[ -f "$backup/files-removed" ]]; then
        echo "Legacy files were removed; resume with bash $REPO_ROOT/install.sh and the same skip options." >&2
    elif [[ -f "$backup/removal-started" ]]; then
        echo 'Legacy file removal was interrupted. Inspect the backup and recover the listed files before retrying; see docs/legacy-migration.md.' >&2
    elif [[ -f "$backup/backup-ready" ]]; then
        echo 'Backup is complete and legacy files are unchanged. Keep or move this backup aside before retrying migration.' >&2
    else
        echo 'Backup is incomplete or its state is unknown. Do not run install.sh; inspect it and the legacy files before retrying migration.' >&2
    fi
    exit 1
fi
if [[ -e "$HOME/.local/bin/dotconfig" || -L "$HOME/.local/bin/dotconfig" ]]; then
    echo 'This account already has dotconfig; use dotconfig sync instead.' >&2
    exit 1
fi
files=(.zshrc .vimrc .vimrc.local .vimrc.local.bundles .vim/coc-settings.json
       .vim/autoload/plug.vim .vim/plugin-lock.vim .vim/coc-extensions.vim)
# A symlinked parent would make removal/deployment affect a different directory.
for parent in .vim .vim/autoload; do
    if [[ -L "$HOME/$parent" ]]; then
        echo "Refusing a symlinked directory: $HOME/$parent" >&2; exit 1
    fi
done
if [[ -d "$HOME/.oh-my-zsh/.git" ]] &&
   [[ -n "$(git -C "$HOME/.oh-my-zsh" status --porcelain --untracked-files=no)" ]]; then
    echo 'Save or commit tracked Oh My Zsh changes before migrating.' >&2; exit 1
fi
echo 'Migration from the b967ec9 installer to chezmoi-managed configuration.'
echo "Backup directory: $backup"
for relative in "${files[@]}"; do
    path="$HOME/$relative"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ ! -d "$path" && ( -f "$path" || -L "$path" ) ]] || {
            echo "Expected a file or symlink: $path" >&2; exit 1;
        }
        echo "Back up and replace: ~/$relative"
    fi
done
echo 'Keep private Zsh overrides, shell history, existing plugin directories and system runtimes.'
echo 'Install native packages, managed files, pinned runtimes and plugins using the current installer (subject to skip options).'
if ! "$apply"; then
    echo 'Preview only. Add --apply to migrate.'
    exit 0
fi
# Publish only a complete snapshot. The private umask applies to backup work
# alone; package managers and their children inherit the caller's original mask.
(
    umask 077
    mkdir -p "$(dirname "$backup")"
    staging="$(mktemp -d "${backup}.tmp.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    mkdir -p "$staging/original" "$staging/contents"
    for relative in "${files[@]}"; do
        path="$HOME/$relative"
        if [[ -e "$path" || -L "$path" ]]; then
            mkdir -p "$staging/original/$(dirname "$relative")" "$staging/contents/$(dirname "$relative")"
            cp -a "$path" "$staging/original/$relative"
            if [[ -f "$path" ]]; then
                cp -Lp "$path" "$staging/contents/$relative"
            fi
        fi
    done
    printf '%s\n' "$REPO_ROOT" > "$staging/new-checkout"
    touch "$staging/backup-ready"
    mv "$staging" "$backup"
)
echo "Backup saved at $backup; readable symlink contents are in contents/."
touch "$backup/removal-started"
for relative in "${files[@]}"; do
    rm -f "$HOME/$relative"
done
touch "$backup/files-removed"
# macOS Bash 3.2 treats an empty array expansion as unset under nounset.
if bash "$REPO_ROOT/install.sh" ${install_args[@]+"${install_args[@]}"}; then
    touch "$backup/complete"
    echo 'Migration complete. Open a new Zsh session and run dotconfig doctor.'
    echo 'Review backed-up customizations before copying selected settings into private overrides.'
else
    echo "Installation stopped. Your original files remain in $backup; see docs/legacy-migration.md for recovery." >&2
    exit 1
fi
