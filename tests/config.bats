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
    [ -z "${KU_CONF[boot_fs_uuid]}" ]
    [ -z "${KU_CONF[boot_luks_uuid]}" ]
    [ "${KU_CONF[verify_action]}" = fail ]
    [ -z "${KU_CONF[disk_ptuuid]}" ]
    [ -z "${KU_CONF[p1_fs_uuid]}" ]
    [ "${KU_CONF[deploy]}" = auto ]
    [ -z "${KU_CONF[p1_path]}" ]
    [ "${KU_CONF[output_dir]}" = /root/kernel-updater/out ]
    [ "${KU_CONF[backups_keep]}" = 5 ]
}

@test "disk_ptuuid takes an MBR disk signature or a GPT UUID and keeps it lower case" {
    printf 'disk_ptuuid = 5CA1AB1E\n' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[disk_ptuuid]}" = 5ca1ab1e ]
    printf 'disk_ptuuid = 5CA1AB1E-0000-4000-8000-000000000D01\n' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[disk_ptuuid]}" = 5ca1ab1e-0000-4000-8000-000000000d01 ]
}

@test "p1_fs_uuid takes an NTFS serial of 16 hex digits and keeps it upper case" {
    printf 'p1_fs_uuid = 5ca1ab1e00000001\n' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[p1_fs_uuid]}" = 5CA1AB1E00000001 ]
}

@test "deploy, p1_path, output_dir and backups_keep take their values" {
    printf '%s\n' 'deploy = path' 'p1_path = /media/sf_BOOT' \
        'output_dir = /srv/kernel updater/out' 'backups_keep = 99' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[deploy]}" = path ]
    [ "${KU_CONF[p1_path]}" = /media/sf_BOOT ]
    [ "${KU_CONF[output_dir]}" = "/srv/kernel updater/out" ]
    [ "${KU_CONF[backups_keep]}" = 99 ]
    local value
    for value in auto direct export; do
        printf 'deploy = %s\n' "$value" > "$CONF"
        ku_config_load "$CONF"
        [ "${KU_CONF[deploy]}" = "$value" ]
    done
}

@test "A path loses its trailing slashes, so that output_dir/ names the directory itself" {
    printf '%s\n' 'output_dir = /root/kernel-updater/out/' 'p1_path = /media/sf_BOOT//' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[output_dir]}" = /root/kernel-updater/out ]
    [ "${KU_CONF[p1_path]}" = /media/sf_BOOT ]
    printf 'output_dir = /\n' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[output_dir]}" = / ]
}

@test "Each new key refuses a value that does not fit, with exit 78 and without echoing it" {
    local entry key value
    for entry in "disk_ptuuid 5ca1ab1" "disk_ptuuid 5ca1ab1e0" "disk_ptuuid 0x5ca1ab1e" \
        "disk_ptuuid 5ca1ab1g" "disk_ptuuid 5ca1ab1e-0000-4000-8000-000000000d0" \
        "p1_fs_uuid 5CA1AB1E0000001" "p1_fs_uuid 5CA1AB1E000000001" \
        "p1_fs_uuid 5CA1-AB1E-0000-0001" "deploy Auto" "deploy copy" "p1_path media/sf_BOOT" \
        "p1_path /media/../BOOT" "p1_path /media/./BOOT" "output_dir ~/out" \
        "backups_keep 0" "backups_keep 100" "backups_keep 05" "backups_keep -1"; do
        read -r key value <<< "$entry"
        printf '%s = %s\n' "$key" "$value" > "$CONF"
        run ku_config_load "$CONF"
        [ "$status" -eq 78 ] || { printf 'accepted: %s\n' "$entry" >&2; return 1; }
        [[ "$output" == *"$CONF:1: invalid value for '$key'"* ]]
        # The identifiers are long enough that the temp path cannot hold them by chance.
        [[ "$key" != *uuid || "${output,,}" != *5ca1ab1* ]]
    done
}

@test "verify_action takes fail or warn, and nothing else" {
    printf 'verify_action = warn\n' > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[verify_action]}" = warn ]
    local value
    for value in Fail ignore "fail warn"; do
        printf 'verify_action = %s\n' "$value" > "$CONF"
        run ku_config_load "$CONF"
        [ "$status" -eq 78 ] || { printf 'accepted: %s\n' "$value" >&2; return 1; }
    done
}

@test "Each key's check is a _ku_valid_ function, which a default that is set passes" {
    local key
    for key in "${!KU_CONF_SCHEMA[@]}"; do
        declare -F "_ku_valid_${KU_CONF_SCHEMA[$key]}" > /dev/null
        [ -z "${KU_CONF[$key]}" ] || "_ku_valid_${KU_CONF_SCHEMA[$key]}" "${KU_CONF[$key]}"
    done
}

@test "boot_fs_uuid and boot_luks_uuid take UUIDs in either case and keep them lower case" {
    printf 'boot_fs_uuid = %s\nboot_luks_uuid=%s\n' 5CA1AB1E-0000-4000-8000-000000000B01 \
        5ca1ab1e-0000-4000-8000-000000000c01 > "$CONF"
    ku_config_load "$CONF"
    [ "${KU_CONF[boot_fs_uuid]}" = 5ca1ab1e-0000-4000-8000-000000000b01 ]
    [ "${KU_CONF[boot_luks_uuid]}" = 5ca1ab1e-0000-4000-8000-000000000c01 ]
}

@test "A UUID that is not 8-4-4-4-12 hex digits exits 78 without echoing the value" {
    local value
    for value in 5ca1ab1e 5ca1ab1e000040008000000000000b01 5ca1ab1e-0000-4000-8000-000000000b0 \
        5ca1ab1e-0000-4000-8000-000000000b01x "{5ca1ab1e-0000-4000-8000-000000000b01}" \
        5ca1ab1g-0000-4000-8000-000000000b01 "5ca1ab1e-0000-4000-8000-000000000b01 x"; do
        printf 'boot_luks_uuid = %s\n' "$value" > "$CONF"
        run ku_config_load "$CONF"
        [ "$status" -eq 78 ] || { printf 'accepted: %s\n' "$value" >&2; return 1; }
        [[ "$output" == *"$CONF:1: invalid value for 'boot_luks_uuid'"* && "$output" != *5ca1ab1* ]]
    done
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
