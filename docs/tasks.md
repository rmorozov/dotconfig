# Follow-up tasks

## Make the advisory audit a required merge check

- [ ] In the GitHub settings for `master`, add **CoC npm dependency audit** to the required status checks of the existing branch protection rule or active ruleset. Keep existing required checks.
- [ ] Verify on a subsequent pull request that the check runs and a failing or pending audit blocks merging. The audit workflow runs on every pull request as of PR #63; the repository setting still needs to be applied.

## Toggle network proxies per machine

- [x] Define `dotconfig proxy on|off|status` semantics and an unmanaged, per-machine configuration source. Preserve proxy URLs, credentials, internal certificate paths, and `NO_PROXY` outside Git. `off` persists for new sessions and takes effect in the current managed Zsh shell.
- [ ] Inventory network clients used by bootstrap, maintenance, and interactive development: curl, Git (including Oh My Zsh and Vim plugins), Homebrew, APT, mise, npm/CoC, and language installers or package managers such as pip and Go modules. Check which clients honor `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY`, including lowercase variants, and which need their own configuration. Test the local Kerberos-aware proxies (cntlm-gss, proxy-detox, Px) when the listener or Kerberos ticket is missing.
- [x] Use a single loader for child processes and newly started shells. Cover `bash install.sh` before chezmoi has applied files, and preserve the selected mode when `dotconfig` launches Bash scripts. Avoid writing a public or machine-wide proxy URL into committed files.
- [ ] Verify Ubuntu APT under `sudo` on a real machine: dotconfig now creates `/etc/apt/apt.conf.d/10-proxy.conf` only when no APT proxy exists. Where existing APT proxy settings are absent, it passes proxy environment through `sudo --preserve-env`; local sudo policy may reject this. Keep existing system package manager settings intact.
- [ ] Test `on`, `off`, `status`, fresh bootstrap, a new shell, and package manager operations on macOS and Ubuntu; include `NO_PROXY` for corporate hosts. Check that status, logs, plans, and error messages never print credentials.

The intended boundary is a machine-local network profile, not a proxy address shared across machines. A proxy switch should affect the tools launched through dotconfig and interactive shells consistently without rewriting users' unrelated package-manager configuration.
