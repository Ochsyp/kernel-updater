#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater baseline command checks
#
# Runs kernel-updater baseline and baseline --show on a partition-1 tree that KU_P1_DIR names
# and a disk image that KU_P1_DISK names: recording, showing, changed, new and missing files, a
# changed MBR boot code and boot sector, declining, --dry-run, another stick, the root check, a
# disk that cannot be read, and ku_baseline_update for the files a writer wrote.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

# The files of the stick's tree that baseline.list names.
FILES=(boot/grub/config.cfg multibootusb/extlinux.cfg multibootusb/grub/core.img
    multibootusb/grub/grub.cfg multibootusb/grub/i386-pc/command.lst
    multibootusb/grub/i386-pc/linux.mod multibootusb/grub/i386-pc/moddep.lst
    multibootusb/grub/i386-pc/normal.mod multibootusb/grub/lnxboot.img
    multibootusb/grub/load_iso.cfg multibootusb/grub/win.cfg multibootusb/ldlinux.c32
    multibootusb/ldlinux.sys multibootusb/syslinux.cfg)
BASELINE=/var/lib/kernel-updater/baseline

# A MultiBootUSB tree as partition 1, with GRUB 2.02 and files the list leaves out, the disk
# image it lies on, a config that names the stick, and root.
setup() {
    local name
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    export KU_P1_DIR="$BATS_TEST_TMPDIR/p1" KU_P1_DISK="$BATS_TEST_TMPDIR/disk.img"
    mkdir -p "$ROOT/etc" "$ROOT/run" "$KU_P1_DIR/boot/grub" \
        "$KU_P1_DIR/multibootusb/grub/i386-pc"
    for name in "${FILES[@]}"; do
        printf '%s of the stick\r\n' "$name" > "$KU_P1_DIR/$name"
    done
    printf 'ELF\0GNU GRUB  version %%s\0%s\0normal\0' 2.02 \
        > "$KU_P1_DIR/multibootusb/grub/i386-pc/normal.mod"
    printf 'font\n' > "$KU_P1_DIR/multibootusb/grub/unicode.pf2"
    printf 'notes\n' > "$KU_P1_DIR/multibootusb/grub/i386-pc/README"
    make_disk_image "$KU_P1_DISK"
    printf 'disk_ptuuid = 5ca1ab1e\np1_fs_uuid = 5CA1AB1E00000001\n' \
        > "$ROOT/etc/kernel-updater.conf"
    # ID_U is the user id, root unless a test says otherwise; root owns the config file and
    # /run.
    mkstub id <<'EOF'
printf '%s\n' "${ID_U:-0}"
EOF
    mkstub stat <<< "echo '0 600'"
    mkstub flock
}

# Print the SHA-256 of stdin.
sum() {
    sha256sum | cut -c 1-64
}

# Print the baseline the tree and the disk image should give, sorted by name.
expected_baseline() {
    local name
    {
        for name in "${FILES[@]}"; do
            printf '%s  %s\n' "$(sum < "$KU_P1_DIR/$name")" "$name"
        done
        printf '%s  mbr:boot-code\n' "$(head -c 440 "$KU_P1_DISK" | sum)"
        printf '%s  p1:boot-sector\n' "$(dd if="$KU_P1_DISK" bs=512 skip=2 count=1 \
            status=none | sum)"
    } | LC_ALL=C sort -k 2
}

@test "baseline records the boot files, the MBR boot code and the boot sector, sorted" {
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%-12s  %s' baseline none)" ]
    [ "$(< "$ROOT$BASELINE")" = "$(expected_baseline)" ]
    [[ "$stderr" == *"info: recorded 16 entries in $BASELINE: 14 file(s) on partition 1, the"* ]]
    [[ "$stderr" == *"the MBR boot code and partition 1's boot sector"* ]]
    # Files the list does not name stay out.
    [[ "$(< "$ROOT$BASELINE")" != *unicode.pf2* && "$(< "$ROOT$BASELINE")" != *README* ]]
    [ -z "$(find "$ROOT/var/lib/kernel-updater" -name '.*')" ]
    grep -q '^flock -n ' "$STUB_LOG"
    # Only root can read it; Git Bash on Windows keeps no such modes.
    if [[ $OSTYPE == linux* ]]; then
        [ "$(stat -c %a "$ROOT/var/lib/kernel-updater")" = 700 ]
        [ "$(stat -c %a "$ROOT$BASELINE")" = 600 ]
    fi
}

@test "baseline --show changes nothing and prints the identity, GRUB and the comparison" {
    run_ku baseline --show
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%-12s  %s\n' disk "not checked" partition-1 "not checked" \
        grub-version 2.02 baseline none)" ]
    [ ! -e "$ROOT$BASELINE" ]
    refute_line_match '^flock' "$STUB_LOG"
    run_ku baseline --yes
    run_ku --porcelain baseline --show
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\n' disk "not checked" partition-1 "not checked" \
        grub-version 2.02 same 16)" ]
}

@test "A changed, a new and a missing file are named, and recorded after a yes" {
    run_ku baseline --yes
    printf 'changed\r\n' >> "$KU_P1_DIR/multibootusb/grub/grub.cfg"
    printf 'menuentry "Kali" {\n}\n' > "$KU_P1_DIR/multibootusb/grub/kali.cfg"
    rm "$KU_P1_DIR/multibootusb/grub/win.cfg"
    printf 'y\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku baseline
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%-12s  %s\n' same 14 changed multibootusb/grub/grub.cfg \
        new multibootusb/grub/kali.cfg missing multibootusb/grub/win.cfg)" ]
    [[ "$stderr" == *"info: baseline: changed: multibootusb/grub/grub.cfg; new:"* ]]
    [[ "$stderr" == *"missing: multibootusb/grub/win.cfg"* ]]
    [[ "$stderr" == *"Record the SHA-256 of 16 entries of the stick's boot code in $BASELINE?"* ]]
    grep -q '  multibootusb/grub/kali.cfg$' "$ROOT$BASELINE"
    refute_line_match 'win\.cfg' "$ROOT$BASELINE"
    # Once recorded, nothing is left to record.
    run_ku baseline
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%-12s  %s\n' same 16)" ]
    [[ "$stderr" == *"partition 1 matches the stored baseline; nothing to record"* ]]
}

@test "A changed byte of the MBR boot code or of the boot sector shows" {
    run_ku baseline --yes
    poke_byte "$KU_P1_DISK" 100
    poke_byte "$KU_P1_DISK" 1100
    run_ku baseline --show
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(printf '%-12s  %s\n' same 14 changed mbr:boot-code changed \
        p1:boot-sector)" ]]
    # Bytes 440 on, the disk signature and the partition table, are no boot code.
    run_ku baseline --yes
    poke_byte "$KU_P1_DISK" 450
    run_ku baseline --show
    [[ "$output" == *"$(printf '%-12s  %s' same 16)" ]]
}

@test "Declining exits 10, --dry-run writes nothing, and no terminal means no" {
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku baseline
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"declined; nothing was changed"* ]]
    [ ! -e "$ROOT$BASELINE" ]
    run_ku --dry-run baseline
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"dry run: would record 16 entries in $BASELINE; nothing was written"* ]]
    [ ! -e "$ROOT$BASELINE" ]
    rm "$BATS_TEST_TMPDIR/tty"
    run_ku baseline
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"no terminal to confirm on; pass --yes"* ]]
    [ ! -e "$ROOT$BASELINE" ]
}

@test "A damaged baseline is recorded anew, and a stick without the files is refused" {
    mkdir -p "$ROOT/var/lib/kernel-updater"
    printf 'not a baseline\n' > "$ROOT$BASELINE"
    run_ku baseline --show
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(printf '%-12s  %s' baseline damaged)" ]]
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: the stored baseline is damaged; it is recorded anew"* ]]
    [ "$(< "$ROOT$BASELINE")" = "$(expected_baseline)" ]
    # An empty partition 1 without a disk image has nothing to record.
    export KU_P1_DIR="$BATS_TEST_TMPDIR/empty" KU_P1_DISK=""
    mkdir "$KU_P1_DIR"
    run_ku baseline --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"partition 1 holds none of the files baseline.list names"* ]]
}

@test "Another stick exits 78, naming the part that differs, and so do unset keys" {
    # KU_P1_DISK stays, so that no test ever reads a real disk.
    unset KU_P1_DIR
    # The stick as sdb under /boot; blkid has nothing to add.
    export BOOT_MOUNT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b01"
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*) printf '%s\n' "$BOOT_MOUNT" ;;
    *) exit 1 ;;
esac
EOF
    mkstub lsblk <<'EOF'
case " $* " in
    *" -s "*) printf '%s\n' '/dev/mapper/boot_crypt crypt' '/dev/sdb3 part' '/dev/sdb disk' ;;
    *" -d "*) printf '5ca1ab1e\n' ;;
    *) printf '%s\n' '/dev/sdb   ' '/dev/sdb1 1 ntfs 5CA1AB1E00000001' ;;
esac
EOF
    mkstub blkid <<< 'exit 2'
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' 5ca1ab1e-0000-4000-8000-000000000d01 \
        5CA1AB1E00000001 > "$ROOT/etc/kernel-updater.conf"
    run_ku baseline --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"error: the disk that holds /boot is not the one disk_ptuuid names;"* ]]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$stderr" != */dev/sd* ]]
    printf 'disk_ptuuid = 5ca1ab1e\np1_fs_uuid = 5CA1AB1E00000002\n' \
        > "$ROOT/etc/kernel-updater.conf"
    run_ku baseline --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"error: partition 1 of the disk that holds /boot is not the NTFS"* ]]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$stderr" != */dev/sd* ]]
    # --show says so too, without a value, exits 0 and leaves the other partition 1 alone.
    mkstub mount <<< 'exit 32'
    : > "$STUB_LOG"
    run_ku baseline --show
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%-12s  %s\n' disk match partition-1 mismatch grub-version \
        unknown baseline "not compared")" ]
    [[ "$stderr" == *"warning: partition 1 of the disk that holds /boot is not the NTFS"* ]]
    [[ "$stderr" == *"p1_fs_uuid names, so partition 1 is not read"* ]]
    refute_line_match '^u?mount ' "$STUB_LOG"
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$stderr" != */dev/sd* ]]
    : > "$ROOT/etc/kernel-updater.conf"
    run_ku baseline --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"the stick cannot be told apart: set disk_ptuuid and p1_fs_uuid in"* ]]
    run_ku baseline --show
    [ "${lines[0]}" = "$(printf '%-12s  %s' disk "not configured")" ]
    [ ! -e "$ROOT$BASELINE" ]
    refute_line_match '^mount .*,rw' "$STUB_LOG"
}

@test "A disk that cannot be read is named by its kind in the warnings, never by its path" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local hash='KU_P1_DISK=$1; ku_baseline_hash "$KU_P1_DIR" > /dev/null || exit 3'
    run_ku_lib "$hash" "$BATS_TEST_TMPDIR/sdz.img"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"warning: cannot read the MBR boot code of the disk"* ]]
    [[ "$stderr" != *sdz* ]]
    # An image too short to place partition 1.
    head -c 446 "$KU_P1_DISK" > "$BATS_TEST_TMPDIR/sdz.img"
    run_ku_lib "$hash" "$BATS_TEST_TMPDIR/sdz.img"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"warning: cannot read the boot sector of partition 1"* ]]
    [[ "$stderr" != *sdz* ]]
    # As root without the seams, it reads the disk and partition 1 that ku_disk_find found.
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'root=$KU_P1_DIR KU_P1_DIR="" KU_P1_DISK="" KU_DK_DISK=$1 KU_DK_PART=${1}1
        ku_baseline_hash "$root" > /dev/null || exit 3' "$BATS_TEST_TMPDIR/dev/sdz"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"warning: cannot read the MBR boot code of the disk"* ]]
    [[ "$stderr" != *sdz* ]]
}

@test "ku_baseline_update sets the entries a writer gives and leaves the others alone" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local hash update='ku_baseline_update "$@" || exit 3'
    hash=$(printf 'menuentry "Kali (links)" {\r\n}\r\n' | sum)
    # Without a stored baseline there is nothing to update.
    run_ku_lib "$update" multibootusb/grub/grub.cfg "$hash"
    [ "$status" -eq 3 ]
    [ ! -e "$ROOT$BASELINE" ]
    run_ku baseline --yes
    cp "$ROOT$BASELINE" "$BATS_TEST_TMPDIR/before"
    # A dry run, which wrote no file either, checks the same but records nothing.
    run_ku_lib "KU_DRY_RUN=1; $update" multibootusb/grub/grub.cfg "$hash"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: dry run: would record 1 file(s) in $BASELINE; nothing was written"* ]]
    cmp "$BATS_TEST_TMPDIR/before" "$ROOT$BASELINE"
    run_ku_lib "KU_DRY_RUN=1; $update" multibootusb/grub/grub.cfg "${hash:0:63}"
    [ "$status" -eq 3 ]
    # Partition 1's core.img changed since, which an update of the menus must not record.
    printf 'changed\n' >> "$KU_P1_DIR/multibootusb/grub/core.img"
    run_ku_lib "$update" multibootusb/grub/grub.cfg "$hash" multibootusb/grub/kali.cfg "$hash"
    [ "$status" -eq 0 ]
    [ "$(< "$ROOT$BASELINE")" = "$({
        grep -v '  multibootusb/grub/grub\.cfg$' "$BATS_TEST_TMPDIR/before"
        printf '%s  %s\n' "$hash" multibootusb/grub/grub.cfg "$hash" multibootusb/grub/kali.cfg
    } | LC_ALL=C sort -k 2)" ]
    run_ku baseline --show
    [[ "$output" == *"$(printf '%-12s  %s\n' changed multibootusb/grub/core.img changed \
        multibootusb/grub/grub.cfg missing multibootusb/grub/kali.cfg)" ]]
    # A pair that is no name and SHA-256, and a damaged baseline, change nothing.
    cp "$ROOT$BASELINE" "$BATS_TEST_TMPDIR/after"
    run_ku_lib "$update" multibootusb/grub/grub.cfg "${hash:0:63}"
    [ "$status" -eq 3 ]
    run_ku_lib "$update" /multibootusb/grub/grub.cfg "$hash"
    [ "$status" -eq 3 ]
    run_ku_lib "$update" multibootusb/grub/grub.cfg
    [ "$status" -eq 3 ]
    cmp "$BATS_TEST_TMPDIR/after" "$ROOT$BASELINE"
    printf 'not a baseline\n' >> "$ROOT$BASELINE"
    cp "$ROOT$BASELINE" "$BATS_TEST_TMPDIR/damaged"
    run_ku_lib "$update" multibootusb/grub/grub.cfg "$hash"
    [ "$status" -eq 3 ]
    cmp "$BATS_TEST_TMPDIR/damaged" "$ROOT$BASELINE"
}

@test "A symlink in the boot tree is not followed: its files show as missing, GRUB as unknown" {
    use_symlinks || skip "this platform cannot make symlinks"
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    # multibootusb/grub turns into a link to the same files elsewhere.
    mv "$KU_P1_DIR/multibootusb/grub" "$BATS_TEST_TMPDIR/grub"
    ln -s "$BATS_TEST_TMPDIR/grub" "$KU_P1_DIR/multibootusb/grub"
    run_ku --porcelain baseline --show
    [ "$status" -eq 0 ]
    [[ "$output" == *$'grub-version\tunknown\n'* ]]
    [[ "$output" == *$'missing\tmultibootusb/grub/grub.cfg'* ]]
    [[ "$output" == *$'missing\tmultibootusb/grub/i386-pc/normal.mod'* ]]
    [[ "$output" != *$'changed\t'* ]]
}

@test "baseline exits 77 when not root, 75 while locked, and 64 on a usage error" {
    export ID_U=1000
    run_ku baseline --yes
    [ "$status" -eq 77 ]
    run_ku baseline --show
    [ "$status" -eq 77 ]
    [ "$(cut -d ' ' -f 1 "$STUB_LOG" | sort -u)" = id ]
    export ID_U=0
    mkstub flock <<< 'exit 1'
    run_ku baseline --yes
    [ "$status" -eq 75 ]
    [ ! -e "$ROOT$BASELINE" ]
    run_ku baseline --bogus
    [ "$status" -eq 64 ]
    run_ku baseline extra
    [ "$status" -eq 64 ]
    run_ku baseline --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: kernel-updater baseline "* ]]
}
