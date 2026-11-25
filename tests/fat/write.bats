#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater writes a FAT partition 1, with --write-fat under VMware
#
# As root in the fat job, on the synthetic stick of fat.bash: the checks that must all hold
# before partition 1 is written, each refusal leaving it byte for byte as it was; the writer on
# real FAT, with a read-back through a new mount, a failed rename and a failed read-back put
# back; and a copy of partition 1 after every step the writer syncs, as a power loss would leave
# it, which fsck.vfat must find in order, with the old or the new grub.cfg.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load fat

REL=multibootusb/grub/grub.cfg
ARGS="root=/dev/mapper/kali--vg-root ro quiet"
OLD=$'menuentry "Kali" {\r\n\tlinux /vmlinuz '"$ARGS"$'\r\n\tinitrd /initrd.img\r\n}\r\n'
NEW=$'menuentry "Kali" {\r\n\tconfigfile /multibootusb/grub/kali.cfg\r\n}\r\n'
# The question before a FAT write, which --yes does not answer.
QUESTION="Write the FAT partition 1 now? In Windows, Test-Path on BOOT's drive must print False"
GATE="refusing to write the FAT partition 1:"

setup_file() {
    fat_enabled || return 0
    make_stick
}

teardown_file() {
    fat_enabled || return 0
    remove_stick
}

# A fresh partition 1 whose grub.cfg boots the running kernel with its command line, partition 2
# mounted as KU_ROOT's /boot, a config that names the stick, VMware, and the answer to the
# question on the terminal.
setup() {
    fat_only
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    cat /proc/filesystems > "$ROOT/proc/filesystems"
    printf 'BOOT_IMAGE=/vmlinuz %s\n' "$ARGS" > "$ROOT/proc/cmdline"
    fresh_partition
    put_grub "$OLD"
    mount "${STICK_LOOP}p2" "$ROOT/boot"
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "$STICK_PTUUID" "$STICK_SERIAL" \
        > "$ROOT/etc/kernel-updater.conf"
    mkstub systemd-detect-virt <<< 'echo vmware'
    printf '%s' "$OLD" > "$BATS_TEST_TMPDIR/old.cfg"
    printf '%s' "$NEW" > "$BATS_TEST_TMPDIR/new.cfg"
    printf 'y\n' > "$BATS_TEST_TMPDIR/tty"
}

teardown() {
    fat_enabled || return 0
    unmount_under "$ROOT"
}

# Write CONTENT to partition 1's grub.cfg through a mount of the test's own.
put_grub() {
    local view
    view=$(mount_p1 rw "$BATS_TEST_TMPDIR")
    printf '%s' "$1" > "$view/$REL"
    umount "$view"
    rmdir "$view"
}

# Print partition 1's grub.cfg, read through a new read-only mount.
p1_grub() {
    local view
    view=$(mount_p1 ro "$BATS_TEST_TMPDIR")
    cat "$view/$REL"
    umount "$view"
    rmdir "$view"
}

# Print the names in partition 1's multibootusb/grub that the writer makes, sorted: backups,
# temporary files and files moved aside.
p1_extras() {
    local view
    view=$(mount_p1 ro "$BATS_TEST_TMPDIR")
    (cd "$view/multibootusb/grub" && find . -maxdepth 1 -name '*.ku-*' | sed 's#^\./##' | sort)
    umount "$view"
    rmdir "$view"
}

# Return 0 when fsck.vfat finds nothing to repair on the FAT32 copy FILE, as a power loss left
# it. Such a copy is marked dirty, which Windows checks it for, and its FSInfo sector may hold an
# old count of free clusters, a hint that Linux writes back when it unmounts and that FAT keeps
# for speed alone. Both are set as unknown first, so that the check looks at what matters: the
# FATs, the directories and the files.
fsck_copy() {
    local fsinfo
    if [[ $(stat -c %s "$1") != "$(blockdev --getsize64 "${STICK_LOOP}p1")" ]]; then
        printf '%s is no whole copy of partition 1\n' "${1##*/}" >&2
        return 1
    fi
    set_byte "$1" "$FAT32_FLAGS" 0
    fsinfo=$(( ($(byte_at "$1" 48) + 256 * $(byte_at "$1" 49)) *
        ($(byte_at "$1" 11) + 256 * $(byte_at "$1" 12)) ))
    dd if=/dev/zero bs=1 count=8 status=none | tr '\0' '\377' |
        dd of="$1" bs=1 seek=$(( fsinfo + 488 )) conv=notrunc status=none
    fsck_clean "$1"
}

# Run CODE, then what a writer with --write-fat runs: ku_deploy_resolve, and ku_deploy_files
# writing grub.cfg anew from new.cfg where the plan read old.cfg.
write_grub() {
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib "${1:-}"'
        KU_DK_WRITE_FAT=1
        ku_deploy_resolve || ku_die "$KU_EX_NOINPUT" "$KU_DK_PROBLEM"
        printf "deploy: %s\n" "$KU_DK_DEPLOY" >&2
        ku_deploy_files "$KU_DK_ROOT" "$1" "$2" "$3"' \
        "$REL" "$BATS_TEST_TMPDIR/new.cfg" "$(sum_of "$BATS_TEST_TMPDIR/old.cfg")"
}

# Fail unless partition 1 is unmounted, byte for byte the SUM given.
p1_unchanged() {
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(p1_sum)" = "$1" ]
}

@test "--write-fat writes grub.cfg under VMware, reads it back through a new mount, and fsck passes" {
    local mounts
    # The writer logs each mount of partition 1 it makes anew and its options.
    # shellcheck disable=SC2016 # the code expands its own variables
    write_grub '
        eval "_ku_real_remount() $(declare -f ku_p1_remount | tail -n +2)"
        ku_p1_remount() {
            _ku_real_remount "$@" || return
            printf "remount %s: %s\n" "$1" "$(findmnt -n -r -o OPTIONS --target "$KU_DK_ROOT")" >&2
        }'
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"info: --write-fat: VMware, the stick's menu booted the running kernel, and"* ]]
    [[ "$stderr" == *"deploy: direct"* ]]
    [[ "$stderr" == *"info: wrote $REL; the old one is kept as $REL.ku-"* ]]
    # Read-write with flush, then read-only for the read-back, then read-write again. The first
    # follows the question on its line, as the typed answer's newline is not echoed here.
    mounts=$(grep -o -E 'remount (ro|rw): [^ ]+' <<< "$stderr")
    [ "$(wc -l <<< "$mounts")" -eq 3 ]
    [[ "$(sed -n 1p <<< "$mounts")" == "remount rw: rw,"*flush* ]]
    [[ "$(sed -n 2p <<< "$mounts")" == "remount ro: ro,"* ]]
    [[ "$(sed -n 3p <<< "$mounts")" == "remount rw: rw,"*flush* ]]
    # CRLF and all, with the old one kept beside it, and nothing else left.
    cmp "$BATS_TEST_TMPDIR/new.cfg" <(p1_grub)
    [[ "$(p1_extras)" =~ ^grub\.cfg\.ku-[0-9]{8}T[0-9]{6}Z\.bak$ ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ "$(fat_flags)" = 0 ]
    fsck_clean "${STICK_LOOP}p1"
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "Each check before a FAT write that fails refuses, and partition 1 stays byte for byte as it was" {
    local before at view mode
    before=$(p1_sum)
    # Not under VMware.
    mkstub systemd-detect-virt <<< 'echo none; exit 1'
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE this system runs in no VM, and --write-fat writes only under VMware;"* ]]
    p1_unchanged "$before"
    mkstub systemd-detect-virt <<< 'echo kvm'
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE this system runs in kvm, and --write-fat writes only under VMware;"* ]]
    p1_unchanged "$before"
    mkstub systemd-detect-virt <<< 'echo vmware'
    # The stick's menu does not boot the running kernel's command line.
    printf 'BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro\n' > "$ROOT/proc/cmdline"
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE the running kernel's command line ends 0 linux line(s) of the stick's"* ]]
    [[ "$stderr" == *"menu and 0 of /boot/grub/grub.cfg, so the stick's menu cannot be told"* ]]
    p1_unchanged "$before"
    # Kali's own menu boots it too.
    printf 'BOOT_IMAGE=/vmlinuz %s\n' "$ARGS" > "$ROOT/proc/cmdline"
    mkdir -p "$ROOT/boot/grub"
    printf '\tlinux /vmlinuz-9.0.2+kali-amd64 %s\n' "$ARGS" > "$ROOT/boot/grub/grub.cfg"
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"ends 1 linux line(s) of the stick's menu and 1 of /boot/grub/grub.cfg"* ]]
    p1_unchanged "$before"
    rm -r "$ROOT/boot/grub"
    # Windows still uses the volume: its FAT is not marked clean.
    at=$(fat_clean_byte "${STICK_LOOP}p1")
    clear_clean_bit "${STICK_LOOP}p1"
    before=$(p1_sum)
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE the volume was not unmounted cleanly, as while Windows uses it:"* ]]
    [[ "$stderr" == *"close what uses BOOT in Windows"* && "$stderr" != *mountvol* ]]
    p1_unchanged "$before"
    set_byte "${STICK_LOOP}p1" "$at" $(( $(byte_at "${STICK_LOOP}p1" "$at") | 8 ))
    # Marked dirty, as an unplug without an eject leaves it.
    set_fat_flags 1
    before=$(p1_sum)
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE the volume is marked dirty, as after an unplug without an eject:"* ]]
    [[ "$stderr" == *"chkdsk X: /f"* ]]
    p1_unchanged "$before"
    set_fat_flags 0
    before=$(p1_sum)
    # Mounted already, here read-only by root alone.
    view=$(mount_p1 ro,uid=0,gid=0,umask=077 "$ROOT")
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE partition 1 is mounted already, and --write-fat writes only through a"* ]]
    umount "$view"
    p1_unchanged "$before"
    # deploy = export and path.
    for mode in export path; do
        printf 'disk_ptuuid = %s\np1_fs_uuid = %s\ndeploy = %s\np1_path = /mnt\n' \
            "$STICK_PTUUID" "$STICK_SERIAL" "$mode" > "$ROOT/etc/kernel-updater.conf"
        write_grub
        [ "$status" -eq 3 ]
        [[ "$stderr" == *"$GATE --write-fat writes through a mount of its own, which deploy = $mode"* ]]
        p1_unchanged "$before"
    done
}

@test "A no, or no answer, to the question before a FAT write writes nothing, --yes or not" {
    local before
    before=$(p1_sum)
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    write_grub
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"$QUESTION [y/N] "* ]]
    [[ "$stderr" == *"declined; nothing was changed"* && "$stderr" != *mountvol* ]]
    p1_unchanged "$before"
    # --yes answers the plan's questions, never this one.
    write_grub 'KU_ASSUME_YES=1'
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"$QUESTION [y/N] "* ]]
    p1_unchanged "$before"
    rm "$BATS_TEST_TMPDIR/tty"
    write_grub 'KU_ASSUME_YES=1'
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"no terminal to answer on, which --yes does not do for this question"* ]]
    p1_unchanged "$before"
    # A dry run asks nothing and writes nothing.
    write_grub 'KU_DRY_RUN=1'
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would write $REL"* ]]
    p1_unchanged "$before"
}

@test "A failed rename on FAT puts grub.cfg back as it was, and fsck passes" {
    export REAL_MV
    REAL_MV=$(command -v mv)
    # The rename of the temporary file to grub.cfg fails.
    mkstub mv <<'EOF'
[[ ${*: -2:1} != */.grub.cfg.ku-* || ${*: -2:1} == *.old ]] || exit 1
exec "$REAL_MV" "$@"
EOF
    write_grub
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"cannot rename the temporary file to $REL; $REL was put back as it was"* ]]
    cmp "$BATS_TEST_TMPDIR/old.cfg" <(p1_grub)
    [[ "$(p1_extras)" =~ ^grub\.cfg\.ku-[0-9]{8}T[0-9]{6}Z\.bak$ ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    fsck_clean "${STICK_LOOP}p1"
}

@test "A read-back through the new mount that differs puts the old grub.cfg back, and fsck passes" {
    # The read through the read-only mount, once the backup is made, gets other bytes.
    # shellcheck disable=SC2016 # the code expands its own variables
    write_grub '
        eval "_ku_real_hash() $(declare -f _ku_deploy_hash | tail -n +2)"
        _ku_deploy_hash() {
            if (( ! KU_DK_WRITABLE )) && [[ $1 == */grub.cfg ]] &&
                compgen -G "${1%/*}/grub.cfg.ku-*.bak" > /dev/null; then
                printf "%064d\n" 0
                return 0
            fi
            _ku_real_hash "$@"
        }'
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"$REL does not read back as it was written; $REL was restored as it was"* ]]
    cmp "$BATS_TEST_TMPDIR/old.cfg" <(p1_grub)
    [[ "$(p1_extras)" =~ ^grub\.cfg\.ku-[0-9]{8}T[0-9]{6}Z\.bak$ ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    fsck_clean "${STICK_LOOP}p1"
}

@test "A read-back mount that fails is followed by a read-write one, which puts the old grub.cfg back" {
    # The read-only mount for the read-back fails, and leaves nothing mounted.
    # shellcheck disable=SC2016 # the code expands its own variables
    write_grub '
        eval "_ku_real_remount() $(declare -f ku_p1_remount | tail -n +2)"
        ku_p1_remount() {
            if [[ $1 == ro ]]; then
                umount "$KU_DK_MOUNT_DIR/p1"
                KU_DK_WRITABLE=0 KU_DK_PROBLEM="the test failed the mount"
                return 1
            fi
            _ku_real_remount "$@"
        }'
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"$REL cannot be read back through a new mount: the test failed the mount;"* ]]
    [[ "$stderr" == *"$REL was restored as it was"* ]]
    cmp "$BATS_TEST_TMPDIR/old.cfg" <(p1_grub)
    [[ "$(p1_extras)" =~ ^grub\.cfg\.ku-[0-9]{8}T[0-9]{6}Z\.bak$ ]]
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    fsck_clean "${STICK_LOOP}p1"
}

@test "When partition 1 does not mount read-write after the read-back, the run says what is left" {
    # The read-write mount after the read-back fails, and leaves nothing mounted.
    # shellcheck disable=SC2016 # the code expands its own variables
    write_grub '
        eval "_ku_real_remount() $(declare -f ku_p1_remount | tail -n +2)"
        ku_p1_remount() {
            if [[ $1 == rw ]] && (( KU_DK_FAT_RW == 2 )); then
                umount "$KU_DK_MOUNT_DIR/p1"
                KU_DK_WRITABLE=0 KU_DK_PROBLEM="the test failed the mount"
                return 1
            fi
            _ku_real_remount "$@"
        }'
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"$REL was written and reads back as written, but partition 1 does not mount"* ]]
    [[ "$stderr" == *"read-write again: the test failed the mount; the old one waits beside it as"* ]]
    [[ "$stderr" != *"warning: the old grub.cfg waits beside the new one"* ]]
    cmp "$BATS_TEST_TMPDIR/new.cfg" <(p1_grub)
    # The backup, and the old one aside, which the run did not reach to remove.
    [ "$(p1_extras | wc -l)" -eq 2 ]
    p1_extras | grep -q -x -E '\.grub\.cfg\.ku-[0-9]{8}T[0-9]{6}Z\.old'
    p1_extras | grep -q -x -E 'grub\.cfg\.ku-[0-9]{8}T[0-9]{6}Z\.bak'
    [ -z "$(findmnt -n -r -o TARGET --source "${STICK_LOOP}p1")" ]
    [ -z "$(ls -A "$ROOT/run")" ]
    fsck_clean "${STICK_LOOP}p1"
}

@test "Power lost after any step of a FAT write leaves a volume fsck passes, with a grub.cfg to boot" {
    local copy view n=0 gaps=0 olds=0 news=0
    export REAL_SYNC COPIES="$BATS_TEST_TMPDIR/copies" P1_DEV="${STICK_LOOP}p1"
    REAL_SYNC=$(command -v sync)
    mkdir "$COPIES"
    # After each sync of the writer, a copy of partition 1 as the stick then holds it: the
    # kernel first drops what it keeps of the device but what the mount uses, which the sync
    # wrote out, so the copy reads the device itself.
    mkstub sync <<'EOF'
"$REAL_SYNC" "$@" || exit
blockdev --flushbufs "$P1_DEV"
n=$(find "$COPIES" -name 'step.*' | wc -l)
dd if="$P1_DEV" of="$COPIES/step.$(printf '%02d' $((n + 1)))" bs=1M status=none
EOF
    write_grub
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    for copy in "$COPIES"/step.*; do
        n=$((n + 1))
        fsck_copy "$copy"
        view=$(mktemp -d "$BATS_TEST_TMPDIR/copy.XXXXXXXX")
        mount -t vfat -o ro,loop "$copy" "$view"
        if [[ ! -e $view/$REL ]]; then
            # Only between the two renames, with the old grub.cfg waiting aside.
            gaps=$((gaps + 1))
            cmp "$BATS_TEST_TMPDIR/old.cfg" "$view"/multibootusb/grub/.grub.cfg.ku-*.old
        elif cmp -s "$BATS_TEST_TMPDIR/old.cfg" "$view/$REL"; then
            olds=$((olds + 1))
        else
            cmp "$BATS_TEST_TMPDIR/new.cfg" "$view/$REL"
            news=$((news + 1))
        fi
        umount "$view"
        rmdir "$view"
        rm "$copy"
    done
    # The backup, the temporary file, the move aside, the rename and the removal of the old
    # one each synced, and the read-back's mounts too.
    (( n >= 5 && gaps == 1 && olds >= 2 && news >= 2 ))
    cmp "$BATS_TEST_TMPDIR/new.cfg" <(p1_grub)
}

@test "On FAT16 the clean-shutdown bit holds a write back too, and a clean volume is written" {
    local before view at
    mkfs.vfat -F 16 -n BOOT -i "${STICK_SERIAL//-/}" "${STICK_LOOP}p1" > /dev/null
    view=$(mount_p1 rw "$BATS_TEST_TMPDIR")
    mkdir -p "$view/multibootusb/grub"
    umount "$view"
    rmdir "$view"
    put_grub "$OLD"
    clear_clean_bit "${STICK_LOOP}p1"
    before=$(p1_sum)
    write_grub
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$GATE the volume was not unmounted cleanly"* ]]
    p1_unchanged "$before"
    at=$(fat_clean_byte "${STICK_LOOP}p1")
    set_byte "${STICK_LOOP}p1" "$at" $(( $(byte_at "${STICK_LOOP}p1" "$at") | 128 ))
    write_grub
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    cmp "$BATS_TEST_TMPDIR/new.cfg" <(p1_grub)
    fsck_clean "${STICK_LOOP}p1"
}
