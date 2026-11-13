#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater cleanup command checks
#
# Runs kernel-updater cleanup on a KU_ROOT tree of a migrated system with stub tools: its usage
# and usage errors, root and the tool's lock, the keys detect fills, the identity of /boot, the
# links in /boot, the kernel packages' states, an interrupted dpkg run, apt's and dpkg's locks
# as /proc/locks shows them, a clean system with nothing to do, the plan lines in both forms,
# and the environment the tools it runs get. No identifier is printed.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

V1=9.0.1+kali-amd64
V2=9.0.2+kali-amd64
CONF=/etc/kernel-updater.conf
# The variables that would point dpkg at another database, force it or change apt's
# configuration, which no tool cleanup runs may inherit.
OVERRIDES=(DPKG_ROOT DPKG_ADMINDIR DPKG_FORCE APT_CONFIG DPKG_FRONTEND_LOCKED)

# A migrated Kali system: kernels V1 and V2, V2 running, linux-base keeping the links in /boot
# on V2 and V1, a configuration that names /boot and its LUKS container, dpkg's and apt's state
# and lock files, an empty updates directory, and no lock in /proc/locks.
setup() {
    stub_init
    use_symlinks || skip "this platform cannot make symlinks"
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/boot" "$ROOT/etc" "$ROOT/proc" "$ROOT/var/lib/dpkg/updates" \
        "$ROOT/var/lib/apt" "$ROOT/usr/lib/modules"
    : > "$ROOT/var/lib/dpkg/status"
    : > "$ROOT/var/lib/dpkg/lock"
    : > "$ROOT/var/lib/dpkg/lock-frontend"
    : > "$ROOT/var/lib/apt/extended_states"
    : > "$ROOT/proc/locks"
    configure 5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c01
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    kernels "$V1" "$V2"
    ln -s "vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    ln -s "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
    stub_system_tools
    stubs
}

# Write the stubs that answer for the system: root, the tool's lock, stat, /boot's mount, dpkg
# and linux-version, and apt-get, apt-mark and dkms, which answer a simulation (-s) with
# nothing to do and refuse anything else. dpkg-query and those three leave the environment
# they got in env.NAME beside the stub log.
stubs() {
    local name
    mkstub id <<'EOF'
printf '%s\n' "${ID_U:-0}"
EOF
    mkstub flock
    # Root owns the config file, with mode 0600; the real stat answers the rest, such as the
    # inodes of dpkg's lock files.
    export REAL_STAT
    REAL_STAT=$(type -P stat)
    mkstub stat <<'EOF'
if [[ " $* " == *" %u %a "* ]]; then
    printf '0 600\n'
else
    exec "$REAL_STAT" "$@"
fi
EOF
    # FINDMNT_OUT is /boot's mount line; empty means /boot is not mounted.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    mkstub findmnt <<'EOF'
[[ " $* " == *" --mountpoint "* && -n $FINDMNT_OUT ]] || exit 1
printf '%s\n' "$FINDMNT_OUT"
EOF
    mkstub dpkg-query <<'EOF'
env > "${STUB_LOG%/*}/env.dpkg-query"
cat "$DPKG_QUERY_OUT"
exit "${DPKG_QUERY_STATUS:-0}"
EOF
    mkstub linux-version <<'EOF'
[[ $1 == sort ]] && exec sort -V
EOF
    for name in apt-get apt-mark dkms; do
        mkstub "$name" <<'EOF'
env > "${STUB_LOG%/*}/env.$STUB_NAME"
[[ " $* " != *" -s "* ]] || exit 0
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
    done
}

# Write the configuration detect leaves: boot_fs_uuid FS and boot_luks_uuid LUKS, each left out
# when empty.
configure() {
    : > "$ROOT$CONF"
    if [[ -n $1 ]]; then
        printf 'boot_fs_uuid = %s\n' "$1" >> "$ROOT$CONF"
    fi
    if [[ -n $2 ]]; then
        printf 'boot_luks_uuid = %s\n' "$2" >> "$ROOT$CONF"
    fi
}

# Install the kernels VERSION..., in dpkg's list and with their files in /boot.
kernels() {
    local v
    export DPKG_QUERY_OUT="$BATS_TEST_TMPDIR/dpkg-query.out"
    : > "$DPKG_QUERY_OUT"
    for v in "$@"; do
        printf 'kernel %s\n' "$v" > "$ROOT/boot/vmlinuz-$v"
        printf 'initrd %s\n' "$v" > "$ROOT/boot/initrd.img-$v"
        printf '%s\t%s\t%s\n' "linux-image-$v" 'ii ' 9-1kali1 >> "$DPKG_QUERY_OUT"
    done
}

# Print the /proc/locks line of a POSIX lock that process PID holds on FILE under ROOT, which
# names FILE by its inode, here on device 08:01, as the kernel does. With COMMAND, PID gets
# that name in its /proc/PID/comm.
lock_line() {
    local inode
    inode=$(stat -c %i "$ROOT$2")
    if [[ -n ${3:-} ]]; then
        mkdir -p "$ROOT/proc/$1"
        printf '%s\n' "$3" > "$ROOT/proc/$1/comm"
    fi
    printf '1: POSIX  ADVISORY  WRITE %s 08:01:%s 0 EOF\n' "$1" "$inode"
}

# Fail unless the last run printed no identifier and no device.
private_output() {
    local all="${output,,}${stderr,,}"
    [[ "$all" != *5ca1ab1e* && "$all" != */dev/* ]] ||
        { printf 'an identifier was printed\n' >&2; return 1; }
}

@test "cleanup --help prints its usage, and an unknown option or an argument exits 64" {
    local args
    run_ku cleanup --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: kernel-updater cleanup [--no-rc] [--no-autoremove] [--no-modules]"* ]]
    [ -z "$stderr" ]
    for args in "--bogus" "-x" "--no-rc=yes" "extra" "-n extra"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku cleanup $args
        [ "$status" -eq 64 ] || { printf '"%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [ -z "$output" ]
        [[ "$stderr" == *"Try 'kernel-updater --help'."* ]]
    done
}

@test "cleanup exits 77 when not root and 75 while another run holds the lock, in a dry run too" {
    local args
    export ID_U=1000
    for args in "" "-n"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku cleanup $args
        [ "$status" -eq 77 ] || { printf '"%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [[ "$stderr" == *"this command must run as root"* ]]
    done
    export ID_U=0
    mkstub flock <<< 'exit 1'
    run_ku cleanup -n
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"another kernel-updater run holds the lock"* ]]
    [ -z "$output" ]
}

@test "cleanup refuses with 3 until detect set boot_fs_uuid and boot_luks_uuid" {
    configure "" 5ca1ab1e-0000-4000-8000-000000000c01
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the configuration lacks boot_fs_uuid: run"* ]]
    [[ "$stderr" == *"'kernel-updater migrate --stage detect' first; nothing was changed"* ]]
    configure 5ca1ab1e-0000-4000-8000-000000000b01 ""
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the configuration lacks boot_luks_uuid: run"* ]]
    configure "" ""
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the configuration lacks boot_fs_uuid and boot_luks_uuid: run"* ]]
    [ -z "$output" ]
    private_output
}

@test "cleanup exits 66 while /boot is not mounted or unreadable, and 78 on another /boot" {
    export FINDMNT_OUT=""
    run_ku cleanup -n
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"/boot is not mounted: unlock and mount it first; nothing was changed"* ]]
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    export LUKS_DUMP="$BATS_TEST_TMPDIR/no-such.dump"
    run_ku cleanup -n
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"the LUKS header of the container that holds /boot cannot be read"* ]]
    export LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks1.dump"
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b02"
    run_ku cleanup -n
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"the filesystem at /boot is not the one boot_fs_uuid names"* ]]
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    configure 5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c09
    run_ku cleanup -n
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"/boot is not in the LUKS container boot_luks_uuid names"* ]]
    [ -z "$output" ]
    private_output
}

@test "cleanup refuses with 3 while the links are not kept in /boot or do not reach a kernel" {
    printf 'do_symlinks = no\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernel-img: do_symlinks is off"* ]]
    [[ "$stderr" == *"run 'kernel-updater migrate --stage system' first; nothing was changed"* ]]
    printf 'do_symlinks = yes\nlink_in_boot = no\n' > "$ROOT/etc/kernel-img.conf"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernel-img: link_in_boot is off"* ]]
    [[ "$stderr" == *"run 'kernel-updater migrate --stage system' first"* ]]
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    rm "$ROOT/boot/initrd.img-$V1"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: boot-links: initrd.img.old does not reach a non-empty file"* ]]
    [[ "$stderr" == *"run 'kernel-updater migrate --stage system' first"* ]]
    printf 'initrd %s\n' "$V1" > "$ROOT/boot/initrd.img-$V1"
    ln -sfn "/boot/vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: boot-links: vmlinuz is absolute"* ]]
    [ -z "$output" ]
    private_output
}

@test "cleanup refuses with 3 and the kernels item's detail while dpkg cannot vouch for them" {
    printf '%s\t%s\t%s\n' "linux-modules-$V2" 'iU ' 9-1kali1 >> "$DPKG_QUERY_OUT"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernels: $V2 is unpacked (iU): run dpkg --configure -a;"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    kernels "$V1" "$V2"
    printf '%s\t%s\t%s\n' "linux-binary-$V1" 'iF ' 9-1kali1 >> "$DPKG_QUERY_OUT"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernels: $V1 is half-configured (iF): run dpkg --configure -a;"* ]]
    kernels "$V1" "$V2"
    export UNAME_R=9.0.3+kali-amd64
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernels: the running kernel 9.0.3+kali-amd64 is not installed"* ]]
    export UNAME_R=$V2 DPKG_QUERY_STATUS=2
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernels: dpkg-query cannot read the package database"* ]]
    # A query that lists no kernel at all refuses too: the running one is not installed then.
    export DPKG_QUERY_STATUS=0
    : > "$DPKG_QUERY_OUT"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernels: the running kernel $V2 is not installed"* ]]
    [ -z "$output" ]
    private_output
}

@test "cleanup refuses with 3 after an interrupted dpkg run left a file in its updates directory" {
    # dpkg's own temporary file does not count, as apt does not count it either.
    : > "$ROOT/var/lib/dpkg/updates/tmp.i"
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    : > "$ROOT/var/lib/dpkg/updates/0003"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"dpkg was interrupted: run 'dpkg --configure -a', then 'kernel-updater"* ]]
    [[ "$stderr" == *"check'; nothing was changed"* ]]
    [ -z "$output" ]
}

@test "cleanup exits 75 while apt or dpkg holds a lock, naming its PID and command" {
    local line
    lock_line 4242 /var/lib/dpkg/lock-frontend apt-get > "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"apt or dpkg is running: PID 4242 (apt-get) holds"* ]]
    [[ "$stderr" == *" /var/lib/dpkg/lock-frontend; run cleanup again once it is done;"* ]]
    [[ "$stderr" == *"nothing was changed"* ]]
    # dpkg's database lock, past a lock on another file, is named by its holder, not by the
    # process that waits for it.
    line=$(lock_line 4444 /var/lib/dpkg/lock apt-get)
    {
        lock_line 99 /var/lib/dpkg/status
        lock_line 4343 /var/lib/dpkg/lock dpkg
        printf '%s\n' "${line/1: /1: -> }"
    } > "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"PID 4343 (dpkg) holds /var/lib/dpkg/lock;"* ]]
    # An open file description lock shows no PID, a holder may be gone by now, and a name
    # that could disturb the terminal is shown tamed.
    lock_line -1 /var/lib/dpkg/lock > "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"a process whose PID /proc/locks does not show holds /var/lib/dpkg/lock;"* ]]
    lock_line 4545 /var/lib/dpkg/lock-frontend > "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"PID 4545 holds /var/lib/dpkg/lock-frontend;"* ]]
    lock_line 4646 /var/lib/dpkg/lock $'apt\e[2J' > "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"PID 4646 (apt??2J) holds"* ]]
    # A lock on another file is no reason to wait.
    lock_line 99 /var/lib/dpkg/status > "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    # Without /proc/locks cleanup cannot tell, and refuses.
    rm "$ROOT/proc/locks"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"cannot read /proc/locks"* ]]
    [ -z "$output" ]
    private_output
}

@test "On a clean system cleanup has nothing to do, in a dry run too, and changes nothing" {
    local args
    find "$ROOT" | sort > "$BATS_TEST_TMPDIR/tree.before"
    for args in "" "-n" "--dry-run --yes" "--porcelain" "--no-rc --no-autoremove --no-modules"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku cleanup $args
        [ "$status" -eq 0 ] || { printf '"%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [ -z "$output" ]
        [[ "$stderr" == *"cleanup: nothing to do"* ]]
    done
    # -n, -y and --porcelain work as global options too.
    run_ku -n -y --porcelain cleanup
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    find "$ROOT" | sort | cmp - "$BATS_TEST_TMPDIR/tree.before"
    grep -q '^flock -n ' "$STUB_LOG"
    refute_line_match '^(apt-get|apt-mark|dkms)( |$)' "$STUB_LOG"
    private_output
}

@test "The tools cleanup runs inherit none of dpkg's or apt's overrides and run in C.UTF-8" {
    local name
    export DPKG_ROOT=/elsewhere DPKG_ADMINDIR=/elsewhere/dpkg DPKG_FORCE=all \
        APT_CONFIG=/elsewhere/apt.conf DPKG_FRONTEND_LOCKED=1 SOURCE_DATE_EPOCH=1700000000
    # The probes cleanup shares with check run dpkg-query by name, so the whole command drops
    # the overrides; SOURCE_DATE_EPOCH passes with KU_TEST=1, for the container tests.
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/env.dpkg-query" ]
    for name in "${OVERRIDES[@]}"; do
        refute_line_match "^$name=" "$BATS_TEST_TMPDIR/env.dpkg-query"
    done
    grep -qx 'SOURCE_DATE_EPOCH=1700000000' "$BATS_TEST_TMPDIR/env.dpkg-query"
    grep -qx 'LC_ALL=C.UTF-8' "$BATS_TEST_TMPDIR/env.dpkg-query"
    run_ku_lib '_ku_cl_child apt-get -s -q purge linux-image-9.0.1+kali-amd64'
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/env.apt-get" ]
    for name in "${OVERRIDES[@]}"; do
        refute_line_match "^$name=" "$BATS_TEST_TMPDIR/env.apt-get"
    done
    grep -qx 'LC_ALL=C.UTF-8' "$BATS_TEST_TMPDIR/env.apt-get"
    # Without KU_TEST=1, as when root runs it, SOURCE_DATE_EPOCH goes too.
    rm "$BATS_TEST_TMPDIR/env.apt-get" "$BATS_TEST_TMPDIR/env.dpkg-query"
    # shellcheck disable=SC2016 # the inner script expands its own arguments
    run --separate-stderr env -u KU_TEST PATH="$STUB_BIN:$PATH" bash -c '
        . "$1/lib/kernel-updater/common.sh"
        . "$1/lib/kernel-updater/cleanup.sh"
        _ku_cl_environment
        dpkg-query -W > /dev/null
        _ku_cl_child apt-get -s -q purge linux-image-9.0.1+kali-amd64' _ "$REPO_DIR"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/env.apt-get" ] && [ -f "$BATS_TEST_TMPDIR/env.dpkg-query" ]
    for name in "${OVERRIDES[@]}" SOURCE_DATE_EPOCH; do
        refute_line_match "^$name=" "$BATS_TEST_TMPDIR/env.apt-get"
        refute_line_match "^$name=" "$BATS_TEST_TMPDIR/env.dpkg-query"
    done
    grep -qx 'LC_ALL=C.UTF-8' "$BATS_TEST_TMPDIR/env.dpkg-query"
}

@test "A plan line goes to stderr at any verbosity, and with --porcelain its records to stdout" {
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib 'KU_VERBOSITY=0
        _ku_cl_plan_line "keep A (running, vmlinuz) and B (vmlinuz.old)" \
            protect keep A "running, vmlinuz" protect keep B vmlinuz.old'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "kernel-updater: plan: keep A (running, vmlinuz) and B (vmlinuz.old)" ]
    # A tab or a line break in a field would shift the fields, and an empty one shows as -.
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib 'KU_PORCELAIN=1
        _ku_cl_plan_line "keep A (running, vmlinuz) and B (vmlinuz.old)" \
            protect keep A "running, vmlinuz" protect keep B vmlinuz.old
        _ku_cl_plan_line "then sync"
        _ku_cl_plan_line "" rc list "$(printf "odd\tname")" "$(printf "two\nlines")" rc skip x ""'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep A 'running, vmlinuz' protect keep B \
        vmlinuz.old rc list 'odd name' 'two lines' rc skip x -)" ]
    [ "$stderr" = "$(printf 'kernel-updater: plan: %s\n' \
        'keep A (running, vmlinuz) and B (vmlinuz.old)' 'then sync')" ]
}
