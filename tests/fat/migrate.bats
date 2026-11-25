#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater migrate on real FAT
#
# As root in the fat job, runs migrate on the synthetic stick of fat.bash, with /boot on ext4 on
# a device-mapper device over partition 2, as the stick's unlocked /boot is: detect fills in the
# stick's identity from real FAT, and the menu stage, which would write partition 1, leaves its
# files in output_dir instead and partition 1 byte for byte as it was. Stubs stand in for what
# the runner lacks: cryptsetup, which the mapping is no LUKS container for, uname, lsinitramfs
# and grub-script-check, which the bats and kali jobs run for real.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load fat

V1=9.0.1+kali-amd64
V2=9.0.2+kali-amd64
FIXTURES="$REPO_DIR/tests/fixtures/grub"
CONF=/etc/kernel-updater.conf

# The stick, and a linear device-mapper device over its partition 2, which /boot mounts.
setup_file() {
    fat_enabled || return 0
    make_stick
    dmsetup create ku-test-fat-boot --table \
        "0 $(blockdev --getsz "${STICK_LOOP}p2") linear ${STICK_LOOP}p2 0"
}

teardown_file() {
    fat_enabled || return 0
    if [[ -e /dev/mapper/ku-test-fat-boot ]]; then
        dmsetup remove ku-test-fat-boot
    fi
    remove_stick
}

# A fresh partition 1 whose grub.cfg is the CRLF fixture from before the migration, with GRUB
# 2.02's command and module lists; /boot mounted from the mapping with kernels V1 and V2 and
# their links, linux-base keeping them in /boot, and the kernel the fixture's legacy entries
# boot; the running kernel's command line; and no VM, so that deploy = auto would write were
# partition 1 NTFS.
setup() {
    fat_only
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    cat /proc/filesystems > "$ROOT/proc/filesystems"
    printf 'BOOT_IMAGE=/vmlinuz root=/dev/mapper/kali--vg-root ro quiet\n' > "$ROOT/proc/cmdline"
    fresh_partition
    sed 's/$/\r/' "$FIXTURES/migrate-before.cfg" > "$BATS_TEST_TMPDIR/grub.before"
    sed 's/$/\r/' "$FIXTURES/migrate-after.cfg" > "$BATS_TEST_TMPDIR/grub.after"
    local view v lists="$REPO_DIR/share/kernel-updater/grub-2.02"
    view=$(mount_p1 rw "$ROOT")
    cp "$BATS_TEST_TMPDIR/grub.before" "$view/multibootusb/grub/grub.cfg"
    cp "$lists/commands.txt" "$view/multibootusb/grub/i386-pc/command.lst"
    cp "$lists/modules.txt" "$view/multibootusb/grub/i386-pc/moddep.lst"
    umount "$view"
    # The tests of this file share the mapping, so each starts from an empty /boot.
    mkfs.ext4 -q -F -U "$STICK_BOOT_UUID" /dev/mapper/ku-test-fat-boot
    mount /dev/mapper/ku-test-fat-boot "$ROOT/boot"
    for v in "$V1" "$V2" 7.2.9+kali-amd64; do
        printf 'kernel %s\n' "$v" > "$ROOT/boot/vmlinuz-$v"
        printf 'initrd %s\n' "$v" > "$ROOT/boot/initrd.img-$v"
    done
    ln -s "vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    ln -s "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    stub_system_tools
    mkstub systemd-detect-virt <<< 'echo none; exit 1'
    mkstub grub-script-check
}

teardown() {
    fat_enabled || return 0
    unmount_under "$ROOT"
}

# Fail unless the last run printed no identifier and no device name.
private_output() {
    local all="${output,,}${stderr,,}"
    [[ "$all" != *5ca1ab1e* && "$all" != *5ca1-ab1e* && "$all" != */dev/loop* &&
        "$all" != *kali--vg-root* ]]
}

@test "detect fills in the identity of a real FAT stick, and check then reads it" {
    local before
    before=$(p1_sum)
    run_ku migrate --stage detect --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"plan:   p1_fs_uuid: the FAT serial of partition 1 of that disk"* ]]
    private_output
    grep -q -x -F "disk_ptuuid = $STICK_PTUUID" "$ROOT$CONF"
    grep -q -x -F "p1_fs_uuid = $STICK_SERIAL" "$ROOT$CONF"
    grep -q -x -F "boot_fs_uuid = $STICK_BOOT_UUID" "$ROOT$CONF"
    grep -q -x -F 'grub_floor = 2.06' "$ROOT$CONF"
    run_ku check --porcelain
    expect_item p1-identity ok "the disk that holds /boot and its FAT partition 1 are"
    expect_item kali-menu skip "not migrated yet"
    # The fixture's legacy entries boot other command lines only.
    expect_item boot-menu ok "hypervisor: none; the running kernel's command line ends 0 linux"
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(p1_sum)" = "$before" ]
}

@test "The menu stage leaves its files in output_dir and partition 1 byte for byte as it was" {
    local before out="$ROOT/root/kernel-updater/out"
    printf '%s\n' "boot_fs_uuid = $STICK_BOOT_UUID" \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' \
        "disk_ptuuid = $STICK_PTUUID" "p1_fs_uuid = $STICK_SERIAL" \
        'root_device = /dev/mapper/kali--vg-root' > "$ROOT$CONF"
    before=$(p1_sum)
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"info: deploy = auto picks export: partition 1 is FAT, which kernel-updater"* ]]
    [[ "$stderr" == *"plan: menu: export kali.cfg and grub.cfg to output_dir for Windows"* ]]
    private_output
    cmp "$FIXTURES/kali.expected.cfg" "$out/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.after" "$out/grub.cfg"
    [ "$(cut -c 67- "$out/SHA256SUMS")" = $'kali.cfg\ngrub.cfg' ]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(p1_sum)" = "$before" ]
}

# The configuration detect writes for the stick, and a command line that the fixture's first
# legacy entry boots, as the stick's menu booted the running kernel.
stick_config() {
    printf '%s\n' "boot_fs_uuid = $STICK_BOOT_UUID" \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' \
        "disk_ptuuid = $STICK_PTUUID" "p1_fs_uuid = $STICK_SERIAL" \
        'root_device = /dev/mapper/kali--vg-root' > "$ROOT$CONF"
    printf 'BOOT_IMAGE=/vmlinuz-7.2.9+kali-amd64 %s %s\n' 'root=/dev/mapper/kali--vg-root' \
        'cryptdevice=UUID=5ca1ab1e-0000-4000-8000-000000000c02:root_crypt ro quiet splash' \
        > "$ROOT/proc/cmdline"
}

# Print partition 1's FILE, read through a new read-only mount.
p1_file() {
    local view
    view=$(mount_p1 ro "$BATS_TEST_TMPDIR")
    cat "$view/multibootusb/grub/$1"
    umount "$view"
    rmdir "$view"
}

@test "menu --write-fat writes the menu under VMware, and --rollback --write-fat puts grub.cfg back" {
    stick_config
    mkstub systemd-detect-virt <<< 'echo vmware'
    printf 'BOOT is unmounted in Windows\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku migrate --stage menu --yes --write-fat
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"info: --write-fat: VMware, the stick's menu booted the running kernel"* ]]
    [[ "$stderr" == *"info: wrote multibootusb/grub/kali.cfg"* ]]
    [[ "$stderr" == *"info: wrote multibootusb/grub/grub.cfg; the old one is kept as"* ]]
    private_output
    cmp "$FIXTURES/kali.expected.cfg" <(p1_file kali.cfg)
    cmp "$BATS_TEST_TMPDIR/grub.after" <(p1_file grub.cfg)
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(fat_flags)" = 0 ]
    fsck_clean "${STICK_LOOP}p1"
    # The legacy entry still boots the running kernel, so the rollback may write too.
    run_ku migrate --rollback --yes --write-fat
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    cmp "$BATS_TEST_TMPDIR/grub.before" <(p1_file grub.cfg)
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    fsck_clean "${STICK_LOOP}p1"
    private_output
}

@test "menu --write-fat outside VMware refuses, and a dry run with it writes nothing" {
    local before
    stick_config
    printf 'BOOT is unmounted in Windows\n' > "$BATS_TEST_TMPDIR/tty"
    before=$(p1_sum)
    run_ku migrate --stage menu --yes --write-fat
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"refusing to write the FAT partition 1: this system runs in no VM, and"* ]]
    private_output
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(p1_sum)" = "$before" ]
    mkstub systemd-detect-virt <<< 'echo vmware'
    run_ku migrate --stage menu --dry-run --write-fat
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"would write multibootusb/grub/grub.cfg"* ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(p1_sum)" = "$before" ]
}
