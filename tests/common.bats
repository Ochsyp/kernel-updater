#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater common library checks
#
# Calls the rails in lib/kernel-updater/common.sh directly: the root check, the lock, the
# confirmation, the dry-run wrapper, the traps and the path and release helpers.
# -------------------------------------------------------

# shellcheck disable=SC2034 # the tests set the settings that the sourced library reads
load helpers

setup() {
    stub_init
    load_ku_libs
    export PATH="$STUB_BIN:$PATH"
}

@test "ku_require_root exits 77 for a user other than root and returns for root" {
    mkstub id <<< 'echo 1000'
    run ku_require_root
    [ "$status" -eq 77 ]
    [[ "$output" == *"must run as root"* ]]
    mkstub id <<< 'echo 0'
    run ku_require_root
    [ "$status" -eq 0 ]
}

@test "The seams KU_ROOT, KU_TTY and KU_LOCKFILE count only with KU_TEST=1" {
    # shellcheck disable=SC2016 # the inner script expands its own variables
    local code='. "$1"; printf "%s|%s|%s\n" "$KU_ROOT" "$KU_TTY" "$KU_LOCKFILE"'
    # A KU_ROOT left in root's environment, as with sudo -E, must not move what the hooks check.
    run env -u KU_TEST KU_ROOT=/srv/root KU_TTY=/srv/tty KU_LOCKFILE=/srv/lock \
        bash -c "$code" _ "$REPO_DIR/lib/kernel-updater/common.sh"
    [ "$output" = "/|/dev/tty|/run/kernel-updater.lock" ]
    run env KU_TEST=1 KU_ROOT=/srv/root KU_TTY=/srv/tty KU_LOCKFILE=/srv/lock \
        bash -c "$code" _ "$REPO_DIR/lib/kernel-updater/common.sh"
    [ "$output" = "/srv/root|/srv/tty|/srv/lock" ]
}

@test "ku_ask takes a yes that ends in a carriage return, as ku_ask_person does" {
    printf 'y\r\n' > "$BATS_TEST_TMPDIR/tty"
    run_ku_lib 'ku_ask "Go on?" && echo yes'
    [ "$status" -eq 0 ]
    [ "$output" = yes ]
}

@test "ku_lock maps flock's busy status to 75 and any other failure to 1" {
    KU_LOCKFILE="$BATS_TEST_TMPDIR/lock"
    mkstub flock <<< 'exit 1'
    run ku_lock
    [ "$status" -eq 75 ]
    [[ "$output" == *"holds the lock"* ]]
    mkstub flock <<< 'exit 64'
    run ku_lock
    [ "$status" -eq 1 ]
    [[ "$output" == *"flock failed with status 64"* ]]
    mkstub flock
    run ku_lock
    [ "$status" -eq 0 ]
    grep -q '^flock -n ' "$STUB_LOG"
}

@test "ku_lock exits 75 when the lock file cannot be opened and 1 without flock" {
    mkstub flock
    KU_LOCKFILE="$BATS_TEST_TMPDIR/no-such-dir/lock"
    run ku_lock
    [ "$status" -eq 75 ]
    [[ "$output" == *"cannot open the lock file"* ]]
    # shellcheck disable=SC2016 # the inner script expands its own arguments
    run "$BASH" -c '. "$1/lib/kernel-updater/common.sh"; PATH=/nonexistent; KU_LOCKFILE=$2; ku_lock' \
        _ "$REPO_DIR" "$BATS_TEST_TMPDIR/lock"
    [ "$status" -eq 1 ]
    [[ "$output" == *"flock (util-linux) is not installed"* ]]
}

@test "ku_lock exits 75 while a real flock holds the lock" {
    PATH=${PATH#"$STUB_BIN:"}
    command -v flock > /dev/null || skip "flock is not on PATH (util-linux)"
    KU_LOCKFILE="$BATS_TEST_TMPDIR/lock"
    flock "$KU_LOCKFILE" sleep 5 &
    local holder=$! tries=0
    until ! flock -n "$KU_LOCKFILE" true || (( ++tries > 50 )); do sleep 0.1; done
    run ku_lock
    kill "$holder" 2> /dev/null || true
    [ "$status" -eq 75 ]
}

@test "ku_confirm returns 0 on yes and exits 10 on anything else or without a terminal" {
    KU_TTY="$BATS_TEST_TMPDIR/tty"
    local answer
    for answer in y Y yes YES; do
        printf '%s\n' "$answer" > "$KU_TTY"
        run ku_confirm "Go on?"
        [ "$status" -eq 0 ]
    done
    for answer in n no "" maybe; do
        printf '%s\n' "$answer" > "$KU_TTY"
        run ku_confirm "Go on?"
        [ "$status" -eq 10 ]
    done
    KU_TTY="$BATS_TEST_TMPDIR/no-such-tty"
    run ku_confirm "Go on?"
    [ "$status" -eq 10 ]
    [[ "$output" == *"--yes"* ]]
    KU_ASSUME_YES=1
    run ku_confirm "Go on?"
    [ "$status" -eq 0 ]
}

@test "ku_ask_person returns 0 on yes alone, and --yes never answers it" {
    KU_TTY="$BATS_TEST_TMPDIR/tty"
    local answer
    # --yes is set: the person still answers on the terminal.
    KU_ASSUME_YES=1
    for answer in y Y yes YES $'y\r'; do
        printf '%s\n' "$answer" > "$KU_TTY"
        run ku_ask_person "Write it now?"
        [ "$status" -eq 0 ]
        [ "$output" = "Write it now? [y/N] " ]
    done
    for answer in n no "" maybe "yes please"; do
        printf '%s\n' "$answer" > "$KU_TTY"
        run ku_ask_person "Write it now?"
        [ "$status" -eq 10 ]
        [[ "$output" == *"declined; nothing was changed" ]]
    done
    # A question given in several words is asked whole.
    printf 'y\n' > "$KU_TTY"
    run ku_ask_person "Write it now? Check" "the drive first"
    [ "$status" -eq 0 ]
    [ "$output" = "Write it now? Check the drive first [y/N] " ]
    KU_TTY="$BATS_TEST_TMPDIR/no-such-tty"
    run ku_ask_person "Write it now?"
    [ "$status" -eq 10 ]
    [[ "$output" == *"no terminal to answer on, which --yes does not do for this question;"* ]]
}

@test "ku_ask returns 1 on a no, and each question reads the next answer of the terminal" {
    KU_TTY="$BATS_TEST_TMPDIR/tty"
    printf 'y\nn\nyes\n' > "$KU_TTY"
    # In one shell, as a command asks: the terminal stays open between the questions.
    ask_three() {
        if ku_ask "One?"; then echo one; fi
        if ! ku_ask "Two?"; then echo two-no; fi
        if ku_ask "Three?"; then echo three; fi
    }
    run --separate-stderr ask_three
    [ "$status" -eq 0 ]
    [ "$output" = $'one\ntwo-no\nthree' ]
    [[ "$stderr" == "One? [y/N] Two? [y/N] Three? [y/N]"* ]]
    # ku_confirm still exits 10 on a no.
    printf 'n\n' > "$KU_TTY"
    run ku_confirm "Go on?"
    [ "$status" -eq 10 ]
}

@test "ku_run only prints the command under --dry-run and runs it otherwise" {
    local target="$BATS_TEST_TMPDIR/made by ku_run"
    KU_DRY_RUN=1
    run ku_run touch "$target"
    [ "$status" -eq 0 ]
    [[ "$output" == "kernel-updater: would run: touch "*"made\\ by\\ ku_run" ]]
    [ ! -e "$target" ]
    KU_DRY_RUN=0
    run ku_run touch "$target"
    [ "$status" -eq 0 ]
    [ -e "$target" ]
}

@test "INT, TERM and HUP run the cleanups newest first and exit 130, 143 and 129" {
    local sig code
    for sig in INT:130 TERM:143 HUP:129; do
        code=${sig#*:} sig=${sig%:*}
        run bash -c '
            . "$1/lib/kernel-updater/common.sh"
            log=$2
            first() { echo first >> "$log"; }
            broken() { return 3; }
            last() { echo last >> "$log"; }
            ku_install_traps
            ku_cleanup_add first
            ku_cleanup_add broken
            ku_cleanup_add last
            kill -"$3" $$
            sleep 5
            echo "not interrupted"' _ "$REPO_DIR" "$BATS_TEST_TMPDIR/$sig.log" "$sig"
        [ "$status" -eq "$code" ] || { printf '%s exited %s\n' "$sig" "$status" >&2; return 1; }
        [ "$(cat "$BATS_TEST_TMPDIR/$sig.log")" = $'last\nfirst' ]
        [[ "$output" == *"interrupted by SIG$sig"* && "$output" == *"cleanup broken failed"* ]]
        [[ "$output" != *"not interrupted"* ]]
    done
}

@test "An unexpected failure is reported once, from the main shell, and exits 1" {
    run bash -c '
        set -Eeuo pipefail
        shopt -s inherit_errexit
        . "$1/lib/kernel-updater/common.sh"
        ku_install_traps
        fails() { (exit 66); echo "went on"; }
        value=$(fails)' _ "$REPO_DIR"
    [ "$status" -eq 1 ]
    [ "$(grep -c "unexpected failure" <<< "$output")" -eq 1 ]
    [[ "$output" != *"went on"* ]]
}

@test "ku_path resolves under KU_ROOT and ku_valid_release accepts only release-shaped text" {
    local release
    KU_ROOT=/srv/root/
    [ "$(ku_path /etc/kernel-img.conf)" = /srv/root/etc/kernel-img.conf ]
    KU_ROOT=/
    [ "$(ku_path /etc/kernel-img.conf)" = /etc/kernel-img.conf ]
    for release in 7.1.5+kali-amd64 6.12.38+deb13-amd64 6.8.11-amd64 6.0.0-kali6-amd64; do
        ku_valid_release "$release"
    done
    for release in "" 7 ../etc "7.1.5 x" "7.1.5;id" -7.1 "7.1/../x"; do
        if ku_valid_release "$release"; then
            printf 'accepted: %s\n' "$release" >&2
            return 1
        fi
    done
}
