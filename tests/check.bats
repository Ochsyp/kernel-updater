#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater check command checks
#
# Runs kernel-updater check on a healthy KU_ROOT tree and partition 1 with stub tools, then
# breaks one item at a time, and checks the formats, the exit codes and that no identifier
# reaches the output.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

V1=9.0.1+kali-amd64
V2=9.0.2+kali-amd64
BY_ID=/dev/disk/by-id/usb-Synthetic_Stick_5CA1AB1E00000001-0:0
ITEMS=(boot-mounted boot-identity boot-shadowed kernel-img boot-links stale-root-links kernels
    reboot-pending initrd boot-luks boot-ext fstab-crypttab grub-pc)
P1_ITEMS=(p1-identity grub-version tripwire deployed kali-cfg kali-menu boot-menu)
# The line migrate's block in grub.cfg opens with.
MARKER="# Kali GNU/Linux: kernel-updater keeps the entries in kali.cfg. Not a MultiBootUSB block."

setup() {
    stub_init
    use_symlinks || skip "this platform cannot make symlinks"
    ROOT="$BATS_TEST_TMPDIR/root"
    # check makes its scan directory in /run, never in TMPDIR, which root may inherit.
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    healthy_system
    healthy_partition
}

# Write the config file with grub_floor FLOOR, 2.02 by default, the UUIDs of /boot and the
# identity of the stick: disk_ptuuid PTUUID, 5ca1ab1e by default, and p1_fs_uuid SERIAL, an
# NTFS serial by default.
write_config() {
    printf 'grub_floor = %s\nboot_fs_uuid = %s\nboot_luks_uuid = %s\n' "${1:-2.02}" \
        5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c01 \
        > "$ROOT/etc/kernel-updater.conf"
    printf 'disk_ptuuid = %s\np1_fs_uuid = %s\n' "${2:-5ca1ab1e}" "${3:-5CA1AB1E00000001}" \
        >> "$ROOT/etc/kernel-updater.conf"
}

# A healthy partition 1 in P1, which KU_P1_DIR names, on the disk image KU_P1_DISK names:
# GRUB 2.14's normal.mod, so that no grub_floor a test sets is newer, with the stick's command
# and module lists, MultiBootUSB's grub.cfg with migrate's block that sources kali.cfg, a
# kali.cfg that passes lint, an export of both in output_dir, and a baseline of it all.
healthy_partition() {
    export KU_P1_DIR="$BATS_TEST_TMPDIR/p1" KU_P1_DISK="$BATS_TEST_TMPDIR/disk.img"
    GRUB="$KU_P1_DIR/multibootusb/grub" OUT="$ROOT/root/kernel-updater/out"
    mkdir -p "$GRUB/i386-pc" "$OUT"
    normal_mod 2.14
    printf '%s\n' '*menuentry: normal' 'linux: linux' 'initrd: linux' \
        'configfile: configfile' > "$GRUB/i386-pc/command.lst"
    printf '%s\n' 'normal: crypto' 'linux: relocator mmap' 'ext2: fshelp' 'gzio:' \
        'part_msdos:' 'configfile:' > "$GRUB/i386-pc/moddep.lst"
    write_grub_cfg
    write_kali_cfg
    make_disk_image "$KU_P1_DISK"
    printf '%s  %s\n' "$(sha256sum < "$GRUB/kali.cfg" | cut -c 1-64)" kali.cfg \
        "$(sha256sum < "$GRUB/grub.cfg" | cut -c 1-64)" grub.cfg > "$OUT/SHA256SUMS"
    record_baseline
}

# Write the stick's i386-pc normal.mod, which names each GRUB VERSION given among its strings.
normal_mod() {
    {
        printf 'ELF\0GNU GRUB  version %%s\0'
        printf '%s\0' "$@"
        printf 'normal\0'
    } > "$GRUB/i386-pc/normal.mod"
}

# Write MultiBootUSB's grub.cfg, CRLF, with migrate's block that sources kali.cfg, followed by
# any further LINES.
write_grub_cfg() {
    printf '%s\r\n' 'insmod part_msdos' "$MARKER" 'if [ -f /multibootusb/grub/kali.cfg ]; then' \
        $'\tsource /multibootusb/grub/kali.cfg' 'else' \
        $'\tmenuentry "Kali GNU/Linux: kali.cfg is missing on BOOT" {' $'\t\tsleep 10' $'\t}' \
        'fi' "$@" > "$GRUB/grub.cfg"
}

# Write a kali.cfg that passes lint, with any further LINES in its menu entry.
write_kali_cfg() {
    {
        printf 'menuentry "Kali GNU/Linux" {\n\tinsmod gzio\n\tinsmod part_msdos\n'
        printf '\tinsmod ext2\n'
        if (( $# )); then
            printf '\t%s\n' "$@"
        fi
        printf '\tlinux /vmlinuz root=/dev/mapper/kali--vg-root ro quiet\n'
        printf '\tinitrd /initrd.img\n}\n'
    } > "$GRUB/kali.cfg"
}

# Store the baseline of partition 1 as it is now, as kernel-updater baseline records it.
record_baseline() {
    mkdir -p "$ROOT/var/lib/kernel-updater"
    (
        load_ku_libs
        ku_baseline_hash "$KU_P1_DIR"
    ) > "$ROOT/var/lib/kernel-updater/baseline"
}

# Describe the stick to the stub lsblk and blkid as sdb under /boot's crypt mapping, and stop
# KU_P1_DIR standing in for partition 1. KU_P1_DISK stays, so that no test reads a real disk.
stick_from_boot() {
    unset KU_P1_DIR
    mkstub lsblk <<'EOF'
[[ -z ${LSBLK_FAIL:-} ]] || exit 32
case " $* " in
    *" -s "*) printf '%s\n' '/dev/mapper/boot_crypt crypt' '/dev/sdb3 part' '/dev/sdb disk' ;;
    *" -d "*) printf '5ca1ab1e\n' ;;
    *) printf '%s\n' '/dev/sdb   ' "/dev/sdb1 1 ${P1_LSBLK:-ntfs 5CA1AB1E00000001}" ;;
esac
EOF
    mkstub blkid <<< 'exit 2'
}

# Build a healthy system under ROOT and the stubs that report it: kernels V1 and V2 with their
# initrds, the four /boot links on them, link_in_boot on, a config naming /boot's UUIDs, a
# root key file in crypttab, devices named by UUID, and nothing hidden under /boot's mount.
healthy_system() {
    local v
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/run" "$ROOT/proc"
    # The command line kali.cfg's entry boots.
    printf 'BOOT_IMAGE=/vmlinuz root=/dev/mapper/kali--vg-root ro quiet\n' > "$ROOT/proc/cmdline"
    for v in "$V1" "$V2"; do
        printf 'kernel %s\n' "$v" > "$ROOT/boot/vmlinuz-$v"
        printf 'initrd %s\n' "$v" > "$ROOT/boot/initrd.img-$v"
    done
    ln -s "vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    ln -s "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    write_config
    printf '%s\n' 'boot_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c01 none luks' \
        'root_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c02 /etc/keys/root.key luks,discard' \
        > "$ROOT/etc/crypttab"
    printf '%s\n' '/dev/mapper/kali--vg-root / ext4 errors=remount-ro 0 1' \
        'UUID=5ca1ab1e-0000-4000-8000-000000000b01 /boot ext4 defaults 0 2' \
        '/dev/mapper/kali--vg-swap_1 none swap sw 0 0' 'tmpfs /tmp tmpfs defaults 0 0' \
        > "$ROOT/etc/fstab"
    export DPKG_QUERY_OUT="$BATS_TEST_TMPDIR/dpkg-query.out"
    printf '%s\t%s\t%s\n' "linux-image-$V1" 'ii ' 9.0.1-1kali1 "linux-image-$V2" 'ii ' \
        9.0.2-1kali1 linux-image-amd64 'ii ' 9.0.2-1kali1 > "$DPKG_QUERY_OUT"
    stub_system_tools
    # ID_U is the user id; root unless a test says otherwise.
    mkstub id <<'EOF'
printf '%s\n' "${ID_U:-0}"
EOF
    # FINDMNT_OUT is /boot's mount line; empty means /boot is not mounted. Partition 1 is
    # mounted nowhere, and a path is on a read-write mount.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    mkstub findmnt <<'EOF'
case " $* " in
    *" --source "*) exit 1 ;;
    *" --target "*) printf 'rw,nosuid,nodev,noexec\n' ;;
    *)
        [[ -n $FINDMNT_OUT ]] || exit 1
        printf '%s\n' "$FINDMNT_OUT"
        ;;
esac
EOF
    mkstub dpkg-query <<'EOF'
cat "$DPKG_QUERY_OUT"
exit "${DPKG_QUERY_STATUS:-0}"
EOF
    # VIRT is the hypervisor systemd-detect-virt names: none on bare metal.
    mkstub systemd-detect-virt <<'EOF'
printf '%s\n' "${VIRT:-none}"
[[ ${VIRT:-none} != none ]]
EOF
    mkstub linux-version <<'EOF'
[[ $1 == sort ]] && exec sort -V
EOF
    export DEBCONF_OUT='* grub-pc/install_devices:'
    mkstub debconf-show <<'EOF'
printf '%s\n' "$DEBCONF_OUT"
EOF
    # The bind mount shows SHADOWED entries under boot/; MOUNT_FAIL=1 makes it fail.
    # UMOUNT_FAIL=plain makes a plain unmount fail, as on a busy mount, and UMOUNT_FAIL=all a
    # lazy one too. Both stubs act only inside the test's /run.
    export SHADOWED=0
    mkstub mount <<'EOF'
[[ -z ${MOUNT_FAIL:-} ]] || exit 32
dir=${*: -1}
[[ $dir == "$KU_ROOT/run"/* ]] || exit 32
mkdir -p "$dir/boot"
for (( i = 0; i < SHADOWED; i++ )); do : > "$dir/boot/vmlinuz-hidden-$i"; done
EOF
    mkstub umount <<'EOF'
lazy=0
if [[ $1 == -l ]]; then lazy=1; shift; fi
[[ $1 == "$KU_ROOT/run"/* ]] || exit 32
case ${UMOUNT_FAIL:-} in
    all) exit 32 ;;
    plain) (( lazy )) || exit 32 ;;
esac
rm -rf -- "$1/boot"
EOF
    # Root owns the config file and /run, whose owner and mode RUN_STAT gives; INITRD_MODE is
    # the mode of the initrds.
    export RUN_STAT="0 755"
    mkstub stat <<'EOF'
if [[ ${*: -1} == */run ]]; then
    echo "$RUN_STAT"
elif [[ $3 == '%u %a' ]]; then
    echo '0 600'
else
    echo "${INITRD_MODE:-600}"
fi
EOF
}

# Run check with --porcelain and any further ARGS.
run_check() {
    run_ku check --porcelain "$@"
}

# Fail unless every item but the ITEMS given passed.
others_ok() {
    local name
    for name in "${ITEMS[@]}"; do
        if [[ " $* " != *" $name "* ]]; then
            expect_item "$name" ok ""
        fi
    done
}

@test "A healthy system passes every item and leaves no bind mount or directory behind" {
    local i all=("${ITEMS[@]}" "${P1_ITEMS[@]}")
    run_ku check
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 20 ]
    for i in "${!all[@]}"; do
        if [[ "${lines[i]}" != "ok    ${all[i]} "* ]]; then
            printf 'line %d: %s\n' "$i" "${lines[i]}" >&2
            return 1
        fi
    done
    [ "${lines[0]}" = "ok    boot-mounted      /boot is a separate ext4 mount" ]
    [[ "$stderr" == *"info: check: 20 item(s): 20 ok, 0 warn, 0 fail, 0 skip"* ]]
    grep -q "^mount --bind --make-private -o ro $ROOT/ $ROOT/run/kernel-updater\.[^/]*/root\$" \
        "$STUB_LOG"
    grep -q "^umount $ROOT/run/kernel-updater\.[^/]*/root\$" "$STUB_LOG"
    refute_line_match '^umount -l ' "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "--porcelain prints ITEM, STATUS and DETAIL tab-separated, as a global option too" {
    local args i
    for args in "check --porcelain" "--porcelain check"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku $args
        [ "$status" -eq 0 ]
        for i in "${!ITEMS[@]}"; do
            [[ "${lines[i]}" == "${ITEMS[i]}"$'\tok\t'?* ]]
        done
    done
    expect_item kernels ok "2 installed, running $V2"
    expect_item initrd ok "cryptsetup, the cryptroot configuration and key files"
}

@test "check exits 77 when not run as root, before it reads or mounts anything" {
    export ID_U=1000
    run_check
    [ "$status" -eq 77 ]
    [ -z "$output" ]
    [[ "$stderr" == *"must run as root"* ]]
    [ "$(cut -d ' ' -f 1 "$STUB_LOG")" = id ]
}

@test "Usage errors exit 64, and --help prints the check usage" {
    run_ku check --bogus
    [ "$status" -eq 64 ]
    run_ku check extra
    [ "$status" -eq 64 ]
    run_ku check --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: kernel-updater check "* ]]
}

@test "boot-mounted fails when /boot is not a mount point, and the /boot items skip" {
    export FINDMNT_OUT=""
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-mounted fail "not a mount point"
    local name
    for name in boot-identity boot-shadowed boot-luks boot-ext; do
        expect_item "$name" skip "not"
    done
    refute_line_match '^mount ' "$STUB_LOG"
}

@test "boot-identity fails on another filesystem or container, and warns without boot_fs_uuid" {
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b02"
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-identity fail "not the one boot_fs_uuid names"
    others_ok boot-identity
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5CA1AB1E-0000-4000-8000-000000000B01"
    run_check
    expect_item boot-identity ok "in the container boot_luks_uuid names"
    printf 'boot_fs_uuid = %s\nboot_luks_uuid = %s\n' 5ca1ab1e-0000-4000-8000-000000000b01 \
        5ca1ab1e-0000-4000-8000-000000000c09 > "$ROOT/etc/kernel-updater.conf"
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-identity fail "not in the LUKS container boot_luks_uuid names"
    : > "$ROOT/etc/kernel-updater.conf"
    run_check
    [ "$status" -eq 0 ]
    expect_item boot-identity warn "boot_fs_uuid is not set"
    run_check --strict
    [ "$status" -eq 2 ]
}

@test "boot-shadowed warns about entries under the /boot mount point and removes its mount" {
    export SHADOWED=3
    run_check
    [ "$status" -eq 0 ]
    expect_item boot-shadowed warn "3 entries hide under the /boot mount point"
    others_ok boot-shadowed
    [ -z "$(ls -A "$ROOT/run")" ]
    export SHADOWED=0 MOUNT_FAIL=1
    : > "$STUB_LOG"
    run_check
    expect_item boot-shadowed warn "the read-only bind mount of / failed"
    # A failed mount may still leave a bind mount, so the cleanup unmounts all the same.
    grep -q "^umount $ROOT/run/kernel-updater\.[^/]*/root\$" "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "boot-shadowed mounts only in a /run whose entries no other user can rename" {
    local mode
    for mode in "1000 755" "0 775" "0 757"; do
        export RUN_STAT=$mode
        : > "$STUB_LOG"
        run_check
        [ "$status" -eq 0 ]
        expect_item boot-shadowed warn \
            "cannot look under the /boot mount point: /run is not a directory whose entries only"
        refute_line_match '^u?mount ' "$STUB_LOG"
        [ -z "$(ls -A "$ROOT/run")" ]
    done
    rmdir "$ROOT/run"
    run_check
    expect_item boot-shadowed warn "/run is not a directory whose entries only root can rename"
    # With the sticky bit, as on /tmp, only root may rename root's entries.
    mkdir "$ROOT/run"
    export RUN_STAT="0 1777"
    run_check
    [ "$status" -eq 0 ]
    others_ok
}

@test "boot-shadowed unmounts a busy bind mount lazily, and fails when that fails too" {
    export UMOUNT_FAIL=plain
    run_check
    [ "$status" -eq 0 ]
    others_ok
    grep -q "^umount -l $ROOT/run/kernel-updater\.[^/]*/root\$" "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    export UMOUNT_FAIL=all
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-shadowed fail "the read-only bind mount of / on $ROOT/run/kernel-updater."
    others_ok boot-shadowed
    # The exit trap tries once more, and says so when that fails too.
    [[ "$stderr" == *"warning: cleanup _ku_check_scan_cleanup failed"* ]]
}

@test "kernel-img warns while link_in_boot or do_symlinks is off, and the link items skip" {
    printf 'link_in_boot = no\n' > "$ROOT/etc/kernel-img.conf"
    run_check
    [ "$status" -eq 0 ]
    expect_item kernel-img warn \
        "link_in_boot is off: the links live in /, where GRUB cannot read them"
    expect_item boot-links skip "link_in_boot is off"
    expect_item stale-root-links skip "the links belong in /"
    expect_item reboot-pending skip "link_in_boot is off"
    printf 'do_symlinks = no\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    run_check
    expect_item kernel-img warn "do_symlinks is off"
}

@test "boot-links fails on a missing, absolute or dangling link" {
    rm "$ROOT/boot/vmlinuz.old" "$ROOT/boot/initrd.img" "$ROOT/boot/initrd.img.old"
    ln -s "/boot/initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-9.0.0+kali-amd64" "$ROOT/boot/initrd.img.old"
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-links fail "vmlinuz.old is missing or no symlink; initrd.img is absolute;"
    expect_item boot-links fail "initrd.img.old does not reach a non-empty file in /boot"
    others_ok boot-links
}

@test "stale-root-links warns about vmlinuz and initrd.img entries left in /" {
    ln -s "boot/vmlinuz-$V1" "$ROOT/vmlinuz"
    printf 'initrd\n' > "$ROOT/initrd.img.old"
    run_check
    [ "$status" -eq 0 ]
    expect_item stale-root-links warn "2 vmlinuz or initrd.img entries are left in /"
    others_ok stale-root-links
}

@test "kernels fails on a stuck package or a running kernel that is not installed" {
    printf '%s\t%s\t%s\n' "linux-modules-$V2" 'iF ' 9.0.2-1kali1 >> "$DPKG_QUERY_OUT"
    run_check
    [ "$status" -eq 2 ]
    expect_item kernels fail "$V2 is half-configured (iF): run dpkg --configure -a; 1 installed"
    export UNAME_R=9.0.3+kali-amd64
    run_check
    expect_item kernels fail "the running kernel 9.0.3+kali-amd64 is not installed"
    export UNAME_R=""
    run_check
    expect_item kernels fail "uname -r prints no kernel release"
}

@test "kernels fails and initrd skips when the kernel packages cannot be read or sorted" {
    export DPKG_QUERY_STATUS=2
    run_check
    [ "$status" -eq 2 ]
    expect_item kernels fail "dpkg-query cannot read the package database"
    expect_item initrd skip "the installed kernels are unknown"
    export DPKG_QUERY_STATUS=0
    # The linux-version stub runs sort -V too, so both fail.
    mkstub sort <<< 'exit 2'
    run_check
    [ "$status" -eq 2 ]
    expect_item kernels fail "the kernel versions cannot be sorted"
    expect_item initrd skip "the installed kernels are unknown"
    [[ "$stderr" == *"warning: linux-version cannot sort the kernel versions"* ]]
}

@test "A running kernel counts as installed when only a package it replaced is removed" {
    printf '%s\t%s\t%s\n' "linux-image-$V2" 'rc ' 9.0.2-1kali1 "linux-image-$V2-unsigned" 'ii ' \
        9.0.2-1kali1 "linux-image-$V1" 'ii ' 9.0.1-1kali1 > "$DPKG_QUERY_OUT"
    run_check
    [ "$status" -eq 0 ]
    expect_item kernels ok "2 installed, running $V2"
    others_ok
}

@test "kernels warns on a removed kernel with config files left and reports held ones" {
    printf '%s\t%s\t%s\n' linux-image-9.0.0+kali-amd64 'rc ' 9.0.0-1kali1 > "$DPKG_QUERY_OUT.new"
    printf '%s\t%s\t%s\n' "linux-image-$V1" 'hi ' 9.0.1-1kali1 "linux-image-$V2" 'ii ' \
        9.0.2-1kali1 >> "$DPKG_QUERY_OUT.new"
    mv "$DPKG_QUERY_OUT.new" "$DPKG_QUERY_OUT"
    run_check
    [ "$status" -eq 0 ]
    expect_item kernels warn "1 removed with config files left; 2 installed, 1 held"
    others_ok kernels
}

@test "reboot-pending warns when the running kernel is not the one vmlinuz points at" {
    export UNAME_R=$V1
    run_check
    [ "$status" -eq 0 ]
    expect_item reboot-pending warn \
        "/boot/vmlinuz points at $V2, but $V1 is running: reboot to start it"
    others_ok reboot-pending
}

@test "initrd fails when an initrd is missing, unreadable or lacks what root needs" {
    rm "$ROOT/boot/initrd.img-$V1"
    run_check
    [ "$status" -eq 2 ]
    expect_item initrd fail "$V1 has no initrd"
    printf 'initrd\n' > "$ROOT/boot/initrd.img-$V1"
    export LSINITRAMFS_FAIL=$V2
    run_check
    expect_item initrd fail "lsinitramfs cannot read the initrd of $V2"
    export LSINITRAMFS_FAIL="" LSINITRAMFS_DROP='^usr/sbin/cryptsetup$|^usr/lib/modules'
    run_check
    expect_item initrd fail "the initrd of $V1 lacks its modules, cryptsetup; the initrd of $V2"
    export LSINITRAMFS_DROP='^cryptroot/keyfiles/'
    run_check
    expect_item initrd fail \
        "lacks the key files crypttab names, so root would ask for a second password"
}

@test "initrd needs key files only when crypttab names one, and warns when others can read them" {
    export INITRD_MODE=644
    run_check
    [ "$status" -eq 0 ]
    expect_item initrd warn \
        "the initrd of $V1, $V2 holds key files and is readable by group or others"
    printf 'root_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c02 none luks\n' > "$ROOT/etc/crypttab"
    export LSINITRAMFS_DROP='^cryptroot/keyfiles'
    run_check
    expect_item initrd ok \
        "2 initrd(s) hold their modules, cryptsetup and the cryptroot configuration"
}

@test "boot-luks fails on LUKS2, on argon2 keyslots and without an open LUKS container" {
    export LUKS_TYPE=LUKS2 LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks2.dump"
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-luks fail \
        "/boot's container is LUKS2 with 1 argon2id keyslot(s): GRUB 2.02 unlocks"
    others_ok boot-luks
    export LUKS_TYPE=""
    run_check
    expect_item boot-luks fail "/boot is not in an open LUKS container"
    expect_item boot-identity fail "not in the LUKS container boot_luks_uuid names"
    export LUKS_TYPE=LUKS1 LUKS_DUMP="$BATS_TEST_TMPDIR/none"
    run_check
    expect_item boot-luks fail "cryptsetup cannot read the LUKS header"
    expect_item boot-identity fail "cannot tell whether /boot is in the LUKS container"
}

@test "boot-luks follows grub_floor: LUKS2 from 2.06 on, and Argon2 keyslots from 2.14 on" {
    local floor
    export LUKS_TYPE=LUKS2 LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks2.dump"
    for floor in 2.06 2.12; do
        write_config "$floor"
        run_check
        [ "$status" -eq 2 ]
        expect_item boot-luks fail "1 keyslot(s) use argon2id: GRUB $floor needs PBKDF2"
        others_ok boot-luks
    done
    write_config 2.14
    run_check
    [ "$status" -eq 0 ]
    expect_item boot-luks ok "LUKS2 with 2 keyslot(s) that GRUB 2.14 unlocks"
    # The same container with PBKDF2 in each keyslot opens with GRUB 2.06 too.
    sed 's/argon2id/pbkdf2/' "$LUKS_DUMP" > "$BATS_TEST_TMPDIR/pbkdf2.dump"
    export LUKS_DUMP="$BATS_TEST_TMPDIR/pbkdf2.dump"
    write_config 2.06
    run_check
    [ "$status" -eq 0 ]
    expect_item boot-luks ok "LUKS2 with 2 keyslot(s) that GRUB 2.06 unlocks"
    write_config 2.02
    run_check
    expect_item boot-luks fail "/boot's container is LUKS2: GRUB 2.02 unlocks only LUKS1"
}

@test "boot-luks and boot-identity blame a missing cryptsetup, not a missing container" {
    # No stub can take cryptsetup off PATH, so the items read the probe's status directly.
    load_ku_libs
    # shellcheck disable=SC2034 # read by the sourced library
    KU_CK_MOUNTED=1 KU_CK_LUKS=3 KU_CONF['boot_luks_uuid']=5ca1ab1e-0000-4000-8000-000000000c01
    _ku_check_boot_identity
    _ku_check_boot_luks
    [ "${KU_CHECK_STATUS[*]}" = "fail fail" ]
    [[ "${KU_CHECK_DETAIL[0]}" == *"boot_luks_uuid names: cryptsetup is not installed" ]]
    [[ "${KU_CHECK_DETAIL[1]}" == "cryptsetup is not installed, so the container"* ]]
}

@test "boot-ext fails on incompatible features GRUB 2.02 refuses, and skips a non-ext /boot" {
    local feature
    for feature in metadata_csum_seed large_dir largedir encrypt inline_data casefold \
        FEATURE_I31; do
        export EXT_FEATURES="has_journal extent 64bit flex_bg metadata_csum $feature"
        run_check
        [ "$status" -eq 2 ]
        expect_item boot-ext fail "/boot has ext feature(s) GRUB 2.02 refuses to read: $feature"
    done
    # GRUB ignores needs_recovery and mmp, and every compatible or read-only compatible feature.
    export EXT_FEATURES="has_journal extent 64bit flex_bg meta_bg needs_recovery mmp orphan_file"
    EXT_FEATURES+=" orphan_present metadata_csum FEATURE_C12 FEATURE_R15"
    run_check
    [ "$status" -eq 0 ]
    expect_item boot-ext ok "/boot has no ext feature GRUB 2.02 refuses"
    export DUMPE2FS_FAIL=1
    run_check
    expect_item boot-ext fail "dumpe2fs cannot read the filesystem at /boot"
    export FINDMNT_OUT="/dev/mapper/boot_crypt vfat 5CA1-AB1E"
    run_check
    expect_item boot-ext skip "/boot is vfat, not ext2, ext3 or ext4"
}

@test "boot-ext follows grub_floor: 2.06 reads encrypt, 2.12 metadata_csum_seed and large_dir" {
    local floor
    export EXT_FEATURES="has_journal extent 64bit flex_bg metadata_csum encrypt"
    write_config 2.06
    run_check
    [ "$status" -eq 0 ]
    expect_item boot-ext ok "/boot has no ext feature GRUB 2.06 refuses"
    EXT_FEATURES+=" metadata_csum_seed large_dir inline_data"
    run_check
    [ "$status" -eq 2 ]
    expect_item boot-ext fail \
        "GRUB 2.06 refuses to read: metadata_csum_seed, large_dir, inline_data"
    for floor in 2.12 2.14; do
        write_config "$floor"
        run_check
        [ "$status" -eq 2 ]
        expect_item boot-ext fail "GRUB $floor refuses to read: inline_data"
        others_ok boot-ext
    done
}

@test "fstab-crypttab warns on kernel names, by-path and by-id sources" {
    {
        printf '/dev/sda1 /boot ext4 defaults 0 2\n'
        printf '%s none swap sw 0 0\n' \
            /dev/disk/by-path/pci-0000:00:14.0-usb-0:2:1.0-scsi-0:0:0:0-part5
        printf 'tmpfs /tmp tmpfs defaults 0 0\n'
    } > "$ROOT/etc/fstab"
    printf 'root_crypt %s /etc/keys/root.key luks\nboot_crypt /dev/nvme0n1p2 none luks\n' \
        "$BY_ID-part3" > "$ROOT/etc/crypttab"
    run_check
    [ "$status" -eq 0 ]
    expect_item fstab-crypttab warn \
        "fstab names 1 device(s) by kernel name (/dev/sdX); fstab names 1"
    expect_item fstab-crypttab warn \
        "by /dev/disk/by-path; crypttab names 1 device(s) by kernel name"
    expect_item fstab-crypttab warn "crypttab names 1 by /dev/disk/by-id: such names change"
}

@test "grub-pc fails while install_devices names a device, and skips without an answer" {
    export DEBCONF_OUT="* grub-pc/install_devices: $BY_ID, /dev/sdb"
    run_check
    [ "$status" -eq 2 ]
    expect_item grub-pc fail "grub-pc/install_devices names 2 device(s)"
    others_ok grub-pc
    export DEBCONF_OUT='  grub-pc/timeout: 5'
    run_check
    [ "$status" -eq 0 ]
    expect_item grub-pc skip "no grub-pc/install_devices answer"
}

@test "No disk identifier, by-id name or key file path reaches the output" {
    local args all
    export LUKS_TYPE=LUKS2 LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks2.dump"
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-0000000000ff"
    export DEBCONF_OUT="* grub-pc/install_devices: $BY_ID, /dev/sdb"
    export LSINITRAMFS_DROP='^cryptroot/keyfiles/'
    printf 'root_crypt %s /etc/keys/root.key luks\n' "$BY_ID-part3" > "$ROOT/etc/crypttab"
    for args in "--verbose check" "--verbose check --porcelain"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku $args
        [ "$status" -eq 2 ]
        all="${output,,}${stderr,,}"
        [[ "$all" != *5ca1ab1e* && "$all" != *synthetic_stick* && "$all" != */dev/sdb* ]]
        [[ "$all" != */etc/keys* && "$all" != *root.key* ]]
    done
}

@test "The partition-1 items report a healthy stick through KU_P1_DIR and KU_P1_DISK" {
    run_check
    [ "$status" -eq 0 ]
    expect_item p1-identity ok "partition 1 is the test directory KU_P1_DIR names"
    expect_item grub-version ok "the stick's GRUB is 2.14 and grub_floor is 2.02; grub_floor ="
    expect_item grub-version ok "2.14 would let lint and check accept what GRUB 2.14 adds"
    expect_item tripwire ok \
        "the 7 entries of the baseline match, the MBR boot code and partition 1's boot sector"
    expect_item deployed ok "the 2 file(s) exported to output_dir match partition 1"
    expect_item kali-cfg ok \
        "multibootusb/grub/kali.cfg passes lint with the stick's command and module lists"
    others_ok
}

@test "--no-partition skips the seven partition-1 items and leaves partition 1 alone" {
    local name
    stick_from_boot
    run_check --no-partition
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 20 ]
    for name in "${P1_ITEMS[@]}"; do
        expect_item "$name" skip "--no-partition leaves partition 1 alone"
    done
    others_ok
    refute_line_match '^(lsblk|blkid)|^mount -t ' "$STUB_LOG"
    run_ku check --help
    [[ "$output" == *"--no-partition  skip the partition-1 items"* ]]
}

@test "p1-identity skips while disk_ptuuid or p1_fs_uuid is not set, and the others still run" {
    printf 'grub_floor = 2.02\nboot_fs_uuid = %s\nboot_luks_uuid = %s\np1_fs_uuid = %s\n' \
        5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c01 \
        5CA1AB1E00000001 > "$ROOT/etc/kernel-updater.conf"
    run_check
    [ "$status" -eq 0 ]
    expect_item p1-identity skip "disk_ptuuid and p1_fs_uuid are not both set: set them to"
    expect_item tripwire ok "the 7 entries of the baseline match"
}

@test "p1-identity finds partition 1 from /boot, and check reads it on a read-only mount" {
    local dir="$ROOT/run/kernel-updater\\.[^/]*/p1"
    stick_from_boot
    run_check
    expect_item p1-identity ok \
        "the disk that holds /boot and its NTFS partition 1 are the ones disk_ptuuid and"
    # The stub mount leaves the mount point empty, so the items see an empty partition 1.
    expect_item grub-version warn "the stick's GRUB version is unknown"
    expect_item kali-cfg skip "multibootusb/grub/kali.cfg does not exist yet"
    grep -q "^mount -t ntfs3 -o nosuid\\\\,nodev\\\\,noexec\\\\,ro /dev/sdb1 $dir\$" "$STUB_LOG"
    grep -q "^umount $dir\$" "$STUB_LOG"
    refute_line_match '\\,rw|force|remove_hiberfile' "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$output$stderr" != */dev/sd* ]]
}

@test "p1-identity finds a FAT partition 1, and check reads it with vfat, read-only" {
    local dir="$ROOT/run/kernel-updater\\.[^/]*/p1" opts
    stick_from_boot
    export P1_LSBLK="vfat 5CA1-AB1E"
    write_config 2.02 5ca1ab1e 5ca1-ab1e
    run_check
    expect_item p1-identity ok \
        "the disk that holds /boot and its FAT partition 1 are the ones disk_ptuuid and"
    opts='nosuid\\,nodev\\,noexec\\,ro\\,uid=0\\,gid=0\\,umask=077'
    grep -q "^mount -t vfat -o $opts /dev/sdb1 $dir\$" "$STUB_LOG"
    refute_line_match '^mount -t ntfs|\\,rw' "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "${output,,}${stderr,,}" != *5ca1-ab1e* ]]
}

@test "boot-menu names the hypervisor and which menu ends a linux line with the kernel's command line" {
    local line="the running kernel's command line ends" args="root=/dev/mapper/kali--vg-root ro"
    # Without a command line beside BOOT_IMAGE, nothing is told.
    rm "$ROOT/proc/cmdline"
    run_check
    expect_item boot-menu skip "/proc/cmdline holds no command line beside BOOT_IMAGE"
    printf 'BOOT_IMAGE=/vmlinuz\n' > "$ROOT/proc/cmdline"
    run_check
    expect_item boot-menu skip "/proc/cmdline holds no command line beside BOOT_IMAGE"
    # kali.cfg's entry, in VMware.
    printf 'BOOT_IMAGE=/vmlinuz %s quiet\n' "$args" > "$ROOT/proc/cmdline"
    export VIRT=vmware
    run_check
    expect_item boot-menu ok "hypervisor: vmware; $line 1 linux line(s) of the stick's menu and 0"
    expect_item boot-menu ok "and 0 of /boot/grub/grub.cfg, so the stick's menu booted it"
    # grub.cfg counts too, CRLF and with other blanks between the words, and so do linux16 and
    # Kali's own menu.
    write_grub_cfg $'\t  linux16\t/vmlinuz-x   root=/dev/mapper/kali--vg-root ro  quiet  '
    mkdir -p "$ROOT/boot/grub"
    printf '\tlinux /vmlinuz-%s %s quiet\n' "$V2" "$args" > "$ROOT/boot/grub/grub.cfg"
    run_check
    expect_item boot-menu ok "$line 2 linux line(s) of the stick's menu and 1 of /boot/grub/grub.cfg,"
    expect_item boot-menu ok "so either menu may have booted it"
    # Kali's own menu alone.
    write_grub_cfg
    printf '\tlinux /vmlinuz-%s root=UUID=x ro quiet\n' "$V2" > "$ROOT/boot/grub/grub.cfg"
    printf 'BOOT_IMAGE=/vmlinuz-%s root=UUID=x ro quiet\n' "$V2" > "$ROOT/proc/cmdline"
    run_check
    expect_item boot-menu ok "$line 0 linux line(s) of the stick's menu and 1 of /boot/grub/grub.cfg,"
    expect_item boot-menu ok "so Kali's own menu booted it"
    # A line that goes on past the command line, a comment and another command do not count.
    printf 'BOOT_IMAGE=/vmlinuz %s\n' "$args" > "$ROOT/proc/cmdline"
    write_grub_cfg "# linux /vmlinuz $args" "	echo linux /vmlinuz $args"
    run_check
    expect_item boot-menu ok "$line 0 linux line(s) of the stick's menu and 0 of /boot/grub/grub.cfg,"
    expect_item boot-menu ok "so which menu booted it cannot be told"
    # A symlink on the stick is not followed.
    rm "$GRUB/kali.cfg"
    ln -s grub.cfg "$GRUB/kali.cfg"
    run_check
    expect_item boot-menu skip "multibootusb/grub/kali.cfg or a directory on its way is a symlink"
    # A file of the stick's menu that cannot be read gives no verdict.
    rm "$GRUB/kali.cfg"
    mkdir "$GRUB/kali.cfg"
    run_check
    expect_item boot-menu skip "multibootusb/grub/kali.cfg cannot be read"
    rmdir "$GRUB/kali.cfg"
    write_kali_cfg
    # A hypervisor name that is no plain word counts as unknown.
    export VIRT='vm ware!'
    run_check
    expect_item boot-menu ok "hypervisor: unknown;"
}

@test "p1-identity fails on another stick or none, and the other partition-1 items skip" {
    local name
    stick_from_boot
    write_config 2.02 5ca1ab1e-0000-4000-8000-000000000d01
    run_check
    [ "$status" -eq 2 ]
    expect_item p1-identity fail "the disk that holds /boot is not the one disk_ptuuid names"
    for name in grub-version tripwire deployed kali-cfg kali-menu boot-menu; do
        expect_item "$name" skip "partition 1 is not the one disk_ptuuid and p1_fs_uuid name"
    done
    refute_line_match '^mount -t ' "$STUB_LOG"
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$output$stderr" != */dev/sd* ]]
    export LSBLK_FAIL=1
    run_check
    [ "$status" -eq 2 ]
    expect_item p1-identity fail "partition 1 cannot be found from /boot: lsblk cannot list"
    expect_item kali-cfg skip "partition 1 cannot be found from /boot: lsblk cannot list"
    export LSBLK_FAIL="" MOUNT_FAIL=1
    write_config
    run_check
    expect_item p1-identity ok "the disk that holds /boot and its NTFS partition 1"
    expect_item tripwire skip "partition 1 cannot be read: partition 1 does not mount read-only"
    [ -z "$(ls -A "$ROOT/run")" ]
}

@test "p1-identity fails when the one key that is set names another stick, which stays unread" {
    local name conf
    stick_from_boot
    printf -v conf 'grub_floor = 2.02\nboot_fs_uuid = %s\nboot_luks_uuid = %s\n' \
        5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c01
    printf '%sdisk_ptuuid = %s\n' "$conf" 5ca1ab1e-0000-4000-8000-000000000d01 \
        > "$ROOT/etc/kernel-updater.conf"
    run_check
    [ "$status" -eq 2 ]
    expect_item p1-identity fail "the disk that holds /boot is not the one disk_ptuuid names"
    for name in grub-version tripwire deployed kali-cfg kali-menu boot-menu; do
        expect_item "$name" skip "partition 1 is not the one disk_ptuuid and p1_fs_uuid name"
    done
    refute_line_match '^mount -t ' "$STUB_LOG"
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$output$stderr" != */dev/sd* ]]
    # The one key that is set matches: the item skips, and the others read partition 1.
    printf '%sdisk_ptuuid = 5ca1ab1e\n' "$conf" > "$ROOT/etc/kernel-updater.conf"
    run_check
    expect_item p1-identity skip "disk_ptuuid and p1_fs_uuid are not both set"
    expect_item kali-cfg skip "multibootusb/grub/kali.cfg does not exist yet"
    grep -q '^mount -t ntfs3 ' "$STUB_LOG"
}

@test "grub-version fails below grub_floor, warns when unknown, and names a higher floor" {
    normal_mod 2.02
    record_baseline
    write_config 2.06
    run_check
    [ "$status" -eq 2 ]
    expect_item grub-version fail "the stick's GRUB 2.02 is older than grub_floor 2.06, so lint"
    expect_item grub-version fail "set grub_floor = 2.02 or update the stick's GRUB"
    write_config
    run_check
    [ "$status" -eq 0 ]
    expect_item grub-version ok "the stick's GRUB is 2.02 and grub_floor is 2.02"
    normal_mod 2.12~rc1
    run_check
    expect_item grub-version ok "the stick's GRUB is 2.12~rc1 and grub_floor is 2.02;"
    expect_item grub-version ok "grub_floor = 2.12 would let lint and check accept what GRUB"
    # A version string must stand alone, and only one may.
    normal_mod 2.06-13+deb12u1 "GRUB 2.14" 2.1 2.14x
    run_check
    expect_item grub-version ok "the stick's GRUB is 2.06-13+deb12u1 and grub_floor is 2.02;"
    normal_mod 2.06 2.12
    run_check
    expect_item grub-version warn "the stick's GRUB version is unknown: multibootusb/grub"
    rm "$GRUB/i386-pc/normal.mod"
    run_check
    expect_item grub-version warn "normal.mod is missing or names no single version"
}

@test "tripwire warns without a baseline, and fails on changed, new and missing entries" {
    rm "$ROOT/var/lib/kernel-updater/baseline"
    run_check
    [ "$status" -eq 0 ]
    expect_item tripwire warn "no baseline is stored: run 'kernel-updater baseline' to record"
    record_baseline
    printf 'changed\r\n' >> "$GRUB/grub.cfg"
    printf 'menuentry "Windows" {\n}\n' > "$GRUB/win.cfg"
    rm "$GRUB/i386-pc/moddep.lst"
    poke_byte "$KU_P1_DISK" 7
    run_check
    [ "$status" -eq 2 ]
    expect_item tripwire fail "changed: mbr:boot-code, multibootusb/grub/grub.cfg; new:"
    expect_item tripwire fail "new: multibootusb/grub/win.cfg; missing:"
    expect_item tripwire fail "missing: multibootusb/grub/i386-pc/moddep.lst since the"
    expect_item tripwire fail "run 'kernel-updater baseline' to record them"
    printf 'not a baseline\n' > "$ROOT/var/lib/kernel-updater/baseline"
    run_check
    expect_item tripwire fail "the stored baseline is damaged"
}

@test "deployed skips without an export and fails when a file differs or is missing" {
    rm "$OUT/SHA256SUMS"
    run_check
    [ "$status" -eq 0 ]
    expect_item deployed skip "output_dir holds no export (no SHA256SUMS)"
    printf '%s  kali.cfg\n%s  grub.cfg\n' "$(sha256sum < "$GRUB/kali.cfg" | cut -c 1-64)" \
        "$(sha256sum < "$GRUB/grub.cfg" | cut -c 1-64)" > "$OUT/SHA256SUMS"
    printf 'changed\r\n' >> "$GRUB/grub.cfg"
    rm "$GRUB/kali.cfg"
    run_check
    [ "$status" -eq 2 ]
    expect_item deployed fail "on partition 1, kali.cfg is missing, grub.cfg differs compared"
    # The stick may have changed after a copy, so the advice is not to copy the export blindly.
    expect_item deployed fail \
        "output_dir: if you have not copied the export yet, copy it as its DEPLOY.txt says; if"
    expect_item deployed fail "do not copy it again, which would undo that change"
    printf 'not a sum\n' > "$OUT/SHA256SUMS"
    run_check
    expect_item deployed fail "output_dir's SHA256SUMS is damaged"
}

@test "kali-cfg skips without kali.cfg, fails on lint errors and warns on lint warnings" {
    # Each change of kali.cfg trips the tripwire too, so only the item is looked at.
    write_kali_cfg "insmod nosuchmod"
    run_check
    [ "$status" -eq 2 ]
    expect_item kali-cfg fail \
        "multibootusb/grub/kali.cfg has 1 error(s) and 0 warning(s) (unknown-module) with the"
    write_kali_cfg "linux /vmlinuz noswap"
    run_check
    expect_item kali-cfg warn "multibootusb/grub/kali.cfg has 1 warning(s) (live-boot-param)"
    # Without the stick's lists, GRUB 2.02's stand in.
    write_kali_cfg
    rm "$GRUB/i386-pc/command.lst"
    run_check
    expect_item kali-cfg ok \
        "passes lint with GRUB 2.02's lists, since the stick's cannot be read"
    rm "$GRUB/kali.cfg"
    run_check
    expect_item kali-cfg skip "multibootusb/grub/kali.cfg does not exist yet"
}

@test "kali-menu skips before the migration, warns about legacy entries and fails half-done" {
    # Each change of grub.cfg or kali.cfg trips the tripwire too, so only the item is looked at.
    run_check
    expect_item kali-menu ok "grub.cfg sources multibootusb/grub/kali.cfg, and no legacy Kali"
    write_grub_cfg 'submenu "Kali GNU/Linux (legacy entries)" {' $'\tmenuentry "x" {' $'\t}' '}'
    run_check
    expect_item kali-menu warn "its legacy Kali entries remain: run 'kernel-updater migrate"
    expect_item kali-menu warn "--stage finalize' after the boot tests"
    mv "$GRUB/kali.cfg" "$BATS_TEST_TMPDIR/kali.cfg"
    run_check
    [ "$status" -eq 2 ]
    expect_item kali-menu fail "grub.cfg sources multibootusb/grub/kali.cfg, which is missing"
    printf 'menuentry "Kali" {\r\n\tconfigfile /multibootusb/grub/kali.cfg\r\n}\r\n' \
        > "$GRUB/grub.cfg"
    run_check
    expect_item kali-menu skip "not migrated yet: grub.cfg does not source kali.cfg"
    mv "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    run_check
    expect_item kali-menu fail "multibootusb/grub/kali.cfg exists, but grub.cfg does not source"
    write_grub_cfg 'submenu "Kali (legacy entries)" {'
    run_check
    expect_item kali-menu fail "the braces or quotes of grub.cfg do not balance"
}

@test "kali-cfg follows no symlink, which it reports as a failure" {
    use_symlinks || skip "this platform cannot make symlinks"
    # A link to a file elsewhere, which lints clean, in the place of kali.cfg.
    write_kali_cfg
    mv "$GRUB/kali.cfg" "$BATS_TEST_TMPDIR/elsewhere.cfg"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.cfg" "$GRUB/kali.cfg"
    run_check
    expect_item kali-cfg fail "multibootusb/grub/kali.cfg or a directory on its way is a symlink"
}
