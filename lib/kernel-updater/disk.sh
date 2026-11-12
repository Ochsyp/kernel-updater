# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater partition 1
#
# Finds the stick's partition 1, the NTFS partition MultiBootUSB boots from, through the disk
# that holds /boot, checks that it is the one the configuration names, reaches its root to read
# or write it, and picks how a writer deploys to it. Defines functions and settings only.
# -------------------------------------------------------

# Seams for the tests, which come from the environment only with KU_TEST=1, as those of
# common.sh do: KU_P1_DIR, a directory that stands in for partition 1's root, so that nothing is
# found or mounted; KU_P1_DISK, a file that stands in for the disk, whose MBR boot code and first
# partition's boot sector the baseline hashes; KU_P1_FSTYPES, the filesystem types a read-only
# mount of partition 1 tries, in order, as a read-write one takes ntfs3 alone; and KU_P1_PROBE,
# the command that checks the volume before a read-write mount, so that a test can do without
# one.
if [[ ${KU_TEST:-} == 1 ]]; then
    KU_P1_DIR=${KU_P1_DIR:-} KU_P1_DISK=${KU_P1_DISK:-}
    KU_P1_FSTYPES=${KU_P1_FSTYPES:-ntfs3 ntfs-3g} KU_P1_PROBE=${KU_P1_PROBE:-ntfs-3g.probe}
else
    KU_P1_DIR="" KU_P1_DISK="" KU_P1_FSTYPES="ntfs3 ntfs-3g" KU_P1_PROBE=ntfs-3g.probe
fi

# What ku_disk_find found: the disk that holds /boot, its partition 1, the disk's PTUUID and
# partition 1's filesystem type and UUID. Never printed, since they name the stick.
KU_DK_DISK="" KU_DK_PART="" KU_DK_PTUUID="" KU_DK_FSTYPE="" KU_DK_UUID=""
# What ku_disk_identity found for the disk and for partition 1: match, mismatch or unset.
KU_DK_DISK_ID="" KU_DK_P1_ID=""
# Why the last step failed, in words that name no identifier.
KU_DK_PROBLEM=""
# Partition 1's root once ku_p1_open reached it, 1 when it can be written, and how it was
# reached: test (KU_P1_DIR), path (p1_path), mount (a mount that was there) or private.
KU_DK_ROOT="" KU_DK_WRITABLE=0 KU_DK_HOW=""
# 1 once _ku_p1_path warned that p1_path holds another grub.cfg than partition 1, so that a
# second look in the same run does not warn again.
KU_DK_PATH_WARNED=0
# Why plan and rw take no mount of partition 1 that is there, nor keep one of their own that
# another mount joined, and what to do about it.
KU_DK_SHARED="partition 1 is mounted where users other than root can change its files, as a"
KU_DK_SHARED+=" desktop mounts it for its user: unmount it there, as its eject does, and run"
KU_DK_SHARED+=" again"
# The private mount's directory in /run, 1 while partition 1 may be mounted on its p1/, and 1
# once the exit trap removes that mount.
KU_DK_MOUNT_DIR="" KU_DK_MOUNTED=0 KU_DK_CLEANUP=0
# How ku_deploy_resolve has a writer deploy, direct, path or export, and why it exports when it
# does.
# shellcheck disable=SC2034 # read by the commands that deploy
KU_DK_DEPLOY="" KU_DK_DEPLOY_WHY=""

# =======================================================
#                 FINDING PARTITION 1
# =======================================================

# Find partition 1 from the /boot mount, never from a /dev/sdX or by-id name: walk up from the
# filesystem at /boot with lsblk -s to the one disk under it (TYPE disk, or loop for a disk
# image), then take that disk's partition 1. Sets KU_DK_DISK, KU_DK_PART, KU_DK_PTUUID,
# KU_DK_FSTYPE and KU_DK_UUID, and reads with blkid -p what lsblk leaves empty without udev.
# Returns 1, with KU_DK_PROBLEM set, when /boot is not mounted, is on no block device, on no
# disk or on several, or the disk has no single partition 1.
ku_disk_find() {
    local out source line path type partn fstype uuid count=0
    local -a disks=()
    KU_DK_DISK="" KU_DK_PART="" KU_DK_PTUUID="" KU_DK_FSTYPE="" KU_DK_UUID="" KU_DK_PROBLEM=""
    out=$(ku_probe_boot_mount)
    IFS=$'\t' read -r source _ <<< "$out"
    if [[ -z $out ]]; then
        KU_DK_PROBLEM="/boot is not mounted"
        return 1
    elif [[ $source != /dev/?* ]]; then
        KU_DK_PROBLEM="the filesystem at /boot is on no block device"
        return 1
    fi
    if ! out=$(lsblk -s -n -r -o PATH,TYPE -- "$source" 2> /dev/null); then
        KU_DK_PROBLEM="lsblk cannot list the devices under the filesystem at /boot"
        return 1
    fi
    # The inverse tree lists a disk once for each path down to it, as for a volume group on two
    # partitions of one disk.
    while read -r path type _; do
        if [[ $type == disk || $type == loop ]] && [[ " ${disks[*]} " != *" $path "* ]]; then
            disks+=("$path")
        fi
    done <<< "$out"
    if (( ${#disks[@]} == 0 )); then
        KU_DK_PROBLEM="lsblk finds no disk under the filesystem at /boot"
        return 1
    elif (( ${#disks[@]} > 1 )); then
        KU_DK_PROBLEM="the filesystem at /boot spans ${#disks[@]} disks, so the stick is unclear"
        return 1
    fi
    if ! out=$(lsblk -n -r -o PATH,PARTN,FSTYPE,UUID -- "${disks[0]}" 2> /dev/null); then
        KU_DK_PROBLEM="lsblk cannot list the partitions of the disk that holds /boot"
        return 1
    fi
    # Raw output puts one space between columns and escapes the spaces in values, so splitting
    # at each space keeps an empty column in its place.
    while IFS= read -r line; do
        IFS='|' read -r path partn fstype uuid _ <<< "${line// /|}"
        if [[ $partn == 1 ]]; then
            count=$((count + 1))
            KU_DK_PART=$path KU_DK_FSTYPE=$fstype KU_DK_UUID=$uuid
        fi
    done <<< "$out"
    if (( count != 1 )); then
        KU_DK_PART="" KU_DK_FSTYPE="" KU_DK_UUID=""
        KU_DK_PROBLEM="the disk that holds /boot has no partition 1"
        (( count == 0 )) || KU_DK_PROBLEM="lsblk lists $count partitions numbered 1 on the disk"
        return 1
    fi
    KU_DK_DISK=${disks[0]}
    KU_DK_PTUUID=$(lsblk -d -n -r -o PTUUID -- "$KU_DK_DISK" 2> /dev/null) || KU_DK_PTUUID=""
    # Without udev, as in a chroot or container, lsblk leaves these empty; as root, blkid reads
    # them from the devices themselves.
    if [[ -z $KU_DK_PTUUID ]]; then
        KU_DK_PTUUID=$(blkid -p -s PTUUID -o value -- "$KU_DK_DISK" 2> /dev/null) ||
            KU_DK_PTUUID=""
    fi
    if [[ -z $KU_DK_FSTYPE ]]; then
        KU_DK_FSTYPE=$(blkid -p -s TYPE -o value -- "$KU_DK_PART" 2> /dev/null) ||
            KU_DK_FSTYPE=""
    fi
    if [[ -z $KU_DK_UUID ]]; then
        KU_DK_UUID=$(blkid -p -s UUID -o value -- "$KU_DK_PART" 2> /dev/null) || KU_DK_UUID=""
    fi
}

# Compare what ku_disk_find found with disk_ptuuid and p1_fs_uuid, ignoring case, and set
# KU_DK_DISK_ID and KU_DK_P1_ID to match, mismatch or unset (the key is not set). Partition 1
# must also be NTFS. Returns 0 when both match, 1 when either does not, and 2 when neither
# mismatches but a key is not set.
ku_disk_identity() {
    local ptuuid=${KU_CONF[disk_ptuuid]} serial=${KU_CONF[p1_fs_uuid]}
    KU_DK_DISK_ID=unset KU_DK_P1_ID=unset
    if [[ -n $ptuuid ]]; then
        KU_DK_DISK_ID=mismatch
        if [[ -n $KU_DK_PTUUID && ${KU_DK_PTUUID,,} == "${ptuuid,,}" ]]; then
            KU_DK_DISK_ID=match
        fi
    fi
    if [[ -n $serial ]]; then
        KU_DK_P1_ID=mismatch
        if [[ $KU_DK_FSTYPE == ntfs && -n $KU_DK_UUID && ${KU_DK_UUID^^} == "${serial^^}" ]]; then
            KU_DK_P1_ID=match
        fi
    fi
    if [[ $KU_DK_DISK_ID == mismatch || $KU_DK_P1_ID == mismatch ]]; then
        return 1
    elif [[ $KU_DK_DISK_ID == unset || $KU_DK_P1_ID == unset ]]; then
        return 2
    fi
}

# Print which part ku_disk_identity found to be another than the configuration names: the
# disk, partition 1 or both, never a value.
ku_disk_identity_problem() {
    case $KU_DK_DISK_ID:$KU_DK_P1_ID in
        mismatch:mismatch)
            printf 'neither the disk that holds /boot nor its partition 1 is the one'
            printf ' disk_ptuuid and p1_fs_uuid name'
            ;;
        mismatch:*) printf 'the disk that holds /boot is not the one disk_ptuuid names' ;;
        *)
            printf 'partition 1 of the disk that holds /boot is not the NTFS filesystem'
            printf ' p1_fs_uuid names'
            ;;
    esac
}

# Print what to do while disk_ptuuid or p1_fs_uuid is not set.
ku_disk_unset_hint() {
    printf 'set disk_ptuuid and p1_fs_uuid in /etc/kernel-updater.conf to the PTUUID of the'
    printf " stick and the UUID of its partition labelled BOOT, which 'lsblk -o"
    printf " NAME,LABEL,PTUUID,UUID' prints as root"
}

# Find partition 1 and check its identity, or exit: 66 when it cannot be found, and 78 when
# disk_ptuuid or p1_fs_uuid is not set or names another disk or partition. Returns at once with
# KU_P1_DIR. For the commands that record or write.
ku_p1_locate() {
    local status=0
    [[ -z $KU_P1_DIR ]] || return 0
    if ! ku_disk_find; then
        ku_die "$KU_EX_NOINPUT" "cannot find the stick's partition 1: $KU_DK_PROBLEM"
    fi
    ku_disk_identity || status=$?
    case $status in
        0) ;;
        1) ku_die "$KU_EX_CONFIG" "$(ku_disk_identity_problem); nothing was changed" ;;
        *) ku_die "$KU_EX_CONFIG" "the stick cannot be told apart: $(ku_disk_unset_hint)" ;;
    esac
}

# =======================================================
#                 REACHING PARTITION 1
# =======================================================

# Reach partition 1's root to read it (MODE ro), to read what a plan builds on (plan), or to
# write it (rw), and set KU_DK_ROOT, KU_DK_WRITABLE and KU_DK_HOW. A reader (ro), such as
# check and baseline, only hashes and lints what it reads, so any root serves it; plan and rw
# take only a root whose files no user but root can change (see _ku_p1_path and
# _ku_p1_device), since what root reads there for a plan ends up on the stick or in
# output_dir. Tries, in order: KU_P1_DIR; p1_path, which ro and plan take whenever it serves
# them and rw exactly when deploy = path; a mount of the partition that is there; and last a
# mount of its own on a private directory in /run, which a dry run makes read-only. Needs
# ku_disk_find first, but for KU_P1_DIR and a reader's p1_path. Returns 0 once a root is
# reached: a writer may write there while KU_DK_PROBLEM stays empty, and KU_DK_WRITABLE is
# then 1, but after a dry run's read-only mount. Returns 1 with KU_DK_PROBLEM set when no root
# is reached.
ku_p1_open() {
    local mode=$1
    if ! ku_p1_close; then
        KU_DK_PROBLEM="the previous mount of partition 1 stays"
        return 1
    fi
    KU_DK_PROBLEM=""
    if [[ -n $KU_P1_DIR ]]; then
        KU_DK_ROOT=$KU_P1_DIR KU_DK_HOW=test
    elif [[ $mode == rw && ${KU_CONF[deploy]} == path ]]; then
        if [[ -z ${KU_CONF[p1_path]} ]]; then
            KU_DK_PROBLEM="p1_path is not set"
            return 1
        fi
        _ku_p1_path rw || return 1
    elif [[ $mode != rw && -n ${KU_CONF[p1_path]} ]] && _ku_p1_path "$mode"; then
        :
    else
        if [[ $mode != rw && -n ${KU_CONF[p1_path]} ]]; then
            ku_log debug "p1_path does not serve: $KU_DK_PROBLEM; partition 1 is read itself"
        fi
        KU_DK_PROBLEM=""
        _ku_p1_device "$mode" || return 1
        [[ -z $KU_DK_PROBLEM ]] || return 0
    fi
    [[ $mode == rw ]] || return 0
    # A dry run mounts partition 1 read-only, so whether a writer could write there stays
    # untried.
    if [[ $KU_DK_HOW == private ]] && (( KU_DRY_RUN )); then
        return 0
    fi
    if ku_p1_writable "$KU_DK_ROOT"; then
        KU_DK_WRITABLE=1
        return 0
    fi
    case $KU_DK_HOW in
        test) KU_DK_PROBLEM="KU_P1_DIR is on a read-only mount" ;;
        path) KU_DK_PROBLEM="p1_path is on a read-only mount" ;;
        mount) KU_DK_PROBLEM="partition 1 is mounted read-only" ;;
        *) KU_DK_PROBLEM="partition 1 mounts only read-only" ;;
    esac
}

# Take p1_path as partition 1's root for MODE, ro, plan or rw, and set KU_DK_ROOT and
# KU_DK_HOW. It serves only while it is a mount point that holds multibootusb/grub/grub.cfg, so
# that an empty mount point, as on a native boot where a VM's shared folder is not mounted,
# never passes for partition 1; and, once partition 1 was found from /boot and can be read,
# only while that grub.cfg is the one partition 1 holds, so that a share of another stick does
# not either. plan and rw also need a p1_path whose files only root can change
# (_ku_p1_root_mount), mounted nowhere else (_ku_p1_path_sole), and one that partition 1 was
# read to check it against. Returns 1 with KU_DK_PROBLEM set otherwise, and warns, once, when
# the grub.cfg differs.
_ku_p1_path() {
    local mode=$1 path cfg want got=""
    path=$(ku_path "${KU_CONF[p1_path]}")
    cfg=$path/multibootusb/grub/grub.cfg
    if ! findmnt -n -r -o TARGET --mountpoint "$path" > /dev/null 2>&1; then
        KU_DK_PROBLEM="p1_path is not a mount point"
        return 1
    elif [[ -L $cfg || ! -f $cfg ]] || ! want=$(ku_sha256 "$cfg"); then
        KU_DK_PROBLEM="p1_path holds no multibootusb/grub/grub.cfg"
        return 1
    elif [[ $mode != ro ]] && ! _ku_p1_root_mount "$path"; then
        KU_DK_PROBLEM="users other than root can change the files under p1_path"
        return 1
    elif [[ $mode != ro ]] && ! _ku_p1_path_sole "$path"; then
        KU_DK_PROBLEM="the filesystem at p1_path is mounted elsewhere too, as by VirtualBox's"
        KU_DK_PROBLEM+=" automount, where users other than root may change its files"
        return 1
    fi
    if [[ -z $KU_DK_PART ]]; then
        if [[ $mode != ro ]]; then
            KU_DK_PROBLEM="partition 1 was not found, so p1_path cannot be checked against it"
            return 1
        fi
    elif _ku_p1_device ro; then
        cfg=$KU_DK_ROOT/multibootusb/grub/grub.cfg
        if [[ ! -L $cfg && -f $cfg ]]; then
            got=$(ku_sha256 "$cfg") || got=""
        fi
        if ! ku_p1_close; then
            KU_DK_PROBLEM="the mount of partition 1 that p1_path was checked against stays"
            return 1
        fi
        if [[ $got != "$want" ]]; then
            KU_DK_PROBLEM="p1_path holds another multibootusb/grub/grub.cfg than partition 1"
            if (( ! KU_DK_PATH_WARNED )); then
                ku_log warning "$KU_DK_PROBLEM, so it is not taken for partition 1"
                KU_DK_PATH_WARNED=1
            fi
            return 1
        fi
    elif [[ $mode != ro ]]; then
        KU_DK_PROBLEM="p1_path cannot be checked against partition 1: $KU_DK_PROBLEM"
        return 1
    fi
    KU_DK_PROBLEM=""
    KU_DK_ROOT=$path KU_DK_HOW=path
}

# Reach partition 1 itself for MODE, ro, plan or rw: through a mount of it that is there, or
# else a mount of its own (_ku_p1_mount). A reader (ro) takes any mount of the whole
# filesystem. plan and rw take one only while it is the partition's only mount, bind mounts
# included, and no user but root can change its files (_ku_p1_root_mount), and rw only while it
# is read-write: a desktop's mount for its user fails that, and so does any mount beside one,
# since mounts of one NTFS partition share their files. plan then has no root, as its reads
# would go through such a mount too. rw gets the first mount anyway, with KU_DK_PROBLEM saying
# why it cannot write there, since a second mount of a mounted NTFS partition fails, or shares
# the first one's files. Returns 1 with KU_DK_PROBLEM set when partition 1 was not found, plan
# finds no mount it may take, or a mount of its own fails.
_ku_p1_device() {
    local mode=$1 out target fsroot options first="" rw="" usable="" count=0
    if [[ -z $KU_DK_PART ]]; then
        KU_DK_PROBLEM="partition 1 was not found"
        return 1
    fi
    out=$(findmnt -n -r -o TARGET,FSROOT,OPTIONS --source "$KU_DK_PART" 2> /dev/null) ||
        out=""
    while read -r target fsroot options; do
        [[ -n $target ]] || continue
        count=$((count + 1))
        # Only a mount of the whole filesystem, not a bind mount of a directory in it, is
        # partition 1's root.
        [[ $fsroot == / ]] || continue
        printf -v target '%b' "$target"
        [[ -n $first ]] || first=$target
        if [[ $mode == rw ]]; then
            [[ ${options%%,*} == rw ]] || continue
            [[ -n $rw ]] || rw=$target
        fi
        if [[ $mode != ro && -z $usable ]] && _ku_p1_root_mount "$target"; then
            usable=$target
        fi
    done <<< "$out"
    # A mount beside it shares its files with whoever made that one.
    (( count == 1 )) || usable=""
    if [[ $mode == ro && -n $first ]]; then
        KU_DK_ROOT=$first KU_DK_HOW=mount
    elif [[ -n $usable ]]; then
        KU_DK_ROOT=$usable KU_DK_HOW=mount
    elif [[ $mode == ro ]] || (( count == 0 )); then
        _ku_p1_mount "$mode"
    elif [[ $mode == plan ]]; then
        KU_DK_PROBLEM=$KU_DK_SHARED
        return 1
    elif [[ -n $rw ]]; then
        KU_DK_ROOT=$rw KU_DK_HOW=mount
        KU_DK_PROBLEM=$KU_DK_SHARED
    elif [[ -n $first ]]; then
        KU_DK_ROOT=$first KU_DK_HOW=mount
        # Read-only or not, a mount others can change is no root for writing.
        if (( count == 1 )) && _ku_p1_root_mount "$first"; then
            KU_DK_PROBLEM="partition 1 is mounted read-only"
        else
            KU_DK_PROBLEM=$KU_DK_SHARED
        fi
    else
        # Only bind mounts of its directories, which hold its files all the same.
        KU_DK_PROBLEM=$KU_DK_SHARED
        return 1
    fi
}

# Return 0 when the mount point TARGET belongs to root and no user but root can change where
# its path leads (ku_p1_root_only): the walk stops at a directory closed to group and others,
# so the mount point itself must be root's too, which the root of a desktop's mount for its
# user is not.
_ku_p1_root_mount() {
    local owner
    ku_p1_root_only "$1" || return 1
    owner=$(stat -L -c '%u' -- "$1" 2> /dev/null) || return 1
    [[ ${owner%% *} == 0 ]]
}

# Return 0 when the filesystem mounted on PATH, which p1_path names, is mounted nowhere else,
# bind mounts included: a second mount, such as VirtualBox's automount of the same share or a
# desktop's mount of partition 1, shares its files with whoever may change them there.
_ku_p1_path_sole() {
    local src out target count=0 seen=0
    src=$(findmnt -n -r -o SOURCE --mountpoint "$1" 2> /dev/null) || return 1
    # Mounts stacked on PATH come oldest first, as an automount's under the share it mounts.
    printf -v src '%b' "${src##*$'\n'}"
    [[ -n $src ]] || return 1
    out=$(findmnt -n -r -o TARGET --source "$src" 2> /dev/null) || return 1
    while read -r target; do
        [[ -n $target ]] || continue
        count=$((count + 1))
        printf -v target '%b' "$target"
        [[ $target != "$1" ]] || seen=1
    done <<< "$out"
    (( count == 1 && seen ))
}

# Return 0 when the filesystem that holds DIR is mounted read-write: its first option, as
# findmnt prints it, is rw. Serves KU_P1_DIR, p1_path and a mount of partition 1 alike.
ku_p1_writable() {
    local out
    out=$(findmnt -n -o OPTIONS --target "$1" 2> /dev/null) || return 1
    out=${out##*$'\n'}
    [[ ${out%%,*} == rw ]]
}

# Return 0 when no user but root can change where the absolute path DIR leads or what its
# directories hold: from / down to DIR, each directory is no symlink, belongs to root and keeps
# every other user from renaming its entries (writable by root alone, or sticky), unless one of
# them, root's, is closed to group and others, who then cannot reach anything under it. A
# writer writes only along such a path, since a user who can rename an entry on it could swap a
# file or directory for a symlink between the writer's checks and its writes.
ku_p1_root_only() {
    local rest=${1#/} dir=/ part info owner mode
    [[ $1 == /* ]] || return 1
    while :; do
        [[ ! -L $dir && -d $dir ]] || return 1
        info=$(stat -L -c '%u %a' -- "$dir" 2> /dev/null) || return 1
        read -r owner mode <<< "$info"
        [[ $owner == 0 && $mode =~ ^[0-7]+$ ]] || return 1
        # Closed to group and others, so nothing under it is theirs to reach.
        (( (8#$mode & 8#011) != 0 )) || return 0
        (( (8#$mode & 8#022) == 0 || (8#$mode & 8#1000) != 0 )) || return 1
        # The next component, past the empty ones a doubled slash leaves.
        part=""
        while [[ -z $part && -n $rest ]]; do
            part=${rest%%/*}
            if [[ $rest == */* ]]; then
                rest=${rest#*/}
            else
                rest=""
            fi
        done
        [[ -n $part ]] || return 0
        dir=${dir%/}/$part
    done
}

# Return 0 when no component of the relative path REL under ROOT, its directories and the file
# alike, is a symlink. Readers of partition 1 follow none, since one that Windows or a user who
# owns a mount of it made could lead root to files elsewhere, and in a boot tree it means that
# something changed.
ku_p1_no_symlink() {
    local path=$1 rest=$2 part
    while [[ -n $rest ]]; do
        part=${rest%%/*}
        if [[ $rest == */* ]]; then
            rest=${rest#*/}
        else
            rest=""
        fi
        path+=/$part
        [[ ! -L $path ]] || return 1
    done
}

# Remove the private mount ku_p1_open made, if it made one, and forget partition 1's root.
# Returns 1 when the mount stays, which the exit trap then tries again to remove.
ku_p1_close() {
    KU_DK_ROOT="" KU_DK_WRITABLE=0 KU_DK_HOW=""
    _ku_p1_cleanup
}

# Mount partition 1 on p1/ in a new private directory in /run, read-only for MODE ro and plan,
# trying the types in KU_P1_FSTYPES in turn, and read-write for rw, with ntfs3 alone; always
# with nosuid, nodev and noexec. A dry run mounts read-only whatever MODE says. Never forced,
# never removing the hibernation file, and never replaying and clearing the log Windows left:
# ntfs3 replays that log on a read-write mount and has no option to refuse, so a read-write
# mount waits for ntfs-3g.probe to find the volume clean (_ku_p1_probe_rw); ntfs3 then refuses
# a volume marked dirty, as Windows marks one it wants to check, which ntfs-3g would mount
# read-write all the same, and which the probe does not look at; and ntfs-3g gets norecover,
# since recovering is its default. A read-only mount writes nothing with either. For plan and rw
# the mount must then be the partition's only one, with a root of root's, since a desktop that
# mounted the partition meanwhile would share its files (_ku_p1_sole). The exit trap removes the
# mount. Returns 1 with KU_DK_PROBLEM set when /run is not safe to mount in, the volume is not
# safe to write, no type mounts, or another mount shares the files.
_ku_p1_mount() {
    local mode=$1 flag=ro parent dir type opts kind=read-only
    local -a types=()
    if [[ $mode == rw ]] && (( ! KU_DRY_RUN )); then
        flag=rw kind=read-write
        _ku_p1_probe_rw || return 1
    fi
    # mount and umount follow symlinks, so a user who can rename entries in the parent could
    # swap the mount point for one. Hence /run, as for check's look under /boot.
    parent=$(ku_path /run)
    if ! ku_root_only_dir "$parent"; then
        KU_DK_PROBLEM="/run is not a directory whose entries only root can rename"
        return 1
    fi
    if ! dir=$(mktemp -d "$parent/kernel-updater.XXXXXXXX"); then
        KU_DK_PROBLEM="mktemp cannot make a directory in /run"
        return 1
    fi
    KU_DK_MOUNT_DIR=$dir
    if (( ! KU_DK_CLEANUP )); then
        ku_cleanup_add _ku_p1_cleanup
        KU_DK_CLEANUP=1
    fi
    # The mount point sits in mktemp's private directory, so no other user can walk the mount.
    if ! mkdir "$dir/p1"; then
        KU_DK_PROBLEM="mkdir cannot make the mount point in /run"
        _ku_p1_cleanup || :
        return 1
    fi
    if [[ $flag == rw ]]; then
        types=(ntfs3)
    else
        read -r -a types <<< "$KU_P1_FSTYPES"
    fi
    for type in "${types[@]}"; do
        opts=nosuid,nodev,noexec,$flag
        if [[ $type == ntfs-3g ]]; then
            opts+=,norecover
        fi
        KU_DK_MOUNTED=1
        if mount -t "$type" -o "$opts" "$KU_DK_PART" "$dir/p1" 2> /dev/null; then
            ku_log debug "partition 1 is mounted $kind with $type"
            if [[ $mode != ro ]] && ! _ku_p1_sole "$dir/p1"; then
                KU_DK_PROBLEM=$KU_DK_SHARED
                _ku_p1_cleanup || :
                return 1
            fi
            KU_DK_ROOT=$dir/p1 KU_DK_HOW=private
            return 0
        fi
        ku_log debug "partition 1 does not mount $kind with $type"
    done
    if [[ $flag == rw ]] && ! grep -q -w ntfs3 "$(ku_path /proc/filesystems)" 2> /dev/null; then
        # mount loaded the module if there was one.
        KU_DK_PROBLEM="partition 1 does not mount read-write: this kernel has no ntfs3 driver,"
        KU_DK_PROBLEM+=" which writing it needs, as ntfs-3g would write a volume marked dirty all"
        KU_DK_PROBLEM+=" the same"
    elif [[ $flag == rw ]]; then
        KU_DK_PROBLEM="partition 1 does not mount read-write with ntfs3, as when the volume is"
        KU_DK_PROBLEM+=" marked dirty: let Windows check the stick, then run again"
    else
        KU_DK_PROBLEM="partition 1 does not mount $kind with ${KU_P1_FSTYPES// /, }"
    fi
    _ku_p1_cleanup || :
    return 1
}

# Return 0 when ntfs-3g.probe finds partition 1 safe to mount read-write: not hibernated, not
# held in a cache of Windows for Fast Startup, and unmounted cleanly. Without ntfs-3g.probe, from
# the package ntfs-3g, partition 1 counts as unsafe. Returns 1 with KU_DK_PROBLEM set otherwise.
# The probe's output names the device, so it goes nowhere.
_ku_p1_probe_rw() {
    local status=0
    if ! command -v "$KU_P1_PROBE" > /dev/null; then
        KU_DK_PROBLEM="ntfs-3g.probe, from the package ntfs-3g, is not installed, so whether"
        KU_DK_PROBLEM+=" Windows left partition 1 safe to write cannot be checked"
        return 1
    fi
    "$KU_P1_PROBE" --readwrite "$KU_DK_PART" > /dev/null 2>&1 || status=$?
    case $status in
        0) return 0 ;;
        14)
            KU_DK_PROBLEM="Windows left partition 1 hibernated, or kept it in its cache for Fast"
            KU_DK_PROBLEM+=" Startup: eject the stick in Windows, or shut Windows down fully,"
            KU_DK_PROBLEM+=" before you boot from it"
            ;;
        15)
            KU_DK_PROBLEM="Windows did not unmount partition 1 cleanly: eject the stick in"
            KU_DK_PROBLEM+=" Windows, or let Windows check it, before you boot from it"
            ;;
        *) KU_DK_PROBLEM="ntfs-3g.probe finds partition 1 unsafe to write (exit $status)" ;;
    esac
    return 1
}

# Return 0 when the mount on TARGET, which _ku_p1_mount made, is partition 1's only mount, bind
# mounts included, and its root is root's: a desktop that mounted the partition in the meantime
# shares the files of that mount, which its user owns.
_ku_p1_sole() {
    local out target owner count=0 seen=0
    out=$(findmnt -n -r -o TARGET --source "$KU_DK_PART" 2> /dev/null) || return 1
    while read -r target; do
        [[ -n $target ]] || continue
        count=$((count + 1))
        printf -v target '%b' "$target"
        [[ $target != "$1" ]] || seen=1
    done <<< "$out"
    (( count == 1 && seen )) || return 1
    owner=$(stat -L -c '%u' -- "$1" 2> /dev/null) || return 1
    [[ ${owner%% *} == 0 ]]
}

# Unmount partition 1's private mount, lazily when a plain unmount fails, and remove its two
# directories. Safe to call again, and only ever removes empty directories: rmdir fails while
# the mount stays, so the mount cannot lose a file, and the exit trap tries again.
_ku_p1_cleanup() {
    [[ -n $KU_DK_MOUNT_DIR ]] || return 0
    if (( KU_DK_MOUNTED )); then
        # After a failed mount there may be nothing to unmount.
        umount "$KU_DK_MOUNT_DIR/p1" 2> /dev/null ||
            umount -l "$KU_DK_MOUNT_DIR/p1" 2> /dev/null || true
    fi
    if [[ -d $KU_DK_MOUNT_DIR/p1 ]]; then
        rmdir "$KU_DK_MOUNT_DIR/p1" || return 1
    fi
    KU_DK_MOUNTED=0
    rmdir "$KU_DK_MOUNT_DIR" || return 1
    KU_DK_MOUNT_DIR=""
}

# =======================================================
#                   THE DEPLOY MODE
# =======================================================

# Return 0 when this system runs in a virtual machine, as systemd-detect-virt --vm tells.
# Without systemd-detect-virt it counts as none.
ku_in_vm() {
    command -v systemd-detect-virt > /dev/null || return 1
    systemd-detect-virt --vm --quiet
}

# Pick how a writer deploys to partition 1, from deploy, and reach its root: direct writes
# through a mount of the partition, path through p1_path, and export leaves the files in
# output_dir for Windows to copy. In a VM, where Windows may have partition 1 mounted on the
# host, this system never writes partition 1 itself: auto and direct export there, and only
# path writes, through the host. Elsewhere auto writes directly. direct and path fall back to
# export, with a warning that says why, when they get no root they may write: a read-only
# mount, a volume Windows left hibernated, unclean or marked dirty, which only a mount of its
# own looks at, since a read-write mount that root made took the volume as it was, a failed
# mount, or a p1_path that does not serve. A dry run keeps the mode it would use but mounts
# partition 1 read-only. Finds partition 1 and checks its identity first, so it exits 66 or 78
# as ku_p1_locate does. Sets KU_DK_DEPLOY, KU_DK_DEPLOY_WHY for every export, and KU_DK_ROOT,
# whose files no user but root can change, so that a plan may read there what it builds on
# (ku_deploy_read), and which direct and path may write but in a dry run. Returns 1 with
# KU_DK_PROBLEM set when there is no
# such root, which an export needs too, as while a desktop has partition 1 mounted for its
# user.
ku_deploy_resolve() {
    local mode=${KU_CONF[deploy]} name=${KU_CONF[deploy]} why="" vm=0
    KU_DK_DEPLOY="" KU_DK_DEPLOY_WHY=""
    ku_p1_locate
    case $mode in
        auto | direct)
            if ku_in_vm; then
                why="this system runs in a VM, where Windows may have partition 1 mounted on"
                why+=" the host, so it never writes partition 1 itself"
                mode="export" vm=1
            else
                mode=direct
            fi
            ;;
        export) why="deploy = export" ;;
    esac
    if [[ $mode == direct || $mode == path ]]; then
        if ku_p1_open rw && [[ -z $KU_DK_PROBLEM ]]; then
            KU_DK_DEPLOY=$mode
            if (( ! KU_DK_WRITABLE )); then
                ku_log info "dry run: partition 1 is mounted read-only, so whether deploy =" \
                    "$name can write it is not tried"
            fi
            return 0
        fi
        why=$KU_DK_PROBLEM
    fi
    # An export reads partition 1 too, but only where no user but root can change it, so it
    # says that the files go to output_dir only once it has such a root.
    if ! ku_p1_open plan; then
        if [[ $name != export && $KU_DK_PROBLEM != "$why" ]]; then
            ku_log warning "deploy = $name cannot write partition 1: $why"
        fi
        return 1
    fi
    if [[ $name == auto ]] && (( vm )); then
        ku_log info "deploy = auto picks export: $why"
    elif [[ $name != export ]]; then
        ku_log warning "deploy = $name cannot write partition 1: $why; the files go to" \
            "output_dir for Windows to copy instead"
    fi
    # shellcheck disable=SC2034 # read by the commands that deploy
    KU_DK_DEPLOY="export" KU_DK_DEPLOY_WHY=$why
}
