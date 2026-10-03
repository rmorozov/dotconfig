#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/repo/scripts" "$root/home/.vim/autoload" "$root/old checkout"
cp "$REPO_ROOT/scripts/migrate-legacy.sh" "$root/repo/scripts/"
cat > "$root/repo/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$HOME/install-args"
[[ ! -e "$HOME/.zshrc" && ! -L "$HOME/.zshrc" ]]
[[ ! -e "$HOME/.vimrc" ]]
printf 'new configuration\n' > "$HOME/.zshrc"
exit "${INSTALL_EXIT:-0}"
INSTALL
export HOME="$root/home"
printf 'private settings\n' > "$HOME/.zshrc.local"
printf 'edited legacy shell\n' > "$root/old checkout/zshrc"
ln -s "$root/old checkout/zshrc" "$HOME/.zshrc"
ln -s "$root/missing" "$HOME/.vimrc.local"
printf 'generated vimrc\n' > "$HOME/.vimrc"
printf 'old manager\n' > "$HOME/.vim/autoload/plug.vim"
mkdir -p "$HOME/.vim/plugged/custom"
printf 'custom plugin\n' > "$HOME/.vim/plugged/custom/file"
migrate="$root/repo/scripts/migrate-legacy.sh"
backup="$HOME/.local/state/dotconfig/migrations/b967ec9"
bash "$migrate" > "$root/preview"
[[ ! -e "$backup" && ! -e "$HOME/install-args" && -L "$HOME/.zshrc" ]]
grep -q 'Preview only' "$root/preview"
if bash "$migrate" --user another > "$root/error" 2>&1; then exit 1; fi
# Unsupported directory layouts fail before writing backups or replacing files.
mkdir "$HOME/.vim/coc-settings.json"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
[[ ! -e "$backup" && -L "$HOME/.zshrc" ]]
rmdir "$HOME/.vim/coc-settings.json"
# A backup failure must not remove any original file.
mkdir -p "$root/bin"
cat > "$root/bin/cp" <<'COPY'
#!/usr/bin/env bash
exit 9
COPY
chmod +x "$root/bin/cp"
if PATH="$root/bin:$PATH" bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
[[ -L "$HOME/.zshrc" && -f "$HOME/.vimrc" && ! -e "$HOME/install-args" ]]
rm -rf "$backup"
bash "$migrate" --apply --skip-packages --skip-plugins --skip-shell-change > "$root/applied"
[[ -f "$backup/complete" && -L "$backup/original/.zshrc" && -L "$backup/original/.vimrc.local" ]]
cmp "$root/old checkout/zshrc" "$backup/contents/.zshrc"
grep -q 'generated vimrc' "$backup/original/.vimrc"
grep -q 'old manager' "$backup/contents/.vim/autoload/plug.vim"
[[ ! -e "$backup/contents/.vimrc.local" ]]
grep -q 'private settings' "$HOME/.zshrc.local"
grep -q 'custom plugin' "$HOME/.vim/plugged/custom/file"
[[ "$(wc -l < "$HOME/install-args" | tr -d ' ')" == 3 ]]
grep -qx -- '--skip-packages' "$HOME/install-args"
[[ "$(stat -c %a "$backup" 2>/dev/null || stat -f %Lp "$backup")" == 700 ]]
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'already prepared' "$root/error"
# A stopped installer keeps the original snapshot and never marks completion.
export HOME="$root/failed-home"
mkdir -p "$HOME"
printf 'old vimrc\n' > "$HOME/.vimrc"
if INSTALL_EXIT=7 bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
backup="$HOME/.local/state/dotconfig/migrations/b967ec9"
[[ -f "$backup/original/.vimrc" && ! -e "$backup/complete" ]]
grep -q 'Installation stopped' "$root/error"
# Already managed machines must not be migrated again.
export HOME="$root/managed-home"
mkdir -p "$HOME/.local/bin"
touch "$HOME/.local/bin/dotconfig"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'already has dotconfig' "$root/error"
echo 'Legacy migration tests passed'
