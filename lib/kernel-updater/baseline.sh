# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater baseline
#
# The tripwire over the stick's boot code: hashes the files share/kernel-updater/baseline.list
# names on partition 1, the MBR boot code and partition 1's boot sector, keeps the sums in
# /var/lib/kernel-updater/baseline and compares them; the baseline command records them, and a
# writer updates the entries of the files it wrote. Also reads the version of the stick's GRUB.
# Defines functions and settings only.
# -------------------------------------------------------

# Where the baseline is kept, under KU_ROOT.
KU_BASELINE=/var/lib/kernel-updater/baseline

# What ku_baseline_compare found: how many entries are the same, and the names of those that
# changed, are new or are missing.
KU_BL_SAME=0 KU_BL_CHANGED=() KU_BL_NEW=() KU_BL_MISSING=()

# The temporary file the baseline is written through, which the exit trap removes.
KU_BL_TMP=""
# 1 once _ku_baseline_cleanup is registered with the exit trap.
KU_BL_CLEANUP=0

# A GRUB 2 version as GRUB builds it into its modules: 2.02, 2.02~beta2 or 2.06-13+deb12u1.
KU_GRUB_VERSION_RE='^2\.[0-9][0-9]([~+.-][0-9A-Za-z.~+-]*)?$'

# Print the baseline command's usage on stdout.
ku_baseline_usage() {
    cat << 'EOF'
Usage: kernel-updater baseline [--show] [--yes] [--dry-run] [--porcelain]

Records the SHA-256 of the stick's boot code in /var/lib/kernel-updater/baseline, which the
tripwire item of check compares with: the files on partition 1 that
share/kernel-updater/baseline.list names, the MBR boot code and partition 1's boot sector.
Runs as root: finds partition 1 from /boot, checks that it is the one disk_ptuuid and
p1_fs_uuid name, reads it through p1_path or a mount that is there, or else through a
read-only mount of its own, which it removes again, prints how it differs from the stored
baseline and asks before it records the new one.

  --show         change nothing: print whether the disk and partition 1 match the
                 configuration, the version of the stick's GRUB and how the stick differs
                 from the stored baseline
  -y, --yes      record without asking
  -n, --dry-run  print how the stick differs, record nothing
  --porcelain    print KEY and VALUE, tab-separated

--show prints disk and partition-1 as match, mismatch or not configured, never a value, or
as not found when partition 1 cannot be found from /boot; grub-version as the version or
unknown; and then same with a count and each changed, new and missing entry, or baseline as
none, damaged or not compared. It does not read a partition 1 that mismatches.

Exits 0 when recorded or shown, 4 when the baseline cannot be written, 10 when declined, 64 on
a usage error, 66 when partition 1 cannot be found or read, 75 when another run holds the lock,
77 when not run as root and 78 when disk_ptuuid or p1_fs_uuid is not set or names another disk
or partition.
EOF
}

# Record the baseline, or with --show only print how the stick compares with it. Prints one
# KEY VALUE line per result on stdout and messages on stderr. Exits 0 when it recorded or
# showed, or nothing changed since the stored baseline; 10 when declined; 64 on a usage error;
# 66 when partition 1 cannot be found or read; 75 when locked; 77 when not root; 78 on a bad
# configuration or another stick; and 4 when the baseline cannot be written.
ku_cmd_baseline() {
    local show=0 current stored file count devices=0 differences
    while (( $# )); do
        case $1 in
            --show) show=1; shift ;;
            -y | --yes)
                # shellcheck disable=SC2034 # read by ku_confirm
                KU_ASSUME_YES=1
                shift
                ;;
            -n | --dry-run) KU_DRY_RUN=1; shift ;;
            --porcelain) KU_PORCELAIN=1; shift ;;
            -h | --help) ku_baseline_usage; exit 0 ;;
            -*) ku_usage_error "baseline: unknown option $1" ;;
            *) ku_usage_error "baseline: unexpected argument '$1'" ;;
        esac
    done
    ku_require_root
    ku_load_config
    if (( show )); then
        _ku_baseline_show
        return 0
    fi
    ku_lock
    ku_p1_locate
    ku_p1_open ro || ku_die "$KU_EX_NOINPUT" "cannot read partition 1: $KU_DK_PROBLEM"
    if ! current=$(ku_baseline_hash "$KU_DK_ROOT"); then
        ku_die "$KU_EX_NOINPUT" "cannot hash the stick's boot code"
    fi
    _ku_baseline_close
    if [[ -z $current ]]; then
        ku_die "$KU_EX_NOINPUT" "partition 1 holds none of the files baseline.list names;" \
            "nothing was recorded"
    fi
    count=$(grep -c '' <<< "$current")
    if [[ $current == *"  mbr:boot-code"* ]]; then
        devices=2
    fi
    file=$(ku_path "$KU_BASELINE")
    if [[ ! -e $file ]]; then
        _ku_baseline_print baseline none
        ku_log info "baseline: no baseline is stored yet"
    elif ! stored=$(ku_baseline_read "$file"); then
        _ku_baseline_print baseline damaged
        ku_log warning "the stored baseline is damaged; it is recorded anew"
    else
        ku_baseline_compare "$stored" "$current"
        _ku_baseline_print_compare
        differences=$(( ${#KU_BL_CHANGED[@]} + ${#KU_BL_NEW[@]} + ${#KU_BL_MISSING[@]} ))
        if (( ! differences )); then
            ku_log info "baseline: partition 1 matches the stored baseline; nothing to record"
            return 0
        fi
        ku_log info "baseline: $(ku_baseline_summary)"
    fi
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: would record $count entries in $KU_BASELINE; nothing was written"
        return 0
    fi
    ku_confirm "Record the SHA-256 of $count entries of the stick's boot code in $KU_BASELINE?"
    _ku_baseline_write "$current"
    if (( devices )); then
        ku_log info "recorded $count entries in $KU_BASELINE: $(( count - devices )) file(s) on" \
            "partition 1, the MBR boot code and partition 1's boot sector"
    else
        ku_log info "recorded $count entries in $KU_BASELINE: $count file(s) on partition 1"
    fi
}

# baseline --show: print whether the disk and partition 1 match the configuration, the version
# of the stick's GRUB and how its boot code differs from the stored baseline. Changes nothing
# but a read-only mount of partition 1, which it removes, and says on stderr why it cannot
# read a part. A partition 1 that differs from what the configuration names is not read at all;
# one found from /boot while the configuration names none is.
_ku_baseline_show() {
    local disk part reach=1 status=0 current="" stored file
    if [[ -n $KU_P1_DIR ]]; then
        disk="not checked" part="not checked"
    elif ! ku_disk_find; then
        disk="not found" part="not found" reach=0
        ku_log warning "partition 1 cannot be found from /boot: $KU_DK_PROBLEM"
    else
        ku_disk_identity || status=$?
        disk=$(_ku_baseline_id_word "$KU_DK_DISK_ID")
        part=$(_ku_baseline_id_word "$KU_DK_P1_ID")
        if (( status == 1 )); then
            reach=0
            ku_log warning "$(ku_disk_identity_problem), so partition 1 is not read"
        fi
    fi
    _ku_baseline_print disk "$disk"
    _ku_baseline_print partition-1 "$part"
    if (( reach )) && ! ku_p1_open ro; then
        ku_log warning "cannot read partition 1: $KU_DK_PROBLEM"
        reach=0
    fi
    if (( ! reach )); then
        _ku_baseline_print grub-version unknown
        _ku_baseline_print baseline "not compared"
        return 0
    fi
    _ku_baseline_print grub-version "$(ku_grub_version "$KU_DK_ROOT")"
    if ! current=$(ku_baseline_hash "$KU_DK_ROOT"); then
        ku_log warning "cannot hash the stick's boot code"
        reach=0
    fi
    _ku_baseline_close
    file=$(ku_path "$KU_BASELINE")
    if [[ ! -e $file ]]; then
        _ku_baseline_print baseline none
    elif ! stored=$(ku_baseline_read "$file"); then
        _ku_baseline_print baseline damaged
    elif (( ! reach )); then
        _ku_baseline_print baseline "not compared"
    else
        ku_baseline_compare "$stored" "$current"
        _ku_baseline_print_compare
    fi
}

# Print the word --show uses for an identity verdict of ku_disk_identity.
_ku_baseline_id_word() {
    case $1 in
        match | mismatch) printf '%s' "$1" ;;
        *) printf 'not configured' ;;
    esac
}

# Remove partition 1's private mount, or warn that it stays, which the exit trap then tries
# again to remove.
_ku_baseline_close() {
    if ! ku_p1_close; then
        ku_log warning "the read-only mount of partition 1 stays on $KU_DK_MOUNT_DIR/p1:" \
            "unmount it and remove $KU_DK_MOUNT_DIR by hand"
    fi
}

# Print KEY and VALUE as one aligned line, or tab-separated with --porcelain.
_ku_baseline_print() {
    if (( KU_PORCELAIN )); then
        printf '%s\t%s\n' "$1" "$2"
    else
        printf '%-12s  %s\n' "$1" "$2"
    fi
}

# Print what ku_baseline_compare found: same with the number of entries alike, then changed,
# new and missing with each name.
_ku_baseline_print_compare() {
    local name
    _ku_baseline_print same "$KU_BL_SAME"
    for name in "${KU_BL_CHANGED[@]}"; do
        _ku_baseline_print changed "$name"
    done
    for name in "${KU_BL_NEW[@]}"; do
        _ku_baseline_print new "$name"
    done
    for name in "${KU_BL_MISSING[@]}"; do
        _ku_baseline_print missing "$name"
    done
}

# Store the baseline TEXT in KU_BASELINE through a temporary file renamed over it, in a
# directory with mode 0700 and with mode 0600. Exits 4 when that fails, which leaves the stored
# baseline as it was.
_ku_baseline_write() {
    local file dir
    file=$(ku_path "$KU_BASELINE")
    dir=${file%/*}
    if (( ! KU_BL_CLEANUP )); then
        ku_cleanup_add _ku_baseline_cleanup
        KU_BL_CLEANUP=1
    fi
    if ! mkdir -p -- "$dir" || ! chmod 0700 -- "$dir" ||
        ! KU_BL_TMP=$(mktemp -- "$dir/.baseline.XXXXXXXX") ||
        ! printf '%s\n' "$1" > "$KU_BL_TMP" || ! chmod 0600 -- "$KU_BL_TMP" ||
        ! mv -T -f -- "$KU_BL_TMP" "$file"; then
        ku_die "$KU_EX_WRITE" "cannot write $KU_BASELINE; the stored baseline is as it was"
    fi
    KU_BL_TMP=""
}

# Exit trap: remove the temporary file a cut-short write of the baseline left behind.
_ku_baseline_cleanup() {
    [[ -z $KU_BL_TMP ]] || rm -f -- "$KU_BL_TMP"
}

# Set the entries NAME of the stored baseline to the SHA-256 HASH, given as NAME HASH pairs,
# adding those it lacks and leaving every other entry as it is. A writer that replaced boot
# files on partition 1 and read them back records just those, so that the tripwire takes them
# without also taking whatever else changed on the stick since the baseline was recorded.
# Returns 1, changing nothing, when no baseline is stored, the stored one is damaged, or a pair
# is no name and SHA-256; exits 4 when the write fails. With --dry-run it checks the same and
# says what it would record, but writes nothing, as the files were not written either.
ku_baseline_update() {
    local file stored hash name names count=$(( $# / 2 ))
    local -A sums=()
    (( $# > 0 && $# % 2 == 0 )) || return 1
    file=$(ku_path "$KU_BASELINE")
    [[ -e $file ]] || return 1
    stored=$(ku_baseline_read "$file") || return 1
    _ku_baseline_sums "$stored" sums
    while (( $# )); do
        [[ $1 =~ ^[^[:cntrl:][:space:]/][^[:cntrl:]]*$ && $2 =~ ^[0-9a-f]{64}$ ]] || return 1
        sums[$1]=$2
        shift 2
    done
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: would record $count file(s) in $KU_BASELINE; nothing was written"
        return 0
    fi
    names=$(printf '%s\n' "${!sums[@]}" | LC_ALL=C sort)
    _ku_baseline_write "$(while IFS= read -r name; do
        printf '%s  %s\n' "${sums[$name]}" "$name"
    done <<< "$names")"
}

# Record the whole baseline of the stick under partition 1's ROOT, as 'kernel-updater baseline
# --yes' records it, without its lock, which the caller holds, and without asking: migrate's
# finalize stage calls it once it wrote grub.cfg while no baseline is stored. With --dry-run it
# only says what it would record. Returns 1, recording nothing, when the boot code cannot be
# hashed or partition 1 holds none of the files baseline.list names; exits 4 when the write
# fails.
ku_baseline_record() {
    local current count
    current=$(ku_baseline_hash "$1") || return 1
    [[ -n $current ]] || return 1
    count=$(grep -c '' <<< "$current")
    if (( KU_DRY_RUN )); then
        ku_log info "dry run: would record $count entries in $KU_BASELINE; nothing was written"
        return 0
    fi
    _ku_baseline_write "$current"
    ku_log info "recorded $count entries of the stick's boot code in $KU_BASELINE"
}

# =======================================================
#                  HASHING AND COMPARING
# =======================================================

# Print "SHA256  NAME" for the boot files under partition 1's ROOT that baseline.list names,
# the MBR boot code of the disk (mbr:boot-code, its bytes 0 to 439) and partition 1's boot
# sector (p1:boot-sector, its first 512 bytes but a FAT flags byte), sorted by NAME. Files that
# do not exist are left out, and so are the two sectors while no disk is known, as with
# KU_P1_DIR without KU_P1_DISK.
# Returns 1 when the list, a file or a sector cannot be read, and then warns which of them,
# naming no device.
ku_baseline_hash() {
    local root=$1 out line name hash lba
    local -a names=()
    local -A sums=()
    if ! out=$(_ku_baseline_names "$root"); then
        ku_log warning "cannot list the files on partition 1 that baseline.list names"
        return 1
    fi
    [[ -z $out ]] || mapfile -t names <<< "$out"
    if (( ${#names[@]} )); then
        if ! out=$(cd -- "$root" && sha256sum -- "${names[@]}"); then
            ku_log warning "cannot read the files on partition 1 that baseline.list names"
            return 1
        fi
        while IFS= read -r line; do
            [[ $line =~ ^([0-9a-f]{64})\ [\ *](.+)$ ]] || return 1
            sums[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
        done <<< "$out"
    fi
    # Root reads the block devices; KU_P1_DISK is an image whose MBR places partition 1. Their
    # errors would name the device, so they go nowhere, and the warnings name the kind.
    if [[ -n $KU_P1_DISK ]]; then
        if ! hash=$(head -c 440 -- "$KU_P1_DISK" 2> /dev/null | ku_sha256); then
            ku_log warning "cannot read the MBR boot code of the disk"
            return 1
        fi
        sums[mbr:boot-code]=$hash
        if ! lba=$(_ku_baseline_p1_lba "$KU_P1_DISK") ||
            ! hash=$(dd if="$KU_P1_DISK" bs=512 skip="$lba" count=1 status=none 2> /dev/null |
                _ku_baseline_sector_hash); then
            ku_log warning "cannot read the boot sector of partition 1"
            return 1
        fi
        sums[p1:boot-sector]=$hash
    elif [[ -z $KU_P1_DIR && -n $KU_DK_DISK && -n $KU_DK_PART ]]; then
        if ! hash=$(head -c 440 -- "$KU_DK_DISK" 2> /dev/null | ku_sha256); then
            ku_log warning "cannot read the MBR boot code of the disk"
            return 1
        fi
        sums[mbr:boot-code]=$hash
        if ! hash=$(head -c 512 -- "$KU_DK_PART" 2> /dev/null | _ku_baseline_sector_hash); then
            ku_log warning "cannot read the boot sector of partition 1"
            return 1
        fi
        sums[p1:boot-sector]=$hash
    fi
    (( ${#sums[@]} )) || return 0
    out=$(printf '%s\n' "${!sums[@]}" | LC_ALL=C sort)
    while IFS= read -r name; do
        printf '%s  %s\n' "${sums[$name]}" "$name"
    done <<< "$out"
}

# Print the names under partition 1's ROOT that baseline.list names and that are regular files,
# one per line and sorted; the last component of a line may be a glob. A name that is or passes
# a symlink is left out (ku_p1_no_symlink), so that the tripwire reports it missing rather than
# hash a file elsewhere, and so is a name with a control character or a backslash, with a
# warning, since no boot file has one. Returns 1 when the list cannot be read or holds a line
# that is no relative path.
_ku_baseline_names() {
    local root=$1 list=$KU_SHAREDIR/baseline.list line name
    local -a patterns=()
    [[ -f $list && -r $list ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ $line =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]] || return 1
        line=${BASH_REMATCH[1]}
        [[ $line != /* && /$line/ != */../* && /$line/ != */./* ]] || return 1
        patterns+=("$line")
    done < "$list"
    (
        cd -- "$root" || exit 1
        shopt -s nullglob
        # FAT finds a name in any case, as GRUB does, and an old FAT tool stores short names
        # in capitals.
        [[ $KU_DK_FSTYPE != vfat ]] || shopt -s nocaseglob
        for line in "${patterns[@]}"; do
            # shellcheck disable=SC2086 # the last component of a line may be a glob
            for name in $line; do
                if [[ $name == *[[:cntrl:]\\]* ]]; then
                    ku_log warning "the tripwire leaves out a file under ${line%/*} whose name" \
                        "holds a control character or a backslash"
                elif [[ -f $name ]] && ku_p1_no_symlink . "$name"; then
                    printf '%s\n' "$name"
                fi
            done
        done
    ) | LC_ALL=C sort -u
}

# Print the SHA-256 of the boot sector on stdin, its first 512 bytes, with the flags byte of a
# FAT boot sector read as 0: Linux and Windows set its "not cleanly unmounted" and "disk
# errors" bits on a mount, and an unplug without an eject leaves them, which says nothing about
# the boot code. Every other sector, NTFS's among them, hashes byte for byte as it is.
_ku_baseline_sector_hash() {
    local hex flags
    hex=$(od -A n -v -t x1 | tr -d ' \n') || return 1
    if flags=$(_ku_baseline_fat_flags "$hex"); then
        hex=${hex:0:flags * 2}00${hex:flags * 2 + 2}
    fi
    # Bash before 5.2 has no & in a replacement, hence sed.
    # shellcheck disable=SC2001,SC2059 # the format holds only the \x escapes sed makes
    printf "$(sed 's/../\\x&/g' <<< "$hex")" | ku_sha256
}

# Print the offset of the flags byte when the hex digits HEX are a FAT boot sector: one that ends
# in 55 AA, is named neither NTFS nor exFAT at byte 3, and has an extended boot signature, 28 or
# 29, right after that byte: at 66 for FAT32, whose 16-bit FAT size is 0, and at 38 for FAT12
# and FAT16. Returns 1 for any other sector.
_ku_baseline_fat_flags() {
    local hex=$1 flags=37
    (( ${#hex} == 1024 )) && [[ ${hex:1020:4} == 55aa ]] || return 1
    # The names start "NTFS" and "EXFAT".
    [[ ${hex:6:8} != 4e544653 && ${hex:6:10} != 4558464154 ]] || return 1
    [[ ${hex:44:4} != 0000 ]] || flags=65
    [[ ${hex:(flags + 1) * 2:2} == 2[89] ]] || return 1
    printf '%s\n' "$flags"
}

# Print the first sector of the first partition in the MBR of the disk image FILE, which
# KU_P1_DISK names: the little-endian 32-bit start at byte 454. Returns 1 when FILE has none.
_ku_baseline_p1_lba() {
    local out lba
    local -a bytes=()
    out=$(od -A n -t u1 -j 454 -N 4 -- "$1" 2> /dev/null) || return 1
    read -r -a bytes <<< "$out"
    (( ${#bytes[@]} == 4 )) || return 1
    lba=$(( bytes[0] + (bytes[1] << 8) + (bytes[2] << 16) + (bytes[3] << 24) ))
    (( lba > 0 )) || return 1
    printf '%s\n' "$lba"
}

# Print the stored baseline in FILE once each of its lines is "SHA256  NAME". Returns 1 when
# one is not, or FILE cannot be read.
ku_baseline_read() {
    local line out=""
    [[ -f $1 && -r $1 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[0-9a-f]{64}\ \ [^[:cntrl:]]+$ ]] || return 1
        out+=$line$'\n'
    done < "$1"
    printf '%s' "$out"
}

# Set the associative array named NAME from the baseline LINES, "SHA256  NAME" each, keeping
# every byte of each name, blanks at its ends too, as a file name on NTFS may have them.
_ku_baseline_sums() {
    local -n _ku_bl_sums=$2
    local line
    while IFS= read -r line; do
        [[ $line =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || continue
        # shellcheck disable=SC2004 # the nameref is an associative array, keyed by the name
        _ku_bl_sums[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
    done <<< "$1"
}

# Compare the baseline lines CURRENT with STORED: set KU_BL_SAME to the number of entries
# alike, and KU_BL_CHANGED, KU_BL_NEW and KU_BL_MISSING to the sorted names that differ, are
# only in CURRENT, or are only in STORED.
ku_baseline_compare() {
    local hash name
    local -A old=() new=()
    KU_BL_SAME=0 KU_BL_CHANGED=() KU_BL_NEW=() KU_BL_MISSING=()
    _ku_baseline_sums "$1" old
    _ku_baseline_sums "$2" new
    while IFS= read -r name; do
        if [[ -z $name ]]; then
            continue
        elif [[ -z ${old[$name]+set} ]]; then
            KU_BL_NEW+=("$name")
        elif [[ ${old[$name]} == "${new[$name]}" ]]; then
            KU_BL_SAME=$((KU_BL_SAME + 1))
        else
            KU_BL_CHANGED+=("$name")
        fi
    done <<< "$(printf '%s\n' "${!new[@]}" | LC_ALL=C sort)"
    while IFS= read -r name; do
        if [[ -n $name && -z ${new[$name]+set} ]]; then
            KU_BL_MISSING+=("$name")
        fi
    done <<< "$(printf '%s\n' "${!old[@]}" | LC_ALL=C sort)"
}

# Print the differences ku_baseline_compare found as "changed: A, B; new: C; missing: D", with
# up to five names per kind and then how many more.
ku_baseline_summary() {
    local kind text=""
    local -a names=()
    for kind in changed new missing; do
        case $kind in
            changed) names=("${KU_BL_CHANGED[@]}") ;;
            new) names=("${KU_BL_NEW[@]}") ;;
            *) names=("${KU_BL_MISSING[@]}") ;;
        esac
        if (( ${#names[@]} )); then
            text+="${text:+; }$kind: $(_ku_baseline_some "${names[@]}")"
        fi
    done
    printf '%s' "$text"
}

# Print the NAMEs as a list: up to five, then how many more.
_ku_baseline_some() {
    local i shown=""
    for (( i = 1; i <= $# && i <= 5; i++ )); do
        shown+="${shown:+, }${!i}"
    done
    if (( $# > 5 )); then
        shown+=" and $(( $# - 5 )) more"
    fi
    printf '%s' "$shown"
}

# =======================================================
#                    THE STICK'S GRUB
# =======================================================

# Print the version of the stick's GRUB, read from the NUL-separated strings of the i386-pc
# normal.mod under partition 1's ROOT: the one distinct string that is exactly a GRUB 2
# version, or unknown when there is no normal.mod, no such string, or several, and when it is
# or passes a symlink, which this reader does not follow.
ku_grub_version() {
    local file=$1/multibootusb/grub/i386-pc/normal.mod out=""
    if ku_p1_no_symlink "$1" multibootusb/grub/i386-pc/normal.mod && [[ -f $file && -r $file ]]
    then
        out=$(tr '\0' '\n' < "$file" | LC_ALL=C grep -a -E -e "$KU_GRUB_VERSION_RE" |
            LC_ALL=C sort -u) || out=""
    fi
    if [[ -n $out && $out != *$'\n'* ]]; then
        printf '%s\n' "$out"
    else
        printf 'unknown\n'
    fi
}

# Print the major and minor version of GRUB VERSION as one number, 206 for 2.06-13+deb12u1,
# the scale on which check compares GRUB versions. Returns 1 for no version.
ku_grub_level() {
    [[ $1 =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    printf '%s\n' $(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} ))
}

# Print the highest grub_floor that GRUB VERSION reaches, 2.12 for 2.12~rc1 and 2.06 for
# 2.06-13+deb12u1, or nothing for a GRUB older than 2.02 or no version at all. Shared by
# check's grub-version item and migrate's detect stage.
ku_grub_floor_for() {
    local level candidate fit=""
    level=$(ku_grub_level "$1") || return 0
    for candidate in 2.02 2.06 2.12 2.14; do
        if (( 10#${candidate/./} <= level )); then
            fit=$candidate
        fi
    done
    [[ -z $fit ]] || printf '%s\n' "$fit"
}
