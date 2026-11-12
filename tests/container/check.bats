#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of the check command
#
# Runs kernel-updater check on the container itself: dpkg, linux-base, a tmpfs on /boot, real
# mounts and debconf, with stubs only for uname and lsinitramfs, which a container cannot answer.
# -------------------------------------------------------

load ../helpers
load container

setup_file() {
    container_setup_file
}

# Two dummy kernels installed with link_in_boot = yes, the newer one running, nothing hidden
# under /boot, one device named by UUID, no crypttab, no config file and no grub-pc devices.
setup() {
    container_only
    reset_system yes
    install_kernels "$V1" "$V2"
    shadow_boot 0
    printf 'UUID=5ca1ab1e-0000-4000-8000-000000000b01 /boot ext4 defaults 0 2\n' > /etc/fstab
    rm -f /etc/crypttab /etc/kernel-updater.conf
    printf 'grub-pc grub-pc/install_devices multiselect \n' | debconf-set-selections
    stub_init
    # The container runs the host's kernel, and a dummy kernel has no initrd to list; without a
    # key file in crypttab, the listed initrds hold none either.
    stub_uname
    stub_lsinitramfs
    export UNAME_R=$V2 LSINITRAMFS_DROP='^cryptroot/keyfiles'
}

@test "check passes the container's items, and fails boot-luks because a tmpfs is no LUKS" {
    run_container_check
    [ "$status" -eq 2 ]
    expect_item boot-mounted ok "/boot is a separate tmpfs mount"
    expect_item boot-identity warn "boot_fs_uuid is not set"
    expect_item boot-shadowed ok "nothing hides under the /boot mount point"
    expect_item kernel-img ok "linux-base keeps the links in /boot"
    expect_item boot-links ok "the 4 links are relative and reach non-empty files in /boot"
    expect_item stale-root-links ok "no vmlinuz or initrd.img entries are left in /"
    expect_item kernels ok "2 installed, running $V2"
    expect_item reboot-pending ok "the running kernel is the one /boot/vmlinuz points at"
    expect_item initrd ok "2 initrd(s) hold their modules, cryptsetup and the cryptroot"
    expect_item boot-luks fail "/boot is not in an open LUKS container"
    expect_item boot-ext skip "/boot is tmpfs, not ext2, ext3 or ext4"
    expect_item fstab-crypttab ok "1 device(s) named by UUID= or another stable name"
    expect_item grub-pc ok "grub-pc/install_devices is empty"
    # The tmpfs on /boot lies on no disk, so there is no partition 1 to look at.
    expect_item p1-identity skip "disk_ptuuid and p1_fs_uuid are not both set"
    local name
    for name in grub-version tripwire deployed kali-cfg; do
        expect_item "$name" skip \
            "partition 1 cannot be found from /boot: the filesystem at /boot is on no block device"
    done
    [ "${#lines[@]}" -eq 18 ]
    # fstab names /boot by a synthetic UUID, which no detail or message repeats.
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* ]]
}

@test "boot-shadowed counts what the tmpfs on /boot hides and leaves no bind mount behind" {
    shadow_boot 2
    run_container_check
    expect_item boot-shadowed warn "2 entries hide under the /boot mount point"
    # The tmpfs on /boot shows that findmnt lists the mounts; none is check's any more.
    run findmnt -r -n -o TARGET
    [ "$status" -eq 0 ]
    [[ $'\n'"$output"$'\n' == *$'\n/boot\n'* ]]
    [[ "$output" != *kernel-updater* ]]
    [ -z "$(find /run -maxdepth 1 -name 'kernel-updater.*' -type d)" ]
    [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'kernel-updater.*')" ]
}

@test "kernels and reboot-pending follow the dpkg states and the links linux-base set" {
    export UNAME_R=$V1
    printf 'linux-image-%s hold\n' "$V1" | dpkg --set-selections
    run_container_check
    expect_item kernels ok "2 installed, 1 held, running $V1"
    expect_item reboot-pending warn "/boot/vmlinuz points at $V2, but $V1 is running"
    run env KU_TEST_POSTINST_FAIL=1 dpkg -i "$(kernel_deb "$V3")"
    [ "$status" -ne 0 ]
    run_container_check
    expect_item kernels fail "$V3 is half-configured (iF): run dpkg --configure -a"
    dpkg --configure -a
    run_container_check
    expect_item kernels ok "3 installed, 1 held, running $V1"
    expect_item reboot-pending warn "/boot/vmlinuz points at $V3, but $V1 is running"
}

@test "stale-root-links finds the links an install left in / before link_in_boot was on" {
    reset_system no
    install_kernels "$V1" "$V2"
    printf 'link_in_boot = yes\n' > /etc/kernel-img.conf
    linux-update-symlinks install "$V1" "/boot/vmlinuz-$V1"
    linux-update-symlinks install "$V2" "/boot/vmlinuz-$V2"
    run_container_check
    expect_item stale-root-links warn "4 vmlinuz or initrd.img entries are left in /"
    expect_item boot-links ok "the 4 links are relative"
}

@test "initrd reads the mode of the initrd files when crypttab names a key file" {
    printf 'root_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c02 /etc/keys/root.key luks\n' \
        > /etc/crypttab
    export LSINITRAMFS_DROP=""
    # dpkg installed the dummy initrds with mode 0644.
    run_container_check
    expect_item initrd warn "the initrd of $V1, $V2 holds key files and is readable by group"
    chmod 600 "/boot/initrd.img-$V1" "/boot/initrd.img-$V2"
    run_container_check
    expect_item initrd ok "2 initrd(s) hold their modules, cryptsetup, the cryptroot"
    [[ "$output" != */etc/keys* && "$output" != *root.key* ]]
    [[ "$stderr" != */etc/keys* && "$stderr" != *root.key* ]]
}

@test "grub-pc counts the install devices debconf holds without printing them" {
    printf 'grub-pc grub-pc/install_devices multiselect %s, %s\n' /dev/sda \
        /dev/disk/by-id/usb-Synthetic_Stick_5CA1AB1E00000001-0:0 | debconf-set-selections
    run_container_check
    expect_item grub-pc fail "grub-pc/install_devices names 2 device(s)"
    [[ "$output" != */dev/sda* && "$output" != *Synthetic* && "$stderr" != *Synthetic* ]]
}
