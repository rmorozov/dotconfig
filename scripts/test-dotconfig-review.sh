#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
git init --bare --initial-branch=master "$test_dir/remote" >/dev/null
git clone "$test_dir/remote" "$test_dir/author" >/dev/null 2>&1
git -C "$test_dir/author" config user.name test
git -C "$test_dir/author" config user.email test@example.com
mkdir -p "$test_dir/author/scripts"
printf '%s\n' 'initial' > "$test_dir/author/scripts/maintenance.sh"
git -C "$test_dir/author" add .
git -C "$test_dir/author" commit -m initial >/dev/null
git -C "$test_dir/author" push -u origin master >/dev/null 2>&1
git clone "$test_dir/remote" "$test_dir/machine" >/dev/null 2>&1
reviewed_head="$(git -C "$test_dir/machine" rev-parse HEAD)"
git -C "$test_dir/machine" config --local dotconfig.reviewedHead "$reviewed_head"

cat > "$test_dir/bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
[[ "${*: -1}" == diff ]] || {
    echo "Unexpected chezmoi apply during declined update" >&2
    exit 1
}
EOF
chmod +x "$test_dir/bin/chezmoi"
awk -v source="$test_dir/machine" '
    BEGIN { q = sprintf("%c", 34) }
    /^SOURCE_DIR=/ { print "SOURCE_DIR=" q source q; next }
    /^MACHINE_ROLE=/ { print "MACHINE_ROLE=" q "personal" q; next }
    /^HOST_TYPE=/ { print "HOST_TYPE=" q "laptop" q; next }
    { print }
' "$REPO_ROOT/home/dot_local/bin/executable_dotconfig.tmpl" > "$test_dir/dotconfig"
chmod +x "$test_dir/dotconfig"

printf '%s\n' 'changed implementation' > "$test_dir/author/scripts/maintenance.sh"
git -C "$test_dir/author" commit -am 'change maintenance script only' >/dev/null
git -C "$test_dir/author" push >/dev/null 2>&1

for attempt in 1 2; do
    if PATH="$test_dir/bin:$PATH" bash "$test_dir/dotconfig" sync > "$test_dir/output" 2>&1; then
        echo "Sync ran without reviewing repository-only changes (attempt $attempt)" >&2
        exit 1
    fi
    grep -q 'Repository changes awaiting review' "$test_dir/output"
    grep -q 'changed implementation' "$test_dir/output"
    grep -q 'refusing to apply or converge without confirmation' "$test_dir/output"
    [[ "$(git -C "$test_dir/machine" config --local --get dotconfig.reviewedHead)" == "$reviewed_head" ]]
done

echo "Repository-only changes remain pending until review"

python3 - "$test_dir/dotconfig" "$test_dir/bin" <<'PY'
import errno
import os
import pty
import select
import signal
import sys

command, fake_bin = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.environ["PATH"] = fake_bin + os.pathsep + os.environ["PATH"]
    os.execv("/bin/bash", ["bash", command, "update"])

os.write(fd, b"y\n")
output = bytearray()
while True:
    if not select.select([fd], [], [], 20)[0]:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise SystemExit("Interactive update timed out")
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
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    sys.stderr.write(output.decode(errors="replace"))
    raise SystemExit("Interactive update failed")
if b"Accept these changes" not in output:
    raise SystemExit("Interactive review prompt was missing")
PY

new_head="$(git -C "$test_dir/machine" rev-parse HEAD)"
[[ "$(git -C "$test_dir/machine" config --local --get dotconfig.reviewedHead)" == "$new_head" ]]
PATH="$test_dir/bin:$PATH" bash "$test_dir/dotconfig" update > "$test_dir/output" 2>&1
grep -q 'Repository and managed dotfiles are already current' "$test_dir/output"

echo "Repository review approval persists across updates"
