#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater static checks
#
# Syntax-checks every shell file and the awk scripts, and requires ShellCheck to report
# nothing for any shell file: the scripts, the libraries, the git hooks, apt-guard, the kernel
# hooks and the tests, the container and NTFS suites included.
# -------------------------------------------------------

load helpers

SCRIPTS=(install.sh bin/kernel-updater lib/kernel-updater/common.sh
    lib/kernel-updater/config.sh lib/kernel-updater/lint.sh lib/kernel-updater/probe.sh
    lib/kernel-updater/check.sh lib/kernel-updater/hook.sh lib/kernel-updater/disk.sh
    lib/kernel-updater/deploy.sh lib/kernel-updater/baseline.sh lib/kernel-updater/migrate.sh
    lib/kernel-updater/cleanup.sh)
# POSIX sh scripts: the git hooks, apt-guard and the kernel hooks install.sh installs.
HOOKS=(.githooks/pre-commit .githooks/pre-push .githooks/privacy-scan lib/kernel-updater/apt-guard
    hooks/kernel/preinst.d/00-kernel-updater hooks/kernel/prerm.d/00-kernel-updater
    hooks/kernel/postinst.d/00-kernel-updater hooks/kernel/postinst.d/kernel-updater)

@test "The bash scripts and libraries pass a bash -n syntax check" {
    local script
    for script in "${SCRIPTS[@]}"; do
        run bash -n "$REPO_DIR/$script"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "SCRIPTS lists every library in lib/kernel-updater, so none escapes the checks" {
    local lib
    cd "$REPO_DIR"
    for lib in lib/kernel-updater/*.sh; do
        if [[ " ${SCRIPTS[*]} " != *" $lib "* ]]; then
            printf '%s is missing from SCRIPTS\n' "$lib" >&2
            return 1
        fi
    done
}

@test "HOOKS lists every kernel hook, so none escapes the checks" {
    local hook
    cd "$REPO_DIR"
    for hook in hooks/kernel/*.d/*; do
        if [[ " ${HOOKS[*]} " != *" $hook "* ]]; then
            printf '%s is missing from HOOKS\n' "$hook" >&2
            return 1
        fi
    done
}

@test "The POSIX sh scripts pass a sh -n syntax check" {
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

@test "menu.awk parses and runs under the system awk" {
    run env LC_ALL=C KU_MENU_CFG=/dev/null awk -f "$REPO_DIR/lib/kernel-updater/menu.awk"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ShellCheck reports nothing for any shell file" {
    command -v shellcheck > /dev/null || skip "shellcheck is not on PATH"
    # The glob expands here, so it must be relative to the repository root.
    cd "$REPO_DIR"
    run_shellcheck -x -f gcc "${SCRIPTS[@]}" "${HOOKS[@]}" tests/helpers.bash tests/*.bats \
        tests/container/container.bash tests/container/*.bats tests/ntfs/ntfs.bash \
        tests/ntfs/*.bats
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
