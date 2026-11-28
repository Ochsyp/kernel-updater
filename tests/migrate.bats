#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater migrate command checks
#
# Runs kernel-updater migrate on a KU_ROOT tree before the migration, with stub tools: detect
# filling the configuration, idempotent and refusing values that differ; system with its
# preconditions, the order of its linux-update-symlinks calls, the edit of kernel-img.conf and
# a write of it that fails, the links left in /, grub-pc's question of its own, a result that
# fails its check, links kept on another kernel that boots, and a kernel install while it runs;
# menu and finalize on a partition-1 tree that KU_P1_DIR names, written and exported, with
# their refusals and a grub.cfg that changes while menu asks, the parameters a plan hides, the
# initrds live needs, kali.cfg written anew, the export a write makes stale and the baseline,
# whose entries a write keeps for files changed outside the tool; --rollback of each stage,
# byte for byte, written and exported, with its refusals and the changes to grub.cfg it drops;
# backups named in the order of the runs, removed while unfinished and passed over without a
# MANIFEST; and root, the lock, declining and usage errors. No value is printed.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

V1=9.0.1+kali-amd64
V2=9.0.2+kali-amd64
V3=9.0.10+kali-amd64
FIXTURES="$TESTS_DIR/fixtures/grub"
CONF=/etc/kernel-updater.conf
BACKUPS=/var/backups/kernel-updater

# A Kali system before the migration: kernels V1 and V2, V2 running, linux-base keeping the links
# in /, which point into boot/, an unconfigured kernel-updater, the hooks installed, and
# partition 1 in P1 with MultiBootUSB's grub.cfg, CRLF, and GRUB 2.06.
setup() {
    stub_init
    use_symlinks || skip "this platform cannot make symlinks"
    ROOT="$BATS_TEST_TMPDIR/root"
    export KU_P1_DIR="$BATS_TEST_TMPDIR/p1"
    GRUB="$KU_P1_DIR/multibootusb/grub"
    mkdir -p "$ROOT/boot" "$ROOT/etc/kernel/preinst.d" "$ROOT/run" "$ROOT/proc" "$GRUB/i386-pc"
    : > "$ROOT/etc/kernel/preinst.d/00-kernel-updater"
    # No process holds a POSIX lock, so apt and dpkg are not running.
    : > "$ROOT/proc/locks"
    printf 'BOOT_IMAGE=/vmlinuz root=/dev/mapper/kali--vg-root ro quiet splash\n' \
        > "$ROOT/proc/cmdline"
    kernels "$V1" "$V2"
    printf '# Kernel image management overrides\ndo_symlinks = yes\nLink_In_Boot = no # old\n' \
        > "$ROOT/etc/kernel-img.conf"
    printf 'image_dest = /\n' >> "$ROOT/etc/kernel-img.conf"
    cp "$ROOT/etc/kernel-img.conf" "$BATS_TEST_TMPDIR/kernel-img.before"
    ln -s "boot/vmlinuz-$V2" "$ROOT/vmlinuz"
    ln -s "boot/vmlinuz-$V1" "$ROOT/vmlinuz.old"
    ln -s "boot/initrd.img-$V2" "$ROOT/initrd.img"
    ln -s "boot/initrd.img-$V1" "$ROOT/initrd.img.old"
    sed 's/$/\r/' "$FIXTURES/migrate-before.cfg" > "$GRUB/grub.cfg"
    cp "$GRUB/grub.cfg" "$BATS_TEST_TMPDIR/grub.before"
    sed 's/$/\r/' "$FIXTURES/migrate-after.cfg" > "$BATS_TEST_TMPDIR/grub.after"
    printf 'ELF\0GNU GRUB  version %%s\0%s\0normal\0' 2.06 > "$GRUB/i386-pc/normal.mod"
    stub_system_tools
    stubs
}

# Write the stubs that answer for the system: root, the lock, stat and chown, /boot's mount,
# the stick as sdb, dpkg, debconf, linux-base, no VM, grub-script-check and the UTC stamps.
stubs() {
    mkstub id <<'EOF'
printf '%s\n' "${ID_U:-0}"
EOF
    mkstub flock
    mkstub chown
    # Root owns every directory, with mode 0755, and output_dir with 0700; a file has mode 0600.
    mkstub stat <<'EOF'
case " $* " in
    *" %u %a "*) [[ ${*: -1} == */out ]] && echo "0 700" || echo "0 755" ;;
    *) echo 600 ;;
esac
EOF
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    mkstub findmnt <<'EOF'
case " $* " in
    *" --mountpoint "*)
        [[ -n $FINDMNT_OUT ]] || exit 1
        printf '%s\n' "$FINDMNT_OUT"
        ;;
    *" --target "*) printf 'rw,nosuid,nodev,noexec\n' ;;
    *) exit 1 ;;
esac
EOF
    export P1_TYPE=ntfs P1_SERIAL=5CA1AB1E00000001
    mkstub lsblk <<'EOF'
case " $* " in
    *" -s "*) printf '%s\n' '/dev/mapper/boot_crypt crypt' '/dev/sdb3 part' '/dev/sdb disk' ;;
    *" -d "*) printf '5ca1ab1e\n' ;;
    *) printf '%s\n' '/dev/sdb   ' "/dev/sdb1 1 $P1_TYPE $P1_SERIAL" ;;
esac
EOF
    mkstub blkid <<< 'exit 2'
    mkstub dpkg-query <<'EOF'
cat "$DPKG_QUERY_OUT"
EOF
    mkstub linux-version <<'EOF'
[[ $1 == sort ]] && exec sort -V
EOF
    # debconf holds one install device until debconf-set-selections empties the answer. As
    # debconf-show runs before the system stage asks, SHOW_MOVES points /vmlinuz at that kernel,
    # as a kernel install while the question waits does.
    export DEBCONF_STATE="$BATS_TEST_TMPDIR/debconf" DEBCONF_IN="$BATS_TEST_TMPDIR/debconf.in"
    printf '* grub-pc/install_devices: /dev/sdb\n' > "$DEBCONF_STATE"
    # SHOW_LOCKS, in the same way, is a /proc/locks line that apt takes while the question waits.
    mkstub debconf-show <<'EOF'
[[ -z ${SHOW_MOVES:-} ]] || ln -sfn "boot/vmlinuz-$SHOW_MOVES" "$KU_ROOT/vmlinuz"
[[ -z ${SHOW_LOCKS:-} ]] || printf '%s\n' "$SHOW_LOCKS" > "$KU_ROOT/proc/locks"
cat "$DEBCONF_STATE"
EOF
    mkstub debconf-set-selections <<'EOF'
cat > "$DEBCONF_IN"
printf '* grub-pc/install_devices:\n' > "$DEBCONF_STATE"
EOF
    # As linux-base 4.17 installs a kernel: the images in /boot, oldest first, but the one
    # installed; the kernels vmlinuz.old and then vmlinuz point at move to the end; the one
    # installed goes last. vmlinuz and initrd.img take the last, the .old links the one before
    # it, or the last again when it is alone, and an initrd link goes when its kernel has no
    # initrd. LUS_ABSOLUTE makes absolute links, and LUS_OLD names the kernel the .old links
    # take instead, as a linux-base that picked another would. LUS_ROOT points /initrd.img at
    # that kernel's initrd, as a kernel install while the stage runs does.
    mkstub linux-update-symlinks <<'EOF'
[[ $1 == install ]] || exit 0
[[ -z ${LUS_ROOT:-} ]] || ln -sfn "boot/initrd.img-$LUS_ROOT" "$KU_ROOT/initrd.img"
boot=$KU_ROOT/boot
list=()
for file in "$boot"/vmlinu[xz]-*; do
    version=${file##*/vmlinu?-}
    if [[ -e $file && $file != *.sig && $version != "$2" ]]; then
        list+=("$version")
    fi
done
(( ! ${#list[@]} )) || mapfile -t list < <(printf '%s\n' "${list[@]}" | sort -V)
for link in vmlinuz.old vmlinuz; do
    target=$(readlink "$boot/$link" 2> /dev/null) || continue
    target=${target##*/}
    target=${target#vmlinuz-}
    for i in "${!list[@]}"; do
        if [[ ${list[i]} == "$target" ]]; then
            list=("${list[@]:0:i}" "${list[@]:i+1}" "$target")
            break
        fi
    done
done
list+=("$2")
new=${list[-1]} old=${list[-1]}
(( ${#list[@]} < 2 )) || old=${list[-2]}
old=${LUS_OLD:-$old}
for kind in vmlinuz initrd.img; do
    for link in "$kind" "$kind.old"; do
        version=$new
        [[ $link == "$kind" ]] || version=$old
        want=$kind-$version
        [[ -z ${LUS_ABSOLUTE:-} ]] || want=/boot/$want
        if [[ -e $boot/$kind-$version ]]; then
            ln -sfn "$want" "$boot/$link"
        else
            rm -f "$boot/$link"
        fi
    done
done
EOF
    mkstub systemd-detect-virt <<< 'exit 1'
    # GSC_FAIL names a file grub-script-check rejects.
    mkstub grub-script-check <<'EOF'
[[ -z ${GSC_FAIL:-} || ${*: -1} != *"$GSC_FAIL" ]]
EOF
    # Each call gets the next second, or DATE_FIXED; date arithmetic (-d) goes to the real date.
    export DATE_COUNT="$BATS_TEST_TMPDIR/date.count" REAL_DATE
    REAL_DATE=$(type -P date)
    printf '0\n' > "$DATE_COUNT"
    mkstub date <<'EOF'
[[ " $* " != *" -d "* ]] || exec "$REAL_DATE" "$@"
if [[ -n ${DATE_FIXED:-} ]]; then
    printf '%s\n' "$DATE_FIXED"
    exit 0
fi
n=$(( $(< "$DATE_COUNT") + 1 ))
printf '%s\n' "$n" > "$DATE_COUNT"
printf '20261112T0900%02dZ\n' "$n"
EOF
}

# Put in /boot the kernel the legacy Kali entries of the fixture boot, as while it is still
# installed.
legacy_kernel() {
    printf 'kernel 7.2.9\n' > "$ROOT/boot/vmlinuz-7.2.9+kali-amd64"
    printf 'initrd 7.2.9\n' > "$ROOT/boot/initrd.img-7.2.9+kali-amd64"
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

# Write the configuration detect would, with any further LINES.
detected() {
    printf '%s\n' 'boot_fs_uuid = 5ca1ab1e-0000-4000-8000-000000000b01' \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' 'disk_ptuuid = 5ca1ab1e' \
        'p1_fs_uuid = 5CA1AB1E00000001' 'root_device = /dev/mapper/kali--vg-root' "$@" \
        > "$ROOT$CONF"
}

# Put the system where the system stage leaves it: the links in /boot on V2 and V1, none in /.
system_done() {
    detected
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
    rm "$ROOT/vmlinuz" "$ROOT/vmlinuz.old" "$ROOT/initrd.img" "$ROOT/initrd.img.old"
    ln -s "vmlinuz-$V2" "$ROOT/boot/vmlinuz"
    ln -s "vmlinuz-$V1" "$ROOT/boot/vmlinuz.old"
    ln -s "initrd.img-$V2" "$ROOT/boot/initrd.img"
    ln -s "initrd.img-$V1" "$ROOT/boot/initrd.img.old"
}

# Fail unless the last run printed no identifier, device or root device.
private_output() {
    local all="${output,,}${stderr,,}"
    [[ "$all" != *5ca1ab1e* && "$all" != *5ca1-ab1e* && "$all" != */dev/sd* &&
        "$all" != *kali--vg-root* ]] ||
        { printf 'an identifier was printed\n' >&2; return 1; }
}

# Print the link targets of NAME... in /boot, one per line.
boot_links() {
    local name
    for name in "$@"; do
        readlink "$ROOT/boot/$name"
    done
}

# Print every path under DIR, ROOT by default, with its kind, its link target and, for a file,
# its SHA-256, so that two calls differ when anything there was added, removed or changed.
tree_state() {
    local dir=${1:-$ROOT}
    (cd "$dir" && find . -printf '%y %p %l\n' | LC_ALL=C sort &&
        find . -type f -exec sha256sum {} + | LC_ALL=C sort)
}

# Print the backup directories, oldest first.
backups() {
    (cd "$ROOT$BACKUPS" 2> /dev/null && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | sort)
}

@test "detect appends the identity under a comment, once, and never prints a value" {
    printf '# mine\nverify_action = warn' > "$ROOT$CONF"
    run_ku migrate --stage detect --yes
    [ "$status" -eq 0 ]
    [ "$(< "$ROOT$CONF")" = "$(printf '%s\n' '# mine' 'verify_action = warn' '' \
        '# Set by kernel-updater migrate --stage detect.' \
        'boot_fs_uuid = 5ca1ab1e-0000-4000-8000-000000000b01' \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' 'disk_ptuuid = 5ca1ab1e' \
        'p1_fs_uuid = 5CA1AB1E00000001' 'root_device = /dev/mapper/kali--vg-root' \
        'grub_floor = 2.06')" ]
    [[ "$stderr" == *"plan: detect: append 6 key(s) to $CONF:"* ]]
    [[ "$stderr" == *"plan:   root_device: the root= device of the running kernel's command"* ]]
    [[ "$stderr" == *"plan:   grub_floor: 2.06, the highest the stick's GRUB 2.06 reaches"* ]]
    [[ "$stderr" == *"setting boot_fs_uuid arms the kernel-updater hooks"* ]]
    grep -q "^chown 0:0 -- $ROOT/etc/\.kernel-updater\.conf\.ku-" "$STUB_LOG"
    [ -z "$(find "$ROOT/etc" -maxdepth 1 -name '.*.ku-*')" ]
    private_output
    # A second run finds every key set to what the system shows.
    cp "$ROOT$CONF" "$BATS_TEST_TMPDIR/conf.after"
    run_ku migrate --stage detect --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"holds the keys already; nothing to do"* ]]
    cmp "$BATS_TEST_TMPDIR/conf.after" "$ROOT$CONF"
    # A key set to another value exits 78, naming the key but neither value.
    printf 'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c09\nroot_device = /dev/sda2\n' \
        > "$ROOT$CONF"
    run_ku migrate --stage detect --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"boot_luks_uuid and root_device in $CONF differ from what this system"* ]]
    [[ "$stderr" == *"correct or remove each such line"* ]]
    private_output
}

@test "detect fills in the FAT serial of a FAT partition 1" {
    export P1_TYPE=vfat P1_SERIAL=5ca1-ab1e
    run_ku migrate --stage detect --yes
    [ "$status" -eq 0 ]
    grep -q -x -F 'p1_fs_uuid = 5CA1-AB1E' "$ROOT$CONF"
    [[ "$stderr" == *"plan:   p1_fs_uuid: the FAT serial of partition 1 of that disk"* ]]
    private_output
    # The config it wrote is one the tool loads.
    run_ku migrate --stage detect --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"holds the keys already; nothing to do"* ]]
}

@test "detect writes nothing in a dry run, and refuses what it cannot fill" {
    run_ku migrate --stage detect --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"dry run: $CONF was not written"* ]]
    [ ! -e "$ROOT$CONF" ]
    export FINDMNT_OUT=""
    run_ku migrate --stage detect --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"/boot is not mounted: unlock and mount it first"* ]]
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID" LUKS_TYPE=""
    run_ku migrate --stage detect --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"/boot is not in an open LUKS container"* ]]
    export LUKS_TYPE=LUKS1 P1_TYPE=exfat P1_SERIAL=5CA1-AB1E
    run_ku migrate --stage detect --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"partition 1 of the disk that holds /boot is neither FAT nor NTFS"* ]]
    # A serial whose form does not fit the filesystem.
    export P1_TYPE=vfat P1_SERIAL=5CA1AB1E00000001
    run_ku migrate --stage detect --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"partition 1 has no form disk_ptuuid or p1_fs_uuid takes"* ]]
    export P1_TYPE=ntfs P1_SERIAL=5CA1-AB1E
    run_ku migrate --stage detect --yes
    [ "$status" -eq 3 ]
    export P1_SERIAL=5CA1AB1E00000001
    printf 'BOOT_IMAGE=/vmlinuz ro quiet\n' > "$ROOT/proc/cmdline"
    run_ku migrate --stage detect --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the running kernel's command line names no root= device"* ]]
    printf 'root=LABEL=root ro\n' > "$ROOT/proc/cmdline"
    run_ku migrate --stage detect --yes
    [ "$status" -eq 3 ]
    [ ! -e "$ROOT$CONF" ]
    # detect writes the file the hooks read, so --config is a usage error.
    run_ku -c "$BATS_TEST_TMPDIR/other.conf" migrate --stage detect
    [ "$status" -eq 64 ]
    private_output
}

@test "advice names sudo and the path the tool was started from, not the bare name" {
    local copy="$BATS_TEST_TMPDIR/opt dir" self
    # A copy under a path with a space, as a checkout may be: the advice quotes it as the
    # shell takes it.
    mkdir -p "$copy"
    cp -R "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/share" "$copy/"
    self=$(printf '%q' "$(readlink -f "$copy/bin/kernel-updater")")
    [[ "$self" == *'opt\ dir'* ]]
    run --separate-stderr env PATH="$STUB_BIN:$PATH" KU_TEST=1 \
        KU_ROOT="$BATS_TEST_TMPDIR/root" KU_TTY="$BATS_TEST_TMPDIR/tty" \
        KU_LOCKFILE="$BATS_TEST_TMPDIR/lock" bash "$copy/bin/kernel-updater" \
        migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"run 'sudo $self migrate --stage detect' first"* ]]
    [[ "$stderr" != *"'kernel-updater migrate"* ]]
    # The checkout's own path, through run_ku.
    run_ku migrate --stage system --yes
    [[ "$stderr" == *"run '$SUDO_KU migrate --stage detect' first"* ]]
    [[ "$SUDO_KU" == "sudo /"*"/bin/kernel-updater" ]]
    # Library code without bin/kernel-updater names the installed path.
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'printf "%s\n" "$KU_CMD"'
    [ "$status" -eq 0 ]
    [ "$output" = "sudo /usr/local/bin/kernel-updater" ]
}

@test "system refuses with 3 before detect and on each failed precondition, changing nothing" {
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the configuration lacks boot_fs_uuid, boot_luks_uuid, disk_ptuuid,"* ]]
    [[ "$stderr" == *"run '$SUDO_KU migrate --stage detect' first"* ]]
    detected
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-000000000b02"
    run_ku migrate --stage system --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"the filesystem at /boot is not the one boot_fs_uuid names"* ]]
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    export LUKS_TYPE=LUKS2 LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks2.dump"
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: boot-luks: /boot's container is LUKS2 with 1 argon2id keyslot(s)"* ]]
    export LUKS_TYPE=LUKS1 LUKS_DUMP="$REPO_DIR/tests/fixtures/system/luks1.dump"
    export EXT_FEATURES="has_journal extent 64bit casefold"
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: boot-ext: /boot has ext feature(s) GRUB 2.02 refuses"* ]]
    export EXT_FEATURES="has_journal extent 64bit"
    printf '%s\t%s\t%s\n' "linux-modules-$V2" 'iU ' 9-1kali1 >> "$DPKG_QUERY_OUT"
    export UNAME_R=9.0.3+kali-amd64
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kernels: $V2 is unpacked (iU): run dpkg --configure -a;"* ]]
    [[ "$stderr" == *"the running kernel 9.0.3+kali-amd64 is not installed"* ]]
    kernels "$V1" "$V2"
    export UNAME_R=$V2
    rm "$ROOT/boot/initrd.img-$V1"
    : > "$ROOT/boot/initrd.img-$V2"
    : > "$ROOT/boot/vmlinuz.old"
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: /boot/initrd.img-$V1 is missing, empty or no regular file"* ]]
    [[ "$stderr" == *"error: /boot/initrd.img-$V2 is missing, empty or no regular file"* ]]
    [[ "$stderr" == *"error: no installed kernel would boot from the stick"* ]]
    [[ "$stderr" == *"error: /boot/vmlinuz.old is no symlink, which linux-update-symlinks"* ]]
    [[ "$stderr" == *"the system stage refuses to run while that is so; nothing was changed"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ -z "$(backups)" ]
    [ ! -L "$ROOT/boot/vmlinuz" ]
    refute_line_match '^(linux-update-symlinks|debconf-set-selections)' "$STUB_LOG"
    private_output
}

@test "system links the previous kernel, then the newest, edits kernel-img.conf and backs up" {
    detected
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    # The running kernel is the newest, so the previous one is the newest other one.
    [ "$(grep '^linux-update-symlinks' "$STUB_LOG")" = "$(printf '%s\n' \
        "linux-update-symlinks install $V1 /boot/vmlinuz-$V1" \
        "linux-update-symlinks install $V2 /boot/vmlinuz-$V2")" ]
    [ "$(boot_links vmlinuz vmlinuz.old initrd.img initrd.img.old)" = "$(printf '%s\n' \
        "vmlinuz-$V2" "vmlinuz-$V1" "initrd.img-$V2" "initrd.img-$V1")" ]
    # Each line that sets a key, in any case, is replaced, comment and all; the others stay.
    [ "$(< "$ROOT/etc/kernel-img.conf")" = "$(printf '%s\n' \
        '# Kernel image management overrides' 'do_symlinks = yes' 'link_in_boot = yes # old' \
        'image_dest = /')" ]
    grep -q "^chown 0:0 -- $ROOT/etc/\.kernel-img\.conf\.ku-" "$STUB_LOG"
    # The links in / moved into the backup, which lists and hashes all it holds.
    [ ! -L "$ROOT/vmlinuz" ]
    [ ! -L "$ROOT/initrd.img.old" ]
    [ "$(backups)" = 20261112T090001Z ]
    local dir="$ROOT$BACKUPS/20261112T090001Z"
    [ "$(< "$dir/stage")" = system ]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$dir/kernel-img.conf"
    [ "$(readlink "$dir/root-links/vmlinuz.old")" = "boot/vmlinuz-$V1" ]
    [ "$(< "$dir/root-links.list")" = "$(printf '%s\t%s\n' vmlinuz "boot/vmlinuz-$V2" \
        vmlinuz.old "boot/vmlinuz-$V1" initrd.img "boot/initrd.img-$V2" initrd.img.old \
        "boot/initrd.img-$V1")" ]
    [ "$(cut -c 67- "$dir/MANIFEST")" = "$(printf '%s\n' stage kernel-img.conf root-links.list)" ]
    (cd "$dir" && sha256sum -c --quiet MANIFEST)
    # grub-pc's answer is emptied, with the answer that lets an upgrade go on unasked.
    [ "$(< "$DEBCONF_IN")" = "$(printf '%s\n' 'grub-pc grub-pc/install_devices multiselect ' \
        'grub-pc grub-pc/install_devices_empty boolean true')" ]
    [[ "$stderr" == *"grub-pc/install_devices is empty now; its old answer is kept nowhere"* ]]
    [[ "$stderr" == *"test both pairs of links at the GRUB prompt, natively and in the VM"* ]]
    [[ "$stderr" == *"'linux /vmlinuz root=<root_device>' and 'initrd /initrd.img'"* ]]
    private_output
    # Run again, it finds its result in place.
    : > "$STUB_LOG"
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"the links in /boot and / are in place already; nothing to do"* ]]
    refute_line_match '^linux-update-symlinks' "$STUB_LOG"
    [ "$(backups)" = 20261112T090001Z ]
}

@test "A dry run of system, and of all once detect is done, plans and changes nothing" {
    local before args
    # With grub_floor set too, detect has nothing to do, and all goes on to system.
    detected 'grub_floor = 2.06'
    before=$(tree_state)
    for args in "--stage system --dry-run" "--dry-run"; do
        : > "$STUB_LOG"
        # shellcheck disable=SC2086 # the options are meant to split
        run_ku migrate $args
        [ "$status" -eq 0 ]
        [[ "$stderr" == *"plan:"* ]]
        [[ "$stderr" == *"dry run: nothing was changed"* ]]
        [ "$(tree_state)" = "$before" ]
        [ -z "$(backups)" ]
        refute_line_match '^(linux-update-symlinks|debconf-set-selections|chown)' "$STUB_LOG"
    done
    # all stops after system, whose result the menu stage's plan builds on.
    [[ "$stderr" == *"dry run: the stages after system build on what it would change"* ]]
}

@test "system takes the running kernel as the previous one, and a lone kernel for both" {
    kernels "$V1" "$V2" "$V3"
    detected
    export UNAME_R=$V1
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ "$(grep '^linux-update-symlinks' "$STUB_LOG")" = "$(printf '%s\n' \
        "linux-update-symlinks install $V1 /boot/vmlinuz-$V1" \
        "linux-update-symlinks install $V3 /boot/vmlinuz-$V3")" ]
    [ "$(boot_links vmlinuz vmlinuz.old)" = "$(printf '%s\n' "vmlinuz-$V3" "vmlinuz-$V1")" ]
    # One kernel: one call, which points all four links at it.
    rm -f "$ROOT"/boot/vmlinuz* "$ROOT"/boot/initrd.img*
    kernels "$V2"
    export UNAME_R=$V2
    printf 'link_in_boot = no\n' > "$ROOT/etc/kernel-img.conf"
    : > "$STUB_LOG"
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ "$(grep '^linux-update-symlinks' "$STUB_LOG")" = \
        "linux-update-symlinks install $V2 /boot/vmlinuz-$V2" ]
    [ "$(boot_links vmlinuz vmlinuz.old initrd.img initrd.img.old)" = "$(printf '%s\n' \
        "vmlinuz-$V2" "vmlinuz-$V2" "initrd.img-$V2" "initrd.img-$V2")" ]
    [ "$(< "$ROOT/etc/kernel-img.conf")" = "$(printf '%s\n' 'link_in_boot = yes' \
        'do_symlinks = yes')" ]
}

@test "grub-pc gets a question of its own, and a no leaves it with a warning" {
    detected
    rm "$ROOT/initrd.img.old"
    printf 'initrd\n' > "$ROOT/initrd.img.old"
    rm "$ROOT/etc/kernel/preinst.d/00-kernel-updater"
    printf 'y\nn\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku migrate --stage system
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Configure the kernel links as planned? [y/N] "* ]]
    [[ "$stderr" == *"Empty grub-pc's install_devices, so that a grub-pc upgrade never writes"* ]]
    [[ "$stderr" == *"warning: grub-pc/install_devices still names 1 device(s), so check's"* ]]
    [ ! -e "$DEBCONF_IN" ]
    # A regular file where a link was stays, and so does the warning about the hooks.
    [[ "$stderr" == *"plan: leave initrd.img.old in /: no symlink"* ]]
    [[ "$stderr" == *"warning: /initrd.img.old is no symlink, so it stays in /"* ]]
    [ -f "$ROOT/initrd.img.old" ]
    [[ "$stderr" == *"warning: the kernel-updater hooks are not installed: run"* ]]
    # Run again, the result is in place, and only the warning about grub-pc remains.
    run_ku migrate --stage system
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"nothing to do"* ]]
    [[ "$stderr" == *"names 1 device(s), so check's grub-pc item fails: run 'dpkg-reconfigure"* ]]
    # The rollback says that the answer still names the device, as the stage left it.
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: grub-pc/install_devices still names 1 device(s), as the system"* ]]
    [[ "$stderr" != *"stays empty"* ]]
    private_output
}

@test "A result that fails its check exits 4, and --rollback restores the system as it was" {
    detected
    export LUS_ABSOLUTE=1
    run_ku migrate --stage system --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"after the system stage, vmlinuz is absolute; vmlinuz.old is absolute;"* ]]
    [[ "$stderr" == *"'$SUDO_KU migrate --rollback' restores kernel-img.conf and the"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: rollback of the system stage run 20261112T090001Z: put"* ]]
    [[ "$stderr" == *"plan: move vmlinuz, vmlinuz.old, initrd.img and initrd.img.old back to /"* ]]
    [[ "$stderr" == *"grub-pc/install_devices stays empty"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ "$(readlink "$ROOT/vmlinuz")" = "boot/vmlinuz-$V2" ]
    [ "$(readlink "$ROOT/initrd.img.old")" = "boot/initrd.img-$V1" ]
    [ "$(backups)" = 20261112T090001Z.rolled-back ]
    # Nothing is left to roll back.
    run_ku migrate --rollback --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"$BACKUPS holds no stage run that was not rolled back"* ]]
    # Without a kernel-img.conf before, the rollback removes the one the stage made, and a link
    # whose name is taken in / stays in the backup.
    rm "$ROOT/etc/kernel-img.conf"
    export LUS_ABSOLUTE=""
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ -e "$ROOT$BACKUPS/20261112T090002Z/kernel-img.conf.absent" ]
    printf 'kernel\n' > "$ROOT/vmlinuz"
    run_ku migrate --rollback 20261112T090002Z --yes
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT/etc/kernel-img.conf" ]
    [[ "$stderr" == *"plan: leave vmlinuz in the backup's root-links, as / has entries of"* ]]
    [[ "$stderr" == *"warning: /vmlinuz exists, so the old link of that name stays in"* ]]
    [ "$(< "$ROOT/vmlinuz")" = kernel ]
    [ -L "$ROOT$BACKUPS/20261112T090002Z.rolled-back/root-links/vmlinuz" ]
    [ "$(readlink "$ROOT/initrd.img")" = "boot/initrd.img-$V2" ]
    private_output
}

@test "system refuses one bootable kernel beside another image, and checks where .old points" {
    detected
    rm "$ROOT/boot/initrd.img-$V1"
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: /boot/initrd.img-$V1 is missing, empty or no regular file"* ]]
    [[ "$stderr" == *"error: only $V2 would boot, while /boot also holds the image(s) of $V1,"* ]]
    [[ "$stderr" == *"from which linux-update-symlinks would take vmlinuz.old: make each boot"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ -z "$(backups)" ]
    refute_line_match '^linux-update-symlinks' "$STUB_LOG"
    # Without the other image, the lone kernel takes all four links; an uncompressed vmlinux
    # of that same kernel is no other image.
    rm "$ROOT/boot/vmlinuz-$V1"
    printf 'elf\n' > "$ROOT/boot/vmlinux-$V2"
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ "$(boot_links vmlinuz vmlinuz.old initrd.img initrd.img.old)" = "$(printf '%s\n' \
        "vmlinuz-$V2" "vmlinuz-$V2" "initrd.img-$V2" "initrd.img-$V2")" ]
    private_output
}

@test "The check after the system stage fails when the .old links point at another kernel" {
    kernels "$V1" "$V2" "$V3"
    detected
    export LUS_OLD=$V1
    run_ku migrate --stage system --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"after the system stage, vmlinuz.old does not point at the files of $V2;"* ]]
    [[ "$stderr" == *"initrd.img.old does not point at the files of $V2; '$SUDO_KU "* ]]
    # Run again, the stage takes .old links on another kernel that would boot for its result,
    # as linux-base keeps them from then on, but not links on one that would not boot.
    export LUS_OLD=""
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"the links in /boot and / are in place already; nothing to do"* ]]
    export LSINITRAMFS_FAIL=$V1
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ "$(boot_links vmlinuz vmlinuz.old)" = "$(printf '%s\n' "vmlinuz-$V3" "vmlinuz-$V2")" ]
}

@test "Run on the newest kernel after menu, system leaves the links, and every run rolls back" {
    kernels "$V1" "$V2" "$V3"
    legacy_kernel
    detected
    export UNAME_R=$V1
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ "$(boot_links vmlinuz vmlinuz.old)" = "$(printf '%s\n' "vmlinuz-$V3" "vmlinuz-$V1")" ]
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    # The previous kernel would be V2 now, but links on V3 and V1 are in place all the same.
    export UNAME_R=$V3
    : > "$STUB_LOG"
    run_ku migrate --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"migrate system: kernel-img.conf, the links in /boot and / are in place"* ]]
    [[ "$stderr" == *"migrate menu: grub.cfg sources kali.cfg already; nothing to do"* ]]
    refute_line_match '^linux-update-symlinks' "$STUB_LOG"
    [ "$(backups)" = "$(printf '%s\n' 20261112T090001Z 20261112T090002Z)" ]
    # A run that links anew after the menu stage keeps kernel-img.conf keeping the links in
    # /boot, so it rolls back while grub.cfg sources kali.cfg, and the runs before it after it.
    rm "$ROOT/boot/vmlinuz.old"
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [ "$(boot_links vmlinuz vmlinuz.old)" = "$(printf '%s\n' "vmlinuz-$V3" "vmlinuz-$V2")" ]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: that kernel-img.conf has linux-base keep the links in /boot too"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"rollback of the menu stage run 20261112T090002Z"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"rollback of the system stage run 20261112T090001Z"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    private_output
}

@test "A kernel install while system asks exits 75, and links it moves later stay in /" {
    kernels "$V1" "$V2" "$V3"
    detected
    # An install while the question waits moved /vmlinuz: the plan no longer holds, and the
    # stage exits 75, as cleanup does, since a run once apt is done can succeed.
    export SHOW_MOVES=$V3
    run_ku migrate --stage system --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"the kernels or their links changed while the question waited"* ]]
    [[ "$stderr" == *"run the system stage again; nothing was changed"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ -z "$(backups)" ]
    refute_line_match '^linux-update-symlinks' "$STUB_LOG"
    # One while the stage links moves /initrd.img, which stays in / then, so that the backup
    # holds only the links it records, and rolls back.
    export SHOW_MOVES="" LUS_ROOT=$V3
    ln -sfn "boot/vmlinuz-$V2" "$ROOT/vmlinuz"
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: /initrd.img no longer points where the backup records it"* ]]
    [ "$(readlink "$ROOT/initrd.img")" = "boot/initrd.img-$V3" ]
    [ ! -e "$ROOT$BACKUPS/20261112T090001Z/root-links/initrd.img" ]
    export LUS_ROOT=""
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ "$(readlink "$ROOT/vmlinuz")" = "boot/vmlinuz-$V2" ]
    [ "$(readlink "$ROOT/initrd.img.old")" = "boot/initrd.img-$V1" ]
    private_output
}

@test "system exits 75 while apt or dpkg holds its lock, before the plan and after the question" {
    local line
    detected
    # The stat stub gives every file the inode 600, so a lock on inode 600 is on lock-frontend.
    mkdir -p "$ROOT/var/lib/dpkg" "$ROOT/proc/4242"
    : > "$ROOT/var/lib/dpkg/lock-frontend"
    printf 'apt-get\n' > "$ROOT/proc/4242/comm"
    line='1: POSIX  ADVISORY  WRITE 4242 08:01:600 0 EOF'
    printf '%s\n' "$line" > "$ROOT/proc/locks"
    run_ku migrate --stage system --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"apt or dpkg is running: PID 4242 (apt-get) holds"* ]]
    [[ "$stderr" == *"/var/lib/dpkg/lock-frontend; run the system stage again once it is done;"* ]]
    [[ "$stderr" == *"nothing was changed"* ]]
    [[ "$stderr" != *"plan:"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ -z "$(backups)" ]
    refute_line_match '^linux-update-symlinks' "$STUB_LOG"
    # apt takes the lock while the question waits: the plan no longer holds.
    : > "$ROOT/proc/locks"
    export SHOW_LOCKS=$line
    run_ku migrate --stage system --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"plan:"* ]]
    [[ "$stderr" == *"apt or dpkg is running: PID 4242 (apt-get) holds"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ -z "$(backups)" ]
    refute_line_match '^linux-update-symlinks' "$STUB_LOG"
    # When /proc/locks cannot be read, the stage cannot tell, and refuses with 3.
    unset SHOW_LOCKS
    rm "$ROOT/proc/locks"
    run_ku migrate --stage system --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"so the system stage cannot tell whether apt or dpkg is running"* ]]
    [ -z "$(backups)" ]
}

@test "A write of kernel-img.conf that fails, as on a full disk, exits 4 before the rename" {
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib '_ku_mg_etc_tmp() { KU_MG_ETC_TMP=/dev/full; }
        _ku_mg_etc_fail() { ku_die "$KU_EX_WRITE" "cannot write $1; it is as it was"; }
        _ku_mg_etc_finish() { printf "renamed\n"; }
        _ku_mg_edit_kernel_img'
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"cannot write /etc/kernel-img.conf; it is as it was"* ]]
    [ -z "$output" ]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
}

@test "menu writes kali.cfg, then grub.cfg, CRLF kept, after a dry run that writes nothing" {
    local kali=multibootusb/grub/kali.cfg grub=multibootusb/grub/grub.cfg
    system_done
    run_ku migrate --stage menu --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would write $kali"*"would write $grub, keeping the old one as"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ ! -e "$GRUB/kali.cfg" ]
    [ -z "$(backups)" ]
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: wrote $kali"*"info: wrote $grub; the old one is kept as"* ]]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
    # The plan names the variants with the root device as a placeholder, and each change.
    [[ "$stderr" == *'plan:   "Kali GNU/Linux": linux /vmlinuz, initrd /initrd.img, root=<'* ]]
    [[ "$stderr" == *"initrd /initrd.img.old, root=<root_device> ro nomodeset noapic"* ]]
    [[ "$stderr" == *"plan:   changed: default: cryptdevice= goes"* ]]
    [[ "$stderr" == *'plan:   not carried over: "Kali GNU/Linux (live mode)", as menu_variants'* ]]
    [[ "$stderr" == *"plan: grub.cfg: lines 57 to 129, the Kali submenu, become a block"* ]]
    [[ "$stderr" == *"warning: the tripwire's baseline was not updated"* ]]
    [[ "$stderr" == *"Then run '$SUDO_KU migrate --stage finalize'"* ]]
    # The dry run took the first stamp for the backup grub.cfg would have had.
    local dir="$ROOT$BACKUPS/20261112T090002Z"
    [ "$(< "$dir/stage")" = menu ]
    # The way the files reached partition 1 is in the plan and the log, not in the backup.
    [ ! -e "$dir/deploy" ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$dir/grub.cfg"
    [ ! -e "$dir/kali.cfg" ]
    private_output
    # Run again, grub.cfg sources kali.cfg already.
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"grub.cfg sources kali.cfg already; nothing to do"* ]]
}

@test "menu exports both files under their own names, and refuses before system and on checks" {
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"run '$SUDO_KU migrate --stage detect' first"* ]]
    detected
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"kernel-img.conf does not have linux-base keep the links in /boot: run"* ]]
    # The links in /boot are named too, as they are not there yet.
    [[ "$stderr" == *"vmlinuz is missing or no symlink"* ]]
    system_done
    export GSC_FAIL=kali.cfg
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"grub-script-check rejects the new kali.cfg, so it is not written"* ]]
    export GSC_FAIL=""
    detected 'menu_variants = default,live'
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"need overlayroot in the initrd, which the initrd of $V2 lacks"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ ! -e "$GRUB/kali.cfg" ]
    [ -z "$(backups)" ]
    detected
    run_ku migrate --stage menu --deploy export --output-dir /root/out/ --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: menu: export kali.cfg and grub.cfg to output_dir for Windows"* ]]
    # check reads the output_dir of the configuration, and not this one.
    [[ "$stderr" == *"warning: --output-dir took this export away from the output_dir of"* ]]
    cmp "$FIXTURES/kali.expected.cfg" "$ROOT/root/out/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.after" "$ROOT/root/out/grub.cfg"
    [ "$(cut -c 67- "$ROOT/root/out/SHA256SUMS")" = $'kali.cfg\ngrub.cfg' ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ ! -e "$GRUB/kali.cfg" ]
    [ ! -e "$ROOT$BACKUPS/20261112T090001Z/deploy" ]
    # The initrds the links reach count: V2's holds overlayroot, and V1's, on the .old links,
    # which previous_variants may give a live entry too, does not.
    mkstub lsinitramfs <<'EOF'
[[ $1 != *"/initrd.img-$OVERLAY_IN" ]] || printf 'usr/sbin/overlayroot-chroot\n'
printf 'usr/lib/modules\n'
EOF
    export OVERLAY_IN=$V2
    detected 'menu_variants = default,live' 'previous_variants = default'
    run_ku migrate --stage menu --dry-run
    [ "$status" -eq 0 ]
    detected 'menu_variants = default,live' 'previous_variants = default,live'
    run_ku migrate --stage menu --dry-run
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"which the initrd of $V1 lacks, the one /boot/initrd.img.old points at"* ]]
    [[ "$stderr" == *"or leave them out of previous_variants; nothing was changed"* ]]
}

@test "A kali.cfg that appears right after the writer's checks leaves no backup to roll back" {
    system_done
    legacy_kernel
    # dd makes kali.cfg on the stick right after the writer first hashes grub.cfg, which is its
    # check of every file before the first write, as another program writing the stick would.
    export REAL_DD DD_DONE="$BATS_TEST_TMPDIR/dd.done" DD_GRUB="$GRUB/grub.cfg"
    REAL_DD=$(command -v dd)
    mkstub dd <<'EOF'
"$REAL_DD" "$@" || exit
case " $* " in
    *" of="*) exit 0 ;;
    *" if=$DD_GRUB "*"bs=1M "*)
        if [[ ! -e $DD_DONE ]]; then
            : > "$DD_DONE"
            printf 'other\n' > "${DD_GRUB%/*}/kali.cfg"
        fi
        ;;
esac
EOF
    run_ku migrate --stage menu --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"refusing to write multibootusb/grub/kali.cfg: it exists, but the plan \
expected none; nothing was changed"* ]]
    [ "$(< "$GRUB/kali.cfg")" = other ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    # The run wrote nothing, so it leaves no backup, and a rollback finds nothing to undo.
    [ -z "$(backups)" ]
    run_ku migrate --rollback --yes
    [ "$status" -eq 66 ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
}

@test "A grub.cfg changed while menu asks exits 75 and writes nothing, and a new run writes it" {
    local other=$'menuentry "Other" {\r\n\ttrue\r\n}\r\n'
    system_done
    legacy_kernel
    # grub-script-check, which checks the new files once the plan read the stick's, adds
    # GSC_CHANGES to the stick's grub.cfg, as another program writing the stick while the
    # question waits would.
    mkstub grub-script-check <<'EOF'
[[ -z ${GSC_CHANGES:-} || ${*: -1} != */grub.cfg ]] ||
    printf '%s' "$GSC_CHANGES" >> "$KU_P1_DIR/multibootusb/grub/grub.cfg"
EOF
    export GSC_CHANGES=$other
    run_ku migrate --stage menu --yes
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"refusing to write multibootusb/grub/grub.cfg: it changed since the plan \
read it; nothing was changed"* ]]
    [[ "$stderr" != *"info: wrote"* ]]
    [ ! -e "$GRUB/kali.cfg" ]
    cmp <(cat "$BATS_TEST_TMPDIR/grub.before"; printf '%s' "$other") "$GRUB/grub.cfg"
    # The run wrote nothing, so it leaves no backup that a rollback would undo.
    [ -z "$(backups)" ]
    # Run again, the stage plans anew from the grub.cfg it finds, and writes both files.
    export GSC_CHANGES=""
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    grep -q -F 'menuentry "Other"' "$GRUB/grub.cfg"
    local stamp
    stamp=$(backups)
    [[ $stamp =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
    [ -f "$ROOT$BACKUPS/$stamp/MANIFEST" ]
    # Its rollback picks that run, the only one.
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"rollback of the menu stage run $stamp"* ]]
    private_output
}

@test "A dry run of finalize plans the removal and changes nothing, the stick included" {
    local before stick backups_before
    system_done
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    before=$(tree_state) stick=$(tree_state "$KU_P1_DIR") backups_before=$(backups)
    : > "$STUB_LOG"
    run_ku migrate --stage finalize --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: grub.cfg: remove lines 65 to 137, the submenu"* ]]
    [[ "$stderr" == *"dry run"*"nothing was"* ]]
    [ "$(tree_state)" = "$before" ]
    [ "$(tree_state "$KU_P1_DIR")" = "$stick" ]
    [ "$(backups)" = "$backups_before" ]
    [ ! -e "$ROOT/var/lib/kernel-updater/baseline" ]
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
}

@test "finalize removes the legacy entries, records the baseline, and rolls back" {
    system_done
    run_ku migrate --stage finalize --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"run '$SUDO_KU migrate --stage menu' first"* ]]
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku migrate --stage finalize
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"Remove the legacy Kali entries from grub.cfg? Do so only once the new"* ]]
    [[ "$stderr" == *"declined; the finalize stage changed nothing"* ]]
    run_ku migrate --stage finalize --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: grub.cfg: remove lines 65 to 137, the submenu"* ]]
    cmp <(head -n 64 "$BATS_TEST_TMPDIR/grub.after"; tail -n +138 "$BATS_TEST_TMPDIR/grub.after") \
        "$GRUB/grub.cfg"
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    grep -q '  multibootusb/grub/kali\.cfg$' "$ROOT/var/lib/kernel-updater/baseline"
    [[ "$stderr" == *"info: recorded 3 entries of the stick's boot code in"* ]]
    run_ku migrate --stage finalize --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"grub.cfg holds no legacy Kali entries; nothing to do"* ]]
    # The rollbacks go newest first: finalize's, then menu's, each byte for byte.
    run_ku migrate --rollback 20261112T090001Z --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the newer stage run 20261112T090003Z is not rolled back yet"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"kali.cfg stays on partition 1, where the grub.cfg put back sources it"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
    # The grub.cfg from before boots the kernel its entries name, which /boot no longer holds.
    run_ku migrate --rollback --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the Kali entries of the grub.cfg in the backup 20261112T090001Z boot no"* ]]
    [[ "$stderr" == *"kernel /boot holds now (they name 7.2.9+kali-amd64), so written back it"* ]]
    [[ "$stderr" == *"the menu stage stays, and kali.cfg's entries keep booting the kernels"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
    # Without kali.cfg, the refusal names the menu stage, which writes it anew.
    mv "$GRUB/kali.cfg" "$BATS_TEST_TMPDIR/kali.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"kali.cfg, which grub.cfg sources, is missing or cannot be read too: run"* ]]
    mv "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    legacy_kernel
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"where the grub.cfg put back no longer uses it: check's kali-menu item"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ -e "$GRUB/kali.cfg" ]
    [ "$(backups)" = "$(printf '%s.rolled-back\n' 20261112T090001Z 20261112T090003Z)" ]
    # A stage run rolled back already, or one there never was, is refused.
    run_ku migrate --rollback 20261112T090003Z --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the stage run 20261112T090003Z was rolled back already"* ]]
    run_ku migrate --rollback 20261112T080000Z --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"$BACKUPS holds no backup 20261112T080000Z"* ]]
    private_output
}

@test "Run again, menu writes kali.cfg alone anew from the legacy entries, and rolls that back" {
    system_done
    legacy_kernel
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    # Other variants: kali.cfg alone is written anew, and grub.cfg stays.
    detected 'menu_variants = default'
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: menu: grub.cfg sources kali.cfg already; write kali.cfg alone to"* ]]
    [[ "$stderr" == *"plan: kali.cfg differs from what the menu stage writes now from the"* ]]
    [[ "$stderr" == *"plan: grub.cfg stays as it is"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
    grep -q -F '"Kali GNU/Linux (previous kernel)"' "$GRUB/kali.cfg"
    refute_line_match 'fail-safe' "$GRUB/kali.cfg"
    local dir="$ROOT$BACKUPS/20261112T090003Z"
    [ "$(< "$dir/stage")" = kali ]
    cmp "$FIXTURES/kali.expected.cfg" "$dir/kali.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"grub.cfg sources kali.cfg already; nothing to do"* ]]
    # Its rollback puts the kali.cfg from before back.
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"rollback of the menu stage run 20261112T090003Z, which wrote kali.cfg"* ]]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    # A kali.cfg deleted from Windows is written anew.
    detected
    rm "$GRUB/kali.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: kali.cfg is missing, so the stick's Kali entry only says so"* ]]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    # After finalize no legacy entries are left to take the parameters from, until its rollback
    # brings them back.
    run_ku migrate --stage finalize --yes
    [ "$status" -eq 0 ]
    rm "$GRUB/kali.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"holds no legacy Kali entries to take its parameters from, as after the"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    # The rollback of a run that wrote a missing kali.cfg leaves it.
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"kali.cfg was missing before, and stays as the run wrote it"* ]]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    private_output
}

@test "A rollback that drops changes made to grub.cfg since its run says so and asks for it" {
    system_done
    legacy_kernel
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    local dir="$ROOT$BACKUPS/20261112T090001Z"
    [ "$(cut -c 67- "$dir/written")" = $'kali.cfg\ngrub.cfg' ]
    grep -q '  written$' "$dir/MANIFEST"
    # MultiBootUSB adds an ISO from Windows.
    printf '%s\r\n' '#start ubuntu.iso' 'menuentry "Ubuntu" {' '    linux (loop)/casper/vmlinuz' \
        '}' '#end ubuntu.iso' >> "$GRUB/grub.cfg"
    cp "$GRUB/grub.cfg" "$BATS_TEST_TMPDIR/grub.iso"
    run_ku migrate --rollback --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: grub.cfg on partition 1 changed after the menu stage run"* ]]
    [[ "$stderr" == *"the rollback drops those changes, which then only the copy the write"* ]]
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku migrate --rollback
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"back as planned, dropping the changes made to grub.cfg since? [y/N]"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.iso" "$GRUB/grub.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    # The copy the write keeps beside grub.cfg holds the ISO's entry.
    grep -q -F 'menuentry "Ubuntu"' "$GRUB"/grub.cfg.ku-*.bak
    private_output
}

@test "A backup whose files do not match its MANIFEST is refused with exit 3" {
    system_done
    legacy_kernel
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    local dir="$ROOT$BACKUPS/20261112T090001Z"
    cp "$GRUB/grub.cfg" "$BATS_TEST_TMPDIR/grub.now"
    printf 'changed\r\n' >> "$dir/grub.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the backup 20261112T090001Z cannot be trusted: grub.cfg does not match"* ]]
    cp "$BATS_TEST_TMPDIR/grub.before" "$dir/grub.cfg"
    : > "$dir/extra"
    run_ku migrate --rollback --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"it holds extra, which its MANIFEST does not list"* ]]
    rm "$dir/extra"
    ln -s ../../../../p1/multibootusb/grub/grub.cfg "$dir/kali.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 3 ]
    rm "$dir/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.now" "$GRUB/grub.cfg"
    # Whole again, it rolls back; a dry run first changes nothing.
    run_ku migrate --rollback --dry-run
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/grub.now" "$GRUB/grub.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
}

@test "The menu plan shows parameters that may name a device or a key as NAME=<value>" {
    local words='resume=UUID=5ca1ab1e-0000-4000-8000-0000000000d1 resume=/dev/sdb5'
    words+=' cryptkey=rootfs:/root.key'
    system_done
    sed -i "s#:root_crypt ro quiet splash#:root_crypt ro quiet splash $words#" "$GRUB/grub.cfg"
    run_ku migrate --stage menu --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"ro quiet splash resume=<value> resume=<value> cryptkey=<value>"* ]]
    private_output
    # kali.cfg itself gets the words as they were.
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    grep -q -F "root=/dev/mapper/kali--vg-root ro quiet splash $words" "$GRUB/kali.cfg"
    private_output
}

@test "menu refuses what it cannot carry over, a grub.cfg it cannot use and another /boot" {
    local lists="$REPO_DIR/share/kernel-updater/grub-2.02"
    system_done
    # The stick's own GRUB lists count, and one without search fails lint.
    grep -v -x -e search "$lists/commands.txt" > "$GRUB/i386-pc/command.lst"
    cp "$lists/modules.txt" "$GRUB/i386-pc/moddep.lst"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: kali.cfg line "*": unknown command 'search' [unknown-command]"* ]]
    [[ "$stderr" == *"the new kali.cfg fails lint, so it is not written; nothing was changed"* ]]
    # With the whole lists, lint finds nothing, and no list of GRUB 2.02 stands in.
    cp "$lists/commands.txt" "$GRUB/i386-pc/command.lst"
    run_ku migrate --stage menu --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"GRUB 2.02's stand in"* && "$stderr" != *"lint warns"* ]]
    # A /boot whose filesystem has its container's UUID: kali.cfg's search --fs-uuid is given
    # that UUID and matches, so the plan holds no lint warning either.
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 5ca1ab1e-0000-4000-8000-000000000c01"
    sed -i 's/^boot_fs_uuid = .*/boot_fs_uuid = 5ca1ab1e-0000-4000-8000-000000000c01/' "$ROOT$CONF"
    run_ku migrate --stage menu --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"lint warns"* ]]
    export FINDMNT_OUT="/dev/mapper/boot_crypt ext4 $BOOT_FS_UUID"
    sed -i "s/^boot_fs_uuid = .*/boot_fs_uuid = $BOOT_FS_UUID/" "$ROOT$CONF"
    # A title with a quote, which kali.cfg's double quotes would not hold.
    sed "s/^submenu \"Kali GNU\/Linux amd64 (full install)\"/submenu \"Kali 'amd64'\"/" \
        "$BATS_TEST_TMPDIR/grub.before" > "$GRUB/grub.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the title of grub.cfg's Kali submenu is not one quoted string without"* ]]
    # A submenu on one line, which migrate does not split.
    printf 'submenu "Kali" { menuentry "Kali" { linux /vmlinuz-9 ro; } }\r\n' > "$GRUB/grub.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the Kali submenu of grub.cfg fits on one line"* ]]
    # A grub.cfg that sources a kali.cfg that is missing, without legacy entries to take the
    # parameters from, as after finalize.
    { head -n 64 "$BATS_TEST_TMPDIR/grub.after"; tail -n +138 "$BATS_TEST_TMPDIR/grub.after"; } \
        > "$GRUB/grub.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"grub.cfg sources kali.cfg, which is missing, and holds no legacy Kali"* ]]
    [[ "$stderr" == *"roll that stage back with '$SUDO_KU migrate --rollback', then run"* ]]
    # No grub.cfg at all.
    rm "$GRUB/grub.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"partition 1 holds no multibootusb/grub/grub.cfg; nothing was changed"* ]]
    # A /boot in another LUKS container than boot_luks_uuid names.
    cp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    sed -i 's/^boot_luks_uuid = .*/boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c09/' \
        "$ROOT$CONF"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"/boot is not in the LUKS container boot_luks_uuid names"* ]]
    [ ! -e "$GRUB/kali.cfg" ]
    [ -z "$(backups)" ]
    private_output
}

@test "finalize and the rollbacks export in export mode, and system waits for the copy" {
    local out="$ROOT/root/out" final="$BATS_TEST_TMPDIR/grub.final"
    local -a opts=(--deploy export --output-dir /root/out --yes)
    legacy_kernel
    detected
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    run_ku migrate --stage menu "${opts[@]}"
    [ "$status" -eq 0 ]
    # Windows copies the export.
    cp "$out/kali.cfg" "$out/grub.cfg" "$GRUB/"
    run_ku migrate --stage finalize "${opts[@]}"
    [ "$status" -eq 0 ]
    { head -n 64 "$BATS_TEST_TMPDIR/grub.after"; tail -n +138 "$BATS_TEST_TMPDIR/grub.after"; } \
        > "$final"
    cmp "$final" "$out/grub.cfg"
    [ "$(cut -c 67- "$out/SHA256SUMS")" = grub.cfg ]
    [ ! -e "$out/kali.cfg" ]
    [ ! -e "$ROOT/var/lib/kernel-updater/baseline" ]
    [[ "$stderr" == *"once Windows copied grub.cfg, run '$SUDO_KU baseline'"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
    # Not copied yet, the finalize export is undone by one of the grub.cfg the stick holds.
    run_ku migrate --rollback "${opts[@]}"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"partition 1 holds grub.cfg as the backup does already, and it is"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.after" "$out/grub.cfg"
    [ "$(cut -c 67- "$out/SHA256SUMS")" = grub.cfg ]
    # The menu stage's rollback exports the grub.cfg from before.
    run_ku migrate --rollback "${opts[@]}"
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$out/grub.cfg"
    # Until Windows copied it, the stick boots the links in /boot, and system stays.
    run_ku migrate --rollback --yes
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"partition 1's grub.cfg still sources kali.cfg, whose entries boot the"* ]]
    grep -q '^link_in_boot = yes' "$ROOT/etc/kernel-img.conf"
    cp "$out/grub.cfg" "$GRUB/grub.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ "$(backups)" = "$(printf '%s.rolled-back\n' 20261112T090001Z 20261112T090002Z \
        20261112T090003Z)" ]
    private_output
}

@test "A write removes the export it makes stale, and finalize leaves other changes to baseline" {
    local out="$ROOT/root/out" stored
    system_done
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    stored=$(< "$ROOT/var/lib/kernel-updater/baseline")
    run_ku migrate --stage menu --deploy export --output-dir /root/out --yes
    [ "$status" -eq 0 ]
    [ "$(< "$ROOT/var/lib/kernel-updater/baseline")" = "$stored" ]
    # Windows copies the export, and a GRUB module changes besides.
    cp "$out/kali.cfg" "$out/grub.cfg" "$GRUB/"
    printf 'changed\n' >> "$GRUB/i386-pc/normal.mod"
    run_ku migrate --stage finalize --output-dir /root/out --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: output_dir holds an export from an earlier run that lists other"* ]]
    [[ "$stderr" == *"info: removed the export in output_dir, which this write made stale"* ]]
    [ -z "$(find "$out" -mindepth 1)" ]
    # grub.cfg came from Windows, so it differed from the baseline before finalize wrote it:
    # the baseline keeps every old entry, and finalize leaves all three files to baseline.
    [[ "$stderr" == *"plan: multibootusb/grub/grub.cfg differs from the tripwire's baseline"* ]]
    [[ "$stderr" == *"the stick differs from the tripwire's baseline in files finalize does"* ]]
    [[ "$stderr" == *"changed: multibootusb/grub/grub.cfg, multibootusb/grub/i386-pc/normal"* ]]
    [[ "$stderr" == *"new: multibootusb/grub/kali.cfg. Check those files, then run 'sudo"* ]]
    [ "$(< "$ROOT/var/lib/kernel-updater/baseline")" = "$stored" ]
    private_output
}

@test "A write given --output-dir still removes the stale export in the configured output_dir" {
    local out="$ROOT/root/kernel-updater/out"
    system_done
    run_ku migrate --stage menu --deploy export --yes
    [ "$status" -eq 0 ]
    cp "$out/kali.cfg" "$out/grub.cfg" "$GRUB/"
    # check's deployed item reads the configured output_dir, whatever --output-dir says.
    run_ku migrate --stage finalize --output-dir /root/elsewhere --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: output_dir holds an export from an earlier run that lists other"* ]]
    [[ "$stderr" == *"info: removed the export in output_dir, which this write made stale"* ]]
    [ -z "$(find "$out" -mindepth 1)" ]
    private_output
}

@test "An export's output_dir is checked before the backup is sealed, and in a dry run" {
    system_done
    mkdir -p "$ROOT/root/kernel-updater/out"
    # output_dir is open to group and others.
    mkstub stat <<'EOF'
case " $* " in
    *" %u %a "*) echo "0 755" ;;
    *) echo 600 ;;
esac
EOF
    run_ku migrate --stage menu --deploy export -n
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"must be owned by root and closed to group and others"* ]]
    run_ku migrate --stage menu --deploy export --yes
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"must be owned by root and closed to group and others"* ]]
    # No sealed backup is left that a rollback would undo, as the run changed nothing.
    [ -z "$(backups)" ]
    [ -z "$(ls -A "$ROOT/root/kernel-updater/out")" ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ ! -e "$GRUB/kali.cfg" ]
}

@test "A backup's MANIFEST is synced under another name before it takes its own" {
    export SEEN="$BATS_TEST_TMPDIR/sync.seen" BACKUP_ROOT="$ROOT$BACKUPS"
    # Each sync notes which MANIFEST names the backups hold at that moment.
    mkstub sync <<'EOF'
for f in "$BACKUP_ROOT"/*/MANIFEST*; do
    [[ ! -e $f ]] || printf '%s\n' "${f##*/}" >> "$SEEN"
done
EOF
    detected
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    # A power loss before the rename leaves no MANIFEST, which --rollback passes over, and never
    # a truncated one, which would stop every --rollback.
    [ "$(grep -m 1 -x -E 'MANIFEST(\.new)?' "$SEEN")" = MANIFEST.new ]
    [ -f "$ROOT$BACKUPS/20261112T090001Z/MANIFEST" ]
    [ ! -e "$ROOT$BACKUPS/20261112T090001Z/MANIFEST.new" ]
}

@test "A write keeps the baseline entry of a file changed since, as the plan and a warning say" {
    local base="$ROOT/var/lib/kernel-updater/baseline" grub=multibootusb/grub/grub.cfg a b c
    local kali=multibootusb/grub/kali.cfg mod=multibootusb/grub/i386-pc/normal.mod
    a=$(printf 'a' | sha256sum | cut -c 1-64)
    b=$(printf 'b' | sha256sum | cut -c 1-64)
    c=$(printf 'c' | sha256sum | cut -c 1-64)
    mkdir -p "${base%/*}"
    printf '%s  %s\n' "$a" "$grub" "$a" "$mod" > "$base"
    # grub.cfg read as b, not the a stored: changed outside the tool, it keeps its entry, while
    # kali.cfg, missing and without an entry, gets one. Exported, nothing is planned.
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib 'KU_DK_DEPLOY=export; _ku_mg_drift_plan "$1" - "$2" "$3"
        KU_DK_DEPLOY=direct; _ku_mg_drift_plan "$1" - "$2" "$3"
        _ku_mg_baseline_set "$1" - "$4" "$2" "$3" "$4"; _ku_mg_drift_warn' \
        "$kali" "$grub" "$b" "$c"
    [ "$status" -eq 0 ]
    [ "$(grep -c "plan: $grub differs from the tripwire's baseline" <<< "$stderr")" -eq 1 ]
    [[ "$stderr" != *"$kali differs"* ]]
    [[ "$stderr" == *"warning: $grub differed from the tripwire's baseline before this write"* ]]
    [ "$(< "$base")" = "$(printf '%s  %s\n' "$a" "$grub" "$a" "$mod" "$c" "$kali")" ]
    # Read as stored, grub.cfg takes the new entry, and a file whose entry has no file stays.
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib '_ku_mg_baseline_set "$1" "$3" "$4" "$2" - "$4"; _ku_mg_drift_warn' \
        "$grub" "$mod" "$a" "$b"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: $mod differed from the tripwire's baseline"* ]]
    [ "$(< "$base")" = "$(printf '%s  %s\n' "$b" "$grub" "$a" "$mod" "$c" "$kali")" ]
    # Without a stored baseline, nothing drifts and nothing is recorded.
    rm "$base"
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib 'KU_DK_DEPLOY=direct; _ku_mg_drift_plan "$1" "$2"
        ! _ku_mg_baseline_set "$1" "$2" "$2"' "$grub" "$b"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ ! -e "$base" ]
}

@test "menu keeps the baseline entry of a grub.cfg changed outside the tool, and says so" {
    local base="$ROOT/var/lib/kernel-updater/baseline" stored
    system_done
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    stored=$(grep 'grub\.cfg$' "$base")
    # A change from Windows outside the Kali submenu, which the tripwire must keep reporting.
    printf 'menuentry "Other" {\r\n\ttrue\r\n}\r\n' >> "$GRUB/grub.cfg"
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: multibootusb/grub/grub.cfg differs from the tripwire's baseline"* ]]
    [[ "$stderr" == *"warning: multibootusb/grub/grub.cfg differed from the tripwire's"* ]]
    grep -q 'menuentry "Other"' "$GRUB/grub.cfg"
    # grub.cfg keeps its old entry; kali.cfg, new and without one, gets its own.
    grep -q -x -F "$stored" "$base"
    grep -q -x "$(sha256sum < "$GRUB/kali.cfg" | cut -c 1-64)  multibootusb/grub/kali.cfg" "$base"
    private_output
}

@test "A second menu run and the rollbacks keep the entries of files changed outside the tool" {
    local base="$ROOT/var/lib/kernel-updater/baseline" kali grub
    system_done
    legacy_kernel
    run_ku baseline --yes
    [ "$status" -eq 0 ]
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    kali=$(grep ' multibootusb/grub/kali\.cfg$' "$base")
    grub=$(grep ' multibootusb/grub/grub\.cfg$' "$base")
    # kali.cfg changes from Windows, then is written anew for other variants: its entry stays.
    printf '# changed\n' >> "$GRUB/kali.cfg"
    detected 'menu_variants = default'
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: multibootusb/grub/kali.cfg differs from the tripwire's baseline"* ]]
    [[ "$stderr" == *"warning: multibootusb/grub/kali.cfg differed from the tripwire's"* ]]
    grep -q -x -F "$kali" "$base"
    [ "$(sha256sum < "$GRUB/kali.cfg" | cut -c 1-64)" != "${kali:0:64}" ]
    # Its rollback writes over a kali.cfg the baseline never took, so the entry stays too.
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: multibootusb/grub/kali.cfg differs from the tripwire's baseline"* ]]
    grep -q -x -F "$kali" "$base"
    # grub.cfg changes from Windows, and the rollback of the menu run writes over it.
    printf 'menuentry "Other" {\r\n\ttrue\r\n}\r\n' >> "$GRUB/grub.cfg"
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: multibootusb/grub/grub.cfg differs from the tripwire's baseline"* ]]
    [[ "$stderr" == *"warning: multibootusb/grub/grub.cfg differed from the tripwire's"* ]]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    grep -q -x -F "$grub" "$base"
    private_output
}

@test "Backups are named in the order the stage runs happened, whatever the clock says" {
    # A run in the same second as the newest backup takes the next second.
    mkdir -p "$ROOT$BACKUPS/20261112T085959Z.rolled-back"
    export DATE_FIXED=20261112T085959Z
    # shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
    run_ku_lib '_ku_mg_backup_dir menu; printf "%s\n" "$KU_MG_STAMP"'
    [ "$status" -eq 0 ]
    [ "$output" = 20261112T090000Z ]
    [[ "$stderr" != *"the clock reads earlier"* ]]
    # Without a MANIFEST, the exit trap took that backup away again.
    [ "$(backups)" = 20261112T085959Z.rolled-back ]
    # A clock behind the newest backup, as a native boot that takes Windows' local time for
    # UTC: the runs take the seconds after it, and roll back newest first.
    mv "$ROOT$BACKUPS/20261112T085959Z.rolled-back" "$ROOT$BACKUPS/20261112T120000Z.rolled-back"
    export DATE_FIXED=""
    legacy_kernel
    detected
    run_ku migrate --stage system --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"the clock reads earlier than the newest backup, 20261112T120000Z, so"* ]]
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    [ "$(backups)" = "$(printf '%s\n' 20261112T120000Z.rolled-back 20261112T120001Z \
        20261112T120002Z)" ]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"rollback of the menu stage run 20261112T120002Z"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"rollback of the system stage run 20261112T120001Z"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
}

@test "A backup that cannot be written whole is removed again, so rollbacks stay possible" {
    system_done
    export REAL_CP
    REAL_CP=$(type -P cp)
    mkstub cp <<'EOF'
[[ ${*: -1} != */var/backups/kernel-updater/* ]] || exit 1
exec "$REAL_CP" "$@"
EOF
    run_ku migrate --stage menu --yes
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"cannot write the backup in $BACKUPS, which was removed again; nothing"* ]]
    [ -z "$(backups)" ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ ! -e "$GRUB/kali.cfg" ]
    run_ku migrate --rollback --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"holds no stage run that was not rolled back"* ]]
}

@test "A backup left without a MANIFEST, as by a kill, is passed over and set aside" {
    system_done
    legacy_kernel
    run_ku migrate --stage menu --yes
    [ "$status" -eq 0 ]
    # Every stage writes its MANIFEST before it changes anything, so this run changed nothing.
    mkdir "$ROOT$BACKUPS/20261112T095959Z"
    printf 'menu\n' > "$ROOT$BACKUPS/20261112T095959Z/stage"
    run_ku migrate --rollback --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: the backup 20261112T095959Z has no MANIFEST, as its stage run"* ]]
    [[ "$stderr" == *"plan: rollback of the menu stage run 20261112T090001Z"* ]]
    [ -d "$ROOT$BACKUPS/20261112T095959Z" ]
    run_ku migrate --rollback 20261112T095959Z --yes
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"it is passed over, and renamed to 20261112T095959Z.failed"* ]]
    run_ku migrate --rollback --yes
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/grub.before" "$GRUB/grub.cfg"
    [ "$(backups)" = "$(printf '%s\n' 20261112T090001Z.rolled-back 20261112T095959Z.failed)" ]
}

@test "migrate runs detect, system and menu in turn, and a dry run stops after detect" {
    run_ku migrate --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"dry run: the stages after detect build on what it would change"* ]]
    [ ! -e "$ROOT$CONF" ]
    run_ku migrate --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"migrate detect: appended 6 key(s)"*"migrate system: done"* ]]
    [[ "$stderr" == *"migrate menu: done"* ]]
    cmp "$FIXTURES/kali.expected.cfg" "$GRUB/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.after" "$GRUB/grub.cfg"
    [ "$(backups)" = "$(printf '%s\n' 20261112T090001Z 20261112T090002Z)" ]
    private_output
}

@test "migrate exits 77 when not root, 75 while locked, 10 when declined and 64 on usage" {
    local args
    export ID_U=1000
    for args in "--stage detect" "--stage system -n" "--stage menu" "--rollback"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku migrate $args
        [ "$status" -eq 77 ] || { printf '%s exited %s\n' "$args" "$status" >&2; return 1; }
    done
    export ID_U=0
    mkstub flock <<< 'exit 1'
    run_ku migrate --stage system --dry-run
    [ "$status" -eq 75 ]
    mkstub flock
    detected
    printf 'n\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku migrate --stage system
    [ "$status" -eq 10 ]
    [[ "$stderr" == *"declined; the system stage changed nothing"* ]]
    cmp "$BATS_TEST_TMPDIR/kernel-img.before" "$ROOT/etc/kernel-img.conf"
    [ -z "$(backups)" ]
    for args in "--stage bogus" "--rollback --stage menu" "--rollback 2026" "--deploy copy" \
        "--output-dir out" "--bogus" "extra" "--stage"; do
        # shellcheck disable=SC2086 # each case is split into its words on purpose
        run_ku migrate $args
        [ "$status" -eq 64 ] || { printf '%s exited %s\n' "$args" "$status" >&2; return 1; }
    done
    run_ku migrate --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: kernel-updater migrate "* ]]
    # 75 also means that the system, or a file on partition 1 a stage writes, changed while the
    # question waited, as for cleanup.
    local usage=${output//$'\n'/ }
    [[ "$usage" == *" 75 when another run holds the lock or the kernels, their links or a file"* ]]
    [[ "$usage" == *"on partition 1 changed while the question waited, 77 when not run"* ]]
}
