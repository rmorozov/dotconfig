# dotconfig

Shared Vim, Zsh, runtime, and command-line configuration for current Apple Silicon macOS and Ubuntu machines.

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
4. installs the mise-managed Node.js, Go, and Python versions;
5. installs Oh My Zsh and Vim plugins;
6. optionally changes the login shell.

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
dotconfig runtimes
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
- Vim and mise
- tmux, fzf, ripgrep and The Silver Searcher
- Universal Ctags
- chezmoi on macOS; Ubuntu bootstrap installs chezmoi directly when needed

Node.js, Go, and Python are intentionally absent from the native manifests. Their exact shared versions live in `home/dot_config/mise/config.toml`, and `dotconfig runtimes` installs any missing pins.

GUI applications, corporate tooling, Docker, and machine-role-specific packages are deliberately excluded for now.

To check package drift without installing anything:

```sh
bash packages/install.sh --check
```

On macOS this uses `brew bundle check`; on Ubuntu it queries the installed dpkg state.

## Configuration layers

- `home/dot_zshrc.tmpl` becomes the small `~/.zshrc` orchestrator.
- `home/dot_config/zsh/common.zsh` contains shared shell behavior.
- `home/dot_config/zsh/darwin.zsh` and `linux.zsh` isolate platform-specific paths, plugins, and aliases.
- `home/dot_vimrc` becomes `~/.vimrc`.
- `home/dot_vimrc.local` and `home/dot_vimrc.local.bundles` contain personal Vim and CoC customization.
- `home/dot_vim/coc-settings.json` becomes `~/.vim/coc-settings.json`.
- `~/.zshrc.local` is loaded when present but is never committed.

## Runtime versions

mise supplies the same runtime versions on macOS and Ubuntu:

- Node.js tracks the current LTS line;
- Go tracks the latest stable release;
- Python tracks the latest stable 3.14 patch release.

The committed file contains exact versions, so machines do not resolve moving aliases independently. The **Refresh runtime versions** workflow runs monthly, rewrites those pins from the allowed channels, and opens a pull request for review. After merging one, run `dotconfig update` and then `dotconfig runtimes` on each machine.

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

## Repository maintenance automation

The repository has independent maintenance loops for validation and controlled upgrades:

- every pull request validates Ubuntu 26.04 and Apple Silicon macOS 26;
- the same target-platform validation runs every Monday even when the repository has not changed, exposing operating-system or upstream installer breakage;
- Dependabot groups GitHub Actions updates into a monthly reviewable pull request;
- the runtime refresh workflow proposes new exact Node.js LTS, Go, and Python 3.14 pins each month.

Vim Bootstrap remains on its separate monthly refresh workflow. None of these workflows upgrade packages or plugins on personal machines; those changes remain explicit through `dotconfig packages` and normal configuration review.
