# Migrate a machine installed at b967ec9

The old installer generated `~/.vimrc`, linked the two Vim local files and CoC settings into its checkout, and installed Oh My Zsh with a linked `.zshrc`. The current installer uses chezmoi, machine profiles, native packages, and pinned runtimes/plugins. Migration replaces that legacy configuration while keeping a private backup.

## Prepare and run

Keep the old checkout intact, especially if you edited its `shell/` or `vim/` files. Clone the current repository into a **different directory**: updating the old checkout first can destroy the targets of legacy symlinks. Run as the account whose home you are migrating; do not run the whole command with sudo.

```sh
git clone https://github.com/rmorozov/dotconfig.git ~/dotconfig-current
cd ~/dotconfig-current
bash scripts/migrate-legacy.sh
bash scripts/migrate-legacy.sh --apply
```

The preview makes no changes or downloads. `--apply` explicitly authorizes replacement of the listed files. This is a migration for the legacy file layout, not an assertion that every file still matches the old commit: local edits are backed up too. For a network requiring the local proxy, enable it using `bash scripts/proxy.sh on` before migration.

The same skip options as installation are available:

```sh
bash scripts/migrate-legacy.sh --apply --skip-packages --skip-shell-change
```

For an account without sudo, have an administrator install the system package baseline first (`bash packages/install.sh` from the current checkout). Run migration as the target account with `--skip-packages --skip-shell-change`; the administrator can change its login shell separately. The first-install `--user` path is not a migration path.

Tracked local changes in Oh My Zsh must be saved or committed before migration. Its untracked custom plugins stay in place. Existing Vim plugin directories also stay in place, but the installer can update managed plugin revisions and CoC extensions. System Node/Go/Python installations are retained; managed Zsh selects mise runtimes. Private `.zshrc.local`, role-specific overrides, shell history, and existing backup files are untouched.

## What is backed up

The backup lives at `~/.local/state/dotconfig/migrations/b967ec9/`, protected by private parent directories. `original/` stores regular files and the original symlinks; `contents/` stores readable file contents, including dereferenced symlinks. Broken symlinks are saved in `original/` only. In particular, the old installer created `.zshrc` as the relative link `shell/zshrc`, which is often broken; in that case, no `contents/.zshrc` exists. No private contents are printed or committed.

The files replaced are `.zshrc`, `.vimrc`, `.vimrc.local`, `.vimrc.local.bundles`, `.vim/coc-settings.json`, `.vim/autoload/plug.vim`, `.vim/plugin-lock.vim`, and `.vim/coc-extensions.vim`, when present. The last two are included to cover machines with partial subsequent upgrades. The backup is built in a private temporary sibling directory and moved into place only after all copies succeed. A failed copy cleans up that temporary directory, leaves every original in place, and allows migration to be retried. The restrictive backup umask does not affect the installer. Every backup completes before any of these files is removed. The installer then deploys new managed files and performs the normal installation stages. Other existing managed destinations may still produce chezmoi overwrite prompts.

After success, open a new terminal and run `dotconfig doctor`. Compare saved customizations with the new configuration. Copy selected shell settings into `~/.zshrc.local` or the file opened by `dotconfig private`; do not replace the new managed Zsh configuration wholesale. Vim customizations remain available in the backup for manual integration into the current managed configuration.

The old installer may also have left a stray `~/coc-settings.json` symlink. Migration leaves it untouched. You can delete that link after verifying that it is the legacy link; the current configuration uses `~/.vim/coc-settings.json`.

## Interrupted installation and recovery

Migration refuses to overwrite an existing backup. Recovery depends on the marker files inside it:

- `complete`: installation finished successfully; use `dotconfig doctor` or the normal update commands.
- `files-removed` without `complete`: all listed legacy files were removed, and installation may have started. Once the cause is fixed, resume with `bash install.sh` from the new checkout using the same skip options.
- `removal-started` without `files-removed`: removal was interrupted; some legacy files may still be in place. Inspect and recover the listed files from the complete backup, then keep that backup elsewhere before retrying migration.
- `backup-ready` without `removal-started`: the backup completed, and the legacy files are unchanged. Keep or move this backup aside before retrying migration.
- No recognized marker: the backup may come from an older failed attempt. Do not run `install.sh` over the originals; inspect the backup and home files first.

A copy failure before the backup is published leaves no final backup directory and changes no legacy files. Fix the cause and rerun migration directly. A forcibly terminated backup step may leave a private `b967ec9.tmp.*` sibling directory; those partial snapshots are never treated as ready backups.

To recover the old configuration, keep the current shell open and stop using chezmoi apply/sync. Review `original/`, remove the corresponding newly deployed destination files, and copy those originals back to the same paths in your home. Original symlinks require the old checkout to remain available. For a broken old link, restore the saved regular file from `contents/` instead, if one exists. Keep the backup until recovery is verified in a new shell.

This backup restores the listed configuration files; it does not undo native package installation, runtime downloads, plugin updates, login-shell changes, or other files deployed by chezmoi. `dotconfig rollback` tracks later accepted repository updates and is not a rollback of this initial migration.
