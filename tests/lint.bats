#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater lint checks
#
# Syntax-checks every shell file and requires ShellCheck to report nothing for any of
# them: the legacy script, the git hooks, the test helpers and the test files.
# -------------------------------------------------------

load helpers

HOOKS=(.githooks/pre-commit .githooks/pre-push .githooks/privacy-scan)

@test "update_kernel.sh passes a bash -n syntax check" {
    run bash -n "$REPO_DIR/update_kernel.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "The git hooks pass a POSIX sh -n syntax check" {
    local hook
    for hook in "${HOOKS[@]}"; do
        run sh -n "$REPO_DIR/$hook"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "ShellCheck reports nothing for any shell file" {
    command -v shellcheck > /dev/null || skip "shellcheck is not on PATH"
    # The glob expands here, so it must be relative to the repository root.
    cd "$REPO_DIR"
    run_shellcheck -x -f gcc update_kernel.sh "${HOOKS[@]}" tests/helpers.bash tests/*.bats
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
