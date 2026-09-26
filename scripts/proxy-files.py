#!/usr/bin/env python3
"""Converge only dotconfig-owned proxy entries; never overwrite other settings."""

import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

START = "# dotconfig proxy begin"
END = "# dotconfig proxy end"
ENV_KEYS = ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY")
ENV_PATTERN = re.compile(r"^\s*(?:export\s+)?(?:http|https|ftp|all|no)_proxy\s*=", re.I | re.M)
APT_PATTERN = re.compile(r"Acquire\s*::\s*(?:http|https|ftp)\s*::\s*Proxy(?:-Auto-Detect)?\b|\bProxy-Auto-Detect\b", re.I)
NPM_PATTERN = re.compile(r"^\s*(?:proxy|https-proxy|noproxy)\s*=", re.I | re.M)


def read(path):
    if path.is_symlink():
        raise ValueError(f"refusing symlink: {path}")
    return path.read_text() if path.exists() else ""


def owned(text):
    if (START in text) != (END in text) or text.count(START) > 1 or text.count(END) > 1:
        raise ValueError("incomplete or duplicate dotconfig proxy markers")
    return START in text


def strip_block(text):
    if not owned(text):
        return text
    return re.sub(r"(?m)^# dotconfig proxy begin\n.*?^# dotconfig proxy end\n?", "", text, count=1, flags=re.S)


def atomic_write(path, content, *, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        mode = path.stat().st_mode & 0o777
    fd, tmp_name = tempfile.mkstemp(prefix=".dotconfig-proxy-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as out:
            out.write(content)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def update(path, action, generated, pattern, label, *, delete_owned=False):
    text = read(path)
    has_block = owned(text)
    rest = strip_block(text)
    if action == "on" and has_block and pattern.search(rest):
        print(f"{label}: external proxy settings found; leaving file unchanged")
        return
    if action == "off":
        if not has_block:
            return
        if delete_owned and not rest.strip():
            path.unlink()
        else:
            atomic_write(path, rest)
        print(f"{label}: removed dotconfig settings")
    elif not has_block and pattern.search(text):
        print(f"{label}: existing proxy settings found; leaving file unchanged")
    else:
        result = rest + ("\n" if rest and not rest.endswith("\n") else "") + generated
        if result != text:
            atomic_write(path, result)
            print(f"{label}: installed dotconfig settings")


def validated_values(data):
    values = {k: data.get(k, "") for k in ENV_KEYS}
    for k, value in values.items():
        if not isinstance(value, str) or any(c in value for c in "\r\n\0"):
            raise ValueError(f"invalid {k} value")
    for key in ("http_proxy", "https_proxy"):
        parts = urlsplit(values[key])
        if parts.scheme != "http" or parts.hostname not in ("localhost", "127.0.0.1", "::1") or parts.username or parts.password or not parts.port or parts.path or parts.query or parts.fragment:
            raise ValueError(f"{key} must be a credential-free local HTTP proxy with an explicit port")
    return values


def manage_system(root, action, values):
    environment = root / "etc/environment"
    env_lines = "".join(f"{k}={json.dumps(values[k])}\n" for k in ENV_KEYS if values.get(k))
    update(environment, action, f"{START}\n{env_lines}{END}\n", ENV_PATTERN, "/etc/environment", delete_owned=True)

    apt_dir = root / "etc/apt/apt.conf.d"
    target = apt_dir / "10-proxy.conf"
    if action == "on":
        if not apt_dir.is_dir():
            print("APT: configuration directory missing; skipping")
            return
        for file in apt_dir.iterdir():
            if file.is_symlink():
                print("APT: linked configuration found; leaving directory unchanged")
                return
            if not file.is_file():
                continue
            contents = read(file)
            if file == target and owned(contents):
                contents = strip_block(contents)
            if APT_PATTERN.search(contents):
                print("APT: existing proxy settings found; leaving directory unchanged")
                return
    lines = "".join(f'Acquire::{proto}::Proxy "{values[proto + "_proxy"]}";\n' for proto in ("http", "https")) if action == "on" else ""
    update(target, action, f"{START}\n{lines}{END}\n", APT_PATTERN, "APT", delete_owned=True)


def manage_user(home, action, values):
    npmrc = home / ".npmrc"
    lines = f"proxy={values['http_proxy']}\nhttps-proxy={values['https_proxy']}\n" if action == "on" else ""
    if action == "on" and values["no_proxy"]:
        lines += f"noproxy={values['no_proxy']}\n"
    update(npmrc, action, f"{START}\n{lines}{END}\n", NPM_PATTERN, "npm", delete_owned=True)


def main():
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in ("system", "user", "payload") or sys.argv[2] not in ("on", "off"):
        raise ValueError("Usage: proxy-files.py {system|user|payload} {on|off} [test-root]")
    scope, action = sys.argv[1:3]
    if scope == "payload":
        print(json.dumps({k: os.environ.get(k, "") for k in ENV_KEYS}))
        return
    values = validated_values(json.load(sys.stdin)) if action == "on" else {}
    root = Path(sys.argv[3]) if len(sys.argv) == 4 else Path("/")
    if scope == "system":
        manage_system(root, action, values)
    else:
        manage_user(root if len(sys.argv) == 4 else Path.home(), action, values)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"proxy configuration: {exc}", file=sys.stderr)
        sys.exit(1)
