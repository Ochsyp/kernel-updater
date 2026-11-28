#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater release check
#
# Runs ci/release-check, which the standard's release-build runs on each release archive, on
# archives built here from this checkout: one as release-build makes it, which passes, and
# others with a file missing, changed or added, install.sh not executable, another version, or
# no release manifest, which each fail and name what is wrong.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

setup() {
    VERSION=$(tr -d '\r' < "$REPO_DIR/VERSION")
    TOP=kernel-updater-$VERSION
    STAGE="$BATS_TEST_TMPDIR/stage"
    mkdir -p "$STAGE/$TOP"
    # What install.sh installs, and install.sh itself: the parts of the archive the check reads.
    cp -pR "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/share" "$REPO_DIR/hooks" \
        "$REPO_DIR/install.sh" "$REPO_DIR/VERSION" "$STAGE/$TOP/"
    manifest "$VERSION"
    ARCHIVE="$BATS_TEST_TMPDIR/$TOP.tar.gz"
}

# Write the release manifest as release-build adds it, naming version V.
manifest() {
    {
        printf '{\n  "schema": 1,\n  "name": "kernel-updater",\n  "version": "%s",\n' "$1"
        printf '  "tag": "v%s",\n  "commit": "%s"\n}\n' "$1" \
            0123456789abcdef0123456789abcdef01234567
    } > "$STAGE/$TOP/kernel-updater-release.json"
}

# Pack the stage into ARCHIVE, install.sh with MODE (0755 unless given), as release-build's
# tar.gz holds it under the folder kernel-updater-VERSION.
pack() {
    local tar="$BATS_TEST_TMPDIR/archive.tar"
    rm -f -- "$tar" "$ARCHIVE"
    tar --force-local -C "$STAGE" --exclude="$TOP/install.sh" -cf "$tar" "$TOP"
    tar --force-local -C "$STAGE" --mode="${1:-0755}" -rf "$tar" "$TOP/install.sh"
    gzip -n < "$tar" > "$ARCHIVE"
}

# Run ci/release-check from the top of the checkout, as release-build does.
run_check() {
    cd "$REPO_DIR" || return 1
    run --separate-stderr ./ci/release-check --archive "$ARCHIVE" --version "${1:-$VERSION}"
}

@test "An archive as release-build makes it passes" {
    pack
    run_check
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"release-check: ok: $TOP holds the"*"files install.sh installs"* ]]
}

@test "A file install.sh installs that the archive lacks fails the check, by name" {
    rm "$STAGE/$TOP/share/kernel-updater/baseline.list"
    pack
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: the archive lacks share/kernel-updater/baseline.list"* ]]
}

@test "A file the archive holds in another version than the checkout fails the check" {
    printf '# changed\n' >> "$STAGE/$TOP/lib/kernel-updater/common.sh"
    pack
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: lib/kernel-updater/common.sh differs from the checkout's"* ]]
}

@test "A file the archive would install that the checkout lacks fails the check" {
    printf 'extra\n' > "$STAGE/$TOP/share/kernel-updater/extra.txt"
    pack
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: the archive also installs share/kernel-updater/extra.txt"* ]]
}

@test "A file install.sh needs by name, missing from the archive, fails the check" {
    rm "$STAGE/$TOP/bin/kernel-updater"
    pack
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: install.sh --list fails in the archive"* ]]
}

@test "An install.sh that is not executable fails the check" {
    pack 0644
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: $TOP/install.sh is not executable"* ]]
}

@test "Another version than the archive's VERSION files and manifest fails the check" {
    pack
    run_check 9.8.7
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: the archive holds no kernel-updater-9.8.7/"* ]]
    printf '9.8.7\n' > "$STAGE/$TOP/VERSION"
    manifest 9.8.7
    pack
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: VERSION holds 9.8.7, not $VERSION"* ]]
    [[ "$stderr" == *"release-check: kernel-updater-release.json names another version"* ]]
}

@test "An archive without the release manifest fails the check" {
    rm "$STAGE/$TOP/kernel-updater-release.json"
    pack
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: the archive lacks kernel-updater-release.json"* ]]
}

@test "release-check refuses a usage error with exit 64 and a missing archive with exit 1" {
    run_check
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"release-check: cannot unpack"* ]]
    cd "$REPO_DIR" || return 1
    run --separate-stderr ./ci/release-check --archive
    [ "$status" -eq 64 ]
    run --separate-stderr ./ci/release-check --version 1.0.0
    [ "$status" -eq 64 ]
    [[ "$stderr" == usage:* ]]
}
