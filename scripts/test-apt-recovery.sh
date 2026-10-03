#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/home"
cat > "$root/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf 'Linux\n'
STUB
cat > "$root/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
cat > "$root/bin/apt-config" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$root/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TEST_APT_LOG"
if [[ "$1" == update ]]; then exit "$TEST_UPDATE_STATUS"; fi
exit "$TEST_INSTALL_STATUS"
STUB
cat > "$root/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
if [[ "${@: -1}" == git && "$TEST_MISSING" == yes ]]; then
    printf 'iU '
else
    printf 'ii '
fi
STUB
cat > "$root/bin/dpkg" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == --audit ]]
printf '%s' "$TEST_AUDIT_OUTPUT"
exit "$TEST_AUDIT_STATUS"
STUB
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" HOME="$root/home" TEST_APT_LOG="$root/apt.log"
export TEST_UPDATE_STATUS=0 TEST_INSTALL_STATUS=0 TEST_MISSING=no TEST_AUDIT_STATUS=0 TEST_AUDIT_OUTPUT=
run_install() { bash "$repo_root/packages/install.sh" > "$root/output" 2>&1; }
run_install
export TEST_UPDATE_STATUS=100
run_install
grep -q 'trying installation with cached' "$root/output"
[[ "$(tail -1 "$TEST_APT_LOG")" == install ]]
export TEST_INSTALL_STATUS=100
run_install
grep -q 'Continuing because all baseline packages are fully installed' "$root/output"
export TEST_MISSING=yes
status=0
run_install || status=$?
[[ "$status" == 100 ]]
grep -q 'baseline is incomplete' "$root/output"
if grep -q 'Continuing because' "$root/output"; then exit 1; fi
export TEST_MISSING=no TEST_AUDIT_OUTPUT='Unconfigured unrelated package'
status=0
run_install || status=$?
[[ "$status" == 100 ]]
grep -q 'dpkg state needs attention' "$root/output"
export TEST_AUDIT_OUTPUT= TEST_AUDIT_STATUS=2
status=0
run_install || status=$?
[[ "$status" == 100 ]]
grep -q 'audit exit 2' "$root/output"
echo 'APT recovery checks passed'
