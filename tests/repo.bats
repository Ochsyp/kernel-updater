#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater repository checks
#
# Runs the standard's privacy-scan over every tracked file, with the packs the config selects,
# then checks executable bits and the GRUB syntax of the example configs. The standard's own
# suites in .github/standard/tests prove what privacy-scan catches.
# -------------------------------------------------------

load helpers

SCAN="$REPO_DIR/.githooks/privacy-scan"

@test "No tracked file holds an identifier, address, home path or CRLF line ending" {
    cd "$REPO_DIR"
    run --separate-stderr sh "$SCAN" --tracked
    [ "$status" -eq 0 ]
    # Without a denylist, as in CI, the scan says so in a note; nothing else may reach stderr.
    local line
    while IFS= read -r line; do
        [[ -z $line || $line == 'privacy-scan: note: '* ]] && continue
        printf '%s\n' "$line" >&2
        return 1
    done <<< "$stderr"
}

@test "The scripts and hooks are stored executable" {
    cd "$REPO_DIR"
    local f
    for f in install.sh bin/kernel-updater lib/kernel-updater/apt-guard \
        hooks/kernel/*.d/* contrib/initramfs/overlayroot-rw ci/test ci/system ci/release-check; do
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

@test "No Windows script takes BOOT offline before the VM starts" {
    # Taken offline with mountvol /p, BOOT cannot be locked by VMware, and Windows then refuses
    # the VM's writes to it (docs/migration.md, "Writing a FAT partition 1 from the VM").
    run grep -r -i -l mountvol "$REPO_DIR/tools/windows"
    [ -z "$output" ]
}
