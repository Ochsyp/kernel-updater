# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater check
#
# The check command: reports, item by item, whether /boot, its links and LUKS container, the
# kernels, their initrds, fstab, crypttab and grub-pc keep the Kali entries bootable.
# -------------------------------------------------------

# The results in the order the items ran: status (ok, warn, fail or skip), item and detail.
KU_CHECK_STATUS=() KU_CHECK_ITEM=() KU_CHECK_DETAIL=()

# What the probes found, shared by the items and set by _ku_check_collect: the /boot mount,
# the links' directory, the kernels and their states (KU_CK_KERNELS is ku_probe_kernels'
# status: 0 read, 1 unreadable, 2 unsorted), the running release, the /boot links and the LUKS
# header (KU_CK_LUKS is ku_probe_boot_luks' status: 0 read, 1 unreadable, 2 none, 3 no cryptsetup).
KU_CK_MOUNTED=0 KU_CK_SOURCE="" KU_CK_FSTYPE="" KU_CK_FS_UUID="" KU_CK_DO_SYMLINKS=1
KU_CK_LINK_DIR=/ KU_CK_KERNELS=0 KU_CK_RUNNING="" KU_CK_LUKS=2 KU_CK_LUKS_VERSION=""
KU_CK_LUKS_UUID="" KU_CK_VERSIONS=() KU_CK_LUKS_KDFS=()
declare -gA KU_CK_STATE=() KU_CK_TARGET=() KU_CK_RELATIVE=() KU_CK_RESOLVES=()

# The shadow scan's private directory in /run, and 1 while a bind mount of / may be at its
# root/.
KU_CK_SCAN_DIR="" KU_CK_SCAN_MOUNTED=0

# The incompatible ext features dumpe2fs names, each with the oldest GRUB that reads or safely
# ignores it, as 204 for 2.04, or 0 when none does. Some e2fsprogs releases spell large_dir
# largedir. GRUB never looks at compatible or read-only compatible features.
declare -gA KU_CK_EXT_INCOMPAT=([filetype]=202 [extent]=202 [flex_bg]=202 [meta_bg]=202
    [64bit]=202 [needs_recovery]=202 [mmp]=202 [encrypt]=204 [metadata_csum_seed]=212
    [large_dir]=212 [largedir]=212 [compression]=0 [journal_dev]=0 [ea_inode]=0 [dirdata]=0
    [inline_data]=0 [casefold]=0)

# Print the check command's usage on stdout.
ku_check_usage() {
    cat << 'EOF'
Usage: kernel-updater check [--strict] [--porcelain]

Reports whether the system keeps the stick's Kali entries bootable: /boot, its links and LUKS
container, the kernel packages, the initrds, fstab, crypttab and grub-pc. Runs as root and
changes nothing; a read-only bind mount of / looks under the /boot mount point and is removed
before the command exits. Results name kinds and counts, never identifiers.

  --strict     exit 2 on warnings too
  --porcelain  print ITEM, STATUS and DETAIL, tab-separated

Each item is ok, warn, fail or skip. Exits 0 when no item fails, 2 when one does (or, with
--strict, warns), 64 on a usage error and 77 when not run as root.
EOF
}

# Run every item and print one result per item on stdout, then a summary on stderr. Exits 0
# when no item fails (or, with --strict, warns), 2 when one does, 64 on a usage error and 77
# when not run as root. Changes nothing but the shadow scan's bind mount, which it removes.
ku_cmd_check() {
    local strict=0 status
    local -A totals=([ok]=0 [warn]=0 [fail]=0 [skip]=0)
    while (( $# )); do
        case $1 in
            --strict) strict=1; shift ;;
            --porcelain) KU_PORCELAIN=1; shift ;;
            -h | --help) ku_check_usage; exit 0 ;;
            -*) ku_usage_error "check: unknown option $1" ;;
            *) ku_usage_error "check: unexpected argument '$1'" ;;
        esac
    done
    ku_require_root
    ku_load_config
    _ku_check_collect
    _ku_check_boot_mounted
    _ku_check_boot_identity
    _ku_check_boot_shadowed
    _ku_check_kernel_img
    _ku_check_boot_links
    _ku_check_stale_root_links
    _ku_check_kernels
    _ku_check_reboot_pending
    _ku_check_initrd
    _ku_check_boot_luks
    _ku_check_boot_ext
    _ku_check_fstab_crypttab
    _ku_check_grub_pc
    _ku_check_print
    for status in "${KU_CHECK_STATUS[@]}"; do
        totals[$status]=$((totals[$status] + 1))
    done
    ku_log info "check: ${#KU_CHECK_STATUS[@]} item(s): ${totals[ok]} ok, ${totals[warn]} warn," \
        "${totals[fail]} fail, ${totals[skip]} skip"
    if (( totals[fail] || (strict && totals[warn]) )); then
        exit "$KU_EX_FINDINGS"
    fi
}

# Record the result of ITEM: STATUS and a DETAIL, whose words are joined by spaces. The detail
# names kinds and counts, never an identifier.
_ku_check_add() {
    KU_CHECK_STATUS+=("$1")
    KU_CHECK_ITEM+=("$2")
    shift 2
    KU_CHECK_DETAIL+=("$*")
}

# Print the results: STATUS ITEM DETAIL in aligned columns, or ITEM<TAB>STATUS<TAB>DETAIL with
# --porcelain.
_ku_check_print() {
    local i width=0
    for i in "${!KU_CHECK_ITEM[@]}"; do
        if (( ${#KU_CHECK_ITEM[i]} > width )); then
            width=${#KU_CHECK_ITEM[i]}
        fi
    done
    for i in "${!KU_CHECK_ITEM[@]}"; do
        if (( KU_PORCELAIN )); then
            printf '%s\t%s\t%s\n' "${KU_CHECK_ITEM[i]}" "${KU_CHECK_STATUS[i]}" \
                "${KU_CHECK_DETAIL[i]}"
        else
            printf '%-4s  %-*s  %s\n' "${KU_CHECK_STATUS[i]}" "$width" "${KU_CHECK_ITEM[i]}" \
                "${KU_CHECK_DETAIL[i]}"
        fi
    done
}

# Run the probes several items share and keep what they find in the KU_CK_* settings.
_ku_check_collect() {
    local out name value relative resolves status=0
    out=$(ku_probe_boot_mount)
    if [[ -n $out ]]; then
        KU_CK_MOUNTED=1
        IFS=$'\t' read -r KU_CK_SOURCE KU_CK_FSTYPE KU_CK_FS_UUID <<< "$out"
        out=$(ku_probe_boot_luks "$KU_CK_SOURCE") || status=$?
        KU_CK_LUKS=$status
        if (( status == 0 )); then
            while IFS=$'\t' read -r name value relative; do
                case $name in
                    version) KU_CK_LUKS_VERSION=$value ;;
                    uuid) KU_CK_LUKS_UUID=$value ;;
                    keyslot) KU_CK_LUKS_KDFS+=("$relative") ;;
                esac
            done <<< "$out"
        fi
    fi
    out=$(ku_probe_kernel_img)
    while IFS=$'\t' read -r name value; do
        case $name in
            do_symlinks) KU_CK_DO_SYMLINKS=$value ;;
            image_dest) KU_CK_LINK_DIR=$value ;;
        esac
    done <<< "$out"
    out=$(ku_probe_kernels) || KU_CK_KERNELS=$?
    if (( KU_CK_KERNELS == 0 )); then
        while IFS=$'\t' read -r name value; do
            if [[ -n $name ]]; then
                KU_CK_VERSIONS+=("$name")
                KU_CK_STATE[$name]=$value
            fi
        done <<< "$out"
    fi
    KU_CK_RUNNING=$(uname -r) || KU_CK_RUNNING=""
    ku_valid_release "$KU_CK_RUNNING" || KU_CK_RUNNING=""
    out=$(ku_probe_boot_links)
    while IFS=$'\t' read -r name value relative resolves; do
        KU_CK_TARGET[$name]=$value
        KU_CK_RELATIVE[$name]=$relative
        KU_CK_RESOLVES[$name]=$resolves
    done <<< "$out"
}

# boot-mounted: /boot must be a mount point of its own, the filesystem GRUB unlocks and reads.
_ku_check_boot_mounted() {
    if (( KU_CK_MOUNTED )); then
        _ku_check_add ok boot-mounted "/boot is a separate $KU_CK_FSTYPE mount"
    else
        _ku_check_add fail boot-mounted "/boot is not a mount point: unlock and mount it first"
    fi
}

# boot-identity: the filesystem at /boot and its LUKS container must be the ones boot_fs_uuid
# and boot_luks_uuid name. Warns while boot_fs_uuid is not set.
_ku_check_boot_identity() {
    local fs=${KU_CONF[boot_fs_uuid]} luks=${KU_CONF[boot_luks_uuid]} reason
    if (( ! KU_CK_MOUNTED )); then
        _ku_check_add skip boot-identity "/boot is not mounted"
    elif [[ -n $fs && ${KU_CK_FS_UUID,,} != "$fs" ]]; then
        _ku_check_add fail boot-identity \
            "the filesystem at /boot is not the one boot_fs_uuid names"
    elif [[ -n $luks && ( $KU_CK_LUKS == 1 || $KU_CK_LUKS == 3 ) ]]; then
        reason="cryptsetup cannot read the LUKS header"
        (( KU_CK_LUKS == 1 )) || reason="cryptsetup is not installed"
        _ku_check_add fail boot-identity \
            "cannot tell whether /boot is in the LUKS container boot_luks_uuid names: $reason"
    elif [[ -n $luks && ( $KU_CK_LUKS != 0 || $KU_CK_LUKS_UUID != "$luks" ) ]]; then
        _ku_check_add fail boot-identity "/boot is not in the LUKS container boot_luks_uuid names"
    elif [[ -z $fs ]]; then
        _ku_check_add warn boot-identity \
            "boot_fs_uuid is not set, so another filesystem at /boot would pass unnoticed"
    elif [[ -n $luks ]]; then
        _ku_check_add ok boot-identity \
            "/boot is the filesystem boot_fs_uuid names, in the container boot_luks_uuid names"
    else
        _ku_check_add ok boot-identity "/boot is the filesystem boot_fs_uuid names"
    fi
}

# boot-shadowed: bind-mounts / read-only on a private directory in /run and counts the entries
# the /boot mount hides, such as kernels installed while /boot was not mounted. The bind mount
# goes at once, or through the exit trap should the command be cut short; fails if it stays.
_ku_check_boot_shadowed() {
    local parent dir count=-1
    if (( ! KU_CK_MOUNTED )); then
        _ku_check_add skip boot-shadowed "/boot is not a separate mount"
        return 0
    fi
    # mount and umount follow symlinks, so a user who can rename entries in the parent could
    # swap the mount point for one. Hence /run and not TMPDIR, which root may inherit from them.
    parent=$(ku_path /run)
    if ! _ku_check_root_only "$parent"; then
        _ku_check_add warn boot-shadowed "cannot look under the /boot mount point: /run is not" \
            "a directory whose entries only root can rename"
        return 0
    fi
    if ! dir=$(mktemp -d "$parent/kernel-updater.XXXXXXXX"); then
        _ku_check_add warn boot-shadowed "cannot look under the /boot mount point: mktemp failed"
        return 0
    fi
    KU_CK_SCAN_DIR=$dir
    ku_cleanup_add _ku_check_scan_cleanup
    # The mount point sits in mktemp's private directory, so no other user can walk the view.
    # A bind mount that is not recursive shows the root filesystem's own /boot directory. An
    # older mount binds first and remounts read-only after, so even a failed one may leave a
    # bind mount for the cleanup to remove.
    if mkdir "$dir/root"; then
        KU_CK_SCAN_MOUNTED=1
        if mount --bind --make-private -o ro "$(ku_path /)" "$dir/root"; then
            count=$(shopt -s nullglob dotglob; set -- "$dir/root/boot"/*; printf '%s' "$#")
        fi
    fi
    if ! _ku_check_scan_cleanup; then
        _ku_check_add fail boot-shadowed "the read-only bind mount of / on $dir/root stays:" \
            "unmount it and remove $dir by hand"
    elif (( count < 0 )); then
        _ku_check_add warn boot-shadowed \
            "cannot look under the /boot mount point: the read-only bind mount of / failed"
    elif (( count > 0 )); then
        _ku_check_add warn boot-shadowed "$count entries hide under the /boot mount point," \
            "such as kernels installed while /boot was not mounted"
    else
        _ku_check_add ok boot-shadowed "nothing hides under the /boot mount point"
    fi
}

# Return 0 when the directory DIR belongs to root and group and others cannot write it, or
# only with the sticky bit set, so that no other user can rename the entries root makes in it.
_ku_check_root_only() {
    local info owner mode
    [[ -d $1 ]] || return 1
    info=$(stat -L -c '%u %a' -- "$1" 2> /dev/null) || return 1
    read -r owner mode <<< "$info"
    [[ $owner == 0 && $mode =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 || (8#$mode & 8#1000) != 0 ))
}

# Unmount the shadow scan's bind mount, lazily when a plain unmount fails, and remove its two
# directories. Safe to call again, and only ever removes empty directories: rmdir fails while
# the bind mount stays, so the mount cannot lose a file, and the exit trap tries again.
_ku_check_scan_cleanup() {
    [[ -n $KU_CK_SCAN_DIR ]] || return 0
    if (( KU_CK_SCAN_MOUNTED )); then
        # After a failed mount there may be nothing to unmount.
        umount "$KU_CK_SCAN_DIR/root" 2> /dev/null ||
            umount -l "$KU_CK_SCAN_DIR/root" 2> /dev/null || true
    fi
    if [[ -d $KU_CK_SCAN_DIR/root ]]; then
        rmdir "$KU_CK_SCAN_DIR/root" || return 1
    fi
    KU_CK_SCAN_MOUNTED=0
    rmdir "$KU_CK_SCAN_DIR" || return 1
    KU_CK_SCAN_DIR=""
}

# kernel-img: linux-base must keep the links, and keep them in /boot, which GRUB can read.
_ku_check_kernel_img() {
    if (( ! KU_CK_DO_SYMLINKS )); then
        _ku_check_add warn kernel-img "do_symlinks is off: kernel installs leave the links alone"
    elif [[ $KU_CK_LINK_DIR != /boot ]]; then
        _ku_check_add warn kernel-img \
            "link_in_boot is off: the links live in $KU_CK_LINK_DIR, where GRUB cannot read them"
    else
        _ku_check_add ok kernel-img "linux-base keeps the links in /boot"
    fi
}

# boot-links: with the links in /boot, each of the four must be relative and reach a
# non-empty file in /boot, or the menu entries that boot them fail.
_ku_check_boot_links() {
    local name detail=""
    if [[ $KU_CK_LINK_DIR != /boot ]]; then
        _ku_check_add skip boot-links "link_in_boot is off"
        return 0
    fi
    for name in vmlinuz vmlinuz.old initrd.img initrd.img.old; do
        if [[ ${KU_CK_TARGET[$name]:--} == - ]]; then
            detail+="${detail:+; }$name is missing or no symlink"
        elif [[ ${KU_CK_RELATIVE[$name]:-0} != 1 ]]; then
            detail+="${detail:+; }$name is absolute"
        elif [[ ${KU_CK_RESOLVES[$name]:-0} != 1 ]]; then
            detail+="${detail:+; }$name does not reach a non-empty file in /boot"
        fi
    done
    if [[ -n $detail ]]; then
        _ku_check_add fail boot-links "$detail"
    else
        _ku_check_add ok boot-links "the 4 links are relative and reach non-empty files in /boot"
    fi
}

# stale-root-links: with the links in /boot, vmlinuz and initrd.img entries left in / are
# leftovers that no kernel install updates any more.
_ku_check_stale_root_links() {
    local root count
    if [[ $KU_CK_LINK_DIR != /boot ]]; then
        _ku_check_add skip stale-root-links "link_in_boot is off, so the links belong in /"
        return 0
    fi
    root=$(ku_path /)
    count=$(shopt -s nullglob; set -- "$root"vmlinuz* "$root"initrd.img*; printf '%s' "$#")
    if (( count )); then
        _ku_check_add warn stale-root-links \
            "$count vmlinuz or initrd.img entries are left in /, and nothing updates them"
    else
        _ku_check_add ok stale-root-links "no vmlinuz or initrd.img entries are left in /"
    fi
}

# kernels: no kernel package may be stuck between states, and the running kernel must be
# installed, or stuck, which fails anyway. Kernels removed with their config files left warn;
# held ones are reported.
_ku_check_kernels() {
    local version state status=ok detail="" stuck="" installed=0 held=0 removed=0 running=0
    case $KU_CK_KERNELS in
        1)
            _ku_check_add fail kernels "dpkg-query cannot read the package database"
            return 0
            ;;
        2)
            _ku_check_add fail kernels "the kernel versions cannot be sorted"
            return 0
            ;;
    esac
    for version in "${KU_CK_VERSIONS[@]}"; do
        state=${KU_CK_STATE[$version]}
        case $state in
            hi) installed=$((installed + 1)) held=$((held + 1)) ;;
            ?i) installed=$((installed + 1)) ;;
            ?c) removed=$((removed + 1)) ;;
            *) stuck+="${stuck:+, }$version $(_ku_check_state_name "$state")" ;;
        esac
        if [[ $version == "$KU_CK_RUNNING" && $state != ?c ]]; then
            running=1
        fi
    done
    if [[ -n $stuck ]]; then
        status=fail
        detail="$stuck: run dpkg --configure -a"
    fi
    if [[ -z $KU_CK_RUNNING ]]; then
        status=fail
        detail+="${detail:+; }uname -r prints no kernel release"
    elif (( ! running )); then
        status=fail
        detail+="${detail:+; }the running kernel $KU_CK_RUNNING is not installed"
    fi
    if (( removed )); then
        [[ $status == fail ]] || status=warn
        detail+="${detail:+; }$removed removed with config files left"
    fi
    detail+="${detail:+; }$installed installed"
    if (( held )); then
        detail+=", $held held"
    fi
    if [[ $status == ok ]]; then
        detail+=", running $KU_CK_RUNNING"
    fi
    _ku_check_add "$status" kernels "$detail"
}

# Print what the dpkg state ABBREV, as ${db:Status-Abbrev} gives it, says about a package
# that is stuck between states.
_ku_check_state_name() {
    case $1 in
        ??R) printf 'needs a reinstall (%s)' "$1" ;;
        ?U) printf 'is unpacked (%s)' "$1" ;;
        ?F) printf 'is half-configured (%s)' "$1" ;;
        ?H) printf 'is half-installed (%s)' "$1" ;;
        ?W | ?t) printf 'awaits triggers (%s)' "$1" ;;
        *) printf 'is in state %s' "$1" ;;
    esac
}

# reboot-pending: with the links in /boot, the running kernel should be the one /boot/vmlinuz
# points at; otherwise the newest kernel starts only after a reboot.
_ku_check_reboot_pending() {
    local target=${KU_CK_TARGET[vmlinuz]:--} version
    if [[ $KU_CK_LINK_DIR != /boot ]]; then
        _ku_check_add skip reboot-pending "link_in_boot is off"
        return 0
    fi
    target=${target##*/}
    version=${target#vmlinuz-}
    if [[ ${KU_CK_RESOLVES[vmlinuz]:-0} != 1 || $target != vmlinuz-?* ]]; then
        _ku_check_add skip reboot-pending "/boot/vmlinuz does not point at a kernel"
    elif [[ -z $KU_CK_RUNNING ]]; then
        _ku_check_add skip reboot-pending "uname -r prints no kernel release"
    elif [[ $version == "$KU_CK_RUNNING" ]]; then
        _ku_check_add ok reboot-pending "the running kernel is the one /boot/vmlinuz points at"
    else
        _ku_check_add warn reboot-pending \
            "/boot/vmlinuz points at $version, but $KU_CK_RUNNING is running: reboot to start it"
    fi
}

# initrd: the initrd of every installed kernel must exist, be readable by lsinitramfs and hold
# its modules, cryptsetup and the cryptroot configuration, plus key files when crypttab names
# one. One that holds key files and is readable by group or others warns.
_ku_check_initrd() {
    local version file flags modules cryptsetup crypttab keyfiles mode missing target key
    local need_keys=0 checked=0 failed="" readable=""
    if (( KU_CK_KERNELS != 0 )); then
        _ku_check_add skip initrd "the installed kernels are unknown"
        return 0
    fi
    while IFS=$'\t' read -r target _ key; do
        if [[ -n $target && $key != - && $key != /dev/* ]]; then
            need_keys=1
        fi
    done <<< "$(ku_probe_crypttab)"
    for version in "${KU_CK_VERSIONS[@]}"; do
        [[ ${KU_CK_STATE[$version]} == ?i ]] || continue
        checked=$((checked + 1))
        file=$(ku_path "/boot/initrd.img-$version")
        if [[ ! -f $file || ! -s $file ]]; then
            failed+="${failed:+; }$version has no initrd"
            continue
        fi
        if ! flags=$(ku_probe_initrd "$file" "$version"); then
            failed+="${failed:+; }lsinitramfs cannot read the initrd of $version"
            continue
        fi
        IFS=$'\t' read -r modules cryptsetup crypttab keyfiles <<< "$flags"
        missing=""
        (( modules )) || missing+="${missing:+, }its modules"
        (( cryptsetup )) || missing+="${missing:+, }cryptsetup"
        (( crypttab )) || missing+="${missing:+, }the cryptroot configuration"
        if (( need_keys && ! keyfiles )); then
            missing+="${missing:+, }the key files crypttab names, so root would ask for a"
            missing+=" second password or not unlock"
        fi
        if [[ -n $missing ]]; then
            failed+="${failed:+; }the initrd of $version lacks $missing"
            continue
        fi
        if (( keyfiles )); then
            mode=$(stat -L -c %a -- "$file") || mode=""
            if [[ $mode =~ ^[0-7]+$ ]] && (( (8#$mode & 8#044) != 0 )); then
                readable+="${readable:+, }$version"
            fi
        fi
    done
    if (( ! checked )); then
        _ku_check_add skip initrd "no kernel is installed"
    elif [[ -n $failed ]]; then
        _ku_check_add fail initrd "$failed"
    elif [[ -n $readable ]]; then
        _ku_check_add warn initrd "the initrd of $readable holds key files and is readable by" \
            "group or others: set UMASK=0077 in initramfs.conf and rebuild it"
    elif (( need_keys )); then
        _ku_check_add ok initrd "$checked initrd(s) hold their modules, cryptsetup, the" \
            "cryptroot configuration and key files"
    else
        _ku_check_add ok initrd \
            "$checked initrd(s) hold their modules, cryptsetup and the cryptroot configuration"
    fi
}

# boot-luks: the GRUB grub_floor names must unlock the container that holds /boot. 2.02 unlocks
# only LUKS1, 2.06 and 2.12 LUKS2 too, all of them with PBKDF2 keyslots, and 2.14 also Argon2.
_ku_check_boot_luks() {
    local floor=${KU_CONF[grub_floor]} newest=2 versions="LUKS1 and LUKS2" kdfs=pbkdf2
    local names=PBKDF2 kdf slots=0 other=0 kinds=""
    case $floor in
        2.02) newest=1 versions=LUKS1 ;;
        2.06 | 2.12) ;;
        *) kdfs="pbkdf2 argon2i argon2id" names="PBKDF2 or Argon2" ;;
    esac
    if (( ! KU_CK_MOUNTED )); then
        _ku_check_add skip boot-luks "/boot is not mounted"
        return 0
    fi
    case $KU_CK_LUKS in
        1)
            _ku_check_add fail boot-luks \
                "cryptsetup cannot read the LUKS header of the container that holds /boot"
            return 0
            ;;
        2)
            _ku_check_add fail boot-luks "/boot is not in an open LUKS container"
            return 0
            ;;
        3)
            _ku_check_add fail boot-luks \
                "cryptsetup is not installed, so the container that holds /boot cannot be read"
            return 0
            ;;
    esac
    for kdf in "${KU_CK_LUKS_KDFS[@]}"; do
        slots=$((slots + 1))
        if [[ " $kdfs " != *" $kdf "* ]]; then
            other=$((other + 1))
            [[ ,$kinds, == *,$kdf,* ]] || kinds+="${kinds:+,}$kdf"
        fi
    done
    if (( 10#$KU_CK_LUKS_VERSION < 1 || 10#$KU_CK_LUKS_VERSION > newest )); then
        if (( other )); then
            kinds=" with $other ${kinds//,/ or } keyslot(s)"
        fi
        _ku_check_add fail boot-luks "/boot's container is LUKS$KU_CK_LUKS_VERSION$kinds:" \
            "GRUB $floor unlocks only $versions, with $names keyslots"
    elif (( other )); then
        _ku_check_add fail boot-luks "$other keyslot(s) use ${kinds//,/ or }:" \
            "GRUB $floor needs $names"
    elif (( ! slots )); then
        _ku_check_add fail boot-luks \
            "/boot's LUKS$KU_CK_LUKS_VERSION container has no keyslot in use"
    else
        _ku_check_add ok boot-luks \
            "LUKS$KU_CK_LUKS_VERSION with $slots keyslot(s) that GRUB $floor unlocks"
    fi
}

# boot-ext: the GRUB grub_floor names must read the ext filesystem at /boot: it must lack every
# incompatible feature that KU_CK_EXT_INCOMPAT dates after the floor or never, and any dumpe2fs
# does not know, which it prints as FEATURE_I<n>.
_ku_check_boot_ext() {
    local floor=${KU_CONF[grub_floor]} level features feature since found=""
    if (( ! KU_CK_MOUNTED )); then
        _ku_check_add skip boot-ext "/boot is not mounted"
        return 0
    fi
    case $KU_CK_FSTYPE in
        ext2 | ext3 | ext4) ;;
        *)
            _ku_check_add skip boot-ext "/boot is $KU_CK_FSTYPE, not ext2, ext3 or ext4"
            return 0
            ;;
    esac
    if ! features=$(ku_probe_ext_features "$KU_CK_SOURCE"); then
        _ku_check_add fail boot-ext "dumpe2fs cannot read the filesystem at /boot"
        return 0
    fi
    # The scale of KU_CK_EXT_INCOMPAT: 2.06 is 206.
    level=$(( ${floor%%.*} * 100 + 10#${floor#*.} ))
    while IFS= read -r feature; do
        if [[ $feature == FEATURE_I* ]]; then
            since=0
        elif [[ -n $feature && -n ${KU_CK_EXT_INCOMPAT[$feature]+set} ]]; then
            since=${KU_CK_EXT_INCOMPAT[$feature]}
        else
            continue
        fi
        if (( since == 0 || since > level )); then
            found+="${found:+, }$feature"
        fi
    done <<< "$features"
    if [[ -n $found ]]; then
        _ku_check_add fail boot-ext "/boot has ext feature(s) GRUB $floor refuses to read: $found"
    else
        _ku_check_add ok boot-ext "/boot has no ext feature GRUB $floor refuses"
    fi
}

# fstab-crypttab: kernel names (/dev/sdX) and /dev/disk/by-path names change with the port, and
# /dev/disk/by-id names (the disk's model and serial) in a VM; UUID= and the other stable names
# do not. Sources that are no block device, such as tmpfs, are left out.
_ku_check_fstab_crypttab() {
    local file out first second source kind detail="" stable=0
    local -A kinds=()
    for file in fstab crypttab; do
        kinds=([kernel]=0 [by-path]=0 [by-id]=0)
        if [[ $file == fstab ]]; then
            out=$(ku_probe_fstab)
        else
            out=$(ku_probe_crypttab)
        fi
        # The source is the first field of an fstab entry and the second of a crypttab one.
        while IFS=$'\t' read -r first second _; do
            source=$first
            [[ $file == fstab ]] || source=$second
            [[ -n $source ]] || continue
            _ku_check_source_kind kind "$source"
            if [[ $kind == stable ]]; then
                stable=$((stable + 1))
            elif [[ -n $kind ]]; then
                kinds[$kind]=$((kinds[$kind] + 1))
            fi
        done <<< "$out"
        if (( kinds[kernel] )); then
            detail+="${detail:+; }$file names ${kinds[kernel]} device(s) by kernel name (/dev/sdX)"
        fi
        if (( kinds[by-path] )); then
            detail+="${detail:+; }$file names ${kinds[by-path]} by /dev/disk/by-path"
        fi
        if (( kinds[by-id] )); then
            detail+="${detail:+; }$file names ${kinds[by-id]} by /dev/disk/by-id"
        fi
    done
    if [[ -n $detail ]]; then
        _ku_check_add warn fstab-crypttab "$detail: such names change with the port or in a VM;" \
            "use UUID="
    else
        _ku_check_add ok fstab-crypttab "$stable device(s) named by UUID= or another stable name"
    fi
}

# Set the variable named VAR to the kind of device SOURCE names: kernel (/dev/sdX and the
# like), by-path, by-id, stable (UUID= and other names that stay), or empty for a source that
# is no block device.
_ku_check_source_kind() {
    local kernel='^/dev/((([hsv]|xv)d[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)(p?[0-9]+)?|dm-[0-9]+)$'
    case $2 in
        /dev/disk/by-path/*) printf -v "$1" '%s' by-path ;;
        /dev/disk/by-id/*) printf -v "$1" '%s' by-id ;;
        UUID=* | PARTUUID=* | LABEL=* | PARTLABEL=*) printf -v "$1" '%s' stable ;;
        /dev/*)
            if [[ $2 =~ $kernel ]]; then
                printf -v "$1" '%s' kernel
            else
                printf -v "$1" '%s' stable
            fi
            ;;
        *) printf -v "$1" '%s' "" ;;
    esac
}

# grub-pc: a grub-pc upgrade reinstalls GRUB onto every device in grub-pc/install_devices,
# which can overwrite the stick's own boot loader, so the list must be empty.
_ku_check_grub_pc() {
    local devices
    if ! devices=$(ku_probe_grub_pc); then
        _ku_check_add warn grub-pc "debconf-show cannot read grub-pc's answers"
    elif [[ -z $devices ]]; then
        _ku_check_add skip grub-pc "debconf holds no grub-pc/install_devices answer"
    elif (( devices > 0 )); then
        _ku_check_add fail grub-pc "grub-pc/install_devices names $devices device(s): a" \
            "grub-pc upgrade reinstalls GRUB there and can overwrite the stick's boot loader"
    else
        _ku_check_add ok grub-pc "grub-pc/install_devices is empty"
    fi
}
