#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Legacy migration test failed at line $LINENO: $BASH_COMMAND" >&2' ERR
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/repo/scripts" "$root/home/.vim/autoload" "$root/old checkout"
cp "$REPO_ROOT/scripts/migrate-legacy.sh" "$root/repo/scripts/"
cat > "$root/repo/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -eu
[[ "$(umask)" == "$EXPECTED_UMASK" ]]
umask > "$HOME/install-umask"
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
# Fail the contents copy after a successful original-link copy. No manual
# cleanup should be necessary to retry, and no original may be removed.
mkdir -p "$root/bin"
export REAL_CP
REAL_CP="$(command -v cp)"
cat > "$root/bin/cp" <<'COPY'
#!/usr/bin/env bash
[[ "$1" != -Lp ]] || exit 9
exec "$REAL_CP" "$@"
COPY
chmod +x "$root/bin/cp"
if PATH="$root/bin:$PATH" bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
[[ -L "$HOME/.zshrc" && -f "$HOME/.vimrc" && ! -e "$HOME/install-args" ]]
[[ ! -e "$backup" && ! -L "$backup" ]]
[[ -z "$(find "$(dirname "$backup")" -name 'b967ec9.tmp.*' -print)" ]]
umask 022
export EXPECTED_UMASK
EXPECTED_UMASK="$(umask)"
bash "$migrate" --apply --skip-packages --skip-plugins --skip-shell-change > "$root/applied"
[[ -f "$backup/backup-ready" && -f "$backup/removal-started" && -f "$backup/files-removed" && -f "$backup/complete" && -L "$backup/original/.zshrc" && -L "$backup/original/.vimrc.local" ]]
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
grep -q 'Migration completed' "$root/error"
# A stopped installer keeps the original snapshot and never marks completion.
export HOME="$root/failed-home"
mkdir -p "$HOME"
printf 'old vimrc\n' > "$HOME/.vimrc"
if INSTALL_EXIT=7 bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
backup="$HOME/.local/state/dotconfig/migrations/b967ec9"
[[ -f "$backup/original/.vimrc" && -f "$backup/files-removed" && ! -e "$backup/complete" ]]
grep -q 'Installation stopped' "$root/error"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'Legacy files were removed; resume with' "$root/error"
# Unknown, ready-but-unremoved, and partially removed backups must not tell
# callers to run installation over legacy files.
export HOME="$root/staged-home"
backup="$HOME/.local/state/dotconfig/migrations/b967ec9"
mkdir -p "$backup"
printf 'untouched vimrc\n' > "$HOME/.vimrc"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'Backup is incomplete or its state is unknown' "$root/error"
if grep -q 'resume with' "$root/error"; then exit 1; fi
touch "$backup/backup-ready"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'legacy files are unchanged' "$root/error"
if grep -q 'resume with' "$root/error"; then exit 1; fi
touch "$backup/removal-started"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'Legacy file removal was interrupted' "$root/error"
if grep -q 'resume with' "$root/error"; then exit 1; fi
grep -q 'untouched vimrc' "$HOME/.vimrc"
# Preserve a different caller umask, with no skip arguments (Bash 3.2).
export HOME="$root/mask-home"
mkdir -p "$HOME"
printf 'old vimrc\n' > "$HOME/.vimrc"
umask 002
EXPECTED_UMASK="$(umask)"
bash "$migrate" --apply > "$root/applied"
[[ "$(cat "$HOME/install-umask")" == "$EXPECTED_UMASK" ]]
# Already managed machines must not be migrated again.
export HOME="$root/managed-home"
mkdir -p "$HOME/.local/bin"
touch "$HOME/.local/bin/dotconfig"
if bash "$migrate" --apply > "$root/error" 2>&1; then exit 1; fi
grep -q 'already has dotconfig' "$root/error"
echo 'Legacy migration tests passed'
