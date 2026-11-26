#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater contrib: overlayroot-rw
#
# Runs contrib/initramfs/overlayroot-rw as initramfs-tools would after overlayroot, with stub
# mount, umount and mkdir that log their calls, and a mounts file in place of /proc/mounts. The
# root is a directory of the test's own, which only holds the fstab the script may edit.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

SCRIPT="$REPO_DIR/contrib/initramfs/overlayroot-rw"
LAYERS="lowerdir=/media/root-ro,upperdir=/media/root-rw/overlay"
LAYERS+=",workdir=/media/root-rw/overlay-workdir/_"

setup() {
    stub_init
    R="$BATS_TEST_TMPDIR/root"
    mkdir -p "$R/etc"
    printf 'overlayroot\t/\toverlay\tro,%s 0 0\n' "$LAYERS" > "$R/etc/fstab"
    # mount fails a move from MOUNT_FAIL_MOVE, and the read-write overlay with MOUNT_FAIL_RW=1;
    # umount exits UMOUNT_STATUS, and UMOUNT_L_STATUS with -l.
    mkstub mount <<'EOF'
if [[ $1 == --move && $2 == "${MOUNT_FAIL_MOVE:-}" ]]; then exit 32; fi
if [[ ${MOUNT_FAIL_RW:-} == 1 && $3 == -o && $4 == rw,* ]]; then exit 32; fi
exit 0
EOF
    mkstub umount <<'EOF'
if [[ $1 == -l ]]; then exit "${UMOUNT_L_STATUS:-0}"; fi
exit "${UMOUNT_STATUS:-0}"
EOF
    mkstub mkdir <<< 'exit 0'
}

# Write the mounts file: the overlay with the options OPTS, then udev's /dev with /dev/pts in it
# and overlayroot's two layers, all under the root, as at the end of init-bottom.
mounts() {
    printf '%s\n' "overlayroot $R overlay $1 0 0" "udev $R/dev devtmpfs rw 0 0" \
        "devpts $R/dev/pts devpts rw 0 0" "/dev/mapper/root $R/media/root-ro ext4 ro 0 0" \
        "tmpfs-root $R/media/root-rw tmpfs rw 0 0" > "$BATS_TEST_TMPDIR/mounts"
}

run_script() {
    run env PATH="$STUB_BIN:$PATH" rootmnt="$R" \
        OVERLAYROOT_RW_MOUNTS="$BATS_TEST_TMPDIR/mounts" \
        OVERLAYROOT_RW_LOG="$BATS_TEST_TMPDIR/log" OVERLAYROOT_RW_KMSG="$BATS_TEST_TMPDIR/kmsg" \
        sh "$SCRIPT" "$@"
}

# Print the calls of mount and umount the run made, in order.
calls() {
    grep -E '^(mount|umount) ' "$STUB_LOG" || true
}

@test "overlayroot-rw names overlayroot as its prerequisite" {
    run_script prereqs
    [ "$status" -eq 0 ]
    [ "$output" = overlayroot ]
}

@test "overlayroot-rw leaves a root alone that is no overlay or is read-write already" {
    printf '%s\n' "/dev/mapper/root $R ext4 ro 0 0" > "$BATS_TEST_TMPDIR/mounts"
    run_script
    [ "$status" -eq 0 ]
    [ "$(< "$BATS_TEST_TMPDIR/log")" = "no overlayroot overlay at $R: nothing to do" ]
    [ -z "$(calls)" ]
    mounts "rw,relatime,$LAYERS"
    : > "$BATS_TEST_TMPDIR/log"
    run_script
    [ "$status" -eq 0 ]
    [ "$(< "$BATS_TEST_TMPDIR/log")" = "the overlay is read-write already" ]
    [ -z "$(calls)" ]
}

@test "overlayroot-rw mounts a read-only overlay's layers read-write, moving only the top mounts" {
    mounts "ro,relatime,$LAYERS,uuid=on"
    run_script
    [ "$status" -eq 0 ]
    [ "$(calls)" = "$(printf '%s\n' "mount --move $R/dev /dev" \
        "mount --move $R/media/root-ro /media/root-ro" \
        "mount --move $R/media/root-rw /media/root-rw" "umount $R" \
        "mount -t overlay -o rw,$LAYERS overlayroot $R" "mount --move /dev $R/dev" \
        "mount --move /media/root-ro $R/media/root-ro" \
        "mount --move /media/root-rw $R/media/root-rw")" ]
    # The fstab line in the overlay names / rw now, so systemd keeps it.
    [ "$(cut -f 1-4 "$R/etc/fstab" | cut -d , -f 1)" = $'overlayroot\t/\toverlay\trw' ]
    grep -q -x 'the overlay is mounted read-write' "$BATS_TEST_TMPDIR/log"
    grep -q -x 'fstab: overlayroot / overlay rw' "$BATS_TEST_TMPDIR/log"
    # Each line of the log also goes to the kernel log, marked.
    [ "$(wc -l < "$BATS_TEST_TMPDIR/kmsg")" -eq "$(wc -l < "$BATS_TEST_TMPDIR/log")" ]
    grep -q -x 'overlayroot-rw: the overlay is mounted read-write' "$BATS_TEST_TMPDIR/kmsg"
}

@test "overlayroot-rw mounts /dev anew when it will not move, after detaching the busy overlay" {
    mounts "ro,relatime,$LAYERS"
    export MOUNT_FAIL_MOVE="$R/dev" UMOUNT_STATUS=32
    run_script
    [ "$status" -eq 0 ]
    calls | grep -q -x "umount -l $R"
    calls | grep -q -x "mount -t overlay -o rw,$LAYERS overlayroot $R"
    calls | grep -q -x "mount -t devtmpfs -o nosuid,mode=0755 udev $R/dev"
    calls | grep -q -x "mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts $R/dev/pts"
    grep -q -x "cannot move $R/dev out: it is mounted anew in the new root" \
        "$BATS_TEST_TMPDIR/log"
    grep -q -x 'the read-only overlay was busy: detached it' "$BATS_TEST_TMPDIR/log"
    grep -q -x 'mounted /dev and /dev/pts anew' "$BATS_TEST_TMPDIR/log"
}

@test "overlayroot-rw leaves the root read-only and puts everything back when it cannot go on" {
    mounts "ro,relatime,$LAYERS"
    # Another top mount will not move: the ones moved already go back, nothing is unmounted.
    export MOUNT_FAIL_MOVE="$R/media/root-rw"
    run_script
    [ "$status" -eq 0 ]
    [ "$(calls)" = "$(printf '%s\n' "mount --move $R/dev /dev" \
        "mount --move $R/media/root-ro /media/root-ro" \
        "mount --move $R/media/root-rw /media/root-rw" "mount --move /dev $R/dev" \
        "mount --move /media/root-ro $R/media/root-ro")" ]
    grep -q -x "cannot move $R/media/root-rw out: the root stays read-only" \
        "$BATS_TEST_TMPDIR/log"
    # The overlay will not unmount, not even lazily.
    export MOUNT_FAIL_MOVE="" UMOUNT_STATUS=32 UMOUNT_L_STATUS=32
    : > "$STUB_LOG"
    run_script
    [ "$status" -eq 0 ]
    [ "$(calls | grep -c -- '-t overlay')" -eq 0 ]
    [ "$(calls | grep -c -- '--move /')" -eq 3 ]
    # The read-write overlay fails: the same layers go back read-only.
    export UMOUNT_STATUS=0 UMOUNT_L_STATUS=0 MOUNT_FAIL_RW=1
    : > "$STUB_LOG"
    run_script
    [ "$status" -eq 0 ]
    calls | grep -q -x "mount -t overlay -o ro,$LAYERS overlayroot $R"
    [ "$(calls | grep -c -- '--move /')" -eq 3 ]
    grep -q -x 'the read-write overlay failed: mounting it read-only again' \
        "$BATS_TEST_TMPDIR/log"
    [ "$(cut -f 4 "$R/etc/fstab" | cut -d , -f 1)" = ro ]
}

@test "overlayroot-rw says so when overlayroot's fstab has no line for /" {
    mounts "ro,relatime,$LAYERS"
    printf 'tmpfs\t/tmp\ttmpfs\tdefaults 0 0\n' > "$R/etc/fstab"
    run_script
    [ "$status" -eq 0 ]
    grep -q -x 'fstab: no overlayroot line, nothing to change' "$BATS_TEST_TMPDIR/log"
    [ "$(< "$R/etc/fstab")" = $'tmpfs\t/tmp\ttmpfs\tdefaults 0 0' ]
}
