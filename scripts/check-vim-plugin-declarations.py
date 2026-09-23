#!/usr/bin/env python3
"""Check that every Git-backed Plug declaration has a committed pin."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
paths = [Path(value) for value in sys.argv[1:]]
if paths and len(paths) != 3:
    raise SystemExit("Usage: check-vim-plugin-declarations.py [vimrc bundles manifest]")
vimrc, bundles, manifest = paths or [
    ROOT / "home/dot_vimrc",
    ROOT / "home/dot_vimrc.local.bundles",
    ROOT / "versions/vim-plugins",
]

plug_pattern = re.compile(r"""(?:^|\|)\s*Plug\s+(['"])(.*?)\1""", re.MULTILINE)
slug_pattern = re.compile(r"[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+)\Z")
declared: dict[str, str] = {}
errors: list[str] = []
for source in (vimrc, bundles):
    for match in plug_pattern.finditer(source.read_text()):
        repository = match.group(2)
        if repository.startswith(("/", "~/")):
            continue  # A local plugin directory, such as Homebrew's fzf.
        slug = slug_pattern.fullmatch(repository)
        if slug is None:
            errors.append(f"Unsupported Plug declaration: {repository} ({source})")
            continue
        name = slug.group(1)
        previous = declared.setdefault(name, repository)
        if previous != repository:
            errors.append(f"Conflicting Plug repositories for {name}: {previous}, {repository}")

pinned: set[str] = set()
for line in manifest.read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    fields = line.split()
    if len(fields) != 4:
        errors.append(f"Invalid Vim plugin manifest row: {line}")
        continue
    name = fields[0]
    if name in pinned:
        errors.append(f"Duplicate Vim plugin pin: {name}")
    pinned.add(name)

for name in sorted(declared.keys() - pinned):
    errors.append(f"Declared Vim plugin has no pin: {name}")
for name in sorted(pinned - declared.keys()):
    errors.append(f"Pinned Vim plugin has no declaration: {name}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
print(f"Vim declarations match {len(pinned)} committed plugin pins.")
