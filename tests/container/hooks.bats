#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of the installed hooks
#
# Installs kernel-updater with install.sh into the container and drives its hooks through real
# dpkg, apt-get and linux-run-hooks runs: dummy kernels whose maintainer scripts run the kernel
# hooks as real kernels do, an ext4 image with a synthetic UUID as /boot, and a stub only for
# lsinitramfs, which a container cannot answer.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load container

K1=9.1.1+kali-amd64 K2=9.1.2+kali-amd64 K3=9.1.3+kali-amd64 K4=9.1.4+kali-amd64
FS_UUID=5ca1ab1e-0000-4000-8000-000000000b01

# Build the dummy kernels: K3 split into linux-image and linux-binary, K4 with its vmlinuz in
# /usr/lib/modules; a dummy grub-pc and an unrelated dummy; and install kernel-updater from the
# read-only checkout.
setup_file() {
    in_test_container || return 0
    build_hooked_kernel "$K1"
    build_hooked_kernel "$K2"
    build_hooked_kernel "$K3" split
    build_hooked_kernel "$K4" usrlib
    build_package grub-pc "Version: 2.99-1"
    build_package ku-test-tool "Version: 1.0-1"
    bash "$REPO_DIR/install.sh"
}

# Disarm the hooks, remove the dummies and kernel-updater, and unmount /boot, so the next file
# finds the container as container_setup_file expects it.
teardown_file() {
    in_test_container || return 0
    reset_hooks
    bash "$REPO_DIR/install.sh" --uninstall
    unmount_boot
}

# Each test starts with no dummy installed, link_in_boot on, a fresh ext4 /boot whose UUID the
# config names, and an lsinitramfs stub that lists a healthy initrd without key files.
setup() {
    container_only
    reset_hooks
    make_boot_image "$FS_UUID"
    mount_boot_image
    printf 'boot_fs_uuid = %s\n' "$FS_UUID" > /etc/kernel-updater.conf
    stub_init
    stub_lsinitramfs
    export LSINITRAMFS_DROP='^cryptroot/keyfiles' DEBIAN_FRONTEND=noninteractive
    export PATH="$STUB_BIN:$PATH"
}

# Disarm the hooks, purge every dummy whatever its state, and clear grub-pc's answer and the
# crypttab an earlier file may have left.
reset_hooks() {
    local -a packages=()
    rm -f /etc/kernel-updater.conf /etc/crypttab
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
    mapfile -t packages < <(dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}\n' \
        'linux-image-9.1.*' 'linux-binary-9.1.*' grub-pc ku-test-tool 2> /dev/null |
        awk '$1 !~ /^.n$/ { print $2 }')
    if (( ${#packages[@]} )); then
        dpkg --force-remove-reinstreq --purge "${packages[@]}" > /dev/null 2>&1
    fi
    printf 'link_in_boot = yes\n' > /etc/kernel-img.conf
    printf 'grub-pc grub-pc/install_devices multiselect \n' | debconf-set-selections
}

# Print what lies in /boot while nothing is mounted there: entries that are no symlink when
# ANY is unset, every entry otherwise.
unmounted_boot_entries() {
    if [[ -n ${1:-} ]]; then
        find /boot -mindepth 1
    else
        find /boot -mindepth 1 ! -type l
    fi
}

# Fail unless package NAME is unknown to dpkg or not installed.
not_installed() {
    local state
    state=$(package_state "$1")
    [[ -z $state || $state == ?n* ]] || { printf '%s is %s\n' "$1" "$state" >&2; return 1; }
}

@test "install.sh puts the hooks where linux-run-hooks and apt run them, in order" {
    local i guard=-1 legacy=-1 verify=-1
    # The guard runs before linux-base's 00-legacy-boot copies a kernel to /boot, and the check
    # after it, as after initramfs-tools and dkms, whose hooks sort before it by name too.
    run run-parts --test /etc/kernel/postinst.d /usr/share/kernel/postinst.d
    [ "$status" -eq 0 ]
    for i in "${!lines[@]}"; do
        case ${lines[i]} in
            /etc/kernel/postinst.d/00-kernel-updater) guard=$i ;;
            /usr/share/kernel/postinst.d/00-legacy-boot) legacy=$i ;;
            /etc/kernel/postinst.d/kernel-updater) verify=$i ;;
        esac
    done
    (( guard == 0 && legacy > guard && verify > legacy )) ||
        { printf 'postinst order:\n%s\n' "$output" >&2; return 1; }
    run run-parts --test /etc/kernel/preinst.d
    [ "${lines[0]}" = /etc/kernel/preinst.d/00-kernel-updater ]
    run run-parts --test /etc/kernel/prerm.d /usr/share/kernel/prerm.d
    [ "${lines[0]}" = /etc/kernel/prerm.d/00-kernel-updater ]
    run apt-config dump
    [[ "${output,,}" == *'::pre-install-pkgs:: "/usr/local/lib/kernel-updater/apt-guard || '* ]]
    [[ "${output,,}" == *'::options::/usr/local/lib/kernel-updater/apt-guard::version "3";'* ]]
}

@test "A kernel with its vmlinuz in /usr/lib/modules passes once linux-base copies it to /boot" {
    run --separate-stderr dpkg -i "$(kernel_deb "$K4")"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: kernel $K4 passes"* ]]
    [ -s "/boot/vmlinuz-$K4" ]
    [ "$(package_state "linux-image-$K4")" = ii ]
}

@test "A kernel installs, configures and passes the check while the right /boot is mounted" {
    run --separate-stderr dpkg -i "$(kernel_deb "$K1")"
    [ "$status" -eq 0 ]
    [ "$(package_state "linux-image-$K1")" = ii ]
    [[ "$stderr" == *"info: kernel $K1 passes"* ]]
    [ -s "/boot/vmlinuz-$K1" ]
    [ "$(readlink /boot/vmlinuz)" = "vmlinuz-$K1" ]
}

@test "dpkg -i is refused while /boot is not mounted, and nothing lands in /boot" {
    unmount_boot
    run --separate-stderr dpkg -i "$(kernel_deb "$K1")"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"error: refusing to install kernel $K1: /boot is not mounted"* ]]
    not_installed "linux-image-$K1"
    [ -z "$(unmounted_boot_entries any)" ]
}

@test "dpkg -i is refused while another filesystem is mounted on /boot" {
    unmount_boot
    mount -t tmpfs -o mode=0755 tmpfs /boot
    run --separate-stderr dpkg -i "$(kernel_deb "$K1")"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"the filesystem at /boot is not the one boot_fs_uuid names"* ]]
    [[ "$stderr" != *5ca1ab1e* ]]
    [ -z "$(find /boot -mindepth 1)" ]
}

@test "Removing a kernel is refused while /boot is not mounted, and it stays installed" {
    dpkg -i "$(kernel_deb "$K1")"
    unmount_boot
    run --separate-stderr dpkg -r "linux-image-$K1"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"error: refusing to remove kernel $K1: /boot is not mounted"* ]]
    [ "$(package_state "linux-image-$K1")" = ii ]
    # Once /boot is back, the removal goes through.
    mount_boot_image
    run dpkg -r "linux-image-$K1"
    [ "$status" -eq 0 ]
    [ ! -e "/boot/vmlinuz-$K1" ]
}

@test "The postinst check leaves a kernel half-configured whose initrd lacks cryptroot" {
    export LSINITRAMFS_DROP='^cryptroot'
    run --separate-stderr dpkg -i "$(kernel_deb "$K4")"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"error: kernel $K4 may not boot from the stick: the initrd of $K4 lacks"* ]]
    [[ "$stderr" == *"error: /boot/vmlinuz and /boot/initrd.img already point at kernel $K4"* ]]
    [ "$(package_state "linux-image-$K4")" = iF ]
    # A configure while /boot is not mounted is refused before 00-legacy-boot copies the
    # kernel there; the kernel's postinst moves the links before any hook runs, so only links
    # can land there.
    unmount_boot
    run --separate-stderr dpkg --configure -a
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"error: refusing to configure kernel $K4: /boot is not mounted"* ]]
    [ "$(package_state "linux-image-$K4")" = iF ]
    [ -z "$(unmounted_boot_entries)" ]
    # With /boot back and a sound initrd, the configure finishes.
    find /boot -mindepth 1 -delete
    mount_boot_image
    export LSINITRAMFS_DROP='^cryptroot/keyfiles'
    run dpkg --configure -a
    [ "$status" -eq 0 ]
    [ "$(package_state "linux-image-$K4")" = ii ]
}

@test "verify_action = warn lets a kernel through whose initrd lacks cryptroot" {
    printf 'verify_action = warn\n' >> /etc/kernel-updater.conf
    export LSINITRAMFS_DROP='^cryptroot'
    run --separate-stderr dpkg -i "$(kernel_deb "$K1")"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: kernel $K1 may not boot from the stick"* ]]
    [ "$(package_state "linux-image-$K1")" = ii ]
}

@test "apt-get installs a kernel while the right /boot is mounted" {
    run --separate-stderr apt-get install --yes "$(kernel_deb "$K2")"
    [ "$status" -eq 0 ]
    [ "$(package_state "linux-image-$K2")" = ii ]
    [[ "$stderr" != *apt-guard* ]]
}

@test "apt-get refuses a split kernel while /boot is not mounted, before dpkg unpacks any part" {
    unmount_boot
    run --separate-stderr apt-get install --yes "$(package_deb "linux-binary-$K3")" \
        "$(kernel_deb "$K3")"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"/boot is not mounted, and this apt run changes"* ]]
    [[ "$stderr" == *"apt-guard refused this apt run; nothing was changed"* ]]
    not_installed "linux-binary-$K3"
    not_installed "linux-image-$K3"
    [ -z "$(unmounted_boot_entries any)" ]
}

@test "apt-get refuses a run that only removes a kernel while /boot is not mounted" {
    dpkg -i "$(kernel_deb "$K1")"
    unmount_boot
    run --separate-stderr apt-get remove --yes "linux-image-$K1"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"this apt run changes linux-image-$K1:"* ]]
    [ "$(package_state "linux-image-$K1")" = ii ]
}

@test "apt-get runs an unrelated package while /boot is not mounted" {
    unmount_boot
    run --separate-stderr apt-get install --yes "$(package_deb ku-test-tool)"
    [ "$status" -eq 0 ]
    [ "$(package_state ku-test-tool)" = ii ]
    [[ "$stderr" != *kernel-updater* ]]
}

@test "apt-get refuses grub-pc while grub-pc/install_devices names a device" {
    printf 'grub-pc grub-pc/install_devices multiselect %s\n' /dev/sda | debconf-set-selections
    run --separate-stderr apt-get install --yes "$(package_deb grub-pc)"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"grub-pc/install_devices names 1 device(s)"* ]]
    [[ "$stderr" != */dev/sda* ]]
    not_installed grub-pc
    printf 'grub-pc grub-pc/install_devices multiselect \n' | debconf-set-selections
    run --separate-stderr apt-get install --yes "$(package_deb grub-pc)"
    [ "$status" -eq 0 ]
    [ "$(package_state grub-pc)" = ii ]
}

@test "Without the tool the kernel hooks let dpkg through, and without apt-guard apt goes on" {
    local tool=/usr/local/bin/kernel-updater guard=/usr/local/lib/kernel-updater/apt-guard
    unmount_boot
    mv "$tool" "$BATS_TEST_TMPDIR/tool"
    run --separate-stderr dpkg -i "$(kernel_deb "$K1")"
    mv "$BATS_TEST_TMPDIR/tool" "$tool"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: $tool is missing, so the /boot guard did not run"* ]]
    [[ "$stderr" == *"warning: $tool is missing, so the new kernel was not checked"* ]]
    # The kernel hooks' messages go to stderr, never to dpkg's stdout.
    [[ "$output" != *kernel-updater* ]]
    # Without apt-guard the run reaches dpkg, where the prerm guard refuses the removal.
    mv "$guard" "$BATS_TEST_TMPDIR/apt-guard"
    run --separate-stderr apt-get remove --yes "linux-image-$K1"
    mv "$BATS_TEST_TMPDIR/apt-guard" "$guard"
    [ "$status" -ne 0 ]
    [[ "$stderr" != *"apt-guard refused"* ]]
    [[ "$stderr" == *"error: refusing to remove kernel $K1: /boot is not mounted"* ]]
    [ "$(package_state "linux-image-$K1")" = ii ]
}

@test "Without boot_fs_uuid the hooks only warn" {
    rm /etc/kernel-updater.conf
    unmount_boot
    run --separate-stderr dpkg -i "$(kernel_deb "$K1")"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: /boot is not mounted, which would make the guard refuse"* ]]
    [[ "$stderr" == *"so the kernel-updater hooks only warn"* ]]
    [ "$(package_state "linux-image-$K1")" = ii ]
}
