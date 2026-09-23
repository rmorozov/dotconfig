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
    /^SOURCE_DIR=/ { print "SOURCE_DIR=\\"" source "\\""; next }
    /^MACHINE_ROLE=/ { print "MACHINE_ROLE=\\"personal\\""; next }
    /^HOST_TYPE=/ { print "HOST_TYPE=\\"laptop\\""; next }
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
