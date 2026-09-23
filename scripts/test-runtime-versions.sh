#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/project"
cat > "$test_dir/project/mise.toml" <<'EOF'
[tools]
node = "1.0.0"
go = "1.0.0"
python = "1.0.0"
EOF
cat > "$test_dir/bin/mise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MISE_TEST_LOG"
case "$1" in
    install) [[ "$*" != *'@1.0.0'* ]] ;;
    where) [[ "$2" != *'@1.0.0' && "$2" != "$MISE_TEST_MISSING" ]] ;;
    exec)
        [[ "$2" != *'@1.0.0' ]] || exit 1
        if [[ "$2" == "${MISE_TEST_BAD_VERSION:-}" ]]; then
            echo "$4 version 0.0.0"
        else
            echo "$4 version ${2#*@}"
        fi
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/mise"
export PATH="$test_dir/bin:$PATH"
export MISE_TEST_LOG="$test_dir/mise.log"
export MISE_TEST_MISSING=''

cd "$test_dir/project"
bash "$REPO_ROOT/scripts/manage-runtime-versions.sh" install
expected=()
while IFS= read -r pin; do
    expected+=("$pin")
done < <(awk -F '"' '/^[a-z]+ = "[0-9]+\.[0-9]+\.[0-9]+"$/ { split($1, key, " "); print key[1] "@" $2 }' "$REPO_ROOT/home/dot_config/mise/config.toml")
[[ "$(cat "$MISE_TEST_LOG")" == "install ${expected[*]}" ]]

: > "$MISE_TEST_LOG"
bash "$REPO_ROOT/scripts/manage-runtime-versions.sh" status
[[ "$(wc -l < "$MISE_TEST_LOG")" -eq "${#expected[@]}" ]]
for pin in "${expected[@]}"; do
    grep -Fxq "where $pin" "$MISE_TEST_LOG"
done

: > "$MISE_TEST_LOG"
bash "$REPO_ROOT/scripts/manage-runtime-versions.sh" smoke
for pin in "${expected[@]}"; do
    grep -Fxq "exec $pin -- ${pin%@*} --version" "$MISE_TEST_LOG"
done

export MISE_TEST_BAD_VERSION="${expected[0]}"
if bash "$REPO_ROOT/scripts/manage-runtime-versions.sh" smoke > "$test_dir/smoke.log" 2>&1; then
    echo "Runtime smoke passed despite wrong reported version" >&2
    exit 1
fi
grep -Fq "version mismatch for ${expected[0]}" "$test_dir/smoke.log"
unset MISE_TEST_BAD_VERSION

export MISE_TEST_MISSING="${expected[1]}"
if bash "$REPO_ROOT/scripts/manage-runtime-versions.sh" status > "$test_dir/status.log" 2>&1; then
    echo "Runtime status passed despite a missing global pin" >&2
    exit 1
fi
grep -Fxq "missing: ${expected[1]}" "$test_dir/status.log"

echo "Runtime baseline tests passed"
