# Network clients and the proxy switch

This inventory records which clients used by bootstrap, maintenance and interactive development follow the variables exported by `dotconfig proxy on`. It is based on each client's documented behavior. Rows marked *needs machine check* still have to be confirmed against a real Kerberos-aware listener.

The loader exports `http_proxy`, `https_proxy`, `no_proxy` and their uppercase forms, unsets `ALL_PROXY`, and sets `NODE_USE_ENV_PROXY=1`. Exporting both cases matters: several clients read only one of them.

| Client | Used by | Proxy variables read | `no_proxy` matching | Extra configuration from dotconfig |
| --- | --- | --- | --- | --- |
| curl | `install.sh`, Homebrew installer, refresh scripts | lowercase `http_proxy`; `https_proxy` or `HTTPS_PROXY`; ignores uppercase `HTTP_PROXY` by design | host and domain suffix; CIDR since curl 7.86 | none needed |
| Git over HTTPS | Oh My Zsh, vim-plug, `dotconfig update` | same as curl (libcurl) | same as curl | none; an existing `http.proxy` in Git config takes precedence |
| Git over SSH | `git@host:` remotes only | none | none | not covered; needs an SSH `ProxyCommand` (see below) |
| Homebrew | macOS package baseline | passes `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy` to curl and Git | same as curl | none needed |
| APT | Ubuntu package baseline | lowercase `http_proxy` and `https_proxy`, only when no `Acquire::*::Proxy` is configured | suffix match on `no_proxy`, only in the environment mode | `10-proxy.conf` with exact-host `DIRECT` entries |
| mise | runtimes, bootstrap | both cases (Rust `reqwest`) | suffix and CIDR | none needed |
| chezmoi | bootstrap, apply | both cases (Go `net/http`) | suffix and CIDR | none needed |
| npm | CoC extensions, Node tooling | `proxy` and `https-proxy` from `.npmrc`; falls back to the variables | `noproxy`: suffix only | marked block in `~/.npmrc` |
| Node.js built-in `fetch` | CoC language servers, scripts | ignored unless `NODE_USE_ENV_PROXY=1` (Node 24) | suffix | `NODE_USE_ENV_PROXY=1` exported by the loader |
| coc.nvim downloads | CoC extension and language server installs | `http.proxy` in `coc-settings.json`, else the variables | suffix | none; *needs machine check* |
| pip | Python packages under mise | both cases (`requests`) | suffix and CIDR | none needed |
| Go modules | `go get`, `go install` | both cases (Go `net/http`) | suffix and CIDR | none; private modules still need `GOPRIVATE` |
| wget | ad hoc | lowercase only | suffix | none needed |

## Known gaps

- **APT bypasses.** Once `Acquire::http::Proxy` is set, APT ignores `no_proxy` entirely. dotconfig now adds `Acquire::http(s)::Proxy::<host> "DIRECT";` for each exact host in the bypass list. Domain suffixes (`.corp.example`) and CIDR ranges cannot be expressed this way; list internal mirrors by full host name.
- **CIDR entries.** curl before 7.86, npm, APT and wget ignore CIDR ranges in `no_proxy`. Prefer host names for anything those tools reach.
- **SSH remotes.** An HTTP proxy does not carry SSH. For `git@` remotes behind a proxy, add a host entry to `~/.ssh/config` with `ProxyCommand nc -X connect -x 127.0.0.1:3128 %h %p` in a private file, or use HTTPS remotes.
- **Desktop and system services.** `/etc/environment` reaches new login sessions only. Snap (`snap set system proxy.https=...`), Docker and other daemons read their own settings and are not touched.

## Failure behavior

With the switch on and no listener on `127.0.0.1:3128`, curl, Git and APT fail fast with "connection refused". When the listener runs but its Kerberos ticket has expired, Px and cntlm-gss answer `407 Proxy Authentication Required` or `502`, which curl reports as `CONNECT tunnel failed`. Neither case falls back to a direct connection. Run `kinit` or restart the listener, or use `dotconfig proxy off`. *Needs machine check* for each listener.
