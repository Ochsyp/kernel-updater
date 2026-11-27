# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater NTFS test helpers
#
# Loaded by tests/ntfs/*.bats, which build a synthetic stick in a loop file and mount real NTFS:
# with KU_NTFS=1 they run as root in CI's ci/system stage, and fail without root;
# without it they skip.
# -------------------------------------------------------

# The stick's synthetic identity: the MBR disk signature, partition 1's NTFS serial, and the
# UUID of the ext4 filesystem on partition 2, which stands in for the unlocked /boot.
# shellcheck disable=SC2034 # read by the .bats files
STICK_PTUUID=5ca1ab1e STICK_SERIAL=5CA1AB1E00000001
STICK_BOOT_UUID=5ca1ab1e-0000-4000-8000-000000000b01

# The files fresh_partition writes on partition 1 that baseline.list names, and MultiBootUSB's
# grub.cfg, with CRLF line endings.
STICK_FILES=(boot/grub/config.cfg multibootusb/extlinux.cfg multibootusb/grub/core.img
    multibootusb/grub/i386-pc/command.lst multibootusb/grub/i386-pc/linux.mod
    multibootusb/grub/i386-pc/moddep.lst multibootusb/grub/lnxboot.img
    multibootusb/grub/load_iso.cfg multibootusb/grub/win.cfg multibootusb/ldlinux.c32
    multibootusb/ldlinux.sys multibootusb/syslinux.cfg)
STICK_GRUB_CFG=$'menuentry "Kali" {\r\n\tconfigfile /multibootusb/grub/kali.cfg\r\n}\r\n'

# Return 0 when the tests may change this system: KU_NTFS=1, as root.
ntfs_enabled() {
    [[ ${KU_NTFS:-} == 1 && $(id -u) == 0 ]]
}

# Skip the test unless KU_NTFS=1, and fail it when that is set but the tests do not run as
# root, so the job never passes without them. Call it first in setup().
ntfs_only() {
    [[ ${KU_NTFS:-} == 1 ]] || skip "runs only in CI's system stage (KU_NTFS=1, as root)"
    if [[ $(id -u) != 0 ]]; then
        printf 'KU_NTFS=1 needs root: run the NTFS tests with sudo\n' >&2
        return 1
    fi
}

# Wait until udev has handled the stick's devices, so that lsblk shows what they hold.
settle() {
    if command -v udevadm > /dev/null; then
        udevadm trigger --action=change "$@" 2> /dev/null || true
        udevadm settle --timeout=30 || true
    fi
}

# Build the stick in a 64 MiB image: an MBR with the synthetic disk signature, partition 1 for
# NTFS (type 7) and partition 2 with ext4 and the synthetic UUID. Attaches it with losetup
# --partscan and exports STICK_LOOP, the loop device, for the tests of the file.
make_stick() {
    STICK_IMAGE="$BATS_FILE_TMPDIR/stick.img"
    truncate -s 64M "$STICK_IMAGE"
    sfdisk --quiet "$STICK_IMAGE" << 'EOF'
label: dos
label-id: 0x5ca1ab1e
unit: sectors

start=2048, size=40960, type=7
start=43008, type=83
EOF
    STICK_LOOP=$(losetup --find --show --partscan "$STICK_IMAGE")
    export STICK_IMAGE STICK_LOOP
    settle "$STICK_LOOP"
    local tries=0
    until [[ -b ${STICK_LOOP}p2 ]] || (( ++tries > 50 )); do
        sleep 0.1
    done
    mkfs.ext4 -q -F -U "$STICK_BOOT_UUID" "${STICK_LOOP}p2"
}

# Unmount whatever is mounted from the stick, detach its loop device and remove its image.
remove_stick() {
    local part target
    [[ -n ${STICK_LOOP:-} ]] || return 0
    for part in "${STICK_LOOP}p1" "${STICK_LOOP}p2"; do
        while target=$(findmnt -n -r -o TARGET --source "$part" | head -n 1) &&
            [[ -n $target ]]; do
            umount "$target" || umount -l "$target" || break
        done
    done
    losetup --detach "$STICK_LOOP"
    rm -f "$STICK_IMAGE"
}

# Make partition 1 anew, as MultiBootUSB leaves it: NTFS labelled BOOT with the synthetic
# serial, its boot menus, GRUB 2.06's normal.mod and lists, syslinux's files; and zero the MBR
# boot code, so each test starts from the same stick.
fresh_partition() {
    local dir name
    mkntfs --fast --quiet --label BOOT --partition-start 2048 --sectors-per-track 63 \
        --heads 255 "${STICK_LOOP}p1"
    ntfslabel --new-serial="$STICK_SERIAL" "${STICK_LOOP}p1"
    dir=$(mktemp -d "$BATS_TEST_TMPDIR/fresh.XXXXXXXX")
    mount -t ntfs3 "${STICK_LOOP}p1" "$dir"
    mkdir -p "$dir/boot/grub" "$dir/multibootusb/grub/i386-pc"
    for name in "${STICK_FILES[@]}"; do
        printf '%s of the stick\r\n' "$name" > "$dir/$name"
    done
    printf '%s' "$STICK_GRUB_CFG" > "$dir/multibootusb/grub/grub.cfg"
    printf 'ELF\0GNU GRUB  version %%s\0%s\0normal\0' 2.06 \
        > "$dir/multibootusb/grub/i386-pc/normal.mod"
    umount "$dir"
    rmdir "$dir"
    dd if=/dev/zero of="$STICK_LOOP" bs=440 count=1 conv=notrunc status=none
    sync
    settle "${STICK_LOOP}p1"
}

# Mount partition 1 with MODE, ro or rw, on a new directory under DIR and print that directory.
mount_p1() {
    local dir
    dir=$(mktemp -d "$2/view.XXXXXXXX")
    mount -t ntfs3 -o "$1" "${STICK_LOOP}p1" "$dir"
    printf '%s\n' "$dir"
}

# Unmount every mount under DIR, the deepest first.
unmount_under() {
    local targets target
    targets=$(findmnt -r -n -o TARGET | grep -F -e "$1/" | sort -r) || return 0
    while IFS= read -r target; do
        umount "$target" || umount -l "$target"
    done <<< "$targets"
}
