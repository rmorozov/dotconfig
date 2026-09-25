#!/usr/bin/env python3
"""Exercise comparable drift and intentional profile differences."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile


script = Path(__file__).with_name("compare-reports.py")
base = {
    "schema_version": 1,
    "platform": {"os": "Linux", "architecture": "x86_64"},
    "profile": {"role": "work", "host_type": "laptop"},
    "repository": {"commit": "a" * 40, "reviewed_commit": "a" * 40,
                   "working_tree_clean": True},
    "dotfiles": {"state": "ok"}, "packages": {"state": "ok"},
    "bootstrap": {"mise": {"expected": "1.2.3", "actual": "1.2.3", "state": "ok"}},
    "runtimes": {"node": {"expected": "24.1.0", "installed": True}},
    "oh_my_zsh": {"expected": "c" * 40, "actual": "c" * 40, "state": "ok"},
    "editor": {"vim_plug": {"revision": "d" * 40, "expected": "e" * 40,
                            "actual": "e" * 40, "state": "ok"},
               "vim_plugins": {"example": {"expected": "f" * 40,
                                          "actual": "f" * 40, "state": "ok"}},
               "coc_extensions": {}},
}

with tempfile.TemporaryDirectory() as root:
    first, second = Path(root) / "a.json", Path(root) / "b.json"
    first.write_text(json.dumps(base))
    other = copy.deepcopy(base)
    other["platform"]["os"] = "Darwin"
    other["profile"]["role"] = "personal"
    second.write_text(json.dumps(other))
    result = subprocess.run([sys.executable, str(script), str(first), str(second)],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert "State differences: 0" in result.stdout

    other["repository"]["commit"] = "b" * 40
    other["runtimes"]["node"]["installed"] = False
    other["editor"]["vim_plugins"]["example"]["actual"] = None
    other["editor"]["vim_plugins"]["example"]["state"] = "missing"
    second.write_text(json.dumps(other))
    result = subprocess.run([sys.executable, str(script), str(first), str(second)],
                            capture_output=True, text=True)
    assert result.returncode == 1, result.stderr
    assert "State differences: 4" in result.stdout
    for field in ("repository.commit", "runtimes.node.installed",
                  "editor.vim_plugins.example.actual", "editor.vim_plugins.example.state"):
        assert field in result.stdout

    second.write_text('{"schema_version": 99}')
    result = subprocess.run([sys.executable, str(script), str(first), str(second)],
                            capture_output=True, text=True)
    assert result.returncode == 2
    assert "schema_version 1" in result.stderr

print("Report comparison passed")
