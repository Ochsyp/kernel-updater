#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater cleanup command checks
#
# Runs kernel-updater cleanup on a KU_ROOT tree of a migrated system with stub tools: its usage
# and usage errors, root and the tool's lock, the keys detect fills, the identity of /boot, the
# links in /boot, the kernel packages' states, an interrupted dpkg run, apt's and dpkg's locks
# as /proc/locks shows them, a clean system with nothing to do, the plan lines in both forms,
# and the environment the tools it runs get; then the purge of the config files removed kernels
# left: what it plans, keeps and lists, a pending reboot, the dry run and the question, the one
# purge and the sync, the simulation that must match the plan, changes while the question
# waits, a purge that fails or is interrupted, and the check after it; and the purge of the old
# kernels apt's autoremove names: which of its packages join the purge and which it keeps or
# only lists, kernels marked manual, one purge for both steps, a purge apt would widen, the
# options that leave a step out, and a simulation that fails or changes while the question
# waits. No identifier is printed.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

V0=9.0.0+kali-amd64
V1=9.0.1+kali-amd64
V2=9.0.2+kali-amd64
# A kernel older still.
OLD=8.9.9+kali-amd64
CONF=/etc/kernel-updater.conf
# The options every apt-get purge cleanup simulates or runs takes, after -s or -y.
PURGE_OPTS="-q -o DPkg::Lock::Timeout=0 -o APT::Get::AutomaticRemove=false"
PURGE_OPTS+=" -o APT::Get::AutomaticRemove::Kernels=false purge"
# The options of apt-get's simulation of its autoremove, after -s.
AUTOREMOVE_OPTS="-q -o DPkg::Lock::Timeout=0 -o APT::Get::AutomaticRemove::Kernels=false"
AUTOREMOVE_OPTS+=" autoremove --purge"
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

# Write the stubs that answer for the system: root, the tool's lock, stat, /boot's mount, dpkg,
# linux-version and sync; apt-get as the apt-get stub below says; apt-mark, whose showmanual
# prints the lines of the file APT_MANUAL names, or nothing, and exits APT_MARK_STATUS; and
# dkms, which answers a simulation (-s) with nothing to do. apt-mark and dkms refuse anything
# else. dpkg-query, apt-get, apt-mark and dkms leave the environment they got in env.NAME beside
# the stub log.
stubs() {
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
    mkstub sync
    mkstub apt-mark <<'EOF'
env > "${STUB_LOG%/*}/env.$STUB_NAME"
if [[ $* == showmanual ]]; then
    [[ -z ${APT_MANUAL:-} ]] || cat "$APT_MANUAL"
    exit "${APT_MARK_STATUS:-0}"
fi
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
    mkstub dkms <<'EOF'
env > "${STUB_LOG%/*}/env.$STUB_NAME"
[[ " $* " != *" -s "* ]] || exit 0
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
    stub_apt_get
}

# Write the apt-get stub. A simulation (-s) of the autoremove prints the lines of the file
# APT_AUTOREMOVE names, or nothing, and exits APT_AUTOREMOVE_STATUS. A simulation of a purge
# prints what apt prints for the removal of each package after "purge", except APT_SIM_SKIP,
# then the lines of APT_SIM_EXTRA, and exits APT_SIM_STATUS. The second simulation of the kind
# APT_SIM_DO_KIND names, purge by default or autoremove, first runs the file APT_SIM_DO names,
# as an apt run while the question waits would change the system. Any other call, such as the
# real purge, runs the file APT_DO names and exits APT_STATUS, or refuses with 100 while APT_DO
# is unset.
stub_apt_get() {
    mkstub apt-get <<'EOF'
env > "${STUB_LOG%/*}/env.$STUB_NAME"
if [[ " $* " == *" -s "* ]]; then
    kind=purge
    [[ " $* " != *" autoremove "* ]] || kind=autoremove
    count=${STUB_LOG%/*}/apt-get.count.$kind
    n=$(( $(cat "$count" 2> /dev/null || printf 0) + 1 ))
    printf '%s\n' "$n" > "$count"
    if (( n == 2 )) && [[ -n ${APT_SIM_DO:-} && ${APT_SIM_DO_KIND:-purge} == "$kind" ]]; then
        . "$APT_SIM_DO"
    fi
    printf 'Reading package lists...\nBuilding dependency tree...\n'
    if [[ $kind == autoremove ]]; then
        [[ -z ${APT_AUTOREMOVE:-} ]] || cat "$APT_AUTOREMOVE"
        exit "${APT_AUTOREMOVE_STATUS:-0}"
    fi
    printf 'The following packages will be REMOVED:\n'
    purge=0
    for arg in "$@"; do
        if (( purge )) && [[ $arg != "${APT_SIM_SKIP:-}" ]]; then
            printf 'Purg %s [9.0-1kali1]\n' "$arg"
        elif [[ $arg == purge ]]; then
            purge=1
        fi
    done
    [[ -z ${APT_SIM_EXTRA:-} ]] || printf '%s\n' "$APT_SIM_EXTRA"
    exit "${APT_SIM_STATUS:-0}"
fi
if [[ -z ${APT_DO:-} ]]; then
    printf '%s: refused under test\n' "$STUB_NAME" >&2
    exit 100
fi
. "$APT_DO"
exit "${APT_STATUS:-0}"
EOF
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

# Add packages to dpkg's list: NAME and STATE pairs, STATE as ${db:Status-Abbrev} gives it
# without its blank, such as rc or hc, each with a package version.
listed() {
    listed_at 9.0-1kali1 "$@"
}

# Add packages to dpkg's list as listed does, each with the package version VERSION.
listed_at() {
    local version=$1
    shift
    while (( $# )); do
        printf '%s\t%s \t%s\n' "$1" "$2" "$version" >> "$DPKG_QUERY_OUT"
        shift 2
    done
}

# Have apt's simulation of its autoremove print the lines LINE..., as for the packages it would
# remove.
autoremoves() {
    export APT_AUTOREMOVE="$BATS_TEST_TMPDIR/autoremove.out"
    printf '%s\n' "$@" > "$APT_AUTOREMOVE"
}

# Have apt-mark showmanual print the package names NAME....
marked_manual() {
    export APT_MANUAL="$BATS_TEST_TMPDIR/manual.out"
    printf '%s\n' "$@" > "$APT_MANUAL"
}

# Have the real purge run the shell CODE, then exit STATUS, 0 by default.
on_purge() {
    export APT_DO="$BATS_TEST_TMPDIR/apt.do" APT_STATUS=${2:-0}
    printf '%s\n' "$1" > "$APT_DO"
}

# Have the second simulation of KIND, purge by default or autoremove, in the next run, the one
# after the question, first run the shell CODE.
on_recheck() {
    export APT_SIM_DO="$BATS_TEST_TMPDIR/apt-sim.do" APT_SIM_DO_KIND=${2:-purge}
    printf '%s\n' "$1" > "$APT_SIM_DO"
    rm -f "$BATS_TEST_TMPDIR"/apt-get.count.*
}

# Print the apt-get and sync calls in the stub log, in order.
apt_calls() {
    grep -E '^(apt-get|sync)( |$)' "$STUB_LOG" || true
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
    # The only tool cleanup ran is apt's simulation of its autoremove, which names nothing here.
    [ "$(grep -E '^(apt-get|apt-mark|dkms)( |$)' "$STUB_LOG" | sort -u)" = \
        "apt-get -s $AUTOREMOVE_OPTS" ]
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

@test "The rc step plans the config files removed kernels left, and lists those it leaves" {
    local name
    listed "linux-headers-$V0" rc linux-headers-9.0.0+kali-common rc linux-headers-amd64 rc \
        "linux-image-$V0" rc "linux-image-$V0-dbg" rc "linux-image-$V0-dbgsym" rc \
        linux-image-9.0.3+kali-amd64-unsigned rc linux-image-9.0.4+kali-amd64 hc \
        linux-image-amd64 rc linux-config-9.0 rc linux-kbuild-9.0.0+kali rc linux-libc-dev rc \
        firmware-linux-free rc
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old \
        rc purge "linux-headers-$V0" "$V0" rc purge "linux-image-$V0" "$V0" \
        rc purge linux-image-9.0.3+kali-amd64-unsigned 9.0.3+kali-amd64 \
        rc list linux-headers-9.0.0+kali-common 'headers shared by the kernels of 9.0.0+kali' \
        rc list "linux-image-$V0-dbg" 'a debug build' \
        rc list "linux-image-$V0-dbgsym" 'a debug build' \
        rc skip linux-image-9.0.4+kali-amd64 held \
        rc list linux-kbuild-9.0.0+kali 'build tools shared by the kernels of 9.0.0+kali')" ]
    [[ "$stderr" == *"plan: keep $V2 (running, vmlinuz) and $V1 (vmlinuz.old)"* ]]
    [[ "$stderr" == *"plan: purge 3 packages removed with config files left: linux-headers-$V0, \
linux-image-$V0 and linux-image-9.0.3+kali-amd64-unsigned"* ]]
    [[ "$stderr" == *"plan: leave 5 packages removed with config files left: \
linux-headers-9.0.0+kali-common (headers shared by the kernels of 9.0.0+kali), \
linux-image-$V0-dbg (a debug build), "*", linux-image-9.0.4+kali-amd64 (held) and \
linux-kbuild-9.0.0+kali (build tools shared by the kernels of 9.0.0+kali)"* ]]
    [[ "$stderr" == *"plan: then sync"*"dry run: nothing was changed"* ]]
    [ "$(apt_calls)" = "$(printf '%s\n' "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-headers-$V0 linux-image-$V0 \
linux-image-9.0.3+kali-amd64-unsigned")" ]
    # Metapackages, linux-config, linux-libc-dev and firmware are no kernel's own packages.
    for name in linux-headers-amd64 linux-image-amd64 linux-config linux-libc-dev firmware; do
        [[ "$output$stderr$(< "$STUB_LOG")" != *"$name"* ]] ||
            { printf '%s was named\n' "$name" >&2; return 1; }
    done
    private_output
    # --no-rc leaves the step out.
    : > "$STUB_LOG"
    run_ku cleanup -n --no-rc --porcelain
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [ "$(apt_calls)" = "apt-get -s $AUTOREMOVE_OPTS" ]
}

@test "No package of the running kernel's release or of one a /boot link points at is purged" {
    printf 'initrd 9.0.5\n' > "$ROOT/boot/initrd.img-9.0.5+kali-amd64"
    ln -sfn initrd.img-9.0.5+kali-amd64 "$ROOT/boot/initrd.img.old"
    # linux-image-V2-unsigned replaced linux-image-V2, which dpkg keeps with its config files.
    : > "$DPKG_QUERY_OUT"
    listed "linux-headers-$V1" rc "linux-image-$V0" rc "linux-image-$V1" ii "linux-image-$V2" rc \
        "linux-image-$V2-unsigned" ii linux-modules-9.0.5+kali-amd64 rc
    on_purge ''
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old protect keep 9.0.5+kali-amd64 initrd.img.old \
        rc purge "linux-image-$V0" "$V0" rc skip "linux-headers-$V1" 'its kernel is kept' \
        rc skip "linux-image-$V2" 'its kernel is kept' \
        rc skip linux-modules-9.0.5+kali-amd64 'its kernel is kept')" ]
    [[ "$stderr" == *"plan: keep $V2 (running, vmlinuz), $V1 (vmlinuz.old) and \
9.0.5+kali-amd64 (initrd.img.old)"* ]]
    [ "$(apt_calls | tail -n 2)" = "$(printf '%s\n' "apt-get -y $PURGE_OPTS linux-image-$V0" \
        sync)" ]
    [[ "$stderr" == *"cleanup: purged 1 package"* ]]
    private_output
}

@test "While a reboot into the kernel vmlinuz points at is pending, cleanup purges nothing" {
    listed "linux-image-$V0" rc
    export UNAME_R=$V1
    run_ku cleanup --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V1" 'running, vmlinuz.old' \
        protect keep "$V2" vmlinuz rc skip "$V2" 'reboot first' \
        autoremove skip "$V2" 'reboot first')" ]
    [[ "$stderr" == *"plan: purge nothing while a reboot is pending: /boot/vmlinuz points at \
$V2, but $V1 is running; reboot first"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [[ "$stderr" != *"Run the cleanup"* ]]
    refute_line_match '^(apt-get|apt-mark)( |$)' "$STUB_LOG"
    private_output
    # Each step left in shows the reboot it waits for.
    run_ku cleanup --porcelain --no-rc
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V1" 'running, vmlinuz.old' \
        protect keep "$V2" vmlinuz autoremove skip "$V2" 'reboot first')" ]
}

@test "A dry run only simulates, and a declined question or no terminal exits 10 unpurged" {
    listed "linux-image-$V0" rc
    on_purge ''
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"plan: purge 1 package removed with config files left: linux-image-$V0"* ]]
    [[ "$stderr" == *"plan: then sync"*"dry run: nothing was changed"* ]]
    [ "$(apt_calls)" = "$(printf '%s\n' "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-image-$V0")" ]
    # No terminal to ask on, then a no on it.
    run_ku cleanup
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"no terminal to confirm on; pass --yes to go ahead unattended"* ]]
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku cleanup
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"Run the cleanup as planned? Purged packages cannot be rolled back. [y/N]"* ]]
    [[ "$stderr" == *"declined; nothing was changed"* ]]
    [ -z "$output" ]
    refute_line_match '^(apt-get -y|sync)( |$)' "$STUB_LOG"
}

@test "With --yes or a yes, cleanup runs one apt-get purge of the planned set, then sync" {
    listed "linux-headers-$V0" rc "linux-image-$V0" rc
    on_purge ''
    export DPKG_FORCE=all
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(apt_calls)" = "$(printf '%s\n' "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-headers-$V0 linux-image-$V0" \
        "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-headers-$V0 linux-image-$V0" \
        "apt-get -y $PURGE_OPTS linux-headers-$V0 linux-image-$V0" sync)" ]
    [[ "$stderr" == *"cleanup: purged 2 packages"* ]]
    # The purge, which the stub logged last, gets no force flag for dpkg.
    refute_line_match '^DPKG_FORCE=' "$BATS_TEST_TMPDIR/env.apt-get"
    : > "$STUB_LOG"
    printf 'y\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku cleanup
    [ "$status" -eq 0 ]
    [ "$(apt_calls | tail -n 2)" = "$(printf '%s\n' \
        "apt-get -y $PURGE_OPTS linux-headers-$V0 linux-image-$V0" sync)" ]
    private_output
}

@test "A purge apt would widen, mix with installs or not simulate refuses with 3, unpurged" {
    listed "linux-image-$V0" rc
    on_purge ''
    export APT_SIM_EXTRA='Purg linux-image-amd64 [2026.1]'
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the purge cannot run as planned: apt would also remove linux-image-amd64; \
nothing was changed"* ]]
    [ -z "$output" ]
    export APT_SIM_EXTRA='Inst linux-image-9.0.9+kali-amd64 (9.0.9-1 kali-rolling [amd64])'
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt would also install or configure linux-image-9.0.9+kali-amd64;"* ]]
    export APT_SIM_EXTRA='Conf linux-base (4.12)'
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt would also install or configure linux-base;"* ]]
    export APT_SIM_EXTRA="" APT_SIM_SKIP="linux-image-$V0"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt would not remove linux-image-$V0;"* ]]
    export APT_SIM_SKIP="" APT_SIM_STATUS=100
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt-get cannot simulate the purge (status 100); nothing was changed"* ]]
    [ -z "$output" ]
    refute_line_match '^(apt-get -y|sync)( |$)' "$STUB_LOG"
    private_output
}

@test "dpkg's status, apt's auto marks, a link or a lock that changes while it asks exits 75" {
    local change
    listed "linux-image-$V0" rc
    on_purge ''
    lock_line 4242 /var/lib/dpkg/lock-frontend apt-get > "$BATS_TEST_TMPDIR/held"
    # shellcheck disable=SC2016 # the stub expands the variables
    for change in 'printf "Package: x\n" >> "$KU_ROOT/var/lib/dpkg/status"' \
        'printf "Package: x\nAuto-Installed: 1\n" >> "$KU_ROOT/var/lib/apt/extended_states"' \
        'ln -sfn vmlinuz-9.0.2+kali-amd64 "$KU_ROOT/boot/vmlinuz.old"'; do
        on_recheck "$change"
        run_ku cleanup --yes
        [ "$status" -eq 75 ] || { printf '%s: exited %s\n' "$change" "$status" >&2; return 1; }
        [[ "$stderr" == *"changed while the question waited"*"so the plan no longer holds: run \
cleanup again; nothing was changed"* ]]
    done
    ln -sfn "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    on_recheck "cat '$BATS_TEST_TMPDIR/held' > \"\$KU_ROOT/proc/locks\""
    run_ku cleanup --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"apt or dpkg is running: PID 4242 (apt-get) holds"* ]]
    refute_line_match '^(apt-get -y|sync)( |$)' "$STUB_LOG"
    private_output
}

@test "A failed purge exits 4 once dpkg's database changed, else 75 while a lock is held, else 3" {
    export HELD="$BATS_TEST_TMPDIR/held"
    listed "linux-image-$V0" rc
    lock_line 4242 /var/lib/dpkg/lock-frontend apt-get > "$HELD"
    # dpkg changed its status file, with apt's lock held when apt-get failed or not.
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'printf "Package: x\n" >> "$KU_ROOT/var/lib/dpkg/status"' 100
    run_ku cleanup --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"apt-get purge failed with status 100 after dpkg began to change its \
database: run 'dpkg --configure -a', then 'kernel-updater check'"* ]]
    [ "$(apt_calls | tail -n 1)" = sync ]
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'printf "Package: y\n" >> "$KU_ROOT/var/lib/dpkg/status"
        cat "$HELD" > "$KU_ROOT/proc/locks"' 100
    run_ku cleanup --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"run 'dpkg --configure -a', then 'kernel-updater check'"* ]]
    # So does dpkg's journal alone, which dpkg folds into the status file only later.
    : > "$ROOT/proc/locks"
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge ': > "$KU_ROOT/var/lib/dpkg/updates/0000"' 100
    run_ku cleanup --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"after dpkg began to change its database"* ]]
    rm "$ROOT/var/lib/dpkg/updates/0000"
    # Nothing changed, and apt or dpkg holds its lock now.
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'cat "$HELD" > "$KU_ROOT/proc/locks"' 100
    run_ku cleanup --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"apt-get purge failed with status 100 while apt or dpkg runs: PID 4242 \
(apt-get) holds /var/lib/dpkg/lock-frontend; run cleanup again once it is done; nothing was \
changed"* ]]
    # Nothing changed and no lock is held: apt or apt-guard refused.
    : > "$ROOT/proc/locks"
    on_purge '' 100
    run_ku cleanup --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt-get purge failed with status 100 before dpkg changed anything"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    [ -z "$output" ]
    private_output
}

@test "An interrupt during the purge exits 130 and says how to settle what dpkg left" {
    listed "linux-image-$V0" rc
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'printf "Package: x\n" >> "$KU_ROOT/var/lib/dpkg/status"
        kill -INT "$PPID"'
    run_ku cleanup --yes
    [ "$status" -eq 130 ]
    [[ "$stderr" == *"interrupted by SIGINT"* ]]
    [[ "$stderr" == *"the purge was cut short after dpkg began to change its database: run \
'dpkg --configure -a', then 'kernel-updater check'"* ]]
    [[ "$stderr" != *"cleanup: purged"* ]]
    [ "$(apt_calls | tail -n 1)" = sync ]
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'kill -INT "$PPID"'
    run_ku cleanup --yes
    [ "$status" -eq 130 ]
    [[ "$stderr" == *"the purge was cut short before dpkg changed its database; nothing was \
purged"* ]]
    private_output
}

@test "boot-links or kernels failing in the check after the purge exits 4" {
    listed "linux-image-$V0" rc
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'rm "$KU_ROOT/boot/initrd.img.old"'
    run_ku cleanup --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: boot-links: initrd.img.old is missing or no symlink"* ]]
    [[ "$stderr" == *"the purge ran, but the check of the links and kernels after it fails"* ]]
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'printf "linux-modules-9.0.2+kali-amd64\tiF \t9-1kali1\n" >> "$DPKG_QUERY_OUT"'
    run_ku cleanup --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: kernels: $V2 is half-configured (iF): run dpkg --configure -a"* ]]
    [ "$(apt_calls | tail -n 1)" = sync ]
    private_output
}

@test "The packages of old kernels apt's autoremove names join the purge, and others are listed" {
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii "linux-headers-$V0" ii \
        linux-headers-9.0.0+kali-common ii linux-kbuild-9.0.0+kali ii
    # apt prints Purg with --purge and Remv without; a library and a debug build are no part of
    # a kernel that cleanup purges.
    autoremoves 'The following packages will be REMOVED:' \
        "  libfoo1* linux-headers-$V0* linux-headers-9.0.0+kali-common* linux-image-$V0*" \
        "  linux-image-$V0-dbg* linux-kbuild-9.0.0+kali*" \
        '0 upgraded, 0 newly installed, 6 to remove and 0 not upgraded.' \
        'Purg libfoo1 [1.2-3]' "Purg linux-headers-$V0 [9.0.0-1kali1]" \
        'Remv linux-headers-9.0.0+kali-common [9.0.0-1kali1]' \
        "Purg linux-image-$V0 [9.0.0-1kali1]" "Purg linux-image-$V0-dbg [9.0.0-1kali1]" \
        'Remv linux-kbuild-9.0.0+kali [9.0.0-1kali1]'
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old \
        autoremove purge "linux-headers-$V0" "$V0" \
        autoremove purge linux-headers-9.0.0+kali-common 9.0.0+kali \
        autoremove purge "linux-image-$V0" "$V0" \
        autoremove purge linux-kbuild-9.0.0+kali 9.0.0+kali \
        autoremove list libfoo1 'not a versioned kernel package' \
        autoremove list "linux-image-$V0-dbg" 'a debug build')" ]
    [[ "$stderr" == *"plan: purge 4 packages apt autoremove names for old kernels: \
linux-headers-$V0, linux-headers-9.0.0+kali-common, linux-image-$V0 and \
linux-kbuild-9.0.0+kali"* ]]
    [[ "$stderr" == *"plan: leave 2 packages apt autoremove names: libfoo1 (not a versioned \
kernel package) and linux-image-$V0-dbg (a debug build)"* ]]
    [[ "$stderr" == *"plan: then sync"*"dry run: nothing was changed"* ]]
    [ "$(apt_calls)" = "$(printf '%s\n' "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-headers-$V0 linux-headers-9.0.0+kali-common \
linux-image-$V0 linux-kbuild-9.0.0+kali")" ]
    grep -qx 'apt-mark showmanual' "$STUB_LOG"
    private_output
}

@test "An -unsigned image apt's autoremove names counts for its release; a metapackage is listed" {
    # linux-image-V1-unsigned replaced linux-image-V1, which dpkg keeps with its config files.
    # apt keeps a kernel by the name after linux-image-, so it may name the unsigned build of
    # one the links point at.
    : > "$DPKG_QUERY_OUT"
    listed_at 9-1kali1 "linux-image-$V1" rc "linux-image-$V1-unsigned" ii "linux-image-$V2" ii
    listed_at 9.0.3-1kali1 linux-image-9.0.3+kali-amd64-unsigned ii
    # A kernel package dpkg does not list as installed is not purged on apt's word alone.
    autoremoves 'Purg linux-config-9.0 [9.0.3-1kali1]' \
        "Purg linux-image-$V1-unsigned [9-1kali1]" \
        'Purg linux-image-9.0.3+kali-amd64-unsigned [9.0.3-1kali1]' \
        'Purg linux-image-9.0.4+kali-amd64 [9.0.4-1kali1]' 'Purg linux-image-amd64 [2026.1]'
    run_ku cleanup -n --porcelain --no-rc
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old \
        autoremove purge linux-image-9.0.3+kali-amd64-unsigned 9.0.3+kali-amd64 \
        autoremove list linux-config-9.0 'not a versioned kernel package' \
        autoremove skip "linux-image-$V1-unsigned" 'its kernel is kept' \
        autoremove skip linux-image-9.0.4+kali-amd64 'dpkg does not list it as installed' \
        autoremove list linux-image-amd64 'not a versioned kernel package')" ]
    [[ "$stderr" == *"plan: leave 4 packages apt autoremove names: linux-config-9.0 (not a \
versioned kernel package), linux-image-$V1-unsigned (its kernel is kept), \
linux-image-9.0.4+kali-amd64 (dpkg does not list it as installed) and linux-image-amd64 (not a \
versioned kernel package)"* ]]
    [ "$(apt_calls | tail -n 1)" = \
        "apt-get -s $PURGE_OPTS linux-image-9.0.3+kali-amd64-unsigned" ]
    private_output
}

@test "A package that shares its version with a kept kernel stays, as the .old kernel's headers" {
    # vmlinuz.old points at V0, older than V1, the second kernel apt keeps, so apt names V0's
    # packages with those of a kernel older still. The headers and build tools the kernels of
    # V0's ABI share name no release that cleanup keeps.
    printf 'kernel %s\n' "$V0" > "$ROOT/boot/vmlinuz-$V0"
    printf 'initrd %s\n' "$V0" > "$ROOT/boot/initrd.img-$V0"
    ln -sfn "vmlinuz-$V0" "$ROOT/boot/vmlinuz.old"
    ln -sfn "initrd.img-$V0" "$ROOT/boot/initrd.img.old"
    : > "$DPKG_QUERY_OUT"
    listed_at 8.9.9-1kali1 "linux-image-$OLD" ii linux-headers-8.9.9+kali-common ii
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii "linux-headers-$V0" ii \
        linux-headers-9.0.0+kali-common ii linux-kbuild-9.0.0+kali ii
    listed_at 9.0.1-1kali1 "linux-image-$V1" ii
    listed_at 9.0.2-1kali1 "linux-image-$V2" ii
    autoremoves "Purg linux-headers-$V0 [9.0.0-1kali1]" \
        'Purg linux-headers-8.9.9+kali-common [8.9.9-1kali1]' \
        'Purg linux-headers-9.0.0+kali-common [9.0.0-1kali1]' \
        "Purg linux-image-$OLD [8.9.9-1kali1]" "Purg linux-image-$V0 [9.0.0-1kali1]" \
        'Purg linux-kbuild-9.0.0+kali [9.0.0-1kali1]'
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V0" vmlinuz.old \
        autoremove purge linux-headers-8.9.9+kali-common 8.9.9+kali \
        autoremove purge "linux-image-$OLD" "$OLD" \
        autoremove skip "linux-headers-$V0" 'its kernel is kept' \
        autoremove skip linux-headers-9.0.0+kali-common 'shares its version with a kept kernel' \
        autoremove skip "linux-image-$V0" 'its kernel is kept' \
        autoremove skip linux-kbuild-9.0.0+kali 'shares its version with a kept kernel')" ]
    [[ "$stderr" == *"plan: keep $V2 (running, vmlinuz) and $V0 (vmlinuz.old)"* ]]
    [ "$(apt_calls | tail -n 1)" = "apt-get -s $PURGE_OPTS linux-headers-8.9.9+kali-common \
linux-image-$OLD" ]
    private_output
}

@test "A held candidate is skipped, and an old kernel marked manual is listed with a hint" {
    local expected
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii "linux-headers-$V0" ii
    listed_at 8.9.9-1kali1 "linux-image-$OLD" hi
    # apt-mark also names the running kernel and a metapackage, which need no hint.
    marked_manual bash linux-image-amd64 "linux-image-$V0" "linux-image-$V2"
    expected=$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old autoremove purge "linux-headers-$V0" "$V0" \
        autoremove skip "linux-image-$OLD" held \
        autoremove list "linux-image-$V0" "marked manual; 'apt-mark auto linux-image-$V0' lets \
apt prune it")
    # apt names neither a package marked manual nor a held one, and cleanup does not rely on it.
    autoremoves "Purg linux-headers-$V0 [9.0.0-1kali1]" "Purg linux-image-$OLD [8.9.9-1kali1]"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    [[ "$stderr" == *"plan: leave 1 package apt autoremove names: linux-image-$OLD (held)"* ]]
    [[ "$stderr" == *"plan: leave linux-image-$V0: marked manual; 'apt-mark auto \
linux-image-$V0' lets apt prune it"* ]]
    autoremoves "Purg linux-headers-$V0 [9.0.0-1kali1]" "Purg linux-image-$V0 [9.0.0-1kali1]" \
        "Purg linux-image-$OLD [8.9.9-1kali1]"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    on_purge ''
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [ "$(apt_calls | tail -n 2)" = "$(printf '%s\n' "apt-get -y $PURGE_OPTS linux-headers-$V0" \
        sync)" ]
    [[ "$stderr" == *"cleanup: purged 1 package"* ]]
    private_output
}

@test "The rc and autoremove steps purge in one apt-get run, checked as one set" {
    listed "linux-image-$OLD" rc
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii
    autoremoves "Purg linux-image-$V0 [9.0.0-1kali1]"
    on_purge ''
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old rc purge "linux-image-$OLD" "$OLD" \
        autoremove purge "linux-image-$V0" "$V0")" ]
    [[ "$stderr" == *"plan: purge 1 package removed with config files left: linux-image-$OLD"* ]]
    [[ "$stderr" == *"plan: purge 1 package apt autoremove names for old kernels: \
linux-image-$V0"* ]]
    [ "$(apt_calls)" = "$(printf '%s\n' "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-image-$OLD linux-image-$V0" \
        "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-image-$OLD linux-image-$V0" \
        "apt-get -y $PURGE_OPTS linux-image-$OLD linux-image-$V0" sync)" ]
    [[ "$stderr" == *"cleanup: purged 2 packages"* ]]
    private_output
}

@test "A purge apt would widen to a DKMS package or a metapackage refuses with 3, naming it" {
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii "linux-headers-$V0" ii
    # A DKMS package built for V0's headers is garbage too, and only listed, but the purge of
    # the headers takes it along.
    autoremoves 'Purg ku-dkms [1.0-1]' "Purg linux-headers-$V0 [9.0.0-1kali1]" \
        "Purg linux-image-$V0 [9.0.0-1kali1]"
    on_purge ''
    export APT_SIM_EXTRA='Purg ku-dkms [1.0-1]'
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the purge cannot run as planned: apt would also remove ku-dkms; nothing \
was changed"* ]]
    [ -z "$output" ]
    export APT_SIM_EXTRA='Purg linux-image-amd64 [2026.1]'
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt would also remove linux-image-amd64; nothing was changed"* ]]
    [ -z "$output" ]
    refute_line_match '^(apt-get -y|sync)( |$)' "$STUB_LOG"
    private_output
}

@test "--no-rc and --no-autoremove leave their step out of the plan" {
    listed "linux-image-$OLD" rc
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii
    autoremoves "Purg linux-image-$V0 [9.0.0-1kali1]"
    run_ku cleanup -n --porcelain --no-rc
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old autoremove purge "linux-image-$V0" "$V0")" ]
    [ "$(apt_calls)" = "$(printf '%s\n' "apt-get -s $AUTOREMOVE_OPTS" \
        "apt-get -s $PURGE_OPTS linux-image-$V0")" ]
    : > "$STUB_LOG"
    run_ku cleanup -n --porcelain --no-autoremove
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep "$V1" vmlinuz.old rc purge "linux-image-$OLD" "$OLD")" ]
    [ "$(apt_calls)" = "apt-get -s $PURGE_OPTS linux-image-$OLD" ]
    refute_line_match '^apt-mark' "$STUB_LOG"
    : > "$STUB_LOG"
    run_ku cleanup -n --porcelain --no-rc --no-autoremove
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    refute_line_match '^(apt-get|apt-mark)( |$)' "$STUB_LOG"
}

@test "An autoremove that fails or would install, or apt-mark failing, refuses with 3" {
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii
    export APT_AUTOREMOVE_STATUS=100
    run_ku cleanup -n --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt-get cannot simulate its autoremove (status 100); nothing was \
changed"* ]]
    [ -z "$output" ]
    export APT_AUTOREMOVE_STATUS=0
    autoremoves "Purg linux-image-$V0 [9.0.0-1kali1]" \
        'Inst libfoo2 (1.0-1 kali-rolling [amd64])' 'Conf libfoo2 (1.0-1 kali-rolling [amd64])'
    run_ku cleanup -n --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt's autoremove would also install or configure libfoo2; nothing was \
changed"* ]]
    [ -z "$output" ]
    autoremoves "Purg linux-image-$V0 [9.0.0-1kali1]"
    export APT_MARK_STATUS=100
    run_ku cleanup -n --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"apt-mark cannot list the packages marked manual (status 100); nothing \
was changed"* ]]
    [ -z "$output" ]
    # None of them got as far as the simulation of the purge.
    refute_line_match '^apt-get -s .* purge ' "$STUB_LOG"
    private_output
}

@test "An autoremove that names other packages once the question is answered exits 75" {
    listed_at 9.0.0-1kali1 "linux-image-$V0" ii
    listed_at 8.9.9-1kali1 "linux-image-$OLD" ii
    autoremoves "Purg linux-image-$V0 [9.0.0-1kali1]"
    on_purge ''
    on_recheck "printf 'Purg linux-image-$OLD [8.9.9-1kali1]\n' >> \"\$APT_AUTOREMOVE\"" \
        autoremove
    run_ku cleanup --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"changed while the question waited"*"so the plan no longer holds: run \
cleanup again; nothing was changed"* ]]
    refute_line_match '^(apt-get -y|sync)( |$)' "$STUB_LOG"
    private_output
}
