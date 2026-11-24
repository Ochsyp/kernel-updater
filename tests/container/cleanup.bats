#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater container checks of cleanup
#
# Runs kernel-updater cleanup on the container itself with the real apt-get, dpkg and
# linux-update-symlinks, and dummy kernels whose maintainer scripts move the links as real ones
# do: a kernel removed with its config files left is purged, and the other kernels, the links and
# check stay as they were; a pending reboot purges nothing; once the dummies are marked auto, the
# old kernel apt's autoremove names is purged in the same run, the kernel vmlinuz.old points at
# stays when apt keeps another one, and a purge that would take along a package that depends on
# an old kernel's headers refuses; the empty module tree a kernel install that the /boot guard
# refused leaves is removed with rmdir, and a tree dkms lists modules for is kept until it lists
# none, then moved into the quarantine; a back-dated quarantine entry that a run saw long ago
# expires, while a fresh one and a back-dated one no run saw stay; and a real fcntl lock on
# dpkg's frontend lock, as apt takes it, shows in /proc/locks on the container's overlay
# filesystem. Stubs stand in only for what a container cannot answer: /boot's LUKS mapping,
# uname, lsinitramfs, dumpe2fs and dkms.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load ../helpers
load container

# A dummy kernel with a real kernel's maintainer scripts, whose preinst makes its module tree,
# the release of a module tree dkms built for, and a preinst hook that runs the checkout's
# /boot guard, as the one install.sh installs runs the installed tool.
HOOKED=9.0.20+kali-amd64 DKMS_REL=9.0.21+kali-amd64 GUARD=/etc/kernel/preinst.d/00-ku-test-guard

# Build the dummy kernels, the hooked one included, and the headers of V2 with a dummy that
# depends on them, as a package of DKMS modules built for one kernel does.
setup_file() {
    container_setup_file
    in_test_container || return 0
    build_hooked_kernel "$HOOKED"
    build_package "linux-headers-$V2" "Version: ${V2%%+*}-1"
    build_package ku-test-dkms "Version: 1.0-1" "Depends: linux-headers-$V2"
}

# Three dummy kernels installed with link_in_boot = yes and marked manual, as dpkg -i leaves
# them, the newest running, so that the links point at V3 and V2, and the oldest, V1, removed
# with its config files left; a configuration that names /boot and its container; stubs that
# show /boot as that unlocked container; and a stand-in partition 1 with a finished migration's
# menu, which run_container_cleanup's KU_TEST=1 lets through.
setup() {
    container_only
    reset_system yes
    install_kernels "$V1" "$V2" "$V3"
    manual_marks
    dpkg -r "linux-image-$V1"
    stub_init
    stub_system_tools
    export KU_P1_DIR="$BATS_TEST_TMPDIR/p1"
    write_finished_menu "$KU_P1_DIR"
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

# Stop the process a test left holding dpkg's frontend lock, remove the /boot guard a test
# left, and mark the dummies manual again.
teardown() {
    in_test_container || return 0
    if [[ -n ${LOCK_PID:-} ]]; then
        kill "$LOCK_PID" 2> /dev/null || true
        wait "$LOCK_PID" 2> /dev/null || true
    fi
    rm -f "$GUARD"
    manual_marks
}

# Mark every dummy package that is installed manual, as dpkg -i leaves it, so that no auto mark
# a test sets outlives the test: apt keeps an auto mark after dpkg purged the package, and an
# apt run in a later file must find no dummy it could remove.
manual_marks() {
    local -a packages=()
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
    mapfile -t packages < <(dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}\n' \
        'linux-image-9.*' 'linux-headers-9.*' ku-test-dkms 2> /dev/null |
        awk '$1 ~ /^.i/ { print $2 }')
    if (( ${#packages[@]} )); then
        apt-mark manual "${packages[@]}" > /dev/null
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

@test "The old kernel apt's autoremove names once marked auto is purged with the rc one" {
    install_kernels "$V4"
    export UNAME_R=$V4
    assert_links "$V4" "$V3"
    # Marked auto, the dummies are apt's to prune: it keeps the two newest, V4 and V3.
    apt-mark auto "linux-image-$V2" "linux-image-$V3" "linux-image-$V4"
    run_container_cleanup --yes --porcelain
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *$'rc\tpurge\tlinux-image-'"$V1"$'\t'"$V1"* ]]
    [[ "$output" == *$'autoremove\tpurge\tlinux-image-'"$V2"$'\t'"$V2"* ]]
    [[ "$stderr" == *"cleanup: purged 2 packages"* ]]
    [ "$(dummies)" = "$(printf 'linux-image-%s ii\n' "$V3" "$V4")" ]
    assert_links "$V4" "$V3"
    run_container_check
    expect_item kernels ok "2 installed, running $V4"
    expect_item boot-links ok "the 4 links are relative and reach non-empty files in /boot"
    # A second run finds nothing left to purge.
    run_container_cleanup --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cleanup: nothing to do"* ]]
    [[ "${output,,}${stderr,,}" != *5ca1ab1e* ]]
}

@test "The kernel vmlinuz.old points at stays when apt's autoremove keeps another one" {
    install_kernels "$V4"
    # The links go to V4 and V2, which is older than V3, the second kernel apt keeps.
    linux-update-symlinks install "$V2" "/boot/vmlinuz-$V2"
    linux-update-symlinks install "$V4" "/boot/vmlinuz-$V4"
    assert_links "$V4" "$V2"
    export UNAME_R=$V4
    apt-mark auto "linux-image-$V2" "linux-image-$V3" "linux-image-$V4"
    run_container_cleanup --yes --porcelain
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *$'protect\tkeep\t'"$V2"$'\tvmlinuz.old'* ]]
    [[ "$output" == *$'autoremove\tskip\tlinux-image-'"$V2"$'\tits kernel is kept'* ]]
    [[ "$output" != *$'autoremove\tpurge'* ]]
    [[ "$stderr" == *"cleanup: purged 1 package"* ]]
    # dpkg lists the names as text: 9.0.10 (V3), 9.0.11 (V4), then 9.0.2 (V2).
    [ "$(dummies)" = "$(printf 'linux-image-%s ii\n' "$V3" "$V4" "$V2")" ]
    assert_links "$V4" "$V2"
}

@test "A purge that would take along a package depending on an old kernel's headers refuses" {
    install_kernels "$V4"
    dpkg -i "$(package_deb "linux-headers-$V2")" "$(package_deb ku-test-dkms)"
    export UNAME_R=$V4
    # All of V2's packages and the one that depends on its headers are garbage to apt now.
    apt-mark auto "linux-image-$V2" "linux-headers-$V2" ku-test-dkms "linux-image-$V3" \
        "linux-image-$V4"
    run_container_cleanup --yes --porcelain
    [ "$status" -eq 3 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$stderr" == *"the purge cannot run as planned: apt would also remove ku-test-dkms;"* ]]
    [[ "$stderr" == *"; nothing was changed"* ]]
    [ -z "$output" ]
    [ "$(package_state "linux-image-$V1")" = rc ]
    [ "$(package_state "linux-image-$V2")" = ii ]
    [ "$(package_state "linux-headers-$V2")" = ii ]
    [ "$(package_state ku-test-dkms)" = ii ]
}

@test "The empty module tree of a kernel install the /boot guard refused is removed with rmdir" {
    local modules=/usr/lib/modules tab=$'\t'
    # With a merged /usr, the preinst's /lib/modules is /usr/lib/modules.
    [[ /lib -ef /usr/lib ]] || modules=/lib/modules
    mkdir -p "${GUARD%/*}"
    printf '#!/bin/sh\nexec < /dev/null >&2\nexec bash %s hook boot-guard preinst "$@"\n' \
        "'$REPO_DIR/bin/kernel-updater'" > "$GUARD"
    chmod 0755 "$GUARD"
    # The kernel's preinst makes its module tree, then the guard refuses while /boot is not
    # mounted, and the postrm that undoes the install leaves the tree empty.
    run env PATH="$STUB_BIN:$PATH" BOOT_MOUNT= dpkg -i "$(kernel_deb "$HOOKED")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to install kernel $HOOKED"* ]]
    [[ "$(package_state "linux-image-$HOOKED")" != ?i* ]]
    [ -d "$modules/$HOOKED" ]
    [ -z "$(ls -A "$modules/$HOOKED")" ]
    rm "$GUARD"
    run_container_cleanup --yes --porcelain --no-rc --no-autoremove
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *"modules${tab}rmdir${tab}$modules/$HOOKED${tab}empty, and no package owns \
it"* ]]
    [[ "$stderr" == *"cleanup: removed 1 empty module tree"* ]]
    [ ! -e "$modules/$HOOKED" ]
    [ "$(package_state "linux-image-$V1")" = rc ]
    [ -z "$(find /var/lib/kernel-updater/quarantine -mindepth 1 2> /dev/null)" ]
}

@test "A module tree dkms lists modules for stays, and moves into the quarantine once it does not" {
    local tree=/usr/lib/modules/$DKMS_REL base=/var/lib/kernel-updater/quarantine tab=$'\t'
    local entry
    mkdir -p "$tree/updates/dkms"
    printf 'module\n' > "$tree/updates/dkms/ku-test.ko"
    export DKMS_LIST="$BATS_TEST_TMPDIR/dkms.list"
    printf 'ku-test/1.0, %s, x86_64: installed\n' "$DKMS_REL" > "$DKMS_LIST"
    mkstub dkms <<'EOF'
[[ $# == 3 && $1 == status && $2 == -k ]] || exit 100
grep -F ", $3, " "$DKMS_LIST" || true
EOF
    run_container_cleanup -n --porcelain
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *"modules${tab}keep${tab}$tree${tab}dkms lists modules for it ('dkms remove \
ku-test/1.0 -k $DKMS_REL')"* ]]
    : > "$DKMS_LIST"
    run_container_cleanup --yes --porcelain
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *"rc${tab}purge${tab}linux-image-$V1${tab}$V1"* ]]
    [[ "$output" == *"modules${tab}quarantine${tab}$tree${tab}no package owns it"* ]]
    [[ "$stderr" == *"cleanup: purged 1 package and moved 1 module tree into the quarantine"* ]]
    [ ! -e "$tree" ]
    entry=$(ls "$base")
    [[ $entry =~ ^9\.0\.21\+kali-amd64\.[0-9]{8}T[0-9]{6}Z$ ]]
    [ "$(< "$base/$entry/tree/updates/dkms/ku-test.ko")" = module ]
    grep -F -q -x -e "path: $tree" "$base/$entry/origin"
    # The run that made the entry writes no seen, and only root can reach the tree.
    [ ! -e "$base/$entry/seen" ]
    [ "$(stat -c '%u %a' "$base" "$base/$entry" "$base/$entry/origin")" = \
        "$(printf '0 %s\n' 700 700 600)" ]
    [ "$(dummies)" = "$(printf 'linux-image-%s ii\n' "$V3" "$V2")" ]
    assert_links "$V3" "$V2"
}

@test "A back-dated quarantine entry a run saw expires, and a fresh or unseen one stays" {
    local base=/var/lib/kernel-updater/quarantine tab=$'\t' now old fresh unseen entry
    now=$(date -u +%Y%m%dT%H%M%SZ)
    old=9.0.30+kali-amd64.20200101T000000Z fresh=9.0.31+kali-amd64.$now
    unseen=9.0.32+kali-amd64.20200101T000000Z
    mkdir -p "$base"
    chmod 0700 "$base"
    for entry in "$old" "$fresh" "$unseen"; do
        mkdir -p "$base/$entry/tree/kernel"
        printf 'module\n' > "$base/$entry/tree/kernel/a.ko"
        printf 'path: /usr/lib/modules/%s\n' "${entry%.*}" > "$base/$entry/origin"
    done
    # The old entry was made and seen long ago, the fresh one now, and no run saw the third.
    printf '20200102T000000Z\n' > "$base/$old/seen"
    printf '%s\n' "$now" > "$base/$fresh/seen"
    run_container_cleanup --yes --porcelain --no-rc --no-autoremove
    [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
    [[ "$output" == *"expire${tab}delete${tab}$base/$old${tab}"*" days old (quarantine_days 30)"* ]]
    [[ "$output" == *"expire${tab}keep${tab}$base/$fresh${tab}0 days old (quarantine_days 30)"* ]]
    [[ "$output" == *"expire${tab}keep${tab}$base/$unseen${tab}"*" days old by its stamp; this run \
marks it seen (quarantine_days 30)"* ]]
    [[ "$stderr" == *"cleanup: deleted 1 expired quarantine entry"* ]]
    [ ! -e "$base/$old" ]
    [ "$(< "$base/$fresh/tree/kernel/a.ko")" = module ]
    [ "$(< "$base/$unseen/tree/kernel/a.ko")" = module ]
    [[ "$(< "$base/$unseen/seen")" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
    [ "$(stat -c '%u %a' "$base/$unseen/seen")" = '0 600' ]
    [ "$(package_state "linux-image-$V1")" = rc ]
}

@test "A real fcntl lock on dpkg's frontend lock, as apt takes it, exits 75 and names its holder" {
    local ready="$BATS_TEST_TMPDIR/locked" i
    # perl takes a write lock on the whole file with F_SETLK, as apt does: struct flock on
    # x86-64 is l_type and l_whence, padding, l_start, l_len and l_pid, padded to 32 bytes. It
    # sits in a variable because perl's fcntl needs a third argument it can write to.
    # shellcheck disable=SC2016 # perl expands its own variables
    perl -MFcntl=F_SETLK,F_WRLCK,SEEK_SET -e '
        open(my $fh, ">>", $ARGV[0]) or die "open: $!\n";
        my $lock = pack("s s x!8 q q i x!8", F_WRLCK, SEEK_SET, 0, 0, 0);
        fcntl($fh, F_SETLK, $lock) or die "fcntl: $!\n";
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
