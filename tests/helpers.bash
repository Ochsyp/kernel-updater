# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater test helpers
#
# Sourced by the .bats files under tests/ through `load`: repository paths, PATH and system
# stubs, runners for bin/kernel-updater and for library code, a library loader, disk images,
# check result readers and ShellCheck runners.
# -------------------------------------------------------

bats_require_minimum_version 1.5.0

# The directory of the running .bats file, and the repository root, found from this file so
# that tests in subdirectories share it.
# shellcheck disable=SC2034 # read by the .bats files
TESTS_DIR="$BATS_TEST_DIRNAME"
REPO_DIR=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
# How the tool's advice names it when run_ku starts it: sudo and the real path of
# bin/kernel-updater, as sudo's secure_path may lack the directory it is in.
SUDO_KU="sudo $(printf '%q' "$(readlink -f "$REPO_DIR/bin/kernel-updater")")"

# Create the per-test stub directory and the log every stub appends its call to.
# Call from setup() before writing any stub.
stub_init() {
    export STUB_BIN="$BATS_TEST_TMPDIR/bin"
    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$STUB_BIN"
    : > "$STUB_LOG"
}

# Shared opening of every stub: appends "NAME ARGS" to $STUB_LOG in one write, each
# argument printf %q-quoted.
IFS= read -r -d '' _STUB_PROLOGUE <<'EOF' || true
if (( $# )); then printf -v _stub_args ' %q' "$@"; else _stub_args=''; fi
printf '%s%s\n' "$STUB_NAME" "$_stub_args" >> "${STUB_LOG:?}"
EOF

# Write the executable stub $STUB_BIN/NAME: shebang, name, the shared prologue, then the
# body read from stdin. An empty body makes a stub that only logs and exits 0.
mkstub() {
    local name="$1" body
    IFS= read -r -d '' body || true
    printf '#!/bin/bash\nSTUB_NAME=%q\n%s%s' "$name" "$_STUB_PROLOGUE" "$body" > "$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
}

# Write a stub NAME that must never run: it logs the call and exits 100, so a test that
# reaches it fails on the exit status and on the log.
stub_refuse() {
    mkstub "$1" <<'EOF'
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
}

# Run bin/kernel-updater with the stubs first on PATH and the KU_ROOT, KU_TTY and KU_LOCKFILE
# seams inside the test's temp directory, which KU_TEST=1 lets it take from the environment,
# through bats' run with separate stderr.
run_ku() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" KU_TEST=1 \
        KU_ROOT="$BATS_TEST_TMPDIR/root" KU_TTY="$BATS_TEST_TMPDIR/tty" \
        KU_LOCKFILE="$BATS_TEST_TMPDIR/lock" bash "$REPO_DIR/bin/kernel-updater" "$@"
}

# Source the libraries into the test shell as bin/kernel-updater does, without its strict
# mode and traps, so tests can call the functions directly. KU_TEST=1 keeps the seams a test
# set before loading them.
load_ku_libs() {
    KU_TEST=1
    # shellcheck disable=SC2034 # read by the sourced libraries
    KU_LIBDIR="$REPO_DIR/lib/kernel-updater" KU_SHAREDIR="$REPO_DIR/share/kernel-updater"
    # shellcheck source=lib/kernel-updater/common.sh
    . "$KU_LIBDIR/common.sh"
    # shellcheck source=lib/kernel-updater/config.sh
    . "$KU_LIBDIR/config.sh"
    # shellcheck source=lib/kernel-updater/lint.sh
    . "$KU_LIBDIR/lint.sh"
    # shellcheck source=lib/kernel-updater/probe.sh
    . "$KU_LIBDIR/probe.sh"
    # shellcheck source=lib/kernel-updater/check.sh
    . "$KU_LIBDIR/check.sh"
    # shellcheck source=lib/kernel-updater/hook.sh
    . "$KU_LIBDIR/hook.sh"
    # shellcheck source=lib/kernel-updater/disk.sh
    . "$KU_LIBDIR/disk.sh"
    # shellcheck source=lib/kernel-updater/deploy.sh
    . "$KU_LIBDIR/deploy.sh"
    # shellcheck source=lib/kernel-updater/baseline.sh
    . "$KU_LIBDIR/baseline.sh"
    # shellcheck source=lib/kernel-updater/migrate.sh
    . "$KU_LIBDIR/migrate.sh"
    # shellcheck source=lib/kernel-updater/cleanup.sh
    . "$KU_LIBDIR/cleanup.sh"
}

# Run the shell CODE as a command of bin/kernel-updater runs: in a bash with its strict mode,
# traps and libraries, the configuration loaded, the stubs first on PATH and the seams of
# run_ku, through bats' run with separate stderr. ARGS follow CODE as its "$@".
run_ku_lib() {
    # shellcheck disable=SC2016 # the inner script expands its own variables
    run --separate-stderr env PATH="$STUB_BIN:$PATH" KU_TEST=1 \
        KU_ROOT="$BATS_TEST_TMPDIR/root" KU_TTY="$BATS_TEST_TMPDIR/tty" \
        KU_LOCKFILE="$BATS_TEST_TMPDIR/lock" bash -c '
            set -Eeuo pipefail
            shopt -s inherit_errexit
            KU_LIBDIR=$0/lib/kernel-updater KU_SHAREDIR=$0/share/kernel-updater
            for lib in common config lint probe check hook disk deploy baseline migrate cleanup; do
                . "$KU_LIBDIR/$lib.sh"
            done
            ku_install_traps
            ku_load_config
            code=$1
            shift
            eval "$code"' "$REPO_DIR" "$@"
}

# Make ln -s create symlinks. Git Bash copies files instead unless MSYS asks for Cygwin-style
# links, which may dangle, or native ones. Returns 1 when neither works, so the test can skip.
use_symlinks() {
    local probe="$BATS_TEST_TMPDIR/symlink-probe" mode
    : > "$probe.target"
    for mode in winsymlinks:sys winsymlinks:nativestrict; do
        export MSYS=$mode
        if ln -s symlink-probe.target "$probe" 2> /dev/null && [[ -L $probe ]]; then
            rm -f "$probe" "$probe.target"
            return 0
        fi
        rm -f "$probe"
    done
    return 1
}

# Write a uname stub that prints UNAME_R, the running kernel's release, for any arguments:
# 9.0.2+kali-amd64 when UNAME_R is unset, and nothing when it is empty.
stub_uname() {
    mkstub uname <<'EOF'
printf '%s\n' "${UNAME_R-9.0.2+kali-amd64}"
EOF
}

# Write an lsinitramfs stub that lists what a healthy initrd of the version in its file name
# holds, key file included: LSINITRAMFS_DROP, an ERE, drops lines, and LSINITRAMFS_FAIL names
# a version whose initrd it cannot read.
stub_lsinitramfs() {
    mkstub lsinitramfs <<'EOF'
version=${1##*/initrd.img-}
[[ $version != "${LSINITRAMFS_FAIL:-}" ]] || exit 1
listing=$(printf '%s\n' . usr usr/lib usr/lib/modules "usr/lib/modules/$version" \
    "usr/lib/modules/$version/modules.dep" usr/sbin usr/sbin/cryptsetup cryptroot \
    cryptroot/crypttab cryptroot/keyfiles cryptroot/keyfiles/root_crypt.key)
if [[ -n ${LSINITRAMFS_DROP:-} ]]; then
    grep -v -E -e "$LSINITRAMFS_DROP" <<< "$listing"
else
    printf '%s\n' "$listing"
fi
EOF
}

# Write stubs for the tools check reads that a test machine cannot answer for: uname,
# lsinitramfs, cryptsetup and dumpe2fs. They report a healthy system unless the variables
# named in each stub say otherwise.
stub_system_tools() {
    export LUKS_DEVICE=/dev/disk/by-id/usb-Synthetic_Stick_5CA1AB1E00000001-0:0-part3
    export LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks1.dump"
    export BOOT_FS_UUID=5ca1ab1e-0000-4000-8000-000000000b01
    export EXT_FEATURES="has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg"
    EXT_FEATURES+=" sparse_super large_file huge_file dir_nlink extra_isize metadata_csum"
    stub_uname
    stub_lsinitramfs
    # LUKS_TYPE is what status reports (empty: no crypt device); luksDump prints LUKS_DUMP for
    # the device status names, and fails for any other.
    mkstub cryptsetup <<'EOF'
case $1 in
    status)
        [[ -n ${LUKS_TYPE-LUKS1} ]] || exit 4
        printf '/dev/mapper/%s is active and is in use.\n' "$2"
        printf '  type:    %s\n  cipher:  aes-xts-plain64\n' "${LUKS_TYPE-LUKS1}"
        printf '  keysize: 512 bits\n  key location: dm-crypt\n  device:  %s\n' "$LUKS_DEVICE"
        printf '  sector size:  512\n  mode:    read/write\n'
        ;;
    luksDump)
        [[ $2 == "$LUKS_DEVICE" ]] || exit 1
        cat "$LUKS_DUMP"
        ;;
    *) exit 1 ;;
esac
EOF
    # EXT_FEATURES is the features line; DUMPE2FS_FAIL=1 makes it fail as on a foreign
    # filesystem.
    mkstub dumpe2fs <<'EOF'
printf 'dumpe2fs 1.47.2 (1-Jan-2025)\n' >&2
[[ -z ${DUMPE2FS_FAIL:-} ]] || exit 1
printf 'Filesystem volume name:   <none>\nLast mounted on:          /boot\n'
printf 'Filesystem UUID:          %s\nFilesystem magic number:  0xEF53\n' "$BOOT_FS_UUID"
printf 'Filesystem features:      %s\n' "$EXT_FEATURES"
printf 'Filesystem flags:         signed_directory_hash\n'
EOF
}

# Write the disk image FILE, which KU_P1_DISK stands for: 440 bytes of MBR boot code, the
# synthetic disk signature, a partition table whose first entry, NTFS, starts at sector 2, a
# gap, and in sector 2 partition 1's boot sector.
make_disk_image() {
    {
        head -c 440 /dev/zero | tr '\0' M
        printf '\x1e\xab\xa1\x5c\0\0'
        printf '\0\0\0\0\x07\0\0\0\x02\0\0\0\x08\0\0\0'
        head -c 48 /dev/zero
        printf '\x55\xaa'
        head -c 512 /dev/zero | tr '\0' G
        printf 'NTFS    '
        head -c 504 /dev/zero | tr '\0' S
    } > "$1"
}

# Write the disk image FILE as make_disk_image does, with partition 1 FAT (type 0x0c) and a
# SYSLINUX boot sector of FAT BITS, 32 or 16, in sector 2: its "not cleanly unmounted" byte, at
# 65 for FAT32 and at 37 for FAT16, is clear.
make_fat_disk_image() {
    local fatsz='\0\0' before=41 after=443
    if [[ $2 == 16 ]]; then
        fatsz='\x20\0' before=13 after=471
    fi
    {
        head -c 440 /dev/zero | tr '\0' M
        printf '\x1e\xab\xa1\x5c\0\0'
        printf '\0\0\0\0\x0c\0\0\0\x02\0\0\0\x08\0\0\0'
        head -c 48 /dev/zero
        printf '\x55\xaa'
        head -c 512 /dev/zero | tr '\0' G
        # Jump, OEM name, bytes per sector up to the media byte, then the 16-bit FAT size,
        # which FAT32 leaves 0.
        printf '\xeb\x58\x90SYSLINUX\0\x02\x01\x20\0\x02\0\0\0\0\xf8'
        # shellcheck disable=SC2059 # the format is one of the two escapes above
        printf "$fatsz"
        head -c "$before" /dev/zero | tr '\0' B
        # The flags byte, then the extended boot signature.
        printf '\0\x29'
        head -c "$after" /dev/zero | tr '\0' C
        printf '\x55\xaa'
    } > "$1"
}

# Write the menu of a finished migration under the partition-1 root DIR: a grub.cfg that sources
# kali.cfg and holds no legacy entries, and that kali.cfg.
write_finished_menu() {
    local marker="# Kali GNU/Linux: kernel-updater keeps the entries in kali.cfg."
    marker+=" Not a MultiBootUSB block."
    mkdir -p "$1/multibootusb/grub"
    printf '%s\n' "$marker" \
        'if [ -f /multibootusb/grub/kali.cfg ]; then' \
        '	source /multibootusb/grub/kali.cfg' \
        'fi' > "$1/multibootusb/grub/grub.cfg"
    cp "$REPO_DIR/tests/fixtures/grub/kali.expected.cfg" "$1/multibootusb/grub/kali.cfg"
}

# Overwrite the byte at OFFSET of FILE with an X.
poke_byte() {
    printf 'X' | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}

# Print STATUS<TAB>DETAIL of ITEM from the porcelain output of the last check run.
check_item() {
    # shellcheck disable=SC2154 # bats' run sets output
    awk -F '\t' -v item="$1" '$1 == item { print $2 "\t" $3 }' <<< "$output"
}

# Fail unless ITEM has STATUS and a detail that contains TEXT in the last check run.
expect_item() {
    local got
    got=$(check_item "$1")
    if [[ "$got" != "$2"$'\t'*"$3"* ]]; then
        printf '%s: expected %s with "%s", got "%s"\n' "$1" "$2" "$3" "$got" >&2
        return 1
    fi
}

# Fail the test when the ERE $1 matches a line of file $2. A bare `! grep` would not fail
# a bats test, because errexit ignores negated commands.
refute_line_match() {
    if grep -q -E -e "$1" "$2"; then
        printf 'unexpected match for %s in %s:\n' "$1" "$2" >&2
        grep -E -e "$1" "$2" >&2
        return 1
    fi
}

# Run shellcheck through bats' run, with separate stderr.
run_shellcheck() {
    run --separate-stderr _exec_shellcheck "$@"
}

# Execute shellcheck in the repository root with MSYS path conversion disabled.
_exec_shellcheck() {
    (cd "$REPO_DIR" && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' shellcheck "$@")
}

# Print "CODE COUNT" per ShellCheck code, sorted, for gcc-format findings on
# stdin. Strips the CR a Windows build may end its lines with.
shellcheck_code_counts() {
    local line code
    local -A count=()
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ \[(SC[0-9]+)\]$ ]]; then
            code="${BASH_REMATCH[1]}"
            count[$code]=$(( ${count[$code]:-0} + 1 ))
        fi
    done
    for code in "${!count[@]}"; do
        printf '%s %d\n' "$code" "${count[$code]}"
    done | sort
}
