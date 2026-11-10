#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of the kernel probe
#
# Puts dummy kernel packages into the states dpkg gives real ones, held, removed and
# half-configured, and checks what ku_probe_kernels reads from dpkg-query and linux-version.
# -------------------------------------------------------

load ../helpers
load container

setup_file() {
    container_setup_file
}

setup() {
    container_only
    reset_system yes
    load_ku_libs
}

@test "The kernel probe reads held, removed and half-configured kernels from dpkg" {
    install_kernels "$V1" "$V2" "$V3"
    printf 'linux-image-%s hold\n' "$V2" | dpkg --set-selections
    # The postrm stays behind, so dpkg keeps the removed kernel's config-files state.
    dpkg -r "linux-image-$V1"
    run env KU_TEST_POSTINST_FAIL=1 dpkg -i "$(kernel_deb "$V4")"
    [ "$status" -ne 0 ]
    run ku_probe_kernels
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\n' "$V1" rc "$V2" hi "$V3" ii "$V4" iF)" ]
}

@test "dpkg --configure -a, the remedy check names, finishes a half-configured kernel" {
    install_kernels "$V1"
    run env KU_TEST_POSTINST_FAIL=1 dpkg -i "$(kernel_deb "$V2")"
    [ "$status" -ne 0 ]
    [ "$(ku_probe_kernels)" = "$(printf '%s\t%s\n' "$V1" ii "$V2" iF)" ]
    # The failed postinst never reached linux-update-symlinks.
    assert_links "$V1" "$V1"
    dpkg --configure -a
    [ "$(ku_probe_kernels)" = "$(printf '%s\t%s\n' "$V1" ii "$V2" ii)" ]
    assert_links "$V2" "$V1"
}
