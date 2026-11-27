#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater migrate on real NTFS
#
# As root in ci/system, runs migrate's menu stage end to end on the synthetic stick of
# ntfs.bash: partition 1 found from an ext4 /boot on a device-mapper device over partition 2, as
# the stick's unlocked /boot is, mounted read-write with ntfs3 after ntfs-3g.probe, kali.cfg and
# the new grub.cfg written there through the safe writer, CRLF kept, and --rollback writing
# grub.cfg back byte for byte. Stubs stand in for what the runner lacks: cryptsetup, which the
# mapping is no LUKS container for, uname, lsinitramfs and grub-script-check, which ci/test and
# the Kali container run for real.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load ntfs

V1=9.0.1+kali-amd64
V2=9.0.2+kali-amd64
FIXTURES="$REPO_DIR/tests/fixtures/grub"

# The stick, and a linear device-mapper device over its partition 2, which /boot mounts.
setup_file() {
    ntfs_enabled || return 0
    modprobe ntfs3
    make_stick
    dmsetup create ku-test-boot --table \
        "0 $(blockdev --getsz "${STICK_LOOP}p2") linear ${STICK_LOOP}p2 0"
}

teardown_file() {
    ntfs_enabled || return 0
    if [[ -e /dev/mapper/ku-test-boot ]]; then
        dmsetup remove ku-test-boot
    fi
    remove_stick
}

# A fresh partition 1 whose grub.cfg is the CRLF fixture from before the migration, and whose
# GRUB command and module lists, which the menu stage lints kali.cfg with, are GRUB 2.02's in
# place of the stick's placeholders; /boot mounted from the mapping with kernels V1 and V2 and
# their links, linux-base keeping them in /boot, and the kernel the fixture's legacy entries
# boot, which a rollback of the menu stage needs; the configuration detect would write; and no
# VM, so that deploy = auto writes.
setup() {
    ntfs_only
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    cat /proc/filesystems > "$ROOT/proc/filesystems"
    fresh_partition
    sed 's/$/\r/' "$FIXTURES/migrate-before.cfg" > "$BATS_TEST_TMPDIR/grub.before"
    sed 's/$/\r/' "$FIXTURES/migrate-after.cfg" > "$BATS_TEST_TMPDIR/grub.after"
    local view lists="$REPO_DIR/share/kernel-updater/grub-2.02"
    view=$(mount_p1 rw "$ROOT")
    cp "$BATS_TEST_TMPDIR/grub.before" "$view/multibootusb/grub/grub.cfg"
    cp "$lists/commands.txt" "$view/multibootusb/grub/i386-pc/command.lst"
    cp "$lists/modules.txt" "$view/multibootusb/grub/i386-pc/moddep.lst"
    umount "$view"
    mount /dev/mapper/ku-test-boot "$ROOT/boot"
    local v
    for v in "$V1" "$V2" 7.2.9+kali-amd64; do
        printf 'kernel %s\n' "$v" > "$ROOT/boot/vmlinuz-$v"
        printf 'initrd %s\n' "$v" > "$ROOT/boot/initrd.img-$v"
    done
    ln -s "vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    ln -s "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    printf '%s\n' "boot_fs_uuid = $STICK_BOOT_UUID" \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' \
        "disk_ptuuid = $STICK_PTUUID" "p1_fs_uuid = $STICK_SERIAL" \
        'root_device = /dev/mapper/kali--vg-root' > "$ROOT/etc/kernel-updater.conf"
    stub_system_tools
    mkstub systemd-detect-virt <<< 'exit 1'
    mkstub grub-script-check
    # Each write gets a stamp of its own for its backups, however fast the runs follow.
    export DATE_COUNT="$BATS_TEST_TMPDIR/date.count"
    printf '0\n' > "$DATE_COUNT"
    mkstub date <<'EOF'
n=$(( $(< "$DATE_COUNT") + 1 ))
printf '%s\n' "$n" > "$DATE_COUNT"
printf '20261112T0900%02dZ\n' "$n"
EOF
}

teardown() {
    ntfs_enabled || return 0
    unmount_under "$ROOT"
}

@test "The menu stage writes kali.cfg and grub.cfg to NTFS, and --rollback puts grub.cfg back" {
    local view backup="$ROOT/var/backups/kernel-updater/20261112T090001Z"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"info: wrote multibootusb/grub/kali.cfg"* ]]
    [[ "$stderr" == *"info: wrote multibootusb/grub/grub.cfg; the old one is kept as"* ]]
    # The stick's own lists served lint, so GRUB 2.02's did not stand in.
    [[ "$stderr" != *"GRUB 2.02's stand in"* ]]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$output$stderr" != */dev/loop* ]]
    [[ "$stderr" != *kali--vg-root* ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    view=$(mount_p1 ro "$ROOT")
    cmp "$FIXTURES/kali.expected.cfg" "$view/multibootusb/grub/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.after" "$view/multibootusb/grub/grub.cfg"
    [ -z "$(find "$view" -name '.*.ku-*')" ]
    umount "$view"
    cmp "$BATS_TEST_TMPDIR/grub.before" "$backup/grub.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    view=$(mount_p1 ro "$ROOT")
    cmp "$BATS_TEST_TMPDIR/grub.before" "$view/multibootusb/grub/grub.cfg"
    cmp "$FIXTURES/kali.expected.cfg" "$view/multibootusb/grub/kali.cfg"
    umount "$view"
    [ -d "$backup.rolled-back" ]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
}
