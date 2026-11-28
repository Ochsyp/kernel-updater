# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater system probes
#
# Read-only probes of the kernel packages, /boot, its links and LUKS container, kernel-img.conf,
# crypttab, fstab, the initrds and grub-pc for check. Defines functions only.
# -------------------------------------------------------

# Each probe prints tab-separated fields, and - for a field that is empty, so that a field
# split on tabs never shifts. Probes return 0 unless their message says otherwise.

# Print VERSION<TAB>STATE per kernel version, oldest first, from its versioned linux-image,
# -binary, -modules and -base packages, -unsigned builds included and -dbg and -dbgsym left out.
# Returns 1 when dpkg-query fails and 2 when neither linux-version nor sort -V orders them.
ku_probe_kernels() {
    local out status=0 name abbrev kind version rank versions sorted
    local -A state=() worst=()
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
    out=$(dpkg-query -W -f '${binary:Package}\t${db:Status-Abbrev}\t${Version}\n' \
        'linux-image-*' 'linux-binary-*' 'linux-modules-*' 'linux-base-*' 2> /dev/null) || status=$?
    # dpkg-query exits 1 when a pattern matches no package, and still lists the others.
    (( status <= 1 )) || return 1
    while IFS=$'\t' read -r name abbrev _; do
        _ku_probe_kernel_name "$name" kind version || continue
        [[ $kind =~ ^(image|binary|modules|base)$ ]] || continue
        abbrev=${abbrev// /}
        # STATE is the one that matters most: a transitional state such as iU or iF, then hi,
        # then ii, and rc only when every package is rc: when linux-image-V-unsigned replaces
        # linux-image-V, dpkg keeps the latter as rc while V stays installed.
        case $abbrev in
            ?n) continue ;;
            ?c) rank=0 ;;
            hi) rank=2 ;;
            ?i) rank=1 ;;
            *) rank=3 ;;
        esac
        if (( rank > ${worst[$version]:--1} )); then
            worst[$version]=$rank
            state[$version]=$abbrev
        fi
    done <<< "$out"
    (( ${#state[@]} )) || return 0
    versions=$(printf '%s\n' "${!state[@]}")
    # linux-version orders the versions as dpkg does; sort -V comes close and stands in for it.
    if ! command -v linux-version > /dev/null; then
        sorted=$(sort -V <<< "$versions") || return 2
    elif ! sorted=$(linux-version sort <<< "$versions"); then
        ku_log warning "linux-version cannot sort the kernel versions; sort -V does instead"
        sorted=$(sort -V <<< "$versions") || return 2
    fi
    while IFS= read -r version; do
        if [[ -n ${state[$version]+set} ]]; then
            printf '%s\t%s\n' "$version" "${state[$version]}"
        fi
    done <<< "$sorted"
}

# Print NAME<TAB>STATE<TAB>VERSION<TAB>KIND<TAB>RELEASE for each versioned kernel package dpkg
# knows in a state other than not-installed, in dpkg's order: STATE is ${db:Status-Abbrev}
# without blanks, such as rc, VERSION the package's version, or - without one, and KIND and
# RELEASE what _ku_probe_kernel_name reads from the name. Metapackages, linux-base,
# linux-config-X.Y, linux-libc-dev and firmware are left out. Returns 1 when dpkg-query fails.
ku_probe_kernel_packages() {
    local out status=0 name abbrev version kind release
    # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
    out=$(dpkg-query -W -f '${binary:Package}\t${db:Status-Abbrev}\t${Version}\n' \
        'linux-image-*' 'linux-binary-*' 'linux-modules-*' 'linux-base-*' 'linux-headers-*' \
        'linux-kbuild-*' 2> /dev/null) || status=$?
    # dpkg-query exits 1 when a pattern matches no package, and still lists the others.
    (( status <= 1 )) || return 1
    while IFS=$'\t' read -r name abbrev version; do
        _ku_probe_kernel_name "$name" kind release || continue
        abbrev=${abbrev// /}
        [[ $abbrev != ?n ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$abbrev" "${version:--}" "$kind" "$release"
    done <<< "$out"
}

# Set the variables named KIND_VAR and RELEASE_VAR from the package NAME, whose architecture
# after a colon does not count, and return 0 when it names a versioned kernel package: image,
# binary, modules, base or headers, with the kernel release in the name, an -unsigned build's
# that of the build it stands in for; common, the headers the flavours of one ABI share, as in
# linux-headers-6.12.38+kali-common, and kbuild, their build tools, each with the ABI in the
# name; or dbg for a -dbg or -dbgsym build, with its kernel's release. The release must have
# the shape of one. Returns 1, both variables empty, for any other name. Shared by
# ku_probe_kernels and ku_probe_kernel_packages.
_ku_probe_kernel_name() {
    local pk_name=${1%%:*} pk_kind="" pk_release=""
    if [[ $pk_name =~ ^linux-(image|binary|modules|base|headers)-([0-9].*)$ ]]; then
        pk_kind=${BASH_REMATCH[1]} pk_release=${BASH_REMATCH[2]%-unsigned}
        if [[ $pk_release =~ ^(.+)-(dbg|dbgsym)$ ]]; then
            pk_kind=dbg pk_release=${BASH_REMATCH[1]%-unsigned}
        elif [[ $pk_kind == headers && $pk_release =~ ^(.+)-common(-rt)?$ ]]; then
            pk_kind=common pk_release=${BASH_REMATCH[1]}
        fi
    elif [[ $pk_name =~ ^linux-kbuild-([0-9].*)$ ]]; then
        pk_kind=kbuild pk_release=${BASH_REMATCH[1]}
    fi
    if [[ -z $pk_kind ]] || ! ku_valid_release "$pk_release"; then
        pk_kind="" pk_release=""
    fi
    printf -v "$2" '%s' "$pk_kind"
    printf -v "$3" '%s' "$pk_release"
    [[ -n $pk_kind ]]
}

# Print SOURCE<TAB>FSTYPE<TAB>UUID of the filesystem mounted at /boot, the topmost one when
# several are, or nothing when /boot is not a mount point or findmnt cannot read the mounts.
ku_probe_boot_mount() {
    local boot out source fstype uuid
    boot=$(ku_path /boot)
    # Looking inside /boot first mounts it when it is an automount nothing has used yet.
    [[ -d $boot/. ]] || :
    out=$(findmnt -r -n -o SOURCE,FSTYPE,UUID --mountpoint "$boot" 2> /dev/null) || true
    [[ -n $out ]] || return 0
    read -r source fstype uuid <<< "${out##*$'\n'}"
    # findmnt takes the UUID from udev, which a chroot or container may lack; as root, blkid
    # reads it from the device itself.
    if [[ -z $uuid && $source == /dev/?* ]]; then
        uuid=$(blkid -p -s UUID -o value -- "$source" 2> /dev/null) || uuid=""
    fi
    printf '%s\t%s\t%s\n' "${source:--}" "${fstype:--}" "${uuid:--}"
}

# Print do_symlinks, link_in_boot and image_dest as linux-update-symlinks reads them from
# /etc/kernel-img.conf, or from FILE, such as a copy of it, NAME<TAB>VALUE: booleans as 1 or 0,
# and image_dest, the links' directory, without a trailing slash. Follows read_kernelimg_conf in
# linux-base's DebianLinux.pm.
ku_probe_kernel_img() {
    local file line name value bool do_symlinks=1 link_in_boot=0 image_dest=/
    file=${1:-$(ku_path /etc/kernel-img.conf)}
    if [[ -f $file && -r $file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%%#*}
            [[ $line =~ ^[[:space:]]*([[:alnum:]_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
            name=${BASH_REMATCH[1],,}
            value=${BASH_REMATCH[2]}
            # Any other value leaves the option as it was; linux-base only warns about it.
            bool=""
            if [[ ${value,,} =~ ^(yes|true|1)[[:space:]]*$ ]]; then
                bool=1
            elif [[ ${value,,} =~ ^(no|false|0)[[:space:]]*$ ]]; then
                bool=0
            fi
            case $name in
                do_symlinks) do_symlinks=${bool:-$do_symlinks} ;;
                link_in_boot) link_in_boot=${bool:-$link_in_boot} ;;
                image_dest)
                    [[ $value =~ ^([^[:space:]]*) ]]
                    image_dest=${BASH_REMATCH[1]}
                    ;;
            esac
        done < "$file"
    fi
    if (( link_in_boot )); then
        image_dest=/boot
    fi
    while [[ $image_dest == ?*/ ]]; do
        image_dest=${image_dest%/}
    done
    printf 'do_symlinks\t%s\nlink_in_boot\t%s\nimage_dest\t%s\n' "$do_symlinks" "$link_in_boot" \
        "${image_dest:-/}"
}

# Print NAME<TAB>TARGET<TAB>RELATIVE<TAB>RESOLVES for vmlinuz, vmlinuz.old, initrd.img and
# initrd.img.old in /boot. TARGET is - when NAME is not a symlink; RELATIVE is 1 for a relative
# target; RESOLVES is 1 when the target is a non-empty regular file directly in /boot.
ku_probe_boot_links() {
    local boot name target file relative resolves
    boot=$(ku_path /boot)
    for name in vmlinuz vmlinuz.old initrd.img initrd.img.old; do
        target="" relative=0 resolves=0
        if [[ -L $boot/$name ]]; then
            target=$(readlink -- "$boot/$name") || target=""
        fi
        if [[ -n $target ]]; then
            file=${target#/boot/}
            if [[ $target != /* ]]; then
                relative=1
                file=$target
            fi
            # GRUB follows the links on the /boot filesystem itself, so the file must be there.
            if [[ $file != */* && ! -L $boot/$file && -f $boot/$file && -s $boot/$file ]]; then
                resolves=1
            fi
        fi
        printf '%s\t%s\t%s\t%s\n' "$name" "${target:--}" "$relative" "$resolves"
    done
}

# Print TARGET<TAB>SOURCE<TAB>KEYFILE<TAB>OPTIONS for each /etc/crypttab entry. KEYFILE is -
# when the entry names none, and OPTIONS - when it lists none.
ku_probe_crypttab() {
    local file target source key options rest
    file=$(ku_path /etc/crypttab)
    [[ -f $file ]] || return 0
    while read -r target source key options rest || [[ -n $target ]]; do
        [[ -n $target && $target != \#* ]] || continue
        if [[ -z $key || $key == none ]]; then
            key=-
        fi
        printf '%s\t%s\t%s\t%s\n' "$target" "${source:--}" "$key" "${options:--}"
    done < "$file"
}

# Print the names of the dm-crypt mappings that the initramfs unlocks, one per line: those under
# the root filesystem, and those under each partition in /proc/swaps, one of which initramfs-tools
# may pick as the resume device; a swap file lies on / already. lsblk -s lists the devices below
# each. Returns 1 when it cannot tell: findmnt or lsblk fails, as in a chroot without udev, / is
# no device, as in a container, or /proc/swaps cannot be read.
ku_probe_root_crypt_names() {
    local source out name type file
    local -a devices=()
    source=$(findmnt -n -r -o SOURCE --mountpoint / 2> /dev/null) || return 1
    source=${source%%[[:space:]]*}
    # A btrfs subvolume shows as DEVICE[/SUBVOLUME].
    source=${source%%\[*}
    [[ $source == /dev/?* ]] || return 1
    devices=("$source")
    file=$(ku_path /proc/swaps)
    if [[ -e $file ]]; then
        [[ -r $file ]] || return 1
        while read -r name type _; do
            if [[ $type == partition && $name == /dev/?* ]]; then
                devices+=("$name")
            fi
        done < "$file"
    fi
    for source in "${devices[@]}"; do
        out=$(lsblk -s -n -r -o NAME,TYPE -- "$source" 2> /dev/null) || return 1
        [[ -n $out ]] || return 1
        while read -r name type _; do
            if [[ $type == crypt ]]; then
                printf '%s\n' "${name##*/}"
            fi
        done <<< "$out"
    done
}

# Print SOURCE<TAB>MOUNTPOINT<TAB>TYPE for each /etc/fstab entry.
ku_probe_fstab() {
    local file source mountpoint type rest
    file=$(ku_path /etc/fstab)
    [[ -f $file ]] || return 0
    while read -r source mountpoint type rest || [[ -n $source ]]; do
        [[ -n $source && $source != \#* ]] || continue
        printf '%s\t%s\t%s\n' "$source" "${mountpoint:--}" "${type:--}"
    done < "$file"
}

# Print MODULES<TAB>CRYPTSETUP<TAB>CRYPTTAB<TAB>KEYFILES, each 1 or 0, for the initrd FILE of
# kernel VERSION: whether lsinitramfs lists VERSION's module tree, the cryptsetup binary, the
# cryptroot configuration and files under cryptroot/keyfiles. Returns 1 when lsinitramfs fails.
ku_probe_initrd() {
    local listing
    listing=$(lsinitramfs "$1" 2> /dev/null) || return 1
    awk -v version="$2" '
        BEGIN { keydir = "cryptroot/keyfiles/" }
        { sub(/^\.?\//, "") }
        $0 == "usr/lib/modules/" version || index($0, "usr/lib/modules/" version "/") == 1 ||
            $0 == "lib/modules/" version || index($0, "lib/modules/" version "/") == 1 {
            modules = 1
        }
        $0 == "usr/sbin/cryptsetup" || $0 == "sbin/cryptsetup" { cryptsetup = 1 }
        $0 == "cryptroot/crypttab" { crypttab = 1 }
        index($0, keydir) == 1 && length($0) > length(keydir) { keyfiles = 1 }
        END { printf "%d\t%d\t%d\t%d\n", modules, cryptsetup, crypttab, keyfiles }
    ' <<< "$listing"
}

# Print the LUKS header of the container behind SOURCE, a /dev/mapper path from findmnt, as
# version<TAB>N, uuid<TAB>UUID and keyslot<TAB>N<TAB>PBKDF per keyslot in use. Returns 2 when
# SOURCE is no open LUKS mapping, 1 when the header is unreadable, 3 when cryptsetup is missing.
ku_probe_boot_luks() {
    local out line type="" device="" version="" uuid="" section="" slot=-
    # LUKS1 marks each keyslot in use, all PBKDF2; LUKS2 lists them, with their PBKDF, under
    # Keyslots.
    local luks1_slot='^Key Slot ([0-9]+): ENABLED' title='^[A-Z][A-Za-z ]*:$'
    local luks2_slot='^[[:space:]]+([0-9]+):[[:space:]]'
    local kdf='^[[:space:]]+PBKDF:[[:space:]]*([^[:space:]]+)'
    [[ $1 == /dev/mapper/?* ]] || return 2
    command -v cryptsetup > /dev/null || return 3
    out=$(cryptsetup status "${1#/dev/mapper/}" 2> /dev/null) || return 2
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]+type:[[:space:]]+([^[:space:]]+) ]]; then
            type=${BASH_REMATCH[1]}
        elif [[ $line =~ ^[[:space:]]+device:[[:space:]]+([^[:space:]]+) ]]; then
            device=${BASH_REMATCH[1]}
        fi
    done <<< "$out"
    [[ $type == LUKS* && -n $device ]] || return 2
    out=$(cryptsetup luksDump "$device" 2> /dev/null) || return 1
    while IFS= read -r line; do
        if [[ $line =~ ^Version:[[:space:]]*([0-9]+) ]]; then
            version=${BASH_REMATCH[1]}
        elif [[ $line =~ ^UUID:[[:space:]]*([^[:space:]]+) ]]; then
            uuid=${BASH_REMATCH[1],,}
        elif [[ $line =~ $luks1_slot ]]; then
            printf 'keyslot\t%s\tpbkdf2\n' "${BASH_REMATCH[1]}"
        elif [[ $line =~ $title ]]; then
            section=$line
        elif [[ $section == Keyslots: && $line =~ $luks2_slot ]]; then
            slot=${BASH_REMATCH[1]}
        elif [[ $section == Keyslots: && $line =~ $kdf ]]; then
            printf 'keyslot\t%s\t%s\n' "$slot" "${BASH_REMATCH[1]}"
        fi
    done <<< "$out"
    [[ -n $version ]] || return 1
    printf 'version\t%s\nuuid\t%s\n' "$version" "${uuid:--}"
}

# Print the features of the ext filesystem on DEVICE, one per line, from the "Filesystem
# features" line of dumpe2fs -h. Returns 1 when dumpe2fs cannot read DEVICE.
ku_probe_ext_features() {
    local out line
    local -a features=()
    out=$(dumpe2fs -h "$1" 2> /dev/null) || return 1
    while IFS= read -r line; do
        if [[ $line == "Filesystem features:"* ]]; then
            read -r -a features <<< "${line#*:}"
            printf '%s\n' "${features[@]}"
            return 0
        fi
    done <<< "$out"
    return 1
}

# Print how many devices grub-pc's debconf answer grub-pc/install_devices names, or nothing
# when debconf holds no such answer, as when grub-pc is not installed. Never prints a device.
# Returns 1 when debconf-show fails.
ku_probe_grub_pc() {
    local out line count=0 device
    local -a devices=()
    out=$(debconf-show grub-pc 2> /dev/null) || return 1
    while IFS= read -r line; do
        [[ $line =~ ^[*[:space:]]+grub-pc/install_devices:(.*)$ ]] || continue
        IFS=, read -r -a devices <<< "${BASH_REMATCH[1]}"
        for device in "${devices[@]}"; do
            if [[ $device =~ [^[:space:]] ]]; then
                count=$((count + 1))
            fi
        done
        printf '%s\n' "$count"
        return 0
    done <<< "$out"
}

# Exit 75 while apt or dpkg holds its frontend or database lock, naming the holder and saying
# to run WHAT again once it is done, and 3 when ku_probe_dpkg_busy cannot tell. Returns 0 while
# neither lock is held.
ku_require_dpkg_idle() {
    local holder status=0
    holder=$(ku_probe_dpkg_busy) || status=$?
    case $status in
        0)
            ku_die "$KU_EX_BUSY" "apt or dpkg is running: $holder; run $1 again once it is" \
                "done; nothing was changed"
            ;;
        1) ;;
        *)
            ku_die "$KU_EX_REFUSED" "cannot read /proc/locks or the inode of a lock file of" \
                "dpkg, so $1 cannot tell whether apt or dpkg is running; nothing was changed"
            ;;
    esac
}

# Print who holds dpkg's frontend lock or its database lock, as "PID 4242 (apt-get) holds
# /var/lib/dpkg/lock-frontend", and return 0 while one of them is held, 1 while neither is, and
# 2 when that cannot be told: /proc/locks or a lock file's inode cannot be read. apt and dpkg
# take these locks with fcntl, which flock cannot test, so the inodes of the lock files are
# looked up in /proc/locks. The device is not compared, as an overlay filesystem may show
# another one there than stat does: a lock on a file of the same inode number elsewhere only
# makes the caller refuse once too often.
ku_probe_dpkg_busy() {
    local name file inode locks pid comm holder
    local -a fields=()
    local -A held=()
    for name in lock-frontend lock; do
        file=$(ku_path "/var/lib/dpkg/$name")
        # apt and dpkg create the file as they lock it, so one that is missing is not held.
        [[ -e $file || -L $file ]] || continue
        inode=$(stat -L -c %i -- "$file" 2> /dev/null) || return 2
        [[ $inode =~ ^[0-9]+$ ]] || return 2
        held[$inode]=/var/lib/dpkg/$name
    done
    file=$(ku_path /proc/locks)
    if [[ ! -r $file ]] || ! { locks=$(< "$file"); } 2> /dev/null; then
        return 2
    fi
    # Each line is ID: TYPE MODE ACCESS PID MAJOR:MINOR:INODE START END, and a process that
    # waits for a lock follows its holder, with "->" after the ID.
    while read -r -a fields; do
        if [[ ${fields[1]:-} == '->' ]]; then
            fields=("${fields[0]}" "${fields[@]:2}")
        fi
        [[ ${fields[5]:-} =~ ^[0-9A-Fa-f]+:[0-9A-Fa-f]+:([0-9]+)$ ]] || continue
        file=${held[${BASH_REMATCH[1]}]:-}
        [[ -n $file ]] || continue
        pid=${fields[4]}
        if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
            holder="PID $pid"
            comm=""
            { comm=$(< "$(ku_path "/proc/$pid/comm")"); } 2> /dev/null || comm=""
            # A process can give itself any name, so only plain characters are shown.
            comm=${comm//[^A-Za-z0-9._+:@ -]/?}
            if [[ -n $comm ]]; then
                holder+=" (${comm:0:32})"
            fi
        else
            holder="a process whose PID /proc/locks does not show"
        fi
        printf '%s holds %s' "$holder" "$file"
        return 0
    done <<< "$locks"
    return 1
}
