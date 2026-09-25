#!/usr/bin/env python3
"""Read-only, portable snapshot of the reviewed dotconfig state."""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()


def run(*args):
    try:
        return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return None


def output(*args):
    result = run(*args)
    return result.stdout.strip() if result and result.returncode == 0 else None


def rows(path):
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            yield line.split()


def state(expected, actual):
    return {"expected": expected, "actual": actual,
            "state": "missing" if actual is None else
                     "ok" if actual == expected else "drift"}


def bootstrap():
    pins = dict(rows(ROOT / "versions/bootstrap-tools"))
    found = {}
    for name in ("chezmoi", "mise"):
        version = output(name, "--version")
        pattern = (r"^chezmoi\s+version\s+v?(\d+\.\d+\.\d+)\b" if name == "chezmoi"
                   else r"^v?(\d+\.\d+\.\d+)\b")
        match = re.search(pattern, version or "")
        found[name] = state(pins[name], match.group(1) if match else None)
        if version is not None and match is None:
            found[name]["state"] = "unknown"
    return found


def runtimes():
    pins = {}
    in_tools = False
    for line in (ROOT / "home/dot_config/mise/config.toml").read_text().splitlines():
        if line.strip() == "[tools]":
            in_tools = True
            continue
        if line.lstrip().startswith("["):
            in_tools = False
        if in_tools:
            match = re.match(r'^\s*([\w-]+)\s*=\s*"([^"]+)"', line)
            if match:
                name, version = match.groups()
                pins[name] = {"expected": version,
                              "installed": output("mise", "where", f"{name}@{version}") is not None}
    return pins


def package_capabilities():
    capabilities = {}
    system = platform.system()
    for name, brew_name, ubuntu_name in rows(ROOT / "packages/packages.tsv"):
        package = brew_name if system == "Darwin" else ubuntu_name if system == "Linux" else "-"
        if package == "-":
            capabilities[name] = {"package": None, "installed": None, "version": None}
        elif system == "Darwin" and shutil.which("brew"):
            found = output("brew", "list", "--versions", "--formula", package)
            versions = found.split()[1:] if found and found.split()[0] == package else []
            capabilities[name] = {"package": package, "installed": bool(versions),
                                  "version": versions[-1] if versions else None}
        elif system == "Linux" and shutil.which("dpkg-query"):
            found = output("dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${Version}", package)
            status, _, version = (found or "").partition("\t")
            installed = status.startswith("ii ")
            capabilities[name] = {"package": package, "installed": installed,
                                  "version": version if installed else None}
        else:
            capabilities[name] = {"package": package, "installed": None, "version": None}
    return capabilities


def editor():
    vim_plug_revision, vim_plug_blob = next(rows(ROOT / "versions/vim-plug"))
    vim_plug_file = HOME / ".vim/autoload/plug.vim"
    plug_actual = output("git", "hash-object", str(vim_plug_file)) if vim_plug_file.is_file() else None
    locations = dict(rows(ROOT / "versions/vim-plugin-locations"))
    plugins = {}
    for name, _url, _ref, expected in rows(ROOT / "versions/vim-plugins"):
        location = HOME / locations.get(name, f".vim/plugged/{name}")
        actual = output("git", "-C", str(location), "rev-parse", "HEAD") if (location / ".git").exists() else None
        plugins[name] = state(expected, actual)
    coc_root = Path(os.environ.get("COC_EXTENSION_HOME", os.environ.get("COC_DATA_HOME",
        str(Path(os.environ.get("XDG_CONFIG_HOME", str(HOME / ".config"))) / "coc")) + "/extensions/node_modules"))
    extensions = {}
    for name, expected in rows(ROOT / "versions/coc-extensions"):
        metadata = coc_root / name / "package.json"
        actual = None
        if metadata.is_file():
            try:
                actual = json.loads(metadata.read_text()).get("version")
            except (OSError, ValueError):
                pass
        extensions[name] = state(expected, actual)
    return {"vim_plug": {"revision": vim_plug_revision, **state(vim_plug_blob, plug_actual)},
            "vim_plugins": plugins, "coc_extensions": extensions}


def report(role, host_type):
    head = output("git", "-C", str(ROOT), "rev-parse", "HEAD")
    reviewed = output("git", "-C", str(ROOT), "config", "--local", "--get", "dotconfig.reviewedHead")
    git_status = output("git", "-C", str(ROOT), "status", "--porcelain")
    diff = run("chezmoi", "--source", str(ROOT), "diff")
    packages = run("bash", str(ROOT / "packages/install.sh"), "--check")
    expected_shell = (ROOT / "versions/oh-my-zsh").read_text().strip()
    shell_dir = HOME / ".oh-my-zsh"
    actual_shell = output("git", "-C", str(shell_dir), "rev-parse", "HEAD") if (shell_dir / ".git").exists() else None
    if packages is None or (platform.system() == "Darwin" and not shutil.which("brew")) or (platform.system() == "Linux" and not shutil.which("apt-get")):
        package_state = "unknown"
    else:
        package_state = "ok" if packages.returncode == 0 else "drift"
    return {
        "schema_version": 1,
        "platform": {"os": platform.system(), "architecture": platform.machine()},
        "profile": {"role": role, "host_type": host_type},
        "repository": {"commit": head, "reviewed_commit": reviewed,
                       "working_tree_clean": git_status == "" if git_status is not None else None},
        "dotfiles": {"state": "unknown" if diff is None or diff.returncode != 0 else
                     "ok" if not diff.stdout else "drift"},
        "packages": {"state": package_state, "capabilities": package_capabilities()},
        "bootstrap": bootstrap(),
        "runtimes": runtimes(),
        "oh_my_zsh": state(expected_shell, actual_shell),
        "editor": editor(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--role", required=True)
    parser.add_argument("--host-type", required=True)
    args = parser.parse_args()
    data = report(args.role, args.host_type)
    if args.json:
        print(json.dumps(data, sort_keys=True, indent=2))
    else:
        print(f"Platform: {data['platform']['os']} {data['platform']['architecture']}")
        print(f"Profile: {args.role} / {args.host_type}")
        repo = data["repository"]
        print(f"Repository: {repo['commit']} ({'reviewed' if repo['commit'] == repo['reviewed_commit'] else 'review pending'})")
        print(f"Working tree: {'clean' if repo['working_tree_clean'] else 'changed or unknown'}")
        print(f"Dotfiles: {data['dotfiles']['state']}; packages: {data['packages']['state']}")
        missing_packages = [name for name, item in data["packages"]["capabilities"].items()
                            if item["installed"] is False]
        if missing_packages:
            print(f"Missing baseline capabilities: {', '.join(missing_packages)}")
        for section in ("bootstrap", "runtimes"):
            items = data[section]
            print(f"{section.title()}: " + ", ".join(f"{name}={item['state'] if 'state' in item else ('installed' if item['installed'] else 'missing')}"
                  for name, item in items.items()))
        print(f"Oh My Zsh: {data['oh_my_zsh']['state']}")
        for section in ("vim_plugins", "coc_extensions"):
            items = data["editor"][section]
            print(f"{section.replace('_', ' ').title()}: {sum(v['state'] == 'ok' for v in items.values())}/{len(items)} match")
        print(f"vim-plug: {data['editor']['vim_plug']['state']}")


if __name__ == "__main__":
    main()
