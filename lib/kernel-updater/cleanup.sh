# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater cleanup
#
# The cleanup command: purges, in one apt-get run, the config files removed kernels left and the
# old kernels apt's autoremove names, once a simulation shows that apt would remove exactly
# those, never the running kernel or one the links in /boot point at, and moves module trees
# no package owns into a quarantine, from which they expire. It checks first, in a dry run too,
# that it may run. Defines functions and settings only.
# -------------------------------------------------------

# The steps --no-rc, --no-autoremove and --no-modules leave out, by name: rc, autoremove and
# modules.
declare -gA KU_CL_SKIP=()

# The variables no tool cleanup runs inherits: they point dpkg at another root or database, pass
# it force flags, change apt's configuration, or tell dpkg that a frontend holds the lock it
# would take. SOURCE_DATE_EPOCH, which the container tests set for apt, goes too unless
# KU_TEST=1.
KU_CL_ENV_DROP=(DPKG_ROOT DPKG_ADMINDIR DPKG_FORCE APT_CONFIG DPKG_FRONTEND_LOCKED)
if [[ ${KU_TEST:-} != 1 ]]; then
    KU_CL_ENV_DROP+=(SOURCE_DATE_EPOCH)
fi

# What the plan rests on, as _ku_cl_snapshot printed it before the plan: taken anew and
# compared after the question, and its dpkg part after a purge that failed or was cut short.
KU_CL_SNAPSHOT=""

# The releases cleanup keeps, each with why, as "running, vmlinuz" (KU_CL_KEEP), in the order
# found (KU_CL_KEEP_ORDER), and the release /boot/vmlinuz points at while another kernel runs,
# which puts the purges off until a reboot (KU_CL_PENDING), or empty.
declare -gA KU_CL_KEEP=()
KU_CL_KEEP_ORDER=() KU_CL_PENDING=""

# The kernel packages dpkg lists, as ku_probe_kernel_packages printed them for the plan.
KU_CL_PACKAGES=""

# The rc step: the packages it purges (KU_CL_RC) and their releases (KU_CL_RC_REL), and those
# it leaves (KU_CL_RC_LEFT), each with the plan's action, skip or list (KU_CL_RC_ACTION), and
# why (KU_CL_RC_WHY).
KU_CL_RC=() KU_CL_RC_REL=() KU_CL_RC_LEFT=() KU_CL_RC_ACTION=() KU_CL_RC_WHY=()

# The autoremove step: the packages it purges (KU_CL_AR) and their releases (KU_CL_AR_REL), and
# those it leaves (KU_CL_AR_LEFT), each with the plan's action, skip or list (KU_CL_AR_ACTION),
# and why (KU_CL_AR_WHY); and the packages of old kernels marked manual, which apt never
# prunes (KU_CL_MANUAL).
KU_CL_AR=() KU_CL_AR_REL=() KU_CL_AR_LEFT=() KU_CL_AR_ACTION=() KU_CL_AR_WHY=() KU_CL_MANUAL=()

# The packages the one apt-get purge removes, the rc step's, then the autoremove step's
# (KU_CL_SET); those the last simulation would remove (KU_CL_SIM) and install or configure
# (KU_CL_SIM_OTHER); and why the plan cannot be made, or how the simulation of the purge
# differs from it (KU_CL_WHY).
KU_CL_SET=() KU_CL_SIM=() KU_CL_SIM_OTHER=() KU_CL_WHY=""

# 1 while apt-get purges, for the exit handler, and 1 once the run synced after the purge.
KU_CL_PURGING=0 KU_CL_SYNCED=0

# Where cleanup moves the module trees no package owns: one entry RELEASE.STAMP per tree, STAMP
# the UTC time it was made, holding origin, which says where the tree came from, the tree, and,
# once a later run found the entry, seen, which holds the UTC time of that run. quarantine_days
# count from the newer of the two times.
KU_CL_QUARANTINE=/var/lib/kernel-updater/quarantine

# The module trees step: the modules directories it scans (KU_CL_MODULES); the trees the plan
# shows (KU_CL_TREE), each with the plan's action, rmdir, quarantine, keep or list
# (KU_CL_TREE_ACTION), and why (KU_CL_TREE_WHY); whether mv can refuse to copy, 1 or 0, once
# known (KU_CL_MV), and why a tree cannot move into the quarantine (KU_CL_MOVE_WHY); and how
# many planned trees were removed, moved and left (KU_CL_REMOVED, KU_CL_MOVED, KU_CL_LEFT).
KU_CL_MODULES=() KU_CL_TREE=() KU_CL_TREE_ACTION=() KU_CL_TREE_WHY=() KU_CL_MV=""
KU_CL_MOVE_WHY="" KU_CL_REMOVED=0 KU_CL_MOVED=0 KU_CL_LEFT=0

# The device the quarantine is on, or will be, as _ku_cl_base_safe found it (KU_CL_BASE_DEV),
# and why cleanup may not act in the quarantine (KU_CL_BASE_WHY).
KU_CL_BASE_DEV="" KU_CL_BASE_WHY=""

# The expiry step: the quarantine entries the plan shows, or the quarantine itself
# (KU_CL_ENTRY), each with the plan's action, delete, keep, list or skip (KU_CL_ENTRY_ACTION),
# why (KU_CL_ENTRY_WHY) and, for an entry expiry may judge, its times as _ku_cl_entry_times
# printed them (KU_CL_ENTRY_TIMES); the time the plan was made, in seconds since the epoch
# (KU_CL_NOW), and the quarantine's device then (KU_CL_EXPIRY_DEV); and how many planned
# entries were deleted and left (KU_CL_EXPIRED, KU_CL_ENTRY_LEFT).
KU_CL_ENTRY=() KU_CL_ENTRY_ACTION=() KU_CL_ENTRY_WHY=() KU_CL_ENTRY_TIMES=() KU_CL_NOW=""
KU_CL_EXPIRY_DEV="" KU_CL_EXPIRED=0 KU_CL_ENTRY_LEFT=0

# The plan's records, with --porcelain, which go to stdout only once the run ends with 0.
KU_CL_RECORDS=""

# Print the cleanup command's usage on stdout.
ku_cleanup_usage() {
    cat << 'EOF'
Usage: kernel-updater cleanup [--no-rc] [--no-autoremove] [--no-modules] [-n] [-y] [--porcelain]

Purges, in one apt-get run, the config files removed kernels left and the old kernels apt's
autoremove names, once a simulation shows that apt would remove exactly those. It never purges
the running kernel or a kernel the links in /boot point at, and purges nothing while a reboot
into the kernel /boot/vmlinuz points at is pending. A module tree that no package owns is
removed when it is empty, and otherwise moved to /var/lib/kernel-updater/quarantine, from
where it can be moved back until it expires: once more than quarantine_days whole days have
passed since the move and since a later run first saw it there, unless the clock is behind.
The plan comes first, then one question. Purged packages cannot be rolled back, so read the
plan with -n first.

  --no-rc          leave the config files of removed kernels alone
  --no-autoremove  leave the old kernels apt's autoremove names alone
  --no-modules     leave the module trees alone, those in the quarantine too
  -n, --dry-run    print the plan, change nothing
  -y, --yes        answer yes to the question
  --porcelain      also print the plan on stdout as STEP, ACTION, OBJECT and DETAIL,
                   tab-separated, once the run ends with 0

Runs as root under the tool's lock, with /boot unlocked and mounted. Exits 0 when done, when
nothing was left to do and after a dry run, 3 when a check refuses, 4 when a purge, a move or
a deletion stopped partway, 10 when declined, 64 on a usage error, 66 when /boot is not mounted
or its LUKS header cannot be read, 75 when another run, apt or dpkg holds a lock or the system
changed while the question waited, 77 when not run as root and 78 when the configuration is
bad or names another /boot.
EOF
}

# Parse the options, then, as root and under the tool's lock, check that cleanup may run, in a
# dry run too, take the snapshot, plan the purge, the module trees and the expiry of the
# quarantine's entries, which writes seen, unless this is a dry run, and print the plan. With
# something to purge, remove, move or delete and no dry run, ask once, check the plan again, run
# the one apt-get purge, check the links and kernels again, check each planned module tree
# again and remove or move it, check each expired entry again and delete it, sync, and with
# --porcelain print the plan's records. Exits 0 when done, also when a re-check left a planned
# tree or entry, when nothing was left to do and after a dry run; 3 when a check or a simulation
# refuses, apt refused the purge, date prints no time or dpkg-query fails before anything was
# changed; 4 when the purge stopped after dpkg began to change its database, the check after it
# fails, a module tree cannot be removed or moved, or checked once something was changed, or a
# quarantine entry cannot be deleted; 10 when declined; 64 on a usage error; 66 when /boot is
# not mounted or its LUKS header cannot be read; 75 while another run, apt or dpkg holds a lock,
# or when the system changed while the question waited; 77 when not root; 78 on a bad
# configuration or another /boot; and 128+N when signal N cut it short.
ku_cmd_cleanup() {
    while (( $# )); do
        case $1 in
            --no-rc) KU_CL_SKIP['rc']=1; shift ;;
            --no-autoremove) KU_CL_SKIP['autoremove']=1; shift ;;
            --no-modules) KU_CL_SKIP['modules']=1; shift ;;
            -n | --dry-run) KU_DRY_RUN=1; shift ;;
            -y | --yes)
                # shellcheck disable=SC2034 # read by ku_ask
                KU_ASSUME_YES=1
                shift
                ;;
            --porcelain) KU_PORCELAIN=1; shift ;;
            -h | --help) ku_cleanup_usage; exit 0 ;;
            -*) ku_usage_error "cleanup: unknown option $1" ;;
            *) ku_usage_error "cleanup: unexpected argument '$1'" ;;
        esac
    done
    _ku_cl_environment
    ku_require_root
    ku_load_config
    ku_lock
    _ku_cl_preconditions
    if ! KU_CL_SNAPSHOT=$(_ku_cl_snapshot); then
        ku_die "$KU_EX_REFUSED" "cannot read dpkg's status file or apt's extended_states;" \
            "nothing was changed"
    fi
    if ! _ku_cl_plan; then
        ku_die "$KU_EX_REFUSED" "$KU_CL_WHY; nothing was changed"
    fi
    if (( ${#KU_CL_SET[@]} )) && ! _ku_cl_exact_set; then
        ku_die "$KU_EX_REFUSED" "the purge cannot run as planned: $KU_CL_WHY; nothing was changed"
    fi
    # The quarantine's entries are module trees too, and --no-modules leaves them alone.
    if _ku_cl_wanted modules; then
        if ! _ku_cl_plan_trees || ! _ku_cl_plan_expiry; then
            ku_die "$KU_EX_REFUSED" "$KU_CL_WHY; nothing was changed"
        fi
    fi
    _ku_cl_plan_print
    if (( ! ${#KU_CL_SET[@]} )) && ! _ku_cl_tree_acts && ! _ku_cl_expiry_acts; then
        _ku_cl_print_records
        ku_log info "cleanup: nothing to do"
        return 0
    fi
    if (( KU_DRY_RUN )); then
        _ku_cl_print_records
        ku_log info "dry run: nothing was changed"
        return 0
    fi
    ku_ask "Run the cleanup as planned? Purged packages cannot be rolled back." ||
        ku_die "$KU_EX_DECLINED" "declined; nothing was changed"
    _ku_cl_recheck
    # From here on the run changes the system, and the exit handler syncs whatever ends it.
    ku_cleanup_add _ku_cl_interrupted
    if (( ${#KU_CL_SET[@]} )); then
        _ku_cl_purge
    fi
    _ku_cl_trees
    _ku_cl_expire
    if ! sync; then
        ku_log warning "sync failed: run it before the stick is unplugged"
    fi
    KU_CL_SYNCED=1
    _ku_cl_print_records
    _ku_cl_summary
}

# Print the summary on stderr, the run's last line: how many packages it purged, how many
# planned module trees it removed, moved into the quarantine and left because a re-check kept
# them, and how many expired quarantine entries it deleted and left so; or that nothing was
# left to change, when all that the plan named went meanwhile.
_ku_cl_summary() {
    local -a parts=()
    if (( ${#KU_CL_SET[@]} )); then
        parts+=("purged $(_ku_cl_count "${#KU_CL_SET[@]}" package)")
    fi
    if (( KU_CL_REMOVED )); then
        parts+=("removed $(_ku_cl_count "$KU_CL_REMOVED" "empty module tree")")
    fi
    if (( KU_CL_MOVED )); then
        parts+=("moved $(_ku_cl_count "$KU_CL_MOVED" "module tree") into the quarantine")
    fi
    if (( KU_CL_LEFT )); then
        parts+=("left $(_ku_cl_count "$KU_CL_LEFT" "module tree") a re-check kept")
    fi
    if (( KU_CL_EXPIRED )); then
        parts+=("deleted $(_ku_cl_count "$KU_CL_EXPIRED" "expired quarantine entry" \
            "expired quarantine entries")")
    fi
    if (( KU_CL_ENTRY_LEFT )); then
        parts+=("left $(_ku_cl_count "$KU_CL_ENTRY_LEFT" "quarantine entry" \
            "quarantine entries") a re-check kept")
    fi
    if (( ! ${#parts[@]} )); then
        parts=("nothing was left to change")
    fi
    ku_log info "cleanup: $(ku_join "${parts[@]}")"
}

# Return 0 unless --no-rc, --no-autoremove or --no-modules left STEP out: rc, autoremove or
# modules.
_ku_cl_wanted() {
    [[ -z ${KU_CL_SKIP[$1]+set} ]]
}

# =======================================================
#                PRECONDITIONS AND TOOLS
# =======================================================

# Check, in a dry run too, that cleanup may run, or exit: 3 until detect set boot_fs_uuid and
# boot_luks_uuid; 66 when /boot is not mounted or its LUKS header cannot be read, and 78 when it
# is not the /boot they name (ku_boot_identity); 3 when apt-get, apt-mark or dpkg-query is
# missing; 75 while apt or dpkg holds its lock, and 3 when that cannot be told
# (_ku_cl_not_busy); 3 when linux-base does not keep the links in /boot or one does not reach a
# non-empty file there, when check's kernels item fails, as while a kernel package is stuck
# between states, and when dpkg was interrupted. The locks come before the links, the packages
# and dpkg's updates directory, which a running apt or dpkg changes for a moment.
_ku_cl_preconditions() {
    local key name i refused=0 kernels=""
    local -a keys=() tools=()
    for key in boot_fs_uuid boot_luks_uuid; do
        [[ -n ${KU_CONF[$key]} ]] || keys+=("$key")
    done
    if (( ${#keys[@]} )); then
        ku_die "$KU_EX_REFUSED" "the configuration lacks $(ku_join "${keys[@]}"): run" \
            "'kernel-updater migrate --stage detect' first; nothing was changed"
    fi
    ku_boot_identity
    for name in apt-get apt-mark dpkg-query; do
        command -v "$name" > /dev/null || tools+=("$name")
    done
    if (( ${#tools[@]} )); then
        ku_die "$KU_EX_REFUSED" "cleanup runs apt-get, apt-mark and dpkg-query, and" \
            "$(ku_join "${tools[@]}") cannot be found; nothing was changed"
    fi
    _ku_cl_not_busy
    ku_check_items kernel-img boot-links kernels
    for i in "${!KU_CHECK_ITEM[@]}"; do
        if [[ ${KU_CHECK_ITEM[i]} == kernels ]]; then
            if [[ ${KU_CHECK_STATUS[i]} == fail ]]; then
                kernels=${KU_CHECK_DETAIL[i]}
            fi
        elif [[ ${KU_CHECK_STATUS[i]} != ok ]]; then
            refused=1
            # boot-links skips while kernel-img says why.
            if [[ ${KU_CHECK_STATUS[i]} != skip ]]; then
                ku_log error "${KU_CHECK_ITEM[i]}: ${KU_CHECK_DETAIL[i]}"
            fi
        fi
    done
    if (( refused )); then
        ku_die "$KU_EX_REFUSED" "linux-base must keep the links in /boot, relative and reaching" \
            "the kernels' files: run 'kernel-updater migrate --stage system' first; nothing was" \
            "changed"
    fi
    if [[ -n $kernels ]]; then
        ku_die "$KU_EX_REFUSED" "kernels: $kernels; nothing was changed"
    fi
    if _ku_cl_dpkg_interrupted; then
        ku_die "$KU_EX_REFUSED" "dpkg was interrupted: run 'dpkg --configure -a', then" \
            "'kernel-updater check'; nothing was changed"
    fi
}

# Exit 75 while apt or dpkg holds its frontend or database lock, naming the holder, and 3 when
# _ku_cl_dpkg_busy cannot tell. Returns 0 while neither is held.
_ku_cl_not_busy() {
    local holder status=0
    holder=$(_ku_cl_dpkg_busy) || status=$?
    case $status in
        0)
            ku_die "$KU_EX_BUSY" "apt or dpkg is running: $holder; run cleanup again once it" \
                "is done; nothing was changed"
            ;;
        1) ;;
        *)
            ku_die "$KU_EX_REFUSED" "cannot read /proc/locks or the inode of a lock file of" \
                "dpkg, so cleanup cannot tell whether apt or dpkg is running; nothing was changed"
            ;;
    esac
}

# Print who holds dpkg's frontend lock or its database lock, as "PID 4242 (apt-get) holds
# /var/lib/dpkg/lock-frontend", and return 0 while one of them is held, 1 while neither is, and
# 2 when that cannot be told: /proc/locks or a lock file's inode cannot be read. apt and dpkg
# take these locks with fcntl, which flock cannot test, so the inodes of the lock files are
# looked up in /proc/locks. The device is not compared, as an overlay filesystem may show
# another one there than stat does: a lock on a file of the same inode number elsewhere only
# makes cleanup refuse once too often.
_ku_cl_dpkg_busy() {
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

# Return 0 when dpkg's updates directory holds a file whose name is all digits, the journal an
# interrupted dpkg run leaves until 'dpkg --configure -a' settles it, as apt reads it before it
# runs dpkg, and 1 otherwise. Other names, such as dpkg's temporary file, do not count.
_ku_cl_dpkg_interrupted() {
    local path
    for path in "$(ku_path /var/lib/dpkg/updates)"/*; do
        if [[ ${path##*/} =~ ^[0-9]+$ ]]; then
            return 0
        fi
    done
    return 1
}

# Drop the variables of KU_CL_ENV_DROP from this shell and export LC_ALL=C.UTF-8, before any
# tool runs: the probes cleanup shares with check run dpkg-query by name, and must read the
# database the purge changes. _ku_cl_child gives each tool it runs the same environment.
_ku_cl_environment() {
    local name
    for name in "${KU_CL_ENV_DROP[@]}"; do
        unset "$name"
    done
    export LC_ALL=C.UTF-8
}

# Run TOOL with ARGS, one of apt-get, apt-mark, dpkg-query and dkms, found through PATH, without
# the variables of KU_CL_ENV_DROP and with LC_ALL=C.UTF-8, so that a sudo -E environment can
# neither point dpkg at another database, force it or change apt's kernel protection, nor
# change the language of the output cleanup reads. Returns the tool's status.
_ku_cl_child() {
    local name
    local -a drop=()
    for name in "${KU_CL_ENV_DROP[@]}"; do
        drop+=(-u "$name")
    done
    env "${drop[@]}" LC_ALL=C.UTF-8 "$@"
}

# =======================================================
#                       SNAPSHOT
# =======================================================

# Print what the plan rests on, one line each: dpkg's state as _ku_cl_dpkg_state prints it,
# first; "extended_states SHA", the SHA-256 of apt's auto marks, or - while there are none; and
# "link NAME TARGET" for vmlinuz, vmlinuz.old, initrd.img and initrd.img.old in /boot, TARGET -
# for one that is no symlink. Returns 1 when a file it hashes cannot be read.
_ku_cl_snapshot() {
    local file sha=- name target
    _ku_cl_dpkg_state || return 1
    file=$(ku_path /var/lib/apt/extended_states)
    if [[ -e $file || -L $file ]]; then
        sha=$(ku_sha256 "$file") || return 1
    fi
    printf 'extended_states %s\n' "$sha"
    while IFS=$'\t' read -r name target _; do
        [[ -n $name ]] || continue
        printf 'link %s %s\n' "$name" "${target//[[:cntrl:]]/?}"
    done <<< "$(ku_probe_boot_links)"
}

# Print dpkg's state: "status SHA", the SHA-256 of its status file, or - while there is none,
# and "updates NAME...", the names in its updates directory, where dpkg journals each change
# before it folds them into the status file, so that a run cut short may have changed only
# those. Returns 1 when the status file cannot be read.
_ku_cl_dpkg_state() {
    local file sha=- path
    local -a names=()
    file=$(ku_path /var/lib/dpkg/status)
    if [[ -e $file || -L $file ]]; then
        sha=$(ku_sha256 "$file") || return 1
    fi
    for path in "$(ku_path /var/lib/dpkg/updates)"/*; do
        if [[ -e $path || -L $path ]]; then
            path=${path##*/}
            names+=("${path//[[:cntrl:]]/?}")
        fi
    done
    printf 'status %s\nupdates' "$sha"
    if (( ${#names[@]} )); then
        printf ' %s' "${names[@]}"
    fi
    printf '\n'
}

# Return 0 when dpkg's state differs from the one in KU_CL_SNAPSHOT, or cannot be read, and 1
# while it is the same.
_ku_cl_dpkg_changed() {
    local now
    now=$(_ku_cl_dpkg_state) || return 0
    [[ $KU_CL_SNAPSHOT != "$now"$'\n'* ]]
}

# =======================================================
#                         PLAN
# =======================================================

# Work out the plan from KU_CL_SNAPSHOT and the packages dpkg lists: the releases cleanup keeps
# and a pending reboot (_ku_cl_protected); unless a pending reboot puts the purges off, the rc
# step and the autoremove step, each unless --no-rc or --no-autoremove leaves it out; and
# KU_CL_SET, the packages the one purge removes, the rc step's first. Returns 1, with KU_CL_WHY
# saying why, when dpkg-query cannot list the kernel packages or the autoremove step cannot be
# planned.
_ku_cl_plan() {
    KU_CL_RC=() KU_CL_RC_REL=() KU_CL_RC_LEFT=() KU_CL_RC_ACTION=() KU_CL_RC_WHY=()
    KU_CL_AR=() KU_CL_AR_REL=() KU_CL_AR_LEFT=() KU_CL_AR_ACTION=() KU_CL_AR_WHY=()
    KU_CL_MANUAL=() KU_CL_SET=() KU_CL_PACKAGES="" KU_CL_WHY=""
    _ku_cl_protected
    if [[ -n $KU_CL_PENDING ]] || ! { _ku_cl_wanted rc || _ku_cl_wanted autoremove; }; then
        return 0
    fi
    if ! KU_CL_PACKAGES=$(ku_probe_kernel_packages); then
        KU_CL_WHY="dpkg-query cannot list the kernel packages"
        return 1
    fi
    if _ku_cl_wanted rc; then
        _ku_cl_plan_rc
    fi
    if _ku_cl_wanted autoremove; then
        _ku_cl_plan_autoremove || return 1
    fi
    KU_CL_SET=("${KU_CL_RC[@]}" "${KU_CL_AR[@]}")
}

# Set KU_CL_KEEP and KU_CL_KEEP_ORDER to the releases nothing named for may be purged or moved:
# the running kernel's (KU_CK_RUNNING, which the preconditions checked), then those the links in
# KU_CL_SNAPSHOT point at, in the order vmlinuz, vmlinuz.old, initrd.img and initrd.img.old; an
# initrd link is named as a reason only when its release differs from its vmlinuz link's. Sets
# KU_CL_PENDING to the release /boot/vmlinuz points at while another kernel runs, or empty.
# Exits 3 when a link points at no file named for a kernel release.
_ku_cl_protected() {
    local kind name target release pair
    local -A linked=()
    KU_CL_KEEP=() KU_CL_KEEP_ORDER=() KU_CL_PENDING=""
    _ku_cl_keep "$KU_CK_RUNNING" running
    while read -r kind name target; do
        [[ $kind == link ]] || continue
        release=${target##*/}
        release=${release#"${name%.old}"-}
        if [[ $release == "${target##*/}" ]] || ! ku_valid_release "$release"; then
            ku_die "$KU_EX_REFUSED" "/boot/$name points at no file named for a kernel release;" \
                "nothing was changed"
        fi
        linked[$name]=$release
        # initrd.img.old pairs with vmlinuz.old, and initrd.img with vmlinuz.
        pair=${name/initrd.img/vmlinuz}
        if [[ $name == initrd.img* && $release == "${linked[$pair]:-}" ]]; then
            continue
        fi
        _ku_cl_keep "$release" "$name"
    done <<< "$KU_CL_SNAPSHOT"
    if [[ ${linked[vmlinuz]:-} != "$KU_CK_RUNNING" ]]; then
        KU_CL_PENDING=${linked[vmlinuz]:-}
    fi
}

# Add WHY to the reasons cleanup keeps RELEASE for, recording a release it meets first.
_ku_cl_keep() {
    if [[ -n ${KU_CL_KEEP[$1]+set} ]]; then
        KU_CL_KEEP[$1]+=", $2"
    else
        KU_CL_KEEP[$1]=$2
        KU_CL_KEEP_ORDER+=("$1")
    fi
}

# Plan the rc step from the kernel packages dpkg lists (KU_CL_PACKAGES): a package removed with
# its config files left, status c with any want but hold, of kind image, binary, modules, base
# or headers, is purged unless cleanup keeps its release. A held one and one of a kept release
# are skipped, and a debug build and the headers and build tools an ABI's kernels share are
# listed; the plan shows each.
_ku_cl_plan_rc() {
    local name state kind release
    KU_CL_RC=() KU_CL_RC_REL=() KU_CL_RC_LEFT=() KU_CL_RC_ACTION=() KU_CL_RC_WHY=()
    while IFS=$'\t' read -r name state _ kind release; do
        [[ -n $name && $state == ?c ]] || continue
        case $kind in
            dbg) _ku_cl_rc_leave "$name" list "a debug build" ;;
            common) _ku_cl_rc_leave "$name" list "headers shared by the kernels of $release" ;;
            kbuild) _ku_cl_rc_leave "$name" list "build tools shared by the kernels of $release" ;;
            *)
                if [[ $state == h? ]]; then
                    _ku_cl_rc_leave "$name" skip held
                elif [[ -n ${KU_CL_KEEP[$release]+set} ]]; then
                    _ku_cl_rc_leave "$name" skip "its kernel is kept"
                else
                    KU_CL_RC+=("$name")
                    KU_CL_RC_REL+=("$release")
                fi
                ;;
        esac
    done <<< "$KU_CL_PACKAGES"
}

# Record that the rc step leaves the package NAME, with the plan's ACTION, skip or list, and
# WHY.
_ku_cl_rc_leave() {
    KU_CL_RC_LEFT+=("$1")
    KU_CL_RC_ACTION+=("$2")
    KU_CL_RC_WHY+=("$3")
}

# Plan the autoremove step. apt decides what is garbage: the source is its simulation of
# 'autoremove --purge', and the kernel packages dpkg lists (KU_CL_PACKAGES) say more about each
# package it names. A versioned kernel package, of kind image, binary, modules, base or headers,
# or the headers or build tools the kernels of one ABI share, is purged, an -unsigned build
# counting for its release, unless cleanup keeps its release, dpkg does not list it as
# installed, its version is that of an installed package of a kept release, as with the headers
# the .old kernel shares with the others of its ABI, or it is held or marked manual. A package
# the rc step purges is left out; a debug build and any other package are only listed. The
# installed kernel packages of the other releases that apt-mark showmanual names, which apt
# never prunes, go to KU_CL_MANUAL. Returns 1, with KU_CL_WHY saying why, when the simulation
# fails or would install or configure a package, or apt-mark cannot list the manual marks.
_ku_cl_plan_autoremove() {
    local name key state version kind release i out status=0
    local -a check=() check_rel=() others=()
    local -A dpkg_state=() dpkg_version=() kept=() taken=() manual=()
    KU_CL_AR=() KU_CL_AR_REL=() KU_CL_AR_LEFT=() KU_CL_AR_ACTION=() KU_CL_AR_WHY=()
    KU_CL_MANUAL=()
    _ku_cl_simulate -o APT::Get::AutomaticRemove::Kernels=false autoremove --purge || status=$?
    if (( status )); then
        KU_CL_WHY="apt-get cannot simulate its autoremove (status $status)"
        return 1
    fi
    if (( ${#KU_CL_SIM_OTHER[@]} )); then
        KU_CL_WHY="apt's autoremove would also install or configure"
        KU_CL_WHY+=" $(ku_join "${KU_CL_SIM_OTHER[@]}")"
        return 1
    fi
    # dpkg's state and version of each kernel package, and the versions of the installed
    # packages of the releases cleanup keeps.
    while IFS=$'\t' read -r name state version kind release; do
        [[ -n $name ]] || continue
        _ku_cl_bare "$name" key
        dpkg_state[$key]=$state
        dpkg_version[$key]=$version
        if [[ -n ${KU_CL_KEEP[$release]+set} && $state == ?[!c]* && $version != - ]]; then
            kept[$version]=1
        fi
    done <<< "$KU_CL_PACKAGES"
    for name in "${KU_CL_RC[@]}"; do
        _ku_cl_bare "$name" key
        taken[$key]=1
    done
    for name in "${KU_CL_SIM[@]}"; do
        _ku_cl_bare "$name" key
        [[ -z ${taken[$key]+set} ]] || continue
        taken[$key]=1
        state=${dpkg_state[$key]:-} version=${dpkg_version[$key]:-}
        if ! _ku_probe_kernel_name "$name" kind release; then
            _ku_cl_ar_leave "$name" list "not a versioned kernel package"
        elif [[ $kind == dbg ]]; then
            _ku_cl_ar_leave "$name" list "a debug build"
        elif [[ -n ${KU_CL_KEEP[$release]+set} ]]; then
            _ku_cl_ar_leave "$name" skip "its kernel is kept"
        elif [[ $state != ?[!c]* ]]; then
            _ku_cl_ar_leave "$name" skip "dpkg does not list it as installed"
        elif [[ -n ${kept[$version]+set} ]]; then
            _ku_cl_ar_leave "$name" skip "shares its version with a kept kernel"
        elif [[ $state == h* ]]; then
            _ku_cl_ar_leave "$name" skip held
        else
            check+=("$name")
            check_rel+=("$release")
        fi
    done
    # The installed kernel packages of the other releases that apt does not name, which it
    # never does while one is marked manual; a held one stays unnamed.
    while IFS=$'\t' read -r name state version kind release; do
        [[ -n $name ]] || continue
        _ku_cl_bare "$name" key
        if [[ -z ${taken[$key]+set} && $kind != dbg && $state == [!h][!c]* &&
            -z ${KU_CL_KEEP[$release]+set} && -z ${kept[$version]+set} ]]; then
            others+=("$name")
        fi
    done <<< "$KU_CL_PACKAGES"
    if (( ${#check[@]} || ${#others[@]} )); then
        out=$(_ku_cl_child apt-mark showmanual) || status=$?
        if (( status )); then
            KU_CL_WHY="apt-mark cannot list the packages marked manual (status $status)"
            return 1
        fi
        while IFS= read -r name; do
            [[ -n $name ]] || continue
            _ku_cl_bare "$name" key
            manual[$key]=1
        done <<< "$out"
    fi
    for i in "${!check[@]}"; do
        _ku_cl_bare "${check[i]}" key
        if [[ -n ${manual[$key]+set} ]]; then
            KU_CL_MANUAL+=("${check[i]}")
        else
            KU_CL_AR+=("${check[i]}")
            KU_CL_AR_REL+=("${check_rel[i]}")
        fi
    done
    for name in "${others[@]}"; do
        _ku_cl_bare "$name" key
        if [[ -n ${manual[$key]+set} ]]; then
            KU_CL_MANUAL+=("$name")
        fi
    done
}

# Record that the autoremove step leaves the package NAME, with the plan's ACTION, skip or
# list, and WHY.
_ku_cl_ar_leave() {
    KU_CL_AR_LEFT+=("$1")
    KU_CL_AR_ACTION+=("$2")
    KU_CL_AR_WHY+=("$3")
}

# Set the variable named VAR to the package NAME without the architecture after a colon, which
# dpkg-query prints for some packages and apt and apt-mark leave out for the native one.
_ku_cl_bare() {
    local cl_bare=${1%%:*}
    printf -v "$2" '%s' "${cl_bare:-$1}"
}

# Run apt-get's simulation (-s) of ARGS, quietly and without waiting for a lock, and set
# KU_CL_SIM to the packages it would remove, from its Purg and Remv lines, and KU_CL_SIM_OTHER
# to those it would install or configure, from its Inst and Conf lines, each once and in apt's
# order. Each line it prints shows as a debug line. Returns apt-get's status.
_ku_cl_simulate() {
    local out line name status=0
    local -A removed=() other=()
    KU_CL_SIM=() KU_CL_SIM_OTHER=()
    out=$(_ku_cl_child apt-get -s -q -o DPkg::Lock::Timeout=0 "$@") || status=$?
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        ku_log debug "apt-get -s: ${line//[[:cntrl:]]/ }"
        [[ $line =~ ^(Purg|Remv|Inst|Conf)\ ([^[:space:][:cntrl:]]+) ]] || continue
        name=${BASH_REMATCH[2]}
        case ${BASH_REMATCH[1]} in
            Purg | Remv)
                [[ -z ${removed[$name]+set} ]] || continue
                removed[$name]=1
                KU_CL_SIM+=("$name")
                ;;
            *)
                [[ -z ${other[$name]+set} ]] || continue
                other[$name]=1
                KU_CL_SIM_OTHER+=("$name")
                ;;
        esac
    done <<< "$out"
    return "$status"
}

# Simulate the purge of KU_CL_SET with the options the real one takes, which keep a local apt
# configuration from widening it, and return 0 when apt would remove exactly those packages and
# install or configure none. Returns 1 otherwise, with KU_CL_WHY saying how it differs: the
# simulation failed, or names packages to install or configure, more to remove, or fewer.
_ku_cl_exact_set() {
    local name status=0
    local -a extra=() missing=()
    local -A planned=() simulated=()
    KU_CL_WHY=""
    _ku_cl_simulate -o APT::Get::AutomaticRemove=false \
        -o APT::Get::AutomaticRemove::Kernels=false purge "${KU_CL_SET[@]}" || status=$?
    if (( status )); then
        KU_CL_WHY="apt-get cannot simulate the purge (status $status)"
        return 1
    fi
    for name in "${KU_CL_SET[@]}"; do
        planned[$name]=1
    done
    for name in "${KU_CL_SIM[@]}"; do
        simulated[$name]=1
        [[ -n ${planned[$name]+set} ]] || extra+=("$name")
    done
    for name in "${KU_CL_SET[@]}"; do
        [[ -n ${simulated[$name]+set} ]] || missing+=("$name")
    done
    if (( ${#KU_CL_SIM_OTHER[@]} )); then
        KU_CL_WHY="apt would also install or configure $(ku_join "${KU_CL_SIM_OTHER[@]}")"
    fi
    if (( ${#extra[@]} )); then
        KU_CL_WHY+="${KU_CL_WHY:+; }apt would also remove $(ku_join "${extra[@]}")"
    fi
    if (( ${#missing[@]} )); then
        KU_CL_WHY+="${KU_CL_WHY:+; }apt would not remove $(ku_join "${missing[@]}")"
    fi
    [[ -z $KU_CL_WHY ]]
}

# Print the plan through _ku_cl_plan_line when it holds anything to show: the releases kept,
# the purges a pending reboot puts off, the packages the rc step purges and those it leaves,
# those the autoremove step purges and those it leaves, the packages of old kernels marked
# manual, each with the hint 'apt-mark auto', the module trees the plan removes, moves, keeps or
# lists, the quarantine entries it deletes, keeps, lists or skips, each with its age unless it
# is listed, or why it judges none, then the sync. Prints nothing when there is nothing to
# purge, leave, put off or show of the module trees and the quarantine.
_ku_cl_plan_print() {
    local release i name step text entry pending=""
    local -a parts=() records=() steps=()
    for step in rc autoremove; do
        if _ku_cl_wanted "$step"; then
            steps+=("$step")
        fi
    done
    if (( ${#steps[@]} )); then
        pending=$KU_CL_PENDING
    fi
    if (( ! ${#KU_CL_SET[@]} && ! ${#KU_CL_RC_LEFT[@]} && ! ${#KU_CL_AR_LEFT[@]} &&
        ! ${#KU_CL_MANUAL[@]} && ! ${#KU_CL_TREE[@]} && ! ${#KU_CL_ENTRY[@]} )) &&
        [[ -z $pending ]]; then
        return 0
    fi
    for release in "${KU_CL_KEEP_ORDER[@]}"; do
        parts+=("$release (${KU_CL_KEEP[$release]})")
        records+=(protect keep "$release" "${KU_CL_KEEP[$release]}")
    done
    _ku_cl_plan_line "keep $(ku_join "${parts[@]}")" "${records[@]}"
    if [[ -n $pending ]]; then
        text="purge nothing while a reboot is pending: /boot/vmlinuz points at $pending, but"
        text+=" $KU_CK_RUNNING is running; reboot first"
        records=()
        for step in "${steps[@]}"; do
            records+=("$step" skip "$pending" "reboot first")
        done
        _ku_cl_plan_line "$text" "${records[@]}"
    fi
    if (( ${#KU_CL_RC[@]} )); then
        records=()
        for i in "${!KU_CL_RC[@]}"; do
            records+=(rc purge "${KU_CL_RC[i]}" "${KU_CL_RC_REL[i]}")
        done
        text="purge $(_ku_cl_count "${#KU_CL_RC[@]}" package) removed with config files left:"
        _ku_cl_plan_line "$text $(ku_join "${KU_CL_RC[@]}")" "${records[@]}"
    fi
    if (( ${#KU_CL_RC_LEFT[@]} )); then
        parts=() records=()
        for i in "${!KU_CL_RC_LEFT[@]}"; do
            parts+=("${KU_CL_RC_LEFT[i]} (${KU_CL_RC_WHY[i]})")
            records+=(rc "${KU_CL_RC_ACTION[i]}" "${KU_CL_RC_LEFT[i]}" "${KU_CL_RC_WHY[i]}")
        done
        text="leave $(_ku_cl_count "${#KU_CL_RC_LEFT[@]}" package) removed with config files"
        _ku_cl_plan_line "$text left: $(ku_join "${parts[@]}")" "${records[@]}"
    fi
    if (( ${#KU_CL_AR[@]} )); then
        records=()
        for i in "${!KU_CL_AR[@]}"; do
            records+=(autoremove purge "${KU_CL_AR[i]}" "${KU_CL_AR_REL[i]}")
        done
        text="purge $(_ku_cl_count "${#KU_CL_AR[@]}" package) apt autoremove names for old"
        _ku_cl_plan_line "$text kernels: $(ku_join "${KU_CL_AR[@]}")" "${records[@]}"
    fi
    if (( ${#KU_CL_AR_LEFT[@]} )); then
        parts=() records=()
        for i in "${!KU_CL_AR_LEFT[@]}"; do
            parts+=("${KU_CL_AR_LEFT[i]} (${KU_CL_AR_WHY[i]})")
            records+=(autoremove "${KU_CL_AR_ACTION[i]}" "${KU_CL_AR_LEFT[i]}"
                "${KU_CL_AR_WHY[i]}")
        done
        text="leave $(_ku_cl_count "${#KU_CL_AR_LEFT[@]}" package) apt autoremove names:"
        _ku_cl_plan_line "$text $(ku_join "${parts[@]}")" "${records[@]}"
    fi
    for name in "${KU_CL_MANUAL[@]}"; do
        text="marked manual; 'apt-mark auto $name' lets apt prune it"
        _ku_cl_plan_line "leave $name: $text" autoremove list "$name" "$text"
    done
    for i in "${!KU_CL_TREE[@]}"; do
        case ${KU_CL_TREE_ACTION[i]} in
            rmdir) text="remove the empty directory ${KU_CL_TREE[i]}" ;;
            quarantine) text="move ${KU_CL_TREE[i]} into the quarantine: ${KU_CL_TREE_WHY[i]}" ;;
            keep) text="keep ${KU_CL_TREE[i]}: ${KU_CL_TREE_WHY[i]}" ;;
            *) text="leave ${KU_CL_TREE[i]}: ${KU_CL_TREE_WHY[i]}" ;;
        esac
        _ku_cl_plan_line "$text" modules "${KU_CL_TREE_ACTION[i]}" "${KU_CL_TREE[i]}" \
            "${KU_CL_TREE_WHY[i]}"
    done
    for i in "${!KU_CL_ENTRY[@]}"; do
        entry=${KU_CL_ENTRY[i]}
        case ${KU_CL_ENTRY_ACTION[i]} in
            delete) text="delete quarantine entry ${entry##*/}" ;;
            keep) text="keep quarantine entry ${entry##*/}" ;;
            *)
                text="leave quarantine entry ${entry##*/}"
                if [[ $entry == "$KU_CL_QUARANTINE" ]]; then
                    text="expire nothing"
                fi
                ;;
        esac
        _ku_cl_plan_line "$text: ${KU_CL_ENTRY_WHY[i]}" expire "${KU_CL_ENTRY_ACTION[i]}" \
            "$entry" "${KU_CL_ENTRY_WHY[i]}"
    done
    if (( ${#KU_CL_SET[@]} )) || _ku_cl_tree_acts || _ku_cl_expiry_acts; then
        _ku_cl_plan_line "then sync"
    fi
}

# Print one line of the plan: TEXT, unless it is empty, on stderr through ku_plan, whatever the
# verbosity, and with --porcelain keep each RECORD after it, the four fields STEP, ACTION,
# OBJECT and DETAIL, as a tab-separated line in KU_CL_RECORDS, which _ku_cl_print_records prints
# once the run ends with 0. STEP is protect, rc, autoremove, modules or expire, and ACTION
# keep, purge, list, skip, rmdir, quarantine or delete. A field's control characters become
# blanks, so that no tab or line break shifts the fields, and an empty field shows as -.
_ku_cl_plan_line() {
    local field line tab=$'\t'
    if [[ -n $1 ]]; then
        ku_plan "$1"
    fi
    shift
    (( KU_PORCELAIN )) || return 0
    while (( $# >= 4 )); do
        line=""
        for field in "$1" "$2" "$3" "$4"; do
            field=${field//[[:cntrl:]]/ }
            line+="${line:+$tab}${field:--}"
        done
        KU_CL_RECORDS+=$line$'\n'
        shift 4
    done
}

# Print on stdout the plan's records that _ku_cl_plan_line kept with --porcelain. The run calls
# it only when it ends with 0, so that one which fails, is declined or is cut short leaves
# stdout empty.
_ku_cl_print_records() {
    printf '%s' "$KU_CL_RECORDS"
}

# Print COUNT and NOUN, the noun in the plural PLURAL, or with an s, unless COUNT is 1:
# "1 package", "2 packages", "2 quarantine entries".
_ku_cl_count() {
    if (( $1 == 1 )); then
        printf '%s %s' "$1" "$2"
    else
        printf '%s %s' "$1" "${3:-$2s}"
    fi
}

# =======================================================
#                        PURGE
# =======================================================

# After the question, check that the plan still holds, or exit: plan again from the same
# snapshot, which simulates apt's autoremove again, and simulate the purge again, if there is
# one, then check the locks, and last take the snapshot anew, so that it also covers what
# changed while the others ran. Exits 75 when apt or dpkg runs or the set, a simulation or the
# snapshot changed, and 3 when the locks cannot be read. A window of milliseconds stays until
# apt takes its lock, which DPkg::Lock::Timeout=0 makes it refuse to wait for. The module trees
# are checked one by one, right before each is removed or moved (_ku_cl_trees).
_ku_cl_recheck() {
    local now planned=" ${KU_CL_SET[*]} " changed=0
    if ! _ku_cl_plan || [[ " ${KU_CL_SET[*]} " != "$planned" ]] ||
        { (( ${#KU_CL_SET[@]} )) && ! _ku_cl_exact_set; }; then
        changed=1
    fi
    _ku_cl_not_busy
    if ! now=$(_ku_cl_snapshot) || [[ $now != "$KU_CL_SNAPSHOT" ]]; then
        changed=1
    fi
    if (( changed )); then
        ku_die "$KU_EX_BUSY" "dpkg's packages, apt's auto marks, what apt's autoremove names or" \
            "the links in /boot changed while the question waited, as when apt ran meanwhile, so" \
            "the plan no longer holds: run cleanup again; nothing was changed"
    fi
}

# Run the one apt-get purge of KU_CL_SET, with apt's output on stderr, once the caller
# registered the exit handler that reports a purge a signal cut short (_ku_cl_interrupted); then
# run check's boot-links and kernels items again. Exits as _ku_cl_failed says when apt-get
# fails, and 4 when an item fails after the purge, which leaves the module trees alone.
_ku_cl_purge() {
    local i status=0 failed=0
    KU_CL_PURGING=1
    ku_run _ku_cl_child apt-get -y -q -o DPkg::Lock::Timeout=0 \
        -o APT::Get::AutomaticRemove=false -o APT::Get::AutomaticRemove::Kernels=false purge \
        "${KU_CL_SET[@]}" >&2 || status=$?
    KU_CL_PURGING=0
    if (( status )); then
        _ku_cl_failed "$status"
    fi
    ku_check_items boot-links kernels
    for i in "${!KU_CHECK_ITEM[@]}"; do
        if [[ ${KU_CHECK_STATUS[i]} == fail || ${KU_CHECK_STATUS[i]} == skip ]]; then
            failed=1
            ku_log error "${KU_CHECK_ITEM[i]}: ${KU_CHECK_DETAIL[i]}"
        fi
    done
    if (( failed )); then
        ku_die "$KU_EX_WRITE" "the purge ran, but the check of the links and kernels after it" \
            "fails: run 'kernel-updater check' and settle that before the next reboot"
    fi
}

# Exit after the purge failed with STATUS, the advice depending on what is left, in this order:
# 4 when dpkg's state changed, whether or not apt or dpkg holds a lock now, naming
# 'dpkg --configure -a' and check; 75 while apt or dpkg holds its lock; and 3 otherwise, apt or
# apt-guard having refused the purge before dpkg changed anything.
_ku_cl_failed() {
    local holder busy=0
    if _ku_cl_dpkg_changed; then
        ku_die "$KU_EX_WRITE" "apt-get purge failed with status $1 after dpkg began to change its" \
            "database: run 'dpkg --configure -a', then 'kernel-updater check'"
    fi
    holder=$(_ku_cl_dpkg_busy) || busy=$?
    if (( busy == 0 )); then
        ku_die "$KU_EX_BUSY" "apt-get purge failed with status $1 while apt or dpkg runs:" \
            "$holder; run cleanup again once it is done; nothing was changed"
    fi
    ku_die "$KU_EX_REFUSED" "apt-get purge failed with status $1 before dpkg changed anything," \
        "as when apt or apt-guard refuses it, which its messages above explain; nothing was" \
        "changed"
}

# Exit handler, registered once the run starts to change the system, right before the purge or
# the module trees: when a signal cut the purge short, say whether dpkg's state changed, and if
# so that 'dpkg --configure -a', then check must settle it; then sync, unless the run synced
# already. The exit status stays 128+N.
_ku_cl_interrupted() {
    if (( KU_CL_PURGING )); then
        if _ku_cl_dpkg_changed; then
            ku_log error "the purge was cut short after dpkg began to change its database: run" \
                "'dpkg --configure -a', then 'kernel-updater check'"
        else
            ku_log error "the purge was cut short before dpkg changed its database; nothing was" \
                "purged"
        fi
    fi
    if (( ! KU_CL_SYNCED )) && ! sync; then
        ku_log warning "sync failed: run it before the stick is unplugged"
    fi
}

# =======================================================
#                     MODULE TREES
# =======================================================

# Set KU_CL_MODULES to the modules directories cleanup scans, of those that are directories:
# /usr/lib/modules, and /lib/modules unless it is the same directory, as with a merged /usr.
_ku_cl_modules_dirs() {
    local usr lib
    KU_CL_MODULES=()
    usr=$(ku_path /usr/lib/modules)
    lib=$(ku_path /lib/modules)
    if [[ -d $usr ]]; then
        KU_CL_MODULES+=(/usr/lib/modules)
    fi
    if [[ -d $lib && ! $lib -ef $usr ]]; then
        KU_CL_MODULES+=(/lib/modules)
    fi
}

# Plan the module trees step from what the modules directories hold, in their order and each
# one's in name order. An installed kernel's tree is left unnamed. The tree of a release this
# run purges packages of is listed: the purge may remove it or leave it, and the next run looks
# at what is left. A tree _ku_cl_keep_reason keeps is kept, and the plan says why. Any other is
# removed with rmdir when it is empty, moved into the quarantine when _ku_cl_movable allows, and
# else listed. An entry that is a symlink, no directory or not named for a kernel release is
# kept, its name tamed. Returns 1, with KU_CL_WHY saying why, when dpkg-query fails.
_ku_cl_plan_trees() {
    local dir path name tree reason status
    local -a paths=()
    local -A purged=()
    KU_CL_TREE=() KU_CL_TREE_ACTION=() KU_CL_TREE_WHY=()
    for name in "${KU_CL_RC_REL[@]}" "${KU_CL_AR_REL[@]}"; do
        purged[$name]=1
    done
    _ku_cl_modules_dirs
    for dir in "${KU_CL_MODULES[@]}"; do
        mapfile -d '' -t paths < <(shopt -s nullglob dotglob
            set -- "$(ku_path "$dir")"/*
            (( ! $# )) || printf '%s\0' "$@")
        for path in "${paths[@]}"; do
            name=${path##*/}
            tree=$dir/$name
            if [[ -L $path || ! -d $path ]] || ! ku_valid_release "$name"; then
                # A process can give an entry any name, so only plain characters are shown.
                tree=$dir/${name//[^A-Za-z0-9._+~:@-]/?}
            elif [[ -n ${purged[$name]+set} ]]; then
                _ku_cl_tree_add list "$tree" "this run purges packages of its release; the next" \
                    "cleanup looks at what is left"
                continue
            elif [[ ${KU_CK_STATE[$name]:-} == ?i ]]; then
                continue
            fi
            status=0
            reason=$(_ku_cl_keep_reason "$dir/$name" "$name") || status=$?
            if (( status == 0 )); then
                _ku_cl_tree_add keep "$tree" "$reason"
            elif (( status != 1 )); then
                KU_CL_WHY=$reason
                return 1
            elif _ku_cl_empty "$path"; then
                _ku_cl_tree_add rmdir "$tree" "empty, and no package owns it"
            elif _ku_cl_movable "$tree"; then
                _ku_cl_tree_add quarantine "$tree" "no package owns it"
            else
                _ku_cl_tree_add list "$tree" "no package owns it, but $KU_CL_MOVE_WHY"
            fi
        done
    done
}

# Add the module tree TREE to the plan with ACTION, rmdir, quarantine, keep or list, and WHY,
# whose words are joined by spaces.
_ku_cl_tree_add() {
    KU_CL_TREE_ACTION+=("$1")
    KU_CL_TREE+=("$2")
    shift 2
    KU_CL_TREE_WHY+=("$*")
}

# Return 0 when the plan removes or moves a module tree, and 1 otherwise.
_ku_cl_tree_acts() {
    local action
    for action in "${KU_CL_TREE_ACTION[@]}"; do
        if [[ $action == rmdir || $action == quarantine ]]; then
            return 0
        fi
    done
    return 1
}

# Print why the module tree TREE, a path such as /usr/lib/modules/RELEASE, must stay, and
# return 0, when any of these holds, the cheapest tests first: it is a symlink or no directory,
# or RELEASE has no kernel release's shape; cleanup keeps RELEASE's kernel; it holds
# .fresh-install, which a kernel install leaves until it is configured; /boot holds RELEASE's
# vmlinuz, initrd.img, config or System.map; dpkg lists a package named for RELEASE, its
# -unsigned build included, in a state other than not-installed, removed with its config files
# left included; dpkg-query -S names an owner (_ku_cl_owned); or dkms speaks for it
# (_ku_cl_dkms_reason). Returns 1 when none holds, and 2, printing why, when dpkg-query fails.
_ku_cl_keep_reason() {
    local tree=$1 release=$2 real boot file out name state status=0
    real=$(ku_path "$tree")
    if [[ -L $real ]]; then
        printf 'it is a symlink'
    elif [[ ! -d $real ]]; then
        printf 'it is no directory'
    elif ! ku_valid_release "$release"; then
        printf 'its name is no kernel release'
    elif [[ -n ${KU_CL_KEEP[$release]+set} ]]; then
        printf 'its kernel is kept (%s)' "${KU_CL_KEEP[$release]}"
    elif [[ -e $real/.fresh-install || -L $real/.fresh-install ]]; then
        printf 'it holds .fresh-install, which a kernel install leaves until it is configured'
    else
        boot=$(ku_path /boot)
        for file in vmlinuz initrd.img config System.map; do
            if [[ -e $boot/$file-$release || -L $boot/$file-$release ]]; then
                printf '/boot holds %s-%s' "$file" "$release"
                return 0
            fi
        done
        # shellcheck disable=SC2016 # dpkg-query expands the ${...} fields itself
        out=$(_ku_cl_child dpkg-query -W -f '${binary:Package}\t${db:Status-Abbrev}\n' \
            "*-$release" "*-$release-unsigned" 2> /dev/null) || status=$?
        # dpkg-query exits 1 when a pattern matches no package, and still lists the others.
        if (( status > 1 )); then
            printf 'dpkg-query -W failed with status %s, so cleanup cannot tell which packages' \
                "$status"
            printf ' are named for %s' "$release"
            return 2
        fi
        while IFS=$'\t' read -r name state _; do
            _ku_cl_bare "$name" name
            state=${state// /}
            if [[ ($name == *-"$release" || $name == *-"$release"-unsigned) && -n $state &&
                $state != ?n ]]; then
                printf 'dpkg lists %s (%s)' "$name" "$state"
                return 0
            fi
        done <<< "$out"
        status=0
        out=$(_ku_cl_owned "$release") || status=$?
        if (( status == 0 )); then
            printf '%s' "$out"
        elif (( status == 1 )); then
            _ku_cl_dkms_reason "$real" "$release" || return 1
        else
            printf 'dpkg-query -S failed with status %s, so cleanup cannot tell whether a' "$out"
            printf ' package owns %s' "$tree"
            return 2
        fi
    fi
}

# Print which package dpkg-query -S names as the owner of the module tree of RELEASE, as
# "PACKAGE owns it" for the tree itself and "PACKAGE owns files in it" for a file in it, and
# return 0. dpkg resolves no merged-/usr alias, so both /lib/modules/RELEASE and
# /usr/lib/modules/RELEASE are asked, and the globs find a package that lists files in the tree
# but not the tree itself. Each pattern gets a call of its own: with several, dpkg-query exits 1
# when any of them finds nothing. Returns 1 when none finds an owner, and 2, printing
# dpkg-query's status, when it fails.
_ku_cl_owned() {
    local release=$1 pattern out line owner status
    for pattern in "/lib/modules/$release" "/usr/lib/modules/$release" \
        "/lib/modules/$release/*" "/usr/lib/modules/$release/*"; do
        status=0
        out=$(_ku_cl_child dpkg-query -S "$pattern" 2> /dev/null) || status=$?
        if (( status == 1 )); then
            continue
        elif (( status )); then
            printf '%s' "$status"
            return 2
        fi
        owner=""
        while IFS= read -r line; do
            # A diversion line names no owner.
            if [[ $line == *': /'* && $line != 'diversion by '* ]]; then
                owner=${line%%: /*}
                owner=${owner%%, *}
                break
            fi
        done <<< "$out"
        owner=${owner//[^A-Za-z0-9.+:~_-]/?}
        if [[ $pattern == *'*' ]]; then
            printf '%s owns files in it' "${owner:-a package}"
        else
            printf '%s owns it' "${owner:-a package}"
        fi
        return 0
    done
    return 1
}

# Print why dkms keeps the module tree at REAL, a path under KU_ROOT, of RELEASE, and return 0:
# 'dkms status -k RELEASE' lists modules, which 'dkms remove' removes, or fails, so that cleanup
# cannot tell; or dkms is not installed, which env tells by its status 127, and the tree holds
# updates/dkms, where dkms puts the modules it builds. Returns 1 otherwise.
_ku_cl_dkms_reason() {
    local real=$1 release=$2 out status=0 module=MODULE/VERSION
    # dkms 3 lists MODULE/VERSION, RELEASE, ARCH: STATE, and dkms 2 MODULE, VERSION, RELEASE, ...
    local dkms3='^([A-Za-z0-9._+-]+)/([A-Za-z0-9._+~-]+),'
    local dkms2='^([A-Za-z0-9._+-]+), ([A-Za-z0-9._+~-]+),'
    out=$(_ku_cl_child dkms status -k "$release" 2> /dev/null) || status=$?
    case $status in
        0)
            [[ -n $out ]] || return 1
            if [[ $out =~ $dkms3 || $out =~ $dkms2 ]]; then
                module=${BASH_REMATCH[1]}/${BASH_REMATCH[2]}
            fi
            printf "dkms lists modules for it ('dkms remove %s -k %s')" "$module" "$release"
            ;;
        127)
            [[ -e $real/updates/dkms || -L $real/updates/dkms ]] || return 1
            printf 'it holds updates/dkms, and dkms is not installed to tell whose'
            ;;
        *)
            printf 'dkms status fails with status %s, so cleanup cannot tell whether dkms' \
                "$status"
            printf ' built modules for it'
            ;;
    esac
}

# Return 0 when the directory DIR holds nothing, hidden entries included, and 1 otherwise.
_ku_cl_empty() {
    [[ $(shopt -s nullglob dotglob; set -- "$1"/*; printf '%s' "$#") == 0 ]]
}

# Return 0 when the module tree TREE may move into the quarantine: mv can refuse to copy, as
# --no-copy from coreutils 9.2 on does; cleanup may act in the quarantine (_ku_cl_base_safe);
# and TREE and its directory lie on the device the quarantine is on, or will be, so that the
# move is one rename. Returns 1 otherwise, with KU_CL_MOVE_WHY saying why.
_ku_cl_movable() {
    local real out
    KU_CL_MOVE_WHY=""
    if [[ -z $KU_CL_MV ]]; then
        KU_CL_MV=0
        if out=$(mv --help 2> /dev/null) && [[ $out == *--no-copy* ]]; then
            KU_CL_MV=1
        fi
    fi
    if (( ! KU_CL_MV )); then
        KU_CL_MOVE_WHY="mv cannot refuse to copy: --no-copy needs coreutils 9.2"
        return 1
    fi
    if ! _ku_cl_base_safe; then
        KU_CL_MOVE_WHY=$KU_CL_BASE_WHY
        return 1
    fi
    real=$(ku_path "$1")
    out=$(stat -c %d -- "${real%/*}" "$real" 2> /dev/null) || out=""
    if [[ -z $KU_CL_BASE_DEV || $out != "$KU_CL_BASE_DEV"$'\n'"$KU_CL_BASE_DEV" ]]; then
        KU_CL_MOVE_WHY="it lies on another filesystem than the quarantine"
        return 1
    fi
}

# Return 0 when cleanup may act in the quarantine: no symlink leads to it, it lies in no modules
# directory, it is, when it is there, a directory of root's with mode 0700, and only root can
# change the directory that holds it, or the nearest one there is while it is not. Sets
# KU_CL_BASE_DEV to the device the quarantine is on, or will be, or empty when stat cannot tell.
# Returns 1 otherwise, with KU_CL_BASE_WHY saying why.
_ku_cl_base_safe() {
    local base root resolved dir info owner mode dev="" out
    KU_CL_BASE_DEV="" KU_CL_BASE_WHY=""
    base=$(ku_path "$KU_CL_QUARANTINE")
    root=$(readlink -m -- "$(ku_path /)") || root=""
    resolved=$(readlink -m -- "$base") || resolved=""
    if [[ -z $root || $resolved != "${root%/}$KU_CL_QUARANTINE" ]]; then
        KU_CL_BASE_WHY="a symlink leads to the quarantine $KU_CL_QUARANTINE"
        return 1
    fi
    for dir in "${KU_CL_MODULES[@]}"; do
        out=$(readlink -m -- "$(ku_path "$dir")") || out=""
        if [[ -z $out || $resolved/ == "${out%/}"/* ]]; then
            KU_CL_BASE_WHY="the quarantine $KU_CL_QUARANTINE lies in $dir"
            return 1
        fi
    done
    dir=${base%/*}
    if [[ -e $base || -L $base ]]; then
        info=""
        if [[ -d $base && ! -L $base ]]; then
            info=$(stat -c '%u %a %d' -- "$base" 2> /dev/null) || info=""
        fi
        read -r owner mode dev <<< "$info"
        if [[ $owner != 0 || $mode != 700 ]]; then
            KU_CL_BASE_WHY="the quarantine $KU_CL_QUARANTINE is no directory of root's with mode"
            KU_CL_BASE_WHY+=" 0700"
            return 1
        fi
    else
        # mkdir -p makes the quarantine in the nearest directory there is.
        while [[ -n $dir && ! -e $dir && ! -L $dir ]]; do
            dir=${dir%/*}
        done
        dir=${dir:-/}
        dev=$(stat -c %d -- "$dir" 2> /dev/null) || dev=""
    fi
    if ! ku_root_only_dir "$dir"; then
        KU_CL_BASE_WHY="a user other than root can change the directory that holds the"
        KU_CL_BASE_WHY+=" quarantine $KU_CL_QUARANTINE"
        return 1
    fi
    KU_CL_BASE_DEV=$dev
}

# Remove or move the module trees the confirmed plan names, in its order. Right before each,
# check the locks and every keep test again, and leave the tree, with a warning, while apt or
# dpkg runs or that cannot be told, when a test keeps it now, when an empty one is no longer
# empty, or when one may no longer move; a tree that went meanwhile is only reported. Then
# remove an empty tree with rmdir, which loses nothing, or move one into the quarantine
# (_ku_cl_quarantine). Exits as _ku_cl_stopped says when dpkg-query fails or a step fails.
_ku_cl_trees() {
    local i tree real reason holder status
    for i in "${!KU_CL_TREE[@]}"; do
        [[ ${KU_CL_TREE_ACTION[i]} == rmdir || ${KU_CL_TREE_ACTION[i]} == quarantine ]] ||
            continue
        tree=${KU_CL_TREE[i]}
        real=$(ku_path "$tree")
        if [[ ! -e $real && ! -L $real ]]; then
            ku_log warning "$tree went while cleanup ran, so there is nothing left to do for it"
            continue
        fi
        status=0
        holder=$(_ku_cl_dpkg_busy) || status=$?
        if (( status == 0 )); then
            _ku_cl_leave "$tree" "apt or dpkg is running: $holder; run cleanup again once it is" \
                "done"
            continue
        elif (( status != 1 )); then
            _ku_cl_leave "$tree" "cleanup cannot tell whether apt or dpkg is running"
            continue
        fi
        status=0
        reason=$(_ku_cl_keep_reason "$tree" "${tree##*/}") || status=$?
        if (( status == 0 )); then
            _ku_cl_leave "$tree" "$reason"
            continue
        elif (( status != 1 )); then
            _ku_cl_stopped "$reason" "$tree"
        fi
        if [[ ${KU_CL_TREE_ACTION[i]} == rmdir ]]; then
            if ! _ku_cl_empty "$real"; then
                _ku_cl_leave "$tree" "it is no longer empty"
                continue
            fi
            if ! ku_run rmdir -- "$real"; then
                _ku_cl_stopped "rmdir cannot remove the empty directory $tree" "$tree" write
            fi
            ku_log info "removed the empty directory $tree"
            KU_CL_REMOVED=$(( KU_CL_REMOVED + 1 ))
        else
            _ku_cl_quarantine_base "$tree"
            if ! _ku_cl_movable "$tree"; then
                _ku_cl_leave "$tree" "$KU_CL_MOVE_WHY"
                continue
            fi
            _ku_cl_quarantine "$tree"
            KU_CL_MOVED=$(( KU_CL_MOVED + 1 ))
        fi
    done
}

# Leave the planned module tree TREE where it is, warning why: WHY, whose words are joined by
# spaces.
_ku_cl_leave() {
    local tree=$1
    shift
    ku_log warning "left $tree where it is: $*"
    KU_CL_LEFT=$(( KU_CL_LEFT + 1 ))
}

# Exit after a step of the module trees stopped with TEXT, saying what is done and that the
# module tree TREE and those after it stay where they are: 4 once the purge ran or a tree was
# removed or moved, or with KIND write, when the step itself failed to change something; and 3
# while nothing was changed.
_ku_cl_stopped() {
    local text=$1 tree=$2 kind=${3:-check} finished
    finished=$(_ku_cl_finished)
    if [[ -z $finished && $kind != write ]]; then
        ku_die "$KU_EX_REFUSED" "$text; nothing was changed"
    fi
    text+="; "
    if [[ -n $finished ]]; then
        text+="$finished, and "
    fi
    ku_die "$KU_EX_WRITE" "$text$tree and the module trees after it stay where they are: run" \
        "cleanup again"
}

# Print what the run changed so far, as a list: that the purge ran, how many module trees it
# removed or moved, and how many quarantine entries it deleted. Prints nothing while it changed
# nothing.
_ku_cl_finished() {
    local count=$(( KU_CL_REMOVED + KU_CL_MOVED ))
    local -a finished=()
    if (( ${#KU_CL_SET[@]} )); then
        finished+=("the purge ran")
    fi
    if (( count == 1 )); then
        finished+=("1 module tree was removed or moved")
    elif (( count )); then
        finished+=("$count module trees were removed or moved")
    fi
    if (( KU_CL_EXPIRED == 1 )); then
        finished+=("1 quarantine entry was deleted")
    elif (( KU_CL_EXPIRED )); then
        finished+=("$KU_CL_EXPIRED quarantine entries were deleted")
    fi
    if (( ${#finished[@]} )); then
        ku_join "${finished[@]}"
    fi
}

# Make the quarantine, and the directories that hold it, with mode 0700, as baseline makes
# /var/lib/kernel-updater, unless it is there. Exits as _ku_cl_stopped says, for the module tree
# TREE, when that fails.
_ku_cl_quarantine_base() {
    local base
    base=$(ku_path "$KU_CL_QUARANTINE")
    [[ ! -e $base && ! -L $base ]] || return 0
    if ! (umask 077 && mkdir -p -- "${base%/*}" && mkdir -- "$base"); then
        _ku_cl_stopped "cannot make the quarantine $KU_CL_QUARANTINE" "$1" write
    fi
}

# Move the module tree TREE into a new entry of the quarantine, RELEASE.STAMP, STAMP the UTC
# time, or a second later while that name is taken: make the entry with mode 0700, write its
# origin, then rename the tree into it as tree with 'mv --no-copy -T', which refuses to copy. A
# kill before the rename leaves the tree where it was and an entry without tree, which expires
# like any other. Exits as _ku_cl_stopped says when a step fails.
_ku_cl_quarantine() {
    local tree=$1 release=${1##*/} real base epoch stamp entry sha version reasons text tries=0
    real=$(ku_path "$tree")
    base=$(ku_path "$KU_CL_QUARANTINE")
    epoch=$(date -u +%s) || epoch=""
    if [[ ! $epoch =~ ^[0-9]+$ ]]; then
        _ku_cl_stopped "date prints no time to name the quarantine entry by" "$tree" write
    fi
    while :; do
        TZ=UTC0 printf -v stamp '%(%Y%m%dT%H%M%SZ)T' "$epoch"
        entry=$KU_CL_QUARANTINE/$release.$stamp
        [[ -e $base/${entry##*/} || -L $base/${entry##*/} ]] || break
        tries=$(( tries + 1 ))
        if (( tries == 10 )); then
            text="the quarantine holds an entry for $release of each of the last 10 seconds"
            _ku_cl_stopped "$text" "$tree" write
        fi
        epoch=$(( epoch + 1 ))
    done
    if ! (umask 077 && mkdir -- "$(ku_path "$entry")"); then
        _ku_cl_stopped "cannot make the quarantine entry $entry" "$tree" write
    fi
    sha=$(ku_sha256 "$(ku_path /var/lib/dpkg/status)") || sha=-
    { version=$(< "${KU_SHAREDIR:-}/VERSION"); } 2> /dev/null || version=unknown
    reasons="no package owns it or is named for its release, its kernel is not kept, /boot"
    reasons+=" holds none of its files, it holds no .fresh-install and dkms speaks for none of it"
    if ! (umask 077 && printf '%s\n' "path: $tree" "release: $release" "stamp: $stamp" \
        "reasons: $reasons" "dpkg-status: $sha" "tool: kernel-updater $version" \
        > "$(ku_path "$entry")/origin"); then
        text="cannot write $entry/origin; the entry holds nothing else and expires like any other"
        _ku_cl_stopped "$text" "$tree" write
    fi
    if ! ku_run mv --no-copy -T -- "$real" "$(ku_path "$entry")/tree"; then
        text="mv cannot move $tree into $entry, which holds only its origin and expires like any"
        _ku_cl_stopped "$text other" "$tree" write
    fi
    ku_log info "moved $tree to $entry/tree; 'mv -T $entry/tree $tree' moves it back"
}

# =======================================================
#                        EXPIRY
# =======================================================

# Plan the expiry of the quarantine's entries, when the quarantine is there. When cleanup may
# not act in it (_ku_cl_base_safe), the plan skips it whole and says why. An entry that
# _ku_cl_entry_times refuses is listed. An entry no run saw yet stays, and gets seen
# (_ku_cl_seen) unless this is a dry run or the clock is behind. Any other is deleted once more
# whole days than quarantine_days have passed since the newer of its stamp and seen, unless
# quarantine_days is 0, which keeps it, or the clock reads earlier than any entry's stamp or
# seen, which skips it and warns; it stays otherwise. The plan shows each entry's age. Returns
# 1, with KU_CL_WHY saying why, when date prints no time.
_ku_cl_plan_expiry() {
    local base name out status stamp seen newer days keeps text i behind=0
    local -a names=() outs=() statuses=()
    KU_CL_ENTRY=() KU_CL_ENTRY_ACTION=() KU_CL_ENTRY_WHY=() KU_CL_ENTRY_TIMES=()
    base=$(ku_path "$KU_CL_QUARANTINE")
    [[ -e $base || -L $base ]] || return 0
    if ! _ku_cl_base_safe; then
        _ku_cl_entry_add skip "$KU_CL_QUARANTINE" "$KU_CL_BASE_WHY" ""
        return 0
    fi
    KU_CL_EXPIRY_DEV=$KU_CL_BASE_DEV
    KU_CL_NOW=$(date -u +%s) || KU_CL_NOW=""
    if [[ ! $KU_CL_NOW =~ ^[0-9]+$ ]]; then
        KU_CL_WHY="date prints no time to tell the age of the quarantine entries by"
        return 1
    fi
    mapfile -d '' -t names < <(shopt -s nullglob dotglob
        set -- "$base"/*
        (( ! $# )) || printf '%s\0' "${@##*/}")
    # Every entry's times come first: a clock behind any of them keeps them all.
    for name in "${names[@]}"; do
        status=0
        out=$(_ku_cl_entry_times "$KU_CL_QUARANTINE/$name" "$KU_CL_EXPIRY_DEV") || status=$?
        outs+=("$out") statuses+=("$status")
        if (( status )); then
            continue
        fi
        read -r stamp seen <<< "$out"
        newer=$stamp
        if [[ $seen != - ]] && (( seen > newer )); then
            newer=$seen
        fi
        if (( newer > KU_CL_NOW )); then
            behind=1
        fi
    done
    if (( behind )); then
        TZ=UTC0 printf -v text '%(%Y%m%dT%H%M%SZ)T' "$KU_CL_NOW"
        ku_log warning "the clock is behind: it reads $text, earlier than a quarantine entry was" \
            "made or seen, so no entry expires in this run"
    fi
    days=${KU_CONF[quarantine_days]}
    keeps=" (quarantine_days $days)"
    if (( days == 0 )); then
        keeps=" (quarantine_days 0 keeps it)"
    fi
    for i in "${!names[@]}"; do
        # A process can give an entry any name, so only plain characters are shown.
        name=$KU_CL_QUARANTINE/${names[i]//[^A-Za-z0-9._+~:@-]/?}
        if (( statuses[i] )); then
            _ku_cl_entry_add list "$name" "${outs[i]}" ""
            continue
        fi
        read -r stamp seen <<< "${outs[i]}"
        if [[ $seen == - ]]; then
            text="$(_ku_cl_age "$stamp" "$KU_CL_NOW") by its stamp; "
            if (( behind )); then
                text+="no run marks it seen while the clock is behind"
            elif (( KU_DRY_RUN )); then
                text+="no run has marked it seen yet"
            elif _ku_cl_seen "$name"; then
                text+="this run marks it seen"
            else
                text+="its seen cannot be written"
            fi
            _ku_cl_entry_add keep "$name" "$text$keeps" "${outs[i]}"
            continue
        fi
        newer=$(( stamp > seen ? stamp : seen ))
        text=$(_ku_cl_age "$newer" "$KU_CL_NOW")
        if (( days == 0 || newer > KU_CL_NOW || (KU_CL_NOW - newer) / 86400 <= days )); then
            _ku_cl_entry_add keep "$name" "$text$keeps" "${outs[i]}"
        elif (( behind )); then
            _ku_cl_entry_add skip "$name" "$text, but the clock is behind$keeps" "${outs[i]}"
        else
            _ku_cl_entry_add delete "$name" "$text$keeps" "${outs[i]}"
        fi
    done
}

# Add the quarantine entry ENTRY, or the quarantine itself, to the plan with ACTION, delete,
# keep, list or skip, WHY, and TIMES, the entry's times as _ku_cl_entry_times printed them, or
# empty.
_ku_cl_entry_add() {
    KU_CL_ENTRY_ACTION+=("$1")
    KU_CL_ENTRY+=("$2")
    KU_CL_ENTRY_WHY+=("$3")
    KU_CL_ENTRY_TIMES+=("$4")
}

# Return 0 when the plan deletes a quarantine entry, and 1 otherwise.
_ku_cl_expiry_acts() {
    local action
    for action in "${KU_CL_ENTRY_ACTION[@]}"; do
        if [[ $action == delete ]]; then
            return 0
        fi
    done
    return 1
}

# Print the times of the quarantine entry ENTRY, a path such as
# /var/lib/kernel-updater/quarantine/RELEASE.STAMP, as "STAMP SEEN" in seconds since the epoch,
# SEEN - while the entry holds no seen, and return 0 when expiry may judge the entry: it is a
# directory and no symlink; its name is RELEASE.STAMP, RELEASE a kernel release and STAMP a UTC
# time as YYYYmmddTHHMMSSZ; it holds nothing but its tree, a directory, and origin and seen,
# each a regular file; it belongs to root and lies, and its tree with it, on DEV, the
# quarantine's device; and its seen holds a UTC time of that form. Prints why not and returns 1
# otherwise.
_ku_cl_entry_times() {
    local entry=$1 dev=$2 real name stamp seen=- part line out owner device
    local -a parts=() paths=() infos=()
    real=$(ku_path "$entry")
    name=${entry##*/}
    if [[ -L $real ]]; then
        printf 'it is a symlink'
        return 1
    elif [[ ! -d $real ]]; then
        printf 'it is no directory'
        return 1
    elif [[ $name != *.* ]] || ! ku_valid_release "${name%.*}" ||
        ! _ku_cl_epoch "${name##*.}" stamp; then
        printf 'its name is not RELEASE.YYYYmmddTHHMMSSZ'
        return 1
    fi
    mapfile -d '' -t parts < <(shopt -s nullglob dotglob
        set -- "$real"/*
        (( ! $# )) || printf '%s\0' "$@")
    paths=("$real")
    for part in "${parts[@]}"; do
        case ${part##*/} in
            tree)
                if [[ -L $part || ! -d $part ]]; then
                    printf 'its tree is no directory'
                    return 1
                fi
                paths+=("$part")
                ;;
            origin | seen)
                if [[ -L $part || ! -f $part ]]; then
                    printf 'its %s is no regular file' "${part##*/}"
                    return 1
                fi
                ;;
            *)
                printf 'it holds more than tree, origin and seen'
                return 1
                ;;
        esac
    done
    out=$(stat -c '%u %d' -- "${paths[@]}" 2> /dev/null) || out=""
    mapfile -t infos <<< "$out"
    if [[ -z $out ]] || (( ${#infos[@]} != ${#paths[@]} )); then
        printf 'stat cannot tell its owner and device'
        return 1
    fi
    read -r owner device <<< "${infos[0]}"
    if [[ $owner != 0 ]]; then
        printf 'it belongs to another user than root'
        return 1
    elif [[ $device != "$dev" ]]; then
        printf 'it lies on another filesystem than the quarantine'
        return 1
    elif (( ${#infos[@]} > 1 )) && [[ ${infos[1]#* } != "$dev" ]]; then
        printf 'its tree lies on another filesystem than the quarantine'
        return 1
    fi
    if [[ -e $real/seen ]]; then
        line=""
        { IFS= read -r line < "$real/seen"; } 2> /dev/null || :
        if ! _ku_cl_epoch "$line" seen; then
            printf 'its seen holds no time as YYYYmmddTHHMMSSZ'
            return 1
        fi
    fi
    printf '%s %s' "$stamp" "$seen"
}

# Set the variable named VAR to the UTC time STAMP, written as YYYYmmddTHHMMSSZ, in seconds
# since the epoch, and return 0. Returns 1 when STAMP has not that form or names no time there
# is, such as 31 November, or one before 1970.
_ku_cl_epoch() {
    local cl_y cl_m cl_d cl_era cl_yoe cl_doy cl_days cl_secs cl_back
    [[ $1 =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] || return 1
    cl_y=$(( 10#${BASH_REMATCH[1]} )) cl_m=$(( 10#${BASH_REMATCH[2]} ))
    cl_d=$(( 10#${BASH_REMATCH[3]} ))
    (( cl_y >= 1970 && cl_m >= 1 && cl_m <= 12 && cl_d >= 1 )) || return 1
    # The days since 1970-01-01 in the Gregorian calendar, its years counted from 1 March so
    # that a leap day ends one, as Howard Hinnant's days_from_civil counts them.
    cl_y=$(( cl_y - (cl_m <= 2) ))
    cl_era=$(( cl_y / 400 ))
    cl_yoe=$(( cl_y - cl_era * 400 ))
    cl_doy=$(( (153 * ((cl_m + 9) % 12) + 2) / 5 + cl_d - 1 ))
    cl_days=$(( cl_era * 146097 + cl_yoe * 365 + cl_yoe / 4 - cl_yoe / 100 + cl_doy - 719468 ))
    cl_secs=$(( cl_days * 86400 + 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60
        + 10#${BASH_REMATCH[6]} ))
    # A stamp that names no real time, such as 31 November or hour 25, comes back as another.
    TZ=UTC0 printf -v cl_back '%(%Y%m%dT%H%M%SZ)T' "$cl_secs"
    [[ $cl_back == "$1" ]] || return 1
    printf -v "$2" '%s' "$cl_secs"
}

# Print how old a quarantine entry whose newer time is THEN is at NOW, both in seconds since
# the epoch: "N days old", in whole days, or "N days ahead of the clock", rounded up, when THEN
# lies after NOW.
_ku_cl_age() {
    if (( $1 > $2 )); then
        printf '%s ahead of the clock' "$(_ku_cl_count $(( ($1 - $2 + 86399) / 86400 )) day)"
    else
        printf '%s old' "$(_ku_cl_count $(( ($2 - $1) / 86400 )) day)"
    fi
}

# Write seen into the quarantine entry ENTRY: the time of the plan, KU_CL_NOW, as
# YYYYmmddTHHMMSSZ, in a new file of mode 0600, which noclobber keeps any file or symlink there
# from standing in for. Returns 1, with a warning, when that fails.
_ku_cl_seen() {
    local stamp file
    TZ=UTC0 printf -v stamp '%(%Y%m%dT%H%M%SZ)T' "$KU_CL_NOW"
    file=$(ku_path "$1")/seen
    if ! (set -C && umask 077 && printf '%s\n' "$stamp" > "$file") 2> /dev/null; then
        ku_log warning "cannot write seen into the quarantine entry ${1##*/}, which cannot" \
            "expire until a run writes it"
        return 1
    fi
}

# Delete the quarantine entries the confirmed plan deletes, in its order, each once a re-check
# finds the quarantine and the entry as the plan saw them: an entry that changed stays, with a
# warning, and one that went is only reported. Deletes, without -f, each part the entry holds:
# its tree with 'rm -r --one-file-system', which keeps rm on the quarantine's filesystem, then
# origin and seen, then the entry with rmdir. Exits as _ku_cl_expire_stopped says when a
# deletion fails.
_ku_cl_expire() {
    local i entry real part out status
    _ku_cl_expiry_acts || return 0
    if ! _ku_cl_base_safe || [[ $KU_CL_BASE_DEV != "$KU_CL_EXPIRY_DEV" ]]; then
        for i in "${!KU_CL_ENTRY[@]}"; do
            if [[ ${KU_CL_ENTRY_ACTION[i]} == delete ]]; then
                _ku_cl_entry_left "${KU_CL_ENTRY[i]}" "the quarantine changed while cleanup ran"
            fi
        done
        return 0
    fi
    for i in "${!KU_CL_ENTRY[@]}"; do
        [[ ${KU_CL_ENTRY_ACTION[i]} == delete ]] || continue
        entry=${KU_CL_ENTRY[i]}
        real=$(ku_path "$entry")
        if [[ ! -e $real && ! -L $real ]]; then
            ku_log warning "the quarantine entry ${entry##*/} went while cleanup ran, so there" \
                "is nothing left to do for it"
            continue
        fi
        status=0
        out=$(_ku_cl_entry_times "$entry" "$KU_CL_EXPIRY_DEV") || status=$?
        if (( status )); then
            _ku_cl_entry_left "$entry" "$out"
            continue
        elif [[ $out != "${KU_CL_ENTRY_TIMES[i]}" ]]; then
            _ku_cl_entry_left "$entry" "it changed while cleanup ran"
            continue
        fi
        if [[ -e $real/tree || -L $real/tree ]] &&
            ! ku_run rm -r --one-file-system -- "$real/tree" < /dev/null; then
            _ku_cl_expire_stopped "rm cannot delete all of $entry/tree" "${entry##*/}"
        fi
        for part in origin seen; do
            if [[ -e $real/$part || -L $real/$part ]] &&
                ! ku_run rm -- "$real/$part" < /dev/null; then
                _ku_cl_expire_stopped "rm cannot delete $entry/$part" "${entry##*/}"
            fi
        done
        if ! ku_run rmdir -- "$real"; then
            _ku_cl_expire_stopped "rmdir cannot remove $entry" "${entry##*/}"
        fi
        ku_log info "deleted the expired quarantine entry ${entry##*/}"
        KU_CL_EXPIRED=$(( KU_CL_EXPIRED + 1 ))
    done
}

# Leave the planned quarantine entry ENTRY as it is, warning why: WHY.
_ku_cl_entry_left() {
    ku_log warning "left the quarantine entry ${1##*/}: $2"
    KU_CL_ENTRY_LEFT=$(( KU_CL_ENTRY_LEFT + 1 ))
}

# Exit 4 after the deletion of the quarantine entry NAME stopped with TEXT, saying what the run
# changed and that what is left of NAME and the entries after it stay in the quarantine.
_ku_cl_expire_stopped() {
    local text="$1; " finished
    finished=$(_ku_cl_finished)
    if [[ -n $finished ]]; then
        text+="$finished, and "
    fi
    ku_die "$KU_EX_WRITE" "${text}what is left of the quarantine entry $2 and the entries after" \
        "it stay: run cleanup again"
}
