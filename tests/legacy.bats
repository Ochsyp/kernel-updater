#!/usr/bin/env bats
# -------------------------------------------------------
# legacy update_kernel.sh checks
#
# Argument handling and the grub.cfg rewrite of the imported script, run with stub
# commands so nothing reaches dpkg, apt, initramfs-tools, GRUB or the module tree. The
# rest of the legacy script is not tested: the redesign replaces it.
# -------------------------------------------------------

load helpers

setup() {
    stub_init
    mkstub uname <<'EOF'
if [[ "$*" == "-r" ]]; then echo "7.3.1+kali-amd64"; exit 0; fi
exit 99
EOF
    # dpkg-query lists no packages, so a run stops right after the grub.cfg rewrite.
    mkstub dpkg-query
    stub_refuse apt-get
    stub_refuse update-initramfs
    stub_refuse update-grub
    stub_refuse rm
}

@test "No argument prints the usage on stderr and exits 64 before anything runs" {
    run_legacy
    [ "$status" -eq 64 ]
    [[ "$stderr" == Usage:* ]]
    [ -z "$output" ]
    [ ! -s "$STUB_LOG" ]
}

@test "Two arguments are a usage error" {
    run_legacy a.cfg b.cfg
    [ "$status" -eq 64 ]
    [ ! -s "$STUB_LOG" ]
}

@test "A missing grub.cfg is an error and no package tool runs" {
    run_legacy "$BATS_TEST_TMPDIR/missing.cfg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Target file does not exist"* ]]
    refute_line_match '^(dpkg-query|apt-get|update-)' "$STUB_LOG"
}

@test "Every kernel version in the given grub.cfg becomes the running kernel's" {
    local cfg="$BATS_TEST_TMPDIR/grub.cfg"
    cp "$REPO_DIR/examples/grub.cfg" "$cfg"
    run_legacy "$cfg"
    # With no kernel packages listed the script refuses to go on, before any purge.
    [ "$status" -eq 1 ]
    [[ "$output" == *"No installed linux-image packages found"* ]]
    refute_line_match '7\.2\.9\+kali-amd64' "$cfg"
    [ "$(grep -c '7\.3\.1+kali-amd64' "$cfg")" -eq 12 ]
    refute_line_match '^(apt-get|update-|rm)' "$STUB_LOG"
    # Nothing but the version strings changed.
    diff <(sed 's/7\.3\.1+kali-amd64/7.2.9+kali-amd64/g' "$cfg") "$REPO_DIR/examples/grub.cfg"
}
