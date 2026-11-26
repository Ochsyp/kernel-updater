# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater deploy
#
# Writes files to partition 1 one at a time and safely: checks that the target still holds what
# the plan read, keeps dated backups beside it, writes a synced temporary file and puts it in
# the target's place, moving the target aside first rather than renaming over it, reads it back
# and puts the old file back when anything fails. Or exports the files, with their SHA-256 sums
# and the steps that copy them, for Windows to deploy. Defines functions and settings only.
# -------------------------------------------------------

# Temporary files a write or an export made and has neither renamed nor removed yet, which the
# exit trap removes.
KU_DEPLOY_TMPS=()

# 1 when dd can refuse to follow a symlink (iflag and oflag nofollow), as GNU dd on Linux can,
# 0 when it cannot, as Cygwin's, and empty until _ku_deploy_probe has asked.
KU_DEPLOY_NOFOLLOW=""

# 1 while ku_deploy_files runs the checks of ku_deploy_write for every file before it writes the
# first, and the files it wrote so far, which a later failure names.
KU_DEPLOY_CHECKING=0 KU_DEPLOY_DONE=()

# A command ku_deploy_write runs once, for the first file a run writes: after that file's last
# check and its verified backup, and before its old backups rotate and its temporary file is
# made; empty for none. It clears itself before it runs, and a dry run never reaches it. migrate
# sets it only for its own writes and seals its backup there, so that a run stopped before it
# changed anything leaves no backup a rollback would take for one that wrote something.
KU_DEPLOY_BEFORE_WRITE=""

# While a write has moved its target aside on NTFS: the target and the name it waits under,
# which the exit trap puts back when the run is cut short before the new file took its place.
KU_DEPLOY_ASIDE=()

# The SHA-256 of the file ku_deploy_read copied last, empty after it failed.
# shellcheck disable=SC2034 # read by the commands that plan
KU_DEPLOY_SUM=""

# Where the files go on partition 1, as DEPLOY.txt names it for Windows.
KU_DEPLOY_WINDOWS_DIR="BOOT:\\multibootusb\\grub\\"

# =======================================================
#                    THE SAFE WRITER
# =======================================================

# Replace RELPATH under partition 1's ROOT with the bytes of the local file SOURCE, CRLF line
# endings and all. EXPECTED is the SHA-256 the plan read from the target, or - for a target
# that must not exist yet. In this order: exit 75, nothing changed, when the target exists
# although the plan expected none, or, re-hashed, changed since the plan read it, as a run that
# plans anew can then succeed, a symlink where none was expected included; exit 3 when the
# target or a directory between ROOT and it is a symlink, or when a user other than root could
# change the path to it (ku_p1_root_only), which KU_P1_DIR needs not pass, as it stands in for a
# private mount; copy the target to
# RELPATH.ku-<UTC stamp>.bak beside it and keep that backup and the newest others, backups_keep
# in all; write SOURCE to a temporary file in the same directory, sync it, put it in the
# target's place (_ku_deploy_replace, which moves the target aside first) and sync the
# filesystem; read the target back from the stick. Exits 4 when a step after the backup fails:
# saying that the target was not changed, or was put back as it was, when the temporary file
# cannot be written or put in its place, or, when putting it back fails too, naming the backup
# to copy by hand while the old file waits aside; and else, once the new file took its place,
# after it restored the old one, saying whether that worked. Follows no symlink, and removes its
# temporary file on every path. Exits 66 when SOURCE
# is a symlink or cannot be read. With --dry-run it stops after the checks and says what it
# would write. Within ku_deploy_files, once it wrote an earlier file, a failure exits 4 and
# names the files written (_ku_deploy_die); so do a refusal and a change since the plan read it.
ku_deploy_write() {
    local root=$1 rel=$2 source=$3 expected=$4 target dir name want got stamp="" backup=-
    local tmp="" aside="" path rest hook
    if [[ $rel == /* || /$rel/ == *//* || /$rel/ == */./* || /$rel/ == */../* ]]; then
        _ku_deploy_die "$KU_EX_REFUSED" 1 \
            "refusing to write $rel: it is no plain path inside partition 1"
    fi
    if [[ $expected != - && ! $expected =~ ^[0-9a-f]{64}$ ]]; then
        _ku_deploy_die "$KU_EX_REFUSED" 1 "refusing to write $rel: the plan holds no SHA-256 for it"
    fi
    if [[ -L $source || ! -f $source || ! -r $source ]] || ! want=$(ku_sha256 "$source"); then
        _ku_deploy_die "$KU_EX_NOINPUT" 1 "cannot read the new contents of $rel"
    fi
    _ku_deploy_probe
    target=$root/$rel
    dir=${target%/*}
    name=${target##*/}
    # a. The target must hold what the plan read: nothing, or the bytes it hashed. Where the
    # plan read a file, a symlink is left to step b, and -f never lets a device or a pipe be
    # read; where it read none, anything there, a symlink too, counts as a change. Either way a
    # mismatch is busy rather than refused: a run that plans anew from what the target holds now
    # can succeed, as when the system changed while a question waited, and that plan then
    # refuses a symlink when it reads the target.
    if [[ $expected == - ]]; then
        if [[ -e $target || -L $target ]]; then
            _ku_deploy_die "$KU_EX_BUSY" 1 \
                "refusing to write $rel: it exists, but the plan expected none"
        fi
    elif [[ ! -L $target ]] && { [[ ! -f $target ]] || ! got=$(_ku_deploy_hash "$target") ||
        [[ $got != "$expected" ]]; }; then
        _ku_deploy_die "$KU_EX_BUSY" 1 \
            "refusing to write $rel: it changed since the plan read it"
    fi
    # b. No symlink may take the write elsewhere, and no user but root may put one in its way
    # between these checks and the writes.
    path=$root rest=$rel
    while [[ $rest == */* ]]; do
        path+=/${rest%%/*}
        rest=${rest#*/}
        if [[ -L $path || ! -d $path ]]; then
            _ku_deploy_die "$KU_EX_REFUSED" 1 \
                "refusing to write $rel: ${path#"$root"/} is a symlink or no directory"
        fi
    done
    if [[ -L $target ]]; then
        _ku_deploy_die "$KU_EX_REFUSED" 1 "refusing to write $rel: it is a symlink"
    fi
    if [[ $root != "$KU_P1_DIR" ]] && ! ku_p1_root_only "$dir"; then
        _ku_deploy_die "$KU_EX_REFUSED" 1 \
            "refusing to write $rel: users other than root can change the directories on its way"
    fi
    # ku_deploy_files checks every file up to here before it writes the first.
    if (( KU_DEPLOY_CHECKING )); then
        return 0
    fi
    if [[ $expected != - ]]; then
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        backup=$target.ku-$stamp.bak aside=$dir/.$name.ku-$stamp.old
        if [[ -e $backup || -L $backup || -e $aside || -L $aside ]]; then
            _ku_deploy_die "$KU_EX_REFUSED" 1 "refusing to write $rel: its backup" \
                "$rel.ku-$stamp.bak exists already, so try again in a second"
        fi
    fi
    if (( KU_DRY_RUN )); then
        ku_log info "would write $rel${stamp:+, keeping the old one as $rel.ku-$stamp.bak}"
        return 0
    fi
    # c. Keep the target as it was, and only its newest backups. The first write of a run
    # runs KU_DEPLOY_BEFORE_WRITE in between: every check passed, and nothing changed yet.
    if [[ -n $stamp ]]; then
        if ! _ku_deploy_copy "$target" "$backup" excl || ! got=$(_ku_deploy_hash "$backup") ||
            [[ $got != "$expected" ]]; then
            rm -f -- "$backup" || :
            _ku_deploy_die "$KU_EX_WRITE" 1 "cannot back up $rel"
        fi
        _ku_deploy_sync "$backup"
    fi
    if [[ -n $KU_DEPLOY_BEFORE_WRITE ]]; then
        hook=$KU_DEPLOY_BEFORE_WRITE
        KU_DEPLOY_BEFORE_WRITE=""
        # A hook that stops the run leaves the stick as it was: the exit trap removes the
        # backup just made, as it removes a temporary file.
        if [[ -n $stamp ]]; then
            _ku_deploy_track "$backup"
        fi
        "$hook"
        if [[ -n $stamp ]]; then
            _ku_deploy_forget "$backup"
        fi
    fi
    if [[ -n $stamp ]]; then
        _ku_deploy_rotate "$dir" "$name" "$backup"
    fi
    # d. Write a synced temporary file beside the target and put it in the target's place
    # (_ku_deploy_replace), then sync the filesystem, so the renames reach the disk too.
    if ! _ku_deploy_mktemp tmp "$dir" "$name" || ! _ku_deploy_copy "$source" "$tmp"; then
        _ku_deploy_discard "$tmp"
        _ku_deploy_die "$KU_EX_WRITE" 0 \
            "cannot write a temporary file beside $rel; $rel was not $(_ku_deploy_kept "$stamp")"
    fi
    _ku_deploy_sync "$tmp"
    _ku_deploy_replace "$target" "$rel" "$tmp" "$aside" "$stamp" "$expected"
    # e. Read the target back from the stick, not from the pages the write left in memory: on a
    # FAT partition 1 through a new mount, since vfat keeps what it knows of a file while the
    # mount lasts.
    if (( KU_DK_FAT_RW == 2 )) && [[ $root == "$KU_DK_ROOT" ]]; then
        _ku_deploy_fat_back "$target" "$rel" "$backup" "$expected" "$want" "$aside"
    else
        got=""
        if [[ ! -L $target && -f $target ]] && sync -f -- "$target"; then
            got=$(_ku_deploy_hash "$target") || got=""
        fi
        if [[ $got != "$want" ]]; then
            _ku_deploy_restore "$target" "$rel" "$backup" "$expected" \
                "$rel does not read back as it was written"
        fi
    fi
    # The old file, which waited aside, is in its backup too.
    if (( ${#KU_DEPLOY_ASIDE[@]} )); then
        if ! rm -f -- "$aside"; then
            ku_log warning "cannot remove ${aside##*/}, the old $rel, beside it: remove it by hand"
        fi
        KU_DEPLOY_ASIDE=()
        _ku_deploy_sync "$dir"
    fi
    ku_log info "wrote $rel${stamp:+; the old one is kept as $rel.ku-$stamp.bak}"
}

# Put the temporary file TMP in the place of TARGET, which is REL on partition 1, and, for a
# target that existed (STAMP set), held EXPECTED. A rename over a file is not safe on NTFS:
# ntfs3 unlinks the file first, and an error after that loses it while the mount still shows
# it, where no restore can reach it; and the rename may go through any mount, p1_path's
# included. So the target first moves aside to ASIDE, a free name, TMP takes the name that is
# then free, and the target goes back should that fail. KU_DEPLOY_ASIDE holds the pair from
# before the first rename on, so that the exit trap puts the target back after a signal at any
# point, and leaves it alone while its name is taken. A new file takes a free name, which ntfs3
# also renames onto whole or not at all. Exits 4 when TMP is not in place, saying what became
# of the target.
_ku_deploy_replace() {
    local target=$1 rel=$2 tmp=$3 aside=$4 stamp=$5 expected=$6 got=""
    if [[ -z $stamp ]]; then
        if mv -T -f -- "$tmp" "$target"; then
            _ku_deploy_forget "$tmp"
            _ku_deploy_sync "$target"
            return 0
        fi
        _ku_deploy_discard "$tmp"
        _ku_deploy_die "$KU_EX_WRITE" 0 \
            "cannot rename the temporary file to $rel; $rel was not created"
    fi
    KU_DEPLOY_ASIDE=("$target" "$aside")
    if ! mv -T -- "$target" "$aside"; then
        KU_DEPLOY_ASIDE=()
        _ku_deploy_discard "$tmp"
        _ku_deploy_die "$KU_EX_WRITE" 0 "cannot move $rel aside to replace it; $rel was not changed"
    fi
    _ku_deploy_sync "$aside"
    if mv -T -- "$tmp" "$target"; then
        _ku_deploy_forget "$tmp"
        _ku_deploy_sync "$target"
        return 0
    fi
    _ku_deploy_discard "$tmp"
    if mv -T -- "$aside" "$target"; then
        KU_DEPLOY_ASIDE=()
        if [[ ! -L $target && -f $target ]]; then
            got=$(_ku_deploy_hash "$target") || got=""
        fi
        if [[ $got == "$expected" ]]; then
            _ku_deploy_die "$KU_EX_WRITE" 0 \
                "cannot rename the temporary file to $rel; $rel was put back as it was"
        fi
    fi
    _ku_deploy_die "$KU_EX_WRITE" 0 "cannot rename the temporary file to $rel, and putting" \
        "$rel back failed too: copy $rel.ku-$stamp.bak to $rel by hand; the old one also waits" \
        "beside it as ${aside##*/}"
}

# Write several files to partition 1's ROOT with ku_deploy_write, in the order given as
# RELPATH SOURCE EXPECTED triples: migrate writes kali.cfg before the grub.cfg that sources
# it. First it runs the checks of every triple, so that a refusal (3), a file that changed since
# the plan read it (75) or a source that cannot be read (66) leaves the stick as it was. Then it
# writes them in turn, the first one running KU_DEPLOY_BEFORE_WRITE, and stops at
# the first failure, which exits as ku_deploy_write says while
# no file was written yet, and else exits 4, naming the files written before it, since the
# stick then changed. A RELPATH given twice is an error of the caller (1).
ku_deploy_files() {
    local root=$1 i
    local -A seen=()
    shift
    if (( $# == 0 || $# % 3 != 0 )); then
        ku_die "$KU_EX_FAILURE" "ku_deploy_files: expected RELPATH SOURCE EXPECTED triples"
    fi
    for (( i = 1; i <= $#; i += 3 )); do
        if [[ -n ${seen[${!i}]+set} ]]; then
            ku_die "$KU_EX_FAILURE" "ku_deploy_files: ${!i} is given twice"
        fi
        seen[${!i}]=1
    done
    KU_DEPLOY_DONE=()
    KU_DEPLOY_CHECKING=1
    for (( i = 1; i <= $#; i += 3 )); do
        ku_deploy_write "$root" "${@:i:3}"
    done
    KU_DEPLOY_CHECKING=0
    # A FAT partition 1 that --write-fat may write is mounted read-write only now.
    if (( KU_DK_FAT_RW == 1 && ! KU_DRY_RUN )) && [[ $root == "$KU_DK_ROOT" ]] &&
        ! ku_p1_fat_rw; then
        _ku_deploy_die "$KU_EX_REFUSED" 1 "refusing to write the FAT partition 1: $KU_DK_PROBLEM"
    fi
    while (( $# )); do
        ku_deploy_write "$root" "$1" "$2" "$3"
        if (( ! KU_DRY_RUN )); then
            KU_DEPLOY_DONE+=("$1")
        fi
        shift 3
    done
    KU_DEPLOY_DONE=()
}

# Exit as ku_die does with CODE and MESSAGE. UNCHANGED is 1 when the stick is as it was before
# this write began: the message then adds that nothing was changed. Once ku_deploy_files wrote
# earlier files, the stick changed all the same, so the exit is 4 and the message names them.
_ku_deploy_die() {
    local code=$1 unchanged=$2 msg list verb=was
    shift 2
    msg=$*
    if (( ${#KU_DEPLOY_DONE[@]} )); then
        printf -v list '%s, ' "${KU_DEPLOY_DONE[@]}"
        (( ${#KU_DEPLOY_DONE[@]} == 1 )) || verb=were
        if (( unchanged )); then
            msg+="; it was not changed"
        fi
        ku_die "$KU_EX_WRITE" "$msg, but ${list%, } $verb written before it"
    fi
    if (( unchanged )); then
        msg+="; nothing was changed"
    fi
    ku_die "$code" "$msg"
}

# Print what became of a target the write did not reach: changed, for one that had a backup
# (STAMP set), or created, for a new one.
_ku_deploy_kept() {
    if [[ -n $1 ]]; then
        printf 'changed'
    else
        printf 'created'
    fi
}

# Find out once whether dd can refuse to follow a symlink, and keep the answer in
# KU_DEPLOY_NOFOLLOW. Where it cannot, the symlink checks before each step stand alone, and the
# path that only root can change keeps other users from swapping a file in between.
_ku_deploy_probe() {
    [[ -z $KU_DEPLOY_NOFOLLOW ]] || return 0
    KU_DEPLOY_NOFOLLOW=0
    if dd if=/dev/null iflag=nofollow count=0 status=none 2> /dev/null; then
        KU_DEPLOY_NOFOLLOW=1
    fi
}

# Copy the file SOURCE to TARGET byte for byte and sync TARGET to the disk, following no
# symlink where dd can refuse to. With EXCL, TARGET must not exist yet, not even as a symlink.
# Returns 1 when that fails.
_ku_deploy_copy() {
    local -a args=("if=$1" "of=$2" bs=1M status=none "conv=fsync${3:+,excl}")
    _ku_deploy_probe
    if (( KU_DEPLOY_NOFOLLOW )); then
        args+=(iflag=nofollow oflag=nofollow)
    fi
    dd "${args[@]}" 2> /dev/null
}

# Print the SHA-256 of FILE as the stick holds it: first the kernel drops its cached pages of
# FILE, and, for a mount of partition 1, of the partition itself, from which ntfs-3g reads, so
# that the read comes from the device and not from what a write just left in memory. Both are
# best effort, and neither reaches a file small enough for NTFS to keep inside its MFT record,
# up to some hundreds of bytes, which ntfs3 answers from the record it holds in memory: for
# such a file the read checks what the write left, not the stick. Never follows a symlink.
# Returns 1 when FILE cannot be read.
_ku_deploy_hash() {
    local -a flags=()
    [[ ! -L $1 ]] || return 1
    _ku_deploy_probe
    if (( KU_DEPLOY_NOFOLLOW )); then
        flags=(iflag=nofollow)
    fi
    dd if="$1" iflag=nocache count=0 status=none 2> /dev/null || :
    if [[ -n $KU_DK_PART && -n $KU_DK_ROOT && $1 == "$KU_DK_ROOT"/* ]] &&
        [[ $KU_DK_HOW == private || $KU_DK_HOW == mount ]] && command -v blockdev > /dev/null; then
        blockdev --flushbufs "$KU_DK_PART" > /dev/null 2>&1 || :
    fi
    dd if="$1" "${flags[@]}" bs=1M status=none 2> /dev/null | ku_sha256
}

# Make a temporary file in DIR named after NAME, which the exit trap removes unless it was
# renamed or removed, and store its path in the variable named VAR. Returns 1 when mktemp
# fails.
_ku_deploy_mktemp() {
    local made
    made=$(mktemp -- "$2/.$3.ku-XXXXXXXX" 2> /dev/null) || return 1
    _ku_deploy_track "$made"
    printf -v "$1" '%s' "$made"
}

# Have the exit trap remove FILE unless it is forgotten first (_ku_deploy_forget).
_ku_deploy_track() {
    KU_DEPLOY_TMPS+=("$1")
    # The exit trap runs the cleanups registered last first, so this one goes last again
    # whenever another, such as the unmount of partition 1, came after it: the files must go
    # while the mount still holds them.
    if [[ ${KU_CLEANUP[*]: -1} != _ku_deploy_cleanup ]]; then
        ku_cleanup_add _ku_deploy_cleanup
    fi
}

# Forget the temporary file TMP, which was renamed or removed, or a file that is to stay.
_ku_deploy_forget() {
    local tmp
    local -a left=()
    for tmp in "${KU_DEPLOY_TMPS[@]}"; do
        [[ $tmp == "$1" ]] || left+=("$tmp")
    done
    KU_DEPLOY_TMPS=("${left[@]}")
}

# Remove the temporary file TMP, if there is one, and forget it once it is gone. A failure does
# not stop the caller, which is failing already; the exit trap tries again.
_ku_deploy_discard() {
    [[ -n $1 ]] || return 0
    if [[ ! -e $1 && ! -L $1 ]] || rm -f -- "$1"; then
        _ku_deploy_forget "$1"
    fi
}

# Exit trap: remove the temporary files that were neither renamed nor removed.
_ku_deploy_cleanup() {
    local tmp status=0
    # A target moved aside goes back while its name is free, as when the run was cut short
    # between the two renames; once the new file holds the name, the old one stays aside, and
    # the warning names it.
    if (( ${#KU_DEPLOY_ASIDE[@]} )); then
        if [[ ! -e ${KU_DEPLOY_ASIDE[0]} && ! -L ${KU_DEPLOY_ASIDE[0]} ]]; then
            if mv -T -- "${KU_DEPLOY_ASIDE[1]}" "${KU_DEPLOY_ASIDE[0]}"; then
                KU_DEPLOY_ASIDE=()
            else
                status=1
            fi
        else
            if [[ -e ${KU_DEPLOY_ASIDE[1]} ]]; then
                ku_log warning "the old ${KU_DEPLOY_ASIDE[0]##*/} waits beside the new one as" \
                    "${KU_DEPLOY_ASIDE[1]##*/}"
            fi
            KU_DEPLOY_ASIDE=()
        fi
    fi
    for tmp in "${KU_DEPLOY_TMPS[@]}"; do
        if [[ -e $tmp || -L $tmp ]] && ! rm -f -- "$tmp"; then
            status=1
        fi
    done
    (( status )) || KU_DEPLOY_TMPS=()
    return "$status"
}

# Keep the backup MADE of NAME in DIR and the newest others, backups_keep in all, and remove the
# older ones. The UTC stamps in the names sort by time. MADE, the backup this write just made,
# stays even when it sorts first, as after the clock went back, since a restore needs it.
_ku_deploy_rotate() {
    local dir=$1 name=$2 made=$3 i keep=${KU_CONF[backups_keep]} file
    local stamp='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z'
    local -a backups=() others=()
    # MADE is one of them.
    keep=$(( keep - 1 ))
    # shellcheck disable=SC2086 # the stamp is a glob
    mapfile -t backups < <(shopt -s nullglob; set -- "$dir/$name".ku-$stamp.bak
        (( $# == 0 )) || printf '%s\n' "$@")
    for file in "${backups[@]}"; do
        [[ $file == "$made" ]] || others+=("$file")
    done
    for (( i = 0; i < ${#others[@]} - keep; i++ )); do
        rm -f -- "${others[i]}" || ku_log warning "cannot remove the old backup ${others[i]##*/}"
    done
}

# After the write of REL to TARGET failed as WHAT says, once the new file took TARGET's place,
# put back what was there and check that it reads back as EXPECTED: the old file, which waits
# aside (KU_DEPLOY_ASIDE), takes its name back from the new one, which is unlinked first, so
# that no rename goes over a file; for a target that did not exist (BACKUP -), what the write
# left goes. Then exit 4, saying whether that worked and else naming BACKUP to copy by hand.
_ku_deploy_restore() {
    local target=$1 rel=$2 backup=$3 expected=$4 what=$5 got="" kept
    if [[ $backup == - ]]; then
        if [[ ! -e $target && ! -L $target ]] || rm -f -- "$target"; then
            _ku_deploy_die "$KU_EX_WRITE" 0 "$what; $rel did not exist before, and does not now"
        fi
        _ku_deploy_die "$KU_EX_WRITE" 0 \
            "$what, and removing $rel again failed too: remove it by hand"
    fi
    kept=$rel${backup#"$target"}
    if (( ${#KU_DEPLOY_ASIDE[@]} )) && rm -f -- "$target" &&
        mv -T -- "${KU_DEPLOY_ASIDE[1]}" "$target"; then
        KU_DEPLOY_ASIDE=()
        if [[ ! -L $target && -f $target ]] && sync -f -- "$target"; then
            got=$(_ku_deploy_hash "$target") || got=""
        fi
        if [[ $got == "$expected" ]]; then
            _ku_deploy_die "$KU_EX_WRITE" 0 "$what; $rel was restored as it was"
        fi
    fi
    _ku_deploy_die "$KU_EX_WRITE" 0 \
        "$what, and restoring it failed too: copy $kept over $rel by hand"
}

# Read TARGET, REL on a FAT partition 1 that --write-fat writes, back through a new read-only
# mount, mount it read-write again, and return 0 when it held WANT. When it did not, or could
# not be read that way, put back what was there as _ku_deploy_restore does, BACKUP being the
# backup of a target that held EXPECTED, or - for a new one. Exits 4 when partition 1 does not
# mount read-write again, saying what is left to do by hand: remove the old file, which waits
# aside as ASIDE, or put the old one back.
_ku_deploy_fat_back() {
    local target=$1 rel=$2 backup=$3 expected=$4 want=$5 aside=$6 got=""
    local what="$rel does not read back as it was written" waits=""
    if ku_p1_remount ro; then
        if [[ ! -L $target && -f $target ]]; then
            got=$(_ku_deploy_hash "$target") || got=""
        fi
    else
        what="$rel cannot be read back through a new mount: $KU_DK_PROBLEM"
    fi
    if (( ! KU_DK_WRITABLE )) && ! ku_p1_remount rw; then
        # With nothing mounted, the exit trap must not take the empty mount point for a free
        # name to move the old file back to.
        if (( ${#KU_DEPLOY_ASIDE[@]} )); then
            waits="; the old one waits beside it as ${aside##*/}"
        fi
        KU_DEPLOY_ASIDE=()
        if [[ $got == "$want" ]]; then
            _ku_deploy_die "$KU_EX_WRITE" 0 "$rel was written and reads back as written, but" \
                "partition 1 does not mount read-write again: $KU_DK_PROBLEM$waits"
        elif [[ $backup == - ]]; then
            _ku_deploy_die "$KU_EX_WRITE" 0 "$what, and partition 1 does not mount read-write" \
                "again: $KU_DK_PROBLEM; remove $rel by hand"
        fi
        _ku_deploy_die "$KU_EX_WRITE" 0 "$what, and partition 1 does not mount read-write" \
            "again: $KU_DK_PROBLEM; copy $rel${backup#"$target"} over $rel by hand$waits"
    fi
    if [[ $got != "$want" ]]; then
        _ku_deploy_restore "$target" "$rel" "$backup" "$expected" "$what"
    fi
}

# While --write-fat writes a FAT partition 1, flush the filesystem that holds PATH to the disk,
# so that what a step of a write did is on the stick before the next one starts: FAT has no
# journal, and a power loss then leaves the target as one step left it. NTFS writes as before.
# A failure does not stop the write, whose read-back finds out what reached the stick.
_ku_deploy_sync() {
    (( KU_DK_FAT_RW == 2 )) || return 0
    sync -f -- "$1" 2> /dev/null || :
}

# =======================================================
#                    THE SAFE READER
# =======================================================

# Copy RELPATH under partition 1's ROOT, as ku_deploy_resolve reached it, byte for byte into the
# local file DEST, and set KU_DEPLOY_SUM to its SHA-256, which a write of RELPATH then takes as
# EXPECTED. Follows no symlink: neither RELPATH nor a directory on its way may be one, since a
# symlink on partition 1, which Windows or an earlier mount may have made, could lead root to a
# file such as the LUKS key, whose bytes a plan would then carry onto the stick. Returns 0 once
# copied; 2 when RELPATH does not exist, which a write then expects with -, leaving DEST alone;
# and 1, with KU_DK_PROBLEM set, when RELPATH is no plain path, is or passes a symlink, is no
# regular file, or cannot be read. KU_DEPLOY_SUM is empty unless it returns 0.
# shellcheck disable=SC2034 # KU_DK_PROBLEM is disk.sh's, which the caller reads
ku_deploy_read() {
    local root=$1 rel=$2 dest=$3 path=$1 rest=$2 got
    KU_DK_PROBLEM="" KU_DEPLOY_SUM=""
    if [[ $rel == /* || /$rel/ == *//* || /$rel/ == */./* || /$rel/ == */../* ]]; then
        KU_DK_PROBLEM="$rel is no plain path inside partition 1"
        return 1
    fi
    while [[ $rest == */* ]]; do
        path+=/${rest%%/*}
        rest=${rest#*/}
        if [[ -L $path ]]; then
            KU_DK_PROBLEM="${path#"$root"/}, on the way to $rel, is a symlink"
            return 1
        elif [[ ! -e $path ]]; then
            return 2
        elif [[ ! -d $path ]]; then
            KU_DK_PROBLEM="${path#"$root"/}, on the way to $rel, is no directory"
            return 1
        fi
    done
    path=$root/$rel
    if [[ -L $path ]]; then
        KU_DK_PROBLEM="$rel is a symlink"
        return 1
    elif [[ ! -e $path ]]; then
        return 2
    elif [[ ! -f $path ]]; then
        KU_DK_PROBLEM="$rel is no regular file"
        return 1
    fi
    if ! _ku_deploy_copy "$path" "$dest" || ! got=$(ku_sha256 "$dest"); then
        KU_DK_PROBLEM="cannot read $rel"
        return 1
    fi
    KU_DEPLOY_SUM=$got
}

# =======================================================
#                       EXPORT
# =======================================================

# Export the FILEs byte for byte into DIR, which is output_dir: each through a temporary file
# renamed into place, then DEPLOY.txt with the steps that copy them to the stick from Windows,
# and last SHA256SUMS with their sums and bare names, as sha256sum -c reads them. Makes DIR,
# owned by root with mode 0700. First removes the files of the earlier export, as its
# SHA256SUMS lists them, that this one does not hold, so that no stale file is left for Windows
# to copy. Exits 78 when DIR is no directory, or is owned by another user or open to group or
# others, or a user other than root can change the path to it; 66 when a FILE cannot be read; 3
# when a FILE's name is not a plain file name or two FILEs share one; and 4 when a write fails,
# which leaves no SHA256SUMS and no DEPLOY.txt. With --dry-run it stops after the checks of the
# FILEs and of output_dir (ku_export_dir) and says what it would export.
ku_export() {
    local dir=$1 file name hash sums="" list="" steps
    local -a names=()
    local -A seen=()
    shift
    (( $# )) || ku_die "$KU_EX_FAILURE" "ku_export: no file to export"
    for file in "$@"; do
        name=${file##*/}
        if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || $name == SHA256SUMS ||
            $name == DEPLOY.txt ]]; then
            ku_die "$KU_EX_REFUSED" "refusing to export $name: no plain file name of its own;" \
                "nothing was exported"
        fi
        if [[ -n ${seen[$name]+set} ]]; then
            ku_die "$KU_EX_REFUSED" "refusing to export two files named $name; nothing was" \
                "exported"
        fi
        seen[$name]=1
        names+=("$name")
        # A symlink is refused here, before the earlier export goes, since the copy follows none.
        if [[ -L $file || ! -f $file || ! -r $file ]]; then
            ku_die "$KU_EX_NOINPUT" "cannot read $name to export it; nothing was exported"
        fi
    done
    ku_export_dir "$dir"
    if (( KU_DRY_RUN )); then
        ku_log info "would export $# file(s) to $dir"
        return 0
    fi
    if ! _ku_export_clear "$dir" "${names[@]}"; then
        ku_die "$KU_EX_WRITE" "cannot remove the files of the earlier export in output_dir;" \
            "nothing was exported"
    fi
    # A partial export must not pass for a whole one, nor be copied as the old DEPLOY.txt says,
    # so the old sums and steps go first.
    if ! rm -f -- "$dir/SHA256SUMS" "$dir/DEPLOY.txt"; then
        ku_die "$KU_EX_WRITE" "cannot remove the old SHA256SUMS and DEPLOY.txt in output_dir;" \
            "nothing was exported"
    fi
    for file in "$@"; do
        name=${file##*/}
        hash=$(ku_sha256 "$file") || ku_die "$KU_EX_NOINPUT" "cannot read $name to export it"
        _ku_export_put "$dir" "$name" "$file"
        sums+="$hash  $name"$'\n'
        list+="     $name"$'\n'
    done
    printf -v steps '%s\n' "kernel-updater export" "" \
        "These files are for the stick's partition 1, the FAT or NTFS partition labelled BOOT," \
        "which kernel-updater does not write itself here. To deploy them:" "" \
        "1. In Windows, copy them, in this order, into $KU_DEPLOY_WINDOWS_DIR on the stick," \
        "   replacing the files of the same name there:" "" "$list" \
        "2. Let Windows finish writing to the stick before you boot from it." \
        "3. In Kali, run '$KU_CMD check' to confirm: its deployed item is ok once" \
        "   the files on the stick match SHA256SUMS here." "" \
        "'sha256sum -c SHA256SUMS' checks the files in this directory."
    _ku_export_text "$dir" DEPLOY.txt "$steps"
    _ku_export_text "$dir" SHA256SUMS "$sums"
    ku_log info "exported $# file(s) to $dir: copy them to the stick from Windows as" \
        "DEPLOY.txt there says, then run '$KU_CMD check'"
}

# Make the output_dir DIR when it is missing, owned by root with mode 0700, and exit as
# _ku_export_check_dir does unless it passes; 4 when it cannot be made. A dry run makes
# nothing: it checks DIR when it exists, and else the path to the directory it would be made
# in. ku_export calls it before anything else changes, and migrate before it seals the backup
# of a stage that exports, so that an output_dir that cannot serve stops the run, and its dry
# run, before there is a backup a rollback would undo.
ku_export_dir() {
    local dir=$1 up
    if [[ -e $dir || -L $dir ]]; then
        _ku_export_check_dir "$dir"
    elif (( KU_DRY_RUN )); then
        up=${dir%/*}
        while [[ -n $up && ! -e $up && ! -L $up ]]; do
            up=${up%/*}
        done
        if ! ku_p1_root_only "${up:-/}"; then
            ku_die "$KU_EX_CONFIG" "the path to output_dir $dir holds a symlink, or a" \
                "directory a user other than root can change, so what root writes there could" \
                "land elsewhere: name a path of root's without symlinks; nothing was exported"
        fi
    else
        if ! mkdir -p -- "${dir%/*}/" || ! (umask 077 && mkdir -- "$dir"); then
            ku_die "$KU_EX_WRITE" "cannot make output_dir $dir; nothing was exported"
        fi
        _ku_export_check_dir "$dir"
    fi
}

# Exit 78 unless DIR is a directory, not a symlink, owned by root and closed to group and
# others, since what it holds goes onto the stick, and unless the path to it holds no symlink
# and no directory a user other than root can change (ku_p1_root_only), since such a user might
# swap DIR for a symlink between these checks and root's writes and removals there.
_ku_export_check_dir() {
    local info owner mode
    if [[ -L $1 || ! -d $1 ]]; then
        ku_die "$KU_EX_CONFIG" "output_dir $1 is no directory; nothing was exported"
    fi
    info=$(stat -L -c '%u %a' -- "$1" 2> /dev/null) ||
        ku_die "$KU_EX_CONFIG" "cannot stat output_dir $1; nothing was exported"
    read -r owner mode <<< "$info"
    if [[ $owner != 0 || ! $mode =~ ^[0-7]+$ ]] || (( (8#$mode & 8#077) != 0 )); then
        ku_die "$KU_EX_CONFIG" "output_dir $1 must be owned by root and closed to group and" \
            "others (mode 0700); nothing was exported"
    fi
    if ! ku_p1_root_only "$1"; then
        ku_die "$KU_EX_CONFIG" "the path to output_dir $1 holds a symlink, or a directory a" \
            "user other than root can change, so what root writes there could land elsewhere:" \
            "name a path of root's without symlinks; nothing was exported"
    fi
}

# Remove from DIR the files that its SHA256SUMS, the earlier export's, lists and that the new
# export of the NAMEs does not hold. Only regular files of plain names go, never anything else
# in DIR; lines that are no sums are passed over. Returns 1 when a file cannot be removed.
_ku_export_clear() {
    local dir=$1 line name
    local -A keep=()
    shift
    for name in "$@"; do
        keep[$name]=1
    done
    [[ -f $dir/SHA256SUMS && ! -L $dir/SHA256SUMS ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[0-9a-f]{64}\ [\ *]([A-Za-z0-9][A-Za-z0-9._+-]*)$ ]] || continue
        name=${BASH_REMATCH[1]}
        if [[ -z ${keep[$name]+set} && $name != SHA256SUMS && $name != DEPLOY.txt &&
            -f $dir/$name && ! -L $dir/$name ]]; then
            rm -f -- "$dir/$name" || return 1
        fi
    done < "$dir/SHA256SUMS"
}

# Copy the file SOURCE into DIR as NAME, byte for byte, through a temporary file renamed into
# place. Exits 4 when that fails, leaving no temporary file.
_ku_export_put() {
    local dir=$1 name=$2 tmp=""
    if _ku_deploy_mktemp tmp "$dir" "$name" && _ku_deploy_copy "$3" "$tmp" &&
        mv -T -f -- "$tmp" "$dir/$name"; then
        _ku_deploy_forget "$tmp"
        return 0
    fi
    _ku_deploy_discard "$tmp"
    ku_die "$KU_EX_WRITE" "cannot write $name in output_dir $dir; it holds no complete" \
        "export now, so run the export again"
}

# Write TEXT into DIR as NAME through a temporary file renamed into place. Exits 4 when that
# fails, leaving no temporary file.
_ku_export_text() {
    local dir=$1 name=$2 tmp=""
    if _ku_deploy_mktemp tmp "$dir" "$name" && printf '%s' "$3" > "$tmp" &&
        mv -T -f -- "$tmp" "$dir/$name"; then
        _ku_deploy_forget "$tmp"
        return 0
    fi
    _ku_deploy_discard "$tmp"
    ku_die "$KU_EX_WRITE" "cannot write $name in output_dir $dir; it holds no complete" \
        "export now, so run the export again"
}

# Compare multibootusb/grub/NAME under partition 1's ROOT with each NAME output_dir's
# SHA256SUMS lists, and print NAME<TAB>same, differs or missing per file. Returns 0 when each
# is the same, 2 when one differs or is missing, 1 when SHA256SUMS is damaged or lists nothing,
# and 66 when output_dir holds none.
ku_export_verify() {
    local root=$1 sums line hash name file got out="" status=0
    sums=$(ku_path "${KU_CONF[output_dir]}")/SHA256SUMS
    [[ -e $sums ]] || return 66
    [[ -f $sums && -r $sums ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([0-9a-f]{64})\ [\ *]([A-Za-z0-9][A-Za-z0-9._+-]*)$ ]] || return 1
        hash=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
        file=$root/multibootusb/grub/$name
        if [[ ! -e $file && ! -L $file ]]; then
            out+=$name$'\t'missing$'\n'
            status=2
        elif ku_p1_no_symlink "$root" "multibootusb/grub/$name" && [[ -f $file ]] &&
            got=$(ku_sha256 "$file") && [[ $got == "$hash" ]]; then
            out+=$name$'\t'same$'\n'
        else
            out+=$name$'\t'differs$'\n'
            status=2
        fi
    done < "$sums"
    [[ -n $out ]] || return 1
    printf '%s' "$out"
    return "$status"
}
