#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater safe writer and export checks
#
# Runs ku_deploy_write, ku_deploy_files, ku_deploy_read, ku_export and ku_export_verify as a
# command runs them, on a partition-1 tree in the test's temp directory: the hash check,
# symlinks, a path other users can change, backups and their rotation, also after the clock
# went back, the old file moved aside rather than renamed over, a temporary file that cannot be
# written and a rename that fails, which leave the target as it was, a bad read-back and a run
# cut short, which put the old file back, CRLF kept byte for byte, new files, the checks of
# every file before the first is written, the reader, and the export with its sums, its steps
# and its directory.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

# A partition-1 tree with MultiBootUSB's grub.cfg, which has CRLF line endings, and a new
# grub.cfg and kali.cfg to write; backups_keep is 2. Each date call gives the next UTC stamp.
setup() {
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    P1="$BATS_TEST_TMPDIR/p1"
    GRUB="$P1/multibootusb/grub"
    OUT="$ROOT/root/kernel-updater/out"
    REL=multibootusb/grub/grub.cfg
    mkdir -p "$ROOT/etc" "$GRUB"
    printf 'backups_keep = 2\n' > "$ROOT/etc/kernel-updater.conf"
    printf 'menuentry "Kali" {\r\n\tconfigfile /multibootusb/grub/kali.cfg\r\n}\r\n' \
        > "$GRUB/grub.cfg"
    cp "$GRUB/grub.cfg" "$BATS_TEST_TMPDIR/old.cfg"
    OLD=$(sha256 "$GRUB/grub.cfg")
    printf 'menuentry "Kali (links)" {\r\n\tlinux /vmlinuz\r\n\tinitrd /initrd.img\r\n}\r\n' \
        > "$BATS_TEST_TMPDIR/grub.cfg"
    printf 'menuentry "Kali" {\n\tlinux /vmlinuz root=/dev/mapper/kali--vg-root ro\n}\n' \
        > "$BATS_TEST_TMPDIR/kali.cfg"
    mkstub id <<< 'echo 1000'
    export DATE_COUNT="$BATS_TEST_TMPDIR/date.count"
    printf '0\n' > "$DATE_COUNT"
    mkstub date <<'EOF'
n=$(( $(< "$DATE_COUNT") + 1 ))
printf '%s\n' "$n" > "$DATE_COUNT"
printf '20261110T1200%02dZ\n' "$n"
EOF
    # Root owns output_dir, and every directory on the way to partition 1's files, with the
    # mode OUT_STAT gives.
    export OUT_STAT="0 700"
    # shellcheck disable=SC2016 # the stub expands the variable when it runs
    mkstub stat <<< 'echo "$OUT_STAT"'
    export REAL_MV REAL_DD MV_DONE="$BATS_TEST_TMPDIR/mv.done"
    REAL_MV=$(command -v mv)
    REAL_DD=$(command -v dd)
}

# Print the SHA-256 of FILE.
sha256() {
    sha256sum < "$1" | cut -c 1-64
}

# Write the local file SOURCE over grub.cfg on partition 1 as the plan that read EXPECTED does,
# through ku_deploy_write and bats' run.
write_grub() {
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_write "$@"' "$P1" "$REL" "$1" "$2"
}

# Fail unless grub.cfg holds what it held before the test, and no temporary file is left.
grub_unchanged() {
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg"
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
}

# Print the names of grub.cfg's backups, oldest first.
backups() {
    (cd "$GRUB" && find . -maxdepth 1 -name 'grub.cfg.ku-*.bak' | sed 's#^\./##' | sort)
}

# Run ku_deploy_files on partition 1 with the TRIPLES given, after --dry-run when that comes
# first, and with a hook that logs to HOOK_LOG what partition 1 holds when it runs: grub.cfg's
# backups, temporary files and whether kali.cfg exists. With CHANGE_AT above 0, the read of
# grub.cfg's hash of that number appends an x to it, as a program writing the stick then would:
# 1 is the check of every file before the first write, 2 the check that write makes itself.
# With HOOK_FAILS set, the hook exits 4 once it logged.
run_hooked() {
    export CHANGE_AT=$1 HOOK_LOG="$BATS_TEST_TMPDIR/hook.log" GRUB
    export HASH_COUNT="$BATS_TEST_TMPDIR/hash.count" HOOK_FAILS=${HOOK_FAILS:-}
    shift
    : > "$HOOK_LOG"
    printf '0\n' > "$HASH_COUNT"
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib '
        eval "_ku_real_hash() $(declare -f _ku_deploy_hash | tail -n +2)"
        _ku_deploy_hash() {
            local n
            _ku_real_hash "$@" || return 1
            [[ $1 == */grub.cfg ]] || return 0
            n=$(( $(< "$HASH_COUNT") + 1 ))
            printf "%s\n" "$n" > "$HASH_COUNT"
            (( n != CHANGE_AT )) || printf x >> "$1"
        }
        hook() {
            local backups temps kali=0
            backups=$(find "$GRUB" -maxdepth 1 -name "grub.cfg.ku-*.bak" | wc -l)
            temps=$(find "$GRUB" -maxdepth 1 -name ".*.ku-*" | wc -l)
            [[ ! -e $GRUB/kali.cfg ]] || kali=1
            printf "hook: backups %s, temporary files %s, kali.cfg %s\n" "$backups" "$temps" \
                "$kali" >> "$HOOK_LOG"
            [[ -z ${HOOK_FAILS:-} ]] || ku_die "$KU_EX_WRITE" "the hook failed"
        }
        if [[ ${2:-} == --dry-run ]]; then
            KU_DRY_RUN=1
            set -- "$1" "${@:3}"
        fi
        KU_DEPLOY_BEFORE_WRITE=hook
        ku_deploy_files "$@"' "$P1" "$@"
}

@test "A write replaces the target byte for byte, CRLF and all, and keeps a backup beside it" {
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$GRUB/grub.cfg"
    [ "$(backups)" = grub.cfg.ku-20261110T120001Z.bak ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg.ku-20261110T120001Z.bak"
    [[ "$stderr" == *"info: wrote $REL; the old one is kept as $REL.ku-20261110T120001Z.bak"* ]]
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
    # Each CRLF of the source reached the stick.
    [ "$(grep -c $'\r$' "$GRUB/grub.cfg")" -eq 4 ]
}

@test "Backups rotate to the newest backups_keep, and other files' backups stay" {
    local i hash
    : > "$GRUB/win.cfg.ku-20261109T000000Z.bak"
    : > "$GRUB/grub.cfg.ku-notes.bak"
    for i in 1 2 3; do
        printf 'menuentry "v%s" {\r\n}\r\n' "$i" > "$BATS_TEST_TMPDIR/v$i.cfg"
        hash=$(sha256 "$GRUB/grub.cfg")
        write_grub "$BATS_TEST_TMPDIR/v$i.cfg" "$hash"
        [ "$status" -eq 0 ]
    done
    cmp "$BATS_TEST_TMPDIR/v3.cfg" "$GRUB/grub.cfg"
    # The first backup went; one whose name holds no stamp is no backup of the writer's.
    [ "$(backups)" = "$(printf 'grub.cfg.ku-%s.bak\n' 20261110T120002Z 20261110T120003Z notes)" ]
    cmp "$BATS_TEST_TMPDIR/v1.cfg" "$GRUB/grub.cfg.ku-20261110T120002Z.bak"
    cmp "$BATS_TEST_TMPDIR/v2.cfg" "$GRUB/grub.cfg.ku-20261110T120003Z.bak"
    [ -e "$GRUB/win.cfg.ku-20261109T000000Z.bak" ]
}

@test "The backup a write makes stays, though backups from a clock that ran ahead sort later" {
    # Two earlier writes stamped their backups while the clock was ahead, and the read-back of
    # this write goes wrong, after which its own backup must still be there.
    printf 'menuentry "ahead %s" {\r\n}\r\n' 0 > "$GRUB/grub.cfg.ku-20991231T000000Z.bak"
    printf 'menuentry "ahead %s" {\r\n}\r\n' 1 > "$GRUB/grub.cfg.ku-20991231T000001Z.bak"
    mkstub mv <<'EOF'
"$REAL_MV" "$@" || exit
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    printf 'x' >> "${*: -1}"
fi
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"does not read back as it was written; $REL was restored as it was"* ]]
    grub_unchanged
    # backups_keep is 2: this write's backup and the newest other one.
    [ "$(backups)" = "$(printf 'grub.cfg.ku-%s.bak\n' 20261110T120001Z 20991231T000001Z)" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg.ku-20261110T120001Z.bak"
    # A write that goes through keeps its backup too, and says so truly.
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"the old one is kept as $REL.ku-20261110T120002Z.bak"* ]]
    [ "$(backups)" = "$(printf 'grub.cfg.ku-%s.bak\n' 20261110T120002Z 20991231T000001Z)" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg.ku-20261110T120002Z.bak"
}

@test "A target changed or appeared since the plan read it exits 75, others 3; nothing changes" {
    # A run that plans anew can succeed, so the exit is 75, as for a change while a question
    # waits.
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$(sha256 "$BATS_TEST_TMPDIR/kali.cfg")"
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"error: refusing to write $REL: it changed since the plan read it;"* ]]
    [[ "$stderr" == *"nothing was changed"* ]]
    grub_unchanged
    [ -z "$(backups)" ]
    # A file that appeared where the plan read none changed since the plan read it too.
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" -
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"refusing to write $REL: it exists, but the plan expected none;"* ]]
    grub_unchanged
    # A plan without a SHA-256, and a path that leaves partition 1.
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "${OLD:0:63}"
    [ "$status" -eq 3 ]
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_write "$@"' "$P1" multibootusb/../grub.cfg \
        "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"it is no plain path inside partition 1"* ]]
    grub_unchanged
    [ -z "$(backups)" ]
    # A source that cannot be read.
    write_grub "$BATS_TEST_TMPDIR/none.cfg" "$OLD"
    [ "$status" -eq 66 ]
    grub_unchanged
}

@test "A symlink as the target or as a directory on its way is refused with exit 3" {
    use_symlinks || skip "this platform cannot make symlinks"
    # The link reaches the same bytes, so only the symlink check can refuse it.
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere/grub"
    mv "$GRUB/grub.cfg" "$BATS_TEST_TMPDIR/elsewhere/grub/grub.cfg"
    ln -s ../../../elsewhere/grub/grub.cfg "$GRUB/grub.cfg"
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"refusing to write $REL: it is a symlink; nothing was changed"* ]]
    [ -L "$GRUB/grub.cfg" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$BATS_TEST_TMPDIR/elsewhere/grub/grub.cfg"
    # multibootusb itself leads elsewhere.
    rm "$GRUB/grub.cfg"
    rmdir "$GRUB" "$P1/multibootusb"
    ln -s ../elsewhere "$P1/multibootusb"
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"refusing to write $REL: multibootusb is a symlink or no directory;"* ]]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$BATS_TEST_TMPDIR/elsewhere/grub/grub.cfg"
    [ -z "$(find "$BATS_TEST_TMPDIR/elsewhere" -name '*.ku-*')" ]
}

@test "A target that is a symlink after the rename is not read through, and is restored" {
    use_symlinks || skip "this platform cannot make symlinks"
    # Right after the rename the new file turns into a symlink to the same bytes, which a
    # read-back through the link would take for the file.
    mkstub mv <<'EOF'
"$REAL_MV" "$@" || exit
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    cp "${*: -1}" "$MV_DONE.copy"
    rm "${*: -1}"
    ln -s "$MV_DONE.copy" "${*: -1}"
fi
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: $REL does not read back as it was written; $REL was restored"* ]]
    [ ! -L "$GRUB/grub.cfg" ]
    grub_unchanged
}

@test "Temporary files go before an unmount registered after them takes them out of reach" {
    # The exit trap runs the cleanups registered last first.
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib '_ku_deploy_mktemp one "$1" a.cfg; ku_cleanup_add _ku_p1_cleanup
        _ku_deploy_mktemp two "$1" b.cfg; printf "%s\n" "${KU_CLEANUP[@]}"' "$GRUB"
    [ "$status" -eq 0 ]
    [ "$output" = $'_ku_deploy_cleanup\n_ku_p1_cleanup\n_ku_deploy_cleanup' ]
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
}

@test "A path to the target that other users can change is refused with exit 3" {
    # A user owns the directories, as on a desktop's mount of partition 1 for its user.
    export OUT_STAT="1000 755"
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"refusing to write $REL: users other than root can change the directories"* ]]
    grub_unchanged
    [ -z "$(backups)" ]
    # KU_P1_DIR stands in for partition 1's private mount, which only root can reach.
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'KU_P1_DIR=$1; ku_deploy_write "$@"' "$P1" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" \
        "$OLD"
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$GRUB/grub.cfg"
}

@test "A temporary file that cannot be written exits 4 and leaves the target as it was" {
    # dd fails to write the temporary file, as on a full stick.
    mkstub dd <<'EOF'
for arg; do
    [[ $arg != of=*/.grub.cfg.ku-* ]] || exit 1
done
exec "$REAL_DD" "$@"
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: cannot write a temporary file beside $REL; $REL was not changed"* ]]
    [[ "$stderr" != *restor* ]]
    grub_unchanged
}

@test "The old file moves aside before the new one takes its name, and goes once that worked" {
    # ntfs3 unlinks a file that a rename replaces before it renames, and an error after that
    # loses it, so the writer never renames over one: each rename takes a free name.
    local renames='s#\.ku-[A-Za-z0-9]{8}( |$)#.ku-X\1#g; s#[^ ]*/##g'
    # shellcheck disable=SC2016 # the stub expands its own variables
    mkstub mv <<< 'exec "$REAL_MV" "$@"'
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 0 ]
    [ "$(grep '^mv ' "$STUB_LOG" | sed -E "$renames")" = \
        $'mv -T -- grub.cfg .grub.cfg.ku-20261110T120001Z.old\nmv -T -- .grub.cfg.ku-X grub.cfg' ]
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$GRUB/grub.cfg"
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
    # Through p1_path too, which may be a mount of partition 1 as well as a host's share.
    cp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg"
    : > "$STUB_LOG"
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'KU_DK_HOW=path; ku_deploy_write "$@"' "$P1" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" \
        "$OLD"
    [ "$status" -eq 0 ]
    [ "$(grep '^mv ' "$STUB_LOG" | sed -E "$renames")" = \
        $'mv -T -- grub.cfg .grub.cfg.ku-20261110T120002Z.old\nmv -T -- .grub.cfg.ku-X grub.cfg' ]
    # A new file takes a free name with one rename.
    : > "$STUB_LOG"
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_write "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" -
    [ "$status" -eq 0 ]
    [ "$(grep '^mv ' "$STUB_LOG" | sed -E "$renames")" = "mv -T -f -- .kali.cfg.ku-X kali.cfg" ]
}

@test "A rename that fails puts the old file back and exits 4, leaving no temporary file" {
    # The rename of the new file into the free name fails, once.
    mkstub mv <<'EOF'
if [[ ${*: -1} == */*.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: cannot rename the temporary file to $REL; $REL was put back as it \
was"* ]]
    grub_unchanged
    [ "$(grep -c '^mv ' "$STUB_LOG")" -eq 3 ]
    [ "$(backups)" = grub.cfg.ku-20261110T120001Z.bak ]
    # A new file is not created.
    rm "$MV_DONE"
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_write "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" -
    [ "$status" -eq 4 ]
    [[ "$stderr" == *" to multibootusb/grub/kali.cfg; multibootusb/grub/kali.cfg was not created"* ]]
    [ ! -e "$GRUB/kali.cfg" ]
    # When moving it back fails too, the message names the backup to copy by hand.
    mkstub mv <<'EOF'
[[ ${*: -1} != */grub.cfg ]] || exit 1
exec "$REAL_MV" "$@"
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"and putting $REL back failed too: copy $REL.ku-20261110T120002Z.bak to \
$REL by hand"* ]]
    # The exit trap, which tries again, finds no other way either; the old file waits aside.
    [ -e "$GRUB/.grub.cfg.ku-20261110T120002Z.old" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg.ku-20261110T120002Z.bak"
    [ -z "$(find "$P1" -name '.*.ku-*' ! -name '*.old')" ]
}

@test "A run cut short between the two renames puts the old file back in its exit trap" {
    # A TERM arrives while the new file is to take the free name, which it then does not.
    mkstub mv <<'EOF'
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    kill -TERM "$PPID"
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 143 ]
    grub_unchanged
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
    # A TERM that arrives while the old file moves aside, which it then does.
    rm "$MV_DONE"
    mkstub mv <<'EOF'
"$REAL_MV" "$@" || exit
if [[ ${*: -1} == */.grub.cfg.ku-*.old && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    kill -TERM "$PPID"
fi
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 143 ]
    grub_unchanged
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
    # In a subshell, which runs no exit trap, the temporary files go all the same.
    rm "$MV_DONE" "$GRUB"/grub.cfg.ku-*.bak
    mkstub mv <<'EOF'
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib '( ku_deploy_write "$@" ) || printf "%s\n" "$?"' "$P1" "$REL" \
        "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 0 ]
    [ "$output" = 4 ]
    grub_unchanged
}

@test "A run cut short after the new file took the name leaves it, and names the old one aside" {
    # A TERM arrives during the sync before the read-back.
    export REAL_SYNC SYNC_DONE="$BATS_TEST_TMPDIR/sync.done"
    REAL_SYNC=$(command -v sync)
    mkstub sync <<'EOF'
if [[ ! -e $SYNC_DONE ]]; then
    : > "$SYNC_DONE"
    kill -TERM "$PPID"
fi
exec "$REAL_SYNC" "$@"
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 143 ]
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$GRUB/grub.cfg"
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/.grub.cfg.ku-20261110T120001Z.old"
    [[ "$stderr" == *"warning: the old grub.cfg waits beside the new one as \
.grub.cfg.ku-20261110T120001Z.old"* ]]
}

@test "A read-back that differs puts the old file back and exits 4" {
    # The new file takes the name, then a byte goes wrong on the way to the stick.
    mkstub mv <<'EOF'
"$REAL_MV" "$@" || exit
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    printf 'x' >> "${*: -1}"
fi
EOF
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: $REL does not read back as it was written; $REL was restored"* ]]
    grub_unchanged
    [ "$(backups)" = grub.cfg.ku-20261110T120001Z.bak ]
}

@test "A file the plan expected to be new is written without a backup, and removed on failure" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_write "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" -
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    [[ "$stderr" == *"info: wrote multibootusb/grub/kali.cfg"* && "$stderr" != *kept* ]]
    [ -z "$(find "$P1" -name '*.ku-*')" ]
    rm "$GRUB/kali.cfg"
    mkstub mv <<'EOF'
"$REAL_MV" "$@" || exit
printf 'x' >> "${*: -1}"
EOF
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_write "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" -
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"multibootusb/grub/kali.cfg did not exist before, and does not now"* ]]
    [ ! -e "$GRUB/kali.cfg" ]
    [ -z "$(find "$P1" -name '*.ku-*')" ]
}

@test "ku_deploy_files writes in the order given and checks every file before the first" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local files='ku_deploy_files "$@"'
    local kali=(multibootusb/grub/kali.cfg "$BATS_TEST_TMPDIR/kali.cfg" -)
    run_ku_lib "$files" "$P1" "${kali[@]}" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$GRUB/grub.cfg"
    [[ "$stderr" == *"info: wrote multibootusb/grub/kali.cfg"*"info: wrote $REL"* ]]
    rm "$GRUB/kali.cfg" "$GRUB"/grub.cfg.ku-*.bak
    cp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg"
    # The second file changed since the plan read it (75), or its source cannot be read (66):
    # refused before the first is written, so nothing changed.
    run_ku_lib "$files" "$P1" "${kali[@]}" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "${OLD//?/0}"
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"error: refusing to write $REL: it changed since the plan read it; nothing"* ]]
    run_ku_lib "$files" "$P1" "${kali[@]}" "$REL" "$BATS_TEST_TMPDIR/none.cfg" "$OLD"
    [ "$status" -eq 66 ]
    [[ "$stderr" != *"info: wrote"* ]]
    [ ! -e "$GRUB/kali.cfg" ]
    grub_unchanged
    [ -z "$(backups)" ]
    # A path given twice, and arguments that are no triples, are errors of the caller.
    run_ku_lib "$files" "$P1" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD" "$REL" \
        "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 1 ]
    run_ku_lib "$files" "$P1" "$REL" "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 1 ]
    grub_unchanged
}

@test "A failure after ku_deploy_files wrote a file exits 4 and names what it wrote" {
    # kali.cfg goes through; the rename of the new grub.cfg into its name fails, once.
    mkstub mv <<'EOF'
if [[ ${*: -1} == */grub.cfg && ! -e $MV_DONE ]]; then
    : > "$MV_DONE"
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_files "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" - "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    grub_unchanged
    [[ "$stderr" == *"error: cannot rename the temporary file to $REL; $REL was put back as it \
was, but multibootusb/grub/kali.cfg was written before it"* ]]
    # A refusal that comes only now, as a backup name taken within the same second, says the
    # stick changed too, and exits 4 instead of 3.
    rm "$GRUB/kali.cfg"
    : > "$GRUB/grub.cfg.ku-20261110T120002Z.bak"
    mkstub mv <<'EOF'
exec "$REAL_MV" "$@"
EOF
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_files "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" - "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"exists already, so try again in a second; it was not changed, but \
multibootusb/grub/kali.cfg was written before it"* ]]
    grub_unchanged
    # So does a grub.cfg that changes while kali.cfg is written: 4, not 75, as the stick changed.
    rm "$GRUB/kali.cfg"
    mkstub mv <<'EOF'
"$REAL_MV" "$@" || exit
target=${*: -1}
[[ $target != */kali.cfg ]] || printf 'x' >> "${target%/*}/grub.cfg"
EOF
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_files "$@"' "$P1" multibootusb/grub/kali.cfg \
        "$BATS_TEST_TMPDIR/kali.cfg" - "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"error: refusing to write $REL: it changed since the plan read it; it was \
not changed, but multibootusb/grub/kali.cfg was written before it"* ]]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    cmp <(cat "$BATS_TEST_TMPDIR/old.cfg"; printf 'x') "$GRUB/grub.cfg"
    # No backup of grub.cfg was made for it, and no temporary file is left.
    [ "$(backups)" = "$(printf 'grub.cfg.ku-%s.bak\n' 20261110T120001Z 20261110T120002Z)" ]
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
}

@test "Loading the libraries sets no hook for the writer" {
    # shellcheck disable=SC2016 # the code expands its own variables
    run_ku_lib 'printf "[%s]\n" "$KU_DEPLOY_BEFORE_WRITE"'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "A target that changes after the checks of ku_deploy_files exits 75, and the hook never ran" {
    run_hooked 1 "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"refusing to write $REL: it changed since the plan read it; nothing"* ]]
    [ ! -s "$HOOK_LOG" ]
    [ -z "$(backups)" ]
    cmp <(cat "$BATS_TEST_TMPDIR/old.cfg"; printf 'x') "$GRUB/grub.cfg"
}

@test "A target that changes just before its backup exits 4, and the hook never ran" {
    run_hooked 2 "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"cannot back up $REL; nothing was changed"* ]]
    [ ! -s "$HOOK_LOG" ]
    [ -z "$(backups)" ]
    cmp <(cat "$BATS_TEST_TMPDIR/old.cfg"; printf 'x') "$GRUB/grub.cfg"
}

@test "The hook runs once, after the first file's backup, before its temporary file and rotation" {
    local kali=(multibootusb/grub/kali.cfg "$BATS_TEST_TMPDIR/kali.cfg" -)
    : > "$GRUB/grub.cfg.ku-20261101T000000Z.bak"
    : > "$GRUB/grub.cfg.ku-20261101T000001Z.bak"
    # grub.cfg first: its backup is made, the two older ones not yet rotated, nothing else written.
    run_hooked 0 "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD" "${kali[@]}"
    [ "$status" -eq 0 ]
    [ "$(< "$HOOK_LOG")" = "hook: backups 3, temporary files 0, kali.cfg 0" ]
    [ "$(backups)" = "$(printf 'grub.cfg.ku-%s.bak\n' 20261101T000001Z 20261110T120001Z)" ]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$GRUB/kali.cfg"
    # A new file first: the hook runs before its temporary file, and once.
    rm "$GRUB/kali.cfg" "$GRUB"/grub.cfg.ku-*.bak
    cp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg"
    run_hooked 0 "${kali[@]}" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 0 ]
    [ "$(< "$HOOK_LOG")" = "hook: backups 0, temporary files 0, kali.cfg 0" ]
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$GRUB/grub.cfg"
    # A dry run runs no hook.
    run_hooked 0 --dry-run "$REL" "$BATS_TEST_TMPDIR/kali.cfg" "$(sha256 "$GRUB/grub.cfg")"
    [ "$status" -eq 0 ]
    [ ! -s "$HOOK_LOG" ]
}

@test "A hook that stops the run leaves no backup beside the target, and changes nothing" {
    : > "$GRUB/grub.cfg.ku-20261101T000000Z.bak"
    HOOK_FAILS=1 run_hooked 0 "$REL" "$BATS_TEST_TMPDIR/grub.cfg" "$OLD"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"the hook failed"* ]]
    [ "$(< "$HOOK_LOG")" = "hook: backups 2, temporary files 0, kali.cfg 0" ]
    [ "$(backups)" = grub.cfg.ku-20261101T000000Z.bak ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$GRUB/grub.cfg"
    [ -z "$(find "$P1" -name '.*.ku-*')" ]
}

@test "A source or an export file that is a symlink exits 66 before anything changes" {
    use_symlinks || skip "this platform cannot make symlinks"
    ln -s grub.cfg "$BATS_TEST_TMPDIR/link.cfg"
    write_grub "$BATS_TEST_TMPDIR/link.cfg" "$OLD"
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"error: cannot read the new contents of $REL; nothing was changed"* ]]
    grub_unchanged
    [ -z "$(backups)" ]
    # An earlier export stays whole when the next one names a symlink.
    # shellcheck disable=SC2016 # the code expands its own arguments
    local code='ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"'
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 0 ]
    cp "$OUT/SHA256SUMS" "$BATS_TEST_TMPDIR/sums.before"
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/link.cfg"
    [ "$status" -eq 66 ]
    [[ "$stderr" == *"error: cannot read link.cfg to export it; nothing was exported"* ]]
    cmp "$BATS_TEST_TMPDIR/sums.before" "$OUT/SHA256SUMS"
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$OUT/grub.cfg"
}

@test "ku_deploy_read copies a file byte for byte and gives the SHA-256 a write expects" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local read='ku_deploy_read "$@"; printf "%s\n" "$KU_DEPLOY_SUM"'
    # shellcheck disable=SC2016 # the code expands its own arguments
    local fail='ku_deploy_read "$@" || { code=$?; printf "%s|%s\n" "$KU_DK_PROBLEM" \
        "$KU_DEPLOY_SUM"; exit "$code"; }'
    run_ku_lib "$read" "$P1" "$REL" "$BATS_TEST_TMPDIR/copy.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "$OLD" ]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$BATS_TEST_TMPDIR/copy.cfg"
    # A write takes that SHA-256 as what the plan read.
    write_grub "$BATS_TEST_TMPDIR/grub.cfg" "$output"
    [ "$status" -eq 0 ]
    # A file or a directory that does not exist gives 2 and copies nothing.
    run_ku_lib "$fail" "$P1" multibootusb/grub/kali.cfg "$BATS_TEST_TMPDIR/none.cfg"
    [ "$status" -eq 2 ]
    run_ku_lib "$fail" "$P1" boot/grub/config.cfg "$BATS_TEST_TMPDIR/none.cfg"
    [ "$status" -eq 2 ]
    [ ! -e "$BATS_TEST_TMPDIR/none.cfg" ]
    # No plain path, and a directory where the file should be.
    run_ku_lib "$fail" "$P1" multibootusb/../grub.cfg "$BATS_TEST_TMPDIR/none.cfg"
    [ "$status" -eq 1 ]
    [ "$output" = "multibootusb/../grub.cfg is no plain path inside partition 1|" ]
    mkdir "$GRUB/dir.cfg"
    run_ku_lib "$fail" "$P1" multibootusb/grub/dir.cfg "$BATS_TEST_TMPDIR/none.cfg"
    [ "$status" -eq 1 ]
    [ "$output" = "multibootusb/grub/dir.cfg is no regular file|" ]
    [ ! -e "$BATS_TEST_TMPDIR/none.cfg" ]
    # A read that fails leaves no SHA-256 of the one before.
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_deploy_read "$1" "$2" "$3"; ku_deploy_read "$1" "$4" "$3" ||
        printf "%s|%s\n" "$?" "$KU_DEPLOY_SUM"' "$P1" "$REL" "$BATS_TEST_TMPDIR/copy.cfg" \
        multibootusb/grub/kali.cfg
    [ "$output" = "2|" ]
}

@test "ku_deploy_read follows no symlink, whether the file or a directory on its way" {
    use_symlinks || skip "this platform cannot make symlinks"
    # shellcheck disable=SC2016 # the code expands its own arguments
    local fail='ku_deploy_read "$@" || { code=$?; printf "%s\n" "$KU_DK_PROBLEM"; exit "$code"; }'
    # A link to a secret, as one made from Windows could be.
    printf 'secret\n' > "$BATS_TEST_TMPDIR/secret.key"
    ln -s "$BATS_TEST_TMPDIR/secret.key" "$GRUB/kali.cfg"
    run_ku_lib "$fail" "$P1" multibootusb/grub/kali.cfg "$BATS_TEST_TMPDIR/copy.cfg"
    [ "$status" -eq 1 ]
    [ "$output" = "multibootusb/grub/kali.cfg is a symlink" ]
    [ ! -e "$BATS_TEST_TMPDIR/copy.cfg" ]
    # multibootusb/grub itself leads elsewhere.
    mkdir "$BATS_TEST_TMPDIR/elsewhere"
    cp "$GRUB/grub.cfg" "$BATS_TEST_TMPDIR/elsewhere/grub.cfg"
    rm "$GRUB/kali.cfg" "$GRUB/grub.cfg"
    rmdir "$GRUB"
    ln -s ../../elsewhere "$GRUB"
    run_ku_lib "$fail" "$P1" "$REL" "$BATS_TEST_TMPDIR/copy.cfg"
    [ "$status" -eq 1 ]
    [ "$output" = "multibootusb/grub, on the way to $REL, is a symlink" ]
    [ ! -e "$BATS_TEST_TMPDIR/copy.cfg" ]
}

@test "--dry-run checks the target and says what it would write, changing nothing" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'KU_DRY_RUN=1; ku_deploy_write "$@"' "$P1" "$REL" "$BATS_TEST_TMPDIR/grub.cfg" \
        "$OLD"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: would write $REL, keeping the old one as $REL.ku-"*".bak"* ]]
    grub_unchanged
    [ -z "$(backups)" ]
}

@test "An export writes the files, SHA256SUMS and DEPLOY.txt into a directory of root's" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"' \
        "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$OUT/kali.cfg"
    cmp "$BATS_TEST_TMPDIR/grub.cfg" "$OUT/grub.cfg"
    [ "$(< "$OUT/SHA256SUMS")" = "$(sha256 "$OUT/kali.cfg")  kali.cfg"$'\n'"$(sha256 \
        "$OUT/grub.cfg")  grub.cfg" ]
    (cd "$OUT" && sha256sum -c --quiet SHA256SUMS)
    grep -q -F 'copy them, in this order, into BOOT:\multibootusb\grub\ on the stick,' \
        "$OUT/DEPLOY.txt"
    # Library code started without bin/kernel-updater names the installed path.
    grep -q -F "run 'sudo /usr/local/bin/kernel-updater check' to confirm" "$OUT/DEPLOY.txt"
    [ "$(grep -n -E '^ +(kali|grub)\.cfg$' "$OUT/DEPLOY.txt" | cut -d : -f 2 | tr -d ' ')" = \
        $'kali.cfg\ngrub.cfg' ]
    [[ "$stderr" == *"info: exported 2 file(s) to $OUT: copy them to the stick from Windows"* ]]
    [ -z "$(find "$OUT" -name '.*')" ]
    # Only root can enter it; Git Bash on Windows keeps no such mode.
    if [[ $OSTYPE == linux* ]]; then
        [ "$(command stat -c %a "$OUT")" = 700 ]
    fi
    # A second export replaces the first: the first one's grub.cfg goes, so that Windows cannot
    # copy it, and a file no export wrote stays.
    printf 'changed\n' > "$BATS_TEST_TMPDIR/kali.cfg"
    printf 'notes\n' > "$OUT/notes.txt"
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"' \
        "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 0 ]
    [ "$(< "$OUT/SHA256SUMS")" = "$(sha256 "$OUT/kali.cfg")  kali.cfg" ]
    [ ! -e "$OUT/grub.cfg" ]
    [ -e "$OUT/notes.txt" ]
    [ "$(grep -c -E '^ +(kali|grub)\.cfg$' "$OUT/DEPLOY.txt")" -eq 1 ]
}

@test "An export refuses an output_dir others can enter or own, and odd or repeated names" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local code='ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"'
    mkdir -p "$OUT"
    for OUT_STAT in "0 750" "0 701" "1000 700"; do
        run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg"
        [ "$status" -eq 78 ] || { printf '%s exited %s\n' "$OUT_STAT" "$status" >&2; return 1; }
        [[ "$stderr" == *"output_dir $OUT must be owned by root and closed to group and others"* ]]
        [ -z "$(ls -A "$OUT")" ]
    done
    export OUT_STAT="0 700"
    rmdir "$OUT"
    printf 'a file\n' > "$OUT"
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"output_dir $OUT is no directory"* ]]
    rm "$OUT"
    mkdir "$BATS_TEST_TMPDIR/again"
    cp "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/again/kali.cfg"
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/again/kali.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"refusing to export two files named kali.cfg"* ]]
    # Names that are no plain file name of their own: the export's own SHA256SUMS and DEPLOY.txt,
    # and one with a leading dot or a space.
    local name
    for name in SHA256SUMS DEPLOY.txt .hidden.cfg "a b.cfg"; do
        printf 'x\n' > "$BATS_TEST_TMPDIR/$name"
        run_ku_lib "$code" "$BATS_TEST_TMPDIR/$name"
        [ "$status" -eq 3 ] || { printf '%s exited %s\n' "$name" "$status" >&2; return 1; }
        [[ "$stderr" == *"refusing to export $name: no plain file name of its own"* ]]
    done
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/none.cfg"
    [ "$status" -eq 66 ]
    [ ! -e "$OUT" ]
}

@test "An export refuses an output_dir whose path a user can change, in a dry run too" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local code='ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"'
    # Root owns every directory, with mode 0755, and output_dir, with 0700, but output_dir's
    # parent is a user's, who could swap output_dir for a symlink between root's checks and its
    # writes.
    export OUT OPEN="$ROOT/root/kernel-updater"
    mkstub stat <<'EOF'
case ${*: -1} in
    "$OUT") echo "0 700" ;;
    "$OPEN") echo "1000 755" ;;
    *) echo "0 755" ;;
esac
EOF
    mkdir -p "$OUT"
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"the path to output_dir $OUT holds a symlink, or a directory a user other"* ]]
    [ -z "$(ls -A "$OUT")" ]
    run_ku_lib "KU_DRY_RUN=1; $code" "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"the path to output_dir $OUT holds a symlink, or a directory a user other"* ]]
    # A dry run makes no output_dir: it checks the path to where it would make one.
    rmdir "$OUT"
    run_ku_lib "KU_DRY_RUN=1; $code" "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 78 ]
    [ ! -e "$OUT" ]
    # With the parent root's, both go ahead.
    export OPEN=/none
    run_ku_lib "KU_DRY_RUN=1; $code" "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would export 1 file(s) to $OUT"* ]]
    [ ! -e "$OUT" ]
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg"
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/kali.cfg" "$OUT/kali.cfg"
}

@test "An export that fails partway leaves neither the old SHA256SUMS nor the old DEPLOY.txt" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local code='ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"'
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 0 ]
    [ -f "$OUT/DEPLOY.txt" ]
    # The next export cannot put grub.cfg in place, after kali.cfg went in.
    export OUT
    mkstub mv <<'EOF'
[[ ${*: -1} != "$OUT/grub.cfg" ]] || exit 1
exec "$REAL_MV" "$@"
EOF
    run_ku_lib "$code" "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/grub.cfg"
    [ "$status" -eq 4 ]
    [ ! -e "$OUT/SHA256SUMS" ]
    [ ! -e "$OUT/DEPLOY.txt" ]
}

@test "ku_export_verify reports each exported file as same, differs or missing" {
    # shellcheck disable=SC2016 # the code expands its own arguments
    local verify='ku_export_verify "$1" || exit'
    run_ku_lib "$verify" "$P1"
    [ "$status" -eq 66 ]
    # shellcheck disable=SC2016 # the code expands its own arguments
    run_ku_lib 'ku_export "$(ku_path "${KU_CONF[output_dir]}")" "$@"' \
        "$BATS_TEST_TMPDIR/kali.cfg" "$BATS_TEST_TMPDIR/grub.cfg"
    run_ku_lib "$verify" "$P1"
    [ "$status" -eq 2 ]
    [ "$output" = $'kali.cfg\tmissing\ngrub.cfg\tdiffers' ]
    cp "$OUT/kali.cfg" "$OUT/grub.cfg" "$GRUB/"
    run_ku_lib "$verify" "$P1"
    [ "$status" -eq 0 ]
    [ "$output" = $'kali.cfg\tsame\ngrub.cfg\tsame' ]
    # A symlink to the very bytes exported is not followed, so it differs.
    if use_symlinks; then
        mv "$GRUB/kali.cfg" "$BATS_TEST_TMPDIR/elsewhere.cfg"
        ln -s "$BATS_TEST_TMPDIR/elsewhere.cfg" "$GRUB/kali.cfg"
        run_ku_lib "$verify" "$P1"
        [ "$status" -eq 2 ]
        [ "$output" = $'kali.cfg\tdiffers\ngrub.cfg\tsame' ]
    fi
    printf 'not a sum\n' >> "$OUT/SHA256SUMS"
    run_ku_lib "$verify" "$P1"
    [ "$status" -eq 1 ]
}
