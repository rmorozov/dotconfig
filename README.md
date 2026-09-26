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

Use `dotconfig private` to create or edit the active role-specific file. New files are created with mode `0600`, and existing files are tightened to that mode before the editor opens. `dotconfig doctor` reports private override files that are accessible to group or other users.

Run `dotconfig status` or `dotconfig doctor` to see the active profile. To change it later, edit the chezmoi configuration with `chezmoi edit-config`, then run `dotconfig apply`.

## Private configuration

### Machine-local proxy switch

Create `~/.config/dotconfig/proxy.local` as a private shell file, for example:

```sh
mkdir -p ~/.config/dotconfig
chmod 700 ~/.config/dotconfig
cat > ~/.config/dotconfig/proxy.local <<'EOF'
export http_proxy='http://proxy.example:8080'
export https_proxy="$http_proxy"
export no_proxy='localhost,127.0.0.1,.internal.example'
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export NO_PROXY="$no_proxy"
EOF
chmod 600 ~/.config/dotconfig/proxy.local
dotconfig proxy on
```

Run `dotconfig proxy off` to disable it or `dotconfig proxy status` to check the saved mode. In a managed Zsh shell, on/off refresh the current shell immediately. Other shells should be restarted. The profile is local shell code: only use a file you control. Its contents and proxy URLs are never committed or displayed by `status`. To bootstrap on a new machine before `dotconfig` is installed, create this file and run `bash scripts/proxy.sh on` before `bash install.sh`.

The loader exports the profile's variables to curl, Git, Homebrew, mise, npm and other tools that honor proxy environment variables. It also supplies them to the repository's APT operations using `sudo --preserve-env`; a restrictive local sudo policy may require a separate APT setup. Existing proxy settings inside Git, npm, APT or other tools can take precedence and are not edited by this switch. Before the first on/off command, existing environment settings remain untouched. An explicit `off` removes inherited proxy environment variables from managed shells and dotconfig operations, including `ALL_PROXY`; it does not reconfigure the operating system or other applications. Keep any certificate paths and credentials in this local profile, and check your machine's trust settings when using an intercepting proxy.

The repository never reads private override contents into Git. Keep ordinary machine-specific values in `~/.zshrc.local` and role-specific or sensitive values in `~/.zshrc.personal.local` or `~/.zshrc.work.local`.

This is local secret hygiene, not secret synchronization. Do not commit passwords, tokens, private keys, or corporate configuration. Cross-machine encrypted synchronization requires a separately backed-up encryption identity and is intentionally deferred until that key-storage policy is chosen.

## Bootstrap

Clone the repository, then run:

```sh
bash install.sh
```

The installer:

1. installs missing chezmoi and mise from the exact, checksum-verified release archives;
2. applies `packages/Brewfile` on macOS or `packages/ubuntu.txt` on Ubuntu;
3. asks for the machine profile on first use and deploys the home-directory files;
4. installs the mise-managed Node.js, Go, and Python versions;
5. installs Oh My Zsh and Vim plugins;
6. optionally changes the login shell.

Existing backups created by the previous installer, such as `.zshrc.pre-dotconfig`, are retained. Use `bash install.sh --help` for options that skip packages, plugins, or the login-shell change.

Bootstrap trust is recorded in `versions/bootstrap-tools`. The status and doctor commands flag installed chezmoi or mise versions that differ from those pins, including binaries supplied by a native package manager. Merging a bootstrap refresh does not replace an existing executable. After reviewing the new pin, run `dotconfig bootstrap` to install the exact chezmoi and mise releases into `~/.local/bin` and verify the versions now selected on `PATH`. This is explicit and separate from `dotconfig sync`. On macOS the package baseline no longer installs duplicate chezmoi or mise formulae. The pinned user-local binaries take precedence in the managed Zsh configuration. Existing Homebrew copies are not removed automatically. Fresh installs select verified binaries before the package step. An existing chezmoi or mise is left in place by `install.sh`; use `dotconfig bootstrap` to converge it explicitly. Homebrew is installed only when the native package baseline is requested. On both target platforms, the exact mise and chezmoi release archives are checked against SHA-256 values committed in the manifest before extraction. A missing Homebrew installation still uses an installer fetched from an immutable commit. That script is downloaded to a temporary file rather than streamed into a shell, and repository validation rejects new `curl | sh` patterns.

## Normal update workflow

The installer deploys a `dotconfig` maintenance command into `~/.local/bin`.

Inspect a machine without changing it:

```sh
dotconfig status
dotconfig doctor
dotconfig report
dotconfig report --json
```

Both commands compare installed chezmoi and mise versions with `versions/bootstrap-tools`, as well as the installed vim-plug file, Vim plugin commits, and CoC extension versions with the committed manifests. `status` reports every category before returning failure on drift, rather than stopping at the first missing package; `doctor` includes the same editor checks in its prerequisite diagnosis.

`report` reads the local state without changing it. Its versioned JSON form includes the repository and reviewed commits, profile, expected and installed dependency revisions, and dotfile/package drift. It does not include hostnames, private file contents, or absolute paths. Keep exported reports local unless you explicitly decide to share their machine metadata. The report returns successfully when it finds drift; inspect the `state` fields to decide whether to sync.

Save a report on each machine and compare them locally:

```sh
dotconfig report --json > machine-a.json
dotconfig compare machine-a.json
dotconfig compare machine-a.json machine-b.json
```

With one file, `compare` measures this machine against the saved report; with two, it works offline. It shows profile and OS for context, then only differing repository, package, dotfile, and pinned dependency fields. Exit status is 0 when those states match, 1 when they differ, and 2 for invalid input. Platform and role differences are context, since they may be intentional. Reports now record each native package baseline capability, its installed state, and its local version. Comparisons check shared capability presence across macOS and Ubuntu; they compare package versions only on the same OS. Refresh older saved reports to include this detail. `dotconfig packages --plan` shows available upgrades using the local package metadata. Reports contain machine metadata, so copy and store them according to your local privacy policy.

For differing states, `compare` groups suggested checks by repository, packages, bootstrap tools, runtimes, shell, and editor. The suggestions identify commands to inspect or explicitly converge on the affected machine; they do not choose which machine should lead or run an installation.

Safely fast-forward the repository, review pulled repository changes and the rendered dotfile diff, and confirm before applying:

```sh
dotconfig update
```

To bring a machine fully onto the reviewed repository state in one pass, use:

```sh
dotconfig sync
```

Preview first with `dotconfig sync --dry-run`. It fetches upstream metadata and shows the incoming repository diff alongside the **current** machine's status, without pulling, applying, installing, or marking a commit reviewed. Rendered dotfile and dependency effects of incoming commits are checked during the normal review after the pull. The preview refuses dirty or diverged repositories.

The accepted commit is recorded in the clone's local Git config. If confirmation is declined, a later `update` or `sync` still shows the unreviewed changes and asks again, including when only scripts or manifests changed. A successful first installation records its initial commit. `dotconfig status` reports a pending review.

After the same pull, diff, and confirmation flow, `sync` installs the pinned mise runtimes, converges the exact Oh My Zsh revision, and installs the pinned Vim plugins and CoC extensions. If review is declined, the remaining convergence steps do not run. Native packages stay separate because Ubuntu may require `sudo` and package-manager changes deserve an explicit operation.

The individual operations remain available:

```sh
dotconfig apply
dotconfig packages
dotconfig bootstrap
dotconfig runtimes
dotconfig shell
dotconfig vim
dotconfig private
dotconfig path
```

### Recovering from an update

After you accept a newer repository commit, `dotconfig` retains the preceding accepted commit in local Git configuration. If the update causes trouble, run `dotconfig rollback` from a clean checkout. It shows the commit change and requires interactive confirmation, then checks out the previous accepted commit on a local rollback branch and reapplies its managed dotfiles. Your newer commit remains available on the original branch; the rollback branch tracks the same upstream, so `dotconfig update` can later review the latest state again.

Rollback does not downgrade native packages or automatically change installed runtimes, Oh My Zsh, or editor plugins. Inspect with `dotconfig status`, then run `dotconfig runtimes`, `dotconfig shell`, and `dotconfig vim` if you want those components to follow the restored pins. Bootstrap tools remain a separate explicit operation. A checkpoint becomes available after the first accepted update made with this version of `dotconfig`; earlier updates did not record one. If managed-dotfile application fails, the command leaves the repository on the rollback branch and keeps the reviewed marker unchanged for inspection.

Package updates are intentionally separate during routine updates because they may require `sudo` on Ubuntu and can make larger system changes. The lower-level chezmoi commands remain usable when needed:

```sh
chezmoi --source "$(dotconfig path)" diff
chezmoi --source "$(dotconfig path)" apply
```

## Package baseline

The authoritative `packages/packages.tsv` manifest maps equivalent capabilities to their Homebrew and Ubuntu package names. `packages/Brewfile` and `packages/ubuntu.txt` are generated from it.

- Git, Curl and Zsh
- Vim
- tmux, fzf, ripgrep and The Silver Searcher
- Universal Ctags

Chezmoi and mise are installed from the checksum-verified bootstrap manifest on both platforms and checked by `dotconfig status` and `doctor`. Node.js, Go, and Python are intentionally absent from the native manifests. Their exact shared versions live in `home/dot_config/mise/config.toml`, and `dotconfig runtimes` installs any missing pins.

GUI applications, corporate tooling, Docker, and machine-role-specific packages are deliberately excluded for now.

To check package drift without installing anything:

```sh
bash packages/install.sh --check
```

On macOS this uses `brew bundle check`; on Ubuntu it queries the installed dpkg state.

To see available updates for the native package baseline without changing installed packages:

```sh
dotconfig packages --outdated
```

For a broader preview of missing packages and proposed changes, run `dotconfig packages --plan`. It uses Homebrew's bundle check and baseline formula list on macOS, and simulates installing the baseline plus required dependencies on Ubuntu. It does not install packages or refresh repository metadata.

Review native package updates about once a week, and sooner when your OS vendor announces a relevant security fix: refresh the machine's package metadata with `brew update` or `sudo apt-get update`, run `dotconfig packages --plan`, then run `dotconfig packages` when you accept the changes. On Ubuntu, also use the operating system's regular security update mechanism for packages outside this small baseline. Homebrew's plan lists baseline formula updates but cannot predict every dependency change. Native repositories choose versions independently per machine; this check is a review routine, not an exact lock or a vulnerability assessment.

On macOS this queries Homebrew for formulae in the shared manifest. On Ubuntu it filters a simulated apt upgrade to the manifest packages and uses the local apt cache; run `sudo apt-get update` separately if the cache is stale. This reports available versions, not confirmed vulnerabilities. Native upgrades remain an explicit machine operation.

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

The committed file contains exact versions, so machines do not resolve moving aliases independently. `versions/runtime-channels` records each tool's refresh selector, executable, and version argument. To add a runtime, add one row there and its exact pin under `[tools]` in `home/dot_config/mise/config.toml`. The nightly updater checks that the lists agree, and platform CI executes each tool using the declared command. Installation and status checks use the exact pins even when invoked inside a project with its own mise configuration. The **Refresh runtime versions** workflow runs nightly, rewrites those pins from the allowed channels, and opens a pull request for review. After merging one, run `dotconfig update` and then `dotconfig runtimes` on each machine.

## Updating Oh My Zsh

Oh My Zsh is installed at the exact commit recorded in `versions/oh-my-zsh`. This prevents newly bootstrapped machines from silently receiving different shell behavior. Run `dotconfig shell` to converge a machine on the committed revision.

The **Refresh Oh My Zsh** workflow proposes a new upstream commit nightly. Before advancing the pin, it checks that the candidate revision still contains every plugin named in the shared, Linux, and macOS Zsh modules. A missing plugin fails the refresh, leaving the previous pin in place for investigation. The change remains inert on machines until its pull request is reviewed, merged, and applied explicitly.

## Vim plugin revisions

The vim-plug manager itself is vendored at `home/dot_vim/autoload/plug.vim`, with its upstream commit and file hash recorded in `versions/vim-plug`. Its first-run fallback URL in the generated vimrc points to that exact commit. The **Refresh vim-plug** workflow proposes changes to both files nightly when upstream code changes; it stages the manager, pin, and fallback URL before updating the repository, and a later run repairs any interrupted partial update. The static validator checks that the vendored file and fallback URL match the pin.

Every Git-backed Vim plugin is pinned in `versions/vim-plugins`. Plugins installed outside vim-plug's default `~/.vim/plugged/<name>` directory are listed in `versions/vim-plugin-locations` using a home-relative path; `fzf` currently uses `~/.fzf`. Pass a home-relative directory as the third argument to `scripts/add-vim-plugin.sh` to create the matching Vim declaration and location entry together. Chezmoi deploys the generated `~/.vim/plugin-lock.vim`, which applies exact commit constraints before vim-plug finishes initialization. Existing `do` hooks therefore run against the pinned revision.

Run `dotconfig vim` to converge a machine. The installer, `dotconfig vim`, and `dotconfig sync` verify the installed vim-plug file, Vim plugin commits, and CoC extension versions before reporting success. The **Refresh Vim plugins** workflow resolves the configured upstream branch for each plugin nightly and opens a reviewable PR containing both the manifest and generated lock.

## Maintaining dependency lists

Files under `versions/` are authoritative; generated Vim files say so in their first line and should not be edited directly. CI regenerates them and fails when a manifest change was not propagated. It also compares every Git-backed `Plug` declaration in the snapshot and local bundles with `versions/vim-plugins`; a Vim Bootstrap refresh that adds or removes a plugin needs a matching manifest update before merge.

Use the helpers for additions:

```sh
scripts/add-native-package.sh jq jq jq
scripts/add-native-package.sh capability homebrew-formula ubuntu-package
scripts/add-coc-extension.sh coc-example
scripts/add-coc-extension.sh coc-example 1.2.3
scripts/add-vim-plugin.sh owner/repository
scripts/add-vim-plugin.sh owner/repository release-branch
scripts/add-vim-plugin.sh owner/repository HEAD .vim/custom-checkout
```

Use `-` when a native package is intentionally absent on one platform. Each helper rejects duplicate capability or dependency names, updates its authoritative manifest, and regenerates deployed files. The Vim and CoC helpers also resolve an exact current revision or version. Existing pinned dependencies are refreshed by the nightly workflows. Runtimes remain simple keys in `home/dot_config/mise/config.toml`; Zsh plugins are grouped in the shared and platform-specific Zsh modules.

## CoC extension versions

Configured CoC extensions are installed as exact npm versions generated from `versions/coc-extensions`. They converge through the existing `dotconfig vim` command. The **Refresh CoC extensions** workflow proposes version bumps nightly without changing `coc.nvim` or the Vim Bootstrap snapshot.

Extensions removed because of unresolved advisories remain recorded in `versions/coc-extensions-disabled`, together with the advisory that caused quarantine. The **Reconsider quarantined CoC extensions** workflow audits each package's latest release nightly with lifecycle scripts disabled. Vulnerable packages remain quiet and disabled; when a package resolves without high-severity npm advisories, automation removes it from quarantine and opens a reviewable PR restoring the same exact version it audited.

## Updating Vim Bootstrap

The **Refresh Vim Bootstrap** GitHub Actions workflow runs nightly and can also be started manually. It regenerates `home/dot_vimrc`, normalizes the generated timestamp, validates the snapshot, and opens or updates a pull request only when substantive content changed.

Edit `versions/vim-bootstrap-profile` to add or remove `language` and `plugin` rows; keep the single `editor vim` row. The nightly workflow reads this profile and proposes the resulting Vim snapshot for review. Run `bash scripts/refresh-vim-bootstrap.sh` to generate it locally after editing the profile.

The generated base is therefore reproducible on every machine while upstream improvements still arrive for review.

## Validation

Run the same static checks locally before pushing:

```sh
bash scripts/validate.sh
```

The validator discovers shell scripts and Zsh modules automatically, checks generated dependency files, and validates pinned manifests. Adding another script does not require maintaining a parallel filename list in CI.

GitHub Actions additionally runs:

- ShellCheck and Bash/Zsh syntax checks;
- package-manifest script validation;
- structural checks for the Vim Bootstrap snapshot;
- installation and executable version checks for every committed mise runtime pin in an isolated home on both platforms;
- a real chezmoi apply into an isolated temporary home;
- ShellCheck of the rendered `dotconfig` command;
- native jobs on Ubuntu 26.04 and Apple Silicon macOS 26.

## Repository maintenance automation

The repository has independent maintenance loops for validation and controlled upgrades:

Nightly discovery does not mean nightly installation. Each stream force-updates one stable automation branch and pull request, so a later run supersedes an unmerged proposal instead of creating a queue. If the latest discovery matches the base branch, the workflow closes the now-obsolete automation PR and deletes its branch. Updates remain exact, reviewable pins and are never auto-merged or deployed to machines.

All refresh workflows use `scripts/open-refresh-pr.sh` for the shared commit, force-push, and PR-upsert behavior. The local validator exercises that helper against an isolated bare Git repository and a fake `gh` client.

The helper explicitly dispatches platform validation and the advisory audit for every bot-authored PR. Human-authored PRs also run both checks. Keeping the advisory check present on every proposal lets branch protection require it without blocking unrelated refreshes. The audit runs against the proposed commit; the independent nightly audit still checks committed pins. Per-ref concurrency prevents different nightly proposals from canceling one another's audit.

Refresh PR descriptions include the changed-file summary and a bounded diff of version manifests and runtime pins. Each nightly replacement refreshes that summary, so it reflects the current proposed commit. Review the full diff for generated configuration and executable code changes before merging.

The CoC refresh, advisory audit, and quarantine review workflows use the exact Node version in `home/dot_config/mise/config.toml` rather than the runner's preinstalled Node or a moving major alias.

The nightly advisory audit builds a temporary npm lock from the exact CoC extension versions with lifecycle scripts disabled, then runs `npm audit` at high severity. This detects published npm advisories, including affected transitive dependencies. It cannot prove that a new release is trustworthy, and it does not cover Vim Git commits or vulnerabilities managed by macOS/Ubuntu package repositories.

- every pull request validates Ubuntu 26.04 and Apple Silicon macOS 26;
- the same target-platform validation runs every Monday even when the repository has not changed, exposing operating-system or upstream installer breakage;
- GitHub Actions are executed from immutable full commit SHAs; validator rejects mutable tag references;
- Dependabot checks those pinned Actions daily and groups proposed SHA updates into a reviewable pull request;
- the bootstrap refresh workflow proposes exact chezmoi/mise releases, their archive SHA-256 pins, and the immutable Homebrew installer revision each night;
- the runtime refresh workflow proposes new exact Node.js LTS, Go, and Python 3.14 pins each night;
- the Oh My Zsh refresh workflow proposes a new exact upstream revision each night;
- the Vim plugin and CoC extension workflows propose exact reviewed editor dependency updates.

Vim Bootstrap and Vim plugin revisions remain on separate nightly refresh workflows: the first updates configuration, while the second updates executable plugin code. None of these workflows upgrade packages or plugins on personal machines; those changes remain explicit through `dotconfig packages` and normal configuration review.
