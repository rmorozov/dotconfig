# dotconfig

Shared Vim, Zsh, and command-line configuration for current Apple Silicon macOS and Ubuntu machines.

## Model

The repository separates three kinds of state:

- `home/` is the chezmoi source state deployed into the home directory.
- `packages/` describes a common command-line capability baseline using native package managers.
- `~/.zshrc.local` remains unmanaged for machine-specific or sensitive settings.

macOS and Ubuntu are kept behaviorally close, but package names and system integration remain native to each platform.

## Machine profiles

On first bootstrap, chezmoi asks for two stable attributes:

- role: `personal` or `work`;
- host type: `laptop`, `desktop`, or `server`.

The rendered shell exports these as `DOTCONFIG_ROLE` and `DOTCONFIG_HOST_TYPE`. The selected role also enables an optional private file:

```text
~/.zshrc.personal.local
~/.zshrc.work.local
```

These files are deliberately unmanaged. They are suitable for corporate paths, proxy configuration, internal certificate locations, and other settings that must not enter the public repository. The existing `~/.zshrc.local` remains the shared per-machine override.

Run `dotconfig status` or `dotconfig doctor` to see the active profile. To change it later, edit the chezmoi configuration with `chezmoi edit-config`, then run `dotconfig apply`.

## Bootstrap

Clone the repository, then run:

```sh
bash install.sh
```

The installer:

1. installs chezmoi if necessary;
2. applies `packages/Brewfile` on macOS or `packages/ubuntu.txt` on Ubuntu;
3. asks for the machine profile on first use and deploys the home-directory files;
4. installs Oh My Zsh and Vim plugins;
5. optionally changes the login shell.

Existing backups created by the previous installer, such as `.zshrc.pre-dotconfig`, are retained. Use `bash install.sh --help` for options that skip packages, plugins, or the login-shell change.

## Normal update workflow

The installer deploys a `dotconfig` maintenance command into `~/.local/bin`.

Inspect a machine without changing it:

```sh
dotconfig status
dotconfig doctor
```

Safely fast-forward the repository, review the rendered diff, and confirm before applying it:

```sh
dotconfig update
```

The individual operations remain available:

```sh
dotconfig apply
dotconfig packages
dotconfig path
```

Package updates are intentionally separate during routine updates because they may require `sudo` on Ubuntu and can make larger system changes. The lower-level chezmoi commands remain usable when needed:

```sh
chezmoi --source "$(dotconfig path)" diff
chezmoi --source "$(dotconfig path)" apply
```

## Package baseline

The manifests target equivalent capabilities rather than identical package versions:

- Git, Curl and Zsh
- Vim, Node.js and Go
- tmux, fzf, ripgrep and The Silver Searcher
- Universal Ctags
- chezmoi on macOS; Ubuntu bootstrap installs chezmoi directly when needed

GUI applications, corporate tooling, Docker, and machine-role-specific packages are deliberately excluded for now.

To check package drift without installing anything:

```sh
bash packages/install.sh --check
```

On macOS this uses `brew bundle check`; on Ubuntu it queries the installed dpkg state.

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
- a real chezmoi apply into an isolated temporary home;
- ShellCheck of the rendered `dotconfig` command;
- native jobs on Ubuntu 26.04 and Apple Silicon macOS 26.
