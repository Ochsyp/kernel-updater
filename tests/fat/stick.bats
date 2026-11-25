#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater checks on real FAT
#
# As root in the fat job, builds a synthetic stick in a loop file, as MultiBootUSB leaves one:
# an MBR with the synthetic disk signature, FAT32 on partition 1 with syslinux's boot sector,
# and ext4 as /boot on partition 2. Runs on it what reading FAT needs: finding partition 1 from
# /boot, its identity, read-only mounts with vfat, names stored in capitals, a mount a user owns,
# a read-only mount, writers that leave it alone, and the baseline and its tripwire with a real
# "not cleanly unmounted" flag.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load fat

FAT_WHY="partition 1 is FAT, which kernel-updater writes only with migrate --write-fat"

setup_file() {
    fat_enabled || return 0
    make_stick
}

teardown_file() {
    fat_enabled || return 0
    remove_stick
}

# A fresh partition 1, partition 2 mounted as KU_ROOT's /boot, a config that names the stick,
# the kernel's list of filesystems, and no VM, whatever runs the job, so that deploy = auto
# would write directly were partition 1 NTFS.
setup() {
    fat_only
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    cat /proc/filesystems > "$ROOT/proc/filesystems"
    printf 'BOOT_IMAGE=/vmlinuz root=/dev/mapper/kali--vg-root ro quiet\n' > "$ROOT/proc/cmdline"
    fresh_partition
    mount "${STICK_LOOP}p2" "$ROOT/boot"
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$STICK_PTUUID" "$STICK_SERIAL" \
        > "$ROOT/etc/kernel-updater.conf"
    mkstub systemd-detect-virt <<< 'echo none; exit 1'
    printf '%s' "$STICK_GRUB_CFG" > "$BATS_TEST_TMPDIR/old.cfg"
}

teardown() {
    fat_enabled || return 0
    unmount_under "$ROOT"
}

# Fail unless the last run printed no identifier and no device name.
private_output() {
    local all="${output,,}${stderr,,}"
    [[ "$all" != *5ca1ab1e* && "$all" != *5ca1-ab1e* && "$all" != */dev/loop* ]]
}

@test "Partition 1 is FAT with syslinux's boot sector, found from /boot, and its identity checked" {
    # syslinux wrote its boot sector, which names it, and ldlinux.sys.
    [ "$(dd if="${STICK_LOOP}p1" bs=1 skip=3 count=8 status=none)" = SYSLINUX ]
    [ "$(fat_flags)" = 0 ]
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_disk_identity
        printf "%s\n" "$KU_DK_DISK" "$KU_DK_PART" "$KU_DK_FSTYPE" "$KU_DK_UUID" \
            "$KU_DK_DISK_ID" "$KU_DK_P1_ID"'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' "$STICK_LOOP" "${STICK_LOOP}p1" vfat "$STICK_SERIAL" match \
        match)" ]
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$STICK_PTUUID" 5CA1-AB1F \
        > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib ku_p1_locate
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"error: partition 1 of the disk that holds /boot is not the FAT or NTFS"* ]]
    private_output
}

@test "vfat mounts partition 1 read-only as root's alone, refuses to write it, and changes nothing" {
    local before
    before=$(p1_sum)
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_p1_open ro
        findmnt -r -n -o FSTYPE,OPTIONS --target "$KU_DK_ROOT"
        stat -c "%u %g %a" "$KU_DK_ROOT" "$KU_DK_ROOT/multibootusb/grub/grub.cfg"
        cmp -s "$KU_DK_ROOT/multibootusb/grub/grub.cfg" "$1"
        ku_p1_open plan
        printf "%s\n" "$KU_DK_HOW"
        ku_p1_open rw || printf "%s\n" "$KU_DK_PROBLEM"' "$BATS_TEST_TMPDIR/old.cfg"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "vfat ro,nosuid,nodev,noexec,"* ]]
    [[ "${lines[0]}" == *"fmask=0077,dmask=0077"* ]]
    [ "${lines[1]}" = "0 0 700" ]
    [ "${lines[2]}" = "0 0 700" ]
    [ "${lines[3]}" = private ]
    [ "${lines[4]}" = "$FAT_WHY" ]
    [ -z "$(ls -A "$ROOT/run")" ]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(p1_sum)" = "$before" ]
}

@test "Names stored in capitals, as an old FAT tool leaves them, read as MultiBootUSB's" {
    local view
    view=$(mount_p1 rw "$ROOT")
    rm "$view/multibootusb/grub/grub.cfg"
    printf '%s' "$STICK_GRUB_CFG" > "$view/multibootusb/grub/GRUB.CFG"
    printf 'module\n' > "$view/multibootusb/grub/i386-pc/EXTRA.MOD"
    # An upper-case 8.3 name gets no long name, so FAT keeps it in capitals only.
    [ -n "$(find "$view/multibootusb/grub" -maxdepth 1 -name GRUB.CFG)" ]
    [ -z "$(find "$view/multibootusb/grub" -maxdepth 1 -name grub.cfg)" ]
    umount "$view"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_p1_open ro; ku_baseline_hash "$KU_DK_ROOT"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(sha256sum < "$BATS_TEST_TMPDIR/old.cfg" | cut -c 1-64)  multibootusb/grub/grub.cfg"* ]]
    [[ "$output" == *"  multibootusb/grub/i386-pc/EXTRA.MOD"* ]]
    run_ku check --porcelain
    expect_item p1-identity ok "the disk that holds /boot and its FAT partition 1 are"
    expect_item grub-version ok "the stick's GRUB is 2.06"
    expect_item kali-menu skip "not migrated yet: grub.cfg does not source kali.cfg"
}

@test "A mount of partition 1 that a user owns serves no plan, and a reader reads through it" {
    local user="$ROOT/media/user/BOOT"
    mkdir -p "$user"
    mount -t vfat -o uid=1000,gid=1000 "${STICK_LOOP}p1" "$user"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }'
    [ "$status" -eq 3 ]
    [[ "$output" == "partition 1 is mounted where users other than root can change its files"* ]]
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s|%s\n" "$KU_DK_HOW" "$KU_DK_ROOT"'
    [ "$output" = "mount|$user" ]
}

@test "No deploy mode writes partition 1: each exports, through a read-only mount that is there" {
    local view before mode
    view=$(mount_p1 ro "$ROOT")
    before=$(p1_sum)
    for mode in auto direct; do
        printf 'disk_ptuuid = %s\np1_fs_uuid = %s\ndeploy = %s\n' "$STICK_PTUUID" \
            "$STICK_SERIAL" "$mode" > "$ROOT/etc/kernel-updater.conf"
        # shellcheck disable=SC2016 # the code expands its own variables
        run_ku_lib 'ku_deploy_resolve
            printf "%s|%s|%s|%s\n" "$KU_DK_DEPLOY" "$KU_DK_DEPLOY_WHY" "$KU_DK_HOW" "$KU_DK_ROOT"'
        [ "$status" -eq 0 ]
        [ "$output" = "export|$FAT_WHY|mount|$view" ]
    done
    # path, with p1_path on that mount.
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\ndeploy = path\np1_path = %s\n' \
        "$STICK_PTUUID" "$STICK_SERIAL" "${view#"$ROOT"}" > "$ROOT/etc/kernel-updater.conf"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve
        printf "%s|%s|%s\n" "$KU_DK_DEPLOY" "$KU_DK_DEPLOY_WHY" "$KU_DK_HOW"'
    [ "$status" -eq 0 ]
    [ "$output" = "export|$FAT_WHY|path" ]
    [[ "$stderr" == *"warning: deploy = path cannot write partition 1: $FAT_WHY"* ]]
    [ "$(findmnt -n -r -o OPTIONS --source "${STICK_LOOP}p1" | cut -d , -f 1 | sort -u)" = ro ]
    [ "$(p1_sum)" = "$before" ]
}

@test "baseline records the stick; the tripwire passes a real dirty flag and catches any other byte" {
    local view
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"recorded 16 entries in /var/lib/kernel-updater/baseline: 14 file(s)"* ]]
    # A read-write mount marks the volume dirty while it lasts, and the tripwire reads the boot
    # sector through it.
    view=$(mount_p1 rw "$ROOT")
    (( $(fat_flags) & 1 ))
    run_ku check --porcelain
    expect_item tripwire ok "entries of the baseline match"
    umount "$view"
    [ "$(fat_flags)" = 0 ]
    # Left dirty, with disk errors, as an unplug without an eject may leave it.
    set_fat_flags 3
    run_ku check --porcelain
    expect_item p1-identity ok "its FAT partition 1 are"
    expect_item tripwire ok "entries of the baseline match"
    expect_item boot-menu ok "hypervisor: none;"
    # check's read-only mount left the flag as it was.
    [ "$(fat_flags)" = 3 ]
    # Any other byte of the boot sector, such as the OEM name syslinux wrote, shows.
    poke_byte "${STICK_LOOP}p1" 3
    run_ku --porcelain baseline --show
    [[ "$output" == *$'same\t15\nchanged\tp1:boot-sector'* ]]
    run_ku check --porcelain
    expect_item tripwire fail "changed: p1:boot-sector since"
    private_output
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
}
