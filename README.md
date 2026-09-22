# dotconfig

Shared Vim and Zsh configuration for current Apple Silicon macOS and Ubuntu machines.

## Bootstrap

Clone the repository and run:

```sh
./install.sh
```

The installer:

- installs missing prerequisites with Homebrew on macOS or `apt` on Ubuntu;
- backs up an existing managed file once with a `.pre-dotconfig` suffix;
- creates absolute symlinks to the files in this checkout;
- installs Oh My Zsh and Vim plugins;
- can safely be run again.

Use `./install.sh --help` to see options for skipping package installation, plugin installation, or the login-shell change.

## Configuration layers

- `vim/.vimrc` is a committed Vim Bootstrap snapshot.
- `vim/.vimrc.local` and `vim/.vimrc.local.bundles` contain personal Vim and CoC customization.
- `shell/zshrc` contains common configuration with small macOS and Ubuntu branches.
- `~/.zshrc.local` is intentionally untracked and may contain machine-specific or sensitive configuration.

## Updating Vim Bootstrap

The **Refresh Vim Bootstrap** GitHub Actions workflow runs monthly and can also be started manually. It requests a new configuration using the repository's current language and plugin selection, normalizes the generated timestamp, validates the result, and opens or updates a pull request only when substantive content changed.

This keeps installation reproducible while allowing Vim Bootstrap changes to be reviewed before they reach other machines.

## Updating a machine

Pull reviewed repository changes and rerun the installer:

```sh
git pull --ff-only
./install.sh
```

GitHub Actions checks shell syntax, ShellCheck findings, and whether the committed Vim configuration can be sourced.
