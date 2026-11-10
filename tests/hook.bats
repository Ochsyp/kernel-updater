#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater kernel hook checks
#
# Runs kernel-updater hook boot-guard and hook verify as the installed kernel hooks do, on a
# KU_ROOT tree with stub tools: armed and not, with /boot mounted, missing or another
# filesystem, with healthy and broken kernels, initrds and links, and in both verify_action
# modes. Hooks keep stdout empty and name no identifier.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

V=9.1.1+kali-amd64
FS_UUID=5ca1ab1e-0000-4000-8000-000000000b01
KEY_LINE="root_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c02 /etc/keys/root.key luks"

# A kernel V with its vmlinuz and a healthy initrd, a config that arms the hooks, /boot mounted
# with the filesystem it names, and linux-run-hooks' DEB_MAINT_PARAMS for a configure.
setup() {
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc"
    printf 'kernel %s\n' "$V" > "$ROOT/boot/vmlinuz-$V"
    printf 'initrd %s\n' "$V" > "$ROOT/boot/initrd.img-$V"
    write_config
    # FINDMNT_OUT is /boot's mount line; empty means /boot is not mounted.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $FS_UUID"
    mkstub findmnt <<'EOF'
[[ -n $FINDMNT_OUT ]] || exit 1
printf '%s\n' "$FINDMNT_OUT"
EOF
    # BLKID_UUID is what blkid reads from the device; empty means it finds none.
    mkstub blkid <<'EOF'
[[ -n ${BLKID_UUID:-} ]] || exit 2
printf '%s\n' "$BLKID_UUID"
EOF
    # Not root, so the config file's owner is not checked; INITRD_MODE is the initrd's mode.
    mkstub id <<< 'echo 1000'
    mkstub stat <<'EOF'
echo "${INITRD_MODE:-600}"
EOF
    stub_lsinitramfs
    export DEB_MAINT_PARAMS="configure"
}

# Write the config file: boot_fs_uuid, which arms the hooks, and any further LINES.
write_config() {
    printf 'boot_fs_uuid = %s\n' "$FS_UUID" > "$ROOT/etc/kernel-updater.conf"
    if (( $# )); then
        printf '%s\n' "$@" >> "$ROOT/etc/kernel-updater.conf"
    fi
}

# Fail unless the last run printed nothing on stdout and no UUID or key file on stderr.
quiet_and_private() {
    [ -z "$output" ]
    [[ "${stderr,,}" != *5ca1ab1e* && "$stderr" != */etc/keys* ]]
}

@test "boot-guard lets a kernel through while /boot is the filesystem boot_fs_uuid names" {
    local phase
    for phase in preinst prerm postinst; do
        run_ku hook boot-guard "$phase" "$V" "/boot/vmlinuz-$V"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        [ -z "$stderr" ]
    done
    # The UUID's case does not matter, and blkid is not asked while findmnt knows it.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 ${FS_UUID^^}"
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 0 ]
    refute_line_match '^blkid' "$STUB_LOG"
}

@test "boot-guard refuses with exit 3 while /boot is not mounted, with the phase's remedy" {
    export FINDMNT_OUT=""
    run_ku hook boot-guard preinst "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 3 ]
    quiet_and_private
    [[ "$stderr" == *"error: refusing to install kernel $V: /boot is not mounted"* ]]
    [[ "$stderr" == *"unlock and mount /boot, then run apt or dpkg again"* ]]
    run_ku hook boot-guard prerm "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: refusing to remove kernel $V: /boot is not mounted"* ]]
    run_ku hook boot-guard postinst "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: refusing to configure kernel $V: /boot is not mounted"* ]]
    [[ "$stderr" == *"then run 'dpkg --configure -a'"* ]]
}

@test "boot-guard refuses another filesystem at /boot without naming either UUID" {
    export FINDMNT_OUT="/dev/mapper/other_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b02"
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 3 ]
    quiet_and_private
    [[ "$stderr" == *"refusing to install kernel $V: the filesystem at /boot is not the one"* ]]
    [[ "$stderr" == *"mount the stick's /boot there instead, or, if /boot was made anew, set"* ]]
    [[ "$stderr" != *"unlock and mount"* ]]
    # A tmpfs over /boot has no UUID at all.
    export FINDMNT_OUT="tmpfs tmpfs "
    run_ku hook boot-guard prerm "$V"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"not the one boot_fs_uuid names"* ]]
}

@test "boot-guard reads the UUID with blkid when findmnt has none, as without udev" {
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4" BLKID_UUID=$FS_UUID
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 0 ]
    grep -q -x -F -- "blkid$(printf ' %q' -p -s UUID -o value -- /dev/mapper/boot_crypt)" \
        "$STUB_LOG"
    export BLKID_UUID=""
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 3 ]
}

@test "A mount table findmnt cannot read is told apart from an unmounted /boot" {
    load_ku_libs
    export PATH="$STUB_BIN:$PATH" FINDMNT_OUT=""
    # shellcheck disable=SC2034,SC2154 # the sourced libraries read KU_ROOT and KU_CONF
    KU_ROOT=$ROOT KU_CONF[boot_fs_uuid]=$FS_UUID
    run _ku_hook_boot_state
    [ "$output" = unmounted ]
    # A chroot without /proc has no mount table.
    _ku_hook_mounts_readable() { return 1; }
    run _ku_hook_boot_state
    [ "$output" = unreadable ]
    run _ku_hook_problem unreadable
    [ "$output" = "findmnt cannot read the mount table, so /boot may not be mounted" ]
    run _ku_hook_remedy unreadable "run apt again"
    [ "$output" = "mount /proc, as a chroot needs, then run apt again" ]
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $FS_UUID"
    run _ku_hook_boot_state
    [ -z "$output" ]
}

@test "Without boot_fs_uuid, boot-guard only warns" {
    rm "$ROOT/etc/kernel-updater.conf"
    export FINDMNT_OUT=""
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"warning: /boot is not mounted, which would make the guard refuse to"* ]]
    [[ "$stderr" == *"warning: boot_fs_uuid is not set in /etc/kernel-updater.conf"* ]]
    # Without a problem it says nothing at all.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $FS_UUID"
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "The postinst guard acts only when the kernel is configured" {
    stub_refuse findmnt
    export DEB_MAINT_PARAMS="triggered"
    run_ku hook boot-guard postinst "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_LOG" ]
    # Run by hand, without DEB_MAINT_PARAMS, it acts.
    unset DEB_MAINT_PARAMS
    run_ku hook boot-guard postinst "$V"
    [ "$status" -eq 3 ]
}

@test "A bad config file stops the hooks with exit 78" {
    printf 'boot_fs_uuid = not-a-uuid\n' > "$ROOT/etc/kernel-updater.conf"
    run_ku hook boot-guard preinst "$V"
    [ "$status" -eq 78 ]
    run_ku hook verify "$V"
    [ "$status" -eq 78 ]
}

@test "The hook command refuses a missing or unknown hook, phase or kernel with exit 64" {
    local args
    for args in "hook" "hook bogus" "hook boot-guard" "hook boot-guard preinst" \
        "hook boot-guard postrm $V" "hook boot-guard preinst ../$V" \
        "hook boot-guard preinst $V /boot/vmlinuz-$V extra" "hook verify" "hook verify -x" \
        "hook apt-guard extra"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku $args
        [ "$status" -eq 64 ] || { printf 'args "%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [ -z "$output" ]
    done
    run_ku hook --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: kernel-updater hook boot-guard "* ]]
}

@test "verify passes a kernel whose vmlinuz and initrd would boot it" {
    run_ku hook verify "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"info: kernel $V passes: its initrd holds its modules, cryptsetup, the"* ]]
    [[ "$stderr" != *warning* && "$stderr" != *"key files"* ]]
    # With a key file in crypttab, the initrd must hold key files, which the stub lists.
    printf '%s\n' "$KEY_LINE" > "$ROOT/etc/crypttab"
    run_ku hook verify "$V"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cryptroot configuration and the key files"* ]]
    quiet_and_private
}

@test "verify fails with exit 2 when the initrd lacks what root needs, or warns if asked to" {
    export LSINITRAMFS_DROP='^cryptroot'
    run_ku hook verify "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: kernel $V may not boot from the stick: the initrd of $V lacks"* ]]
    [[ "$stderr" == *"lacks the cryptroot configuration"* ]]
    [[ "$stderr" == *"'update-initramfs -u -k $V' rebuilds its initrd"* ]]
    # With the links in /, as before migrate, the stick's entries name versions themselves.
    [[ "$stderr" != *"already point at"* ]]
    write_config "verify_action = warn"
    run_ku hook verify "$V"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: kernel $V may not boot from the stick: the initrd of $V lacks"* ]]
    [[ "$stderr" != *error:* ]]
}

@test "verify names each problem: vmlinuz, a missing or unreadable initrd, missing key files" {
    : > "$ROOT/boot/vmlinuz-$V"
    run_ku hook verify "$V"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"may not boot from the stick: /boot/vmlinuz-$V is missing or empty"* ]]
    rm "$ROOT/boot/vmlinuz-$V" "$ROOT/boot/initrd.img-$V"
    run_ku hook verify "$V"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"/boot/vmlinuz-$V is missing or empty; $V has no initrd"* ]]
    printf 'kernel\n' > "$ROOT/boot/vmlinuz-$V"
    printf 'initrd\n' > "$ROOT/boot/initrd.img-$V"
    export LSINITRAMFS_FAIL=$V
    run_ku hook verify "$V"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"lsinitramfs cannot read the initrd of $V"* ]]
    unset LSINITRAMFS_FAIL
    printf '%s\n' "$KEY_LINE" > "$ROOT/etc/crypttab"
    export LSINITRAMFS_DROP='^cryptroot/keyfiles'
    run_ku hook verify "$V"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"lacks the key files crypttab names, so root would ask for a second"* ]]
    quiet_and_private
}

@test "verify checks the four /boot links while linux-base keeps them there" {
    use_symlinks || skip "this platform cannot make symlinks"
    printf 'link_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    ln -s "vmlinuz-$V" "$ROOT/boot/vmlinuz"
    ln -s "initrd.img-$V" "$ROOT/boot/initrd.img"
    ln -s "vmlinuz-$V" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-9.0.2+kali-amd64" "$ROOT/boot/initrd.img.old"
    run_ku hook verify "$V"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"in /boot, initrd.img.old does not reach a non-empty file in /boot"* ]]
    # The links already moved to the kernel that failed, which the message says.
    [[ "$stderr" == *"error: /boot/vmlinuz and /boot/initrd.img already point at kernel $V:"* ]]
    [[ "$stderr" == *"boot the previous kernel, which vmlinuz.old and initrd.img.old point at"* ]]
    rm "$ROOT/boot/initrd.img.old"
    ln -s "initrd.img-$V" "$ROOT/boot/initrd.img.old"
    run_ku hook verify "$V"
    [ "$status" -eq 0 ]
    # With the links in /, they are not the stick's concern.
    printf 'link_in_boot = no\n' > "$ROOT/etc/kernel-img.conf"
    rm "$ROOT/boot/vmlinuz"
    run_ku hook verify "$V"
    [ "$status" -eq 0 ]
}

@test "verify warns about an initrd with key files that group or others can read" {
    export INITRD_MODE=644
    run_ku hook verify "$V"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: the initrd of $V holds key files and is readable by group"* ]]
}

@test "Without boot_fs_uuid, verify only warns" {
    rm "$ROOT/etc/kernel-updater.conf"
    export LSINITRAMFS_DROP='^usr/sbin/cryptsetup'
    run_ku hook verify "$V"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: kernel $V may not boot from the stick: the initrd of $V lacks"* ]]
    [[ "$stderr" == *"lacks cryptsetup"* && "$stderr" == *"so the kernel-updater hooks only warn"* ]]
}

@test "verify does nothing unless the kernel is configured" {
    stub_refuse lsinitramfs
    rm "$ROOT/boot/initrd.img-$V"
    export DEB_MAINT_PARAMS="abort-configure"
    run_ku hook verify "$V" "/boot/vmlinuz-$V"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ ! -s "$STUB_LOG" ]
}
