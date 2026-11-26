# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater migrate
#
# The migrate command: the one-time switch of the stick's Kali entries to the links linux-base
# keeps in /boot, in stages that each print a plan, ask, and keep a backup that --rollback
# restores. detect fills the configuration, system configures the links, menu writes kali.cfg
# and has grub.cfg source it, and finalize removes the legacy entries. Also reads grub.cfg's
# Kali submenu for check's kali-menu item. Defines functions and settings only.
# -------------------------------------------------------

# Where each stage run keeps its backup, under KU_ROOT: a directory named by its UTC stamp,
# renamed to STAMP.rolled-back once --rollback restored what it holds.
KU_MG_BACKUPS=/var/backups/kernel-updater

# The comment line that opens the block migrate puts in grub.cfg in place of the Kali submenu,
# by which a migrated grub.cfg is told, and what the submenu's title gains behind that block.
KU_MG_MARKER="# Kali GNU/Linux: kernel-updater keeps the entries in kali.cfg."
KU_MG_MARKER+=" Not a MultiBootUSB block."
KU_MG_LEGACY=" (legacy entries)"

# The files on partition 1 the stages read and write.
KU_MG_GRUB=multibootusb/grub/grub.cfg KU_MG_KALI=multibootusb/grub/kali.cfg

# The keys detect fills, in the order it appends them; grub_floor may follow.
KU_MG_KEYS=(boot_fs_uuid boot_luks_uuid disk_ptuuid p1_fs_uuid root_device)

# The private directory in /run a stage works in; the backup directory it writes, its stamp,
# and 1 once its MANIFEST is written, until when the exit trap removes it, as the stage then
# changed nothing else; the temporary file a write in /etc goes through; 1 once the exit trap
# removes those; and 1 when the stage changed something, or in a dry run would have.
KU_MG_TMP="" KU_MG_BACKUP="" KU_MG_STAMP="" KU_MG_SEALED=0 KU_MG_ETC_TMP="" KU_MG_CLEANUP=0
KU_MG_CHANGED=0

# The files on partition 1 that _ku_mg_drifted found changed since the tripwire's baseline was
# recorded, by their names there: a write of migrate leaves their baseline entries as they were.
KU_MG_DRIFTED=()

# The root= of the running kernel's command line, once _ku_mg_cmdline_root read it; the title
# of the Kali submenu, once _ku_mg_title read it; --deploy and --output-dir, which hold for this
# run even after detect loads the configuration anew; and the output_dir the configuration
# names, which check's deployed item reads whatever --output-dir says.
KU_MG_ROOTDEV="" KU_MG_TITLE="" KU_MG_OPT_DEPLOY="" KU_MG_OPT_OUTPUT="" KU_MG_CONF_OUTPUT=""

# What _ku_mg_discover found, by key: each value, and where it comes from in words that name
# no value.
declare -gA KU_MG_VALUE=() KU_MG_ORIGIN=()

# What _ku_mg_scan read from a grub.cfg: how many Kali submenus it holds, 1 when its braces or
# quotes do not balance, and per submenu N its first and last line, 1 when MultiBootUSB's
# markers lie around or in it, 1 when it starts and ends on lines of its own, and its title as
# written; per menu entry N.M, in KU_MG_ENTRIES in order, its title, the line of its first
# linux command, the kernel that command loads, and the words it passes after the kernel, one
# per line.
KU_MG_COUNT=0 KU_MG_UNBALANCED=0 KU_MG_ENTRIES=() KU_MG_FOUND=""
declare -gA KU_MG_START=() KU_MG_END=() KU_MG_MARKED=() KU_MG_TIDY=() KU_MG_RAWTITLE=()
declare -gA KU_MG_ENTRY=() KU_MG_LINUX=() KU_MG_KERNEL=() KU_MG_WORDS=()

# The variants the menu gets, in order, and those that also get an entry for the previous
# kernel; per variant the kernel parameters _ku_mg_derive settled and where they came from;
# what it changed, as notes for the plan; and the legacy entries it carries over to no variant.
KU_MG_MENU=() KU_MG_PREV=() KU_MG_NOTES=() KU_MG_LEFT=()
declare -gA KU_MG_PARAMS=() KU_MG_FROM=() KU_MG_NOTED=()

# The values _ku_mg_fill puts in place of @NAME@ in share/kernel-updater/kali.cfg.in.
declare -gA KU_MG_SUB=()

# Per variant, the parameters its entries get when no legacy entry is one of its kind, and per
# entry, VARIANT for the current kernel and VARIANT.old for the previous one, its title and id.
declare -gA KU_MG_DEFAULTS=([default]="ro quiet splash"
    [failsafe]="ro nomodeset noapic nolapic nosplash"
    [live]="ro quiet splash overlayroot=tmpfs:recurse=0"
    [forensic]="ro quiet splash overlayroot=tmpfs systemd.swap=0 noautomount")
declare -gA KU_MG_TITLES=([default]="Kali GNU/Linux"
    [default.old]="Kali GNU/Linux (previous kernel)"
    [failsafe]="Kali GNU/Linux (fail-safe mode)"
    [failsafe.old]="Kali GNU/Linux (fail-safe, previous kernel)"
    [live]="Kali GNU/Linux (live mode)" [live.old]="Kali GNU/Linux (live mode, previous kernel)"
    [forensic]="Kali GNU/Linux (forensic mode)"
    [forensic.old]="Kali GNU/Linux (forensic mode, previous kernel)")
declare -gA KU_MG_IDS=([default]=kali-default [default.old]=kali-previous
    [failsafe]=kali-failsafe [failsafe.old]=kali-failsafe-previous [live]=kali-live
    [live.old]=kali-live-previous [forensic]=kali-forensic [forensic.old]=kali-forensic-previous)

# Print the migrate command's usage on stdout.
ku_migrate_usage() {
    cat << 'EOF'
Usage: kernel-updater migrate [--stage STAGE] [--deploy MODE] [--output-dir DIR] [--write-fat]
                              [-n] [-y]
       kernel-updater migrate --rollback [STAMP] [--write-fat] [-n] [-y]

Moves the stick's Kali entries, once, onto the links linux-base keeps in /boot, so that
kernel updates no longer change partition 1. Each stage prints its plan, asks, and does
nothing when its result is in place already; system, menu and finalize keep what they change
in a backup directory in /var/backups/kernel-updater, which --rollback restores, and detect
keeps none:

  detect    fill /etc/kernel-updater.conf with the identity of /boot, its LUKS container, the
            stick, its partition 1 and the root device, and grub_floor from the stick's GRUB
  system    set do_symlinks and link_in_boot in /etc/kernel-img.conf, point the links in /boot
            at the newest and the previous kernel, move old links out of /, and, after a
            question of its own, empty grub-pc's install devices
  menu      write multibootusb/grub/kali.cfg, whose entries boot those links, and have
            grub.cfg source it, keeping the old Kali entries behind it as legacy entries;
            run again while they are there, it writes kali.cfg alone anew from them when it
            is missing or differs, as after menu_variants changed
  finalize  remove the legacy entries from grub.cfg, once the new ones booted natively and in
            the VM, and update grub.cfg's entry in the tripwire's baseline, or record the
            baseline when none is stored
  all       detect, system and menu in turn (the default); finalize never runs with them

  --stage STAGE       run STAGE: detect, system, menu, finalize or all
  --deploy MODE       deploy for this run: auto, direct, export or path
  --output-dir DIR    output_dir for this run
  --rollback [STAMP]  undo the newest stage run that was not rolled back, which STAMP, the
                      name of its backup directory, may name
  --write-fat         write a FAT partition 1 in this run, and only under VMware, when the
                      stick's menu booted the running kernel, the volume was left clean, and
                      you answer y that Windows no longer has it; without it, FAT is exported
  -n, --dry-run       print the plan, change nothing
  -y, --yes           answer yes to every question but the one --write-fat asks

Runs as root under the tool's lock. docs/migration.md walks through the stages. Exits 0 when
done or nothing was left to do, 3 when a check refuses or another stage must run first, 4
when a write fails, 10 when declined, 64 on a usage error, 66 when /boot, partition 1 or a
backup cannot be found or read, 75 when another run holds the lock or the kernels, their
links or a file on partition 1 changed while the question waited, 77 when not run as root
and 78 when the configuration names another /boot, container or stick.
EOF
}

# Parse the options, then run the stage, or roll a stage run back, as root and under the lock.
# Exits as the stage does: 0 when done or nothing was left to do, 3 refused, 4 write failed,
# 10 declined, 64 usage, 66 missing input, 75 busy, also when the system stage's plan no longer
# holds after its question or a file on partition 1 changed since the plan read it, before
# anything was written (ku_deploy_files), 77 not root, 78 another /boot or stick.
ku_cmd_migrate() {
    local stage=all staged=0 rollback=0 stamp="" deploy="" output=""
    while (( $# )); do
        case $1 in
            --stage | --deploy | --output-dir)
                (( $# >= 2 )) || ku_usage_error "migrate: $1 needs a value"
                case $1 in
                    --stage) stage=$2 staged=1 ;;
                    --deploy) deploy=$2 ;;
                    *) output=$2 ;;
                esac
                shift 2
                ;;
            --stage=*) stage=${1#*=} staged=1; shift ;;
            --deploy=*) deploy=${1#*=}; shift ;;
            --output-dir=*) output=${1#*=}; shift ;;
            --rollback)
                rollback=1
                shift
                if (( $# )) && [[ $1 != -* ]]; then
                    stamp=$1
                    shift
                fi
                ;;
            --rollback=*) rollback=1 stamp=${1#*=}; shift ;;
            --write-fat)
                # shellcheck disable=SC2034 # read by ku_deploy_resolve in disk.sh
                KU_DK_WRITE_FAT=1
                shift
                ;;
            -n | --dry-run) KU_DRY_RUN=1; shift ;;
            -y | --yes)
                # shellcheck disable=SC2034 # read by ku_ask
                KU_ASSUME_YES=1
                shift
                ;;
            -h | --help) ku_migrate_usage; exit 0 ;;
            -*) ku_usage_error "migrate: unknown option $1" ;;
            *) ku_usage_error "migrate: unexpected argument '$1'" ;;
        esac
    done
    [[ $stage =~ ^(detect|system|menu|finalize|all)$ ]] ||
        ku_usage_error "migrate: --stage takes detect, system, menu, finalize or all"
    if (( rollback && staged )); then
        ku_usage_error "migrate: --rollback undoes a stage run and takes no --stage"
    fi
    if [[ -n $stamp && ! $stamp =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
        ku_usage_error "migrate: STAMP is the name of a backup directory, such as 20261112T093000Z"
    fi
    if [[ -n $deploy ]] && ! _ku_valid_deploy "$deploy"; then
        ku_usage_error "migrate: --deploy takes auto, direct, export or path"
    fi
    if [[ -n $output ]] && ! _ku_valid_abs_path "$output"; then
        ku_usage_error "migrate: --output-dir takes an absolute path"
    fi
    if (( ! rollback )) && [[ -n $KU_CONFIG_FILE && $stage =~ ^(detect|all)$ ]]; then
        ku_usage_error "migrate: the detect stage writes /etc/kernel-updater.conf, which the" \
            "hooks read, so it takes no --config"
    fi
    while [[ $output == ?*/ ]]; do
        output=${output%/}
    done
    KU_MG_OPT_DEPLOY=$deploy KU_MG_OPT_OUTPUT=$output
    ku_require_root
    ku_load_config
    _ku_mg_options
    ku_lock
    if (( rollback )); then
        _ku_mg_rollback "$stamp"
    elif [[ $stage == all ]]; then
        _ku_mg_all
    else
        "_ku_mg_stage_$stage"
    fi
}

# Let --deploy and --output-dir, when given, stand in for deploy and output_dir, keeping the
# output_dir the configuration names in KU_MG_CONF_OUTPUT.
_ku_mg_options() {
    KU_MG_CONF_OUTPUT=${KU_CONF[output_dir]}
    if [[ -n $KU_MG_OPT_DEPLOY ]]; then
        KU_CONF['deploy']=$KU_MG_OPT_DEPLOY
    fi
    if [[ -n $KU_MG_OPT_OUTPUT ]]; then
        KU_CONF['output_dir']=$KU_MG_OPT_OUTPUT
    fi
}

# Run detect, system and menu in turn, each as its own stage would. A dry run stops after the
# first stage that would change something, since the plans of the stages after it build on
# that change.
_ku_mg_all() {
    local stage
    for stage in detect system menu; do
        KU_MG_CHANGED=0
        "_ku_mg_stage_$stage"
        if (( KU_DRY_RUN && KU_MG_CHANGED )) && [[ $stage != menu ]]; then
            ku_log info "dry run: the stages after $stage build on what it would change, so" \
                "their plans show once it ran"
            return 0
        fi
    done
}

# =======================================================
#                     STAGE: DETECT
# =======================================================

# detect: fill /etc/kernel-updater.conf from what this system shows: boot_fs_uuid,
# boot_luks_uuid, disk_ptuuid, p1_fs_uuid and root_device, and grub_floor when the file has
# none and partition 1 can be read. A key the file sets to the same value is left alone, and
# one it sets to another value exits 78, naming the key but never a value. The keys it lacks
# are appended under a comment line, through a temporary file renamed over the file, which
# keeps every other line. Exits 66 when /boot is not mounted or the stick or a value cannot be
# read, and 3 when /boot is in no LUKS container or a value has no form its key takes.
_ku_mg_stage_detect() {
    local file key floor version
    local -a add=() others=() lines=()
    file=$(ku_path /etc/kernel-updater.conf)
    if [[ -L $file ]]; then
        ku_die "$KU_EX_REFUSED" "/etc/kernel-updater.conf is a symlink, and detect writes only a" \
            "regular file; nothing was changed"
    fi
    _ku_mg_discover
    for key in "${KU_MG_KEYS[@]}"; do
        if [[ -z ${KU_CONF_SET[$key]+set} ]]; then
            add+=("$key")
        elif [[ ${KU_CONF[$key]} != "${KU_MG_VALUE[$key]}" ]]; then
            others+=("$key")
        fi
    done
    if (( ${#others[@]} )); then
        ku_die "$KU_EX_CONFIG" "$(ku_join "${others[@]}") in /etc/kernel-updater.conf" \
            "differ from what this system shows: correct or remove each such line, then run the" \
            "detect stage again; nothing was changed"
    fi
    if [[ -z ${KU_CONF_SET[grub_floor]+set} ]]; then
        if ku_p1_open ro; then
            version=$(ku_grub_version "$KU_DK_ROOT")
            _ku_mg_p1_close
            floor=$(ku_grub_floor_for "$version")
            if [[ -n $floor ]]; then
                add+=(grub_floor)
                KU_MG_VALUE['grub_floor']=$floor
                KU_MG_ORIGIN['grub_floor']="$floor, the highest the stick's GRUB $version reaches"
            else
                ku_log info "grub_floor stays at its default: the stick's GRUB version is unknown"
            fi
        else
            ku_log warning "grub_floor stays at its default: partition 1 cannot be read:" \
                "$KU_DK_PROBLEM"
        fi
    fi
    if (( ! ${#add[@]} )); then
        ku_log info "migrate detect: /etc/kernel-updater.conf holds the keys already; nothing" \
            "to do"
        return 0
    fi
    KU_MG_CHANGED=1
    ku_plan "detect: append ${#add[@]} key(s) to /etc/kernel-updater.conf:"
    for key in "${add[@]}"; do
        ku_plan "  $key: ${KU_MG_ORIGIN[$key]}"
        lines+=("$key = ${KU_MG_VALUE[$key]}")
    done
    if [[ " ${add[*]} " == *" boot_fs_uuid "* ]]; then
        ku_plan "setting boot_fs_uuid arms the kernel-updater hooks: from then on they" \
            "refuse kernel installs and removals while /boot is not that filesystem"
    fi
    ku_plan "no value is printed here; read them in /etc/kernel-updater.conf afterwards"
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: /etc/kernel-updater.conf was not written"
        return 0
    fi
    _ku_mg_ask detect "Append ${#add[@]} key(s) to /etc/kernel-updater.conf?"
    _ku_mg_conf_append "$file" "${lines[@]}"
    ku_config_load "$file"
    _ku_mg_options
    ku_log info "migrate detect: appended ${#add[@]} key(s) to /etc/kernel-updater.conf; next:" \
        "'$KU_CMD check', then '$KU_CMD migrate --stage system -n'"
}

# Find what detect fills: set KU_MG_VALUE and KU_MG_ORIGIN by key. Exits as detect says.
_ku_mg_discover() {
    local out source fstype uuid name value kind luks="" status=0
    KU_MG_VALUE=() KU_MG_ORIGIN=()
    out=$(ku_probe_boot_mount)
    if [[ -z $out ]]; then
        ku_die "$KU_EX_NOINPUT" "/boot is not mounted: unlock and mount it first; nothing was" \
            "changed"
    fi
    IFS=$'\t' read -r source fstype uuid <<< "$out"
    if [[ $uuid == - ]]; then
        ku_die "$KU_EX_NOINPUT" "cannot read the UUID of the filesystem at /boot; nothing was" \
            "changed"
    elif ! _ku_valid_uuid "$uuid"; then
        ku_die "$KU_EX_REFUSED" "the UUID of the filesystem at /boot is not in the 8-4-4-4-12" \
            "form boot_fs_uuid takes; nothing was changed"
    fi
    KU_MG_VALUE['boot_fs_uuid']=${uuid,,}
    KU_MG_ORIGIN['boot_fs_uuid']="the UUID of the $fstype filesystem mounted at /boot"
    out=$(ku_probe_boot_luks "$source") || status=$?
    case $status in
        0) ;;
        1)
            ku_die "$KU_EX_NOINPUT" "cryptsetup cannot read the LUKS header of the container" \
                "that holds /boot; nothing was changed"
            ;;
        3)
            ku_die "$KU_EX_REFUSED" "cryptsetup is not installed, so the LUKS container that" \
                "holds /boot cannot be read; nothing was changed"
            ;;
        *)
            ku_die "$KU_EX_REFUSED" "/boot is not in an open LUKS container, which the Kali" \
                "entries unlock; nothing was changed"
            ;;
    esac
    while IFS=$'\t' read -r name value _; do
        if [[ $name == uuid ]]; then
            luks=$value
        fi
    done <<< "$out"
    if [[ -z $luks || $luks == - ]]; then
        ku_die "$KU_EX_NOINPUT" "cryptsetup shows no UUID for the LUKS container that holds" \
            "/boot; nothing was changed"
    elif ! _ku_valid_uuid "$luks"; then
        ku_die "$KU_EX_REFUSED" "the UUID of the LUKS container that holds /boot is not in the" \
            "8-4-4-4-12 form boot_luks_uuid takes; nothing was changed"
    fi
    KU_MG_VALUE['boot_luks_uuid']=${luks,,}
    KU_MG_ORIGIN['boot_luks_uuid']="the UUID of the LUKS container that holds /boot"
    if ! ku_disk_find; then
        ku_die "$KU_EX_NOINPUT" "cannot find the stick's partition 1: $KU_DK_PROBLEM; nothing" \
            "was changed"
    elif [[ $KU_DK_FSTYPE == vfat ]]; then
        kind=FAT
    elif [[ $KU_DK_FSTYPE == ntfs ]]; then
        kind=NTFS
    else
        ku_die "$KU_EX_REFUSED" "partition 1 of the disk that holds /boot is neither FAT nor" \
            "NTFS, so it is not the MultiBootUSB partition kernel-updater serves; nothing was" \
            "changed"
    fi
    if [[ -z $KU_DK_PTUUID || -z $KU_DK_UUID ]]; then
        ku_die "$KU_EX_NOINPUT" "cannot read the PTUUID of the disk that holds /boot or the" \
            "serial of its partition 1; nothing was changed"
    elif ! _ku_valid_ptuuid "$KU_DK_PTUUID" || ! "_ku_valid_${kind,,}_serial" "$KU_DK_UUID"; then
        ku_die "$KU_EX_REFUSED" "the PTUUID of the disk that holds /boot or the serial of its" \
            "partition 1 has no form disk_ptuuid or p1_fs_uuid takes; nothing was changed"
    fi
    KU_MG_VALUE['disk_ptuuid']=${KU_DK_PTUUID,,}
    KU_MG_ORIGIN['disk_ptuuid']="the PTUUID of the disk that holds /boot"
    KU_MG_VALUE['p1_fs_uuid']=${KU_DK_UUID^^}
    KU_MG_ORIGIN['p1_fs_uuid']="the $kind serial of partition 1 of that disk"
    _ku_mg_cmdline_root
    KU_MG_VALUE['root_device']=$KU_MG_ROOTDEV
    KU_MG_ORIGIN['root_device']="the root= device of the running kernel's command line"
}

# Set KU_MG_ROOTDEV to the root= device of the running kernel's command line, /proc/cmdline
# under KU_ROOT: the last root= on it, as the kernel takes the last. Exits 66 when the command
# line cannot be read, and 3 when it names no root= device, or one of a form root_device does
# not take.
_ku_mg_cmdline_root() {
    local file line word root=""
    local -a words=()
    file=$(ku_path /proc/cmdline)
    if [[ ! -f $file || ! -r $file ]] || ! line=$(< "$file"); then
        ku_die "$KU_EX_NOINPUT" "cannot read the running kernel's command line; nothing was" \
            "changed"
    fi
    read -r -a words <<< "$line"
    for word in "${words[@]}"; do
        if [[ $word == root=* ]]; then
            root=${word#root=}
        fi
    done
    if [[ -z $root ]]; then
        ku_die "$KU_EX_REFUSED" "the running kernel's command line names no root= device;" \
            "nothing was changed"
    elif ! _ku_valid_root_device "$root"; then
        ku_die "$KU_EX_REFUSED" "the root= device of the running kernel's command line is" \
            "neither an absolute path nor UUID=, the forms root_device takes; nothing was changed"
    fi
    KU_MG_ROOTDEV=$root
}

# Append the LINES to the config FILE under a comment line that names detect: through a
# temporary file in its directory, which holds the file's bytes first, a line break when its
# last line lacks one, a blank line, then the comment and the LINES, and is renamed over it.
# Each write must succeed, as when the disk is full it would not: else it exits 4.
_ku_mg_conf_append() {
    local file=$1 mode=644
    shift
    if [[ -e $file ]]; then
        mode=$(_ku_mg_mode "$file")
    fi
    _ku_mg_etc_tmp "$file"
    if ! {
        if [[ -s $file ]]; then
            cat -- "$file" && { [[ -z $(tail -c 1 -- "$file") ]] || printf '\n'; } &&
                printf '\n'
        fi && printf '%s\n' "# Set by kernel-updater migrate --stage detect." "$@"
    } > "$KU_MG_ETC_TMP"; then
        _ku_mg_etc_fail /etc/kernel-updater.conf
    fi
    _ku_mg_etc_finish "$file" "$mode" /etc/kernel-updater.conf
}

# =======================================================
#                     STAGE: SYSTEM
# =======================================================

# system: have linux-base keep relative links in /boot, vmlinuz and initrd.img on the newest
# kernel that would boot and the .old ones on the previous: the running kernel when it is
# another that would boot, or else the newest other one. Links on the newest kernel and on
# another that would boot stay as they are (_ku_mg_links_kept). Backs up kernel-img.conf and
# the links it moves out of / first, then sets do_symlinks and link_in_boot, calls
# linux-update-symlinks, moves the old links in / into the backup, asks on its own whether to
# empty grub-pc's install devices, and checks the result: exits 4 when the links or
# kernel-img.conf are not as they should be. Needs detect done (3), /boot mounted (66) and the
# one boot_fs_uuid and boot_luks_uuid name (78), and refuses (3) when check's boot-luks,
# boot-ext or kernels item fails, no kernel would boot, or a name the links take in /boot is no
# symlink; and when only one kernel would boot while /boot holds the image of another, since
# linux-update-symlinks takes the .old links from the images in /boot and would point them at
# that one. Exits 75, changing nothing, when the kernels or the links changed while its
# question waited, as when apt installed a kernel meanwhile, so that a run once apt is done can
# succeed.
_ku_mg_stage_system() {
    local i version name path problem target need_keys=0 newest="" previous="" edit=1
    local relink=1 devices="" img grub_read=1 others state old
    local -a problems=() bootable=() unbootable=() links=() targets=() files=()
    _ku_mg_need_detect
    ku_boot_identity
    state=$(_ku_mg_system_state)
    ku_check_items boot-luks boot-ext kernels
    for i in "${!KU_CHECK_STATUS[@]}"; do
        if [[ ${KU_CHECK_STATUS[i]} == fail ]]; then
            problems+=("${KU_CHECK_ITEM[i]}: ${KU_CHECK_DETAIL[i]}")
        fi
    done
    if ku_crypttab_names_keys; then
        need_keys=1
    fi
    for version in "${KU_CK_VERSIONS[@]}"; do
        [[ ${KU_CK_STATE[$version]} == ?i ]] || continue
        if problem=$(_ku_mg_bootable "$version" "$need_keys"); then
            bootable+=("$version")
        else
            unbootable+=("$problem")
        fi
    done
    if (( ${#bootable[@]} )); then
        newest=${bootable[-1]} previous=${bootable[-1]}
        if [[ $KU_CK_RUNNING != "$newest" && " ${bootable[*]} " == *" $KU_CK_RUNNING "* ]]; then
            previous=$KU_CK_RUNNING
        elif (( ${#bootable[@]} > 1 )); then
            previous=${bootable[-2]}
        fi
    fi
    if _ku_mg_links_in_boot; then
        edit=0
    fi
    if [[ -n $newest ]] && old=$(_ku_mg_links_kept "$newest" "${bootable[@]}"); then
        relink=0 previous=$old
    fi
    for name in vmlinuz vmlinuz.old initrd.img initrd.img.old; do
        path=$(ku_path "/$name")
        if [[ -L $path ]]; then
            target=$(readlink -- "$path") || target=""
            if [[ -z $target || $target == *[[:cntrl:]]* ]]; then
                files+=("$name")
            else
                links+=("$name")
                targets+=("$target")
            fi
        elif [[ -e $path ]]; then
            files+=("$name")
        fi
        path=$(ku_path "/boot/$name")
        if [[ -e $path && ! -L $path ]]; then
            problem="/boot/$name is no symlink, which linux-update-symlinks would replace: move"
            problems+=("$problem it away first")
        fi
    done
    if ! devices=$(ku_probe_grub_pc); then
        devices="" grub_read=0
    fi
    if (( ! edit && ! relink && ! ${#links[@]} )); then
        ku_log info "migrate system: kernel-img.conf, the links in /boot and / are in place" \
            "already; nothing to do"
        _ku_mg_grub_pc_note "$devices" "$grub_read"
        return 0
    fi
    if (( ! ${#bootable[@]} )); then
        for problem in "${unbootable[@]}"; do
            problems+=("$problem")
        done
        problems+=("no installed kernel would boot from the stick")
    elif (( ${#bootable[@]} == 1 )) && others=$(_ku_mg_other_images "$newest"); then
        for problem in "${unbootable[@]}"; do
            problems+=("$problem")
        done
        problem="only $newest would boot, while /boot also holds $others, from which"
        problem+=" linux-update-symlinks would take vmlinuz.old: make each boot, or remove it,"
        problems+=("$problem first")
    fi
    if (( ${#problems[@]} )); then
        for problem in "${problems[@]}"; do
            ku_log error "$problem"
        done
        ku_die "$KU_EX_REFUSED" "the system stage refuses to run while that is so; nothing was" \
            "changed"
    fi
    img=$(ku_path /etc/kernel-img.conf)
    if [[ -L $img ]]; then
        ku_die "$KU_EX_REFUSED" "/etc/kernel-img.conf is a symlink, and the system stage writes" \
            "only a regular file; nothing was changed"
    fi
    KU_MG_CHANGED=1
    ku_plan "system: first a backup of /etc/kernel-img.conf and the links in / in a new" \
        "directory in $KU_MG_BACKUPS"
    if (( edit )); then
        ku_plan "set do_symlinks = yes and link_in_boot = yes in /etc/kernel-img.conf, so" \
            "that every kernel install and removal moves the links in /boot"
    else
        ku_plan "/etc/kernel-img.conf has linux-base keep the links in /boot already"
    fi
    if (( relink )) && [[ $previous != "$newest" ]]; then
        ku_plan "linux-update-symlinks install $previous, then install $newest: vmlinuz and" \
            "initrd.img in /boot on $newest, vmlinuz.old and initrd.img.old on $previous"
    elif (( relink )); then
        ku_plan "linux-update-symlinks install $newest: all four links in /boot on" \
            "$newest, the one kernel that would boot"
    else
        ku_plan "the links in /boot are on $newest and $previous already"
    fi
    if (( ${#links[@]} )); then
        ku_plan "move the old links $(ku_join "${links[@]}") out of / into the backup"
    fi
    if (( ${#files[@]} )); then
        ku_plan "leave $(ku_join "${files[@]}") in /: no symlink, so check keeps" \
            "warning about it; remove it by hand"
    fi
    if [[ -n $devices ]] && (( devices > 0 )); then
        ku_plan "grub-pc/install_devices names $devices device(s): a question of its own" \
            "offers to empty it"
    fi
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    _ku_mg_ask system "Configure the kernel links as planned?"
    if [[ $(_ku_mg_system_state) != "$state" ]]; then
        ku_die "$KU_EX_BUSY" "the kernels or their links changed while the question waited," \
            "as when apt installs a kernel meanwhile, so the plan no longer holds: run the system" \
            "stage again; nothing was changed"
    fi
    _ku_mg_backup_dir system
    if [[ -e $img ]]; then
        cp -- "$img" "$KU_MG_BACKUP/kernel-img.conf" || _ku_mg_backup_fail
    else
        : > "$KU_MG_BACKUP/kernel-img.conf.absent" || _ku_mg_backup_fail
    fi
    : > "$KU_MG_BACKUP/root-links.list" || _ku_mg_backup_fail
    for i in "${!links[@]}"; do
        printf '%s\t%s\n' "${links[i]}" "${targets[i]}" >> "$KU_MG_BACKUP/root-links.list" ||
            _ku_mg_backup_fail
    done
    _ku_mg_manifest
    if (( edit )); then
        _ku_mg_edit_kernel_img
    fi
    if (( relink )); then
        if [[ $previous != "$newest" ]]; then
            _ku_mg_update_symlinks "$previous"
        fi
        _ku_mg_update_symlinks "$newest"
    fi
    if (( ${#links[@]} )); then
        if ! (umask 077 && mkdir -- "$KU_MG_BACKUP/root-links"); then
            _ku_mg_system_die "cannot make root-links in the backup"
        fi
        # A link moves only while it points where root-links.list records, so that root-links
        # holds nothing a rollback would not trust, even when a kernel install moved one since.
        for i in "${!links[@]}"; do
            name=${links[i]} target=""
            path=$(ku_path "/$name")
            if [[ -L $path ]]; then
                target=$(readlink -- "$path") || target=""
            fi
            if [[ $target != "${targets[i]}" ]]; then
                ku_log warning "/$name no longer points where the backup records it, as after a" \
                    "kernel install meanwhile, so it stays in /, where nothing updates it any" \
                    "more: remove it by hand"
            elif ! mv -T -- "$path" "$KU_MG_BACKUP/root-links/$name"; then
                _ku_mg_system_die "cannot move /$name into the backup"
            fi
        done
    fi
    for name in "${files[@]}"; do
        ku_log warning "/$name is no symlink, so it stays in /, where nothing updates it any" \
            "more: remove it by hand"
    done
    _ku_mg_grub_pc "$devices"
    if (( ! grub_read )); then
        _ku_mg_grub_pc_note "" 0
    fi
    _ku_mg_system_verify "$newest" "$previous"
    if [[ ! -e $(ku_path /etc/kernel/preinst.d/00-kernel-updater) ]]; then
        ku_log warning "the kernel-updater hooks are not installed: run 'sudo ./install.sh'" \
            "from the checkout, so that apt and dpkg refuse a kernel while /boot is not mounted"
    fi
    ku_log info "migrate system: done; the backup is $KU_MG_BACKUPS/$KU_MG_STAMP"
    ku_log info "before the menu stage, test both pairs of links at the GRUB prompt, natively" \
        "and in the VM: in the stick's menu press c, then run 'cryptomount -u" \
        "<boot_luks_uuid without dashes>', 'search --no-floppy --fs-uuid --set=root" \
        "<boot_fs_uuid>', 'linux /vmlinuz root=<root_device>' and 'initrd /initrd.img', and the" \
        "last two again with /vmlinuz.old and /initrd.img.old; each must load without an" \
        "error. Esc goes back to the menu. /etc/kernel-updater.conf holds the values, and" \
        "docs/migration.md the steps"
}

# Print why kernel VERSION would not boot from the stick and return 1, or return 0 when it
# would: /boot/vmlinuz-VERSION and /boot/initrd.img-VERSION are non-empty regular files, not
# symlinks, and ku_initrd_verdict passes the initrd with NEED_KEYS, readable by others or not.
_ku_mg_bootable() {
    local version=$1 name path problem status=0
    for name in "vmlinuz-$version" "initrd.img-$version"; do
        path=$(ku_path "/boot/$name")
        if [[ -L $path || ! -f $path || ! -s $path ]]; then
            printf '/boot/%s is missing, empty or no regular file' "$name"
            return 1
        fi
    done
    problem=$(ku_initrd_verdict "$version" "$2") || status=$?
    if (( status == 0 || status == 2 )); then
        return 0
    fi
    printf '%s' "$problem"
    return 1
}

# Return 0 when /etc/kernel-img.conf, or the kernel-img.conf FILE given, has linux-base keep the
# links, and keep them in /boot, as ku_probe_kernel_img reads it.
_ku_mg_links_in_boot() {
    local name value do_symlinks=1 in_boot=0
    while IFS=$'\t' read -r name value; do
        case $name in
            do_symlinks) do_symlinks=$value ;;
            link_in_boot) in_boot=$value ;;
        esac
    done <<< "$(ku_probe_kernel_img "$@")"
    [[ $do_symlinks == 1 && $in_boot == 1 ]]
}

# Print the kernel the .old links in /boot point at, and return 0, when the four links are as
# the system stage leaves them and linux-base keeps them from then on: relative, reaching
# non-empty files, vmlinuz and initrd.img on the files of kernel NEWEST and the .old ones on
# those of another of the kernels BOOTABLE, which would boot, or of NEWEST when it is the only
# one. Which other kernel does not matter, so that a run after the running kernel changed, as
# after a boot of the newest one, neither links anew nor keeps a backup. Returns 1 otherwise.
_ku_mg_links_kept() {
    local newest=$1 target old
    shift
    [[ -z $(ku_probe_boot_links | ku_boot_links_problems) ]] || return 1
    target=$(readlink -- "$(ku_path /boot/vmlinuz.old)") || return 1
    old=${target#vmlinuz-}
    if [[ $old == "$target" || " $* " != *" $old "* ]] ||
        { [[ $old == "$newest" ]] && (( $# > 1 )); }; then
        return 1
    fi
    [[ -z $(_ku_mg_links_elsewhere "$newest" "$old") ]] || return 1
    printf '%s\n' "$old"
}

# Print what the system stage builds its plan on, so that a change while its question waits
# shows: the kernels with their dpkg states, the links in /boot, and the entries in / that the
# stage moves or leaves, a symlink with its target.
_ku_mg_system_state() {
    local name path
    ku_probe_kernels || printf 'the kernels cannot be read\n'
    ku_probe_boot_links
    for name in vmlinuz vmlinuz.old initrd.img initrd.img.old; do
        path=$(ku_path "/$name")
        if [[ -L $path ]]; then
            printf '%s\t%s\n' "$name" "$(readlink -- "$path" || :)"
        elif [[ -e $path ]]; then
            printf '%s\t-\n' "$name"
        fi
    done
}

# Print, "; "-separated, each link in /boot that does not point at the files of kernel NEWEST,
# for vmlinuz and initrd.img, or of kernel PREVIOUS, for the .old ones; nothing when all four do.
_ku_mg_links_elsewhere() {
    local name target version detail=""
    while IFS=$'\t' read -r name target _; do
        [[ -n $name ]] || continue
        case $name in
            vmlinuz | initrd.img) version=$1 ;;
            *) version=$2 ;;
        esac
        if [[ $target != "${name%.old}-$version" ]]; then
            detail+="${detail:+; }$name does not point at the files of $version"
        fi
    done <<< "$(ku_probe_boot_links)"
    printf '%s' "$detail"
}

# Print the kernel images in /boot besides that of kernel VERSION, as linux-update-symlinks
# lists them, every vmlinuz-* and vmlinux-* file but detached signatures, by their versions,
# and return 0; or return 1 when there is none. A name that holds no kernel release is counted.
_ku_mg_other_images() {
    local file version count=0
    local -a versions=()
    for file in "$(ku_path /boot)"/vmlinu[xz]-*; do
        [[ -e $file || -L $file ]] || continue
        [[ $file != *.sig && ${file##*/} != "vmlinuz-$1" ]] || continue
        version=${file##*/vmlinu?-}
        if ku_valid_release "$version"; then
            versions+=("$version")
        else
            count=$((count + 1))
        fi
    done
    if (( count )); then
        versions+=("$count other file(s) named vmlinuz-*")
    fi
    (( ${#versions[@]} )) || return 1
    printf 'the image(s) of %s' "$(ku_join "${versions[@]}")"
}

# Have linux-base point the links at kernel VERSION, as a kernel's postinst does on a fresh
# install: the links that pointed elsewhere become the .old ones. Calls linux-update-symlinks
# through PATH, never under KU_ROOT, its output on stderr. Exits 4 when it fails.
_ku_mg_update_symlinks() {
    if ! linux-update-symlinks install "$1" "/boot/vmlinuz-$1" >&2; then
        _ku_mg_system_die "linux-update-symlinks install $1 failed"
    fi
}

# Have linux-base keep the links in /boot: set do_symlinks = yes and link_in_boot = yes in
# /etc/kernel-img.conf. Each line that sets either, its key matched in any case as
# ku_probe_kernel_img reads it, becomes "KEY = yes" with its comment; every other line stays as
# it is, a key the file lacks is appended, and without a file one with the two lines is made.
# Keeps the file's mode. Exits 4 when the write fails, the disk full included, before the new
# file takes the old one's place.
_ku_mg_edit_kernel_img() {
    local file mode=644 line body code name comment eol content=""
    local -A seen=()
    file=$(ku_path /etc/kernel-img.conf)
    if [[ -e $file ]]; then
        mode=$(_ku_mg_mode "$file")
        while IFS= read -r line || [[ -n $line ]]; do
            eol="" body=${line%$'\r'}
            if [[ $line == *$'\r' ]]; then
                eol=$'\r'
            fi
            code=${body%%#*} name=""
            if [[ $code =~ ^[[:space:]]*([[:alnum:]_]+)[[:space:]]*= ]]; then
                name=${BASH_REMATCH[1],,}
            fi
            if [[ $name == do_symlinks || $name == link_in_boot ]]; then
                comment=""
                if [[ $body == *#* ]]; then
                    comment=" #${body#*#}"
                fi
                content+="$name = yes$comment$eol"$'\n'
                seen[$name]=1
            else
                content+="$line"$'\n'
            fi
        done < "$file"
    fi
    if [[ -z ${seen[do_symlinks]+set} ]]; then
        content+=$'do_symlinks = yes\n'
    fi
    if [[ -z ${seen[link_in_boot]+set} ]]; then
        content+=$'link_in_boot = yes\n'
    fi
    _ku_mg_etc_tmp "$file"
    # One write, so that its failure shows: a group of writes takes the status of its last.
    printf '%s' "$content" > "$KU_MG_ETC_TMP" || _ku_mg_etc_fail /etc/kernel-img.conf
    _ku_mg_etc_finish "$file" "$mode" /etc/kernel-img.conf
}

# Ask, on its own, whether to empty grub-pc's install devices when DEVICES, how many
# grub-pc/install_devices names, is more than 0; on yes, give debconf the empty answer and the
# one that lets a later grub-pc upgrade go on without asking, and check that it took: exits 4
# when not. On no, warn that check's grub-pc item keeps failing. Stores no device anywhere.
_ku_mg_grub_pc() {
    local devices=$1 now question
    if [[ -z $devices ]] || (( devices == 0 )); then
        return 0
    fi
    question="Empty grub-pc's install_devices, so that a grub-pc upgrade never writes GRUB to"
    if ! ku_ask "$question the stick?"; then
        ku_log warning "grub-pc/install_devices still names $devices device(s), so check's" \
            "grub-pc item keeps failing"
        return 0
    fi
    if ! printf '%s\n' 'grub-pc grub-pc/install_devices multiselect ' \
        'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections; then
        _ku_mg_system_die "debconf-set-selections failed"
    fi
    if ! now=$(ku_probe_grub_pc) || [[ -n $now && $now != 0 ]]; then
        _ku_mg_system_die "grub-pc/install_devices does not read back empty"
    fi
    ku_log info "grub-pc/install_devices is empty now; its old answer is kept nowhere"
}

# Warn, when grub-pc/install_devices names DEVICES devices or debconf cannot be read (READ 0),
# that check's grub-pc item fails, and how to empty the answer.
_ku_mg_grub_pc_note() {
    if (( ! $2 )); then
        ku_log warning "debconf-show cannot read grub-pc's answers"
    elif [[ -n $1 ]] && (( $1 > 0 )); then
        ku_log warning "grub-pc/install_devices names $1 device(s), so check's grub-pc item" \
            "fails: run 'dpkg-reconfigure grub-pc' and select no device"
    fi
}

# Exit 4 unless the four links in /boot are relative and reach non-empty files there,
# vmlinuz and initrd.img those of kernel NEWEST and the .old ones those of kernel PREVIOUS, and
# kernel-img.conf has linux-base keep them there, saying what is wrong and how to roll back.
_ku_mg_system_verify() {
    local problem
    problem=$(ku_probe_boot_links | ku_boot_links_problems)
    if [[ -z $problem ]]; then
        problem=$(_ku_mg_links_elsewhere "$1" "$2")
    fi
    if ! _ku_mg_links_in_boot; then
        problem+="${problem:+; }kernel-img.conf does not have linux-base keep the links in /boot"
    fi
    [[ -z $problem ]] || _ku_mg_system_die "after the system stage, $problem"
}

# Exit 4 with MESSAGE, adding that the backup restores what the system stage changed.
_ku_mg_system_die() {
    ku_die "$KU_EX_WRITE" "$1; '$KU_CMD migrate --rollback' restores kernel-img.conf and" \
        "the links in / from the backup $KU_MG_BACKUPS/$KU_MG_STAMP"
}

# =======================================================
#                      STAGE: MENU
# =======================================================

# menu: write multibootusb/grub/kali.cfg, whose entries boot the links in /boot, and replace
# the Kali submenu of multibootusb/grub/grub.cfg with a block that sources it, the submenu
# following as legacy entries. Builds both in a private directory in /run and checks them
# before any write: every byte of grub.cfg outside the submenu stays, grub-script-check takes
# both, and lint finds no error in kali.cfg. Then asks, backs up both files as it read them,
# and writes kali.cfg before grub.cfg, removing an export in output_dir that the write makes
# stale (_ku_mg_retire_export), or exports both. Once grub.cfg sources kali.cfg, it writes
# kali.cfg alone when that is missing or differs (_ku_mg_menu_again). Needs detect and system
# done (3), grub-script-check (3), a partition 1 it may reach (66) and the /boot, container
# and stick the configuration names (78); refuses (3) a grub.cfg without exactly one Kali
# submenu, one between MultiBootUSB's markers, or what it cannot carry over.
_ku_mg_stage_menu() {
    local tmp status=0 expk=- expg title sumk sumg n
    _ku_mg_need_detect
    _ku_mg_need_system
    ku_boot_identity
    _ku_mg_need_check_tool
    _ku_mg_variants
    if [[ " ${KU_MG_MENU[*]} " == *" live "* || " ${KU_MG_MENU[*]} " == *" forensic "* ]]; then
        _ku_mg_overlayroot
    fi
    _ku_mg_resolve
    _ku_mg_tmpdir
    tmp=$KU_MG_TMP
    _ku_mg_read_grub "$tmp/grub.cfg.old"
    expg=$KU_DEPLOY_SUM
    ku_deploy_read "$KU_DK_ROOT" "$KU_MG_KALI" "$tmp/kali.cfg.old" || status=$?
    case $status in
        0) expk=$KU_DEPLOY_SUM ;;
        2) ;;
        *)
            ku_die "$KU_EX_NOINPUT" "cannot read $KU_MG_KALI: $KU_DK_PROBLEM; nothing was" \
                "changed"
            ;;
    esac
    if ku_menu_sources_kali "$tmp/grub.cfg.old"; then
        _ku_mg_menu_again "$tmp" "$expk"
        return 0
    fi
    _ku_mg_scan_one "$tmp/grub.cfg.old" "" 1
    n=$KU_MG_FOUND
    _ku_mg_title "$n"
    title=$KU_MG_TITLE
    _ku_mg_derive "$n"
    _ku_mg_render "$tmp/kali.cfg" "$title"
    _ku_mg_menu_block "$tmp/grub.cfg.old" "$n" "$title" "$tmp/repl"
    _ku_mg_splice "$tmp/grub.cfg.old" "${KU_MG_START[$n]}" "${KU_MG_END[$n]}" "$tmp/repl" \
        "$tmp/grub.cfg"
    _ku_mg_syntax "$tmp/kali.cfg" kali.cfg
    _ku_mg_syntax "$tmp/grub.cfg" grub.cfg
    _ku_mg_lint "$tmp/kali.cfg" "$tmp"
    if ! sumk=$(ku_sha256 "$tmp/kali.cfg") || ! sumg=$(ku_sha256 "$tmp/grub.cfg"); then
        ku_die "$KU_EX_FAILURE" "cannot hash the new kali.cfg and grub.cfg; nothing was changed"
    fi
    KU_MG_CHANGED=1
    _ku_mg_menu_plan "$title" "$expk" "$n" "$sumk" "$sumg"
    _ku_mg_drift_plan "$KU_MG_KALI" "$expk" "$KU_MG_GRUB" "$expg"
    if (( KU_DRY_RUN )); then
        _ku_mg_deploy "$tmp" "$expk" "$expg" "$sumk" "$sumg"
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    if [[ $KU_DK_DEPLOY == export ]]; then
        _ku_mg_ask menu "Export kali.cfg and the new grub.cfg to output_dir as planned?"
    else
        _ku_mg_ask menu "Write kali.cfg and the new grub.cfg to partition 1 as planned?"
    fi
    _ku_mg_backup_dir menu
    cp -- "$tmp/grub.cfg.old" "$KU_MG_BACKUP/grub.cfg" || _ku_mg_backup_fail
    if [[ $expk != - ]]; then
        cp -- "$tmp/kali.cfg.old" "$KU_MG_BACKUP/kali.cfg" || _ku_mg_backup_fail
    fi
    printf '%s\n' "$KU_DK_DEPLOY" > "$KU_MG_BACKUP/deploy" || _ku_mg_backup_fail
    _ku_mg_written kali.cfg "$sumk" grub.cfg "$sumg"
    _ku_mg_seal_export
    _ku_mg_deploy "$tmp" "$expk" "$expg" "$sumk" "$sumg"
    if [[ $KU_DK_DEPLOY != export ]]; then
        if ! _ku_mg_baseline_set "$KU_MG_KALI" "$expk" "$sumk" "$KU_MG_GRUB" "$expg" "$sumg"
        then
            ku_log warning "the tripwire's baseline was not updated, as none is stored or it is" \
                "damaged: run '$KU_CMD baseline' after the finalize stage"
        fi
        _ku_mg_drift_warn
    fi
    _ku_mg_menu_done
}

# Say that the menu stage is done, where its backup is, and which tests come before finalize.
_ku_mg_menu_done() {
    local first=${KU_MG_TITLES[default]}
    if [[ " ${KU_MG_PREV[*]} " == *" default "* ]]; then
        first+="' and '${KU_MG_TITLES[default.old]}"
    fi
    ku_log info "migrate menu: done; the backup is $KU_MG_BACKUPS/$KU_MG_STAMP"
    ku_log info "now boot the new entries, '$first' first, natively and in the VM; the legacy" \
        "entries stay in the menu as a fallback. Then run '$KU_CMD migrate --stage" \
        "finalize'"
}

# The menu stage once grub.cfg sources kali.cfg, which leaves grub.cfg as it is: render kali.cfg
# from the legacy entries grub.cfg still holds and check it as the first run does; when kali.cfg
# is missing, or differs, as after menu_variants changed, ask, back up the kali.cfg there is,
# and write kali.cfg alone, or export it. Nothing to do when it is the same, or when kali.cfg
# exists and no legacy entries remain. Exits 3 when kali.cfg is missing and no legacy entries
# remain to take its parameters from, as after the finalize stage, which must then be rolled
# back first. TMP is the stage's private directory, EXPK the SHA-256 of kali.cfg as read, or -.
_ku_mg_menu_again() {
    local tmp=$1 expk=$2 n title sumk
    _ku_mg_scan_one "$tmp/grub.cfg.old" "$KU_MG_LEGACY" 0
    if (( KU_MG_COUNT == 0 )) && [[ $expk != - ]]; then
        ku_log info "migrate menu: grub.cfg sources kali.cfg already; nothing to do"
        return 0
    elif (( KU_MG_COUNT == 0 )); then
        ku_die "$KU_EX_REFUSED" "grub.cfg sources kali.cfg, which is missing, and holds no" \
            "legacy Kali entries to take its parameters from, as after the finalize stage: roll" \
            "that stage back with '$KU_CMD migrate --rollback', then run the menu stage" \
            "again, which writes kali.cfg anew; nothing was changed"
    fi
    n=$KU_MG_FOUND
    _ku_mg_title "$n"
    title=${KU_MG_TITLE%"$KU_MG_LEGACY"}
    _ku_mg_derive "$n"
    _ku_mg_render "$tmp/kali.cfg" "$title"
    sumk=$(ku_sha256 "$tmp/kali.cfg") ||
        ku_die "$KU_EX_FAILURE" "cannot hash the new kali.cfg; nothing was changed"
    if [[ $sumk == "$expk" ]]; then
        ku_log info "migrate menu: grub.cfg sources kali.cfg already; nothing to do"
        return 0
    fi
    _ku_mg_syntax "$tmp/kali.cfg" kali.cfg
    _ku_mg_lint "$tmp/kali.cfg" "$tmp"
    KU_MG_CHANGED=1
    if [[ $KU_DK_DEPLOY == export ]]; then
        ku_plan "menu: grub.cfg sources kali.cfg already; export kali.cfg alone to" \
            "output_dir for Windows to copy: $KU_DK_DEPLOY_WHY"
    else
        ku_plan "menu: grub.cfg sources kali.cfg already; write kali.cfg alone to" \
            "partition 1 (deploy = $KU_DK_DEPLOY)"
    fi
    if [[ $expk == - ]]; then
        ku_plan "kali.cfg is missing, so the stick's Kali entry only says so: it is written" \
            "anew from the legacy entries in grub.cfg, and a new backup directory in" \
            "$KU_MG_BACKUPS records that it was missing"
    else
        ku_plan "kali.cfg differs from what the menu stage writes now from the legacy" \
            "entries in grub.cfg, as after menu_variants changed: it is replaced, and goes to a" \
            "new backup directory in $KU_MG_BACKUPS first"
    fi
    _ku_mg_entries_plan "$title"
    ku_plan "grub.cfg stays as it is"
    if [[ $KU_DK_DEPLOY != export ]] && _ku_mg_stale_export kali.cfg "$sumk"; then
        _ku_mg_stale_plan
    fi
    _ku_mg_drift_plan "$KU_MG_KALI" "$expk"
    if (( KU_DRY_RUN )); then
        _ku_mg_kali_deploy "$tmp/kali.cfg" "$expk" "$sumk"
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    if [[ $KU_DK_DEPLOY == export ]]; then
        _ku_mg_ask menu "Export kali.cfg alone to output_dir as planned?"
    else
        _ku_mg_ask menu "Write kali.cfg alone to partition 1 as planned?"
    fi
    _ku_mg_backup_dir kali
    if [[ $expk != - ]]; then
        cp -- "$tmp/kali.cfg.old" "$KU_MG_BACKUP/kali.cfg" || _ku_mg_backup_fail
    else
        : > "$KU_MG_BACKUP/kali.cfg.absent" || _ku_mg_backup_fail
    fi
    printf '%s\n' "$KU_DK_DEPLOY" > "$KU_MG_BACKUP/deploy" || _ku_mg_backup_fail
    _ku_mg_written kali.cfg "$sumk"
    _ku_mg_seal_export
    _ku_mg_kali_deploy "$tmp/kali.cfg" "$expk" "$sumk"
    _ku_mg_menu_done
}

# Write kali.cfg and the new grub.cfg from the directory TMP to partition 1, kali.cfg first,
# so that the old menu keeps working until grub.cfg changes, as the plan read them with the
# SHA-256 EXPK and EXPG, then remove an export the new files, with the SHA-256 SUMK and SUMG,
# make stale; or export both for Windows to copy. A dry run only says what it would.
_ku_mg_deploy() {
    local tmp=$1
    if [[ $KU_DK_DEPLOY == export ]]; then
        _ku_mg_export "$tmp/kali.cfg" "$tmp/grub.cfg"
    else
        _ku_mg_deploy_files "$KU_DK_ROOT" "$KU_MG_KALI" "$tmp/kali.cfg" "$2" "$KU_MG_GRUB" \
            "$tmp/grub.cfg" "$3"
        _ku_mg_retire_export kali.cfg "$4" grub.cfg "$5"
    fi
}

# Write the file FILE, named kali.cfg, with the SHA-256 SUM, to partition 1 as kali.cfg, over
# the one read with the SHA-256 EXPECTED, or - for none, then remove an export it makes stale
# and set its entry in the tripwire's baseline, unless kali.cfg had drifted from it
# (_ku_mg_baseline_set); or export it. A dry run only says what it would.
_ku_mg_kali_deploy() {
    if [[ $KU_DK_DEPLOY == export ]]; then
        _ku_mg_export "$1"
        return 0
    fi
    _ku_mg_deploy_files "$KU_DK_ROOT" "$KU_MG_KALI" "$1" "$2"
    _ku_mg_retire_export kali.cfg "$3"
    if ! _ku_mg_baseline_set "$KU_MG_KALI" "$2" "$3"; then
        ku_log warning "the tripwire's baseline was not updated, as none is stored or it is" \
            "damaged: run '$KU_CMD baseline'"
    fi
    _ku_mg_drift_warn
}

# Export the FILEs to output_dir with ku_export. When --output-dir took the export elsewhere
# than the output_dir the configuration names, warn that check's deployed item, to which
# DEPLOY.txt points, reads that one alone, and that a later write, which removes an export it
# makes stale, reads this one only when given the same --output-dir.
_ku_mg_export() {
    ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"
    if [[ ${KU_CONF[output_dir]} != "$KU_MG_CONF_OUTPUT" ]]; then
        ku_log warning "--output-dir took this export away from the output_dir of the" \
            "configuration, the only one check's deployed item reads: once Windows copied the" \
            "files, compare them with SHA256SUMS yourself, as check cannot, then remove the" \
            "export, which a later write removes when it makes it stale only when given the" \
            "same --output-dir"
    fi
}

# Print the menu stage's plan: how the files reach partition 1, kali.cfg's entries
# (_ku_mg_entries_plan), the change to grub.cfg, from line START to END of Kali submenu N, the
# files written, and an export in output_dir that the new files, with the SHA-256 SUMK and
# SUMG, make stale. TITLE is the submenu's, EXPK - for no kali.cfg.
_ku_mg_menu_plan() {
    local title=$1 expk=$2 n=$3 sumk=$4 sumg=$5
    if [[ $KU_DK_DEPLOY == export ]]; then
        ku_plan "menu: export kali.cfg and grub.cfg to output_dir for Windows to copy:" \
            "$KU_DK_DEPLOY_WHY"
    else
        ku_plan "menu: write kali.cfg and grub.cfg to partition 1 (deploy = $KU_DK_DEPLOY)"
    fi
    _ku_mg_entries_plan "$title"
    ku_plan "grub.cfg: lines ${KU_MG_START[$n]} to ${KU_MG_END[$n]}, the Kali submenu, become" \
        "a block that sources kali.cfg, and the submenu follows it as" \
        "$(_ku_mg_shown "$title$KU_MG_LEGACY"); every other byte stays"
    if [[ $expk == - ]]; then
        ku_plan "files: $KU_MG_KALI, new, then $KU_MG_GRUB; both go to a new backup" \
            "directory in $KU_MG_BACKUPS first"
    else
        ku_plan "files: $KU_MG_KALI, which exists and is replaced, then $KU_MG_GRUB; both" \
            "go to a new backup directory in $KU_MG_BACKUPS first"
    fi
    if [[ $KU_DK_DEPLOY != export ]] && _ku_mg_stale_export kali.cfg "$sumk" grub.cfg "$sumg"
    then
        _ku_mg_stale_plan
    fi
}

# Print the plan lines of kali.cfg's entries: the submenu TITLE, each entry with its
# parameters, the root device shown as root=<root_device> and words that may name a device or
# key as KEY=<value> (_ku_mg_shown_params), what changed against the legacy entries, and the
# entries not carried over.
_ku_mg_entries_plan() {
    local title=$1 variant kind note count=0
    for variant in "${KU_MG_MENU[@]}"; do
        count=$((count + 1))
        if [[ " ${KU_MG_PREV[*]} " == *" $variant "* ]]; then
            count=$((count + 1))
        fi
    done
    ku_plan "kali.cfg: the submenu $(_ku_mg_shown "$title") with $count entries:"
    for variant in "${KU_MG_MENU[@]}"; do
        for kind in "" .old; do
            if [[ $kind == .old && " ${KU_MG_PREV[*]} " != *" $variant "* ]]; then
                continue
            fi
            ku_plan "  \"${KU_MG_TITLES[$variant$kind]}\": $(_ku_mg_kernel "$kind")" \
                "root=<root_device>$(_ku_mg_shown_params "${KU_MG_PARAMS[$variant]}")"
        done
        ku_plan "    the $variant parameters are ${KU_MG_FROM[$variant]}"
    done
    for note in "${KU_MG_NOTES[@]}"; do
        ku_plan "  changed: $note"
    done
    for note in "${KU_MG_LEFT[@]}"; do
        ku_plan "  not carried over: $note"
    done
}

# Print the plan line that says that an export in output_dir goes once the files are written,
# since copied after the write it would undo it.
_ku_mg_stale_plan() {
    ku_plan "output_dir holds an export from an earlier run that lists other contents for" \
        "these files: it is removed once they are written, as copied then it would undo the write"
}

# Print the kernel and the initrd an entry boots: the current kernel's links for KIND empty,
# the previous kernel's for .old.
_ku_mg_kernel() {
    if [[ -z $1 ]]; then
        printf 'linux /vmlinuz, initrd /initrd.img,'
    else
        printf 'linux /vmlinuz.old, initrd /initrd.img.old,'
    fi
}

# Set KU_MG_TITLE to the title of Kali submenu N, which kali.cfg's submenu takes over. Exits 3
# unless grub.cfg writes it as one quoted string that holds no quote, $, backslash, brace or
# control character, so that it reads the same between kali.cfg's double quotes.
_ku_mg_title() {
    local raw=${KU_MG_RAWTITLE[$1]} q title
    q=${raw:0:1}
    title=${raw:1}
    title=${title%"$q"}
    if (( ${#raw} < 3 )) || [[ $q != [\"\'] || ${raw: -1} != "$q" ]] ||
        [[ $title == *[\"\'\$\\{}]* || $title == *[[:cntrl:]]* ]]; then
        ku_die "$KU_EX_REFUSED" "the title of grub.cfg's Kali submenu is not one quoted string" \
            "without quotes, dollar signs, backslashes, braces or control characters, as" \
            "kali.cfg takes it over; nothing was changed"
    fi
    KU_MG_TITLE=$title
}

# Exit 3 unless each initrd the live and forensic entries boot lists a path with overlayroot in
# it, which they need: the one /boot/initrd.img points at, and the one /boot/initrd.img.old
# points at when previous_variants holds live or forensic. The system stage, which the menu
# stage needs done, left both links relative and reaching their files.
_ku_mg_overlayroot() {
    local link target version listing keys=menu_variants
    local -a names=(initrd.img)
    if [[ " ${KU_MG_PREV[*]} " == *" live "* || " ${KU_MG_PREV[*]} " == *" forensic "* ]]; then
        names+=(initrd.img.old)
    fi
    for link in "${names[@]}"; do
        target=$(readlink -- "$(ku_path "/boot/$link")") || target=""
        version=${target#initrd.img-}
        if [[ $version == "$target" || $target == */* ]] ||
            ! listing=$(lsinitramfs "$(ku_path "/boot/$target")" 2> /dev/null); then
            ku_die "$KU_EX_REFUSED" "the initrd /boot/$link points at cannot be listed, so" \
                "whether it holds overlayroot, which live and forensic need, is unknown; nothing" \
                "was changed"
        fi
        if [[ $link == initrd.img.old ]]; then
            keys=previous_variants
        fi
        if [[ $listing != *overlayroot* ]]; then
            ku_die "$KU_EX_REFUSED" "the variants live and forensic need overlayroot in the" \
                "initrd, which the initrd of $version lacks, the one /boot/$link points at:" \
                "install the package overlayroot and rebuild that initrd with 'update-initramfs" \
                "-u -k $version', or leave them out of $keys; nothing was changed"
        fi
    done
}

# Set KU_MG_MENU to the variants of menu_variants and KU_MG_PREV to those of previous_variants.
# A previous_variants the config file does not set keeps only the variants menu_variants has;
# one it sets exits 78 when it names another.
_ku_mg_variants() {
    local variant
    local -a prev=()
    IFS=, read -r -a KU_MG_MENU <<< "${KU_CONF[menu_variants]}"
    IFS=, read -r -a prev <<< "${KU_CONF[previous_variants]}"
    KU_MG_PREV=()
    for variant in "${prev[@]}"; do
        if [[ " ${KU_MG_MENU[*]} " == *" $variant "* ]]; then
            KU_MG_PREV+=("$variant")
        elif [[ -n ${KU_CONF_SET[previous_variants]+set} ]]; then
            ku_die "$KU_EX_CONFIG" "previous_variants names $variant, which menu_variants does" \
                "not; nothing was changed"
        fi
    done
}

# Settle the kernel parameters of each variant in KU_MG_MENU from the menu entries of Kali
# submenu N: each entry with a linux command is the failsafe variant when its title holds
# fail-safe or failsafe, else live, else forensic, else default, whichever comes first, and
# hands its words after the kernel to _ku_mg_rewrite; an entry whose variant an earlier one
# took, or that menu_variants lacks, is not carried over. Variants without an entry get the
# built-in parameters.
_ku_mg_derive() {
    local n=$1 key title variant
    local -A claimed=()
    KU_MG_PARAMS=() KU_MG_FROM=() KU_MG_NOTES=() KU_MG_LEFT=() KU_MG_NOTED=()
    for key in "${KU_MG_ENTRIES[@]}"; do
        [[ $key == "$n".* ]] || continue
        title=${KU_MG_ENTRY[$key]}
        if [[ -z ${KU_MG_LINUX[$key]+set} ]]; then
            KU_MG_LEFT+=("$(_ku_mg_shown "$title"), which has no linux command")
            continue
        fi
        case ${title,,} in
            *fail-safe* | *failsafe*) variant=failsafe ;;
            *live*) variant=live ;;
            *forensic*) variant=forensic ;;
            *) variant=default ;;
        esac
        if [[ -n ${claimed[$variant]+set} ]]; then
            KU_MG_LEFT+=("$(_ku_mg_shown "$title"), as an earlier entry is the $variant one")
            continue
        fi
        claimed[$variant]=1
        if [[ " ${KU_MG_MENU[*]} " != *" $variant "* ]]; then
            KU_MG_LEFT+=("$(_ku_mg_shown "$title"), as menu_variants lacks $variant")
            continue
        fi
        _ku_mg_rewrite "$variant" "${KU_MG_WORDS[$key]-}"
        KU_MG_FROM[$variant]="those of the legacy entry $(_ku_mg_shown "$title")"
    done
    for variant in "${KU_MG_MENU[@]}"; do
        if [[ -z ${KU_MG_PARAMS[$variant]+set} ]]; then
            KU_MG_PARAMS[$variant]=${KU_MG_DEFAULTS[$variant]}
            KU_MG_FROM[$variant]="the built-in ones, as no legacy entry is a $variant one"
        fi
    done
}

# Set the parameters of VARIANT from WORDS, a legacy entry's words after the kernel, one per
# line, and note each change: root= goes, as root=<root_device> comes first; cryptdevice=,
# BOOT_IMAGE= and initrd= go; noswap becomes systemd.swap=0, which then appears once; and
# overlayroot's resurce= becomes recurse=. Exits 3 when a word left holds other characters
# than letters, digits and ._:/=,+-, naming the variant but not the word.
_ku_mg_rewrite() {
    local variant=$1 word out="" root=0 swap=0 other=0
    local -a words=()
    if [[ -n $2 ]]; then
        mapfile -t words < <(printf '%s' "$2")
    fi
    for word in "${words[@]}"; do
        case $word in
            root=*)
                root=1
                if [[ ${word#root=} != "${KU_CONF[root_device]}" ]]; then
                    other=1
                fi
                continue
                ;;
            cryptdevice=*)
                _ku_mg_note "$variant: cryptdevice= goes, as Debian's initramfs ignores it"
                continue
                ;;
            BOOT_IMAGE=*)
                _ku_mg_note "$variant: BOOT_IMAGE= goes, as GRUB passes it itself"
                continue
                ;;
            initrd=*)
                _ku_mg_note "$variant: initrd= goes, as the initrd command loads the initrd"
                continue
                ;;
            noswap)
                _ku_mg_note "$variant: noswap, which does nothing on an installed system," \
                    "becomes systemd.swap=0"
                word=systemd.swap=0
                ;;
            overlayroot=*resurce=*)
                _ku_mg_note "$variant: overlayroot's resurce= becomes recurse=, the option" \
                    "overlayroot knows"
                word=${word//resurce=/recurse=}
                ;;
        esac
        if [[ $word == systemd.swap=0 ]]; then
            (( ! swap )) || continue
            swap=1
        fi
        if [[ ! $word =~ ^[A-Za-z0-9._:/=,+-]+$ ]]; then
            ku_die "$KU_EX_REFUSED" "the legacy $variant entry passes the kernel a word with" \
                "other characters than letters, digits and ._:/=,+-, which migrate does not" \
                "carry over: remove it from that entry, or leave $variant out of" \
                "menu_variants; nothing was changed"
        fi
        out+="${out:+ }$word"
    done
    if (( ! root )); then
        _ku_mg_note "$variant: root=<root_device> is added, as the legacy entry has no root="
    elif (( other )); then
        _ku_mg_note "$variant: root= becomes root=<root_device>, another device than the" \
            "legacy entry named"
    fi
    KU_MG_PARAMS[$variant]=$out
}

# Add the note TEXT, its words joined by spaces, to KU_MG_NOTES, unless KU_MG_NOTED shows that
# it is there already.
_ku_mg_note() {
    [[ -z ${KU_MG_NOTED[$*]+set} ]] || return 0
    KU_MG_NOTED[$*]=1
    KU_MG_NOTES+=("$*")
}

# Render kali.cfg into the file OUT from share/kernel-updater/kali.cfg.in: the lines before
# "## begin entry" with TITLE as the submenu's, the entry lines once per variant of KU_MG_MENU
# and once more for the previous kernel when KU_MG_PREV holds it, then the lines after
# "## end entry"; lines that start with ## are dropped. Exits 66 when the template cannot be
# read, and 1 when it is malformed.
_ku_mg_render() {
    local out=$1 template=$KU_SHAREDIR/kali.cfg.in line part=top variant kind
    local -a head=() body=() tail=()
    if [[ ! -f $template || ! -r $template ]]; then
        ku_die "$KU_EX_NOINPUT" "cannot read share/kernel-updater/kali.cfg.in"
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            '## begin entry') part=entry ;;
            '## end entry') part=bottom ;;
            '##'*) ;;
            *)
                case $part in
                    top) head+=("$line") ;;
                    entry) body+=("$line") ;;
                    *) tail+=("$line") ;;
                esac
                ;;
        esac
    done < "$template"
    if [[ $part != bottom ]] || (( ! ${#body[@]} )); then
        ku_die "$KU_EX_FAILURE" "share/kernel-updater/kali.cfg.in has no entry between its" \
            "begin and end lines"
    fi
    KU_MG_SUB=([TITLE]=$2 [LUKS_UUID]=${KU_CONF[boot_luks_uuid]//-/}
        [FS_UUID]=${KU_CONF[boot_fs_uuid]})
    {
        for line in "${head[@]}"; do
            _ku_mg_fill "$line"
        done
        for variant in "${KU_MG_MENU[@]}"; do
            for kind in "" .old; do
                if [[ $kind == .old && " ${KU_MG_PREV[*]} " != *" $variant "* ]]; then
                    continue
                fi
                _ku_mg_entry_values "$variant" "$kind"
                for line in "${body[@]}"; do
                    _ku_mg_fill "$line"
                done
            done
        done
        for line in "${tail[@]}"; do
            _ku_mg_fill "$line"
        done
    } > "$out"
}

# Set the values of one entry in KU_MG_SUB: VARIANT for the current kernel, with KIND empty,
# or for the previous one, with KIND .old.
_ku_mg_entry_values() {
    local variant=$1 kind=$2
    KU_MG_SUB[ENTRY_TITLE]=${KU_MG_TITLES[$variant$kind]}
    KU_MG_SUB[ENTRY_ID]=${KU_MG_IDS[$variant$kind]}
    KU_MG_SUB[KERNEL]=/vmlinuz$kind KU_MG_SUB[INITRD]=/initrd.img$kind
    KU_MG_SUB[CMDLINE]="root=${KU_CONF[root_device]}${KU_MG_PARAMS[$variant]:+ }"
    KU_MG_SUB[CMDLINE]+=${KU_MG_PARAMS[$variant]}
    if [[ -z $kind ]]; then
        KU_MG_SUB[WHICH]=current KU_MG_SUB[OTHER]="a previous-kernel entry"
    else
        KU_MG_SUB[WHICH]=previous KU_MG_SUB[OTHER]="a current-kernel entry"
    fi
}

# Print LINE with each @NAME@ replaced by the value KU_MG_SUB holds for NAME, in one pass, so
# that no value is searched for placeholders in its turn. Exits 1 on a placeholder it has no
# value for, which is a fault of the template.
_ku_mg_fill() {
    local text=$1 out="" name
    while [[ $text == *@* ]]; do
        out+=${text%%@*}
        text=${text#*@}
        if [[ $text =~ ^([A-Z_]+)@ ]]; then
            name=${BASH_REMATCH[1]}
            if [[ -z ${KU_MG_SUB[$name]+set} ]]; then
                ku_die "$KU_EX_FAILURE" "share/kernel-updater/kali.cfg.in names @$name@, for" \
                    "which migrate has no value"
            fi
            out+=${KU_MG_SUB[$name]}
            text=${text#"$name"@}
        else
            out+=@
        fi
    done
    printf '%s\n' "$out$text"
}

# Write to the file OUT what takes the place of Kali submenu N of the grub.cfg FILE: migrate's
# block, which sources kali.cfg when it is there and else shows an entry that says it is
# missing, then the submenu as it is, but for " (legacy entries)" added inside the quotes of its
# title, TITLE. The block's lines end as the submenu's first line does, CRLF or LF. Exits 3 when
# the submenu fits on one line, or its title is not where migrate can extend it.
_ku_mg_menu_block() {
    local file=$1 n=$2 title=$3 out=$4 block=$KU_MG_TMP/block first line eol=$'\n'
    local re='^([[:space:]]*submenu[[:space:]]+)("[^"]*"|'\''[^'\'']*'\'')(.*)$'
    local lead="" q="" quoted="" rest=""
    if (( KU_MG_START[$n] == KU_MG_END[$n] )); then
        ku_die "$KU_EX_REFUSED" "the Kali submenu of grub.cfg fits on one line, which migrate" \
            "does not split: give its entries lines of their own; nothing was changed"
    fi
    # head reads the file and tail its whole input, so that no writer to the pipe dies of
    # SIGPIPE, as tail would before head under pipefail when much of grub.cfg follows the block.
    head -n "${KU_MG_END[$n]}" -- "$file" | tail -n "+${KU_MG_START[$n]}" > "$block"
    IFS= read -r first < "$block" || :
    line=${first%$'\r'}
    if [[ $line != "$first" ]]; then
        eol=$'\r\n'
    fi
    if [[ $line =~ $re ]]; then
        lead=${BASH_REMATCH[1]} q=${BASH_REMATCH[2]:0:1} quoted=${BASH_REMATCH[2]}
        rest=${BASH_REMATCH[3]}
    fi
    if [[ -z $q || ${quoted:1:-1} != "$title" ]] || [[ -n $rest && ! $rest =~ ^[[:space:]{] ]]
    then
        ku_die "$KU_EX_REFUSED" "the title of grub.cfg's Kali submenu is not one quoted string" \
            "right after submenu, before any option such as --class, where migrate" \
            "adds$KU_MG_LEGACY; nothing was changed"
    fi
    {
        printf "%s$eol" "$KU_MG_MARKER" 'if [ -f /multibootusb/grub/kali.cfg ]; then' \
            $'\tsource /multibootusb/grub/kali.cfg' 'else' \
            $'\tmenuentry "Kali GNU/Linux: kali.cfg is missing on BOOT" {' $'\t\tsleep 10' \
            $'\t}' 'fi'
        printf '%s%s%s%s%s%s\n' "$lead" "$q" "$title" "$KU_MG_LEGACY" "$q" "$rest${first#"$line"}"
        tail -n +2 -- "$block"
    } > "$out"
}

# Build the file NEW from the file OLD with its lines START to END replaced by the file REPL,
# which may be empty, then check with _ku_mg_guard that every byte outside them came through.
_ku_mg_splice() {
    local old=$1 start=$2 end=$3 repl=$4 new=$5 before through total len
    before=$(head -n "$(( start - 1 ))" -- "$old" | wc -c)
    through=$(head -n "$end" -- "$old" | wc -c)
    total=$(wc -c < "$old")
    len=$(wc -c < "$repl")
    {
        head -c "$before" -- "$old"
        cat -- "$repl"
        tail -c "+$(( through + 1 ))" -- "$old"
    } > "$new"
    _ku_mg_guard "$old" "$new" "$(( before ))" "$(( total - through ))" "$(( len ))"
}

# Exit 3 unless the file NEW is the file OLD's first BEFORE bytes, LEN bytes of its own, then
# OLD's last AFTER bytes: its size must add up, and cmp must find both slices the same.
_ku_mg_guard() {
    local old=$1 new=$2 before=$3 after=$4 len=$5 size
    size=$(wc -c < "$new")
    if (( size != before + len + after )) ||
        ! cmp -s <(head -c "$before" -- "$new") <(head -c "$before" -- "$old") ||
        ! cmp -s <(tail -c "$after" -- "$new") <(tail -c "$after" -- "$old"); then
        ku_die "$KU_EX_REFUSED" "the new grub.cfg would differ from the old one outside the" \
            "Kali submenu, so it is not written; nothing was changed"
    fi
}

# Exit 3 unless grub-script-check takes FILE, the new NAME.
_ku_mg_syntax() {
    if ! LC_ALL=C grub-script-check "$1" > /dev/null 2>&1; then
        ku_die "$KU_EX_REFUSED" "grub-script-check rejects the new $2, so it is not written;" \
            "nothing was changed"
    fi
}

# Lint the new kali.cfg FILE as check's kali-cfg item does, with the command and module lists
# of the stick's GRUB, which it reads into the directory TMP, or GRUB 2.02's when they cannot
# be read, and grub_floor. Exits 3 on an error, which it names; warnings only go to the plan.
_ku_mg_lint() {
    local file=$1 dir=$2/i386-pc list findings ln severity rule message
    local -a errors=()
    mkdir -- "$dir" || ku_die "$KU_EX_WRITE" "cannot make a directory in $KU_MG_TMP"
    for list in command.lst moddep.lst; do
        if ! ku_deploy_read "$KU_DK_ROOT" "multibootusb/grub/i386-pc/$list" "$dir/$list"; then
            dir=""
            ku_log info "the stick's GRUB lists cannot be read, so GRUB 2.02's stand in for lint"
            break
        fi
    done
    findings=$(ku_lint_findings "$file" "${KU_CONF[grub_floor]}" 0 "$dir")
    while IFS=$'\t' read -r ln severity rule message; do
        case $severity in
            error) errors+=("kali.cfg line $ln: $message [$rule]") ;;
            warning) ku_plan "lint warns about kali.cfg line $ln: $message [$rule]" ;;
        esac
    done <<< "$findings"
    if (( ${#errors[@]} )); then
        for message in "${errors[@]}"; do
            ku_log error "$message"
        done
        ku_die "$KU_EX_REFUSED" "the new kali.cfg fails lint, so it is not written; nothing was" \
            "changed"
    fi
}

# =======================================================
#                    STAGE: FINALIZE
# =======================================================

# finalize: remove the legacy Kali entries the menu stage kept from grub.cfg: the submenu
# whose title ends in " (legacy entries)", every byte outside it staying as it is. Asks, saying
# that the new entries should have booted natively and in the VM first, backs grub.cfg up, and
# writes it, or exports it. After a write it brings check's tripwire up to date
# (_ku_mg_finalize_baseline) and removes an export the write makes stale. Needs the menu stage
# done (3), grub-script-check (3) and a partition 1 it may reach (66).
_ku_mg_stage_finalize() {
    local tmp status=0 expg n="" sum
    _ku_mg_need_check_tool
    _ku_mg_resolve
    _ku_mg_tmpdir
    tmp=$KU_MG_TMP
    _ku_mg_read_grub "$tmp/grub.cfg.old"
    expg=$KU_DEPLOY_SUM
    ku_deploy_read "$KU_DK_ROOT" "$KU_MG_KALI" "$tmp/kali.cfg.old" || status=$?
    if (( status == 1 )); then
        ku_die "$KU_EX_NOINPUT" "cannot read $KU_MG_KALI: $KU_DK_PROBLEM; nothing was changed"
    fi
    if (( status == 2 )) || ! ku_menu_sources_kali "$tmp/grub.cfg.old"; then
        ku_die "$KU_EX_REFUSED" "grub.cfg does not source kali.cfg yet, or kali.cfg is missing:" \
            "run '$KU_CMD migrate --stage menu' first; nothing was changed"
    fi
    _ku_mg_scan_one "$tmp/grub.cfg.old" "$KU_MG_LEGACY" 0
    if (( KU_MG_COUNT == 0 )); then
        ku_log info "migrate finalize: grub.cfg holds no legacy Kali entries; nothing to do"
        return 0
    fi
    n=$KU_MG_FOUND
    : > "$tmp/repl"
    _ku_mg_splice "$tmp/grub.cfg.old" "${KU_MG_START[$n]}" "${KU_MG_END[$n]}" "$tmp/repl" \
        "$tmp/grub.cfg"
    _ku_mg_syntax "$tmp/grub.cfg" grub.cfg
    if ! sum=$(ku_sha256 "$tmp/grub.cfg"); then
        ku_die "$KU_EX_FAILURE" "cannot hash the new grub.cfg; nothing was changed"
    fi
    KU_MG_CHANGED=1
    if [[ $KU_DK_DEPLOY == export ]]; then
        ku_plan "finalize: export grub.cfg to output_dir for Windows to copy:" \
            "$KU_DK_DEPLOY_WHY"
    else
        ku_plan "finalize: write grub.cfg to partition 1 (deploy = $KU_DK_DEPLOY), then" \
            "update its entry in the tripwire's baseline, or record the whole baseline of the" \
            "stick's boot code when none is stored"
    fi
    ku_plan "grub.cfg: remove lines ${KU_MG_START[$n]} to ${KU_MG_END[$n]}, the submenu" \
        "$(_ku_mg_shown "${KU_MG_RAWTITLE[$n]:1:-1}"); every other byte stays, and so does" \
        "kali.cfg"
    ku_plan "grub.cfg goes to a new backup directory in $KU_MG_BACKUPS first"
    if [[ $KU_DK_DEPLOY != export ]] && _ku_mg_stale_export grub.cfg "$sum"; then
        _ku_mg_stale_plan
    fi
    _ku_mg_drift_plan "$KU_MG_GRUB" "$expg"
    if (( KU_DRY_RUN )); then
        _ku_mg_finalize_deploy "$tmp" "$expg" "$sum"
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    _ku_mg_ask finalize "Remove the legacy Kali entries from grub.cfg? Do so only once the new" \
        "entries booted, natively and in the VM."
    _ku_mg_backup_dir finalize
    cp -- "$tmp/grub.cfg.old" "$KU_MG_BACKUP/grub.cfg" || _ku_mg_backup_fail
    printf '%s\n' "$KU_DK_DEPLOY" > "$KU_MG_BACKUP/deploy" || _ku_mg_backup_fail
    _ku_mg_written grub.cfg "$sum"
    _ku_mg_seal_export
    _ku_mg_finalize_deploy "$tmp" "$expg" "$sum"
    ku_log info "migrate finalize: done; the backup is $KU_MG_BACKUPS/$KU_MG_STAMP"
}

# Write the new grub.cfg, with the SHA-256 SUM, from the directory TMP to partition 1, as the
# plan read it with the SHA-256 EXPG, then remove an export it makes stale and bring the
# tripwire's baseline up to date; or export it, and say to record the baseline once Windows
# copied it. A dry run only says what it would.
_ku_mg_finalize_deploy() {
    if [[ $KU_DK_DEPLOY == export ]]; then
        _ku_mg_export "$1/grub.cfg"
        ku_log info "once Windows copied grub.cfg, run '$KU_CMD baseline' to record" \
            "the stick's boot code for check's tripwire"
        return 0
    fi
    _ku_mg_deploy_files "$KU_DK_ROOT" "$KU_MG_GRUB" "$1/grub.cfg" "$2"
    _ku_mg_retire_export grub.cfg "$3"
    _ku_mg_finalize_baseline "$2" "$3"
}

# Bring check's tripwire up to date once finalize wrote grub.cfg, read with the SHA-256 READ,
# with the SHA-256 SUM. Without a stored baseline, record the whole one, as 'kernel-updater
# baseline --yes' would. With one, set grub.cfg's entry alone, as the menu stage sets those of
# the files it writes, unless grub.cfg had drifted from it (_ku_mg_baseline_set), and warn,
# naming them, about the entries that still differ from the stick, such as that grub.cfg, a
# kali.cfg copied from an export or a boot file that changed since: recorded unseen here, the
# tripwire would never report them, so they wait for 'kernel-updater baseline', which shows
# them and asks. A damaged baseline is left to that command too. Only warns when it cannot do
# its part, as grub.cfg is written by then.
_ku_mg_finalize_baseline() {
    local file stored current
    file=$(ku_path "$KU_BASELINE")
    if [[ ! -e $file && ! -L $file ]]; then
        if ! ku_baseline_record "$KU_DK_ROOT"; then
            ku_log warning "the baseline was not recorded, as the stick's boot code cannot be" \
                "hashed: run '$KU_CMD baseline'"
        fi
        return 0
    fi
    if ! _ku_mg_baseline_set "$KU_MG_GRUB" "$1" "$2" || ! stored=$(ku_baseline_read "$file")
    then
        ku_log warning "the tripwire's baseline is damaged, so grub.cfg's entry was not" \
            "updated: run '$KU_CMD baseline'"
        return 0
    fi
    if ! current=$(ku_baseline_hash "$KU_DK_ROOT"); then
        ku_log warning "the stick's boot code cannot be hashed, so whether it differs from the" \
            "tripwire's baseline beyond grub.cfg is unknown: run '$KU_CMD baseline'"
        return 0
    fi
    # grub.cfg's entry holds the file written now, unless it drifted, so only what the
    # baseline must not take unseen still differs.
    ku_baseline_compare "$stored" "$current"
    # shellcheck disable=SC2153 # ku_baseline_compare in baseline.sh sets the KU_BL_ arrays
    if (( ${#KU_BL_CHANGED[@]} + ${#KU_BL_NEW[@]} + ${#KU_BL_MISSING[@]} )); then
        ku_log warning "the stick differs from the tripwire's baseline in files finalize does" \
            "not record: $(ku_baseline_summary). Check those files, then run" \
            "'$KU_CMD baseline', which shows them again and records them"
    fi
}

# Set KU_MG_DRIFTED to the NAMEs, given as NAME READ pairs, whose entry in the tripwire's
# baseline does not match READ, the SHA-256 the file on partition 1 had when the plan read it,
# or - when it was missing: such a file changed outside kernel-updater since the baseline was
# recorded, as by a copy from Windows, or else an entry with no file or a file with no entry.
# Returns 1, leaving KU_MG_DRIFTED empty, when no baseline is stored or it is damaged.
_ku_mg_drifted() {
    local file stored hash name
    local -A sums=()
    KU_MG_DRIFTED=()
    file=$(ku_path "$KU_BASELINE")
    [[ -e $file || -L $file ]] || return 1
    stored=$(ku_baseline_read "$file") || return 1
    while read -r hash name; do
        [[ -z $name ]] || sums[$name]=$hash
    done <<< "$stored"
    while (( $# >= 2 )); do
        if [[ -n ${sums[$1]+set} && ${sums[$1]} != "$2" ]] ||
            [[ -z ${sums[$1]+set} && $2 != - ]]; then
            KU_MG_DRIFTED+=("$1")
        fi
        shift 2
    done
}

# After a write of migrate to partition 1, set the tripwire's baseline entries of the files
# given as NAME READ SUM triples, READ as _ku_mg_drifted takes it and SUM the SHA-256 written,
# but not those of the files that had drifted (KU_MG_DRIFTED): recorded here unseen, their
# change would never show in check's tripwire, so their entries stay as they were, which
# _ku_mg_drift_warn says. Returns 1, recording nothing, when no baseline is stored or it is
# damaged, or the update fails.
_ku_mg_baseline_set() {
    local i
    local -a all=("$@") reads=() pairs=()
    for (( i = 0; i + 2 < ${#all[@]}; i += 3 )); do
        reads+=("${all[i]}" "${all[i + 1]}")
    done
    _ku_mg_drifted "${reads[@]}" || return 1
    for (( i = 0; i + 2 < ${#all[@]}; i += 3 )); do
        if [[ " ${KU_MG_DRIFTED[*]} " != *" ${all[i]} "* ]]; then
            pairs+=("${all[i]}" "${all[i + 2]}")
        fi
    done
    (( ! ${#pairs[@]} )) || ku_baseline_update "${pairs[@]}"
}

# Print the plan line that says, when files given as NAME READ pairs drifted from the
# tripwire's baseline (_ku_mg_drifted), that the write leaves their baseline entries as they
# were, so that check's tripwire keeps reporting the change until 'kernel-updater baseline'
# records it, and that the owner should look at the stick first. An export changes no
# baseline, so it gets no such line.
_ku_mg_drift_plan() {
    local verb=differs
    if [[ $KU_DK_DEPLOY == export ]] || ! _ku_mg_drifted "$@" || (( ! ${#KU_MG_DRIFTED[@]} ))
    then
        return 0
    fi
    (( ${#KU_MG_DRIFTED[@]} == 1 )) || verb=differ
    ku_plan "$(ku_join "${KU_MG_DRIFTED[@]}") $verb from the tripwire's baseline, as" \
        "after a change from Windows since it was recorded: look at the stick before you" \
        "answer. The write leaves the baseline entry as it was, so check's tripwire keeps" \
        "reporting the change until '$KU_CMD baseline' records it"
}

# Warn, after a write, that the files in KU_MG_DRIFTED differed from the tripwire's baseline
# before it, so that their entries stayed as they were and check's tripwire keeps reporting
# them until the owner looked at them and ran 'kernel-updater baseline'. Silent in a dry run,
# whose plan said so already.
_ku_mg_drift_warn() {
    if (( KU_DRY_RUN || ! ${#KU_MG_DRIFTED[@]} )); then
        return 0
    fi
    ku_log warning "$(ku_join "${KU_MG_DRIFTED[@]}") differed from the tripwire's baseline" \
        "before this write, so the baseline keeps its old entry and check's tripwire keeps" \
        "reporting the change: look at the stick, then run '$KU_CMD baseline'," \
        "which shows what differs and records it"
}

# =======================================================
#                       ROLLBACK
# =======================================================

# --rollback [STAMP]: undo the stage run whose backup directory in /var/backups/kernel-updater
# STAMP names, or without STAMP the newest one not rolled back yet, which STAMP must be too,
# since stages undo in the reverse order they ran. A backup without a MANIFEST is passed over
# (_ku_mg_set_aside). Checks the backup against its MANIFEST (3), then restores by its stage:
# kernel-img.conf and the links moved out of / for system, grub.cfg for menu and finalize, and
# kali.cfg for a run of the menu stage that wrote kali.cfg alone. Asks once, and renames the
# directory to STAMP.rolled-back once done. Exits 66 when there is no such backup.
_ku_mg_rollback() {
    local stamp=$1 base newest="" stage name
    local -a stamps=()
    base=$(ku_path "$KU_MG_BACKUPS")
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        if [[ -e $base/$name/MANIFEST || -L $base/$name/MANIFEST ]]; then
            stamps+=("$name")
        else
            _ku_mg_set_aside "$base/$name"
        fi
    done < <(_ku_mg_stamps "$base")
    if (( ${#stamps[@]} )); then
        newest=${stamps[-1]}
    fi
    if [[ -z $stamp ]]; then
        if [[ -z $newest ]]; then
            ku_die "$KU_EX_NOINPUT" "$KU_MG_BACKUPS holds no stage run that was not rolled back;" \
                "nothing was changed"
        fi
        stamp=$newest
    elif [[ " ${stamps[*]} " != *" $stamp "* ]]; then
        if [[ -e $base/$stamp.rolled-back ]]; then
            ku_die "$KU_EX_REFUSED" "the stage run $stamp was rolled back already; nothing was" \
                "changed"
        fi
        ku_die "$KU_EX_NOINPUT" "$KU_MG_BACKUPS holds no backup $stamp; nothing was changed"
    elif [[ $stamp != "$newest" ]]; then
        ku_die "$KU_EX_REFUSED" "the newer stage run $newest is not rolled back yet: roll it" \
            "back first, as stages undo in the reverse order they ran; nothing was changed"
    fi
    _ku_mg_check_backup "$base/$stamp"
    stage=$(< "$base/$stamp/stage")
    case $stage in
        system) _ku_mg_rollback_system "$base/$stamp" ;;
        menu | finalize) _ku_mg_rollback_menu "$base/$stamp" "$stage" ;;
        kali) _ku_mg_rollback_kali "$base/$stamp" ;;
        *)
            ku_die "$KU_EX_REFUSED" "the backup $stamp holds nothing migrate can restore;" \
                "nothing was changed"
            ;;
    esac
}

# Print the names of the backup directories in BASE that were not rolled back, oldest first.
_ku_mg_stamps() {
    local dir name
    for dir in "$1"/*; do
        name=${dir##*/}
        if [[ $name =~ ^[0-9]{8}T[0-9]{6}Z$ && -d $dir && ! -L $dir ]]; then
            printf '%s\n' "$name"
        fi
    done | LC_ALL=C sort
}

# Pass over the backup directory DIR, which has no MANIFEST: every stage writes it before it
# changes anything, so the stage run was cut short before it did, by a kill, a crash or a power
# loss, and there is nothing to roll back. Renames DIR to DIR.failed, but for a dry run, so
# that it no longer counts as the newest run, and warns.
_ku_mg_set_aside() {
    local stamp=${1##*/} what
    what="the backup $stamp has no MANIFEST, as its stage run was cut short before it changed"
    if (( KU_DRY_RUN )); then
        ku_log warning "$what anything: it is passed over, and a run without --dry-run renames" \
            "it to $stamp.failed"
    elif mv -T -- "$1" "$1.failed"; then
        ku_log warning "$what anything: it is passed over, and renamed to $stamp.failed"
    else
        ku_log warning "$what anything: it is passed over, but cannot be renamed to" \
            "$stamp.failed"
    fi
}

# Exit 3 unless the backup directory DIR is whole: its MANIFEST, a regular file, lists every
# regular file in it but itself, each with the SHA-256 it has, as sha256sum -c checks them, and
# a stage file; besides those it holds only root-links, a directory whose entries are symlinks
# that root-links.list lists with the target each has. Follows no other symlink.
_ku_mg_check_backup() {
    local dir=$1 stamp=${1##*/} line name hash got target
    local -A listed=() recorded=()
    if [[ -L $dir/MANIFEST || ! -f $dir/MANIFEST ]]; then
        _ku_mg_damaged "$stamp" "it has no MANIFEST"
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ ! $line =~ ^([0-9a-f]{64})\ [\ *]([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
            _ku_mg_damaged "$stamp" "its MANIFEST is damaged"
        fi
        hash=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
        if [[ $name == MANIFEST || -n ${listed[$name]+set} || -L $dir/$name || ! -f $dir/$name ]] ||
            ! got=$(ku_sha256 "$dir/$name") || [[ $got != "$hash" ]]; then
            _ku_mg_damaged "$stamp" "$name does not match its MANIFEST"
        fi
        listed[$name]=1
    done < "$dir/MANIFEST"
    [[ -n ${listed[stage]+set} ]] || _ku_mg_damaged "$stamp" "its MANIFEST lists no stage file"
    if [[ -n ${listed[root-links.list]+set} ]]; then
        while IFS=$'\t' read -r name target || [[ -n $name ]]; do
            if [[ ! $name =~ ^(vmlinuz|initrd\.img)(\.old)?$ || -z $target ]]; then
                _ku_mg_damaged "$stamp" "its root-links.list is damaged"
            fi
            # shellcheck disable=SC2034 # read by _ku_mg_check_links
            recorded[$name]=$target
        done < "$dir/root-links.list"
    fi
    while IFS= read -r name; do
        if [[ $name == MANIFEST || ( -n ${listed[$name]+set} && ! -L $dir/$name ) ]]; then
            continue
        elif [[ $name == root-links && -d $dir/$name && ! -L $dir/$name ]]; then
            _ku_mg_check_links "$dir/root-links" "$stamp" recorded
        else
            _ku_mg_damaged "$stamp" "it holds $name, which its MANIFEST does not list"
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n')
}

# Exit 3 unless each entry of the directory ROOT_LINKS, in the backup STAMP, is a symlink that
# the array named LINKS lists, with the target it records.
_ku_mg_check_links() {
    local -n links_=$3
    local name target
    while IFS= read -r name; do
        target=""
        if [[ -L $1/$name ]]; then
            target=$(readlink -- "$1/$name") || target=""
        fi
        if [[ -z ${links_[$name]+set} || -z $target || $target != "${links_[$name]}" ]]; then
            _ku_mg_damaged "$2" "root-links/$name is not a link that root-links.list records"
        fi
    done < <(find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n')
}

# Exit 3, saying that the backup STAMP cannot be trusted, and WHY.
_ku_mg_damaged() {
    ku_die "$KU_EX_REFUSED" "the backup $1 cannot be trusted: $2; nothing was changed"
}

# Undo the system stage run whose backup is DIR: put /etc/kernel-img.conf back as it was, or
# remove it when the stage made it, and move each link the stage moved out of / back where its
# name is free. The links in /boot stay, and so does grub-pc's answer, as the stage left it.
# When the kernel-img.conf put back would stop linux-base from keeping the links in /boot, as
# the one of the first run does, it exits 3 while partition 1's grub.cfg sources kali.cfg,
# whose entries boot those links, as when a rollback of the menu stage exported grub.cfg and
# Windows has not copied it yet; when partition 1 cannot be read, the plan says so. A later
# run, whose kernel-img.conf keeps them there, rolls back whatever grub.cfg holds.
_ku_mg_rollback_system() {
    local dir=$1 stamp=${1##*/} img name status=1 keeps=0 devices empty=0
    local -a back=() taken=()
    img=$(ku_path /etc/kernel-img.conf)
    if [[ ! -f $dir/kernel-img.conf && ! -f $dir/kernel-img.conf.absent ]]; then
        ku_die "$KU_EX_REFUSED" "the backup $stamp holds nothing to restore; nothing was changed"
    fi
    if [[ -L $img ]]; then
        ku_die "$KU_EX_REFUSED" "/etc/kernel-img.conf is a symlink, and the rollback writes only" \
            "a regular file; nothing was changed"
    fi
    if [[ -f $dir/kernel-img.conf ]] && _ku_mg_links_in_boot "$dir/kernel-img.conf"; then
        keeps=1
    else
        status=0
        _ku_mg_p1_sources_kali || status=$?
    fi
    if (( status == 0 )); then
        ku_die "$KU_EX_REFUSED" "partition 1's grub.cfg still sources kali.cfg, whose entries" \
            "boot the links in /boot that only the system stage keeps moving: roll the menu" \
            "stage back first, and when that exported grub.cfg, copy it to the stick as" \
            "DEPLOY.txt in output_dir says; nothing was changed"
    fi
    if [[ -f $dir/root-links.list ]]; then
        while IFS=$'\t' read -r name _ || [[ -n $name ]]; do
            [[ -L $dir/root-links/$name ]] || continue
            if [[ -e $(ku_path "/$name") || -L $(ku_path "/$name") ]]; then
                taken+=("$name")
            else
                back+=("$name")
            fi
        done < "$dir/root-links.list"
    fi
    if [[ -f $dir/kernel-img.conf ]]; then
        ku_plan "rollback of the system stage run $stamp: put /etc/kernel-img.conf back as" \
            "it was before"
    else
        ku_plan "rollback of the system stage run $stamp: remove /etc/kernel-img.conf, which" \
            "the stage made"
    fi
    if (( keeps )); then
        ku_plan "that kernel-img.conf has linux-base keep the links in /boot too, as the" \
            "stage found it, so kernel installs keep moving the links kali.cfg's entries boot"
    fi
    if (( ${#back[@]} )); then
        ku_plan "move $(ku_join "${back[@]}") back to /"
    fi
    if (( ${#taken[@]} )); then
        ku_plan "leave $(ku_join "${taken[@]}") in the backup's root-links, as / has" \
            "entries of those names now"
    fi
    if (( status == 2 )); then
        ku_plan "whether partition 1's grub.cfg still sources kali.cfg is unknown, as" \
            "$KU_DK_PROBLEM: go on only when it no longer does, since kali.cfg's entries boot" \
            "the links in /boot, which kernel installs stop moving after this rollback"
    fi
    ku_plan "the links in /boot stay: they harm nothing, and kernel installs keep them"
    if ! devices=$(ku_probe_grub_pc); then
        ku_plan "grub-pc's install_devices answer stays as the system stage left it, which" \
            "debconf-show cannot read now"
    elif [[ -n $devices ]] && (( devices > 0 )); then
        ku_plan "grub-pc/install_devices still names $devices device(s), as the system" \
            "stage left it: check's grub-pc item fails until 'dpkg-reconfigure grub-pc' selects" \
            "no device"
    else
        empty=1
        ku_plan "grub-pc/install_devices stays empty, which is safe: no device it named" \
            "before was kept"
    fi
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    _ku_mg_ask rollback "Roll the system stage run $stamp back as planned?"
    if [[ -f $dir/kernel-img.conf ]]; then
        _ku_mg_etc_copy "$dir/kernel-img.conf" "$img" /etc/kernel-img.conf
    elif [[ -e $img ]] && ! rm -f -- "$img"; then
        ku_die "$KU_EX_WRITE" "cannot remove /etc/kernel-img.conf; nothing was changed"
    fi
    for name in "${back[@]}"; do
        if ! mv -T -- "$dir/root-links/$name" "$(ku_path "/$name")"; then
            ku_die "$KU_EX_WRITE" "cannot move $name back to /; kernel-img.conf is restored," \
                "so run the rollback again"
        fi
    done
    for name in "${taken[@]}"; do
        ku_log warning "/$name exists, so the old link of that name stays in" \
            "$KU_MG_BACKUPS/$stamp.rolled-back/root-links"
    done
    _ku_mg_rolled_back "$dir"
    if (( empty )); then
        ku_log info "grub-pc/install_devices stays empty; 'dpkg-reconfigure grub-pc' changes it"
    fi
}

# Undo the menu or finalize stage run, STAGE, whose backup is DIR: write grub.cfg back to
# partition 1 as the stage read it, or export it. An export goes out even when partition 1
# holds that grub.cfg already, so that output_dir no longer holds the stage's own export, which
# copied would redo what the rollback undoes; a write, or a partition 1 that needs none,
# removes such an export. kali.cfg stays on partition 1. The grub.cfg of a menu stage run names
# kernel versions, so writing it back is refused (3) once /boot holds none of the kernels its
# Kali entries boot (_ku_mg_legacy_kernels). When grub.cfg changed after the stage run wrote
# it, as when MultiBootUSB added an ISO, the plan says that the rollback drops those changes,
# and the question asks for that too.
_ku_mg_rollback_menu() {
    local dir=$1 stage=$2 stamp=${1##*/} status=0 expected=- sum write=0 wrote drops=0
    local question
    if [[ ! -f $dir/grub.cfg ]]; then
        ku_die "$KU_EX_REFUSED" "the backup $stamp holds nothing to restore; nothing was changed"
    fi
    _ku_mg_resolve
    _ku_mg_tmpdir
    ku_deploy_read "$KU_DK_ROOT" "$KU_MG_GRUB" "$KU_MG_TMP/current.cfg" || status=$?
    case $status in
        0) expected=$KU_DEPLOY_SUM ;;
        2) ;;
        *)
            ku_die "$KU_EX_NOINPUT" "cannot read $KU_MG_GRUB: $KU_DK_PROBLEM; nothing was" \
                "changed"
            ;;
    esac
    sum=$(ku_sha256 "$dir/grub.cfg") || _ku_mg_damaged "$stamp" "its grub.cfg cannot be read"
    if [[ $sum != "$expected" || $KU_DK_DEPLOY == export ]]; then
        write=1
    fi
    if [[ $stage == menu && $sum != "$expected" ]]; then
        status=0
        ku_deploy_read "$KU_DK_ROOT" "$KU_MG_KALI" "$KU_MG_TMP/current-kali.cfg" || status=$?
        _ku_mg_legacy_kernels "$dir/grub.cfg" "$stamp" "$status"
    fi
    wrote=$(_ku_mg_written_sum "$dir" grub.cfg)
    if [[ -n $wrote && $expected != - && $expected != "$wrote" && $expected != "$sum" ]]; then
        drops=1
    fi
    if [[ $KU_DK_DEPLOY == export && $sum == "$expected" ]]; then
        ku_plan "rollback of the $stage stage run $stamp: partition 1 holds grub.cfg as the" \
            "backup does already, and it is exported all the same, so that output_dir no" \
            "longer holds the stage's own export: $KU_DK_DEPLOY_WHY"
    elif [[ $KU_DK_DEPLOY == export ]]; then
        ku_plan "rollback of the $stage stage run $stamp: export grub.cfg as it was before" \
            "to output_dir for Windows to copy: $KU_DK_DEPLOY_WHY"
    elif (( ! write )); then
        ku_plan "rollback of the $stage stage run $stamp: grub.cfg is as the backup holds" \
            "it already, so only the backup is marked as rolled back"
    else
        ku_plan "rollback of the $stage stage run $stamp: write grub.cfg back to partition" \
            "1 as it was before (deploy = $KU_DK_DEPLOY)"
    fi
    if [[ $KU_DK_DEPLOY != export ]] && _ku_mg_stale_export grub.cfg "$sum"; then
        _ku_mg_stale_plan
    fi
    if (( write )); then
        _ku_mg_drift_plan "$KU_MG_GRUB" "$expected"
    fi
    if (( drops )) && [[ $KU_DK_DEPLOY == export ]]; then
        ku_plan "grub.cfg on partition 1 changed after the $stage stage run $stamp wrote it," \
            "as when MultiBootUSB adds an ISO: copied over it, the export drops those changes," \
            "so copy grub.cfg from the stick first to keep them"
    elif (( drops )); then
        ku_plan "grub.cfg on partition 1 changed after the $stage stage run $stamp wrote it," \
            "as when MultiBootUSB adds an ISO: the rollback drops those changes, which then only" \
            "the copy the write keeps beside it, $KU_MG_GRUB.ku-<UTC stamp>.bak, holds, until" \
            "backups_keep later writes of grub.cfg remove it"
    fi
    if [[ $stage == menu ]]; then
        ku_plan "$KU_MG_KALI stays on partition 1, where the grub.cfg put back no longer" \
            "uses it: check's kali-menu item fails until you delete it from Windows or run the" \
            "menu stage again"
    else
        ku_plan "$KU_MG_KALI stays on partition 1, where the grub.cfg put back sources it"
    fi
    question="Roll the $stage stage run $stamp back as planned?"
    if (( drops )); then
        question="Roll the $stage stage run $stamp back as planned, dropping the changes made to"
        question+=" grub.cfg since?"
    fi
    if (( ! KU_DRY_RUN )); then
        _ku_mg_ask rollback "$question"
    fi
    if (( write )); then
        _ku_mg_rollback_write "$dir" "$expected" "$sum"
    else
        _ku_mg_retire_export grub.cfg "$sum"
    fi
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    _ku_mg_rolled_back "$dir"
}

# Undo a run of the menu stage that wrote kali.cfg alone, whose backup is DIR: write kali.cfg
# back to partition 1 as the run read it, or export it, as _ku_mg_rollback_menu does grub.cfg.
# A kali.cfg the run wrote where none was stays, since grub.cfg sources it: without it the
# stick's Kali entry only says that it is missing; only the backup is marked as rolled back.
_ku_mg_rollback_kali() {
    local dir=$1 stamp=${1##*/} status=0 expected=- sum="" write=0 run
    run="rollback of the menu stage run $stamp, which wrote kali.cfg alone:"
    if [[ ! -f $dir/kali.cfg && ! -f $dir/kali.cfg.absent ]]; then
        ku_die "$KU_EX_REFUSED" "the backup $stamp holds nothing to restore; nothing was changed"
    fi
    if [[ -f $dir/kali.cfg.absent ]]; then
        ku_plan "$run kali.cfg was missing before, and stays as the run wrote it, since" \
            "grub.cfg sources it and without it the stick's Kali entry only says that it is" \
            "missing; only the backup is marked as rolled back"
    else
        _ku_mg_resolve
        _ku_mg_tmpdir
        ku_deploy_read "$KU_DK_ROOT" "$KU_MG_KALI" "$KU_MG_TMP/current-kali.cfg" || status=$?
        case $status in
            0) expected=$KU_DEPLOY_SUM ;;
            2) ;;
            *)
                ku_die "$KU_EX_NOINPUT" "cannot read $KU_MG_KALI: $KU_DK_PROBLEM; nothing was" \
                    "changed"
                ;;
        esac
        sum=$(ku_sha256 "$dir/kali.cfg") || _ku_mg_damaged "$stamp" "its kali.cfg cannot be read"
        if [[ $sum != "$expected" || $KU_DK_DEPLOY == export ]]; then
            write=1
        fi
        if [[ $KU_DK_DEPLOY == export ]]; then
            ku_plan "$run export kali.cfg as it was before to output_dir for Windows to" \
                "copy: $KU_DK_DEPLOY_WHY"
        elif (( ! write )); then
            ku_plan "$run kali.cfg is as the backup holds it already, so only the backup" \
                "is marked as rolled back"
        else
            ku_plan "$run write kali.cfg back to partition 1 as it was before (deploy =" \
                "$KU_DK_DEPLOY)"
        fi
        if [[ $KU_DK_DEPLOY != export ]] && _ku_mg_stale_export kali.cfg "$sum"; then
            _ku_mg_stale_plan
        fi
        if (( write )); then
            _ku_mg_drift_plan "$KU_MG_KALI" "$expected"
        fi
    fi
    if (( ! KU_DRY_RUN )); then
        _ku_mg_ask rollback "Roll the menu stage run $stamp back as planned?"
    fi
    if (( write )); then
        _ku_mg_kali_deploy "$dir/kali.cfg" "$expected" "$sum"
    elif [[ -n $sum ]]; then
        _ku_mg_retire_export kali.cfg "$sum"
    fi
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    _ku_mg_rolled_back "$dir"
}

# Write the backup DIR's grub.cfg, with the SHA-256 SUM, to partition 1 over the grub.cfg read
# with the SHA-256 EXPECTED, remove an export it makes stale, and record it in the tripwire's
# baseline; or export it. A dry run only says what it would.
_ku_mg_rollback_write() {
    if [[ $KU_DK_DEPLOY == export ]]; then
        _ku_mg_export "$1/grub.cfg"
        return 0
    fi
    _ku_mg_deploy_files "$KU_DK_ROOT" "$KU_MG_GRUB" "$1/grub.cfg" "$2"
    _ku_mg_retire_export grub.cfg "$3"
    if ! _ku_mg_baseline_set "$KU_MG_GRUB" "$2" "$3"; then
        ku_log warning "the tripwire's baseline was not updated, as none is stored or it is" \
            "damaged: run '$KU_CMD baseline'"
    fi
    _ku_mg_drift_warn
}

# Check the Kali entries of the grub.cfg FILE from the backup STAMP, which a rollback of the menu
# stage writes back: they boot kernels by their versions, as /vmlinuz-VERSION, which kernel
# updates remove in time, and GRUB then reports the file not found. Adds a plan line naming
# the kernels /boot no longer holds, and exits 3 when not one of the entries' kernels is there,
# since the stick would then keep no Kali entry that boots; kali.cfg's entries keep booting
# the kernels linux-base links instead, when KALI, how ku_deploy_read found kali.cfg on
# partition 1, is 0, and else the menu stage writes kali.cfg anew.
_ku_mg_legacy_kernels() {
    local file=$1 stamp=$2 kali=$3 key kernel name found=0 other=0 list
    local re='^(\([^)]*\))?(/boot)?/([^/]+)$'
    local -a missing=()
    local -A seen=()
    if ! _ku_mg_scan "$file" || (( KU_MG_UNBALANCED )); then
        ku_die "$KU_EX_REFUSED" "the Kali entries of the grub.cfg in the backup $stamp cannot" \
            "be read, so whether they would boot is unknown; nothing was changed"
    fi
    for key in "${KU_MG_ENTRIES[@]}"; do
        [[ -n ${KU_MG_KERNEL[$key]+set} ]] || continue
        kernel=${KU_MG_KERNEL[$key]}
        name=""
        if [[ $kernel =~ $re ]]; then
            name=${BASH_REMATCH[3]}
        fi
        if [[ -n $name ]] && _ku_mg_boot_file "$name"; then
            found=1
        elif [[ $name == vmlinu[xz]-* ]] && ku_valid_release "${name#vmlinu?-}"; then
            if [[ -z ${seen[$name]+set} ]]; then
                seen[$name]=1
                missing+=("${name#vmlinu?-}")
            fi
        else
            other=$((other + 1))
        fi
    done
    list=""
    if (( ${#missing[@]} )); then
        list=$(ku_join "${missing[@]}")
    fi
    if (( ! found )) && (( kali == 0 )); then
        ku_die "$KU_EX_REFUSED" "the Kali entries of the grub.cfg in the backup $stamp boot no" \
            "kernel /boot holds now${list:+ (they name $list)}, so written back it would leave" \
            "the stick without a Kali entry that boots: the menu stage stays, and kali.cfg's" \
            "entries keep booting the kernels linux-base links; nothing was changed"
    elif (( ! found )); then
        ku_die "$KU_EX_REFUSED" "the Kali entries of the grub.cfg in the backup $stamp boot no" \
            "kernel /boot holds now${list:+ (they name $list)}, so written back it would leave" \
            "the stick without a Kali entry that boots: the menu stage stays. kali.cfg, which" \
            "grub.cfg sources, is missing or cannot be read too: run '$KU_CMD migrate" \
            "--stage menu', which writes it anew from the legacy entries; nothing was changed"
    fi
    if [[ -n $list ]]; then
        ku_plan "the Kali entries of the grub.cfg put back that boot $list will fail, as" \
            "/boot no longer holds that kernel"
    fi
    if (( other )); then
        ku_plan "$other Kali entr(ies) of the grub.cfg put back load a kernel that migrate" \
            "cannot find in /boot"
    fi
}

# Return 0 when GRUB, reading the /boot filesystem, would load the file NAME there: a non-empty
# regular file, or a relative symlink in /boot to one, as the links in /boot are.
_ku_mg_boot_file() {
    local boot name=$1 target
    boot=$(ku_path /boot)
    if [[ -L $boot/$name ]]; then
        target=$(readlink -- "$boot/$name") || return 1
        [[ -n $target && $target != */* && ! -L $boot/$target ]] || return 1
        name=$target
    fi
    [[ -f $boot/$name && -s $boot/$name ]]
}

# Rename the backup directory DIR to DIR.rolled-back once its rollback is done. Exits 4 when
# that fails.
_ku_mg_rolled_back() {
    if ! mv -T -- "$1" "$1.rolled-back"; then
        ku_die "$KU_EX_WRITE" "the rollback is done, but $KU_MG_BACKUPS/${1##*/} cannot be" \
            "renamed: rename it to ${1##*/}.rolled-back by hand"
    fi
    ku_log info "migrate rollback: done; the backup is $KU_MG_BACKUPS/${1##*/}.rolled-back now"
}

# =======================================================
#                  PRECONDITIONS AND I/O
# =======================================================

# Exit 3 unless the configuration sets the five keys detect fills.
_ku_mg_need_detect() {
    local key
    local -a missing=()
    for key in "${KU_MG_KEYS[@]}"; do
        [[ -n ${KU_CONF[$key]} ]] || missing+=("$key")
    done
    if (( ${#missing[@]} )); then
        ku_die "$KU_EX_REFUSED" "the configuration lacks $(ku_join "${missing[@]}"): run" \
            "'$KU_CMD migrate --stage detect' first; nothing was changed"
    fi
}

# Exit 3 unless the system stage's result is in place: kernel-img.conf has linux-base keep the
# links in /boot, and the four are relative and reach non-empty files there.
_ku_mg_need_system() {
    local problem
    problem=$(ku_probe_boot_links | ku_boot_links_problems)
    if ! _ku_mg_links_in_boot; then
        problem="kernel-img.conf does not have linux-base keep the links in /boot"
    fi
    if [[ -n $problem ]]; then
        ku_die "$KU_EX_REFUSED" "$problem: run '$KU_CMD migrate --stage system' first;" \
            "nothing was changed"
    fi
}

# Exit 3 unless grub-script-check is installed, which checks the new menu before it is written.
_ku_mg_need_check_tool() {
    if ! command -v grub-script-check > /dev/null; then
        ku_die "$KU_EX_REFUSED" "grub-script-check, from the package grub-common, is needed to" \
            "check the new menu; nothing was changed"
    fi
}

# Pick how the files reach partition 1 and reach a root to read it from, or exit 66 when there
# is none, as ku_deploy_resolve says; it exits 78 itself on another stick.
_ku_mg_resolve() {
    if ! ku_deploy_resolve; then
        ku_die "$KU_EX_NOINPUT" "cannot reach partition 1: $KU_DK_PROBLEM; nothing was changed"
    fi
}

# Copy grub.cfg from partition 1 into the file DEST, with its SHA-256 in KU_DEPLOY_SUM. Exits
# 66 when it is missing or cannot be read.
_ku_mg_read_grub() {
    local status=0
    ku_deploy_read "$KU_DK_ROOT" "$KU_MG_GRUB" "$1" || status=$?
    if (( status == 2 )); then
        ku_die "$KU_EX_NOINPUT" "partition 1 holds no $KU_MG_GRUB; nothing was changed"
    elif (( status )); then
        ku_die "$KU_EX_NOINPUT" "cannot read $KU_MG_GRUB: $KU_DK_PROBLEM; nothing was changed"
    fi
}

# Return 0 when partition 1's grub.cfg holds migrate's block that sources kali.cfg, and 1 when
# it holds none or does not exist. Returns 2, with KU_DK_PROBLEM set, when that cannot be told:
# partition 1 cannot be found from /boot, is another than the configuration names, or cannot be
# read. Finds and reads it read-only, as check does, with a mount of its own that it removes.
_ku_mg_p1_sources_kali() {
    local status=0
    if [[ -z $KU_P1_DIR ]]; then
        ku_disk_find || return 2
        ku_disk_identity || status=$?
        if (( status == 1 )); then
            KU_DK_PROBLEM=$(ku_disk_identity_problem)
            return 2
        fi
    fi
    ku_p1_open ro || return 2
    _ku_mg_tmpdir
    status=0
    ku_deploy_read "$KU_DK_ROOT" "$KU_MG_GRUB" "$KU_MG_TMP/p1-grub.cfg" || status=$?
    _ku_mg_p1_close
    case $status in
        0) ;;
        2) return 1 ;;
        *) return 2 ;;
    esac
    ku_menu_sources_kali "$KU_MG_TMP/p1-grub.cfg"
}

# Print the output_dirs an export of an earlier run may wait in, one per line: the one the
# configuration names, which check's deployed item and DEPLOY.txt point at, and the one
# --output-dir gave this run, when it is another.
_ku_mg_export_dirs() {
    local conf=${KU_MG_CONF_OUTPUT:-${KU_CONF[output_dir]}}
    printf '%s\n' "$conf"
    if [[ ${KU_CONF[output_dir]} != "$conf" ]]; then
        printf '%s\n' "${KU_CONF[output_dir]}"
    fi
}

# Return 0 when an output_dir of _ku_mg_export_dirs holds an export that a write of the NAMEs,
# given as NAME HASH pairs, makes stale (_ku_mg_stale_in). Returns 1 otherwise.
_ku_mg_stale_export() {
    local dir
    while IFS= read -r dir; do
        _ku_mg_stale_in "$dir" "$@" && return 0
    done < <(_ku_mg_export_dirs)
    return 1
}

# Return 0 when the output_dir DIR holds an export whose SHA256SUMS lists one of the NAMEs,
# given as NAME HASH pairs, with another SHA-256 than its HASH: an export from an earlier run
# that a write of those files to partition 1 makes stale, and that, copied after the write,
# would undo it. Returns 1 otherwise, also when DIR holds no export.
_ku_mg_stale_in() {
    local sums line
    local -A want=()
    sums=$(ku_path "$1")/SHA256SUMS
    shift
    [[ -f $sums && ! -L $sums && -r $sums ]] || return 1
    while (( $# >= 2 )); do
        want[$1]=$2
        shift 2
    done
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([0-9a-f]{64})\ [\ *]([A-Za-z0-9][A-Za-z0-9._+-]*)$ ]] || continue
        if [[ -n ${want[${BASH_REMATCH[2]}]+set} &&
            ${want[${BASH_REMATCH[2]}]} != "${BASH_REMATCH[1]}" ]]; then
            return 0
        fi
    done < "$sums"
    return 1
}

# After a write to partition 1 of the NAMEs, given as NAME HASH pairs, remove each export in an
# output_dir of _ku_mg_export_dirs that _ku_mg_stale_in finds stale, so that check's deployed
# item no longer asks for it to be copied, and no DEPLOY.txt says to: SHA256SUMS first, then
# DEPLOY.txt and the files SHA256SUMS listed, as far as they are regular files, never anything
# else there, and only from an output_dir of root's closed to group and others, on a path no
# other user can change, as ku_export takes one. Only warns when that fails, as the write is
# done; with --dry-run it only says that it would.
_ku_mg_retire_export() {
    local out
    while IFS= read -r out; do
        _ku_mg_stale_in "$out" "$@" || continue
        if (( KU_DRY_RUN )); then
            ku_log info "dry run: would remove the export in output_dir, which this write" \
                "makes stale"
        else
            _ku_mg_retire_in "$(ku_path "$out")"
        fi
    done < <(_ku_mg_export_dirs)
}

# Remove the stale export in the output_dir DIR, as _ku_mg_retire_export says.
_ku_mg_retire_in() {
    local dir=$1 info owner mode line name
    local -a names=()
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[0-9a-f]{64}\ [\ *]([A-Za-z0-9][A-Za-z0-9._+-]*)$ ]]; then
            names+=("${BASH_REMATCH[1]}")
        fi
    done < "$dir/SHA256SUMS"
    info=$(stat -L -c '%u %a' -- "$dir" 2> /dev/null) || info=""
    read -r owner mode <<< "$info"
    if [[ -L $dir || $owner != 0 || ! $mode =~ ^[0-7]+$ ]] || (( (8#$mode & 8#077) != 0 )) ||
        ! ku_p1_root_only "$dir" || ! rm -f -- "$dir/SHA256SUMS"; then
        ku_log warning "output_dir holds an export from an earlier run that this write makes" \
            "stale, and it cannot be removed: do not copy it, and remove it by hand"
        return 0
    fi
    for name in DEPLOY.txt "${names[@]}"; do
        if [[ $name != SHA256SUMS && -f $dir/$name && ! -L $dir/$name ]] &&
            ! rm -f -- "$dir/$name"; then
            ku_log warning "cannot remove $name of the stale export in output_dir: remove it" \
                "by hand"
        fi
    done
    ku_log info "removed the export in output_dir, which this write made stale: copied, it" \
        "would have undone the write"
}

# Read the Kali submenus of the grub.cfg FILE and set KU_MG_FOUND to the one migrate works on:
# the one Kali submenu when ONE is 1, or the one whose title ends in SUFFIX. Exits 3 when the
# braces or quotes do not balance, when there is not exactly one such submenu, when it lies
# between MultiBootUSB's markers, or when it shares its first or last line with other commands.
# With ONE 0, no submenu with SUFFIX leaves KU_MG_COUNT at 0.
_ku_mg_scan_one() {
    local file=$1 suffix=$2 one=$3 n count=0
    KU_MG_FOUND=""
    if ! _ku_mg_scan "$file" || (( KU_MG_UNBALANCED )); then
        ku_die "$KU_EX_REFUSED" "the braces or quotes of grub.cfg do not balance, so its Kali" \
            "submenu cannot be told; nothing was changed"
    fi
    for (( n = 1; n <= KU_MG_COUNT; n++ )); do
        if (( one )) || [[ ${KU_MG_RAWTITLE[$n]:1:-1} == *"$suffix" ]]; then
            count=$((count + 1))
            KU_MG_FOUND=$n
        fi
    done
    if (( one && count != 1 )); then
        ku_die "$KU_EX_REFUSED" "grub.cfg holds $count Kali submenus; migrate needs exactly one;" \
            "nothing was changed"
    elif (( ! one && count > 1 )); then
        ku_die "$KU_EX_REFUSED" "grub.cfg holds $count submenus of legacy Kali entries, where" \
            "migrate wrote one; nothing was changed"
    fi
    if (( ! one )); then
        KU_MG_COUNT=$count
        (( count )) || return 0
    fi
    n=$KU_MG_FOUND
    if (( KU_MG_MARKED[$n] )); then
        ku_die "$KU_EX_REFUSED" "the Kali submenu of grub.cfg lies between MultiBootUSB's #start" \
            "and #end markers, between which its uninstaller removes or rewrites what it finds:" \
            "move it out of them first; nothing was changed"
    elif (( ! KU_MG_TIDY[$n] )); then
        ku_die "$KU_EX_REFUSED" "the Kali submenu of grub.cfg shares its first or last line" \
            "with other commands: give it lines of its own first; nothing was changed"
    fi
}

# Read the Kali submenus of the GRUB config FILE with menu.awk into the KU_MG_* settings that
# hold them. Returns 1 when menu.awk fails.
_ku_mg_scan() {
    local out kind a b c d e f
    KU_MG_COUNT=0 KU_MG_UNBALANCED=0 KU_MG_ENTRIES=()
    KU_MG_START=() KU_MG_END=() KU_MG_MARKED=() KU_MG_TIDY=() KU_MG_RAWTITLE=()
    KU_MG_ENTRY=() KU_MG_LINUX=() KU_MG_KERNEL=() KU_MG_WORDS=()
    out=$(LC_ALL=C KU_MENU_CFG=$1 "$KU_AWK" -f "$KU_LIBDIR/menu.awk") || return 1
    while IFS=$'\t' read -r kind a b c d e f; do
        case $kind in
            kali)
                KU_MG_COUNT=$((KU_MG_COUNT + 1))
                KU_MG_START[$a]=$b KU_MG_END[$a]=$c KU_MG_MARKED[$a]=$d KU_MG_TIDY[$a]=$e
                KU_MG_RAWTITLE[$a]=$f
                ;;
            entry) KU_MG_ENTRIES+=("$a.$b") KU_MG_ENTRY[$a.$b]=$d ;;
            linux) KU_MG_LINUX[$a.$b]=$c KU_MG_KERNEL[$a.$b]=$d ;;
            param) KU_MG_WORDS[$a.$b]+=$c$'\n' ;;
            error) KU_MG_UNBALANCED=1 ;;
        esac
    done <<< "$out"
}

# Return 0 when the GRUB config FILE holds migrate's marker comment line, which opens the block
# that sources kali.cfg, with LF or CRLF line endings. Shared with check's kali-menu item.
ku_menu_sources_kali() {
    grep -q -x -F -e "$KU_MG_MARKER" -e "$KU_MG_MARKER"$'\r' -- "$1"
}

# Print how many top-level submenus of the GRUB config FILE hold legacy Kali entries: their
# quoted titles hold Kali and end in " (legacy entries)". Returns 1 when its braces or quotes
# do not balance. Shared with check's kali-menu item.
ku_menu_legacy_count() {
    local n count=0
    if ! _ku_mg_scan "$1" || (( KU_MG_UNBALANCED )); then
        return 1
    fi
    for (( n = 1; n <= KU_MG_COUNT; n++ )); do
        if [[ ${KU_MG_RAWTITLE[$n]:1:-1} == *"$KU_MG_LEGACY" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

# Make the private directory the stage works in, in /run under KU_ROOT, where only root can
# rename entries, as check makes its own; the exit trap removes it. Exits 3 when /run is not
# such a directory and 4 when mktemp fails.
_ku_mg_tmpdir() {
    local parent
    [[ -z $KU_MG_TMP ]] || return 0
    parent=$(ku_path /run)
    if ! ku_root_only_dir "$parent"; then
        ku_die "$KU_EX_REFUSED" "/run is not a directory whose entries only root can rename," \
            "so migrate has no private place to work in; nothing was changed"
    fi
    _ku_mg_cleanup_add
    if ! KU_MG_TMP=$(mktemp -d "$parent/kernel-updater.XXXXXXXX"); then
        KU_MG_TMP=""
        ku_die "$KU_EX_WRITE" "mktemp cannot make a directory in /run; nothing was changed"
    fi
}

# Make the backup directory of a stage run of STAGE, KU_MG_BACKUP, in
# /var/backups/kernel-updater with mode 0700, and write STAGE into its stage file. Its name,
# KU_MG_STAMP, is the UTC stamp of now, or one second after the newest backup there, rolled
# back or not, when the clock reads no later than that one: so the names sort in the order the
# stage runs happened, which --rollback undoes newest first, also when two runs fall in one
# second, as 'migrate --yes' runs system and menu, and when a clock is behind another, as a
# native boot that takes Windows' local time for UTC is behind the VM. The exit trap removes
# the backup until its MANIFEST is written (_ku_mg_backup_drop), from before mkdir makes it on,
# so that a run cut short right after mkdir leaves none. Exits 1 when date gives no stamp, 3
# when the name is taken, and 4 when the directory cannot be made.
_ku_mg_backup_dir() {
    local base stamp newest
    base=$(ku_path "$KU_MG_BACKUPS")
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    if [[ ! $stamp =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
        ku_die "$KU_EX_FAILURE" "date prints no UTC stamp; nothing was changed"
    fi
    newest=$(_ku_mg_newest_stamp "$base")
    if [[ -n $newest ]] && (( 10#${stamp//[TZ]/} <= 10#${newest//[TZ]/} )); then
        if [[ $stamp != "$newest" ]]; then
            ku_log info "the clock reads earlier than the newest backup, $newest, so this" \
                "run's backup is named one second after it, which keeps the stage runs in the" \
                "order they ran"
        fi
        if ! stamp=$(_ku_mg_stamp_after "$newest"); then
            ku_die "$KU_EX_FAILURE" "date cannot give the stamp one second after $newest;" \
                "nothing was changed"
        fi
    fi
    if [[ -e $base/$stamp || -L $base/$stamp ]]; then
        ku_die "$KU_EX_REFUSED" "the backup directory $KU_MG_BACKUPS/$stamp exists already;" \
            "nothing was changed"
    fi
    _ku_mg_cleanup_add
    if mkdir -p -- "$base"; then
        KU_MG_BACKUP=$base/$stamp KU_MG_STAMP=$stamp KU_MG_SEALED=0
        if (umask 077 && mkdir -- "$KU_MG_BACKUP"); then
            printf '%s\n' "$1" > "$KU_MG_BACKUP/stage" || _ku_mg_backup_fail
            return 0
        fi
    fi
    KU_MG_BACKUP=""
    ku_die "$KU_EX_WRITE" "cannot make the backup directory $KU_MG_BACKUPS/$stamp; nothing was" \
        "changed"
}

# Print the newest stamp that names a backup directory in BASE, rolled back or not, or nothing
# when there is none.
_ku_mg_newest_stamp() {
    local dir name newest=""
    for dir in "$1"/*; do
        name=${dir##*/}
        [[ $name =~ ^([0-9]{8}T[0-9]{6}Z)(\.|$) ]] || continue
        name=${BASH_REMATCH[1]}
        if [[ -z $newest ]] || (( 10#${name//[TZ]/} > 10#${newest//[TZ]/} )); then
            newest=$name
        fi
    done
    printf '%s' "$newest"
}

# Print the UTC stamp one second after STAMP, as GNU date counts. Returns 1 when it cannot.
_ku_mg_stamp_after() {
    local s=$1 epoch out
    epoch=$(date -u -d "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2} UTC" +%s) ||
        return 1
    [[ $epoch =~ ^[0-9]+$ ]] || return 1
    out=$(date -u -d "@$(( epoch + 1 ))" +%Y%m%dT%H%M%SZ) || return 1
    [[ $out =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
    printf '%s\n' "$out"
}

# Exit 4, saying that the backup could not be written: _ku_mg_backup_drop removed it again, so
# nothing was changed; or, when that fails too, which directory to remove by hand.
_ku_mg_backup_fail() {
    if _ku_mg_backup_drop; then
        ku_die "$KU_EX_WRITE" "cannot write the backup in $KU_MG_BACKUPS, which was removed" \
            "again; nothing was changed"
    fi
    KU_MG_BACKUP=""
    ku_die "$KU_EX_WRITE" "cannot write the backup $KU_MG_BACKUPS/$KU_MG_STAMP, nor remove it" \
        "again: remove that directory by hand, or leave it to the next --rollback, which" \
        "passes over it; nothing else was changed"
}

# Remove this run's backup directory while its MANIFEST is not written, as after a write into
# it failed or the run was cut short: the stage has changed nothing else then, and a backup
# without a MANIFEST would stop every later --rollback. Removes the files a stage puts there,
# then the directory; should that fail, renames it to STAMP.failed, which --rollback passes
# over. Returns 1 when neither works.
_ku_mg_backup_drop() {
    local name
    [[ -n $KU_MG_BACKUP ]] && (( ! KU_MG_SEALED )) || return 0
    if [[ ! -e $KU_MG_BACKUP && ! -L $KU_MG_BACKUP ]]; then
        KU_MG_BACKUP=""
        return 0
    fi
    for name in MANIFEST MANIFEST.new stage deploy written kernel-img.conf \
        kernel-img.conf.absent root-links.list grub.cfg kali.cfg kali.cfg.absent; do
        rm -f -- "$KU_MG_BACKUP/$name" || :
    done
    if ! rmdir -- "$KU_MG_BACKUP" 2> /dev/null &&
        ! mv -T -- "$KU_MG_BACKUP" "$KU_MG_BACKUP.failed"; then
        return 1
    fi
    KU_MG_BACKUP=""
}

# Seal the backup before an export, which writes nothing on the stick, once output_dir passed
# its checks or was made (ku_export_dir): an output_dir that cannot serve then stops the stage
# with an unsealed backup, which the exit trap removes. A write to partition 1 leaves sealing to
# ku_deploy_write, which calls _ku_mg_seal before it changes the first file: a stage the writer
# stops before that (75, 3 or 4) then leaves an unsealed backup too, instead of one a later
# --rollback would undo although the stage wrote nothing.
_ku_mg_seal_export() {
    if [[ $KU_DK_DEPLOY == export ]]; then
        ku_export_dir "$(ku_path "${KU_CONF[output_dir]}")"
        _ku_mg_manifest
    fi
}

# The KU_DEPLOY_BEFORE_WRITE of migrate's writes: seal this run's backup when it has one that
# is not sealed yet. A rollback, which makes no backup, passes through.
_ku_mg_seal() {
    if [[ -n $KU_MG_BACKUP ]] && (( ! KU_MG_SEALED )); then
        _ku_mg_manifest
    fi
}

# ku_deploy_files with _ku_mg_seal as the hook of its first write, so that only migrate's own
# writes seal its backup, and no other caller of the writer runs it.
# shellcheck disable=SC2034 # KU_DEPLOY_BEFORE_WRITE is read by ku_deploy_write in deploy.sh
_ku_mg_deploy_files() {
    KU_DEPLOY_BEFORE_WRITE=_ku_mg_seal
    ku_deploy_files "$@"
    KU_DEPLOY_BEFORE_WRITE=""
}

# Write the MANIFEST of the backup directory: "SHA256  NAME" for each file the stage put in
# it, as sha256sum writes them, so that a rollback trusts only a whole backup. It goes to
# MANIFEST.new first, which is flushed to the disk and then renamed, so that a power loss
# leaves either no MANIFEST, a backup --rollback passes over, or a whole one, never a truncated
# one that would stop every --rollback. The rename is flushed too, so that the backup is on
# the disk before the stage changes what it may restore, which a crash could otherwise leave
# changed beside an empty backup. From then on the backup stays, whatever happens.
_ku_mg_manifest() {
    local name hash sums=""
    for name in stage deploy written kernel-img.conf kernel-img.conf.absent root-links.list \
        grub.cfg kali.cfg kali.cfg.absent; do
        [[ -f $KU_MG_BACKUP/$name ]] || continue
        hash=$(ku_sha256 "$KU_MG_BACKUP/$name") || _ku_mg_backup_fail
        sums+="$hash  $name"$'\n'
    done
    printf '%s' "$sums" > "$KU_MG_BACKUP/MANIFEST.new" || _ku_mg_backup_fail
    sync -f -- "$KU_MG_BACKUP" || _ku_mg_backup_fail
    mv -T -f -- "$KU_MG_BACKUP/MANIFEST.new" "$KU_MG_BACKUP/MANIFEST" || _ku_mg_backup_fail
    sync -f -- "$KU_MG_BACKUP" || _ku_mg_backup_fail
    KU_MG_SEALED=1
}

# Record in the backup directory the SHA-256 of each file the stage run writes or exports,
# given as NAME HASH pairs, in a file named written that the MANIFEST covers, so that a
# rollback can tell whether a file changed on partition 1 after the run wrote it.
_ku_mg_written() {
    local sums=""
    while (( $# >= 2 )); do
        sums+="$2  $1"$'\n'
        shift 2
    done
    printf '%s' "$sums" > "$KU_MG_BACKUP/written" || _ku_mg_backup_fail
}

# Print the SHA-256 that the stage run of the backup directory DIR recorded for the file NAME
# it wrote, or nothing when it recorded none.
_ku_mg_written_sum() {
    local line
    [[ -f $1/written ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^([0-9a-f]{64})\ \ (.+)$ && ${BASH_REMATCH[2]} == "$2" ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$1/written"
}

# Print the mode of FILE in octal, or 644 when stat cannot tell.
_ku_mg_mode() {
    local mode
    mode=$(stat -c %a -- "$1" 2> /dev/null) || mode=""
    [[ $mode =~ ^[0-7]{3,4}$ ]] || mode=644
    printf '%s\n' "$mode"
}

# Make the temporary file KU_MG_ETC_TMP beside FILE, which the exit trap removes unless it was
# renamed over FILE. Exits 4 when mktemp fails.
_ku_mg_etc_tmp() {
    _ku_mg_cleanup_add
    if ! KU_MG_ETC_TMP=$(mktemp -- "${1%/*}/.${1##*/}.ku-XXXXXXXX"); then
        KU_MG_ETC_TMP=""
        ku_die "$KU_EX_WRITE" "cannot make a temporary file beside ${1#"${KU_ROOT%/}"}; it is" \
            "as it was"
    fi
}

# Put KU_MG_ETC_TMP in the place of FILE, shown as NAME: with MODE, owned by root when run as
# root, and renamed over it with mv -T, so that FILE is never seen half written. Exits 4 when
# that fails, leaving FILE as it was.
_ku_mg_etc_finish() {
    if ! chmod "$2" -- "$KU_MG_ETC_TMP" ||
        { [[ $(id -u) == 0 ]] && ! chown 0:0 -- "$KU_MG_ETC_TMP"; } ||
        ! mv -T -f -- "$KU_MG_ETC_TMP" "$1"; then
        _ku_mg_etc_fail "$3"
    fi
    KU_MG_ETC_TMP=""
}

# Remove KU_MG_ETC_TMP and exit 4, saying that NAME is as it was.
_ku_mg_etc_fail() {
    rm -f -- "$KU_MG_ETC_TMP" || :
    KU_MG_ETC_TMP=""
    ku_die "$KU_EX_WRITE" "cannot write $1; it is as it was"
}

# Replace FILE, shown as NAME, with a copy of SOURCE as _ku_mg_etc_finish writes it, keeping
# FILE's mode, or 0644 for a new one.
_ku_mg_etc_copy() {
    local source=$1 file=$2 mode=644
    if [[ -e $file ]]; then
        mode=$(_ku_mg_mode "$file")
    fi
    _ku_mg_etc_tmp "$file"
    cat -- "$source" > "$KU_MG_ETC_TMP" || _ku_mg_etc_fail "$3"
    _ku_mg_etc_finish "$file" "$mode" "$3"
}

# Register the exit trap's cleanup once.
_ku_mg_cleanup_add() {
    if (( ! KU_MG_CLEANUP )); then
        ku_cleanup_add _ku_mg_cleanup
        KU_MG_CLEANUP=1
    fi
}

# Exit trap: remove a backup that has no MANIFEST yet (_ku_mg_backup_drop), the temporary file
# in /etc a cut-short write left, and the private directory with the files the stage made in
# it, file by file.
_ku_mg_cleanup() {
    local status=0
    if ! _ku_mg_backup_drop; then
        ku_log warning "the unfinished backup $KU_MG_BACKUPS/$KU_MG_STAMP stays: remove it by" \
            "hand, or leave it to the next --rollback, which passes over it"
    fi
    if [[ -n $KU_MG_ETC_TMP ]]; then
        rm -f -- "$KU_MG_ETC_TMP" || status=1
    fi
    if [[ -n $KU_MG_TMP && -d $KU_MG_TMP ]]; then
        if [[ -d $KU_MG_TMP/i386-pc ]]; then
            rm -f -- "$KU_MG_TMP"/i386-pc/* || status=1
            rmdir -- "$KU_MG_TMP/i386-pc" || status=1
        fi
        rm -f -- "$KU_MG_TMP"/* || status=1
        rmdir -- "$KU_MG_TMP" || status=1
    fi
    return "$status"
}

# Remove partition 1's private mount after a read, or warn that it stays, which the exit trap
# then tries again to remove.
_ku_mg_p1_close() {
    if ! ku_p1_close; then
        ku_log warning "the read-only mount of partition 1 stays on $KU_DK_MOUNT_DIR/p1:" \
            "unmount it and remove $KU_DK_MOUNT_DIR by hand"
    fi
}

# Ask PROMPT for STAGE, and exit 10, saying that the stage changed nothing, unless the answer
# is yes.
_ku_mg_ask() {
    local stage=$1
    shift
    ku_ask "$*" || ku_die "$KU_EX_DECLINED" "declined; the $stage stage changed nothing"
}

# Print TEXT, a title from grub.cfg, in double quotes, or a neutral phrase when it holds what
# could be an identifier, a run of 8 hex digits or a device path, or a control character.
_ku_mg_shown() {
    if [[ $1 =~ [0-9A-Fa-f]{8} || $1 == */dev/* || $1 == *[[:cntrl:]]* ]]; then
        printf '(a title that looks like data)'
    else
        printf '"%s"' "$1"
    fi
}

# Print the kernel parameters WORDS, one line of them, each after a blank, as a plan shows them:
# a word that may name a device, a UUID, a serial, a label or a key file, whose value holds a
# run of 8 hex digits, /dev/, UUID= or LABEL=, as PARTUUID= does, or whose name holds key, shows
# as NAME=<value>, or <value> without a name. kali.cfg gets the words themselves.
_ku_mg_shown_params() {
    local word name
    local -a words=()
    read -r -a words <<< "$1"
    for word in "${words[@]}"; do
        name=""
        if [[ $word == ?*=* ]]; then
            name=${word%%=*}
        fi
        if [[ $word =~ [0-9A-Fa-f]{8} || ${word^^} == *UUID=* || ${word^^} == *LABEL=* ||
            $word == */dev/* || ${name,,} == *key* ]]; then
            word=${name:+$name=}"<value>"
        fi
        printf ' %s' "$word"
    done
}
