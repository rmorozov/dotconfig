#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT

HOME="$test_home" python3 "$repo_root/scripts/report.py" \
    --role work --host-type laptop --json > "$test_home/report.json"

python3 - "$test_home/report.json" "$test_home" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report["schema_version"] == 1
assert report["profile"] == {"role": "work", "host_type": "laptop"}
assert report["repository"]["commit"]
assert report["editor"]["vim_plugins"]
assert report["editor"]["coc_extensions"]
assert report["editor"]["vim_plug"]["state"] == "missing"
assert report["oh_my_zsh"]["state"] == "missing"
assert sys.argv[2] not in json.dumps(report)
PY
