#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of cleanup
#
# Runs kernel-updater cleanup on the container itself with the real apt-get, dpkg and
# linux-update-symlinks, and dummy kernels whose maintainer scripts move the links as real ones
# do: a kernel removed with its config files left is purged, and the other kernels, the links and
# check stay as they were; a pending reboot purges nothing; and a real fcntl lock on dpkg's
# frontend lock, as apt takes it, shows in /proc/locks on the container's overlay filesystem.
# Stubs stand in only for what a container cannot answer: /boot's LUKS mapping, uname,
# lsinitramfs and dumpe2fs.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load container

setup_file() {
    container_setup_file
}

# Three dummy kernels installed with link_in_boot = yes, the newest running, so that the links
# point at V3 and V2, and the oldest, V1, removed with its config files left; a configuration
# that names /boot and its container; and stubs that show /boot as that unlocked container.
setup() {
    container_only
    reset_system yes
    install_kernels "$V1" "$V2" "$V3"
    dpkg -r "linux-image-$V1"
    stub_init
    stub_system_tools
    export UNAME_R=$V3 LSINITRAMFS_DROP='^cryptroot/keyfiles'
    printf '%s\n' "boot_fs_uuid = $BOOT_FS_UUID" \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' > /etc/kernel-updater.conf
    export BOOT_MOUNT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*) printf '%s\n' "$BOOT_MOUNT" ;;
    *) exit 1 ;;
esac
EOF
}

# Stop the process a test left holding dpkg's frontend lock.
teardown() {
    if [[ -n ${LOCK_PID:-} ]]; then
        kill "$LOCK_PID" 2> /dev/null || true
        wait "$LOCK_PID" 2> /dev/null || true
    fi
}

# Print NAME STATE for each dummy kernel package dpkg knows in a state other than
# not-installed.
dummies() {
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
    dpkg-query -W -f '${binary:Package} ${db:Status-Abbrev}\n' 'linux-image-9.*' \
        2> /dev/null | awk '$2 !~ /^.n$/ { print $1, $2 }'
}

@test "The kernel removed with its config files left is purged, and the rest stays as it was" {
    [ "$(package_state "linux-image-$V1")" = rc ]
    assert_links "$V3" "$V2"
    run_container_check
    expect_item kernels warn "1 removed with config files left; 2 installed"
    grep -v '^kernels' <<< "$output" > "$BATS_TEST_TMPDIR/check.before"
    run_container_cleanup --yes --porcelain
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *$'rc\tpurge\tlinux-image-'"$V1"$'\t'"$V1"* ]]
    [[ "$stderr" == *"cleanup: purged 1 package"* ]]
    # dpkg lists the names as text, which puts 9.0.10 (V3) before 9.0.2 (V2).
    [ "$(dummies)" = "$(printf 'linux-image-%s ii\n' "$V3" "$V2")" ]
    assert_links "$V3" "$V2"
    run_container_check
    expect_item kernels ok "2 installed, running $V3"
    grep -v '^kernels' <<< "$output" | cmp - "$BATS_TEST_TMPDIR/check.before"
    # A second run finds nothing left to purge.
    run_container_cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* ]]
}

@test "While a reboot into the kernel vmlinuz points at is pending, nothing is purged" {
    export UNAME_R=$V2
    run_container_cleanup --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"/boot/vmlinuz points at $V3, but $V2 is running; reboot first"* ]]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [ "$(package_state "linux-image-$V1")" = rc ]
    assert_links "$V3" "$V2"
}

@test "A real fcntl lock on dpkg's frontend lock, as apt takes it, exits 75 and names its holder" {
    local ready="$BATS_TEST_TMPDIR/locked" i
    # perl takes a write lock on the whole file with F_SETLK, as apt does: struct flock on
    # x86-64 is l_type and l_whence, padding, l_start, l_len and l_pid, padded to 32 bytes.
    # shellcheck disable=SC2016 # perl expands its own variables
    perl -MFcntl=F_SETLK,F_WRLCK,SEEK_SET -e '
        open(my $fh, ">>", $ARGV[0]) or die "open: $!\n";
        fcntl($fh, F_SETLK, pack("s s x!8 q q i x!8", F_WRLCK, SEEK_SET, 0, 0, 0))
            or die "fcntl: $!\n";
        open(my $ready, ">", $ARGV[1]) or die "ready: $!\n";
        close($ready);
        sleep 120;' /var/lib/dpkg/lock-frontend "$ready" > "$BATS_TEST_TMPDIR/perl.log" 2>&1 3>&- &
    LOCK_PID=$!
    for (( i = 0; i < 100; i++ )); do
        [[ ! -e $ready ]] || break
        sleep 0.1
    done
    [ -e "$ready" ] || { cat "$BATS_TEST_TMPDIR/perl.log" >&2; return 1; }
    run_container_cleanup --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"apt or dpkg is running: PID $LOCK_PID (perl) holds \
/var/lib/dpkg/lock-frontend; run cleanup again once it is done; nothing was changed"* ]]
    [ "$(package_state "linux-image-$V1")" = rc ]
}
