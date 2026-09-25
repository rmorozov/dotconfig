#!/usr/bin/env python3
"""Compare two version-1 dotconfig reports without sending them anywhere."""

import argparse
import json
from pathlib import Path
import sys

import report as local_report


def load(path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise ValueError(f"Cannot read report: {error}") from error
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError("Expected a dotconfig report with schema_version 1")
    required = ("platform", "profile", "repository", "dotfiles", "packages",
                "bootstrap", "runtimes", "oh_my_zsh", "editor")
    if any(not isinstance(data.get(name), dict) for name in required):
        raise ValueError("Incomplete dotconfig report")
    if any(not isinstance(data["editor"].get(name), dict)
           for name in ("vim_plug", "vim_plugins", "coc_extensions")):
        raise ValueError("Incomplete editor state in dotconfig report")
    return data


def fields(data):
    """Select comparable state; omit profile and OS, which may differ intentionally."""
    result = {}

    def add(prefix, entry, names):
        if not isinstance(entry, dict):
            return
        for name in names:
            result[f"{prefix}.{name}"] = entry.get(name)

    add("repository", data.get("repository"),
        ("commit", "reviewed_commit", "working_tree_clean"))
    for name in ("dotfiles", "packages"):
        add(name, data.get(name), ("state",))
    for category, attributes in (("bootstrap", ("expected", "actual", "state")),
                                 ("runtimes", ("expected", "installed"))):
        group = data.get(category)
        if isinstance(group, dict):
            for name, entry in group.items():
                add(f"{category}.{name}", entry, attributes)
    add("oh_my_zsh", data.get("oh_my_zsh"), ("expected", "actual", "state"))
    editor = data.get("editor")
    if isinstance(editor, dict):
        add("editor.vim_plug", editor.get("vim_plug"),
            ("revision", "expected", "actual", "state"))
        for category in ("vim_plugins", "coc_extensions"):
            group = editor.get(category)
            if isinstance(group, dict):
                for name, entry in group.items():
                    add(f"editor.{category}.{name}", entry,
                        ("expected", "actual", "state"))
    return result


def display(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True)


def compare(first, second):
    for key in ("platform", "profile"):
        print(f"{key.title()}: {display(first.get(key))} | {display(second.get(key))}")
    left, right = fields(first), fields(second)
    missing = object()
    differences = [(key, left.get(key, missing), right.get(key, missing))
                   for key in sorted(left.keys() | right.keys())
                   if left.get(key, missing) != right.get(key, missing)]
    print(f"State differences: {len(differences)}")
    for key, a, b in differences:
        print(f"{display(key)}: {display(a) if a is not missing else '<absent>'} | "
              f"{display(b) if b is not missing else '<absent>'}")
    return bool(differences)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", metavar="REPORT.json",
                        help="one saved report against this machine, or two saved reports")
    parser.add_argument("--role", help=argparse.SUPPRESS)
    parser.add_argument("--host-type", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if len(args.reports) not in (1, 2):
        parser.error("provide one or two report files")
    try:
        first = (local_report.report(args.role, args.host_type) if len(args.reports) == 1
                 else load(args.reports[0]))
        second = load(args.reports[-1])
    except ValueError as error:
        parser.error(str(error))
    return 1 if compare(first, second) else 0


if __name__ == "__main__":
    sys.exit(main())
