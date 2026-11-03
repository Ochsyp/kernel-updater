#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater static checks
#
# Syntax-checks every shell file and the awk linter, and requires ShellCheck to report
# nothing for any shell file: the scripts, the libraries, the git hooks and the tests.
# -------------------------------------------------------

load helpers

SCRIPTS=(update_kernel.sh bin/kernel-updater lib/kernel-updater/common.sh
    lib/kernel-updater/config.sh lib/kernel-updater/lint.sh)
HOOKS=(.githooks/pre-commit .githooks/pre-push .githooks/privacy-scan)

@test "The bash scripts and libraries pass a bash -n syntax check" {
    local script
    for script in "${SCRIPTS[@]}"; do
        run bash -n "$REPO_DIR/$script"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "The git hooks pass a POSIX sh -n syntax check" {
    local hook
    for hook in "${HOOKS[@]}"; do
        run sh -n "$REPO_DIR/$hook"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "lint.awk parses and runs under the system awk" {
    run env KU_LINT_CFG=/dev/null KU_LINT_CMDS=/dev/null KU_LINT_MODS=/dev/null KU_LINT_FLOOR=2.02 \
        awk -f "$REPO_DIR/lib/kernel-updater/lint.awk"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ShellCheck reports nothing for any shell file" {
    command -v shellcheck > /dev/null || skip "shellcheck is not on PATH"
    # The glob expands here, so it must be relative to the repository root.
    cd "$REPO_DIR"
    run_shellcheck -x -f gcc "${SCRIPTS[@]}" "${HOOKS[@]}" tests/helpers.bash tests/*.bats
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
