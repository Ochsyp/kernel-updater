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

# Print the cleanup command's usage on stdout.
ku_cleanup_usage() {
    cat << 'EOF'
Usage: kernel-updater cleanup [--no-rc] [--no-autoremove] [--no-modules] [-n] [-y] [--porcelain]

Purges, in one apt-get run, the config files removed kernels left and the old kernels apt's
autoremove names, once a simulation shows that apt would remove exactly those. It never purges
the running kernel or a kernel the links in /boot point at, and purges nothing while a reboot
into the kernel /boot/vmlinuz points at is pending. A module tree that no package owns is
removed when it is empty, and otherwise moved to /var/lib/kernel-updater/quarantine, from
where it can be moved back until it expires: quarantine_days after a later run first saw it.
The plan comes first, then one question. Purged packages cannot be rolled back, so read the
plan with -n first.

  --no-rc          leave the config files of removed kernels alone
  --no-autoremove  leave the old kernels apt's autoremove names alone
  --no-modules     leave the module trees alone
  -n, --dry-run    print the plan, change nothing
  -y, --yes        answer yes to the question
  --porcelain      also print the plan on stdout as STEP, ACTION, OBJECT and DETAIL,
                   tab-separated

Runs as root under the tool's lock, with /boot unlocked and mounted. Exits 0 when done, when
nothing was left to do and after a dry run, 3 when a check refuses, 4 when a purge, a move or
a deletion stopped partway, 10 when declined, 64 on a usage error, 66 when /boot is not mounted
or its LUKS header cannot be read, 75 when another run, apt or dpkg holds a lock or the system
changed while the question waited, 77 when not run as root and 78 when the configuration is
bad or names another /boot.
EOF
}

# Parse the options, then, as root and under the tool's lock, check that cleanup may run, in a
# dry run too, and report that it has nothing to do. Exits 0 then, 3 when a check refuses, 64
# on a usage error, 66 when /boot is not mounted or its LUKS header cannot be read, 75 while
# another run, apt or dpkg holds a lock, 77 when not root and 78 on a bad configuration or
# another /boot.
ku_cmd_cleanup() {
    while (( $# )); do
        case $1 in
            --no-rc) KU_CL_SKIP['rc']=1; shift ;;
            --no-autoremove) KU_CL_SKIP['autoremove']=1; shift ;;
            --no-modules) KU_CL_SKIP['modules']=1; shift ;;
            -n | --dry-run)
                # shellcheck disable=SC2034 # read by ku_run
                KU_DRY_RUN=1
                shift
                ;;
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
    ku_log info "cleanup: nothing to do"
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
# missing; 75 while apt or dpkg holds its lock, and 3 when that cannot be told; 3 when
# linux-base does not keep the links in /boot or one does not reach a non-empty file there,
# when check's kernels item fails, as while a kernel package is stuck between states, and when
# dpkg was interrupted. The locks come before the links, the packages and dpkg's updates
# directory, which a running apt or dpkg changes for a moment.
_ku_cl_preconditions() {
    local key name holder i status=0 refused=0 kernels=""
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
#                         PLAN
# =======================================================

# Print one line of the plan: TEXT, unless it is empty, on stderr through ku_plan, whatever the
# verbosity, and with --porcelain each RECORD after it, the four fields STEP, ACTION, OBJECT and
# DETAIL, as a tab-separated line on stdout. STEP is protect, rc, autoremove, modules or
# expire, and ACTION keep, purge, list, skip, rmdir, quarantine or delete. A field's control
# characters become blanks, so that no tab or line break shifts the fields, and an empty field
# shows as -.
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
        printf '%s\n' "$line"
        shift 4
    done
}
