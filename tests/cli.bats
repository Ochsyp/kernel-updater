#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater command-line checks
#
# Runs bin/kernel-updater for help, version, usage errors and a missing config file, and
# checks the exit codes and that errors leave stdout empty.
# -------------------------------------------------------

load helpers

setup() {
    stub_init
}

@test "--help and help print the usage on stdout and exit 0" {
    local arg
    for arg in --help -h help; do
        run_ku "$arg"
        [ "$status" -eq 0 ]
        [[ "$output" == "Usage: kernel-updater "* ]]
        [ -z "$stderr" ]
    done
}

@test "--version and version print the version from share/kernel-updater/VERSION" {
    local arg version
    version=$(< "$REPO_DIR/share/kernel-updater/VERSION")
    for arg in --version -V version; do
        run_ku "$arg"
        [ "$status" -eq 0 ]
        [ "$output" = "kernel-updater $version" ]
    done
}

@test "A missing or unknown command, an unknown option and a missing value exit 64" {
    local args
    for args in "" "bogus" "--bogus lint" "-c" "--config= lint x" "lint --floor"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku $args
        [ "$status" -eq 64 ] || { printf 'args "%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [ -z "$output" ]
        [[ "$stderr" == *"Try 'kernel-updater --help'."* ]]
    done
}

@test "-c with a file that does not exist exits 78" {
    run_ku -c "$BATS_TEST_TMPDIR/none.conf" lint "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 78 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not found"* ]]
}

@test "--quiet drops the info lines and only --verbose shows debug lines" {
    run_ku --quiet lint "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"info:"* ]]
    run_ku lint "$REPO_DIR/examples/grub.cfg"
    [[ "$stderr" == *"info: lint: 1 file(s), 0 error(s), 0 warning(s)"* && "$stderr" != *"debug:"* ]]
    run_ku --verbose lint "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"debug: no config file at"* ]]
}

@test "A command's --help works even with a broken config file" {
    printf 'not a config line\n' > "$BATS_TEST_TMPDIR/broken.conf"
    run_ku -c "$BATS_TEST_TMPDIR/broken.conf" lint --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: kernel-updater lint "* ]]
    run_ku -c "$BATS_TEST_TMPDIR/broken.conf" lint "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 78 ]
}
