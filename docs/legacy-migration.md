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

The backup lives at `~/.local/state/dotconfig/migrations/b967ec9/`, protected by private parent directories. `original/` stores regular files and the original symlinks; `contents/` stores readable file contents, including dereferenced symlinks. Broken symlinks are saved in `original/` only. No private contents are printed or committed.

The files replaced are `.zshrc`, `.vimrc`, `.vimrc.local`, `.vimrc.local.bundles`, `.vim/coc-settings.json`, `.vim/autoload/plug.vim`, `.vim/plugin-lock.vim`, and `.vim/coc-extensions.vim`, when present. The last two are included to cover machines with partial subsequent upgrades. Every backup completes before any of these files is removed. The installer then deploys new managed files and performs the normal installation stages. Other existing managed destinations may still produce chezmoi overwrite prompts.

After success, open a new terminal and run `dotconfig doctor`. Compare saved customizations with the new configuration. Copy selected shell settings into `~/.zshrc.local` or the file opened by `dotconfig private`; do not replace the new managed Zsh configuration wholesale. Vim customizations remain available in the backup for manual integration into the current managed configuration.

## Interrupted installation and recovery

Migration refuses to overwrite an existing backup, including after a failed installation. Once the cause is fixed, resume with `bash install.sh` from the new checkout, using the same skip options. A `complete` file in the backup indicates that installation finished successfully.

To recover the old configuration, keep the current shell open and stop using chezmoi apply/sync. Review `original/`, remove the corresponding newly deployed destination files, and copy those originals back to the same paths in your home. Original symlinks require the old checkout to remain available. For a broken old link, restore the saved regular file from `contents/` instead, if one exists. Keep the backup until recovery is verified in a new shell.

This backup restores the listed configuration files; it does not undo native package installation, runtime downloads, plugin updates, login-shell changes, or other files deployed by chezmoi. `dotconfig rollback` tracks later accepted repository updates and is not a rollback of this initial migration.
