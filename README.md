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

For a local Kerberos-aware proxy such as Px, cntlm-gss, or proxy-detox listening on `127.0.0.1:3128`, start that service with your usual machine-specific setup, then run:

```sh
dotconfig proxy on
dotconfig proxy status
dotconfig proxy off
```

The built-in endpoint is `http://127.0.0.1:3128` for HTTP and HTTPS requests, with localhost bypassed. Dotconfig does not start the service, acquire Kerberos tickets, or probe connectivity. If the proxy stops or its ticket expires, requests through it fail until you restore the service or turn the switch off. For a new machine before `dotconfig` is installed, run `bash scripts/proxy.sh on` before `bash install.sh`.

Extend the bypass list in `~/.config/dotconfig/no-proxy.local`, one entry per line. Blank lines and `#` comments are ignored, duplicate entries are removed, and `localhost,127.0.0.1,::1` remain in the list:

```sh
mkdir -p ~/.config/dotconfig
chmod 700 ~/.config/dotconfig
cat > ~/.config/dotconfig/no-proxy.local <<'EOF'
# Internal services that should bypass the local proxy
.internal.example
git.internal.example
EOF
chmod 600 ~/.config/dotconfig/no-proxy.local
dotconfig proxy on
```

Run `dotconfig proxy on` again after editing the list to update the persistent files and current managed Zsh shell. Other shells should be restarted. Different clients interpret bypass patterns differently; verify domain suffixes or CIDR entries against the tools you use. To change the local proxy port or set additional environment variables, optionally use `~/.config/dotconfig/proxy.local` as private shell code. Both optional files should have mode `0600`; their contents are never committed or displayed by `status`.

On Ubuntu, `on` also adds a marked block to `/etc/environment` if it has no existing proxy assignments, and creates `/etc/apt/apt.conf.d/10-proxy.conf` if the APT configuration directory has no proxy settings. Both operations require `sudo`. APT ignores `no_proxy` once a proxy is configured, so exact host names from the bypass list are written as `DIRECT` entries; domain suffixes and CIDR ranges cannot be expressed there. It adds a marked block to the current user's `~/.npmrc` if that file has no proxy keys; this applies on both platforms. `off` removes only dotconfig's blocks and deletes a file only when that block was its sole content. Existing settings are preserved and can remain effective after `off`. The system environment takes effect for new login sessions; APT and npm read their configuration on the next invocation. This does not configure system services already running, nor does it change macOS system-wide proxy settings.

The loader exports the local endpoint and optional profile overrides to curl, Git, Homebrew, mise, npm and other tools that honor proxy environment variables. It also sets `NODE_USE_ENV_PROXY=1` so the built-in `fetch` of Node.js 24 uses the proxy. [docs/proxy-clients.md](docs/proxy-clients.md) lists how each client reads these settings and the known gaps. For APT without persistent proxy settings, dotconfig passes them through `sudo --preserve-env`; a restrictive local sudo policy may require a separate APT setup. Only credential-free loopback proxy URLs are allowed in the persisted files. Existing proxy settings inside Git, npm, APT or other tools can take precedence and are not edited by this switch. Before the first on/off command, existing environment settings remain untouched. An explicit `off` removes inherited proxy environment variables from managed shells and dotconfig operations, including `ALL_PROXY`.

The repository never reads private override contents into Git. Keep ordinary machine-specific values in `~/.zshrc.local` and role-specific or sensitive values in `~/.zshrc.personal.local` or `~/.zshrc.work.local`.

This is local secret hygiene, not secret synchronization. Do not commit passwords, tokens, private keys, or corporate configuration. Cross-machine encrypted synchronization requires a separately backed-up encryption identity and is intentionally deferred until that key-storage policy is chosen.

### Domain login caches on Ubuntu

On Ubuntu machines that log in with a domain account through SSSD, `dotconfig creds` inspects and clears what SSSD and Kerberos cached:

```sh
dotconfig creds status          # settings, PAM order, cached passwords, tickets; never secrets
dotconfig creds check-logs      # search the last 7 days of login logs and judge the likely cause
dotconfig creds clear           # kdestroy -A and sss_cache -E; cached passwords stay
dotconfig creds clear --purge   # also stop SSSD and move its whole cache aside
```

`status` reads `/etc/sssd` and `/var/lib/sss` through `sudo`. It shows only the settings that decide offline login and flags the two usual reasons a domain password is never cached: `cache_credentials` left at its default of `False`, and `pam_krb5` authenticating before `pam_sss`, which skips SSSD entirely. Installing `ldb-tools` lets it name the users with a cached password.

`status` also checks file access the way SSSD 2.12 on Ubuntu 26.04 does. That release runs the daemon as the `sssd` user, so `root:sssd 0640` is a valid `sssd.conf`. The check takes the service user and groups from `systemctl show sssd.service` on the running system, including `Group=` and `SupplementaryGroups=` overrides and numeric IDs. When it inspects files without systemd, it reads `sssd.service` and its drop-ins instead and labels the result an approximation. SSSD 2.11 removed the `[sssd] user` option, which is reported as stale. The check accepts only root or `sssd` as owner and group, rejects access for others, and checks that the service user can read each snippet and enter its directories. For Kerberos it follows `krb5.conf` and its `include` and `includedir` targets, which ordinary users must be able to read, and it checks that `/etc/krb5.keytab` stays private. POSIX access ACLs are evaluated as acl(5) describes, on the file and on every directory above it, so a named-user entry can deny what mode bits allow and the reverse. When an ACL cannot be read, access is reported as not checked.

Every result line says how sure it is:
- `warning` is a problem the evidence confirms.
- `possible cause` is a hypothesis that the evidence does not settle.
- `not checked` means the evidence could not be gathered, such as unreadable metadata, an unevaluated ACL, or an unknown service user.
- `check failed` means a probe like `systemctl`, `sssctl` or `journalctl` exited with an error; the line keeps its exit status and a sanitized first line of output.

Neither uncertain kind is ever reported as a cause.

The rest of `status` covers the Ubuntu 26.04 platform around SSSD:
- **Packages.** SSSD and Kerberos package versions from dpkg, partial installs, and mixed versions. It also flags builds that predate Ubuntu fixes the upstream version hides: helper capabilities before restart in `2.12.0-1ubuntu5.2`, and the slow-smartcard crash in `5.3`.
- **Service and helpers.** Responder identities. It checks that `krb5_child`, `ldap_child` and `sssd_pam` are `root:sssd 0750` and carry their file capabilities, and that `NoNewPrivileges`, `CapabilityBoundingSet` or a `nosuid` mount does not cancel those capabilities. It also checks, for each directory SSSD writes, that the unit's mount sandbox (`ProtectSystem=strict`, `ReadOnlyPaths`, `InaccessiblePaths`, reopened by `ReadWritePaths` or `StateDirectory`) leaves the cache and logs writable and does not hide the configuration or keytab. On the running system these settings come from systemd itself.
- **State directories.** `/var/lib/sss`, `/run/sssd` and `/var/log/sssd` are checked against who must reach them. The cache stays private, and the pipes and `pubconf` stay public. Its advice never uses a recursive `chmod` or `chown`.
- **Configuration hygiene.** Removed options (`[sssd] user`, `id_provider = files`, `ipa_enable_dns_sites` and others), misspelled sections, inline comments, and `domains` entries without a section. Shown values name the snippet that set them. No configuration value is printed.
- **Kerberos caches and keys.** The effective ticket cache, from `krb5_ccname_template` or `default_ccache_name`. SSSD 2.11 and later no longer create missing parent directories for `FILE:` and `DIR:` caches, and KCM needs `sssd-kcm.socket`. It also lists the keytab's encryption types, flagging keytabs with only RC4 or 3DES keys, which 26.04 no longer allows by default. Key bytes are never read into the output.
- **PAM services.** The auth, account and session modules of `gdm-password`, `gdm-smartcard`, `login`, `sshd`, `su` and `sudo`, including services that check domain passwords but skip domain access rules.
- **Smartcard.** When `pam_cert_auth` is on: the CA bundle, PKCS#11 module files, and the `gdm-smartcard` service.

Anything that needs the running system, such as systemd state, `sssd --version`, NTP sync or mount options, is listed under **Not checked** when it could not be checked.

CI also installs the packaged SSSD on an Ubuntu 26.04 runner and runs both commands against it (`scripts/test-credentials-live.sh`), failing on any permission, capability or sandbox warning the packaged layout would trigger. That runner has no domain, so logins, cached passwords and the VPN are still checked only by fixtures and on a real machine.

`check-logs` reads, through `sudo`, the journal for the SSSD units, the auth facility, and OpenConnect or NetworkManager VPN messages, plus `/var/log/sssd/*.log` including rotated files, and falls back to `/var/log/auth.log` when the journal has no auth entries. Besides SSSD's own messages, it matches AppArmor denials for SSSD processes (summarized by profile, operation and path), ticket-cache creation failures, home-directory and session-stage failures, `pam_sss` account-stage refusals, unsupported encryption types, stale keytabs, smartcard failures, and local accounts that share a short name with a domain user. It matches known patterns such as `pam_sss` returning `Authentication service cannot retrieve authentication info`, `Cached credentials not available`, expired cached entries, unreachable KDCs or domain controllers, clock skew, keytab and GPO failures, and SSSD watchdog restarts. It prints each finding with its count, time span, and one example line (`--examples N` for more), then an assessment that weighs the logs against the configuration. Each failed offline login is tied to its own user, domain and PAM service. It counts as offline only with an unreachable line from its own domain; lines that name no domain, or VPN timing, make it a possible cause when several domains are configured. it is blamed on `cache_credentials` only for its own domain, and on a `pam_krb5` bypass only in its own service's stack. When the logs do not say which domain or stack applies, the candidate settings are printed as a possible cause. An unreadable snippet or a failed `sssctl` check also turns causes into possible causes, and account- or session-stage messages are never taken as proof that a password was checked. The assessment shows which of the two usual causes applies, whether login failed before the VPN connected in each boot, and whether SSSD stayed unreachable after the VPN came up, which points at DNS over the VPN. Configuration problems come first in the assessment, backed by `sssctl config-check` when it is installed; while the configuration is invalid, no judgement relies on `sssd.conf`. Use `--days N` to widen or narrow the window. SSSD log files are searched for the phrases the patterns need with ripgrep when it is installed (gzip-rotated files included), else grep, so only matching lines are parsed, and a file over 64 MiB shows its progress on a terminal. SSSD's default `debug_level` logs only serious failures, so if it finds little, run `sudo sssctl debug-level 6`, reproduce the login, and run it again. Examples hide values of settings named like passwords or secrets, but do include user and host names.

`--purge` asks for confirmation, then moves the SSSD cache to `/var/lib/sss/dotconfig-backup/<timestamp>/` instead of deleting it. After a purge, the next domain login must reach a domain controller, so connect the VPN first. To undo, stop SSSD, move the files back into `/var/lib/sss/db` and `/var/lib/sss/mc`, and start it again.

### Machine health on Ubuntu

`dotconfig machine status` reports what is broken on an Ubuntu 26.04 machine and why, and how long boot and login took:

```sh
dotconfig machine status              # unprivileged; root-only checks are listed as not checked
dotconfig machine status --sudo       # everything, through sudo
dotconfig machine status --boot -1    # the journal of the previous boot, e.g. after a freeze
dotconfig machine status --sudo --user alice@corp.example   # another account: home, sessions, installation, proxy
dotconfig machine status --probe github.com --probe pypi.org:443   # DNS, TCP, proxy and TLS, step by step
dotconfig machine status --sudo --probe-domain   # also find the domain controllers through the current DNS
```

It never changes anything. Each finding is an `ok`, `info`, `warning`, `not checked` or `check failed` line, followed by quoted log lines (`--examples N` for more). `not checked` is an expected limit: the check needs `--sudo`, or its tool is not installed. `check failed` means a diagnostic that should work did not (it exited with an error or timed out, including the delegated `dotconfig creds` checks, bounded at 300 s), so that part of the machine was not assessed. The summary and exit status keep the three outcomes apart: 1 when problems were found, 3 when nothing wrong was found but the assessment is incomplete, and 0 when the machine is healthy within the checked scope. Sections:

- **System.** `systemctl is-system-running`, decoded kernel taint flags, a pending reboot and the packages that need it, and whether the previous boot shut down cleanly or ended in a crash, freeze, power loss or failed suspend.
- **Account and session.** The inspected account (`--user NAME`, else the one that ran the command, also under `sudo`) as NSS resolves it: uid, home, shell and groups; whether the home exists, is owned by the account and is reachable and writable, ACLs included; each `loginctl` session with its type, class and state; the runtime directory (owner, mode 700), the user bus and the user manager; and `XDG_*_HOME` overrides in the user manager that hide the files dotconfig installs. Another account needs `--sudo`; without it these checks are listed as not checked.
- **Boot and login timing.** Firmware, loader, kernel, initrd and userspace time and the slowest units. For each graphical or console login, from the journal: when the login screen appeared, when the password was accepted, how long the user manager and the desktop session took after that, failed password attempts before it, and the slowest user units when the login took over 30 seconds.
- **Services.** Failed system and user units with the reason (result, exit status, restarts) and their last log lines. With `--sudo`, the user units of every running user manager (logged-in and lingering accounts, from `loginctl`) are checked, each with that account's own log lines; without it, only yours. Also units with a bad unit file or a deleted one; units referenced but not installed; and services restarted during this boot.
- **Expected services, timers and mounts.** What should be running even when nothing has failed, from the machine role and host type in the account's chezmoi data and the features in use (SSSD, the dotconfig proxy): time sync (timesyncd or chrony), NetworkManager and the display manager on laptops and desktops, SSH on servers (`ssh.socket` or `ssh.service`), `sssd` where it is configured, the local proxy when the dotconfig proxy is on (proxydetox as a user or system service, Px or cntlm), and the maintenance timers (package refresh and upgrades, `fstrim`, `logrotate`, temporary-file cleanup, `e2scrub`). A built-in expectation applies only where the unit is installed, and alternatives count as one capability: it is reported only when none of them provides it. It reports units that are masked, disabled (unless something else starts them), skipped because a start condition failed, or not running, and timers that are not running, never ran, or are overdue once the machine has been up a while. A oneshot that finished is not reported as inactive, nor is a unit whose socket, path or timer is live; when that source is stopped or masked, the report names it. Mounts from `/etc/fstab` (not `noauto`), from `/etc/auto.master` when they hold the account's home, and declared ones must be mounted; a missing one says when its directory is writable, because files then land on the parent filesystem. Add your own in `/etc/dotconfig/machine-expect` or `~/.config/dotconfig/machine-expect`, one per line: `require [--user] UNIT [max-age=7d]`, `ignore UNIT`, `mount PATH`, `ignore-mount PATH`, and `offline-ok DOMAIN` (below).
- **Journal errors.** Error-priority messages grouped by program with counts and examples, coredumps, and Apport reports in `/var/crash`.
- **Kernel.** OOM kills, unsigned modules refused under Secure Boot, disk I/O, filesystem, NVMe and SATA errors, oopses and stack traces, hung tasks, GPU errors, thermal throttling, machine checks, firmware load failures, segfaults, AppArmor denials, USB enumeration failures and ACPI firmware noise. Other kernel errors are grouped and quoted.
- **Storage and memory.** Filesystems with less than 20% of space or inodes free, including the in-memory `/run`, `/run/user/UID`, `/dev/shm` and `/tmp`, a read-only `/`, `/home`, `/var` or `/boot`, and disk quotas of the invoking account, NFS homes included. With `--sudo`, SMART health and the indicators that fail before it: NVMe critical warnings, endurance used, spare capacity and media errors, and SATA reallocated, pending and uncorrectable sectors. Also available memory, swap use, memory pressure, and systemd-oomd kills.
- **Load and limits.** CPU and I/O pressure (time tasks spent waiting, not utilization), units that hit their own cgroup memory or task limit or lost processes to the OOM killer (each cgroup counted once, from `memory.events.local` where the kernel has it), and a nearly full kernel file or process table.
- **Network and time.** NetworkManager state and connectivity, an active VPN, the default route, DNS servers, and NTP synchronization, which Kerberos needs.
- **Domain login.** Whether `sssd` runs. With `--sudo`, the output of `dotconfig creds status` and `dotconfig creds check-logs` for the days since boot is included.
- **Domain login of the inspected account.** Whether SSSD serves it (`getent -s sss`) and resolves more than its primary group. With `--sudo`: whether SSSD is online for each domain. Offline is a warning: with hypotheses when a connected network (Wi-Fi, wired or VPN) routes the domain's DNS or its controllers are discoverable, and with the next check otherwise, since being away from the domain network looks the same as losing it. Where offline is normal, such as a laptop used at home, `offline-ok DOMAIN` in `machine-expect` records that; and whether the account is authorized to log in now (`sssctl user-checks -a acct`, which never asks for a password; no verdict counts as a failed check). From the journal, the last login through each PAM service is split into authentication, authorization and session setup, with the PAM code explained, so an access rule refusing the account is not mistaken for a wrong password. Events are tied to their login by the process that ran them; a session failure that names neither account nor process is shown as possibly related, never as this login's. `--probe-domain` also looks up the `_ldap` and `_kerberos` SRV records and names the link whose DNS answered.
- **Proxy and TLS.** The dotconfig proxy setting against each environment the account's programs inherit, naming which one: this shell (unprivileged runs only), the user manager, and `/etc/environment`. It reports conflicting upper and lower case variables, a proxy other than the configured one, a proxy left set while dotconfig proxy is off, missing or unreadable CA files in `SSL_CERT_FILE` and similar variables, and a local proxy that does not listen. Each `--probe HOST[:PORT]` is tried once per distinct route those environments give (environments with the same proxy, `no_proxy` and trust settings share one attempt, and the dotconfig proxy setting gets its own when no environment uses it yet), labeled with the environments it stands for. The stages are bounded and named: DNS, TCP to the addresses that lookup returned, the proxy `CONNECT` (with the meaning of 407, 403 and 502), and a TLS handshake with verification on. Verification trusts that environment's `SSL_CERT_FILE` and `SSL_CERT_DIR` as the account can read them, else OpenSSL's built-in locations, never the environment of the report itself; tool-specific bundles such as `CURL_CA_BUNDLE` are named but not exercised. Proxy credentials are never printed.
- **Installation.** For the inspected account: dotconfig-managed files owned by another account or in a directory the account cannot write (so `dotconfig apply` fails), managed files not applied yet, broken symlinks in `~/.local/bin` and the dotconfig and Zsh configuration, private files readable by others, files in the account's own checkout owned by another account (often after `sudo git`; the checkout is the one its installed `dotconfig` command was rendered from, else chezmoi's `sourceDir`, else `~/.local/share/chezmoi`), and insecure Zsh completion directories, checked as that account.
- **Packages and security.** `dpkg --audit`, pending and security updates, held packages, no successful APT refresh for a week (from the `apt.systemd.daily` stamps, not the lists' own dates), failed daily refreshes, repositories whose metadata expired (`Valid-Until`) or has not changed for 30 days, unattended upgrades not run for three days (both only once the machine has been up a day), DKMS modules not built for an installed kernel, a `/boot` too small for the next kernel, failed snap changes and snap warnings, Secure Boot, AppArmor, the last APT run and the journal size. With `--sudo`, also AppArmor profile modes, `ufw` state and unattended-upgrades errors.
- **Hardware.** Battery charge, wear against design capacity and cycle count, and thermal zones at 90 °C or more.

Without `--sudo`, an account outside the `adm` group sees only its own journal, so boot timing, the login timeline, system errors and the kernel log need `--sudo` or `sudo usermod -aG adm $USER`. Ubuntu adds the first local user to `adm`, but not domain users. Quoted log lines hide values of settings named like passwords, secrets or tokens, but can include user and host names.

## Bootstrap

Clone the repository, then run:

```sh
bash install.sh
```

The installation flow is:

1. **Prepare downloads and tools.** If your network needs the local proxy, enable it first. The installer adds missing checksum-verified chezmoi and mise binaries to your account.
2. **Install system packages.** APT on Ubuntu or Homebrew on macOS supplies the shared command-line tools. This is where system setup may request sudo.
3. **Choose your profile and deploy configuration.** Select `personal` or `work`, then `laptop`, `desktop`, or `server`. Chezmoi installs the managed Zsh and Vim files; review any overwrite prompts for existing files.
4. **Set up languages and editor plugins.** Mise installs pinned Node.js, Go, and Python versions. Oh My Zsh, Vim plugins, and CoC extensions converge to the repository pins. Downloads can take a while.
5. **Select Zsh and verify.** The installer optionally changes your login shell, which may request your account password. Open a new terminal and run `dotconfig doctor`. Put machine-specific settings in `~/.zshrc.local` or use `dotconfig private` for role-specific settings.

Use `bash install.sh --help` to skip system packages, Vim plugins, or the login-shell change. Existing private overrides and previous backups, such as `.zshrc.pre-dotconfig`, remain unmanaged.

### Installation progress and diagnostics

Every installation prints the current stage. For platform details, selected chezmoi/mise paths, skip choices, and stage timings, use:

```sh
bash install.sh --verbose
bash install.sh --user alice --verbose
bash scripts/migrate-legacy.sh --apply --verbose
```

Verbose mode adds installer diagnostics without shell tracing or environment dumps. Tools retain their usual output and interactive prompts. A final `SUCCESS` message appears only when all requested installation steps finish; skipped steps are reported separately. It does not mean skipped components were installed or that every existing tool matches the current pins. Open a new Zsh session and run `dotconfig doctor` to check the resulting machine.

On Ubuntu/Debian, a failed APT refresh produces a warning and installation is attempted using cached package lists. If APT installation itself returns an error, dotconfig verifies that every baseline package is fully installed and that `dpkg --audit` is clean before continuing. Missing or partially configured packages, an audit error, or audit findings still stop installation. A successful dotconfig installation after these warnings means the required packages are available; it does not guarantee fresh package lists or completed upgrades. Review the original APT errors and repair failing repositories or hooks separately. Run `bash packages/install.sh --check` to check baseline presence and `dpkg --audit` to inspect incomplete package state.

On failure, the installer reports the stage, exit code, and elapsed time, then exits with that same code. Review the preceding tool error for the cause. For migration, follow the backup markers and recovery instructions in the migration guide. For `--user`, a failure after checkout creation leaves the target checkout in place: use `--user USER --resume` as described below; any failed system package or login-shell step still needs administrator attention.

### Migrate an older installation

For a machine configured by the installer at `b967ec9`, use a separate current checkout and run:

```sh
bash scripts/migrate-legacy.sh          # preview files and backup location
bash scripts/migrate-legacy.sh --apply # back up old files, then install
```

The migration saves old files, symlinks, and their readable contents before replacing the legacy configuration. It preserves private overrides and existing plugin directories. See [the migration guide](docs/legacy-migration.md) for preparation, skip options, customization review, and recovery.

### Install for an account without sudo

To compare curl and wget when troubleshooting bootstrap downloads, use `bash install.sh --downloader wget`. Curl remains the default; there is no automatic fallback. This selects the downloader for chezmoi and mise binaries (and the Homebrew installer on macOS), retaining pinned archive checksum verification and TLS certificate checks. It does not change downloads performed internally by mise, Git, Vim or package managers, nor does it fix missing proxy settings. Wget may read its own wgetrc configuration, so a successful comparison does not by itself identify a TLS interception problem.

The switch also works across accounts and with resume:

```sh
bash install.sh --user 'user@example.com' --resume --skip-shell-change --downloader wget
```

Wget must already be available to the target user for cross-account installation; install it as the administrator if needed. Without `--user`, Linux bootstrap can install the selected downloader when missing. For direct bootstrap-helper invocations, use `DOTCONFIG_DOWNLOADER=wget bash scripts/install-bootstrap-tool.sh chezmoi` (or `mise`).

For `--resume`, the target checkout must also contain this downloader option: resume deliberately does not update its code. After this change is merged, update an existing clean target checkout to the reviewed default branch before retrying with the new flag.

Add `--verbose` to print the exact release URL, downloader path/version, effective UID, and whether proxy/CA environment variables are set in the downloading process. Curl also reports HTTP status, remote IP, redirects, and DNS/connect/TLS/total timings, including on failure. Environment values are omitted. This does not enable raw HTTP tracing, which can expose credentials. Wget retains its normal connection and TLS error output. For the bootstrap helper or `dotconfig bootstrap`, use `DOTCONFIG_DOWNLOAD_VERBOSE=true` (and optionally `DOTCONFIG_DOWNLOADER=wget`). These diagnostics cover bootstrap downloads; mise's runtime downloads have their own logging.

An OpenSSL unexpected EOF or GnuTLS “TLS connection was non-properly terminated” means the TLS connection ended unexpectedly; it does not identify which endpoint or intermediary closed it. Compare the exact release asset URL under the same account/environment, including the redirect hosts, and correlate failures with proxy and endpoint security logs. An interactive wget request to a different URL or with a different environment is not an equivalent test.

On Ubuntu/Debian, run this from an administrator account with sudo access:

```sh
bash install.sh --user alice
```

The target account must already exist and have a writable home directory. Use a clean, committed checkout whose HEAD is an ancestor of the fetched default branch (`git fetch origin` first); feature-only commits are refused so the target can fast-forward future updates. The administrator installs the shared APT baseline and changes Alice's login shell to a system zsh listed in `/etc/shells`; Alice does not need sudo. The installer transfers the committed checkout to `~alice/.local/share/dotconfig` and runs all home-directory setup as Alice: chezmoi profile prompts, dotfiles, pinned bootstrap tools, runtimes, Oh My Zsh, and Vim plugins. The checkout retains the original Git remote for later updates.

SSSD/domain accounts can be selected by their qualified login name, even when NSS returns a different canonical name. The installer verifies that both resolve to the same UID and uses the home directory returned by `getent passwd`; it does not construct a path from the login name. For example, `user@example.com` can use `/home/user`:

```sh
bash install.sh --user 'user@example.com' --skip-shell-change
```

Use `--skip-shell-change` when the domain or SSSD configuration manages the login shell; the local `chsh` command may not be able to change it. To retry this installation, add `--resume` to the same command. The target environment uses the canonical NSS account name for `USER` and `LOGNAME`, while sudo continues to select the requested login name.

User setup uses Alice's HOME and a clean environment, preserving an explicit list of network settings from the administrator's effective session even before dotconfig proxy mode is configured. This includes `http_proxy`, `https_proxy`, `all_proxy`, and `no_proxy` in both cases, plus `NODE_USE_ENV_PROXY`. Case variants and explicitly empty values remain distinct. Inherited proxy endpoints may use HTTP, HTTPS, or SOCKS; URLs containing credentials are rejected without displaying their values. A managed administrator proxy profile still requires credential-free loopback HTTP endpoints. The administrator's explicit proxy `off` clears session proxy settings before transfer.

Custom trust settings also pass through: `CURL_CA_BUNDLE`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `GIT_SSL_CAPATH`, and `NODE_EXTRA_CA_CERTS`. These must be absolute paths readable by the target account; certificates are not copied and file permissions are not changed. Client-specific configuration files and other administrator variables remain outside this transfer. Alice's own proxy profile, if present, takes precedence; explicit `off` clears inherited proxy variables while preserving CA settings. This does not persist a new proxy or CA profile for Alice. Downloads through an inherited Kerberos-authenticated listener use the administrator's corporate identity, including when installing for someone else's account.

Settings from `/etc/environment` must already be loaded into the administrator's calling session; the installer does not source that file or run the target's interactive shell startup files. If you changed it after login, start a new login session or explicitly export the required settings before running `bash install.sh --user USER`. With `--verbose`, download diagnostics show whether supported proxy/CA variables reached the target, omitting their values. Settings used only by an existing target user's interactive shell still need to be made available to the installer or configured in that target's dotconfig proxy profile.

The same skip options apply. With `--skip-packages`, curl, Git, and the other required system tools must already be installed. An existing target checkout is refused on first installation. To retry after a failure, run from the administrator account:

```sh
bash install.sh --user alice --resume --verbose
```

Resume verifies a clean target checkout, the same origin remote, and a target revision contained in the administrator's fetched default branch before changing anything. It reuses that checkout without resetting, deleting, or updating it, and retries package setup, user setup, and the login-shell change. Already installed tools/runtimes are reused by their installers. Add the same skip options if desired; `--resume` requires `--user`. A missing, dirty, mismatched, or unreviewed checkout is refused. Proxy settings pass through the same restricted mechanism as first installation, so a target proxy mode of `off` still clears inherited settings.

For subsequent user-only setup, you can also run `sudo -H -u alice bash ~alice/.local/share/dotconfig/install.sh --skip-packages --skip-shell-change`. System package maintenance still belongs to the administrator. Cross-account installation currently rejects macOS, whose Homebrew ownership needs a separate setup.

Bootstrap trust is recorded in `versions/bootstrap-tools`. The status and doctor commands flag installed chezmoi or mise versions that differ from those pins, including binaries supplied by a native package manager. Merging a bootstrap refresh does not replace an existing executable. After reviewing the new pin, run `dotconfig bootstrap` to install the exact chezmoi and mise releases into `~/.local/bin` and verify the versions now selected on `PATH`. This is explicit and separate from `dotconfig sync`. On macOS the package baseline no longer installs duplicate chezmoi or mise formulae. The pinned user-local binaries take precedence in the managed Zsh configuration. Existing Homebrew copies are not removed automatically. Fresh installs select verified binaries before the package step. An existing chezmoi or mise is left in place by `install.sh`; use `dotconfig bootstrap` to converge it explicitly. Homebrew is installed only when the native package baseline is requested. On both target platforms, the exact mise and chezmoi release archives are checked against SHA-256 values committed in the manifest before extraction. A missing Homebrew installation still uses an installer fetched from an immutable commit. That script is downloaded to a temporary file rather than streamed into a shell, and repository validation rejects new `curl | sh` patterns.

## Normal update workflow

The installer deploys a `dotconfig` maintenance command into `~/.local/bin`.

Oh My Zsh installation prevents group/other-writable completion code, including when the caller uses a permissive umask or Git shared-repository setting. Re-running `dotconfig shell` also removes group/other write permission from current-user-owned managed Oh My Zsh files and directories. It preserves stricter umasks, executable bits, and ownership; it skips Git metadata, the custom plugin tree, and symlinks. A symlinked installation root is refused.

Installation, `dotconfig status`, and `dotconfig doctor` run Zsh's `compaudit` on the standard completion paths plus dotconfig's configured Oh My Zsh plugins and custom overrides, without loading interactive startup files or plugin code. Remaining insecure paths make the check fail and are printed for inspection. For an existing installation, update the checkout to this change, then run `dotconfig shell` (or `bash scripts/install-oh-my-zsh.sh` from the checkout if configuration was not deployed). If the audit still fails, inspect the reported paths and parents with `ls -ld` and, on Linux, `namei -l`; fix only those whose ownership and intended use you have verified. Shared system paths and custom plugins need a targeted administrator or owner decision. Restart Zsh after repair. Keep `ZSH_DISABLE_COMPFIX` unset so the shell continues checking completion security.

Each account owns its checkout, reviewed revision, dotfiles, runtimes, and editor dependencies. Run `dotconfig sync` separately as each installed user, including a domain user whose NSS home is `/home/user`. No sudo is required for these per-user updates. From an administrator's terminal you can run:

```sh
sudo -iu localuser -- /bin/bash -c 'exec "$HOME/.local/bin/dotconfig" sync'
sudo -iu 'user@example.com' -- /bin/bash -c 'exec "$HOME/.local/bin/dotconfig" sync'
```

Review and confirm each account's changes at its prompt; keep terminal input attached. Each command uses that account's deployed source path and network configuration. These commands require an already completed installation; for a failed first installation, use `install.sh --user USER --resume` instead. Shared native packages need updating only once by the administrator with `dotconfig packages`. Pinned bootstrap binaries remain a separate `dotconfig bootstrap` operation per user. There is no automatic machine-wide fan-out: updating one user's checkout does not update another's, and `--resume` does not fetch new code.

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
