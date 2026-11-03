#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater lint command checks
#
# Runs kernel-updater lint on the synthetic fixtures in tests/fixtures/grub and on configs the
# tests write, and compares the findings, formats and exit codes.
# -------------------------------------------------------

load helpers

FIXTURES="$TESTS_DIR/fixtures/grub"

setup() {
    stub_init
}

@test "lint reports every defect class in the fixture with its line, severity and rule" {
    run_ku lint --porcelain "$FIXTURES/defects.cfg"
    [ "$status" -eq 2 ]
    diff <(cut -f2- <<< "$output") "$FIXTURES/defects.expected"
}

@test "A CRLF copy of the fixture gives the same findings" {
    sed 's/$/\r/' "$FIXTURES/defects.cfg" > "$BATS_TEST_TMPDIR/crlf.cfg"
    run_ku lint --porcelain "$BATS_TEST_TMPDIR/crlf.cfg"
    [ "$status" -eq 2 ]
    diff <(cut -f2- <<< "$output") "$FIXTURES/defects.expected"
}

@test "Findings name identifier kinds and never their values" {
    run_ku lint "$FIXTURES/defects.cfg"
    [[ "$output" != *5ca1ab1e* && "$stderr" != *5ca1ab1e* ]]
}

@test "The human format puts file, line, severity, message and rule on one line" {
    run_ku lint "$FIXTURES/defects.cfg"
    [ "${lines[0]}" = "$FIXTURES/defects.cfg:5: error: unknown module 'nfts' [unknown-module]" ]
}

@test "The example config is clean" {
    run_ku lint "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--floor 2.12 accepts dashed LUKS UUIDs and still reports malformed ones" {
    run_ku lint --floor 2.12 --porcelain "$FIXTURES/defects.cfg"
    [ "$status" -eq 2 ]
    [[ "$output" != *cryptouuid-dashes* ]]
    [[ "$output" == *cryptouuid-malformed* ]]
    [ "$(grep -c cryptomount-uuid <<< "$output")" -eq 1 ]
}

@test "grub_floor in the config sets the default floor and --floor overrides it" {
    printf 'grub_floor = 2.12\n' > "$BATS_TEST_TMPDIR/k.conf"
    run_ku -c "$BATS_TEST_TMPDIR/k.conf" lint --porcelain "$FIXTURES/defects.cfg"
    [[ "$output" != *cryptouuid-dashes* ]]
    run_ku -c "$BATS_TEST_TMPDIR/k.conf" lint --floor 2.02 --porcelain "$FIXTURES/defects.cfg"
    [[ "$output" == *cryptouuid-dashes* ]]
}

@test "Warnings alone exit 0, and 2 with --strict" {
    printf 'menuentry "x" {\n\tlinux /vmlinuz noswap\n}\n' > "$BATS_TEST_TMPDIR/w.cfg"
    run_ku lint "$BATS_TEST_TMPDIR/w.cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[live-boot-param]" ]]
    run_ku lint --strict "$BATS_TEST_TMPDIR/w.cfg"
    [ "$status" -eq 2 ]
}

@test "--grub-dir takes the command and module names from that directory" {
    local dir="$BATS_TEST_TMPDIR/i386-pc"
    mkdir "$dir"
    printf '*menuentry: normal\nlinux: linux\n' > "$dir/command.lst"
    printf 'linux: relocator mmap\nnormal: crypto\n' > "$dir/moddep.lst"
    printf 'insmod linux\ninsmod gzio\nmenuentry "x" {\n\tlinux /vmlinuz\n\tinitrd /initrd.img\n}\n' \
        > "$BATS_TEST_TMPDIR/g.cfg"
    run_ku lint --porcelain --grub-dir "$dir" "$BATS_TEST_TMPDIR/g.cfg"
    [ "$status" -eq 2 ]
    [ "$(cut -f2-4 <<< "$output")" = $'2\terror\tunknown-module\n5\terror\tunknown-command' ]
}

@test "A rejection by grub-script-check becomes an error at the line it names" {
    mkstub grub-script-check <<< 'echo "Syntax error at line 3" >&2; exit 1'
    run_ku lint --porcelain "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 2 ]
    [ "$(cut -f2-4 <<< "$output")" = $'3\terror\tsyntax' ]
}

@test "The real grub-script-check catches an if without fi" {
    command -v grub-script-check > /dev/null || skip "grub-script-check is not on PATH (package grub-common)"
    printf 'set a=1\nif true; then\n\techo x\n' > "$BATS_TEST_TMPDIR/s.cfg"
    run_ku lint --porcelain "$BATS_TEST_TMPDIR/s.cfg"
    [ "$status" -eq 2 ]
    [[ "$(cut -f3,4 <<< "$output")" == $'error\tsyntax'* ]]
}

@test "Usage errors exit 64 and unreadable inputs exit 66" {
    run_ku lint
    [ "$status" -eq 64 ]
    run_ku lint --bogus x
    [ "$status" -eq 64 ]
    run_ku lint --floor 2.03 "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 64 ]
    run_ku lint "$BATS_TEST_TMPDIR/none.cfg"
    [ "$status" -eq 66 ]
    run_ku lint --grub-dir "$BATS_TEST_TMPDIR/none" "$REPO_DIR/examples/grub.cfg"
    [ "$status" -eq 66 ]
}

@test "Continued lines and quotes left open are one statement, and no value is echoed" {
    {
        printf 'menuentry "x" {\n'
        printf '\tsearch --no-floppy --fs-uuid --set=root \\\n\t\t5ca1ab1e-0000-4000-8000-000000000b01\n'
        printf '\tlinux /vmlinuz root=/dev/mapper/r ro \\\n\t\tcryptdevice=UUID=5ca1ab1e:root noswap\n'
        printf '\techo "two\n\tlines"\n'
        printf '}\n'
    } > "$BATS_TEST_TMPDIR/c.cfg"
    run_ku lint --porcelain "$BATS_TEST_TMPDIR/c.cfg"
    [ "$status" -eq 0 ]
    [ "$(cut -f2-4 <<< "$output")" = $'4\twarning\tarch-param\n4\twarning\tlive-boot-param' ]
    [[ "$output" != *5ca1ab1e* ]]
}

@test "Values held in GRUB variables are not judged" {
    # shellcheck disable=SC2016 # the GRUB variables must reach the file unexpanded
    printf 'menuentry "x" {\n\tcryptomount -u $luks\n\tcryptomount -u "${luks}"\n\tset root=(cryptouuid/${luks})\n\tsearch --fs-uuid --set=root $fs\n}\n' \
        > "$BATS_TEST_TMPDIR/v.cfg"
    run_ku lint "$BATS_TEST_TMPDIR/v.cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "An ISO9660 date is a valid search --fs-uuid value" {
    printf 'search --no-floppy --fs-uuid --set=root 2024-02-26-10-28-48-00\n' > "$BATS_TEST_TMPDIR/i.cfg"
    run_ku lint "$BATS_TEST_TMPDIR/i.cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Above the 2.02 floor, names missing from the bundled lists are only warnings" {
    printf 'insmod luks2\nbli_check\n' > "$BATS_TEST_TMPDIR/n.cfg"
    run_ku lint --porcelain --floor 2.12 "$BATS_TEST_TMPDIR/n.cfg"
    [ "$status" -eq 0 ]
    [ "$(cut -f2-4 <<< "$output")" = $'1\twarning\tunknown-module\n2\twarning\tunknown-command' ]
    run_ku lint --porcelain "$BATS_TEST_TMPDIR/n.cfg"
    [ "$status" -eq 2 ]
}

@test "A drive in an assignment is reported, one in a title or echo text is not" {
    printf 'root=(hd0,gpt2)\nmenuentry "Chainload (hd1)" {\n\techo "on (hd1)"\n}\n' > "$BATS_TEST_TMPDIR/d.cfg"
    run_ku lint --porcelain "$BATS_TEST_TMPDIR/d.cfg"
    [ "$(cut -f2-4 <<< "$output")" = $'1\twarning\thard-coded-drive' ]
}

@test "A brace on the line after function opens its block" {
    printf 'function video\n{\n\tinsmod all_video\n}\nvideo\n' > "$BATS_TEST_TMPDIR/b.cfg"
    run_ku lint "$BATS_TEST_TMPDIR/b.cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "A hint given as --hint VALUE is only a warning" {
    printf 'search --fs-uuid --set=root --hint cryptouuid/abc 5ca1ab1e-0000-4000-8000-000000000b01\n' \
        > "$BATS_TEST_TMPDIR/h.cfg"
    run_ku lint --porcelain "$BATS_TEST_TMPDIR/h.cfg"
    [ "$status" -eq 0 ]
    [ "$(cut -f2-4 <<< "$output")" = $'1\twarning\tcryptouuid-malformed' ]
}

@test "--grub-dir can be repeated and merges the lists" {
    local pc="$BATS_TEST_TMPDIR/pc" efi="$BATS_TEST_TMPDIR/efi"
    mkdir "$pc" "$efi"
    printf 'linux: linux\n' > "$pc/command.lst"
    printf 'linux: relocator\n' > "$pc/moddep.lst"
    printf 'fwsetup: efifwsetup\n' > "$efi/command.lst"
    printf 'efifwsetup: extcmd\n' > "$efi/moddep.lst"
    printf 'insmod efifwsetup\nfwsetup\nlinux /vmlinuz\n' > "$BATS_TEST_TMPDIR/m.cfg"
    run_ku lint --grub-dir "$pc" --grub-dir "$efi" "$BATS_TEST_TMPDIR/m.cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "lint.awk gives the same findings under mawk and under gawk" {
    local awk_bin
    for awk_bin in mawk gawk; do
        command -v "$awk_bin" > /dev/null || skip "$awk_bin is not on PATH"
        export KU_AWK=$awk_bin
        run_ku lint --porcelain "$FIXTURES/defects.cfg"
        diff <(cut -f2- <<< "$output") "$FIXTURES/defects.expected"
    done
}
