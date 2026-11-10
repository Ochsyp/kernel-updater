#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater apt-guard checks
#
# Feeds lib/kernel-updater/apt-guard what APT sends a DPkg::Pre-Install-Pkgs hook, in protocol
# versions 3, 2 and 1, and checks which runs pass at once, which the tool refuses before dpkg
# would run and why, with stub tools for findmnt and debconf-show.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

V=9.1.1+kali-amd64
OLD=9.0.2+kali-amd64
FS_UUID=5ca1ab1e-0000-4000-8000-000000000b01
DEBS=/var/cache/apt/archives

# A config that arms the hooks, /boot mounted with the filesystem it names, and no grub-pc
# install devices.
setup() {
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/etc"
    printf 'boot_fs_uuid = %s\n' "$FS_UUID" > "$ROOT/etc/kernel-updater.conf"
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $FS_UUID"
    mkstub findmnt <<'EOF'
[[ -n $FINDMNT_OUT ]] || exit 1
printf '%s\n' "$FINDMNT_OUT"
EOF
    export DEBCONF_OUT='* grub-pc/install_devices:'
    mkstub debconf-show <<'EOF'
printf '%s\n' "$DEBCONF_OUT"
exit "${DEBCONF_STATUS:-0}"
EOF
    mkstub id <<< 'echo 1000'
    STREAM="$BATS_TEST_TMPDIR/stream"
}

# Write the version 3 stream APT would send with the action LINES: the header, a configuration
# whose values hold spaces and an action-like line, the blank line, then the actions.
stream() {
    {
        printf 'VERSION 3\nAPT::Architecture=amd64\n'
        printf 'Unattended-Upgrade::Origins-Pattern::=origin=Kali, codename=kali-rolling\n'
        printf 'Comment=linux-image-%s - - none < 1 amd64 same **CONFIGURE**\n\n' "$V"
        printf '%s\n' "$@"
    } > "$STREAM"
}

# Print a version 3 action line: unpacking package NAME, new to the system.
unpack() {
    printf '%s - - none < %s amd64 same %s/%s_%s_amd64.deb' "$1" 9.1.1-1kali1 "$DEBS" "$1" \
        9.1.1-1kali1
}

# Print a version 3 action line: configuring package NAME.
configure() {
    printf '%s - - none < 9.1.1-1kali1 amd64 same **CONFIGURE**' "$1"
}

# Print a version 3 action line: removing package NAME.
remove() {
    printf '%s 9.0.2-1kali1 amd64 same > - - none **REMOVE**' "$1"
}

# Run apt-guard as APT does, with the stream on stdin, the stubs first on PATH and KU_ROOT in
# the test's temp directory.
run_guard() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" KU_TEST=1 KU_ROOT="$ROOT" \
        sh "${1:-$REPO_DIR/lib/kernel-updater/apt-guard}" < "$STREAM"
}

@test "A run without kernel, initramfs-tools or grub-pc actions passes without a probe" {
    stub_refuse findmnt
    stub_refuse debconf-show
    stream "$(unpack vim)" "$(unpack cryptsetup)" "$(unpack dkms)" "$(unpack grub-common)" \
        "$(unpack linux-image-amd64)" "$(unpack "linux-headers-$V")" \
        "$(unpack "linux-image-$V-dbg")" "$(configure "linux-kbuild-9.1.1+kali")" \
        "$(remove "linux-image-$OLD-dbgsym")"
    run_guard
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -s "$STUB_LOG" ]
}

@test "A kernel install while /boot is not mounted is refused, naming the packages" {
    export FINDMNT_OUT=""
    stream "$(unpack vim)" "$(unpack "linux-image-$V")" "$(unpack "linux-binary-$V")" \
        "$(unpack "linux-modules-$V")" "$(unpack "linux-base-$V")" \
        "$(configure "linux-image-$V")"
    run_guard
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: /boot is not mounted, and this apt run changes linux-image-$V,"* ]]
    [[ "$stderr" == *"linux-binary-$V, linux-modules-$V and 1 more: unlock and mount /boot,"* ]]
    [[ "$stderr" == *"error: apt-guard refused this apt run; nothing was changed"* ]]
}

@test "A run that only removes or only configures a kernel is refused too" {
    export FINDMNT_OUT=""
    stream "$(remove "linux-image-$OLD")" "$(remove "linux-modules-$OLD")"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"this apt run changes linux-image-$OLD, linux-modules-$OLD:"* ]]
    stream "$(configure "linux-image-$V")"
    run_guard
    [ "$status" -eq 3 ]
}

@test "linux-base and initramfs-tools, with its -core and -bin parts, count as kernel packages" {
    local name
    export FINDMNT_OUT=""
    for name in linux-base initramfs-tools initramfs-tools-core initramfs-tools-bin; do
        stream "$(unpack "$name")"
        run_guard
        [ "$status" -eq 3 ] || { printf '%s passed\n' "$name" >&2; return 1; }
        [[ "$stderr" == *"this apt run changes $name:"* ]]
    done
}

@test "A kernel run passes while /boot is the filesystem boot_fs_uuid names" {
    stream "$(unpack "linux-image-$V")" "$(remove "linux-image-$OLD")" \
        "$(unpack initramfs-tools)"
    run_guard
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "Another filesystem at /boot is refused without naming a UUID" {
    export FINDMNT_OUT="/dev/mapper/other_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b02"
    stream "$(unpack "linux-image-$V")"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the filesystem at /boot is not the one boot_fs_uuid names, and this"* ]]
    [[ "$stderr" == *"set boot_fs_uuid to the UUID 'findmnt -n -o UUID /boot' prints; then run apt again"* ]]
    [[ "${stderr,,}" != *5ca1ab1e* ]]
}

@test "The APT configuration runs apt-guard with protocol version 3, and lets runs through without it" {
    local conf="$REPO_DIR/hooks/apt/50kernel-updater" cmd guard="$BATS_TEST_TMPDIR/guard/apt-guard"
    cmd=$(sed -n 's/^DPkg::Pre-Install-Pkgs { "\(.*\)"; };$/\1/p' "$conf")
    [[ $cmd == "/usr/local/lib/kernel-updater/apt-guard || "* ]]
    # APT looks up the options under the command up to its first space.
    grep -q -x -F "DPkg::Tools::Options::${cmd%% *}::Version \"3\";" "$conf"
    cmd=${cmd//\/usr\/local\/lib\/kernel-updater\/apt-guard/$guard}
    stream "$(unpack "linux-image-$V")"
    # Without apt-guard, every run goes through.
    run sh -c "$cmd" < "$STREAM"
    [ "$status" -eq 0 ]
    # With it, its refusal stops the run.
    mkdir -p "${guard%/*}"
    printf '#!/bin/sh\ncat > /dev/null\nexit 3\n' > "$guard"
    chmod +x "$guard"
    run sh -c "$cmd" < "$STREAM"
    [ "$status" -ne 0 ]
    printf '#!/bin/sh\ncat > /dev/null\n' > "$guard"
    run sh -c "$cmd" < "$STREAM"
    [ "$status" -eq 0 ]
}

@test "grub-pc is refused while grub-pc/install_devices names a device, unless it is removed" {
    export DEBCONF_OUT="* grub-pc/install_devices: /dev/sda, /dev/disk/by-id/usb-Synthetic"
    stream "$(unpack grub-common)" "$(unpack grub-pc)"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"grub-pc/install_devices names 2 device(s), and this apt run upgrades"* ]]
    [[ "$stderr" == *"run 'dpkg-reconfigure grub-pc', select no device, then run apt again"* ]]
    [[ "$stderr" != */dev/sda* && "$stderr" != *Synthetic* ]]
    stream "$(configure grub-pc)"
    run_guard
    [ "$status" -eq 3 ]
    stream "$(remove grub-pc)"
    run_guard
    [ "$status" -eq 0 ]
    export DEBCONF_OUT='* grub-pc/install_devices:'
    stream "$(unpack grub-pc)"
    run_guard
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "grub-pc is refused when debconf-show cannot read its answers" {
    export DEBCONF_STATUS=1
    stream "$(unpack grub-pc)"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"debconf-show cannot read grub-pc's answers"* ]]
}

@test "Both problems are reported in one refusal" {
    export FINDMNT_OUT="" DEBCONF_OUT="* grub-pc/install_devices: /dev/sda"
    stream "$(unpack "linux-image-$V")" "$(unpack grub-pc)"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"/boot is not mounted, and this apt run changes linux-image-$V:"* ]]
    [[ "$stderr" == *"grub-pc/install_devices names 1 device(s)"* ]]
}

@test "Without boot_fs_uuid, apt-guard only warns" {
    rm "$ROOT/etc/kernel-updater.conf"
    export FINDMNT_OUT=""
    stream "$(unpack "linux-image-$V")"
    run_guard
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: /boot is not mounted, and this apt run changes linux-image-$V:"* ]]
    [[ "$stderr" == *"warning: boot_fs_uuid is not set in /etc/kernel-updater.conf"* ]]
    [[ "$stderr" != *error:* ]]
}

@test "Protocol versions 2 and 1 are read as well" {
    export FINDMNT_OUT=""
    printf 'VERSION 2\nAPT::Architecture=amd64\n\nlinux-image-%s - < 9.1.1-1kali1 %s\n' "$V" \
        "**CONFIGURE**" > "$STREAM"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"changes linux-image-$V:"* ]]
    printf '%s/linux-image-%s_9.1.1-1kali1_amd64.deb\n%s/vim_2%%3a9.1_amd64.deb\n' "$DEBS" "$V" \
        "$DEBS" > "$STREAM"
    run_guard
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"changes linux-image-$V:"* ]]
}

@test "apt-guard lets a run through with a warning when the tool is missing" {
    mkdir -p "$BATS_TEST_TMPDIR/prefix/lib/kernel-updater"
    cp "$REPO_DIR/lib/kernel-updater/apt-guard" "$BATS_TEST_TMPDIR/prefix/lib/kernel-updater/"
    export FINDMNT_OUT=""
    stream "$(unpack "linux-image-$V")"
    run_guard "$BATS_TEST_TMPDIR/prefix/lib/kernel-updater/apt-guard"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: "*"/bin/kernel-updater is missing, so apt-guard let this apt run"* ]]
}
