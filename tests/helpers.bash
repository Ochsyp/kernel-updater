# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater test helpers
#
# Sourced by every .bats file in tests/ through `load helpers`. Holds the repository
# paths, PATH stubs that log their arguments, and the ShellCheck runners the lint
# checks use.
# -------------------------------------------------------

bats_require_minimum_version 1.5.0

TESTS_DIR="$BATS_TEST_DIRNAME"
REPO_DIR="${TESTS_DIR%/*}"

# Create the per-test stub directory and the log every stub appends its call to.
# Call from setup() before writing any stub.
stub_init() {
    export STUB_BIN="$BATS_TEST_TMPDIR/bin"
    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$STUB_BIN"
    : > "$STUB_LOG"
}

# Shared opening of every stub: appends "NAME ARGS" to $STUB_LOG in one write, each
# argument printf %q-quoted.
IFS= read -r -d '' _STUB_PROLOGUE <<'EOF' || true
if (( $# )); then printf -v _stub_args ' %q' "$@"; else _stub_args=''; fi
printf '%s%s\n' "$STUB_NAME" "$_stub_args" >> "${STUB_LOG:?}"
EOF

# Write the executable stub $STUB_BIN/NAME: shebang, name, the shared prologue, then the
# body read from stdin. An empty body makes a stub that only logs and exits 0.
mkstub() {
    local name="$1" body
    IFS= read -r -d '' body || true
    printf '#!/bin/bash\nSTUB_NAME=%q\n%s%s' "$name" "$_STUB_PROLOGUE" "$body" > "$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
}

# Write a stub NAME that must never run: it logs the call and exits 100, so a test that
# reaches it fails on the exit status and on the log.
stub_refuse() {
    mkstub "$1" <<'EOF'
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
}

# Run update_kernel.sh with the stubs first on PATH, through bats' run with separate
# stderr. Only the script sees the stubs; the test's own commands stay real.
run_legacy() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$REPO_DIR/update_kernel.sh" "$@"
}

# Fail the test when the ERE $1 matches a line of file $2. A bare `! grep` would not fail
# a bats test, because errexit ignores negated commands.
refute_line_match() {
    if grep -q -E -e "$1" "$2"; then
        printf 'unexpected match for %s in %s:\n' "$1" "$2" >&2
        grep -E -e "$1" "$2" >&2
        return 1
    fi
}

# Run shellcheck through bats' run, with separate stderr.
run_shellcheck() {
    run --separate-stderr _exec_shellcheck "$@"
}

# Execute shellcheck in the repository root with MSYS path conversion disabled.
_exec_shellcheck() {
    (cd "$REPO_DIR" && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' shellcheck "$@")
}

# Print "CODE COUNT" per ShellCheck code, sorted, for gcc-format findings on
# stdin. Strips the CR a Windows build may end its lines with.
shellcheck_code_counts() {
    local line code
    local -A count=()
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ \[(SC[0-9]+)\]$ ]]; then
            code="${BASH_REMATCH[1]}"
            count[$code]=$(( ${count[$code]:-0} + 1 ))
        fi
    done
    for code in "${!count[@]}"; do
        printf '%s %d\n' "$code" "${count[$code]}"
    done | sort
}
