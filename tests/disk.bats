#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater partition 1 checks
#
# Runs the partition-1 functions of lib/kernel-updater/disk.sh as a command runs them, with stub
# lsblk, blkid, findmnt, mount, umount, stat, ntfs-3g.probe and systemd-detect-virt: finding
# partition 1 from /boot whichever disk name the stick gets, refusing no disk or two, the
# identity check, the order and options of mounts, the probe before a read-write one, mounts
# that are there, beside one another, or whose files other users can change, p1_path, how the
# deploy mode falls back to export, and the root it leaves for a plan's reads.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
# shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
load helpers

PTUUID=5ca1ab1e
SERIAL=5CA1AB1E00000001
BOOT_UUID=5ca1ab1e-0000-4000-8000-000000000b01
# What the tests print of the deploy mode: mode|why|how|writable.
SHOW_DEPLOY='printf "%s|%s|%s|%s\n" "$KU_DK_DEPLOY" "$KU_DK_DEPLOY_WHY" "$KU_DK_HOW"'
SHOW_DEPLOY+=' "$KU_DK_WRITABLE"'
# Why auto and direct export in a VM.
IN_VM="this system runs in a VM, where Windows may have partition 1 mounted on the host, so it"
IN_VM+=" never writes partition 1 itself"
# Why a writer or a plan takes no mount whose files other users can change.
SHARED="partition 1 is mounted where users other than root can change its files, as a desktop"
SHARED+=" mounts it for its user: unmount it there, as its eject does, and run again"
# What a plan does when that leaves it no root: say so, and exit 3.
RESOLVE='ku_deploy_resolve || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }'

# The stick as sdb, a config that names it, and stubs that answer for it: partition 1 mounts
# with ntfs3, nothing is mounted there yet, and this is no VM.
setup() {
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    # The kernel has an ntfs3 driver.
    printf 'nodev\tsysfs\n\text4\n\tntfs3\n' > "$ROOT/proc/filesystems"
    write_config
    stick_on sdb
    # lsblk answers from STICK_TREE (the inverse tree under /boot), STICK_PARTS (the disk's
    # partitions, raw) and STICK_PTUUID.
    mkstub lsblk <<'EOF'
case " $* " in
    *" -s "*) printf '%s\n' "$STICK_TREE" ;;
    *" -d "*) printf '%s\n' "${STICK_PTUUID-}" ;;
    *) printf '%s\n' "$STICK_PARTS" ;;
esac
EOF
    # blkid reads from the devices what BLKID_PTUUID, BLKID_TYPE and BLKID_UUID say.
    mkstub blkid <<'EOF'
case $3 in
    PTUUID) value=${BLKID_PTUUID:-} ;;
    TYPE) value=${BLKID_TYPE:-} ;;
    *) value=${BLKID_UUID:-} ;;
esac
[[ -n $value ]] || exit 2
printf '%s\n' "$value"
EOF
    # findmnt prints /boot's mount (BOOT_MOUNT), partition 1's mounts (P1_MOUNTS, lines of
    # TARGET FSROOT OPTIONS, then those the mount stub made, then P1_JOINED, a desktop's mount
    # made meanwhile, while one of those is there), only their targets with -o TARGET, and the
    # options of the mount that holds a path (TARGET_OPTS). Any other mount point is one while
    # P1_PATH_MOUNTED is 1, of the share sf_BOOT, which is mounted on p1_path and on
    # P1_PATH_JOINED, when that is set, as VirtualBox's automount mounts it; with
    # P1_PATH_STACKED set it lies on systemd's automount there, which findmnt lists first.
    export P1_MOUNTS="" P1_JOINED="" TARGET_OPTS="rw,nosuid,nodev,noexec,relatime"
    export P1_PATH_MOUNTED=0 P1_PATH_JOINED="" P1_PATH_STACKED=""
    export MOUNTED="$BATS_TEST_TMPDIR/mounted"
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*"/boot ") out=$BOOT_MOUNT ;;
    *" -o SOURCE --mountpoint "*)
        out=${P1_PATH_STACKED:+systemd-1$'\n'}sf_BOOT
        (( P1_PATH_MOUNTED )) || out=""
        ;;
    *" --mountpoint "*) out=${*: -1}; (( P1_PATH_MOUNTED )) || out="" ;;
    *" --source sf_BOOT "*)
        out=$KU_ROOT/media/sf_BOOT${P1_PATH_JOINED:+$'\n'$P1_PATH_JOINED}
        ;;
    *" --source "*)
        out=$P1_MOUNTS
        if [[ -s $MOUNTED ]]; then
            out+=${out:+$'\n'}$(< "$MOUNTED")
            out+=${P1_JOINED:+$'\n'$P1_JOINED}
        fi
        [[ " $* " != *" -o TARGET "* ]] || out=$(cut -d ' ' -f 1 <<< "$out")
        ;;
    *) out=$TARGET_OPTS ;;
esac
[[ -n $out ]] || exit 1
printf '%s\n' "$out"
EOF
    # mount succeeds, only inside the test's /run, for the types in MOUNT_TYPES, and fails a
    # read-write mount with MOUNT_RW_FAIL=1. Once mounted, partition 1 shows P1_GRUB_CFG, when
    # that is set, as its grub.cfg, and findmnt lists the mount, until the unmount takes both
    # away again. UMOUNT_FAIL=plain fails a plain unmount, as on a busy mount.
    export MOUNT_TYPES=ntfs3
    mkstub mount <<'EOF'
target=${*: -1}
[[ $target == "$KU_ROOT/run"/* ]] || exit 32
[[ " $MOUNT_TYPES " == *" $2 "* ]] || exit 32
[[ -z ${MOUNT_RW_FAIL:-} || $4 != *,rw* ]] || exit 32
if [[ -n ${P1_GRUB_CFG:-} ]]; then
    mkdir -p "$target/multibootusb/grub"
    cp "$P1_GRUB_CFG" "$target/multibootusb/grub/grub.cfg"
fi
flag=ro
[[ $4 != *,rw* ]] || flag=rw
printf '%s / %s,nosuid,nodev,noexec\n' "${target// /\\x20}" "$flag" >> "$MOUNTED"
EOF
    mkstub umount <<'EOF'
target=${*: -1}
[[ $target == "$KU_ROOT/run"/* ]] || exit 32
[[ ${UMOUNT_FAIL:-} != plain || $1 == -l ]] || exit 32
if [[ -e $target/multibootusb ]]; then
    rm -f "$target/multibootusb/grub/grub.cfg"
    rmdir "$target/multibootusb/grub" "$target/multibootusb"
fi
if [[ -e $MOUNTED ]]; then
    { grep -v -F -e "${target// /\\x20} " "$MOUNTED" || true; } > "$MOUNTED.left"
    cat "$MOUNTED.left" > "$MOUNTED"
    rm -f "$MOUNTED.left"
fi
EOF
    # ntfs-3g.probe finds the volume as PROBE_STATUS says: 0, safe to mount read-write.
    export PROBE_STATUS=0
    mkstub ntfs-3g.probe <<'EOF'
exit "$PROBE_STATUS"
EOF
    # VIRT_STATUS is systemd-detect-virt's status: 0 in a VM, 1 on bare metal.
    export VIRT_STATUS=1
    mkstub systemd-detect-virt <<'EOF'
exit "$VIRT_STATUS"
EOF
    # Not root, so the config file's owner is not checked. Root owns every directory, with the
    # owner and mode RUN_STAT gives, but those under USER_TREE, which a user owns, as a
    # desktop's mount for its user has them, and the root of a private mount, whose owner and
    # mode P1_STAT gives when set.
    mkstub id <<< 'echo 1000'
    export RUN_STAT="0 755" USER_TREE="" P1_STAT=""
    mkstub stat <<'EOF'
if [[ -n $USER_TREE && ${*: -1} == "$USER_TREE"* ]]; then
    echo "1000 755"
elif [[ -n $P1_STAT && ${*: -1} == */p1 ]]; then
    echo "$P1_STAT"
else
    echo "$RUN_STAT"
fi
EOF
}

# Write the config file: the stick's identity, then any further LINES.
write_config() {
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$PTUUID" "$SERIAL" \
        > "$ROOT/etc/kernel-updater.conf"
    if (( $# )); then
        printf '%s\n' "$@" >> "$ROOT/etc/kernel-updater.conf"
    fi
}

# Describe the stick as the disk /dev/NAME, with BOOT on partition 1, a FAT partition 2 and
# /boot in the LUKS container on partition 3, which is open as boot_crypt.
stick_on() {
    local disk=/dev/$1
    export BOOT_MOUNT="/dev/mapper/boot_crypt ext4 $BOOT_UUID" STICK_PTUUID=$PTUUID
    export STICK_TREE="/dev/mapper/boot_crypt crypt"$'\n'"${disk}3 part"$'\n'"$disk disk"
    STICK_PARTS=$(printf '%s %s %s %s\n' "$disk" "" "" "" "${disk}1" 1 ntfs "$SERIAL" \
        "${disk}2" 2 vfat 5CA1-AB1E "${disk}3" 3 crypto_LUKS \
        5ca1ab1e-0000-4000-8000-000000000c01 /dev/mapper/boot_crypt "" ext4 "$BOOT_UUID")
    export STICK_PARTS
}

# Make p1_path, /media/sf_BOOT, a mounted share that holds MultiBootUSB's grub.cfg, and have
# partition 1 show the same grub.cfg once it is mounted, unless DIFFERENT is given.
share_p1() {
    local share="$ROOT/media/sf_BOOT"
    mkdir -p "$share/multibootusb/grub"
    printf 'menuentry "Kali" {\r\n}\r\n' > "$share/multibootusb/grub/grub.cfg"
    export P1_PATH_MOUNTED=1 P1_GRUB_CFG="$BATS_TEST_TMPDIR/device-grub.cfg"
    cp "$share/multibootusb/grub/grub.cfg" "$P1_GRUB_CFG"
    if (( $# )); then
        printf '%s\r\n' "$1" >> "$P1_GRUB_CFG"
    fi
}

# Fail unless the last run printed no identifier and no device name.
private_output() {
    local all="${output,,}${stderr,,}"
    [[ "$all" != *5ca1ab1e* && "$all" != */dev/sd* && "$all" != */dev/mapper* ]]
}

# Print the mount and umount calls of the stub log, without the private directory's random
# name.
mount_calls() {
    grep -E '^u?mount ' "$STUB_LOG" | sed -E 's#/run/kernel-updater\.[^/ ]+/#/run/X/#g'
}

@test "Partition 1 is found from /boot through the crypt mapping, as sda or as sdb" {
    local name
    for name in sda sdb; do
        stick_on "$name"
        run_ku_lib 'ku_disk_find
            printf "%s\n" "$KU_DK_DISK" "$KU_DK_PART" "$KU_DK_PTUUID" "$KU_DK_FSTYPE" \
                "$KU_DK_UUID"'
        [ "$status" -eq 0 ]
        [ "$output" = "$(printf '%s\n' "/dev/$name" "/dev/${name}1" "$PTUUID" ntfs "$SERIAL")" ]
    done
    # It walks up from the source findmnt names, and asks blkid nothing lsblk knows.
    grep -q -x -F -- "lsblk$(printf ' %q' -s -n -r -o PATH,TYPE -- /dev/mapper/boot_crypt)" \
        "$STUB_LOG"
    grep -q -x -F -- "lsblk$(printf ' %q' -n -r -o PATH,PARTN,FSTYPE,UUID -- /dev/sdb)" \
        "$STUB_LOG"
    grep -q -x -F -- "lsblk$(printf ' %q' -d -n -r -o PTUUID -- /dev/sdb)" "$STUB_LOG"
    refute_line_match '^blkid' "$STUB_LOG"
}

@test "A dm path from findmnt works as well, and a disk reached twice counts once" {
    export BOOT_MOUNT="/dev/dm-1 ext4 $BOOT_UUID"
    # Two partitions of sdb under one volume group, which holds /boot.
    export STICK_TREE=$'/dev/dm-1 lvm\n/dev/sdb3 part\n/dev/sdb disk\n/dev/sdb4 part\n/dev/sdb disk'
    run_ku_lib 'ku_disk_find; printf "%s\n" "$KU_DK_PART"'
    [ "$status" -eq 0 ]
    [ "$output" = /dev/sdb1 ]
    grep -q -x -F -- "lsblk$(printf ' %q' -s -n -r -o PATH,TYPE -- /dev/dm-1)" "$STUB_LOG"
}

@test "blkid reads the PTUUID, type and UUID that lsblk leaves empty without udev" {
    export STICK_PTUUID="" BLKID_PTUUID=$PTUUID BLKID_TYPE=ntfs BLKID_UUID=$SERIAL
    STICK_PARTS=$(printf '%s %s %s %s\n' /dev/sdb "" "" "" /dev/sdb1 1 "" "" /dev/sdb2 2 "" "")
    export STICK_PARTS
    run_ku_lib 'ku_disk_find
        printf "%s\n" "$KU_DK_PART" "$KU_DK_PTUUID" "$KU_DK_FSTYPE" "$KU_DK_UUID"'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' /dev/sdb1 "$PTUUID" ntfs "$SERIAL")" ]
    grep -q -x -F -- "blkid$(printf ' %q' -p -s PTUUID -o value -- /dev/sdb)" "$STUB_LOG"
    grep -q -x -F -- "blkid$(printf ' %q' -p -s TYPE -o value -- /dev/sdb1)" "$STUB_LOG"
    grep -q -x -F -- "blkid$(printf ' %q' -p -s UUID -o value -- /dev/sdb1)" "$STUB_LOG"
}

@test "No disk, two disks, no partition 1 and no block device under /boot are refused" {
    local find='ku_disk_find || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }'
    export STICK_TREE=$'/dev/mapper/boot_crypt crypt\n/dev/loop9p3 part'
    run_ku_lib "$find"
    [ "$status" -eq 3 ]
    [ "$output" = "lsblk finds no disk under the filesystem at /boot" ]
    export STICK_TREE=$'/dev/dm-1 lvm\n/dev/sda3 part\n/dev/sda disk\n/dev/sdb2 part\n/dev/sdb disk'
    run_ku_lib "$find"
    [ "$status" -eq 3 ]
    [ "$output" = "the filesystem at /boot spans 2 disks, so the stick is unclear" ]
    stick_on sdb
    STICK_PARTS=$(printf '%s %s %s %s\n' /dev/sdb "" "" "" /dev/sdb2 2 vfat 5CA1-AB1E)
    run_ku_lib "$find"
    [ "$status" -eq 3 ]
    [ "$output" = "the disk that holds /boot has no partition 1" ]
    export BOOT_MOUNT="tmpfs tmpfs"
    run_ku_lib "$find"
    [ "$output" = "the filesystem at /boot is on no block device" ]
    export BOOT_MOUNT=""
    run_ku_lib "$find"
    [ "$output" = "/boot is not mounted" ]
}

@test "The identity matches in either case, and a writer exits 66 when partition 1 is not found" {
    write_config
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "${PTUUID^^}" "${SERIAL,,}" \
        > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib 'ku_disk_find; ku_disk_identity; printf "%s %s\n" "$KU_DK_DISK_ID" "$KU_DK_P1_ID"
        ku_p1_locate'
    [ "$status" -eq 0 ]
    [ "$output" = "match match" ]
    export BOOT_MOUNT=""
    run_ku_lib ku_p1_locate
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"error: cannot find the stick's partition 1: /boot is not mounted"* ]]
}

@test "A writer exits 78 naming the disk or partition 1 that differs, never a value" {
    write_config
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' 5ca1ab1e-0000-4000-8000-000000000d01 "$SERIAL" \
        > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib ku_p1_locate
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"error: the disk that holds /boot is not the one disk_ptuuid names;"* ]]
    private_output
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$PTUUID" 5CA1AB1E00000002 \
        > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib ku_p1_locate
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"error: partition 1 of the disk that holds /boot is not the NTFS"* ]]
    private_output
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' 5ca1ab1e-0000-4000-8000-000000000d01 \
        5CA1AB1E00000002 > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib ku_p1_locate
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"neither the disk that holds /boot nor its partition 1 is the one"* ]]
    private_output
    # Partition 1 must be NTFS too, whatever its UUID.
    write_config
    STICK_PARTS=$(printf '%s %s %s %s\n' /dev/sdb "" "" "" /dev/sdb1 1 exfat "$SERIAL")
    export STICK_PARTS
    run_ku_lib ku_p1_locate
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"partition 1 of the disk that holds /boot is not the NTFS filesystem"* ]]
}

@test "A writer exits 78 while disk_ptuuid or p1_fs_uuid is not set, saying how to set them" {
    printf 'disk_ptuuid = %s\n' "$PTUUID" > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib 'ku_disk_find; ku_disk_identity || printf "%s %s %s\n" "$?" "$KU_DK_DISK_ID" \
        "$KU_DK_P1_ID"; ku_p1_locate'
    [ "$status" -eq 78 ]
    [ "$output" = "2 match unset" ]
    [[ "$stderr" == *"the stick cannot be told apart: set disk_ptuuid and p1_fs_uuid"* ]]
    [[ "$stderr" == *"'lsblk -o NAME,LABEL,PTUUID,UUID' prints as root"* ]]
    # KU_P1_DIR takes the stick's place, so there is nothing to tell apart.
    : > "$ROOT/etc/kernel-updater.conf"
    mkdir "$BATS_TEST_TMPDIR/p1"
    export KU_P1_DIR="$BATS_TEST_TMPDIR/p1"
    run_ku_lib ku_p1_locate
    [ "$status" -eq 0 ]
}

@test "A mount of its own tries ntfs3, then ntfs-3g with norecover, never forced or recovering" {
    local expected
    export MOUNT_TYPES=ntfs-3g
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s|%s\n" "$KU_DK_HOW" "$KU_DK_ROOT"'
    [ "$status" -eq 0 ]
    [[ "$output" == "private|$ROOT/run/kernel-updater."*/p1 ]]
    expected="mount$(printf ' %q' -t ntfs3 -o nosuid,nodev,noexec,ro /dev/sdb1) $ROOT/run/X/p1"
    expected+=$'\n'"mount$(printf ' %q' -t ntfs-3g -o nosuid,nodev,noexec,ro,norecover \
        /dev/sdb1) $ROOT/run/X/p1"$'\n'"umount $ROOT/run/X/p1"
    [ "$(mount_calls)" = "$expected" ]
    refute_line_match 'force|remove_hiberfile|[ ,\\]recover' "$STUB_LOG"
    # A read-only mount needs no probe.
    refute_line_match '^ntfs-3g\.probe' "$STUB_LOG"
    # The exit trap removed the mount and both directories.
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "A read-write mount of its own waits for the probe and takes ntfs3 alone" {
    local show='ku_disk_find; ku_p1_open rw || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }
        printf "%s|%s\n" "$KU_DK_HOW" "$KU_DK_WRITABLE"'
    run_ku_lib "$show"
    [ "$status" -eq 0 ]
    [ "$output" = "private|1" ]
    # The probe comes first, then the one read-write mount.
    [ "$(grep -E '^(ntfs-3g\.probe|mount) ' "$STUB_LOG" | head -n 1)" = \
        "ntfs-3g.probe --readwrite /dev/sdb1" ]
    [ "$(grep -c '^mount ' "$STUB_LOG")" -eq 1 ]
    grep -q "^mount -t ntfs3 -o nosuid\\\\,nodev\\\\,noexec\\\\,rw /dev/sdb1 " "$STUB_LOG"
    # ntfs3 refuses a volume marked dirty, which ntfs-3g would mount read-write all the same,
    # so no other type is tried.
    export MOUNT_TYPES=ntfs-3g
    : > "$STUB_LOG"
    run_ku_lib "$show"
    [ "$status" -eq 3 ]
    [ "$output" = "partition 1 does not mount read-write with ntfs3, as when the volume is \
marked dirty: let Windows check the stick, then run again" ]
    refute_line_match '^mount -t ntfs-3g' "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    # A kernel without ntfs3 cannot write it at all, and the message says so.
    printf 'nodev\tsysfs\n\text4\n\tfuseblk\n' > "$ROOT/proc/filesystems"
    run_ku_lib "$show"
    [ "$status" -eq 3 ]
    [ "$output" = "partition 1 does not mount read-write: this kernel has no ntfs3 driver, which \
writing it needs, as ntfs-3g would write a volume marked dirty all the same" ]
}

@test "A volume the probe finds hibernated or unclean is mounted read-only only, and exported" {
    local code why
    for code in 14 15 16; do
        export PROBE_STATUS=$code
        : > "$STUB_LOG"
        run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
        [ "$status" -eq 0 ]
        case $code in
            14) why="Windows left partition 1 hibernated, or kept it in its cache for Fast"
                why+=" Startup: eject the stick in Windows, or shut Windows down fully, before"
                why+=" you boot from it" ;;
            15) why="Windows did not unmount partition 1 cleanly: eject the stick in Windows, or"
                why+=" let Windows check it, before you boot from it" ;;
            *) why="ntfs-3g.probe finds partition 1 unsafe to write (exit 16)" ;;
        esac
        [ "$output" = "export|$why|private|0" ]
        [[ "$stderr" == *"warning: deploy = auto cannot write partition 1: $why; the files go to"* ]]
        grep -q -x -F -- "ntfs-3g.probe --readwrite /dev/sdb1" "$STUB_LOG"
        # ntfs3 would replay and clear the log Windows left, so no read-write mount is tried.
        refute_line_match ',rw' "$STUB_LOG"
        private_output
    done
}

@test "Without ntfs-3g.probe partition 1 counts as unsafe to write, and is exported" {
    export KU_P1_PROBE=ku-test-no-such-probe
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|ntfs-3g.probe, from the package ntfs-3g, is not installed, so whether \
Windows left partition 1 safe to write cannot be checked|private|0" ]
    refute_line_match ',rw' "$STUB_LOG"
}

@test "A failed mount and a busy one leave nothing in /run, and /run must be root's alone" {
    export MOUNT_TYPES=""
    run_ku_lib 'ku_disk_find; ku_p1_open ro || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }'
    [ "$status" -eq 3 ]
    [ "$output" = "partition 1 does not mount read-only with ntfs3, ntfs-3g" ]
    [ -z "$(ls -A "$ROOT/run")" ]
    export MOUNT_TYPES=ntfs3 UMOUNT_FAIL=plain
    : > "$STUB_LOG"
    run_ku_lib 'ku_disk_find; ku_p1_open ro; ku_p1_close'
    [ "$status" -eq 0 ]
    grep -q "^umount -l $ROOT/run/kernel-updater\.[^/]*/p1\$" "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    export RUN_STAT="1000 755"
    : > "$STUB_LOG"
    run_ku_lib 'ku_disk_find; ku_p1_open ro || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }'
    [ "$status" -eq 3 ]
    [ "$output" = "/run is not a directory whose entries only root can rename" ]
    refute_line_match '^u?mount ' "$STUB_LOG"
}

@test "A mount that is there serves a reader, and a writer only while root alone can write it" {
    local show='printf "%s|%s|%s|%s\n" "$KU_DK_HOW" "$KU_DK_ROOT" "$KU_DK_WRITABLE"'
    show+=' "$KU_DK_PROBLEM"'
    mkdir -p "$ROOT/media/BOOT STICK" "$ROOT/media/BOOT" "$ROOT/mnt/p1"
    export P1_MOUNTS="${ROOT// /\\x20}/media/BOOT\\x20STICK / rw,nosuid,nodev,relatime"
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s|%s\n" "$KU_DK_HOW" "$KU_DK_ROOT"
        ku_p1_open rw; '"$show"
    [ "$status" -eq 0 ]
    [ "$output" = "mount|$ROOT/media/BOOT STICK"$'\n'"mount|$ROOT/media/BOOT STICK|1|" ]
    refute_line_match '^mount ' "$STUB_LOG"
    # A desktop mounts it for its user, who could swap a file for a symlink while root writes.
    export USER_TREE="$ROOT/media"
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s\n" "$KU_DK_HOW"; ku_p1_open rw; '"$show"
    [ "$status" -eq 0 ]
    [ "$output" = $'mount\n'"mount|$ROOT/media/BOOT STICK|0|$SHARED" ]
    refute_line_match '^mount ' "$STUB_LOG"
    # Root's own mount beside it shares the same files, so it serves no writer either.
    export P1_MOUNTS="$ROOT/mnt/p1 / rw,relatime"$'\n'"${P1_MOUNTS}"
    run_ku_lib 'ku_disk_find; ku_p1_open rw; '"$show"
    [ "$output" = "mount|$ROOT/mnt/p1|0|$SHARED" ]
    # Read-only, it serves a reader but not a writer, and no second mount is tried.
    export USER_TREE="" P1_MOUNTS="$ROOT/media/BOOT / ro,nosuid,nodev,relatime" TARGET_OPTS=ro
    run_ku_lib 'ku_disk_find; ku_p1_open rw; '"$show"
    [ "$status" -eq 0 ]
    [ "$output" = "mount|$ROOT/media/BOOT|0|partition 1 is mounted read-only" ]
    refute_line_match '^mount ' "$STUB_LOG"
    # A bind mount of a directory on partition 1 is not its root.
    export P1_MOUNTS='/srv/grub /multibootusb/grub rw,relatime' TARGET_OPTS=rw
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s\n" "$KU_DK_HOW"'
    [ "$output" = private ]
}

@test "A plan reads only where root alone can change partition 1, and else has no root" {
    mkdir -p "$ROOT/media/user/BOOT" "$ROOT/mnt/p1"
    # A desktop has partition 1 mounted for its user: it is neither written nor read for a plan,
    # and nothing says that the files go to output_dir, since none can be exported either.
    export P1_MOUNTS="$ROOT/media/user/BOOT / rw,nosuid,nodev,relatime" USER_TREE="$ROOT/media/user"
    run_ku_lib "$RESOLVE"
    [ "$status" -eq 3 ]
    [ "$output" = "$SHARED" ]
    [[ "$stderr" != *output_dir* ]]
    refute_line_match '^mount ' "$STUB_LOG"
    # A read-only mount of root's beside the desktop's shares its files all the same.
    export P1_MOUNTS="$ROOT/mnt/p1 / ro,relatime"$'\n'"$P1_MOUNTS" TARGET_OPTS=ro
    run_ku_lib "$RESOLVE"
    [ "$status" -eq 3 ]
    [ "$output" = "$SHARED" ]
    # Alone, root's read-only mount serves an export's reads.
    export P1_MOUNTS="$ROOT/mnt/p1 / ro,relatime" USER_TREE=""
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|partition 1 is mounted read-only|mount|0" ]
    private_output
}

@test "A mount of its own that a desktop's mount joins, or whose root a user owns, is given up" {
    # The desktop mounts partition 1 while the tool mounts it, so both share one filesystem.
    export P1_JOINED="$ROOT/media/user/BOOT / rw,relatime"
    run_ku_lib "$RESOLVE"
    [ "$status" -eq 3 ]
    [ "$output" = "$SHARED" ]
    # Both the read-write mount and the read-only one for the export were tried and removed.
    [ "$(grep -c '^mount ' "$STUB_LOG")" -eq 2 ]
    [ "$(grep -c '^umount ' "$STUB_LOG")" -eq 2 ]
    [ -z "$(ls -A "$ROOT/run")" ]
    # The root of the mount shows a user as its owner, as after joining the desktop's mount.
    export P1_JOINED="" P1_STAT="1000 755"
    run_ku_lib "$RESOLVE"
    [ "$status" -eq 3 ]
    [ "$output" = "$SHARED" ]
    [ -z "$(ls -A "$ROOT/run")" ]
    # A reader, which only hashes, keeps its mount all the same.
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s\n" "$KU_DK_HOW"'
    [ "$output" = private ]
}

@test "deploy = auto exports in a VM and writes directly elsewhere" {
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "direct||private|1" ]
    grep -q -x -F -- "ntfs-3g.probe --readwrite /dev/sdb1" "$STUB_LOG"
    grep -q "^mount -t ntfs3 -o nosuid\\\\,nodev\\\\,noexec\\\\,rw /dev/sdb1 " "$STUB_LOG"
    export VIRT_STATUS=0
    : > "$STUB_LOG"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|$IN_VM|private|0" ]
    [[ "$stderr" == *"info: deploy = auto picks export: this system runs in a VM, where"* ]]
    # An export only reads partition 1.
    refute_line_match ',rw' "$STUB_LOG"
    private_output
}

@test "deploy = direct exports in a VM too, and never mounts partition 1 read-write there" {
    write_config "deploy = direct"
    export VIRT_STATUS=0
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|$IN_VM|private|0" ]
    [[ "$stderr" == *"warning: deploy = direct cannot write partition 1: this system runs in"* ]]
    [[ "$stderr" == *"the files go to output_dir for Windows to copy instead"* ]]
    refute_line_match ',rw' "$STUB_LOG"
    grep -q "^mount -t ntfs3 -o nosuid\\\\,nodev\\\\,noexec\\\\,ro /dev/sdb1 " "$STUB_LOG"
    private_output
}

@test "Without systemd-detect-virt the system counts as no VM" {
    rm "$STUB_BIN/systemd-detect-virt"
    # shellcheck disable=SC2016 # the inner script expands its own arguments
    run env PATH="$STUB_BIN" "$BASH" -c '. "$1"; . "$2"; ku_in_vm' _ \
        "$REPO_DIR/lib/kernel-updater/common.sh" "$REPO_DIR/lib/kernel-updater/disk.sh"
    [ "$status" -eq 1 ]
    export VIRT_STATUS=0
    mkstub systemd-detect-virt <<'EOF'
exit "$VIRT_STATUS"
EOF
    # shellcheck disable=SC2016 # the inner script expands its own arguments
    run env PATH="$STUB_BIN" "$BASH" -c '. "$1"; . "$2"; ku_in_vm' _ \
        "$REPO_DIR/lib/kernel-updater/common.sh" "$REPO_DIR/lib/kernel-updater/disk.sh"
    [ "$status" -eq 0 ]
    grep -q '^systemd-detect-virt --vm --quiet$' "$STUB_LOG"
}

@test "direct falls back to export, saying why, on a read-only mount or a failed one" {
    write_config "deploy = direct"
    # The volume mounts, but only read-only, as a driver may leave a volume it will not write.
    export TARGET_OPTS=ro,nosuid,nodev,noexec
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|partition 1 mounts only read-only|private|0" ]
    [[ "$stderr" == *"warning: deploy = direct cannot write partition 1: partition 1 mounts"* ]]
    [[ "$stderr" == *"the files go to output_dir for Windows to copy instead"* ]]
    # The read-write mount fails, as ntfs3's does on a volume marked dirty, and a read-only one
    # serves the export's reads.
    export TARGET_OPTS=rw MOUNT_RW_FAIL=1
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|partition 1 does not mount read-write with ntfs3, as when the volume \
is marked dirty: let Windows check the stick, then run again|private|0" ]
    # A read-only mount of root's that is there.
    mkdir -p "$ROOT/media/BOOT"
    export MOUNT_RW_FAIL="" P1_MOUNTS="$ROOT/media/BOOT / ro,relatime" TARGET_OPTS=ro
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|partition 1 is mounted read-only|mount|0" ]
    private_output
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "--dry-run keeps the mode direct would use, but mounts partition 1 read-only" {
    run_ku_lib "KU_DRY_RUN=1; ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "direct||private|0" ]
    [[ "$stderr" == *"info: dry run: partition 1 is mounted read-only, so whether deploy ="* ]]
    refute_line_match ',rw' "$STUB_LOG"
    # The probe opens the volume for writing, which a dry run leaves alone.
    refute_line_match '^ntfs-3g\.probe' "$STUB_LOG"
    grep -q "^mount -t ntfs3 -o nosuid\\\\,nodev\\\\,noexec\\\\,ro /dev/sdb1 " "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "path writes p1_path while it is a mount of partition 1's files that only root can change" {
    write_config "deploy = path" "p1_path = /media/sf_BOOT"
    share_p1
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY; "'printf "%s\n" "$KU_DK_ROOT"'
    [ "$status" -eq 0 ]
    [ "$output" = $'path||path|1\n'"$ROOT/media/sf_BOOT" ]
    # partition 1 was mounted read-only to check that the share holds its grub.cfg.
    refute_line_match ',rw' "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    # In a VM too, where the host writes through its share.
    export VIRT_STATUS=0
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "path||path|1" ]
    export VIRT_STATUS=1 TARGET_OPTS=ro
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|p1_path is on a read-only mount|path|0" ]
    # A share other users can change serves neither the write nor the export's reads, which
    # then read partition 1 itself.
    export TARGET_OPTS=rw USER_TREE="$ROOT/media/sf_BOOT"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|users other than root can change the files under p1_path|private|0" ]
    write_config "deploy = path"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|p1_path is not set|private|0" ]
    write_config "deploy = export"
    : > "$STUB_LOG"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|deploy = export|private|0" ]
    refute_line_match ',rw' "$STUB_LOG"
}

@test "p1_path serves a writer or a plan only as its share's one mount, with a root of root's" {
    local share="the filesystem at p1_path is mounted elsewhere too, as by VirtualBox's"
    share+=" automount, where users other than root may change its files"
    write_config "deploy = path" "p1_path = /media/sf_BOOT"
    share_p1
    # Mounted by systemd's automount, the share lies on an autofs mount, which is no second
    # mount of the share.
    export P1_PATH_STACKED=1
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "path||path|1" ]
    # VirtualBox's automount of the same share, which its group can change, beside p1_path.
    export P1_PATH_JOINED="$ROOT/media/sf_BOOT2"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|$share|private|0" ]
    # A reader, which only hashes, takes it all the same.
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s\n" "$KU_DK_HOW"'
    [ "$output" = path ]
    # Below a directory closed to group and others, p1_path's own root shows a user as its
    # owner, as when root mounted partition 1 there while a desktop had it mounted too.
    export P1_PATH_JOINED="" RUN_STAT="0 700" USER_TREE="$ROOT/media/sf_BOOT"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|users other than root can change the files under p1_path|private|0" ]
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "path exports when p1_path is an empty mount point, missing or another stick's share" {
    write_config "deploy = path" "p1_path = /media/sf_BOOT"
    # The share is not mounted, as on a native boot, so its mount point is empty.
    mkdir -p "$ROOT/media/sf_BOOT"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$status" -eq 0 ]
    [ "$output" = "export|p1_path is not a mount point|private|0" ]
    refute_line_match ',rw' "$STUB_LOG"
    rmdir "$ROOT/media/sf_BOOT"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|p1_path is not a mount point|private|0" ]
    # Mounted, but without MultiBootUSB's menu.
    mkdir -p "$ROOT/media/sf_BOOT"
    export P1_PATH_MOUNTED=1
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = "export|p1_path holds no multibootusb/grub/grub.cfg|private|0" ]
    # The share holds another grub.cfg than partition 1, as another stick's share does.
    share_p1 "another stick"
    run_ku_lib "ku_deploy_resolve; $SHOW_DEPLOY"
    [ "$output" = \
        "export|p1_path holds another multibootusb/grub/grub.cfg than partition 1|private|0" ]
    [[ "$stderr" == *"warning: p1_path holds another multibootusb/grub/grub.cfg than"* ]]
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "A reader takes p1_path only while it serves, and reads partition 1 itself otherwise" {
    local open='ku_disk_find; ku_p1_open ro; printf "%s|%s\n" "$KU_DK_HOW" "$KU_DK_ROOT"'
    write_config "p1_path = /media/sf_BOOT"
    share_p1
    run_ku_lib "$open"
    [ "$status" -eq 0 ]
    [ "$output" = "path|$ROOT/media/sf_BOOT" ]
    # Without the share, as on a native boot, the empty mount point or none at all.
    export P1_PATH_MOUNTED=0
    run_ku_lib "$open"
    [[ "$output" == "private|$ROOT/run/kernel-updater."*/p1 ]]
    rm "$ROOT/media/sf_BOOT/multibootusb/grub/grub.cfg"
    rmdir "$ROOT/media/sf_BOOT/multibootusb/grub" "$ROOT/media/sf_BOOT/multibootusb" \
        "$ROOT/media/sf_BOOT"
    run_ku_lib "$open"
    [[ "$output" == "private|$ROOT/run/kernel-updater."*/p1 ]]
    # Another stick's share.
    share_p1 "another stick"
    run_ku_lib "$open"
    [[ "$output" == "private|$ROOT/run/kernel-updater."*/p1 ]]
    [[ "$stderr" == *"so it is not taken for partition 1"* ]]
    # When partition 1 cannot be read, its share is all there is to read.
    export MOUNT_TYPES=""
    run_ku_lib "$open"
    [ "$output" = "path|$ROOT/media/sf_BOOT" ]
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "The seams KU_P1_DIR, KU_P1_DISK, KU_P1_FSTYPES and KU_P1_PROBE count only with KU_TEST=1" {
    # shellcheck disable=SC2016 # the inner script expands its own variables
    local code='. "$1"; . "$2"; printf "%s|%s|%s|%s\n" "$KU_P1_DIR" "$KU_P1_DISK" \
        "$KU_P1_FSTYPES" "$KU_P1_PROBE"'
    run env -u KU_TEST KU_P1_DIR=/srv/p1 KU_P1_DISK=/srv/disk KU_P1_FSTYPES=vfat \
        KU_P1_PROBE=/srv/probe bash -c "$code" _ "$REPO_DIR/lib/kernel-updater/common.sh" \
        "$REPO_DIR/lib/kernel-updater/disk.sh"
    [ "$output" = "||ntfs3 ntfs-3g|ntfs-3g.probe" ]
    run env KU_TEST=1 KU_P1_DIR=/srv/p1 KU_P1_DISK=/srv/disk KU_P1_FSTYPES=vfat \
        KU_P1_PROBE=/srv/probe bash -c "$code" _ "$REPO_DIR/lib/kernel-updater/common.sh" \
        "$REPO_DIR/lib/kernel-updater/disk.sh"
    [ "$output" = "/srv/p1|/srv/disk|vfat|/srv/probe" ]
}
