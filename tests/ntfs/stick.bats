#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater checks on real NTFS
#
# As root in the ntfs job, builds a synthetic stick in a loop file, an MBR with the synthetic
# disk signature, NTFS on partition 1 and ext4 as /boot on partition 2, and runs on it what
# phase 5 adds: finding partition 1 from /boot, its identity, mounts with ntfs3 and ntfs-3g,
# ntfs-3g.probe refusing a volume Windows left hibernated and ntfs3 one marked dirty, the safe
# writer, a failed rename and its restore after a bad read-back, a read-only mount, a mount a
# user owns, and the baseline and its tripwire.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load ntfs

setup_file() {
    ntfs_enabled || return 0
    modprobe ntfs3
    make_stick
}

teardown_file() {
    ntfs_enabled || return 0
    remove_stick
}

# A fresh partition 1, partition 2 mounted as KU_ROOT's /boot, a config that names the stick,
# the kernel's list of filesystems, ntfs3 among them, and no VM, whatever runs the job, so that
# deploy = auto writes directly.
setup() {
    ntfs_only
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    cat /proc/filesystems > "$ROOT/proc/filesystems"
    fresh_partition
    mount "${STICK_LOOP}p2" "$ROOT/boot"
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$STICK_PTUUID" "$STICK_SERIAL" \
        > "$ROOT/etc/kernel-updater.conf"
    mkstub systemd-detect-virt <<< 'exit 1'
    printf 'menuentry "Kali (links)" {\r\n\tlinux /vmlinuz\r\n\tinitrd /initrd.img\r\n}\r\n' \
        > "$BATS_TEST_TMPDIR/grub.cfg"
    printf '%s' "$STICK_GRUB_CFG" > "$BATS_TEST_TMPDIR/old.cfg"
    export REAL_MV MV_DONE="$BATS_TEST_TMPDIR/mv.done"
    REAL_MV=$(command -v mv)
}

teardown() {
    ntfs_enabled || return 0
    unmount_under "$ROOT"
}

# Write grub.cfg on partition 1 with the bytes of the local file SOURCE, as a plan that read it
# first does, through ku_deploy_resolve and ku_deploy_write and bats' run.
deploy_grub() {
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve
        printf "%s\n" "$KU_DK_DEPLOY"
        old=$(ku_sha256 "$KU_DK_ROOT/multibootusb/grub/grub.cfg")
        ku_deploy_write "$KU_DK_ROOT" multibootusb/grub/grub.cfg "$1" "$old"' "$1"
}

@test "Partition 1 is found from /boot through lsblk, and its identity checked" {
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_disk_identity
        printf "%s\n" "$KU_DK_DISK" "$KU_DK_PART" "$KU_DK_FSTYPE" "$KU_DK_DISK_ID" \
            "$KU_DK_P1_ID"'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' "$STICK_LOOP" "${STICK_LOOP}p1" ntfs match match)" ]
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$STICK_PTUUID" 5CA1AB1E00000002 \
        > "$ROOT/etc/kernel-updater.conf"
    run_ku_lib ku_p1_locate
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"error: partition 1 of the disk that holds /boot is not the FAT or NTFS"* ]]
    [[ "${stderr,,}" != *5ca1ab1e* && "$stderr" != */dev/loop* ]]
}

@test "ntfs3 mounts partition 1 read-only and read-write, and the mount goes again" {
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_p1_open ro
        findmnt -r -n -o FSTYPE,OPTIONS --target "$KU_DK_ROOT"
        cmp -s "$KU_DK_ROOT/multibootusb/grub/grub.cfg" "$1"
        ku_p1_open rw
        findmnt -r -n -o FSTYPE,OPTIONS --target "$KU_DK_ROOT"
        printf "%s\n" "$KU_DK_WRITABLE"' "$BATS_TEST_TMPDIR/old.cfg"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "ntfs3 ro,nosuid,nodev,noexec"* ]]
    [[ "${lines[1]}" == "ntfs3 rw,nosuid,nodev,noexec"* ]]
    [ "${lines[2]}" = 1 ]
    [ -z "$(ls -A "$ROOT/run")" ]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
}

@test "ntfs-3g mounts partition 1 read-only through KU_P1_FSTYPES" {
    export KU_P1_FSTYPES=ntfs-3g
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_p1_open ro
        findmnt -r -n -o FSTYPE,OPTIONS --target "$KU_DK_ROOT"'
    [ "$status" -eq 0 ]
    [[ "$output" == "fuseblk ro,nosuid,nodev,noexec"* ]]
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "A partition 1 marked dirty is mounted read-only only, as ntfs3 refuses it read-write" {
    local dir
    # ntfsfix marks the volume dirty, so that Windows checks it. ntfs-3g would mount it
    # read-write all the same, and ntfs-3g.probe does not look at the mark; ntfs3 refuses.
    ntfsfix "${STICK_LOOP}p1" > /dev/null
    dir=$(mktemp -d "$ROOT/dirty.XXXXXXXX")
    if mount -t ntfs3 -o rw "${STICK_LOOP}p1" "$dir" 2> /dev/null; then
        umount "$dir"
        printf 'ntfsfix left the volume unmarked, so this test shows nothing\n' >&2
        return 1
    fi
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve
        printf "%s|%s|%s\n" "$KU_DK_DEPLOY" "$KU_DK_HOW" "$KU_DK_WRITABLE"'
    [ "$status" -eq 0 ]
    [ "$output" = "export|private|0" ]
    [[ "$stderr" == *"cannot write partition 1: partition 1 does not mount read-write with ntfs3"* ]]
    [[ "$stderr" != *"no ntfs3 driver"* ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
}

@test "ku_deploy_write writes a CRLF grub.cfg with a backup, and reads it back" {
    local view
    deploy_grub "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = direct ]
    [[ "$stderr" == *"info: wrote multibootusb/grub/grub.cfg; the old one is kept as"* ]]
    view=$(mount_p1 ro "$ROOT")
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$view/multibootusb/grub/grub.cfg"
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$view"/multibootusb/grub/grub.cfg.ku-*.bak
    [ -z "$(find "$view" -name '.*.ku-*')" ]
}

@test "A rename that fails on NTFS puts grub.cfg back as it was and exits 4" {
    local view
    # grub.cfg moves aside on NTFS for real; the rename of the new one into its name fails,
    # once, and grub.cfg takes its name back for real.
    mkstub mv <<'EOF'
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
    deploy_grub "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"cannot rename the temporary file to multibootusb/grub/grub.cfg;"* ]]
    [[ "$stderr" == *"multibootusb/grub/grub.cfg was put back as it was"* ]]
    view=$(mount_p1 ro "$ROOT")
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$view/multibootusb/grub/grub.cfg"
    [ -z "$(find "$view" -name '.*.ku-*')" ]
}

@test "A read-back that fails on NTFS puts grub.cfg back and exits 4" {
    local view
    # The sync before the read-back fails; the restore's goes through.
    export REAL_SYNC SYNC_DONE="$BATS_TEST_TMPDIR/sync.done"
    REAL_SYNC=$(command -v sync)
    mkstub sync <<'EOF'
if [[ ! -e $SYNC_DONE ]]; then
    : > "$SYNC_DONE"
    exit 1
fi
exec "$REAL_SYNC" "$@"
EOF
    deploy_grub "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"multibootusb/grub/grub.cfg does not read back as it was written;"* ]]
    [[ "$stderr" == *"multibootusb/grub/grub.cfg was restored as it was"* ]]
    view=$(mount_p1 ro "$ROOT")
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$view/multibootusb/grub/grub.cfg"
    [ -z "$(find "$view" -name '.*.ku-*')" ]
}

@test "A partition 1 that Windows left hibernated is mounted read-only only, so auto exports" {
    local view
    # Windows marks a hibernated volume with hiberfil.sys at its root, which ntfs-3g.probe reads;
    # ntfs3 would mount it read-write all the same.
    view=$(mount_p1 rw "$ROOT")
    { printf 'hibr'; head -c 8188 /dev/zero; } > "$view/hiberfil.sys"
    umount "$view"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve
        printf "%s|%s|%s\n" "$KU_DK_DEPLOY" "$KU_DK_HOW" "$KU_DK_WRITABLE"
        findmnt -r -n -o OPTIONS --target "$KU_DK_ROOT"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "export|private|0" ]
    [[ "${lines[1]}" == ro,* ]]
    [[ "$stderr" == *"warning: deploy = auto cannot write partition 1: Windows left partition 1"* ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
}

@test "A mount of partition 1 that a user owns serves no writer and no plan" {
    local user
    # A desktop's mount for its user, whose files the user owns.
    user="$ROOT/media/user/BOOT"
    mkdir -p "$user"
    mount -t ntfs3 -o uid=1000,gid=1000 "${STICK_LOOP}p1" "$user"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve || { printf "%s\n" "$KU_DK_PROBLEM"; exit 3; }'
    [ "$status" -eq 3 ]
    [[ "$output" == "partition 1 is mounted where users other than root can change its files"* ]]
    # A reader, which only hashes, reads through it all the same.
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_disk_find; ku_p1_open ro; printf "%s|%s\n" "$KU_DK_HOW" "$KU_DK_ROOT"'
    [ "$output" = "mount|$user" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$user/multibootusb/grub/grub.cfg"
}

@test "A read-only mount of partition 1 is not writable, so direct falls back to export" {
    local view
    view=$(mount_p1 ro "$ROOT")
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_p1_writable "$1" || printf "read-only\n"' "$view"
    [ "$output" = read-only ]
    printf 'deploy = direct\n' >> "$ROOT/etc/kernel-updater.conf"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'ku_deploy_resolve
        printf "%s|%s|%s\n" "$KU_DK_DEPLOY" "$KU_DK_DEPLOY_WHY" "$KU_DK_ROOT"'
    [ "$status" -eq 0 ]
    [ "$output" = "export|partition 1 is mounted read-only|$view" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$view/multibootusb/grub/grub.cfg"
}

@test "baseline records the stick, and the tripwire catches one byte of a file and of the MBR" {
    local view
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"recorded 16 entries in /var/lib/kernel-updater/baseline: 14 file(s)"* ]]
    run_ku --porcelain baseline --show
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\n' disk match partition-1 match grub-version 2.06 \
        same 16)" ]
    view=$(mount_p1 rw "$ROOT")
    poke_byte "$view/multibootusb/grub/grub.cfg" 3
    umount "$view"
    poke_byte "$STICK_LOOP" 100
    run_ku --porcelain baseline --show
    [[ "$output" == *$'same\t14\nchanged\tmbr:boot-code\nchanged\tmultibootusb/grub/grub.cfg' ]]
    run_ku check --porcelain
    expect_item p1-identity ok "the disk that holds /boot and its NTFS partition 1 are"
    expect_item tripwire fail "changed: mbr:boot-code, multibootusb/grub/grub.cfg since"
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$output$stderr" != */dev/loop* ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
}
