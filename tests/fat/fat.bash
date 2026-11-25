# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater FAT test helpers
#
# Loaded by tests/fat/*.bats, which build a synthetic stick in a loop file and mount real FAT:
# with KU_FAT=1 they run as root in the fat job of the tests workflow, and fail without root;
# without it they skip.
# -------------------------------------------------------

# The stick's synthetic identity: the MBR disk signature, partition 1's FAT serial, and the
# UUID of the ext4 filesystem on partition 2, which stands in for the unlocked /boot.
# shellcheck disable=SC2034 # read by the .bats files
STICK_PTUUID=5ca1ab1e STICK_SERIAL=5CA1-AB1E
STICK_BOOT_UUID=5ca1ab1e-0000-4000-8000-000000000b01

# The files fresh_partition writes on partition 1 that baseline.list names, but ldlinux.sys,
# which syslinux writes, and MultiBootUSB's grub.cfg, with CRLF line endings.
STICK_FILES=(boot/grub/config.cfg multibootusb/extlinux.cfg multibootusb/grub/core.img
    multibootusb/grub/i386-pc/command.lst multibootusb/grub/i386-pc/linux.mod
    multibootusb/grub/i386-pc/moddep.lst multibootusb/grub/lnxboot.img
    multibootusb/grub/load_iso.cfg multibootusb/grub/win.cfg multibootusb/ldlinux.c32
    multibootusb/syslinux.cfg)
STICK_GRUB_CFG=$'menuentry "Kali" {\r\n\tconfigfile /multibootusb/grub/kali.cfg\r\n}\r\n'

# Where FAT32 keeps the flags byte that marks a volume not cleanly unmounted, in its boot sector.
FAT32_FLAGS=65

# Return 0 when the tests may change this system: KU_FAT=1, as root.
fat_enabled() {
    [[ ${KU_FAT:-} == 1 && $(id -u) == 0 ]]
}

# Skip the test unless KU_FAT=1, and fail it when that is set but the tests do not run as
# root, so the job never passes without them. Call it first in setup().
fat_only() {
    [[ ${KU_FAT:-} == 1 ]] || skip "runs only in the fat job (KU_FAT=1, as root)"
    if [[ $(id -u) != 0 ]]; then
        printf 'KU_FAT=1 needs root: run the FAT tests with sudo\n' >&2
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

# Build the stick in a 128 MiB image: an MBR with the synthetic disk signature, partition 1 of
# 64 MiB for FAT32 (type 0x0c), enough clusters for FAT32 at one sector each, and partition 2
# with ext4 and the synthetic UUID. Attaches it with losetup --partscan and exports STICK_LOOP,
# the loop device, for the tests of the file.
make_stick() {
    STICK_IMAGE="$BATS_FILE_TMPDIR/stick.img"
    truncate -s 128M "$STICK_IMAGE"
    sfdisk --quiet "$STICK_IMAGE" << 'EOF'
label: dos
label-id: 0x5ca1ab1e
unit: sectors

start=2048, size=131072, type=c, bootable
start=133120, type=83
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

# Make partition 1 anew, as MultiBootUSB leaves it: FAT32 labelled BOOT with the synthetic
# serial, its boot menus, GRUB 2.06's normal.mod and lists, syslinux's files, and syslinux
# installed in multibootusb, which writes its boot sector and ldlinux.sys; and zero the MBR
# boot code, so each test starts from the same stick.
fresh_partition() {
    local dir name
    mkfs.vfat -F 32 -s 1 -n BOOT -i "${STICK_SERIAL//-/}" "${STICK_LOOP}p1" > /dev/null
    dir=$(mktemp -d "$BATS_TEST_TMPDIR/fresh.XXXXXXXX")
    mount -t vfat "${STICK_LOOP}p1" "$dir"
    mkdir -p "$dir/boot/grub" "$dir/multibootusb/grub/i386-pc"
    for name in "${STICK_FILES[@]}"; do
        printf '%s of the stick\r\n' "$name" > "$dir/$name"
    done
    printf '%s' "$STICK_GRUB_CFG" > "$dir/multibootusb/grub/grub.cfg"
    printf 'ELF\0GNU GRUB  version %%s\0%s\0normal\0' 2.06 \
        > "$dir/multibootusb/grub/i386-pc/normal.mod"
    umount "$dir"
    rmdir "$dir"
    syslinux --install --directory /multibootusb "${STICK_LOOP}p1"
    dd if=/dev/zero of="$STICK_LOOP" bs=440 count=1 conv=notrunc status=none
    sync
    settle "${STICK_LOOP}p1"
}

# Mount partition 1 with MODE, ro or rw, on a new directory under DIR and print that directory.
mount_p1() {
    local dir
    dir=$(mktemp -d "$2/view.XXXXXXXX")
    mount -t vfat -o "$1" "${STICK_LOOP}p1" "$dir"
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

# Print the flags byte of partition 1's FAT32 boot sector, as a decimal number.
fat_flags() {
    od -A n -t u1 -j "$FAT32_FLAGS" -N 1 "${STICK_LOOP}p1" | tr -d ' '
}

# Set the flags byte of partition 1's FAT32 boot sector to the decimal VALUE, as an unplug
# without an eject leaves it.
set_fat_flags() {
    # shellcheck disable=SC2059 # the format is the one escape made here
    printf "\\x$(printf '%02x' "$1")" |
        dd of="${STICK_LOOP}p1" bs=1 seek="$FAT32_FLAGS" conv=notrunc status=none
    sync
}

# Print the SHA-256 of all of partition 1, to show that a run left it as it was.
p1_sum() {
    sync
    sha256sum < "${STICK_LOOP}p1" | cut -c 1-64
}

# Print the byte at OFFSET of FILE as a decimal number.
byte_at() {
    od -A n -t u1 -j "$2" -N 1 "$1" | tr -d ' '
}

# Set the byte at OFFSET of FILE to the decimal VALUE.
set_byte() {
    # shellcheck disable=SC2059 # the format is the one escape made here
    printf "\x$(printf '%02x' "$3")" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
    sync
}

# Print the offset in FILE, a FAT32 or FAT16 volume, of the byte of the FAT's entry 1 that holds
# its clean-shutdown bit: bit 27 of a FAT32 entry, bit 15 of a FAT16 one, as the bit 3 or 7 of
# that byte.
fat_clean_byte() {
    local bps rsv fatsz16
    bps=$(( $(byte_at "$1" 11) + 256 * $(byte_at "$1" 12) ))
    rsv=$(( $(byte_at "$1" 14) + 256 * $(byte_at "$1" 15) ))
    fatsz16=$(( $(byte_at "$1" 22) + 256 * $(byte_at "$1" 23) ))
    if (( fatsz16 == 0 )); then
        printf '%s\n' $(( rsv * bps + 7 ))
    else
        printf '%s\n' $(( rsv * bps + 3 ))
    fi
}

# Clear the clean-shutdown bit of FILE's FAT, as Windows does while it uses the volume.
clear_clean_bit() {
    local at mask=8
    at=$(fat_clean_byte "$1")
    [[ $(byte_at "$1" 22)$(byte_at "$1" 23) == 00 ]] || mask=128
    set_byte "$1" "$at" $(( $(byte_at "$1" "$at") & ~mask & 255 ))
}

# Return 0 when fsck.vfat finds nothing to repair on FILE, and print what it found otherwise.
fsck_clean() {
    local out
    if ! out=$(fsck.vfat -n "$1" 2>&1); then
        printf 'fsck.vfat -n %s:\n%s\n' "${1##*/}" "$out" >&2
        return 1
    fi
}

# Print the SHA-256 of FILE.
sum_of() {
    sha256sum < "$1" | cut -c 1-64
}
