#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater configuration checks
#
# Calls ku_config_load on config files in the test's temp directory: defaults, the accepted
# syntax, unknown keys, rejected lines and values, and the owner check when run as root.
# -------------------------------------------------------

load helpers

setup() {
    stub_init
    load_ku_libs
    export PATH="$STUB_BIN:$PATH"
    CONF="$BATS_TEST_TMPDIR/kernel-updater.conf"
    mkstub id <<< 'echo 1000'
}

@test "A missing config file keeps the defaults" {
    ku_config_load "$BATS_TEST_TMPDIR/none.conf"
    [ "${KU_CONF[grub_floor]}" = 2.02 ]
}

@test "A config file sets its keys, with comments, blank lines, spaces and CRLF allowed" {
    printf '# comment\r\n\r\n  grub_floor   =  2.12  \r\n' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[grub_floor]}" = 2.12 ]
}

@test "An unknown key is ignored with a warning that names the line" {
    printf 'grub_floor = 2.06\nnew_key = x\n' > "$CONF"
    run ku_config_load "$CONF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$CONF:2: unknown key 'new_key' ignored"* ]]
}

@test "A line that is not key = value or an invalid value exits 78 and names the line" {
    printf 'grub_floor 2.06\n' > "$CONF"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
    [[ "$output" == *"$CONF:1: expected a 'key = value' line"* ]]
    printf '\ngrub_floor = 2.03\n' > "$CONF"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
    [[ "$output" == *"$CONF:2: invalid value for 'grub_floor'"* ]]
    printf 'grub_floor =\n' > "$CONF"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
}

@test "A value is never executed" {
    # shellcheck disable=SC2016 # the command substitution must reach the file unexpanded
    printf 'grub_floor = $(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" > "$CONF"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "As root, a config file owned by another user or writable by group or others exits 78" {
    printf 'grub_floor = 2.06\n' > "$CONF"
    mkstub id <<< 'echo 0'
    # shellcheck disable=SC2016 # the stub expands the variable when it runs
    mkstub stat <<< 'echo "$STAT_RESULT"'
    export STAT_RESULT="1000 644"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
    [[ "$output" == *"must be owned by root"* ]]
    export STAT_RESULT="0 664"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
    [[ "$output" == *"must not be writable by group or others"* ]]
    export STAT_RESULT="0 600"
    run ku_config_load "$CONF"
    [ "$status" -eq 0 ]
}

@test "The example config file loads without a warning" {
    run ku_config_load "$REPO_DIR/examples/kernel-updater.conf"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    KU_CONF[grub_floor]=2.14
    ku_config_load "$REPO_DIR/examples/kernel-updater.conf"
    [ "${KU_CONF[grub_floor]}" = 2.02 ]
}

@test "A key set twice exits 78 and names the second line" {
    printf 'grub_floor = 2.06\n# again\ngrub_floor = 2.12\n' > "$CONF"
    run ku_config_load "$CONF"
    [ "$status" -eq 78 ]
    [[ "$output" == *"$CONF:3: 'grub_floor' is set twice"* ]]
}
