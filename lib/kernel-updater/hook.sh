# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater hooks
#
# The hook command that the hooks install.sh puts in /etc/kernel and /etc/apt run: the /boot
# guard for kernel installs, removals and configures, the postinst check that a new kernel
# would boot, and apt-guard's decision. Defines functions only.
# -------------------------------------------------------

# The hooks are armed while boot_fs_uuid is set, and then refuse what would leave the stick's
# Kali unbootable. Until it is set they run the same checks but only warn, so installing the
# tool on a system it was not set up for never blocks apt or dpkg.
KU_HOOK_NOT_ARMED="boot_fs_uuid is not set in /etc/kernel-updater.conf, so the kernel-updater"
KU_HOOK_NOT_ARMED+=" hooks only warn"

# Print the hook command's usage on stdout.
ku_hook_usage() {
    cat << 'EOF'
Usage: kernel-updater hook boot-guard PHASE VERSION [IMAGE]
       kernel-updater hook verify VERSION [IMAGE]
       kernel-updater hook apt-guard

Run by the hooks install.sh installs, not by hand. Messages go to stderr, nothing to stdout.

  boot-guard  from /etc/kernel/{preinst,prerm,postinst}.d, with PHASE preinst, prerm or
              postinst: refuses (exit 3) to let kernel VERSION be installed, removed or
              configured while /boot is not the filesystem boot_fs_uuid names
  verify      from /etc/kernel/postinst.d, once the initrd is built: fails (exit 2) when
              kernel VERSION's files, initrd or the /boot links would not boot it, or only
              warns with verify_action = warn
  apt-guard   reads NAME<TAB>ACTION lines from lib/kernel-updater/apt-guard and refuses
              (exit 3) an apt run that changes kernel packages while /boot is not the
              filesystem boot_fs_uuid names, or upgrades grub-pc while
              grub-pc/install_devices names a device

Until boot_fs_uuid is set in /etc/kernel-updater.conf, every hook only warns.
EOF
}

# Run the hook NAME with its ARGS. Takes no lock, since apt and dpkg run the hooks while
# another kernel-updater command may hold it.
ku_cmd_hook() {
    local name
    (( $# )) || ku_usage_error "hook: name one: boot-guard, verify or apt-guard"
    name=$1
    shift
    case $name in
        -h | --help) ku_hook_usage; exit 0 ;;
        boot-guard) _ku_hook_boot_guard "$@" ;;
        verify) _ku_hook_verify "$@" ;;
        apt-guard) _ku_hook_apt_guard "$@" ;;
        *) ku_usage_error "hook: unknown hook '$name'" ;;
    esac
}

# boot-guard PHASE VERSION [IMAGE]: refuse, with exit 3, to let kernel VERSION be installed
# (preinst), removed (prerm) or configured (postinst) while /boot is not the filesystem
# boot_fs_uuid names, so no kernel file lands in, or goes missing from, the directory the /boot
# mount point hides. Like the kernel's own postinst hooks, the postinst guard acts only when
# the kernel is configured.
_ku_hook_boot_guard() {
    local phase=${1-} version=${2-} verb retry kind
    (( $# == 2 || $# == 3 )) || ku_usage_error "hook boot-guard: expected PHASE VERSION [IMAGE]"
    case $phase in
        preinst) verb=install retry="run apt or dpkg again" ;;
        prerm) verb=remove retry="run apt or dpkg again" ;;
        postinst) verb=configure retry="run 'dpkg --configure -a'" ;;
        *) ku_usage_error "hook boot-guard: unknown phase '$phase'" ;;
    esac
    ku_valid_release "$version" || ku_usage_error "hook boot-guard: VERSION is no kernel release"
    if [[ $phase == postinst ]] && ! _ku_hook_configuring; then
        return 0
    fi
    ku_load_config
    kind=$(_ku_hook_boot_state)
    [[ -n $kind ]] || return 0
    if ! _ku_hook_armed; then
        ku_log warning "$(_ku_hook_problem "$kind"), which would make the guard refuse to $verb" \
            "kernel $version"
        ku_log warning "$KU_HOOK_NOT_ARMED"
        return 0
    fi
    ku_log error "refusing to $verb kernel $version: $(_ku_hook_problem "$kind")"
    ku_log error "$(_ku_hook_remedy "$kind" "$retry")"
    exit "$KU_EX_REFUSED"
}

# verify VERSION [IMAGE]: once the kernel's postinst hooks have built its initrd, check that
# kernel VERSION would boot from the stick: /boot/vmlinuz-VERSION is a non-empty file, its
# initrd holds its modules, cryptsetup, the cryptroot configuration and the key files crypttab
# names, and while linux-base keeps the links in /boot, the four are relative and resolve.
# Exits 2 on a problem with verify_action = fail, the default, which leaves the package
# half-configured; otherwise only warns. Acts only when the kernel is configured.
_ku_hook_verify() {
    local version=${1-} file need_keys=0 problem status=0 detail="" joined="" links=""
    local -a problems=()
    (( $# == 1 || $# == 2 )) || ku_usage_error "hook verify: expected VERSION [IMAGE]"
    ku_valid_release "$version" || ku_usage_error "hook verify: VERSION is no kernel release"
    _ku_hook_configuring || return 0
    ku_load_config
    file=$(ku_path "/boot/vmlinuz-$version")
    if [[ ! -f $file || ! -s $file ]]; then
        problems+=("/boot/vmlinuz-$version is missing or empty")
    fi
    if ku_crypttab_names_keys; then
        need_keys=1
        detail=" and the key files"
    fi
    problem=$(ku_initrd_verdict "$version" "$need_keys") || status=$?
    case $status in
        0) ;;
        2)
            ku_log warning "the initrd of $version holds key files and is readable by group or" \
                "others: set UMASK=0077 in initramfs.conf and rebuild it"
            ;;
        *) problems+=("$problem") ;;
    esac
    if _ku_hook_links_in_boot; then
        problem=$(ku_probe_boot_links | ku_boot_links_problems)
        [[ -z $problem ]] || problems+=("in /boot, $problem")
    fi
    if (( ! ${#problems[@]} )); then
        ku_log info "kernel $version passes: its initrd holds its modules, cryptsetup, the" \
            "cryptroot configuration$detail"
        return 0
    fi
    for problem in "${problems[@]}"; do
        joined+="${joined:+; }$problem"
    done
    # The kernel's postinst moved the links before any hook ran, so the stick's default entries
    # already boot this kernel; only the .old ones still boot the previous kernel.
    if _ku_hook_links_in_boot; then
        links="/boot/vmlinuz and /boot/initrd.img already point at kernel $version: until it"
        links+=" passes, boot the previous kernel, which vmlinuz.old and initrd.img.old point at"
    fi
    if [[ ${KU_CONF[verify_action]} == warn ]] || ! _ku_hook_armed; then
        ku_log warning "kernel $version may not boot from the stick: $joined"
        [[ -z $links ]] || ku_log warning "$links"
        _ku_hook_armed || ku_log warning "$KU_HOOK_NOT_ARMED"
        return 0
    fi
    ku_log error "kernel $version may not boot from the stick: $joined"
    [[ -z $links ]] || ku_log error "$links"
    ku_log error "fix that ('update-initramfs -u -k $version' rebuilds its initrd), then run" \
        "'dpkg --configure -a'; verify_action = warn in /etc/kernel-updater.conf only warns"
    exit "$KU_EX_FINDINGS"
}

# apt-guard: read the NAME<TAB>ACTION lines (ACTION unpack, configure or remove) that
# lib/kernel-updater/apt-guard picks out of APT's Pre-Install-Pkgs information, and refuse the
# apt run with exit 3, before dpkg changes anything, when it changes a kernel package,
# linux-base or initramfs-tools while /boot is not the filesystem boot_fs_uuid names, or when
# it unpacks or configures grub-pc while grub-pc/install_devices names a device.
_ku_hook_apt_guard() {
    local name action problem devices kind grub=0
    local -a kernels=() problems=()
    (( $# == 0 )) || ku_usage_error "hook apt-guard: takes no arguments"
    while IFS=$'\t' read -r name action; do
        [[ -n $name ]] || continue
        if [[ $name == grub-pc ]]; then
            [[ $action == remove ]] || grub=1
        elif [[ " ${kernels[*]} " != *" $name "* ]]; then
            kernels+=("$name")
        fi
    done
    (( ${#kernels[@]} || grub )) || return 0
    ku_load_config
    if (( ${#kernels[@]} )); then
        kind=$(_ku_hook_boot_state)
        if [[ -n $kind ]]; then
            problem="$(_ku_hook_problem "$kind"), and this apt run changes"
            problem+=" $(_ku_hook_names "${kernels[@]}"): $(_ku_hook_remedy "$kind" "run apt again")"
            problems+=("$problem")
        fi
    fi
    if (( grub )); then
        problem=""
        if ! devices=$(ku_probe_grub_pc); then
            problem="debconf-show cannot read grub-pc's answers, so this grub-pc upgrade could"
            problem+=" reinstall GRUB over the stick's boot loader"
        elif [[ -n $devices ]] && (( devices > 0 )); then
            problem="grub-pc/install_devices names $devices device(s), and this apt run upgrades"
            problem+=" grub-pc, which reinstalls GRUB there and can overwrite the stick's boot"
            problem+=" loader: run 'dpkg-reconfigure grub-pc', select no device, then run apt again"
        fi
        [[ -z $problem ]] || problems+=("$problem")
    fi
    (( ${#problems[@]} )) || return 0
    if ! _ku_hook_armed; then
        for problem in "${problems[@]}"; do
            ku_log warning "$problem"
        done
        ku_log warning "$KU_HOOK_NOT_ARMED"
        return 0
    fi
    for problem in "${problems[@]}"; do
        ku_log error "$problem"
    done
    ku_log error "apt-guard refused this apt run; nothing was changed"
    exit "$KU_EX_REFUSED"
}

# Return 0 when boot_fs_uuid is set, which arms the hooks.
_ku_hook_armed() {
    [[ -n ${KU_CONF[boot_fs_uuid]} ]]
}

# Return 0 when the kernel is being configured: DEB_MAINT_PARAMS, which linux-run-hooks sets to
# the maintainer script's arguments, starts with configure, or is unset, as when run by hand.
_ku_hook_configuring() {
    local params=${DEB_MAINT_PARAMS-configure}
    [[ ${params%% *} == configure ]]
}

# Print why /boot is not the filesystem boot_fs_uuid names, as a kind, or nothing when it is:
# unreadable when findmnt has no mount table to read, unmounted when nothing is mounted on
# /boot, and other when, with boot_fs_uuid set, another filesystem is.
_ku_hook_boot_state() {
    local out uuid fs=${KU_CONF[boot_fs_uuid]}
    out=$(ku_probe_boot_mount)
    if [[ -z $out ]]; then
        if _ku_hook_mounts_readable; then
            printf 'unmounted'
        else
            printf 'unreadable'
        fi
        return 0
    fi
    IFS=$'\t' read -r _ _ uuid <<< "$out"
    if [[ -n $fs && ${uuid,,} != "$fs" ]]; then
        printf 'other'
    fi
}

# Return 0 when the kernel's mount table, which findmnt reads, can be read: a chroot without
# /proc has none.
_ku_hook_mounts_readable() {
    [[ -r /proc/self/mountinfo ]]
}

# Print the problem the /boot state KIND names, without an identifier.
_ku_hook_problem() {
    case $1 in
        unreadable) printf 'findmnt cannot read the mount table, so /boot may not be mounted' ;;
        unmounted) printf '/boot is not mounted' ;;
        *) printf 'the filesystem at /boot is not the one boot_fs_uuid names' ;;
    esac
}

# Print what to do about the /boot state KIND, ending with RETRY, what to run again.
_ku_hook_remedy() {
    case $1 in
        unreadable) printf 'mount /proc, as a chroot needs, then %s' "$2" ;;
        unmounted) printf 'unlock and mount /boot, then %s' "$2" ;;
        *)
            printf "mount the stick's /boot there instead, or, if /boot was made anew, set"
            printf " boot_fs_uuid to the UUID 'findmnt -n -o UUID /boot' prints; then %s" "$2"
            ;;
    esac
}

# Return 0 when linux-base keeps the kernel links in /boot, as /etc/kernel-img.conf says.
_ku_hook_links_in_boot() {
    local name value do_symlinks=1 dest=/
    while IFS=$'\t' read -r name value; do
        case $name in
            do_symlinks) do_symlinks=$value ;;
            image_dest) dest=$value ;;
        esac
    done <<< "$(ku_probe_kernel_img)"
    [[ $do_symlinks == 1 && $dest == /boot ]]
}

# Print the package NAMEs as a list: up to three, then how many more.
_ku_hook_names() {
    local -a names=("$@")
    local i shown=""
    for (( i = 0; i < ${#names[@]} && i < 3; i++ )); do
        shown+="${shown:+, }${names[i]}"
    done
    if (( ${#names[@]} > 3 )); then
        shown+=" and $(( ${#names[@]} - 3 )) more"
    fi
    printf '%s' "$shown"
}
