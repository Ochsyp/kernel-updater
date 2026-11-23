#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater cleanup command checks
#
# Runs kernel-updater cleanup on a KU_ROOT tree of a migrated system with stub tools: its usage
# and usage errors, root and the tool's lock, the keys detect fills, the identity of /boot, the
# links in /boot, the kernel packages' states, an interrupted dpkg run, a migration that is not
# finished or a partition 1 that cannot tell, apt's and dpkg's locks as /proc/locks shows them,
# a clean system with nothing to do, the plan lines in both forms,
# and the environment the tools it runs get; then the purge of the config files removed kernels
# left: what it plans, keeps and lists, a pending reboot, the dry run and the question, the one
# purge and the sync, the simulation that must match the plan, changes while the question
# waits, a purge that fails or is interrupted, and the check after it; and the purge of the old
# kernels apt's autoremove names: which of its packages join the purge and which it keeps or
# only lists, kernels marked manual, one purge for both steps, a purge apt would widen, the
# options that leave a step out, and a simulation that fails or changes while the question
# waits; and the module trees: each reason that keeps one, which the plan shows, an owner each
# of dpkg-query -S's four patterns finds alone, dpkg-query failing, an empty tree removed with
# rmdir and another moved into the quarantine, origin first, a kill before the move, a
# quarantine on another device or an mv that cannot refuse to copy, a tree this run's purge
# leaves, a re-check that keeps a tree, merged and separate modules directories, --no-modules
# and the dry run; and the quarantine's expiry: seen, which a real run writes, the age that
# counts from the newer of an entry's stamp and seen, the order of the deletion and the parts an
# entry lacks, quarantine_days, a clock that is behind, the entries and the quarantine that are
# only listed, the dry run and the question, and an entry that changed or went meanwhile; the
# records --porcelain prints only once the run ends with 0, and sync before the last line. No
# identifier is printed.
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
# The quarantine, as cleanup names it.
Q=/var/lib/kernel-updater/quarantine

# A migrated Kali system: kernels V1 and V2, V2 running, linux-base keeping the links in /boot
# on V2 and V1, a configuration that names /boot and its LUKS container, dpkg's and apt's state
# and lock files, an empty updates directory, no lock in /proc/locks, and a stand-in partition 1
# that holds the menu of a finished migration.
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
    # The time the date stub gives: 2026-11-14 12:00:00 UTC.
    export DATE_NOW=1794657600
    configure 5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c01
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    kernels "$V1" "$V2"
    ln -s "vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    ln -s "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
    stub_system_tools
    stubs
    export KU_P1_DIR="$BATS_TEST_TMPDIR/p1"
    write_finished_menu "$KU_P1_DIR"
}

# Write the stubs that answer for the system: root, the tool's lock, stat, /boot's mount, dpkg,
# linux-version, date and sync; apt-get as the apt-get stub below says; apt-mark, whose
# showmanual prints the lines of the file APT_MANUAL names, or nothing, and exits
# APT_MARK_STATUS; dkms, whose status -k RELEASE prints the lines of the file DKMS_LIST names
# that name RELEASE; and mv, rmdir, mkdir and rm, which run the real ones. apt-mark and dkms
# refuse anything else. dpkg-query, apt-get, apt-mark and dkms leave the environment they got
# in env.NAME beside the stub log.
stubs() {
    mkstub id <<'EOF'
printf '%s\n' "${ID_U:-0}"
EOF
    mkstub flock
    # Root owns the config file and what holds the quarantine, with mode 0600, and the
    # quarantine, with mode 0700, on the device STAT_DEV when that is set. Asked for owners and
    # devices, it shows root's and the real devices, but another user's for each path the file
    # foreign.owner beside the stub log lists, and another device for each that foreign.dev
    # lists. The real stat answers the rest, such as the inodes of dpkg's lock files and the
    # devices of the module trees.
    export REAL_STAT
    REAL_STAT=$(type -P stat)
    mkstub stat <<'EOF'
case " $* " in
    *" %u %a %d "*)
        dev=$("$REAL_STAT" -c %d -- "${@: -1}") || exit
        printf '0 700 %s\n' "${STAT_DEV:-$dev}"
        ;;
    *" %u %d "*)
        shift 3
        for path in "$@"; do
            dev=$("$REAL_STAT" -c %d -- "$path") || exit
            owner=0
            if grep -F -q -x -e "$path" "${STUB_LOG%/*}/foreign.owner" 2> /dev/null; then
                owner=1000
            fi
            if grep -F -q -x -e "$path" "${STUB_LOG%/*}/foreign.dev" 2> /dev/null; then
                dev=4242
            fi
            printf '%s %s\n' "$owner" "$dev"
        done
        ;;
    *" %u %a "*) printf '0 600\n' ;;
    *" -c %u -- "*)
        if grep -F -q -x -e "${*: -1}" "${STUB_LOG%/*}/foreign.owner" 2> /dev/null; then
            printf '1000\n'
        else
            printf '0\n'
        fi
        ;;
    *) exec "$REAL_STAT" "$@" ;;
esac
EOF
    # date -u +%s prints DATE_NOW, the time the tests set; the real date answers the rest.
    export REAL_DATE
    REAL_DATE=$(type -P date)
    mkstub date <<'EOF'
if [[ $* == '-u +%s' ]]; then
    printf '%s\n' "$DATE_NOW"
    exit 0
fi
exec "$REAL_DATE" "$@"
EOF
    # FINDMNT_OUT is /boot's mount line; empty means /boot is not mounted.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    mkstub findmnt <<'EOF'
[[ " $* " == *" --mountpoint "* && -n $FINDMNT_OUT ]] || exit 1
printf '%s\n' "$FINDMNT_OUT"
EOF
    # dpkg-query -W prints the file DPKG_QUERY_OUT names and exits DPKG_QUERY_STATUS. -S looks
    # each pattern up in the PACKAGE: PATH lines of the file DPKG_OWNERS names, as dpkg-query
    # does: one with a wildcard as a glob whose * matches a slash too, any other as the literal
    # path; it exits 1 when any pattern finds nothing, or with the status that the file
    # dpkg-query.S.status beside the stub log holds.
    mkstub dpkg-query <<'EOF'
env > "${STUB_LOG%/*}/env.dpkg-query"
if [[ $1 == -S ]]; then
    shift
    forced=${STUB_LOG%/*}/dpkg-query.S.status
    [[ ! -s $forced ]] || exit "$(< "$forced")"
    status=0
    for pattern in "$@"; do
        found=0
        while IFS= read -r line; do
            path=${line#*: }
            case $pattern in
                *'*'* | *'?'* | *'['*) [[ $path == $pattern ]] || continue ;;
                *) [[ $path == "$pattern" ]] || continue ;;
            esac
            printf '%s\n' "$line"
            found=1
        done < "${DPKG_OWNERS:-/dev/null}"
        if (( ! found )); then
            printf 'dpkg-query: no path found matching pattern %s\n' "$pattern" >&2
            status=1
        fi
    done
    exit "$status"
fi
cat "$DPKG_QUERY_OUT"
exit "${DPKG_QUERY_STATUS:-0}"
EOF
    mkstub linux-version <<'EOF'
[[ $1 == sort ]] && exec sort -V
EOF
    # sync says on stderr that it ran when SYNC_SAYS is set, and exits SYNC_STATUS.
    mkstub sync <<'EOF'
[[ -z ${SYNC_SAYS:-} ]] || printf 'sync ran\n' >&2
exit "${SYNC_STATUS:-0}"
EOF
    mkstub apt-mark <<'EOF'
env > "${STUB_LOG%/*}/env.$STUB_NAME"
if [[ $* == showmanual ]]; then
    [[ -z ${APT_MANUAL:-} ]] || cat "$APT_MANUAL"
    exit "${APT_MARK_STATUS:-0}"
fi
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
    # dkms lists its modules as "MODULE/VERSION, RELEASE, ARCH: STATE". With DKMS_MISSING set it
    # exits 127, as env does for a tool that is not installed.
    mkstub dkms <<'EOF'
env > "${STUB_LOG%/*}/env.$STUB_NAME"
[[ -z ${DKMS_MISSING:-} ]] || exit 127
if [[ $# == 3 && $1 == status && $2 == -k ]]; then
    [[ -z ${DKMS_LIST:-} ]] || grep -F ", $3, " "$DKMS_LIST" || true
    exit 0
fi
printf '%s: refused under test\n' "$STUB_NAME" >&2
exit 100
EOF
    # mv takes --no-copy, which the real one may lack and a rename within one filesystem does
    # without, and names it in its --help unless MV_OLD is set. It notes whether the quarantine
    # entry it moves into holds origin, and with MV_KILL set kills the tool before it moves
    # anything, as a kill at that moment would. mkdir notes its umask. rm fails for a path that
    # ends in RM_FAIL, as on a read-only filesystem.
    export REAL_MV REAL_RMDIR REAL_MKDIR REAL_RM
    REAL_MV=$(type -P mv) REAL_RMDIR=$(type -P rmdir) REAL_MKDIR=$(type -P mkdir)
    REAL_RM=$(type -P rm)
    mkstub rm <<'EOF'
if [[ -n ${RM_FAIL:-} && ${*: -1} == *"$RM_FAIL" ]]; then
    printf 'rm: cannot remove %s: Read-only file system\n' "${*: -1}" >&2
    exit 1
fi
exec "$REAL_RM" "$@"
EOF
    mkstub mv <<'EOF'
if [[ $* == --help ]]; then
    printf 'Usage: mv [OPTION]... [-T] SOURCE DEST\n'
    [[ -n ${MV_OLD:-} ]] || printf '      --no-copy                do not copy if renaming fails\n'
    exit 0
fi
dest=${*: -1}
[[ ! -e ${dest%/*}/origin ]] || printf '  origin was written\n' >> "$STUB_LOG"
if [[ -n ${MV_KILL:-} ]]; then
    kill -KILL "$PPID"
    exit 1
fi
args=()
for arg in "$@"; do
    [[ $arg == --no-copy ]] || args+=("$arg")
done
exec "$REAL_MV" "${args[@]}"
EOF
    mkstub rmdir <<'EOF'
exec "$REAL_RMDIR" "$@"
EOF
    mkstub mkdir <<'EOF'
printf '  umask %s\n' "$(umask)" >> "$STUB_LOG"
exec "$REAL_MKDIR" "$@"
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

# Make the module tree RELEASE in the modules directory DIR, such as /usr/lib/modules, under
# ROOT: empty, or holding the files FILE..., each holding its own name.
module_tree() {
    local tree=$ROOT$1/$2 file
    shift 2
    mkdir -p "$tree"
    for file in "$@"; do
        mkdir -p "$(dirname "$tree/$file")"
        printf '%s\n' "$file" > "$tree/$file"
    done
}

# Have dpkg-query -S name PACKAGE as the owner of PATH, for each PACKAGE and PATH pair.
owns() {
    export DPKG_OWNERS="$BATS_TEST_TMPDIR/owners"
    while (( $# )); do
        printf '%s: %s\n' "$1" "$2" >> "$DPKG_OWNERS"
        shift 2
    done
}

# Print the names in the quarantine, one per line, or nothing while there is none.
entries() {
    if [[ -d $ROOT/var/lib/kernel-updater/quarantine ]]; then
        ls -A "$ROOT/var/lib/kernel-updater/quarantine"
    fi
}

# Print the line the stub log holds for a call of NAME with ARGS, each quoted as a stub logs it.
logged() {
    local name=$1
    shift
    printf '%s' "$name"
    printf ' %q' "$@"
    printf '\n'
}

# Print the plan records of the releases cleanup keeps on setup's system: V2, which runs and
# vmlinuz points at, and V1, which vmlinuz.old points at.
kept() {
    printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' protect keep "$V1" vmlinuz.old
}

# Print the UTC time DAYS days and SECONDS seconds before DATE_NOW, the date stub's time, or
# after it when negative, as cleanup writes a stamp: YYYYmmddTHHMMSSZ.
ago() {
    date -u -d "@$(( DATE_NOW - $1 * 86400 - ${2:-0} ))" +%Y%m%dT%H%M%SZ
}

# Make the quarantine entry RELEASE.STAMP under ROOT as cleanup leaves one: its tree, which holds
# a module, and its origin; with SEEN, also its seen, which holds SEEN.
quarantined() {
    local entry=$ROOT$Q/$1.$2
    mkdir -p "$entry/tree/kernel"
    printf 'module\n' > "$entry/tree/kernel/a.ko"
    printf 'path: /usr/lib/modules/%s\n' "$1" > "$entry/origin"
    if [[ -n ${3:-} ]]; then
        printf '%s\n' "$3" > "$entry/seen"
    fi
}

# Print the plan record of the quarantine entry NAME with ACTION and DETAIL.
expiry() {
    printf '%s\t%s\t%s\t%s\n' expire "$1" "$Q/$2" "$3"
}

# Have stat show the path PATH under ROOT with KIND: owner, another user as its owner, or dev,
# another device.
foreign() {
    printf '%s\n' "$ROOT$2" >> "$BATS_TEST_TMPDIR/foreign.$1"
}

# Replace the stand-in for partition 1 with a real lookup: /boot lies on the disk sdb, whose
# partition 1 is the NTFS filesystem the configuration names.
stick_on_disk() {
    unset KU_P1_DIR
    mkdir -p "$ROOT/run"
    printf 'disk_ptuuid = 5ca1ab1e\np1_fs_uuid = 5CA1AB1E00000001\n' >> "$ROOT$CONF"
    mkstub lsblk <<'EOF'
case " $* " in
    *" -s "*) printf '/dev/mapper/boot_crypt crypt\n/dev/sdb3 part\n/dev/sdb disk\n' ;;
    *" -d "*) printf '5ca1ab1e\n' ;;
    *) printf '/dev/sdb   \n/dev/sdb1 1 ntfs 5CA1AB1E00000001\n/dev/sdb3 3 crypto_LUKS x\n' ;;
esac
EOF
}

# Have partition 1 mount as root's, showing a finished menu, and findmnt list that mount while it
# is there. The mount number MOUNT_CHANGE_AT also changes dpkg's status file, as an apt run would.
stick_mounts() {
    export MENU_SRC="$BATS_TEST_TMPDIR/menu" MOUNTED="$BATS_TEST_TMPDIR/mounted"
    write_finished_menu "$MENU_SRC"
    mkstub mount <<'EOF'
n=$(( $(cat "$MOUNTED.count" 2> /dev/null || printf 0) + 1 ))
printf '%s\n' "$n" > "$MOUNTED.count"
if (( n == ${MOUNT_CHANGE_AT:-0} )); then
    printf 'changed\n' >> "$KU_ROOT/var/lib/dpkg/status"
fi
cp -r "$MENU_SRC"/. "${*: -1}"/
printf '%s\n' "${*: -1}" > "$MOUNTED"
EOF
    mkstub umount <<'EOF'
rm -rf "${*: -1}"/multibootusb
rm -f "$MOUNTED"
EOF
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*) printf '%s\n' "$FINDMNT_OUT" ;;
    *" -o TARGET --source "*) [[ -s $MOUNTED ]] && cat "$MOUNTED" ;;
    *) exit 1 ;;
esac
EOF
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

@test "cleanup refuses with 3 and purges nothing while the menu stage has not run" {
    local args grub=$KU_P1_DIR/multibootusb/grub
    listed "linux-image-$OLD" rc
    rm "$grub/kali.cfg"
    printf 'menuentry "Other" {\n\ttrue\n}\n' > "$grub/grub.cfg"
    for args in "" "-n" "--yes"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku cleanup $args
        [ "$status" -eq 3 ] || { printf '"%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [[ "$stderr" == *"the Kali entries still boot kernels by their versions, which a purge \
could take away: run 'kernel-updater migrate --stage menu', boot the new entries, then run \
'kernel-updater migrate --stage finalize'; nothing was changed"* ]]
        [ -z "$output" ]
    done
    [ -z "$(apt_calls)" ]
    private_output
}

@test "cleanup refuses with 3 and purges nothing while legacy entries remain" {
    local args
    listed "linux-image-$OLD" rc
    # With CRLF line endings, as MultiBootUSB writes them.
    sed 's/$/\r/' "$REPO_DIR/tests/fixtures/grub/migrate-after.cfg" \
        > "$KU_P1_DIR/multibootusb/grub/grub.cfg"
    for args in "" "-n" "--yes"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku cleanup $args
        [ "$status" -eq 3 ] || { printf '"%s" exited %s\n' "$args" "$status" >&2; return 1; }
        [[ "$stderr" == *"the legacy Kali entries boot a kernel by its version, which a purge \
could take away: run 'kernel-updater migrate --stage finalize' after the boot tests; nothing \
was changed"* ]]
        [ -z "$output" ]
    done
    [ -z "$(apt_calls)" ]
    private_output
}

@test "A finished menu with CRLF line endings lets cleanup run" {
    sed -i 's/$/\r/' "$KU_P1_DIR/multibootusb/grub/grub.cfg"
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
}

@test "cleanup refuses while an export waits to put back a menu that boots kernels by version" {
    local out=$ROOT/root/kernel-updater/out name
    local waits="the export in output_dir waits to put back a menu whose Kali entries boot"
    listed "linux-image-$OLD" rc
    mkdir -p "$out"
    # A rollback in a VM only exports, so the stick still shows the finished menu.
    for name in migrate-before.cfg migrate-after.cfg; do
        cp "$REPO_DIR/tests/fixtures/grub/$name" "$out/grub.cfg"
        (cd "$out" && sha256sum grub.cfg > SHA256SUMS)
        run_ku cleanup --yes
        [ "$status" -eq 3 ] || { printf '%s exited %s\n' "$name" "$status" >&2; return 1; }
        [[ "$stderr" == *"$waits kernels by their versions, which a purge could take away"* ]]
        [[ "$stderr" == *"; nothing was changed"* ]]
    done
    [ -z "$(apt_calls | grep -v -e ' -s ' || true)" ]
    # A finished menu that differs from the stick, as after an ISO was added, puts back none.
    cp "$KU_P1_DIR/multibootusb/grub/grub.cfg" "$out/grub.cfg"
    printf '# an older copy\n' >> "$out/grub.cfg"
    (cd "$out" && sha256sum grub.cfg > SHA256SUMS)
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    private_output
}

@test "A change while cleanup reads the menu after the question exits 75 before the purge" {
    listed "linux-image-$OLD" rc
    stick_on_disk
    stick_mounts
    export MOUNT_CHANGE_AT=2
    run_ku cleanup --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"changed while the question waited"* ]]
    [ "$(cat "$MOUNTED.count")" -eq 2 ]
    [ -z "$(apt_calls | grep -v -e ' -s ' || true)" ]
    private_output
}

@test "cleanup names an export that waits to be copied before the stage that made it" {
    local out=$ROOT/root/kernel-updater/out grub=$KU_P1_DIR/multibootusb/grub
    local copy="copy the export in output_dir to the stick as its DEPLOY.txt says if you have"
    copy+=" not yet (a second copy would undo later changes); if you have,"
    mkdir -p "$out"
    # The menu stage exported, and Windows has not copied the files yet.
    printf 'exported kali.cfg\n' > "$out/kali.cfg"
    (cd "$out" && sha256sum kali.cfg > SHA256SUMS)
    rm "$grub/kali.cfg"
    printf 'menuentry "Other" {\n\ttrue\n}\n' > "$grub/grub.cfg"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$copy run 'kernel-updater migrate --stage menu', boot"* ]]
    # finalize exported, and its grub.cfg is not on the stick yet.
    write_finished_menu "$KU_P1_DIR"
    cp "$REPO_DIR/tests/fixtures/grub/migrate-after.cfg" "$grub/grub.cfg"
    printf 'exported grub.cfg\n' > "$out/grub.cfg"
    (cd "$out" && sha256sum grub.cfg > SHA256SUMS)
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$copy run 'kernel-updater migrate --stage finalize' after"* ]]
    # An export the stick already holds waits for nothing.
    cp "$grub/grub.cfg" "$out/grub.cfg"
    (cd "$out" && sha256sum grub.cfg > SHA256SUMS)
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"take away: run 'kernel-updater migrate --stage finalize' after"* ]]
    [[ "$stderr" != *"$copy"* ]]
    [ -z "$(apt_calls)" ]
    private_output
}

@test "cleanup refuses with 3 and purges nothing when legacy entries return during the question" {
    listed "linux-image-$OLD" rc
    on_recheck "cp '$REPO_DIR/tests/fixtures/grub/migrate-after.cfg' \
'$KU_P1_DIR/multibootusb/grub/grub.cfg'"
    run_ku cleanup --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the legacy Kali entries boot a kernel by its version"* ]]
    [ -z "$(apt_calls | grep -v -e ' -s ' || true)" ]
    private_output
}

@test "cleanup exits 66 and purges nothing while a desktop has partition 1 mounted for its user" {
    listed "linux-image-$OLD" rc
    stick_on_disk
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*) printf '%s\n' "$FINDMNT_OUT" ;;
    *" --source "*) printf '%s / rw,nosuid,nodev\n' "$KU_ROOT/media/user/BOOT" ;;
    *) exit 1 ;;
esac
EOF
    foreign owner /media/user/BOOT
    stub_refuse mount
    run_ku cleanup -n
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"so cleanup cannot tell whether the migration is finished: partition 1 is \
mounted where users other than root can change its files"* ]]
    [ -z "$(apt_calls)" ]
    private_output
}

@test "cleanup refuses with 3 and check's words on a damaged menu" {
    local grub=$KU_P1_DIR/multibootusb/grub
    listed "linux-image-$OLD" rc
    rm "$grub/kali.cfg"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"kali-menu: grub.cfg sources multibootusb/grub/kali.cfg, which is missing"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    write_finished_menu "$KU_P1_DIR"
    printf 'menuentry "Other" {\n\ttrue\n}\n' > "$grub/grub.cfg"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"kali-menu: multibootusb/grub/kali.cfg exists, but grub.cfg does not"* ]]
    write_finished_menu "$KU_P1_DIR"
    printf 'submenu "Open" {\n' >> "$grub/grub.cfg"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"kali-menu: the braces or quotes of grub.cfg do not balance"* ]]
    [ -z "$(apt_calls)" ]
    private_output
}

@test "cleanup exits 66 or 78 and purges nothing when partition 1 cannot tell the menu's state" {
    local unknown="so cleanup cannot tell whether the migration is finished"
    listed "linux-image-$OLD" rc
    stick_on_disk
    # Another stick.
    sed -i 's/^p1_fs_uuid = .*/p1_fs_uuid = 5CA1AB1E00000002/' "$ROOT$CONF"
    run_ku cleanup -n
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"is not the NTFS filesystem p1_fs_uuid names; nothing was changed"* ]]
    private_output
    # A stick the configuration does not name.
    sed -i '/^p1_fs_uuid = /d' "$ROOT$CONF"
    run_ku cleanup -n
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"the stick cannot be told apart, $unknown: set disk_ptuuid"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    private_output
    printf 'p1_fs_uuid = 5CA1AB1E00000001\n' >> "$ROOT$CONF"
    # The stick's partition 1 does not mount.
    mkstub mount <<< 'exit 32'
    run_ku cleanup -n
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"cannot read the stick's partition 1, $unknown: partition 1 does not mount"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    [ -z "$(ls -A "$ROOT/run")" ]
    private_output
    # /boot's disk cannot be listed.
    mkstub lsblk <<< 'exit 1'
    run_ku cleanup -n
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"cannot find the stick's partition 1, $unknown: lsblk cannot list"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    [ -z "$(apt_calls)" ]
    private_output
}

@test "cleanup reads the menu through a read-only mount and removes it before apt runs" {
    stick_on_disk
    stick_mounts
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    grep -q -F -e "$(logged mount -t ntfs3 -o nosuid,nodev,noexec,ro /dev/sdb1) " "$STUB_LOG"
    awk '/^umount / && !u { u = NR } /^apt-get / && !a { a = NR }
        END { exit !(u && a && u < a) }' "$STUB_LOG"
    [ -z "$(ls -A "$ROOT/run")" ]
    private_output
}

@test "cleanup names the detect and system stages before the menu" {
    local grub=$KU_P1_DIR/multibootusb/grub
    rm "$grub/kali.cfg"
    printf 'menuentry "Other" {\n\ttrue\n}\n' > "$grub/grub.cfg"
    printf 'do_symlinks = yes\nlink_in_boot = no\n' > "$ROOT/etc/kernel-img.conf"
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"run 'kernel-updater migrate --stage system' first"* ]]
    [[ "$stderr" != *"--stage menu"* ]]
    configure "" ""
    run_ku cleanup -n
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"'kernel-updater migrate --stage detect' first"* ]]
    [[ "$stderr" != *"--stage menu"* ]]
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
    # The records wait until the run prints them, which it does only once it ends with 0.
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib 'KU_VERBOSITY=0 KU_PORCELAIN=1
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
        _ku_cl_plan_line "" rc list "$(printf "odd\tname")" "$(printf "two\nlines")" rc skip x ""
        _ku_cl_print_records'
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

@test "An rc package whose kernel is still installed through its twin is skipped, not purged" {
    # linux-image-V0-unsigned replaced linux-image-V0: V0 is installed, though no link names it.
    # Purging the rc twin would run its postrm, which deletes V0's module index.
    : > "$DPKG_QUERY_OUT"
    listed "linux-image-$V1" ii "linux-image-$V2" ii "linux-image-$V0" rc \
        "linux-image-$V0-unsigned" ii
    on_purge ''
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(printf 'rc\tskip\t%s\t%s' "linux-image-$V0" \
        'its kernel is still installed')"* ]]
    [[ "$output" != *"rc"$'\t'"purge"* ]]
    [[ "$(apt_calls)" != *"apt-get -y"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
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
    # The failure is reported once, without the interrupt's "cut short" line.
    [[ "$stderr" != *"cut short"* ]]
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

@test "An interrupt while a failed purge is classified still says how to settle dpkg" {
    listed "linux-image-$V0" rc
    # apt-get changes dpkg's status and fails with 100, leaving the tool's PID; the first
    # sha256sum after that, the one that compares dpkg's status, sends SIGINT to the tool.
    # shellcheck disable=SC2016 # the stub expands the variables
    on_purge 'printf "Package: x\n" >> "$KU_ROOT/var/lib/dpkg/status"
        printf "%s\n" "$PPID" > "$KU_ROOT/tool.pid"' 100
    REAL_SHA256SUM=$(type -P sha256sum)
    export REAL_SHA256SUM
    mkstub sha256sum <<'EOF'
if [[ -f $KU_ROOT/tool.pid ]]; then
    pid=$(< "$KU_ROOT/tool.pid")
    rm -f "$KU_ROOT/tool.pid"
    kill -INT "$pid"
fi
exec "$REAL_SHA256SUM" "$@"
EOF
    run_ku cleanup --yes
    [ "$status" -eq 130 ]
    [[ "$stderr" == *"interrupted by SIGINT"* ]]
    [[ "$stderr" == *"the purge was cut short after dpkg began to change its database: run \
'dpkg --configure -a', then 'kernel-updater check'"* ]]
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

@test "A module tree that must stay is kept and the plan says why, but an installed kernel's not" {
    local m=/usr/lib/modules release
    # vmlinuz.old points at 9.0.3, a kernel built by hand that no package holds.
    printf 'kernel 9.0.3\n' > "$ROOT/boot/vmlinuz-9.0.3+kali-amd64"
    printf 'initrd 9.0.3\n' > "$ROOT/boot/initrd.img-9.0.3+kali-amd64"
    ln -sfn vmlinuz-9.0.3+kali-amd64 "$ROOT/boot/vmlinuz.old"
    ln -sfn initrd.img-9.0.3+kali-amd64 "$ROOT/boot/initrd.img.old"
    for release in "$V1" "$V2" 9.0.3+kali-amd64; do
        module_tree $m "$release" kernel/a.ko modules.dep
    done
    # A package of modules dkms built for 9.0.4, and 9.0.10's held image, removed with its
    # config files left.
    listed ku-modules-9.0.4+kali-amd64 ii linux-image-9.0.10+kali-amd64 hc
    module_tree $m 9.0.4+kali-amd64 updates/ku.ko
    module_tree $m 9.0.10+kali-amd64 modules.dep
    module_tree $m 9.0.5+kali-amd64 .fresh-install
    module_tree $m 9.0.6+kali-amd64 modules.dep
    printf 'config\n' > "$ROOT/boot/config-9.0.6+kali-amd64"
    ln -s "$V1" "$ROOT$m/9.0.7+kali-amd64"
    printf 'no tree\n' > "$ROOT$m/9.0.8+kali-amd64"
    module_tree $m 9.0.9+kali-amd64 updates/dkms/ku-test.ko
    export DKMS_LIST="$BATS_TEST_TMPDIR/dkms.list"
    printf 'ku-test/1.0, 9.0.9+kali-amd64, x86_64: installed\n' > "$DKMS_LIST"
    module_tree $m not-a-release modules.dep
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' protect keep "$V2" 'running, vmlinuz' \
        protect keep 9.0.3+kali-amd64 vmlinuz.old rc skip linux-image-9.0.10+kali-amd64 held \
        modules keep $m/9.0.10+kali-amd64 'dpkg lists linux-image-9.0.10+kali-amd64 (hc)' \
        modules keep $m/9.0.3+kali-amd64 'its kernel is kept (vmlinuz.old)' \
        modules keep $m/9.0.4+kali-amd64 'dpkg lists ku-modules-9.0.4+kali-amd64 (ii)' \
        modules keep $m/9.0.5+kali-amd64 \
        'it holds .fresh-install, which a kernel install leaves until it is configured' \
        modules keep $m/9.0.6+kali-amd64 '/boot holds config-9.0.6+kali-amd64' \
        modules keep $m/9.0.7+kali-amd64 'it is a symlink' \
        modules keep $m/9.0.8+kali-amd64 'it is no directory' \
        modules keep $m/9.0.9+kali-amd64 \
        "dkms lists modules for it ('dkms remove ku-test/1.0 -k 9.0.9+kali-amd64')" \
        modules keep $m/not-a-release 'its name is no kernel release')" ]
    [[ "$stderr" == *"plan: keep $m/9.0.9+kali-amd64: dkms lists modules for it ('dkms remove \
ku-test/1.0 -k 9.0.9+kali-amd64')"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    # Only the tree that no cheaper test keeps is looked up with dpkg-query -S.
    [ "$(grep -c '^dpkg-query -S ' "$STUB_LOG")" -eq 4 ]
    # Without dkms, the tree it may have built is kept all the same.
    export DKMS_MISSING=1
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nmodules\tkeep\t'"$m/9.0.9+kali-amd64"$'\t'"it holds updates/dkms, and \
dkms is not installed to tell whose"$'\n'* ]]
    private_output
}

@test "An owner that any one of dpkg-query -S's four patterns finds keeps the tree, each alone" {
    local m=/usr/lib/modules release entry expected=""
    local -a patterns=()
    for release in 9.0.4 9.0.5 9.0.6 9.0.7 9.0.8; do
        module_tree $m "$release+kali-amd64" kernel/a.ko
    done
    owns ku-a /lib/modules/9.0.4+kali-amd64 ku-b /usr/lib/modules/9.0.5+kali-amd64 \
        ku-c /lib/modules/9.0.6+kali-amd64/extra/c.ko ku-d /usr/lib/modules/9.0.7+kali-amd64/d.ko
    # As dpkg-query does, the stub exits 1 when one of several patterns finds nothing, and
    # still prints what the others found.
    run --separate-stderr "$STUB_BIN/dpkg-query" -S /lib/modules/9.0.4+kali-amd64 \
        /usr/lib/modules/9.0.4+kali-amd64
    [ "$status" -eq 1 ]
    [ "$output" = "ku-a: /lib/modules/9.0.4+kali-amd64" ]
    : > "$STUB_LOG"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' \
        modules keep $m/9.0.4+kali-amd64 'ku-a owns it' \
        modules keep $m/9.0.5+kali-amd64 'ku-b owns it' \
        modules keep $m/9.0.6+kali-amd64 'ku-c owns files in it' \
        modules keep $m/9.0.7+kali-amd64 'ku-d owns files in it' \
        modules quarantine $m/9.0.8+kali-amd64 'no package owns it')" ]
    # Each pattern gets a call of its own, and the first owner found ends the search.
    for entry in 9.0.4:1 9.0.5:2 9.0.6:3 9.0.7:4 9.0.8:4; do
        release=${entry%:*}+kali-amd64
        patterns=("/lib/modules/$release" "/usr/lib/modules/$release" "/lib/modules/$release/*"
            "/usr/lib/modules/$release/*")
        expected+=$(printf 'dpkg-query -S %q\n' "${patterns[@]:0:${entry#*:}}")$'\n'
    done
    [ "$(grep '^dpkg-query -S ' "$STUB_LOG")"$'\n' = "$expected" ]
    private_output
}

@test "dpkg-query -S failing refuses with 3 before any change, and exits 4 after the purge" {
    local tree=/usr/lib/modules/9.0.8+kali-amd64 failed="$BATS_TEST_TMPDIR/dpkg-query.S.status"
    module_tree /usr/lib/modules 9.0.8+kali-amd64 kernel/a.ko
    printf '2\n' > "$failed"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"dpkg-query -S failed with status 2, so cleanup cannot tell whether a \
package owns $tree; nothing was changed"* ]]
    [ -z "$output" ]
    refute_line_match '^(apt-get -y|sync)( |$)' "$STUB_LOG"
    rm "$failed"
    listed "linux-image-$V0" rc
    on_purge "printf '2\n' > '$failed'"
    run_ku cleanup --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"dpkg-query -S failed with status 2, so cleanup cannot tell whether a \
package owns $tree; the purge ran, and $tree and the module trees after it stay where they \
are: run cleanup again"* ]]
    [ -f "$ROOT$tree/kernel/a.ko" ]
    [ -z "$(entries)" ]
    refute_line_match '^mv --no-copy' "$STUB_LOG"
    [ "$(apt_calls | tail -n 1)" = sync ]
    private_output
}

@test "An empty module tree no package owns is removed with rmdir, and rm never runs" {
    local tree=/usr/lib/modules/9.0.8+kali-amd64
    stub_refuse rm
    module_tree /usr/lib/modules 9.0.8+kali-amd64
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules rmdir "$tree" \
        'empty, and no package owns it')" ]
    [[ "$stderr" == *"plan: remove the empty directory $tree"*"plan: then sync"* ]]
    [[ "$stderr" == *"cleanup: removed 1 empty module tree"* ]]
    [ ! -e "$ROOT$tree" ]
    [ -d "$ROOT/usr/lib/modules" ]
    [ "$(grep -E '^(rm|rmdir|mv|mkdir|sync)( |$)' "$STUB_LOG")" = \
        "$(logged rmdir -- "$ROOT$tree"; printf 'sync\n')" ]
    [ ! -e "$ROOT/var/lib/kernel-updater" ]
    private_output
}

@test "A module tree no package owns moves into a quarantine entry of mode 0700, origin first" {
    local tree=/usr/lib/modules/9.0.8+kali-amd64 base="$ROOT/var/lib/kernel-updater/quarantine"
    local entry line
    module_tree /usr/lib/modules 9.0.8+kali-amd64 kernel/a.ko modules.dep
    printf 'Package: x\n' > "$ROOT/var/lib/dpkg/status"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules quarantine "$tree" \
        'no package owns it')" ]
    [[ "$stderr" == *"plan: move $tree into the quarantine: no package owns it"* ]]
    [[ "$stderr" == *"cleanup: moved 1 module tree into the quarantine"* ]]
    [ ! -e "$ROOT$tree" ]
    entry=$(entries)
    [[ "$entry" =~ ^9\.0\.8\+kali-amd64\.[0-9]{8}T[0-9]{6}Z$ ]]
    [ "$(< "$base/$entry/tree/kernel/a.ko")" = kernel/a.ko ]
    [ "$(< "$base/$entry/tree/modules.dep")" = modules.dep ]
    # origin says where the tree came from, when and why; the run that made the entry writes no
    # seen.
    for line in "path: $tree" "release: 9.0.8+kali-amd64" "stamp: ${entry##*.}" \
        "dpkg-status: $(sha256sum < "$ROOT/var/lib/dpkg/status" | cut -d ' ' -f 1)" \
        "tool: kernel-updater $(< "$REPO_DIR/share/kernel-updater/VERSION")"; do
        grep -F -q -x -e "$line" "$base/$entry/origin" ||
            { printf 'origin lacks "%s"\n' "$line" >&2; return 1; }
    done
    grep -q '^reasons: no package owns it' "$base/$entry/origin"
    [ ! -e "$base/$entry/seen" ]
    # The entry is made with umask 077, and origin is written before the tree is renamed.
    [ "$(grep -F -x -A 1 -e "$(logged mkdir -- "$base/$entry")" "$STUB_LOG")" = \
        "$(logged mkdir -- "$base/$entry"; printf '  umask 0077\n')" ]
    [ "$(grep -F -x -A 1 -e "$(logged mv --no-copy -T -- "$ROOT$tree" "$base/$entry/tree")" \
        "$STUB_LOG")" = "$(logged mv --no-copy -T -- "$ROOT$tree" "$base/$entry/tree"
        printf '  origin was written\n')" ]
    # Git Bash on Windows keeps no such modes.
    if [[ $OSTYPE == linux* ]]; then
        [ "$(stat -c %a "$base")" = 700 ]
        [ "$(stat -c %a "$base/$entry")" = 700 ]
    fi
    [ "$(apt_calls | tail -n 1)" = sync ]
    private_output
}

@test "A kill after origin and before the move leaves the tree, which the next run plans again" {
    local tree=/usr/lib/modules/9.0.8+kali-amd64 base="$ROOT/var/lib/kernel-updater/quarantine"
    local entry
    module_tree /usr/lib/modules 9.0.8+kali-amd64 kernel/a.ko
    export MV_KILL=1
    run_ku cleanup --yes
    [ "$status" -eq 137 ]
    [ -f "$ROOT$tree/kernel/a.ko" ]
    entry=$(entries)
    grep -F -q -x -e "path: $tree" "$base/$entry/origin"
    [ ! -e "$base/$entry/tree" ]
    export MV_KILL=""
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    # The half-made entry stays as it is until it expires like any other.
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules quarantine "$tree" \
        'no package owns it'
        expiry keep "$entry" "0 days old by its stamp; no run has marked it seen yet \
(quarantine_days 30)")" ]
    [ "$(entries)" = "$entry" ]
    [ ! -e "$base/$entry/tree" ]
}

@test "A tree on another device than the quarantine, or without mv --no-copy, is only listed" {
    local tree=/usr/lib/modules/9.0.8+kali-amd64
    module_tree /usr/lib/modules 9.0.8+kali-amd64 kernel/a.ko
    mkdir -p "$ROOT/var/lib/kernel-updater/quarantine"
    export STAT_DEV=4242
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules list "$tree" \
        'no package owns it, but it lies on another filesystem than the quarantine')" ]
    [[ "$stderr" == *"plan: leave $tree: no package owns it, but it lies on another filesystem \
than the quarantine"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    export STAT_DEV="" MV_OLD=1
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules list "$tree" \
        'no package owns it, but mv cannot refuse to copy: --no-copy needs coreutils 9.2')" ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [ -f "$ROOT$tree/kernel/a.ko" ]
    [ -z "$(entries)" ]
    [ "$(grep -E '^(mv|mkdir|rmdir)( |$)' "$STUB_LOG" | sort -u)" = "mv --help" ]
}

@test "A tree whose release this run purges packages of is left, and the next run plans it" {
    local tree=/usr/lib/modules/$V0
    listed "linux-image-$V0" rc
    module_tree /usr/lib/modules "$V0" modules.dep
    # The purge takes V0's package from dpkg's list, and leaves the tree.
    on_purge "grep -v '^linux-image-$V0' '$DPKG_QUERY_OUT' > '$BATS_TEST_TMPDIR/rest'
        cat '$BATS_TEST_TMPDIR/rest' > '$DPKG_QUERY_OUT'"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' rc purge "linux-image-$V0" "$V0" \
        modules list "$tree" \
        'this run purges packages of its release; the next cleanup looks at what is left')" ]
    [[ "$stderr" == *"cleanup: purged 1 package"* ]]
    [ -f "$ROOT$tree/modules.dep" ]
    refute_line_match '^(mkdir|rmdir)( |$)|^mv --no-copy' "$STUB_LOG"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules quarantine "$tree" \
        'no package owns it')" ]
    private_output
}

@test "A planned tree a re-check finds owned, or while apt holds its lock, stays with a warning" {
    local tree=/usr/lib/modules/9.0.8+kali-amd64 gone=/usr/lib/modules/9.0.9+kali-amd64
    listed "linux-image-$V0" rc
    module_tree /usr/lib/modules 9.0.8+kali-amd64 kernel/a.ko
    module_tree /usr/lib/modules 9.0.9+kali-amd64
    owns ku-tool /usr/bin/ku-tool
    # A package that owns files in the tree turns up while the purge runs, and the empty tree
    # goes.
    on_purge "printf 'ku-late: %s\n' '$tree/extra/late.ko' >> '$DPKG_OWNERS'
        rm -d '$ROOT$gone'"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nmodules\tquarantine\t'"$tree"$'\tno package owns it\nmodules\trmdir\t'"\
$gone"$'\tempty, and no package owns it' ]]
    [[ "$stderr" == *"warning: left $tree where it is: ku-late owns files in it"* ]]
    [[ "$stderr" == *"warning: $gone went while cleanup ran, so there is nothing left to do for \
it"* ]]
    [[ "$stderr" == *"cleanup: purged 1 package and left 1 module tree a re-check kept"* ]]
    [ -f "$ROOT$tree/kernel/a.ko" ]
    [ -z "$(entries)" ]
    # So does a lock apt or dpkg holds by then.
    printf 'ku-tool: /usr/bin/ku-tool\n' > "$DPKG_OWNERS"
    lock_line 4242 /var/lib/dpkg/lock-frontend apt-get > "$BATS_TEST_TMPDIR/held"
    on_purge "cat '$BATS_TEST_TMPDIR/held' > '$ROOT/proc/locks'"
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: left $tree where it is: apt or dpkg is running: PID 4242 \
(apt-get) holds /var/lib/dpkg/lock-frontend; run cleanup again once it is done"* ]]
    [ -f "$ROOT$tree/kernel/a.ko" ]
    [ -z "$(entries)" ]
    refute_line_match '^(mkdir|rmdir)( |$)|^mv --no-copy' "$STUB_LOG"
    private_output
}

@test "With a merged /usr cleanup scans one modules directory, and both with a separate /lib" {
    module_tree /usr/lib/modules 9.0.8+kali-amd64
    ln -s usr/lib "$ROOT/lib"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' modules rmdir \
        /usr/lib/modules/9.0.8+kali-amd64 'empty, and no package owns it')" ]
    rm "$ROOT/lib"
    module_tree /lib/modules 9.0.9+kali-amd64
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' \
        modules rmdir /usr/lib/modules/9.0.8+kali-amd64 'empty, and no package owns it' \
        modules rmdir /lib/modules/9.0.9+kali-amd64 'empty, and no package owns it')" ]
}

@test "--no-modules leaves module trees alone, quarantined ones too; a dry run changes nothing" {
    local a b
    a=9.0.6+kali-amd64.$(ago 100) b=9.0.7+kali-amd64.$(ago 100)
    module_tree /usr/lib/modules 9.0.8+kali-amd64
    module_tree /usr/lib/modules 9.0.9+kali-amd64 kernel/a.ko
    quarantined 9.0.6+kali-amd64 "${a##*.}" "$(ago 40)"
    quarantined 9.0.7+kali-amd64 "${b##*.}"
    find "$ROOT" | sort > "$BATS_TEST_TMPDIR/tree.before"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' \
        modules rmdir /usr/lib/modules/9.0.8+kali-amd64 'empty, and no package owns it' \
        modules quarantine /usr/lib/modules/9.0.9+kali-amd64 'no package owns it'
        expiry delete "$a" '40 days old (quarantine_days 30)'
        expiry keep "$b" "100 days old by its stamp; no run has marked it seen yet \
(quarantine_days 30)")" ]
    [[ "$stderr" == *"plan: then sync"*"dry run: nothing was changed"* ]]
    find "$ROOT" | sort | cmp - "$BATS_TEST_TMPDIR/tree.before"
    refute_line_match '^(mkdir|rmdir|rm|sync)( |$)|^mv --no-copy' "$STUB_LOG"
    : > "$STUB_LOG"
    run_ku cleanup --yes --no-modules --porcelain
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    find "$ROOT" | sort | cmp - "$BATS_TEST_TMPDIR/tree.before"
    refute_line_match '^(dpkg-query -S|dkms|mv|mkdir|rmdir|rm)( |$)' "$STUB_LOG"
}

@test "A real run marks a quarantine entry seen, and it stays in that run however old its stamp" {
    local name before="$BATS_TEST_TMPDIR/tree.before"
    name=9.0.4+kali-amd64.$(ago 400)
    quarantined 9.0.4+kali-amd64 "${name##*.}"
    find "$ROOT" | sort > "$before"
    # A dry run writes nothing, not even seen.
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$name" "400 days old by its stamp; no run has marked it \
seen yet (quarantine_days 30)")" ]
    [[ "$stderr" == *"plan: keep quarantine entry $name: 400 days old by its stamp; no run has \
marked it seen yet (quarantine_days 30)"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    find "$ROOT" | sort | cmp - "$before"
    # A real run writes seen as it plans, without a question, and the entry stays.
    run_ku cleanup --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$name" "400 days old by its stamp; this run marks it \
seen (quarantine_days 30)")" ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [ "$(< "$ROOT$Q/$name/seen")" = 20261114T120000Z ]
    [ "$(< "$ROOT$Q/$name/tree/kernel/a.ko")" = module ]
    [ -f "$ROOT$Q/$name/origin" ]
    # Git Bash on Windows keeps no such modes.
    if [[ $OSTYPE == linux* ]]; then
        [ "$(stat -c %a "$ROOT$Q/$name/seen")" = 600 ]
    fi
    # Its age counts from seen now, and once more than 30 whole days passed, it expires.
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$name" '0 days old (quarantine_days 30)')" ]
    export DATE_NOW=$(( DATE_NOW + 31 * 86400 ))
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry delete "$name" '31 days old (quarantine_days 30)')" ]
    refute_line_match '^(rm|rmdir)( |$)' "$STUB_LOG"
    private_output
}

@test "An empty seen, as a crash right after its write leaves, counts as none and is rewritten" {
    local name
    name=9.0.4+kali-amd64.$(ago 400)
    quarantined 9.0.4+kali-amd64 "${name##*.}"
    : > "$ROOT$Q/$name/seen"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$name" "400 days old by its stamp; no run has marked it \
seen yet (quarantine_days 30)")" ]
    [ ! -s "$ROOT$Q/$name/seen" ]
    run_ku cleanup --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$name" "400 days old by its stamp; this run marks it \
seen (quarantine_days 30)")" ]
    [ "$(< "$ROOT$Q/$name/seen")" = 20261114T120000Z ]
    private_output
}

@test "An entry expires once more whole days than quarantine_days passed since its stamp and seen" {
    local a b c name
    a=9.0.4+kali-amd64.$(ago 100) b=9.0.5+kali-amd64.$(ago 31) c=9.0.6+kali-amd64.$(ago 31)
    # a was seen 31 days ago, b was made 31 days ago, after an older seen, and c was seen 30
    # days and 23 hours ago, which makes 30 whole days.
    quarantined 9.0.4+kali-amd64 "${a##*.}" "$(ago 31)"
    quarantined 9.0.5+kali-amd64 "${b##*.}" "$(ago 45)"
    quarantined 9.0.6+kali-amd64 "${c##*.}" "$(ago 30 82800)"
    export SYNC_SAYS=1
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry delete "$a" '31 days old (quarantine_days 30)'
        expiry delete "$b" '31 days old (quarantine_days 30)'
        expiry keep "$c" '30 days old (quarantine_days 30)')" ]
    [[ "$stderr" == *"plan: delete quarantine entry $a: 31 days old (quarantine_days 30)"* ]]
    [[ "$stderr" == *"plan: keep quarantine entry $c: 30 days old (quarantine_days 30)"*"plan: \
then sync"* ]]
    # Each entry's tree goes, then origin, then seen, then the entry; sync runs before the line
    # that says what the run did, which comes last.
    [ "$(grep -E '^(rm|rmdir|sync)( |$)' "$STUB_LOG")" = "$(for name in "$a" "$b"; do
            logged rm -r --one-file-system -- "$ROOT$Q/$name/tree"
            logged rm -- "$ROOT$Q/$name/origin"
            logged rm -- "$ROOT$Q/$name/seen"
            logged rmdir -- "$ROOT$Q/$name"
        done; printf 'sync\n')" ]
    [[ "$stderr" == *"info: deleted the expired quarantine entry $b"$'\nsync ran\n'"kernel-\
updater: info: cleanup: deleted 2 expired quarantine entries" ]]
    [ "$(entries)" = "$c" ]
    private_output
}

@test "Expiry skips the parts an entry lacks, as after a kill before the move, and deletes it" {
    local a b
    a=9.0.4+kali-amd64.$(ago 100) b=9.0.5+kali-amd64.$(ago 100)
    # a lacks its tree, as a kill after origin leaves an entry, and b holds only seen, as a kill
    # right after mkdir leaves one, once a later run saw it.
    quarantined 9.0.4+kali-amd64 "${a##*.}" "$(ago 40)"
    quarantined 9.0.5+kali-amd64 "${b##*.}" "$(ago 40)"
    rm -r "${ROOT:?}$Q/$a/tree" "${ROOT:?}$Q/$b/tree"
    rm "$ROOT$Q/$b/origin"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry delete "$a" '40 days old (quarantine_days 30)'
        expiry delete "$b" '40 days old (quarantine_days 30)')" ]
    [ "$(grep -E '^(rm|rmdir)( |$)' "$STUB_LOG")" = "$(logged rm -- "$ROOT$Q/$a/origin"
        logged rm -- "$ROOT$Q/$a/seen"
        logged rmdir -- "$ROOT$Q/$a"
        logged rm -- "$ROOT$Q/$b/seen"
        logged rmdir -- "$ROOT$Q/$b")" ]
    [[ "$stderr" == *"cleanup: deleted 2 expired quarantine entries"* ]]
    [ -z "$(entries)" ]
}

@test "A younger quarantine entry stays, and quarantine_days 0 keeps every entry" {
    local a b before="$BATS_TEST_TMPDIR/tree.before"
    a=9.0.4+kali-amd64.$(ago 100) b=9.0.5+kali-amd64.$(ago 100)
    quarantined 9.0.4+kali-amd64 "${a##*.}" "$(ago 10)"
    quarantined 9.0.5+kali-amd64 "${b##*.}" "$(ago 90)"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$a" '10 days old (quarantine_days 30)'
        expiry delete "$b" '90 days old (quarantine_days 30)')" ]
    printf 'quarantine_days = 7\n' >> "$ROOT$CONF"
    run_ku cleanup -n --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry delete "$a" '10 days old (quarantine_days 7)'
        expiry delete "$b" '90 days old (quarantine_days 7)')" ]
    configure 5ca1ab1e-0000-4000-8000-000000000b01 5ca1ab1e-0000-4000-8000-000000000c01
    printf 'quarantine_days = 0\n' >> "$ROOT$CONF"
    find "$ROOT" | sort > "$before"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; expiry keep "$a" '10 days old (quarantine_days 0 keeps it)'
        expiry keep "$b" '90 days old (quarantine_days 0 keeps it)')" ]
    [[ "$stderr" == *"plan: keep quarantine entry $b: 90 days old (quarantine_days 0 keeps \
it)"*"cleanup: nothing to do"* ]]
    find "$ROOT" | sort | cmp - "$before"
    refute_line_match '^(rm|rmdir)( |$)' "$STUB_LOG"
}

@test "A clock behind an entry's stamp or seen expires nothing and warns; the plan shows ages" {
    local a b c
    a=9.0.4+kali-amd64.$(ago 100) b=9.0.5+kali-amd64.$(ago -2) c=9.0.6+kali-amd64.$(ago 10)
    quarantined 9.0.4+kali-amd64 "${a##*.}" "$(ago 60)"
    # b was made two days after the time the clock reads, and no run saw it yet.
    quarantined 9.0.5+kali-amd64 "${b##*.}"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept
        expiry skip "$a" '60 days old, but the clock is behind (quarantine_days 30)'
        expiry keep "$b" "2 days ahead of the clock by its stamp; no run marks it seen while \
the clock is behind (quarantine_days 30)")" ]
    [[ "$stderr" == *"warning: the clock is behind: it reads 20261114T120000Z, earlier than a \
quarantine entry was made or seen, so no entry expires in this run"* ]]
    [[ "$stderr" == *"plan: leave quarantine entry $a: 60 days old, but the clock is behind \
(quarantine_days 30)"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [ ! -e "$ROOT$Q/$b/seen" ]
    # A seen after the time the clock reads does the same.
    rm -r "${ROOT:?}$Q/$b"
    quarantined 9.0.6+kali-amd64 "${c##*.}" "$(ago -1)"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept
        expiry skip "$a" '60 days old, but the clock is behind (quarantine_days 30)'
        expiry keep "$c" '1 day ahead of the clock (quarantine_days 30)')" ]
    [[ "$stderr" == *"warning: the clock is behind"* ]]
    [ "$(< "$ROOT$Q/$a/tree/kernel/a.ko")" = module ]
    refute_line_match '^(rm|rmdir)( |$)' "$STUB_LOG"
    private_output
    # Without a time from date, the ages cannot be told, and cleanup refuses.
    export DATE_NOW=never
    run_ku cleanup -n --porcelain
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"date prints no time to tell the age of the quarantine entries by; nothing \
was changed"* ]]
    [ -z "$output" ]
}

@test "Entries of another name, kind, owner or filesystem, or behind a symlink, are only listed" {
    local s seen e name expected
    s=$(ago 100) seen=$(ago 60)
    quarantined 9.0.4+kali-amd64 "$s" "$seen"
    quarantined not-a-release "$s" "$seen"
    mkdir "$ROOT$Q/9.0.5+kali-amd64.2026"
    # 30 November is the last day of the month.
    quarantined 9.0.5+kali-amd64 20261131T120000Z "$seen"
    ln -s "9.0.4+kali-amd64.$s" "$ROOT$Q/9.0.6+kali-amd64.$s"
    printf 'no entry\n' > "$ROOT$Q/9.0.7+kali-amd64.$s"
    for name in 9.0.8 9.0.9 9.0.10 9.0.11 9.0.12 9.0.13; do
        quarantined "$name+kali-amd64" "$s" "$seen"
    done
    foreign owner "$Q/9.0.8+kali-amd64.$s"
    foreign dev "$Q/9.0.9+kali-amd64.$s"
    foreign dev "$Q/9.0.10+kali-amd64.$s/tree"
    printf 'note\n' > "$ROOT$Q/9.0.11+kali-amd64.$s/note"
    printf 'yesterday\n' > "$ROOT$Q/9.0.12+kali-amd64.$s/seen"
    rm "$ROOT$Q/9.0.13+kali-amd64.$s/origin"
    mkdir "$ROOT$Q/9.0.13+kali-amd64.$s/origin"
    e='its name is not RELEASE.YYYYmmddTHHMMSSZ'
    expected=$(kept
        expiry delete "9.0.4+kali-amd64.$s" '60 days old (quarantine_days 30)'
        expiry list "not-a-release.$s" "$e"
        expiry list 9.0.5+kali-amd64.2026 "$e"
        expiry list 9.0.5+kali-amd64.20261131T120000Z "$e"
        expiry list "9.0.6+kali-amd64.$s" 'it is a symlink'
        expiry list "9.0.7+kali-amd64.$s" 'it is no directory'
        expiry list "9.0.8+kali-amd64.$s" 'it belongs to another user than root'
        expiry list "9.0.9+kali-amd64.$s" 'it lies on another filesystem than the quarantine'
        expiry list "9.0.10+kali-amd64.$s" \
            'its tree lies on another filesystem than the quarantine'
        expiry list "9.0.11+kali-amd64.$s" 'it holds more than tree, origin and seen'
        expiry list "9.0.12+kali-amd64.$s" 'its seen holds no time as YYYYmmddTHHMMSSZ'
        expiry list "9.0.13+kali-amd64.$s" 'its origin is no regular file')
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$(sort <<< "$output")" = "$(sort <<< "$expected")" ]
    [[ "$stderr" == *"plan: leave quarantine entry 9.0.6+kali-amd64.$s: it is a symlink"* ]]
    [[ "$stderr" == *"cleanup: deleted 1 expired quarantine entry"* ]]
    # Only the entry expiry may judge went.
    [ "$(grep -E '^(rm|rmdir)( |$)' "$STUB_LOG")" = "$(
        logged rm -r --one-file-system -- "$ROOT$Q/9.0.4+kali-amd64.$s/tree"
        logged rm -- "$ROOT$Q/9.0.4+kali-amd64.$s/origin"
        logged rm -- "$ROOT$Q/9.0.4+kali-amd64.$s/seen"
        logged rmdir -- "$ROOT$Q/9.0.4+kali-amd64.$s")" ]
    [ "$(entries | wc -l)" -eq 11 ]
    # Nothing in a quarantine that a symlink leads to is judged, and no seen is written there.
    rm "$ROOT$Q/9.0.12+kali-amd64.$s/seen"
    mv "$ROOT/var/lib/kernel-updater" "$ROOT/var/lib/elsewhere"
    ln -s elsewhere "$ROOT/var/lib/kernel-updater"
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' expire skip "$Q" \
        "a symlink leads to the quarantine $Q")" ]
    [[ "$stderr" == *"plan: expire nothing: a symlink leads to the quarantine $Q"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [ ! -e "$ROOT/var/lib/elsewhere/quarantine/9.0.12+kali-amd64.$s/seen" ]
    private_output
}

@test "Nothing expires in a dry run or before the answer, and a dry run writes no seen" {
    local a b before="$BATS_TEST_TMPDIR/tree.before"
    a=9.0.4+kali-amd64.$(ago 100) b=9.0.5+kali-amd64.$(ago 100)
    quarantined 9.0.4+kali-amd64 "${a##*.}" "$(ago 40)"
    quarantined 9.0.5+kali-amd64 "${b##*.}"
    find "$ROOT" | sort > "$before"
    run_ku cleanup -n
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"plan: delete quarantine entry $a: 40 days old (quarantine_days 30)"*"plan: \
then sync"*"dry run: nothing was changed"* ]]
    find "$ROOT" | sort | cmp - "$before"
    # Without a terminal to ask on, or with a no, nothing expires either; a run that may change
    # things writes seen as it plans, as its own bookkeeping.
    run_ku cleanup
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"no terminal to confirm on"* ]]
    [ "$(< "$ROOT$Q/$b/seen")" = 20261114T120000Z ]
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku cleanup
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"declined; nothing was changed"* ]]
    [ "$(< "$ROOT$Q/$a/tree/kernel/a.ko")" = module ]
    [ -f "$ROOT$Q/$a/origin" ]
    [ -f "$ROOT$Q/$a/seen" ]
    refute_line_match '^(rm|rmdir|sync)( |$)' "$STUB_LOG"
}

@test "A quarantine entry that changed or went once the question was answered is left alone" {
    local a b c d
    a=9.0.4+kali-amd64.$(ago 100) b=9.0.5+kali-amd64.$(ago 100) c=9.0.6+kali-amd64.$(ago 100)
    d=9.0.7+kali-amd64.$(ago 100)
    quarantined 9.0.4+kali-amd64 "${a##*.}" "$(ago 40)"
    quarantined 9.0.5+kali-amd64 "${b##*.}" "$(ago 40)"
    # While apt simulates its autoremove again, a gets a newer seen and b goes.
    on_recheck "printf '%s\n' '$(ago 1)' > '$ROOT$Q/$a/seen'
        \"\$REAL_RM\" -r '$ROOT$Q/$b'" autoremove
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: left the quarantine entry $a: it changed while cleanup ran"* ]]
    [[ "$stderr" == *"warning: the quarantine entry $b went while cleanup ran, so there is \
nothing left to do for it"* ]]
    [[ "$stderr" == *"cleanup: left 1 quarantine entry a re-check kept"* ]]
    [ "$(< "$ROOT$Q/$a/tree/kernel/a.ko")" = module ]
    refute_line_match '^(rm|rmdir)( |$)' "$STUB_LOG"
    # A run whose only change went meanwhile says that nothing was left to change.
    quarantined 9.0.6+kali-amd64 "${c##*.}" "$(ago 40)"
    on_recheck "\"\$REAL_RM\" -r '$ROOT$Q/$c'" autoremove
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: the quarantine entry $c went while cleanup ran"* ]]
    [[ "$stderr" == *"cleanup: nothing was left to change" ]]
    # Every planned entry stays when the quarantine changed, as when a symlink took its place.
    quarantined 9.0.7+kali-amd64 "${d##*.}" "$(ago 40)"
    on_recheck "mv '$ROOT/var/lib/kernel-updater' '$ROOT/var/lib/elsewhere'
        ln -s elsewhere '$ROOT/var/lib/kernel-updater'" autoremove
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: left the quarantine entry $d: the quarantine changed while \
cleanup ran"* ]]
    [[ "$stderr" == *"cleanup: left 1 quarantine entry a re-check kept" ]]
    [ "$(< "$ROOT/var/lib/elsewhere/quarantine/$d/tree/kernel/a.ko")" = module ]
    refute_line_match '^(rm|rmdir)( |$)' "$STUB_LOG"
    private_output
}

@test "--porcelain prints only the plan's records, once the run ends with 0, and none on an error" {
    local a line re
    a=9.0.7+kali-amd64.$(ago 100)
    re=$'^(protect|rc|autoremove|modules|expire)\t(keep|purge|list|skip|rmdir|quarantine|delete)'
    re+=$'\t[^\t]+\t[^\t]+$'
    listed "linux-image-$V0" rc
    module_tree /usr/lib/modules 9.0.8+kali-amd64
    quarantined 9.0.7+kali-amd64 "${a##*.}" "$(ago 40)"
    on_purge ''
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 0 ]
    [ "$output" = "$(kept; printf '%s\t%s\t%s\t%s\n' rc purge "linux-image-$V0" "$V0" \
        modules rmdir /usr/lib/modules/9.0.8+kali-amd64 'empty, and no package owns it'
        expiry delete "$a" '40 days old (quarantine_days 30)')" ]
    while IFS= read -r line; do
        [[ $line =~ $re ]] || { printf 'no record: %s\n' "$line" >&2; return 1; }
    done <<< "$output"
    [[ "$stderr" == *"cleanup: purged 1 package, removed 1 empty module tree and deleted 1 \
expired quarantine entry"* ]]
    # These end otherwise once the plan is on stderr, and leave stdout empty: a no, a change
    # while the question waited, and a part of an entry that cannot be deleted after the purge
    # and the removal of a tree.
    module_tree /usr/lib/modules 9.0.8+kali-amd64
    quarantined 9.0.7+kali-amd64 "${a##*.}" "$(ago 40)"
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku cleanup --porcelain
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"plan: then sync"* ]]
    [ -z "$output" ]
    # shellcheck disable=SC2016 # the stub expands the variable
    on_recheck 'printf "Package: x\n" >> "$KU_ROOT/var/lib/dpkg/status"'
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 75 ]
    [ -z "$output" ]
    export RM_FAIL=/origin
    run_ku cleanup --yes --porcelain
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"rm cannot delete $Q/$a/origin; the purge ran and 1 module tree was removed \
or moved, and what is left of the quarantine entry $a and the entries after it stay: run cleanup \
again"* ]]
    [ -z "$output" ]
    [ ! -e "$ROOT/usr/lib/modules/9.0.8+kali-amd64" ]
    [ ! -e "$ROOT$Q/$a/tree" ]
    [ -f "$ROOT$Q/$a/origin" ]
    [ "$(apt_calls | tail -n 1)" = sync ]
    private_output
}

@test "sync runs before the last line, which says what was done, and a failed sync only warns" {
    local last
    listed "linux-image-$V0" rc
    on_purge ''
    export SYNC_SAYS=1
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *$'\nsync ran\nkernel-updater: info: cleanup: purged 1 package' ]]
    export SYNC_STATUS=1
    last=$'sync ran\nkernel-updater: warning: sync failed: run it before the stick is unplugged'
    last+=$'\nkernel-updater: info: cleanup: purged 1 package'
    run_ku cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *$'\n'"$last" ]]
}
