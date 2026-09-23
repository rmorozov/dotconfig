#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
snapshot="${1:-$REPO_ROOT/home/dot_vimrc}"
manifest="${VIM_PLUG_MANIFEST:-$REPO_ROOT/versions/vim-plug}"
read -r revision blob < "$manifest"
[[ "$revision" =~ ^[0-9a-f]{40}$ && "$blob" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Invalid vim-plug pin' >&2
    exit 1
}
python3 - "$snapshot" "$revision" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text()
pattern = r"https://raw.githubusercontent.com/junegunn/vim-plug/[^/\s\"']+/plug.vim"
new_content, count = re.subn(pattern, "https://raw.githubusercontent.com/junegunn/vim-plug/" + sys.argv[2] + "/plug.vim", content)
if count != 1:
    raise SystemExit(f"Expected one vim-plug bootstrap URL, found {count}")
path.write_text(new_content)
PY
