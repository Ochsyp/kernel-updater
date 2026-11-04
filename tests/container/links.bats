#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of the kernel links
#
# Installs and removes dummy kernel packages whose maintainer scripts call linux-update-symlinks,
# and checks where linux-base points vmlinuz, initrd.img and their .old links in /boot.
# -------------------------------------------------------

load ../helpers
load container

setup_file() {
    container_setup_file
}

setup() {
    container_only
    reset_system yes
}

@test "Two calls, the previous kernel first, put vmlinuz on the newest and vmlinuz.old on it" {
    reset_system no
    install_kernels "$V1" "$V2" "$V3"
    # With link_in_boot = no the links are in / and point into boot/.
    [ "$(readlink /vmlinuz)" = "boot/vmlinuz-$V3" ]
    [ ! -L /boot/vmlinuz ]
    printf 'link_in_boot = yes\n' > /etc/kernel-img.conf
    linux-update-symlinks install "$V2" "/boot/vmlinuz-$V2"
    linux-update-symlinks install "$V3" "/boot/vmlinuz-$V3"
    assert_links "$V3" "$V2"
    # The probe sees four relative links that reach non-empty files in /boot.
    load_ku_libs
    run ku_probe_boot_links
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t1\t1\n' vmlinuz "vmlinuz-$V3" vmlinuz.old "vmlinuz-$V2" \
        initrd.img "initrd.img-$V3" initrd.img.old "initrd.img-$V2")" ]
}

@test "The opposite order leaves vmlinuz on the previous kernel" {
    reset_system no
    install_kernels "$V1" "$V2" "$V3"
    printf 'link_in_boot = yes\n' > /etc/kernel-img.conf
    linux-update-symlinks install "$V3" "/boot/vmlinuz-$V3"
    linux-update-symlinks install "$V2" "/boot/vmlinuz-$V2"
    assert_links "$V2" "$V3"
}

@test "Installing a kernel moves vmlinuz to it and vmlinuz.old to the kernel vmlinuz left" {
    install_kernels "$V1"
    assert_links "$V1" "$V1"
    install_kernels "$V2"
    assert_links "$V2" "$V1"
    install_kernels "$V3"
    assert_links "$V3" "$V2"
}

@test "Reinstalling a kernel is an upgrade, which leaves the links where they were" {
    install_kernels "$V1" "$V2"
    # dpkg passes the installed version to postinst configure, so the dummy postinst calls
    # linux-update-symlinks upgrade; install would move vmlinuz to the reinstalled kernel.
    dpkg -i "$(kernel_deb "$V1")"
    assert_links "$V2" "$V1"
}

@test "Removing kernels moves the links to the newest kernels left" {
    install_kernels "$V1" "$V2" "$V3"
    dpkg -r "linux-image-$V3"
    assert_links "$V2" "$V1"
    dpkg -r "linux-image-$V1"
    assert_links "$V2" "$V2"
}
