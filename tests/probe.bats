#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater probe checks
#
# Calls the probes in lib/kernel-updater/probe.sh with stub tools and a KU_ROOT tree in the
# test's temp directory, and checks how they parse dpkg, kernel-img.conf and the boot files.
# -------------------------------------------------------

# shellcheck disable=SC2034 # the tests set the settings that the sourced libraries read
# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

setup() {
    stub_init
    load_ku_libs
    export PATH="$STUB_BIN:$PATH"
    KU_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$KU_ROOT/boot" "$KU_ROOT/etc"
    export DPKG_QUERY_OUT="$BATS_TEST_TMPDIR/dpkg-query.out"
    # Prints DPKG_QUERY_OUT and exits DPKG_QUERY_STATUS, as dpkg-query -W would. Only builtins,
    # so it also runs with nothing but the stubs on PATH.
    mkstub dpkg-query <<'EOF'
while IFS= read -r line; do printf '%s\n' "$line"; done < "$DPKG_QUERY_OUT"
exit "${DPKG_QUERY_STATUS:-0}"
EOF
    # Orders these versions as linux-base's linux-version does.
    mkstub linux-version <<'EOF'
[[ $1 == sort ]] && exec sort -V
EOF
}

# Write the lines of a dpkg-query listing: NAME and STATE pairs, each with a package version.
dpkg_lists() {
    : > "$DPKG_QUERY_OUT"
    while (( $# )); do
        printf '%s\t%s\t%s\n' "$1" "$2" 9.0-1kali1 >> "$DPKG_QUERY_OUT"
        shift 2
    done
}

@test "Each kernel version gets the state of its packages that matters most, oldest first" {
    dpkg_lists linux-image-9.0.10+kali-amd64 'ii ' linux-image-9.0.2+kali-amd64 'hi ' \
        linux-image-9.0.1+kali-amd64 'ii ' linux-modules-9.0.1+kali-amd64 'ii ' \
        linux-image-9.0.3+kali-amd64 'rc ' \
        linux-image-9.0.4+kali-amd64 'ii ' linux-binary-9.0.4+kali-amd64 'ii ' \
        linux-modules-9.0.4+kali-amd64 'iF ' linux-base-9.0.4+kali-amd64 'ii ' \
        linux-image-9.0.5+kali-amd64-unsigned 'iU ' linux-image-9.0.6+kali-amd64 iHR \
        linux-image-9.0.7+kali-amd64 'un '
    run ku_probe_kernels
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\n' 9.0.1+kali-amd64 ii 9.0.2+kali-amd64 hi \
        9.0.3+kali-amd64 rc 9.0.4+kali-amd64 iF 9.0.5+kali-amd64 iU 9.0.6+kali-amd64 iHR \
        9.0.10+kali-amd64 ii)" ]
    [[ "$(< "$STUB_LOG")" == *"dpkg-query -W -f "*" linux-image-\\* linux-binary-\\*"* ]]
    [[ "$(< "$STUB_LOG")" == *" linux-modules-\\* linux-base-\\*"* ]]
}

@test "A version counts as removed only when every one of its packages is" {
    dpkg_lists linux-image-9.0.1+kali-amd64 'rc ' linux-image-9.0.1+kali-amd64-unsigned 'ii ' \
        linux-image-9.0.2+kali-amd64 'rc ' linux-modules-9.0.2+kali-amd64 'rc ' \
        linux-image-9.0.3+kali-amd64-unsigned 'rc ' linux-image-9.0.3+kali-amd64 'hi ' \
        linux-image-9.0.4+kali-amd64 'rc ' linux-image-9.0.4+kali-amd64-unsigned 'iU '
    run ku_probe_kernels
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\n' 9.0.1+kali-amd64 ii 9.0.2+kali-amd64 rc \
        9.0.3+kali-amd64 hi 9.0.4+kali-amd64 iU)" ]
}

@test "Only versioned names count, without debug builds, and -unsigned builds join theirs" {
    dpkg_lists linux-image-9.0.1+kali-amd64 'ii ' linux-image-9.0.1+kali-amd64-dbg 'iU ' \
        linux-image-9.0.1+kali-amd64-dbgsym 'iF ' linux-image-9.0.1+kali-amd64-unsigned 'hi ' \
        linux-modules-9.0.1+kali-amd64:amd64 'ii ' linux-image-amd64 'iF ' linux-base 'iF ' \
        linux-image-unsigned-9.0.1+kali-amd64 'iF ' 'linux-image-9.0.1;id' 'iF '
    run ku_probe_kernels
    [ "$status" -eq 0 ]
    [ "$output" = $'9.0.1+kali-amd64\thi' ]
}

@test "dpkg-query's exit 1 for a pattern without a match still counts, and a failure returns 1" {
    dpkg_lists linux-image-9.0.1+kali-amd64 'ii '
    export DPKG_QUERY_STATUS=1
    run ku_probe_kernels
    [ "$status" -eq 0 ]
    [ "$output" = $'9.0.1+kali-amd64\tii' ]
    export DPKG_QUERY_STATUS=2
    run ku_probe_kernels
    [ "$status" -eq 1 ]
    : > "$DPKG_QUERY_OUT"
    export DPKG_QUERY_STATUS=1
    run ku_probe_kernels
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "linux-version orders the versions when it is installed, and sort -V when it is not" {
    local sort_bin
    dpkg_lists linux-image-9.0.1+kali-amd64 'ii ' linux-image-9.0.9+kali-amd64 'ii ' \
        linux-image-9.0.10+kali-amd64 'ii '
    # A stub with an order of its own, which sort -V never gives, shows that linux-version ran.
    mkstub linux-version <<'EOF'
[[ $1 == sort ]] && LC_ALL=C exec sort -r
EOF
    run ku_probe_kernels
    [ "$output" = $'9.0.9+kali-amd64\tii\n9.0.10+kali-amd64\tii\n9.0.1+kali-amd64\tii' ]
    grep -q '^linux-version sort$' "$STUB_LOG"
    # Without it on PATH, sort -V runs; the real linux-version may be installed, so PATH holds
    # only the stubs.
    rm "$STUB_BIN/linux-version"
    sort_bin=$(command -v sort)
    # shellcheck disable=SC2016 # the stub expands its own arguments
    printf 'exec %q "$@"\n' "$sort_bin" | mkstub sort
    # shellcheck disable=SC2016 # the inner script expands its own arguments
    run env PATH="$STUB_BIN" "$BASH" -c '. "$1"; . "$2"; ku_probe_kernels' _ \
        "$REPO_DIR/lib/kernel-updater/common.sh" "$REPO_DIR/lib/kernel-updater/probe.sh"
    [ "$status" -eq 0 ]
    [ "$output" = $'9.0.1+kali-amd64\tii\n9.0.9+kali-amd64\tii\n9.0.10+kali-amd64\tii' ]
    grep -q '^sort -V$' "$STUB_LOG"
}

@test "sort -V stands in for a failing linux-version, and a failing sort -V returns 2" {
    dpkg_lists linux-image-9.0.10+kali-amd64 'ii ' linux-image-9.0.9+kali-amd64 'ii '
    mkstub linux-version <<< 'exit 1'
    run --separate-stderr ku_probe_kernels
    [ "$status" -eq 0 ]
    [ "$output" = $'9.0.9+kali-amd64\tii\n9.0.10+kali-amd64\tii' ]
    [[ "$stderr" == *"warning: linux-version cannot sort the kernel versions; sort -V does"* ]]
    mkstub sort <<< 'exit 2'
    run ku_probe_kernels
    [ "$status" -eq 2 ]
}

@test "kernel-img.conf is read as linux-base reads it" {
    local content expected got
    # No file: linux-base's defaults.
    [ "$(ku_probe_kernel_img)" = $'do_symlinks\t1\nlink_in_boot\t0\nimage_dest\t/' ]
    # Each case: the file's content, then do_symlinks, link_in_boot and image_dest.
    while IFS='|' read -r content expected; do
        printf '%b' "$content" > "$KU_ROOT/etc/kernel-img.conf"
        got=$(ku_probe_kernel_img | cut -f 2 | tr '\n' ' ')
        if [ "$got" != "$expected " ]; then
            printf '%s: %s, not %s\n' "$content" "$got" "$expected" >&2
            return 1
        fi
    done << 'EOF'
link_in_boot = yes\n|1 1 /boot
Link_In_Boot=TRUE # links for GRUB\n|1 1 /boot
  link_in_boot = 1\r\n|1 1 /boot
link_in_boot = y\n|1 0 /
link_in_boot = yes\nlink_in_boot = no\n|1 0 /
link_in_boot = yes\nlink_in_boot = maybe\n|1 1 /boot
do_symlinks = No\nlink_in_boot = Yes|0 1 /boot
image_dest = /boot/ extra\n|1 0 /boot
image_dest = /boot\nlink_in_boot = no\n|1 0 /boot
# link_in_boot = yes\nlink_in_boot yes\n|1 0 /
do_bootloader = no\nno_symlinks = yes\n|1 0 /
EOF
}

@test "The /boot links are told apart: relative, absolute, outside /boot, empty, missing" {
    use_symlinks || skip "this platform cannot make symlinks"
    local boot="$KU_ROOT/boot"
    printf 'kernel\n' > "$boot/vmlinuz-9.0.2+kali-amd64"
    printf 'initrd\n' > "$KU_ROOT/initrd.img-9.0.2+kali-amd64"
    : > "$boot/initrd.img-9.0.1+kali-amd64"
    ln -s vmlinuz-9.0.2+kali-amd64 "$boot/vmlinuz"
    ln -s /boot/vmlinuz-9.0.2+kali-amd64 "$boot/vmlinuz.old"
    ln -s ../initrd.img-9.0.2+kali-amd64 "$boot/initrd.img"
    ln -s initrd.img-9.0.1+kali-amd64 "$boot/initrd.img.old"
    run ku_probe_boot_links
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' vmlinuz vmlinuz-9.0.2+kali-amd64 1 1 \
        vmlinuz.old /boot/vmlinuz-9.0.2+kali-amd64 0 1 \
        initrd.img ../initrd.img-9.0.2+kali-amd64 1 0 \
        initrd.img.old initrd.img-9.0.1+kali-amd64 1 0)" ]
    rm "$boot/vmlinuz" "$boot/initrd.img.old"
    printf 'kernel\n' > "$boot/vmlinuz"
    run ku_probe_boot_links
    [[ "${lines[0]}" == $'vmlinuz\t-\t0\t0' && "${lines[3]}" == $'initrd.img.old\t-\t0\t0' ]]
}

@test "crypttab and fstab entries skip comments and blank lines, and a missing key file is -" {
    local by_id=/dev/disk/by-id/usb-Synthetic_Stick_5CA1AB1E00000001-0:0-part4
    {
        printf '# <target> <source> <key file> <options>\n\n'
        printf 'boot_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c01 none luks\n'
        printf '  root_crypt\t%s  /etc/keys/root.key  luks,discard\n' "$by_id"
        printf 'swap_crypt /dev/sda5 /dev/urandom swap\n'
        printf 'nokey_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c03'
    } > "$KU_ROOT/etc/crypttab"
    run ku_probe_crypttab
    [ "$output" = "$(printf '%s\t%s\t%s\n' boot_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c01 - \
        root_crypt "$by_id" /etc/keys/root.key swap_crypt /dev/sda5 /dev/urandom \
        nokey_crypt UUID=5ca1ab1e-0000-4000-8000-000000000c03 -)" ]
    printf '# fstab\n%s /boot ext4 defaults 0 2\n\ntmpfs /tmp tmpfs' \
        UUID=5ca1ab1e-0000-4000-8000-000000000b01 > "$KU_ROOT/etc/fstab"
    run ku_probe_fstab
    [ "$output" = $'UUID=5ca1ab1e-0000-4000-8000-000000000b01\t/boot\text4\ntmpfs\t/tmp\ttmpfs' ]
    rm "$KU_ROOT/etc/crypttab"
    run ku_probe_crypttab
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "The initrd probe finds the modules, cryptsetup, the cryptroot configuration and key files" {
    local initrd=/boot/initrd.img-9.0.2+kali-amd64
    export LISTING="$BATS_TEST_TMPDIR/listing"
    mkstub lsinitramfs <<'EOF'
cat "$LISTING"
EOF
    printf '%s\n' . usr/lib/modules/9.0.2+kali-amd64 usr/lib/modules/9.0.2+kali-amd64/modules.dep \
        usr/sbin/cryptsetup cryptroot/crypttab cryptroot/keyfiles cryptroot/keyfiles/root.key \
        > "$LISTING"
    [ "$(ku_probe_initrd "$initrd" 9.0.2+kali-amd64)" = $'1\t1\t1\t1' ]
    # The older layout with ./ prefixes; another version's modules and an empty keyfiles
    # directory do not count.
    printf '%s\n' ./lib/modules/9.0.2+kali-amd64/modules.dep ./sbin/cryptsetup \
        ./cryptroot/keyfiles > "$LISTING"
    [ "$(ku_probe_initrd "$initrd" 9.0.2+kali-amd64)" = $'1\t1\t0\t0' ]
    printf '%s\n' usr/lib/modules/9.0.20+kali-amd64/modules.dep > "$LISTING"
    [ "$(ku_probe_initrd "$initrd" 9.0.2+kali-amd64)" = $'0\t0\t0\t0' ]
    grep -q "^lsinitramfs $initrd\$" "$STUB_LOG"
    export LISTING="$BATS_TEST_TMPDIR/none"
    run ku_probe_initrd "$initrd" 9.0.2+kali-amd64
    [ "$status" -eq 1 ]
}

@test "The LUKS probe reads the version, UUID and each keyslot's PBKDF of LUKS1 and LUKS2" {
    stub_system_tools
    run ku_probe_boot_luks /dev/mapper/boot_crypt
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'keyslot\t0\tpbkdf2\nkeyslot\t1\tpbkdf2\nversion\t1\nuuid\t%s' \
        5ca1ab1e-0000-4000-8000-000000000c01)" ]
    grep -q '^cryptsetup status boot_crypt$' "$STUB_LOG"
    export LUKS_TYPE=LUKS2 LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks2.dump"
    run ku_probe_boot_luks /dev/mapper/boot_crypt
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'keyslot\t0\targon2id\nkeyslot\t1\tpbkdf2\nversion\t2\nuuid\t%s' \
        5ca1ab1e-0000-4000-8000-000000000c01)" ]
}

@test "The LUKS probe returns 2 without an open LUKS mapping and 1 for an unreadable header" {
    stub_system_tools
    run ku_probe_boot_luks /dev/sdb2
    [ "$status" -eq 2 ]
    [ ! -s "$STUB_LOG" ]
    local type
    for type in "" PLAIN; do
        export LUKS_TYPE=$type
        run ku_probe_boot_luks /dev/mapper/boot_crypt
        [ "$status" -eq 2 ]
    done
    export LUKS_TYPE=LUKS1 LUKS_DUMP="$BATS_TEST_TMPDIR/none"
    run ku_probe_boot_luks /dev/mapper/boot_crypt
    [ "$status" -eq 1 ]
}

@test "The LUKS probe returns 3 without cryptsetup, but 2 still for a source that is no mapping" {
    local source expected
    # PATH holds only the stubs, and none of them is cryptsetup.
    for source in /dev/mapper/boot_crypt:3 /dev/sdb2:2; do
        expected=${source##*:} source=${source%:*}
        # shellcheck disable=SC2016 # the inner script expands its own arguments
        run env PATH="$STUB_BIN" "$BASH" -c '. "$1"; . "$2"; ku_probe_boot_luks "$3"' _ \
            "$REPO_DIR/lib/kernel-updater/common.sh" "$REPO_DIR/lib/kernel-updater/probe.sh" \
            "$source"
        [ "$status" -eq "$expected" ]
        [ -z "$output" ]
    done
}

@test "The ext probe lists the features dumpe2fs reports, and fails with dumpe2fs" {
    stub_system_tools
    export EXT_FEATURES="has_journal extent 64bit metadata_csum_seed"
    run --separate-stderr ku_probe_ext_features /dev/mapper/boot_crypt
    [ "$status" -eq 0 ]
    [ "$output" = $'has_journal\nextent\n64bit\nmetadata_csum_seed' ]
    [ -z "$stderr" ]
    export DUMPE2FS_FAIL=1
    run ku_probe_ext_features /dev/mapper/boot_crypt
    [ "$status" -eq 1 ]
}

@test "The grub-pc probe counts install devices without printing them" {
    mkstub debconf-show <<'EOF'
printf '%s' "$DEBCONF_OUT"
exit "${DEBCONF_STATUS:-0}"
EOF
    export DEBCONF_OUT="  grub-pc/install_devices_empty: false
* grub-pc/install_devices: /dev/disk/by-id/usb-Synthetic_Stick_5CA1AB1E00000001-0:0, /dev/sda
  grub-pc/timeout: 5
"
    run ku_probe_grub_pc
    [ "$status" -eq 0 ]
    [ "$output" = 2 ]
    grep -q '^debconf-show grub-pc$' "$STUB_LOG"
    export DEBCONF_OUT=$'* grub-pc/install_devices:\n'
    [ "$(ku_probe_grub_pc)" = 0 ]
    export DEBCONF_OUT=$'  grub-pc/install_devices: \n'
    [ "$(ku_probe_grub_pc)" = 0 ]
    export DEBCONF_OUT=""
    run ku_probe_grub_pc
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    export DEBCONF_STATUS=1
    run ku_probe_grub_pc
    [ "$status" -eq 1 ]
}

@test "The /boot mount probe gives the topmost mount's fields, - for a missing UUID" {
    mkstub findmnt <<'EOF'
[[ -n $FINDMNT_OUT ]] || exit 1
printf '%s\n' "$FINDMNT_OUT"
EOF
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b01"
    run ku_probe_boot_mount
    [ "$output" = $'/dev/mapper/boot_crypt\text4\t5ca1ab1e-0000-4000-8000-000000000b01' ]
    # The stub log quotes each argument as printf %q does.
    grep -q -x -F -- "findmnt$(printf ' %q' -r -n -o SOURCE,FSTYPE,UUID --mountpoint \
        "$KU_ROOT/boot")" "$STUB_LOG"
    # A tmpfs mounted over it comes last; FINDMNT_OUT stays exported.
    FINDMNT_OUT+=$'\ntmpfs tmpfs '
    run ku_probe_boot_mount
    [ "$output" = $'tmpfs\ttmpfs\t-' ]
    export FINDMNT_OUT=""
    run ku_probe_boot_mount
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "The /boot mount probe asks blkid for a UUID findmnt lacks, and only for a device" {
    mkstub findmnt <<'EOF'
printf '%s\n' "$FINDMNT_OUT"
EOF
    mkstub blkid <<'EOF'
[[ -n ${BLKID_UUID:-} ]] || exit 2
printf '%s\n' "$BLKID_UUID"
EOF
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4" BLKID_UUID=5ca1ab1e-0000-4000-8000-000000000b01
    run ku_probe_boot_mount
    [ "$output" = $'/dev/mapper/boot_crypt\text4\t5ca1ab1e-0000-4000-8000-000000000b01' ]
    grep -q -x -F -- "blkid$(printf ' %q' -p -s UUID -o value -- /dev/mapper/boot_crypt)" \
        "$STUB_LOG"
    export BLKID_UUID=""
    run ku_probe_boot_mount
    [ "$output" = $'/dev/mapper/boot_crypt\text4\t-' ]
    : > "$STUB_LOG"
    export FINDMNT_OUT="tmpfs tmpfs"
    run ku_probe_boot_mount
    [ "$output" = $'tmpfs\ttmpfs\t-' ]
    refute_line_match '^blkid' "$STUB_LOG"
}
