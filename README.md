# dotconfig

Shared Vim, Zsh, and command-line configuration for current Apple Silicon macOS and Ubuntu machines.

## Model

The repository separates three kinds of state:

- `home/` is the chezmoi source state deployed into the home directory.
- `packages/` describes a common command-line capability baseline using native package managers.
- `~/.zshrc.local` remains unmanaged for machine-specific or sensitive settings.

macOS and Ubuntu are kept behaviorally close, but package names and system integration remain native to each platform.

## Bootstrap

Clone the repository, then run:

```sh
bash install.sh
```

The installer:

1. installs chezmoi if necessary;
2. applies `packages/Brewfile` on macOS or `packages/ubuntu.txt` on Ubuntu;
3. uses chezmoi to deploy the home-directory files;
4. installs Oh My Zsh and Vim plugins;
5. optionally changes the login shell.

Existing backups created by the previous installer, such as `.zshrc.pre-dotconfig`, are retained. Use `bash install.sh --help` for options that skip packages, plugins, or the login-shell change.

## Normal update workflow

Review repository changes before applying them:

```sh
git pull --ff-only
chezmoi --source "$PWD" diff
chezmoi --source "$PWD" apply
```

When the package manifests changed, apply them explicitly:

```sh
bash packages/install.sh
```

The package step is intentionally separate during routine updates because it may require `sudo` on Ubuntu and can make larger system changes.

## Package baseline

The manifests target equivalent capabilities rather than identical package versions:

- Git, Curl and Zsh
- Vim, Node.js and Go
- tmux, fzf, ripgrep and The Silver Searcher
- Universal Ctags
- chezmoi on macOS; Ubuntu bootstrap installs chezmoi directly when needed

GUI applications, corporate tooling, Docker, and machine-role-specific packages are deliberately excluded for now.

To inspect the Ubuntu package operation without installing anything:

```sh
bash packages/install.sh --dry-run
```

On macOS, dry-run mode uses `brew bundle check`.

## Configuration layers

- `home/dot_zshrc` becomes `~/.zshrc`.
- `home/dot_vimrc` becomes `~/.vimrc`.
- `home/dot_vimrc.local` and `home/dot_vimrc.local.bundles` contain personal Vim and CoC customization.
- `home/dot_vim/coc-settings.json` becomes `~/.vim/coc-settings.json`.
- `~/.zshrc.local` is loaded when present but is never committed.

## Updating Vim Bootstrap

The **Refresh Vim Bootstrap** GitHub Actions workflow runs monthly and can also be started manually. It regenerates `home/dot_vimrc`, normalizes the generated timestamp, validates the snapshot, and opens or updates a pull request only when substantive content changed.

The generated base is therefore reproducible on every machine while upstream improvements still arrive for review.

## Validation

GitHub Actions runs:

- ShellCheck and Bash/Zsh syntax checks;
- package-manifest script validation;
- structural checks for the Vim Bootstrap snapshot;
- chezmoi rendering checks for the managed Zsh and Vim files.
