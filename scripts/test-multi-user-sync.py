#!/usr/bin/env python3
"""Exercise independent per-account updates without creating system accounts."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def git(repo, *args):
    return subprocess.check_output(
        ["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL, text=True
    ).strip()


def sync(command, home, login, bin_dir):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(HOME=str(home), USER=login, LOGNAME=login)
        os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]
        os.execv("/bin/bash", ["bash", str(command), "sync"])
    output = bytearray()
    try:
        os.write(fd, b"y\n")
        while True:
            if not select.select([fd], [], [], 20)[0]:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                raise AssertionError("Per-user sync timed out")
            try:
                chunk = os.read(fd, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
        _, status = os.waitpid(pid, 0)
        assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, output.decode()
        assert b"Accept these changes" in output, output.decode()
        assert b"Machine configuration is synchronized" in output, output.decode()
    finally:
        os.close(fd)


with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    remote, author = temp / "remote", temp / "author"
    remote.mkdir()
    git(remote, "init", "--bare", "--initial-branch=master")
    git(temp, "clone", str(remote), str(author))
    git(author, "config", "user.name", "Test")
    git(author, "config", "user.email", "test@example.invalid")
    (author / "home/dot_config/zsh").mkdir(parents=True)
    (author / "home/dot_config/zsh/proxy.zsh").write_text(
        (ROOT / "home/dot_config/zsh/proxy.zsh").read_text()
    )
    for script, operation in (
        ("packages/install.sh", "packages"),
        ("scripts/manage-runtime-versions.sh", "runtimes"),
        ("scripts/install-oh-my-zsh.sh", "shell"),
        ("scripts/converge-vim.sh", "vim"),
    ):
        path = author / script
        path.parent.mkdir(exist_ok=True)
        path.write_text(f'#!/bin/bash\nprintf "%s\\n" {operation} >> "$HOME/operations"\n')
    git(author, "add", ".")
    git(author, "commit", "-m", "initial distribution")
    git(author, "push", "-u", "origin", "master")
    initial = git(author, "rev-parse", "HEAD")
    bin_dir = temp / "bin"
    bin_dir.mkdir()
    chezmoi = bin_dir / "chezmoi"
    chezmoi.write_text('''#!/bin/bash
set -eu
[[ "$1" == --source ]]
case "$3" in
    diff) echo 'managed distribution changes' ;;
    apply) git -C "$2" rev-parse HEAD > "$HOME/applied" ;;
    *) exit 1 ;;
esac
''')
    chezmoi.chmod(0o755)
    mise = bin_dir / "mise"
    mise.write_text("#!/bin/sh\nexit 0\n")
    mise.chmod(0o755)
    accounts = []
    for login, home_name in (("localuser", "localuser"), ("user@example.com", "user")):
        home = temp / home_name
        repo = home / ".local/share/dotconfig"
        repo.parent.mkdir(parents=True)
        git(temp, "clone", str(remote), str(repo))
        git(repo, "config", "--local", "dotconfig.reviewedHead", initial)
        command = home / ".local/bin/dotconfig"
        command.parent.mkdir(parents=True)
        rendered = (ROOT / "home/dot_local/bin/executable_dotconfig.tmpl").read_text()
        rendered = rendered.replace('{{ .chezmoi.sourceDir | quote }}', f'"{repo}"')
        rendered = rendered.replace('{{ .machineRole | quote }}', '"work"')
        rendered = rendered.replace('{{ .hostType | quote }}', '"laptop"')
        command.write_text(rendered)
        accounts.append((login, home, repo, command))
    (author / "distribution-version").write_text("new reviewed distribution\n")
    git(author, "add", ".")
    git(author, "commit", "-m", "update distribution")
    git(author, "push")
    latest = git(author, "rev-parse", "HEAD")
    for index, (login, home, repo, command) in enumerate(accounts):
        sync(command, home, login, bin_dir)
        assert git(repo, "rev-parse", "HEAD") == latest
        assert git(repo, "config", "--get", "dotconfig.reviewedHead") == latest
        assert (home / "applied").read_text().strip() == latest
        assert (home / "operations").read_text().splitlines() == [
            "packages", "runtimes", "shell", "vim", "packages"
        ]
        if index == 0:
            other_home, other_repo = accounts[1][1:3]
            assert git(other_repo, "rev-parse", "HEAD") == initial
            assert git(other_repo, "config", "--get", "dotconfig.reviewedHead") == initial
            assert not (other_home / "applied").exists()
            assert not (other_home / "operations").exists()
print("Local and domain account distributions sync independently with review.")
