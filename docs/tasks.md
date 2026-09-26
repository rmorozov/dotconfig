# Follow-up tasks

## Make the advisory audit a required merge check

- [ ] In the GitHub settings for `master`, add **CoC npm dependency audit** to the required status checks of the existing branch protection rule or active ruleset. Keep existing required checks.
- [ ] Verify on a subsequent pull request that the check runs and a failing or pending audit blocks merging. The audit workflow runs on every pull request as of PR #63; the repository setting still needs to be applied.

## Toggle network proxies per machine

- [ ] Define `dotconfig proxy on|off|status` semantics and an unmanaged, per-machine configuration source. Preserve proxy URLs, credentials, internal certificate paths, and `NO_PROXY` outside Git. Decide whether `off` means a temporary shell override or a persistent state for new sessions; support both only if the distinction is clear.
- [ ] Inventory network clients used by bootstrap, maintenance, and interactive development: curl, Git (including Oh My Zsh and Vim plugins), Homebrew, APT, mise, npm/CoC, and language installers or package managers such as pip and Go modules. Check which clients honor `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY`, including lowercase variants, and which need their own configuration.
- [ ] Prefer a single loader for child processes and newly started shells. Cover `bash install.sh` before chezmoi has applied files, and preserve the selected mode when `dotconfig` launches Bash scripts. Avoid writing a public or machine-wide proxy URL into committed files.
- [ ] Handle Ubuntu APT under `sudo` explicitly: verify whether a temporary `sudo` invocation can pass the chosen proxy safely; if persistent APT configuration is needed, generate it locally with restrictive permissions and remove only the file owned by dotconfig when disabling. Keep the system package manager's existing settings intact.
- [ ] Test `on`, `off`, `status`, fresh bootstrap, a new shell, and package manager operations on macOS and Ubuntu; include `NO_PROXY` for corporate hosts. Check that status, logs, plans, and error messages never print credentials.

The intended boundary is a machine-local network profile, not a proxy address shared across machines. A proxy switch should affect the tools launched through dotconfig and interactive shells consistently without rewriting users' unrelated package-manager configuration.
