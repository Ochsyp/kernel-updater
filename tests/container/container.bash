# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater container test helpers
#
# Loaded by tests/container/*.bats, which install packages and mount over /boot: with KU_CONTAINER=1
# they run in the Kali container of ci/kali/Dockerfile and fail outside one; without it they skip.
# -------------------------------------------------------

# The dummy kernels the tests install, oldest first. 9.0.10 sorts after 9.0.2 only as a kernel
# version, not as text, so their order shows which sort ran.
V1=9.0.1+kali-amd64 V2=9.0.2+kali-amd64 V3=9.0.10+kali-amd64 V4=9.0.11+kali-amd64

# The dummy kernel packages, built once per bats run and shared by the files.
KU_DEBS="$BATS_RUN_TMPDIR/kernel-debs"

# Return 0 when the tests may change this system: KU_CONTAINER=1 inside a container.
in_test_container() {
    [[ ${KU_CONTAINER:-} == 1 ]] && [[ -e /.dockerenv || -e /run/.containerenv ]]
}

# Skip the test unless KU_CONTAINER=1, and fail it when that is set on a system that is no
# container, so the suite never changes a real installation. Call it first in setup().
container_only() {
    [[ ${KU_CONTAINER:-} == 1 ]] || skip "runs only in the Kali test container (KU_CONTAINER=1)"
    if ! in_test_container; then
        printf 'KU_CONTAINER=1 outside a container: nothing on this system is changed\n' >&2
        return 1
    fi
}

# Prepare the container once per file: a tmpfs on /boot, which stands in for the stick's
# separate /boot, and the dummy kernel packages. Does nothing outside the test container.
container_setup_file() {
    local version
    in_test_container || return 0
    mkdir -p /boot
    mountpoint -q /boot || mount -t tmpfs -o mode=0755 tmpfs /boot
    for version in "$V1" "$V2" "$V3" "$V4"; do
        build_kernel "$version"
    done
}

# Build the dummy package linux-image-VERSION into KU_DEBS unless it is there. It ships
# /boot/vmlinuz-VERSION and /boot/initrd.img-VERSION, and its postinst and postrm call
# linux-update-symlinks as a real kernel's do; KU_TEST_POSTINST_FAIL=1 makes the postinst fail.
build_kernel() {
    local version=$1 dir="$KU_DEBS/build-$1" script
    if compgen -G "$KU_DEBS/linux-image-${version}_*.deb" > /dev/null; then
        return 0
    fi
    mkdir -p "$dir"
    IFS= read -r -d '' script <<'EOF' || true
#!/bin/sh
# Points the default links at this kernel on configure, as a real kernel's postinst does.
set -e
version=@VERSION@
[ "$1" = configure ] || exit 0
if [ -n "${KU_TEST_POSTINST_FAIL:-}" ]; then
    echo "postinst of $version fails on request" >&2
    exit 1
fi
if [ -z "$2" ]; then change=install; else change=upgrade; fi
linux-update-symlinks "$change" "$version" "/boot/vmlinuz-$version"
EOF
    printf '%s' "${script//@VERSION@/$version}" > "$dir/postinst"
    IFS= read -r -d '' script <<'EOF' || true
#!/bin/sh
# Moves the default links off this kernel on removal, as a real kernel's postrm does.
set -e
version=@VERSION@
if [ "$1" != upgrade ] && command -v linux-update-symlinks > /dev/null; then
    linux-update-symlinks remove "$version" "/boot/vmlinuz-$version"
fi
EOF
    printf '%s' "${script//@VERSION@/$version}" > "$dir/postrm"
    {
        printf 'Section: kernel\nPriority: optional\nPackage: linux-image-%s\n' "$version"
        printf 'Version: %s-1\n' "${version%%+*}"
        printf 'Maintainer: kernel-updater tests <tests@example.org>\n'
        printf 'Postinst: %s/postinst\nPostrm: %s/postrm\n' "$dir" "$dir"
        printf 'File: /boot/vmlinuz-%s\n dummy kernel %s\n' "$version" "$version"
        printf 'File: /boot/initrd.img-%s\n dummy initrd %s\n' "$version" "$version"
        printf 'Description: dummy kernel %s for the kernel-updater container tests\n' "$version"
    } > "$dir/control"
    # equivs-build leaves the package in TMPDIR, or without one in the current directory.
    if ! (cd "$dir" && TMPDIR="$dir" equivs-build control > build.log 2>&1); then
        cat "$dir/build.log" >&2
        return 1
    fi
    mv "$dir"/linux-image-"$version"_*.deb "$KU_DEBS/"
}

# Build the dummy package NAME into KU_DEBS from the equivs control LINES, which give at least
# its Version, unless it is there.
build_package() {
    local name=$1 dir="$KU_DEBS/build-$1"
    shift
    if compgen -G "$KU_DEBS/${name}_*.deb" > /dev/null; then
        return 0
    fi
    mkdir -p "$dir"
    {
        printf 'Section: misc\nPriority: optional\nPackage: %s\n' "$name"
        printf 'Maintainer: kernel-updater tests <tests@example.org>\n'
        printf '%s\n' "$@"
        printf 'Description: dummy %s for the kernel-updater container tests\n' "$name"
    } > "$dir/control"
    if ! (cd "$dir" && TMPDIR="$dir" equivs-build control > build.log 2>&1); then
        cat "$dir/build.log" >&2
        return 1
    fi
    mv "$dir/${name}"_*.deb "$KU_DEBS/"
}

# Build the dummy package linux-image-VERSION with a real kernel's maintainer scripts, as
# image.{preinst,postinst,prerm,postrm}.in in Debian's linux source has them: preinst marks a
# fresh install, postinst and postrm move the links with linux-update-symlinks, and each runs
# its hooks in /etc/kernel through linux-run-hooks. It ships /boot/initrd.img-VERSION, standing
# in for the one initramfs-tools builds, and the vmlinuz as LAYOUT says: boot, the default, ships
# /boot/vmlinuz-VERSION; split puts that in linux-binary-VERSION, which it depends on, as Kali's
# kernels from 6.19 to 7.1 do; usrlib ships /usr/lib/modules/VERSION/vmlinuz, which linux-base's
# 00-legacy-boot hook copies to /boot, as Debian's kernels from 7.2 on do.
build_hooked_kernel() {
    local version=$1 layout=${2:-boot} dir="$KU_DEBS/scripts-$1" name script
    local -a lines=()
    mkdir -p "$dir"
    for name in preinst postinst prerm postrm; do
        IFS= read -r -d '' script <<'EOF' || true
#!/bin/sh
set -e
version=@VERSION@
image_path=/boot/vmlinuz-$version
case @SCRIPT@ in
    preinst)
        [ "$1" != abort-upgrade ] || exit 0
        if [ "$1" = install ]; then
            mkdir -p "/lib/modules/$version"
            touch "/lib/modules/$version/.fresh-install"
        fi
        ;;
    postinst)
        [ "$1" = configure ] || exit 0
        if [ -f "/lib/modules/$version/.fresh-install" ]; then
            change=install
        else
            change=upgrade
        fi
        linux-update-symlinks "$change" "$version" "$image_path"
        rm -f "/lib/modules/$version/.fresh-install"
        ;;
    prerm)
        [ "$1" = remove ] || exit 0
        ;;
    postrm)
        rm -f "/lib/modules/$version/.fresh-install"
        if [ "$1" != upgrade ] && command -v linux-update-symlinks > /dev/null; then
            linux-update-symlinks remove "$version" "$image_path"
        fi
        command -v linux-run-hooks > /dev/null || exit 0
        ;;
esac
linux-run-hooks image @SCRIPT@ "$version" "$image_path" -- "$@"
EOF
        script=${script//@VERSION@/$version}
        printf '%s' "${script//@SCRIPT@/$name}" > "$dir/$name"
    done
    lines=("Version: ${version%%+*}-1" "Preinst: $dir/preinst" "Postinst: $dir/postinst"
        "Prerm: $dir/prerm" "Postrm: $dir/postrm")
    case $layout in
        split)
            build_package "linux-binary-$version" "Version: ${version%%+*}-1" \
                "File: /boot/vmlinuz-$version" " dummy kernel $version"
            lines+=("Depends: linux-binary-$version")
            ;;
        usrlib) lines+=("File: /usr/lib/modules/$version/vmlinuz" " dummy kernel $version") ;;
        *) lines+=("File: /boot/vmlinuz-$version" " dummy kernel $version") ;;
    esac
    lines+=("File: /boot/initrd.img-$version" " dummy initrd $version")
    build_package "linux-image-$version" "${lines[@]}"
}

# Print the path of the dummy package of kernel VERSION.
kernel_deb() {
    local debs=("$KU_DEBS"/linux-image-"$1"_*.deb)
    printf '%s\n' "${debs[0]}"
}

# Print the path of the dummy package NAME.
package_deb() {
    local debs=("$KU_DEBS/$1"_*.deb)
    printf '%s\n' "${debs[0]}"
}

# Print package NAME's state as ${db:Status-Abbrev} gives it, such as ii or iF, without
# spaces, or nothing when dpkg does not know it.
package_state() {
    local state
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} field itself
    state=$(dpkg-query -W -f '${db:Status-Abbrev}' "$1" 2> /dev/null) || state=""
    printf '%s' "${state// /}"
}

# The ext4 image the hook tests mount on /boot through a loop device.
BOOT_IMAGE="$BATS_RUN_TMPDIR/boot.img"

# Unmount everything mounted on /boot and detach BOOT_IMAGE's loop devices.
unmount_boot() {
    local dev
    while mountpoint -q /boot; do
        umount /boot
    done
    for dev in $(losetup --list --noheadings --output NAME --associated "$BOOT_IMAGE" \
        2> /dev/null); do
        losetup --detach "$dev"
    done
}

# Unmount /boot, empty the directory under it and write a fresh ext4 filesystem with UUID
# into BOOT_IMAGE.
make_boot_image() {
    unmount_boot
    find /boot -mindepth 1 -delete
    truncate -s 16M "$BOOT_IMAGE"
    mkfs.ext4 -q -F -U "$1" "$BOOT_IMAGE"
}

# Mount BOOT_IMAGE on /boot through a loop device, as the stick's unlocked /boot is. Makes the
# loop device's node when the container's /dev lacks it.
mount_boot_image() {
    local dev
    dev=$(losetup --find)
    [[ -b $dev ]] || mknod -m 0660 "$dev" b 7 "${dev#/dev/loop}"
    losetup "$dev" "$BOOT_IMAGE"
    mount "$dev" /boot
}

# Install the dummy kernels VERSION... with dpkg, one after the other in the order given.
install_kernels() {
    local version
    for version in "$@"; do
        dpkg -i "$(kernel_deb "$version")"
    done
}

# Purge every dummy kernel package, whatever its state, the split ones, any headers and
# ku-test-dkms, which depends on headers, included, empty /boot and cleanup's quarantine, remove
# the default links from / and write /etc/kernel-img.conf with link_in_boot = VALUE, yes or no.
reset_system() {
    local -a packages=()
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
    mapfile -t packages < <(dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}\n' \
        'linux-image-9.*' 'linux-binary-9.*' 'linux-modules-9.*' 'linux-base-9.*' \
        'linux-headers-9.*' ku-test-dkms 2> /dev/null | awk '$1 !~ /^.n$/ { print $2 }')
    if (( ${#packages[@]} )); then
        printf '%s install\n' "${packages[@]}" | dpkg --set-selections
        dpkg --force-hold --force-remove-reinstreq --purge "${packages[@]}"
    fi
    find /boot -mindepth 1 -delete
    if [[ -d /var/lib/kernel-updater/quarantine ]]; then
        find /var/lib/kernel-updater/quarantine -mindepth 1 -delete
    fi
    rm -f /vmlinuz /vmlinuz.old /initrd.img /initrd.img.old
    printf 'link_in_boot = %s\n' "$1" > /etc/kernel-img.conf
}

# Fail unless /boot/vmlinuz and /boot/initrd.img point, relative, at the files of kernel NEW,
# and vmlinuz.old and initrd.img.old at those of kernel OLD.
assert_links() {
    local got
    got=$(readlink /boot/vmlinuz /boot/vmlinuz.old /boot/initrd.img /boot/initrd.img.old) || true
    if [[ $got != "vmlinuz-$1"$'\n'"vmlinuz-$2"$'\n'"initrd.img-$1"$'\n'"initrd.img-$2" ]]; then
        printf 'expected the links on %s and %s, got:\n%s\n' "$1" "$2" "$got" >&2
        return 1
    fi
}

# Leave COUNT files, and nothing else, in the directory the tmpfs on /boot hides. They are
# written through a bind mount of / that leaves the tmpfs out and goes afterwards.
shadow_boot() {
    local view i
    view=$(mktemp -d)
    mount --bind / "$view"
    find "$view/boot" -mindepth 1 -delete
    for (( i = 0; i < $1; i++ )); do
        : > "$view/boot/vmlinuz-shadowed-$i"
    done
    umount "$view"
    rmdir "$view"
}

# Run kernel-updater check --porcelain ARGS on the container itself, with the stubs first on
# PATH and TMPDIR in the test's temp directory, which check must leave alone, through bats' run
# with separate stderr.
run_container_check() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" \
        bash "$REPO_DIR/bin/kernel-updater" check --porcelain "$@"
}

# Run kernel-updater cleanup ARGS on the container itself, with the stubs first on PATH and TMPDIR
# in the test's temp directory, through bats' run with separate stderr. KU_TEST=1 lets
# SOURCE_DATE_EPOCH through to apt: as for a reproducible build, apt then leaves the running
# kernel, the CI host's, out of the kernels it keeps from autoremoval.
run_container_cleanup() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" KU_TEST=1 \
        SOURCE_DATE_EPOCH=1700000000 bash "$REPO_DIR/bin/kernel-updater" cleanup "$@"
}
