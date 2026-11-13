#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of migrate
#
# Runs kernel-updater migrate on the container itself with the real linux-update-symlinks,
# dpkg and debconf, and dummy kernels whose maintainer scripts move the links as real ones do:
# the system stage points relative links in /boot at the newest and the previous kernel, after
# which kernel installs and removals move them without the tool; its rollback puts the links in
# / back; and the menu stage writes a kali.cfg and a grub.cfg that the real grub-script-check
# takes. Stubs stand in only for what a container cannot answer: /boot's LUKS mapping, uname,
# lsinitramfs and dumpe2fs.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load container

M1=9.2.1+kali-amd64 M2=9.2.2+kali-amd64 M3=9.2.3+kali-amd64

# The tmpfs on /boot and the dummy kernels, built with a real kernel's maintainer scripts.
setup_file() {
    container_setup_file
    in_test_container || return 0
    build_hooked_kernel "$M1"
    build_hooked_kernel "$M2"
    build_hooked_kernel "$M3"
}

# Each test starts before the migration: M1 and M2 installed while linux-base kept the links
# in /, M2 running, the identity detect would write, one grub-pc install device, no backups,
# and stubs that show /boot as the unlocked LUKS container of the configuration.
setup() {
    container_only
    reset_system no
    install_kernels "$M1" "$M2"
    rm -f /etc/crypttab
    if [[ -d /var/backups/kernel-updater ]]; then
        find /var/backups/kernel-updater -mindepth 1 -delete
    fi
    printf 'grub-pc grub-pc/install_devices multiselect %s\n' /dev/sda | debconf-set-selections
    stub_init
    stub_system_tools
    export UNAME_R=$M2
    printf '%s\n' "boot_fs_uuid = $BOOT_FS_UUID" \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' 'disk_ptuuid = 5ca1ab1e' \
        'p1_fs_uuid = 5CA1AB1E00000001' 'root_device = /dev/mapper/kali--vg-root' \
        > /etc/kernel-updater.conf
    export BOOT_MOUNT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*) printf '%s\n' "$BOOT_MOUNT" ;;
    *" --target "*) printf 'rw,nosuid,nodev,noexec\n' ;;
    *) exit 1 ;;
esac
EOF
    mkstub systemd-detect-virt <<< 'exit 1'
    # Each run of a stage gets a stamp of its own, however fast they follow one another.
    export DATE_COUNT="$BATS_TEST_TMPDIR/date.count"
    printf '0\n' > "$DATE_COUNT"
    mkstub date <<'EOF'
n=$(( $(< "$DATE_COUNT") + 1 ))
printf '%s\n' "$n" > "$DATE_COUNT"
printf '20261112T0900%02dZ\n' "$n"
EOF
}

# Run kernel-updater migrate ARGS on the container, with the stubs first on PATH, through bats'
# run with separate stderr.
run_migrate() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" \
        bash "$REPO_DIR/bin/kernel-updater" migrate "$@"
}

@test "The system stage links the newest and the previous kernel, and kernels then move them" {
    [ "$(readlink /vmlinuz)" = "boot/vmlinuz-$M2" ]
    run_migrate --stage system --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    assert_links "$M2" "$M1"
    [ ! -L /vmlinuz ]
    [ ! -L /initrd.img.old ]
    [ "$(readlink /var/backups/kernel-updater/20261112T090001Z/root-links/vmlinuz)" = \
        "boot/vmlinuz-$M2" ]
    grep -q -i '^link_in_boot = yes$' /etc/kernel-img.conf
    run debconf-show grub-pc
    [[ "$output" == *"grub-pc/install_devices:"* && "$output" != */dev/sda* ]]
    # From now on linux-base moves the links as kernels come and go, without the tool.
    dpkg -i "$(kernel_deb "$M3")"
    assert_links "$M3" "$M2"
    dpkg --purge "linux-image-$M3"
    assert_links "$M2" "$M1"
    run_migrate --stage system --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"nothing to do"* ]]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* && "$stderr" != *kali--vg-root* ]]
}

@test "The rollback of the system stage puts kernel-img.conf and the links in / back" {
    run_migrate --stage system --yes
    [ "$status" -eq 0 ]
    run_migrate --rollback --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [ "$(< /etc/kernel-img.conf)" = "link_in_boot = no" ]
    [ "$(readlink /vmlinuz)" = "boot/vmlinuz-$M2" ]
    [ "$(readlink /initrd.img.old)" = "boot/initrd.img-$M1" ]
    [ -d /var/backups/kernel-updater/20261112T090001Z.rolled-back ]
}

@test "The menu stage writes a kali.cfg and a grub.cfg that grub-script-check takes" {
    local p1="$BATS_TEST_TMPDIR/p1" grub
    grub="$p1/multibootusb/grub"
    mkdir -p "$grub"
    sed 's/$/\r/' "$REPO_DIR/tests/fixtures/grub/migrate-before.cfg" > "$grub/grub.cfg"
    run_migrate --stage system --yes
    [ "$status" -eq 0 ]
    run --separate-stderr env PATH="$STUB_BIN:$PATH" KU_TEST=1 KU_P1_DIR="$p1" \
        TMPDIR="$BATS_TEST_TMPDIR" bash "$REPO_DIR/bin/kernel-updater" migrate --stage menu \
        --deploy direct --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    cmp "$REPO_DIR/tests/fixtures/grub/kali.expected.cfg" "$grub/kali.cfg"
    sed 's/$/\r/' "$REPO_DIR/tests/fixtures/grub/migrate-after.cfg" | cmp - "$grub/grub.cfg"
    grub-script-check "$grub/kali.cfg"
    grub-script-check "$grub/grub.cfg"
    [ -z "$(find /run -maxdepth 1 -name 'kernel-updater.*' -type d)" ]
}
