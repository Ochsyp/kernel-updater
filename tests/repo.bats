#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater repository checks
#
# Runs privacy-scan over every tracked file and proves it catches each kind of leak,
# then checks line endings, executable bits and the GRUB syntax of the example configs.
# -------------------------------------------------------

load helpers

SCAN="$REPO_DIR/.githooks/privacy-scan"

# Create a scratch repository at $BATS_TEST_TMPDIR/repo that stores files byte for byte, so
# a CRLF file stays CRLF in the index whatever the machine's core.autocrlf says.
scratch_repo() {
    SCRATCH="$BATS_TEST_TMPDIR/repo"
    git init -q "$SCRATCH"
    git -C "$SCRATCH" config core.autocrlf false
}

@test "No tracked file holds an identifier, address, home path or CRLF line ending" {
    cd "$REPO_DIR"
    run --separate-stderr sh "$SCAN" --tracked
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "privacy-scan reports each kind of leak by file and line, never the value" {
    scratch_repo
    # Assembled at run time from fragments, so this file itself holds no identifier.
    {
        printf 'uuid %s-%s-%s-%s-%s\n' d00dfeed cafe 4abc 8def 0123456789ab
        printf 'luks %s%s%s%s%s\n' d00dfeed cafe 4abc 8def 0123456789ab
        printf 'serial %s%s\n' D00DFEED CAFEF00D
        printf 'serial %s%s\n' d00dfeed cafef00d
        printf 'fat %s="%s-%s"\n' UUID 1A2B 3C4D
        printf 'search --fs-uuid --set=root %s-%s\n' 1a2b 3c4d
        printf 'lvm %s-%s-%s-%s-%s-%s-%s\n' Ab12Cd 3456 7890 abcd EfGh 1234 Zz99Yy
        printf 'disk %sUUID="%s-01"\n' PART d00dfeed
        printf 'addr 192.%s.7.9\n' 168
        printf 'addr %s::1\n' fe80
        printf 'host printer.%s\n' lan
        printf 'path /%s/someone/file\n' home
        printf 'win C:%sUsers%ssomeone\n' "\\" "\\"
        printf 'win C:/%s/someone\n' Users
        printf 'msys /c/%s/someone\n' Users
        printf 'mac /%s/someone\n' Users
        printf 'mail someone@%s\n' example.de
        printf 'label Secret Label\n'
        printf 'mail someone@%s\n' users.noreply.github.com
    } > "$SCRATCH/leak.txt"
    printf 'one\r\ntwo\r\n' > "$SCRATCH/crlf.txt"
    # A file named like a synthetic identifier still has its contents scanned.
    printf 'addr 10.%s.0.1\nserial %s%s\n' 20 0123ABCD 4567EF89 > "$SCRATCH/5ca1ab1e-fixture.txt"
    # Written with CRLF, as Notepad would: the CR must not stop the value from matching.
    printf 'secret label\r\n' > "$SCRATCH/.git/info/privacy-denylist"
    git -C "$SCRATCH" add leak.txt crlf.txt 5ca1ab1e-fixture.txt
    # A staged symlink is scanned through its target.
    local target
    target=$(printf '/%s/someone/x' home | git -C "$SCRATCH" hash-object -w --stdin)
    git -C "$SCRATCH" update-index --add --cacheinfo "120000,$target,link"
    cd "$SCRATCH"
    run --separate-stderr sh "$SCAN" --staged
    [ "$status" -eq 1 ]
    local hit
    for hit in "leak.txt:1: disk UUID" "leak.txt:2: dashless UUID" \
        "leak.txt:3: NTFS volume serial" "leak.txt:4: NTFS volume serial" \
        "leak.txt:5: FAT volume serial" "leak.txt:6: FAT volume serial" "leak.txt:7: LVM UUID" \
        "leak.txt:8: PARTUUID or PTUUID" "leak.txt:9: private IPv4 address" \
        "leak.txt:10: private IPv6 address" "leak.txt:11: .lan host name" \
        "leak.txt:12: user home path" "leak.txt:13: user home path" \
        "leak.txt:14: user home path" "leak.txt:15: user home path" \
        "leak.txt:16: user home path" "leak.txt:17: e-mail address" \
        "leak.txt:18: denylisted value" "crlf.txt: CRLF line endings" \
        "5ca1ab1e-fixture.txt:1: private IPv4 address" \
        "5ca1ab1e-fixture.txt:2: NTFS volume serial" "link:1: user home path"; do
        [[ "$stderr" == *"privacy-scan: $hit"* ]] || { printf 'missing: %s\n%s\n' "$hit" "$stderr" >&2; return 1; }
    done
    # Exactly those 22 hits: the no-reply address on line 19 is exempt and nothing is reported twice.
    [ "$(grep -c '^privacy-scan: [^ ]*: ' <<< "$stderr")" -eq 22 ]
    [[ "$stderr" != *d00dfeed* && "$stderr" != *D00DFEED* && "$stderr" != *someone* && "$stderr" != *1A2B* ]]
}

@test "privacy-scan lets the synthetic 5ca1ab1e identifiers in the example config through" {
    scratch_repo
    cp "$REPO_DIR/examples/grub.cfg" "$SCRATCH/grub.cfg"
    git -C "$SCRATCH" add grub.cfg
    cd "$SCRATCH"
    run --separate-stderr sh "$SCAN" --staged
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "privacy-scan refuses an unknown option with exit 64" {
    run --separate-stderr sh "$SCAN" --all
    [ "$status" -eq 64 ]
    [[ "$stderr" == usage:* ]]
}

@test "The scripts and hooks are stored executable" {
    cd "$REPO_DIR"
    local f
    for f in update_kernel.sh bin/kernel-updater .githooks/pre-commit .githooks/pre-push .githooks/privacy-scan; do
        run git ls-files -s -- "$f"
        [[ "$output" == "100755 "* ]] || { printf '%s is not stored executable: %s\n' "$f" "$output" >&2; return 1; }
    done
}

@test "The example configs pass grub-script-check" {
    command -v grub-script-check > /dev/null || skip "grub-script-check is not on PATH (package grub-common)"
    local cfg
    for cfg in "$REPO_DIR"/examples/*.cfg; do
        run grub-script-check "$cfg"
        [ "$status" -eq 0 ]
    done
}
