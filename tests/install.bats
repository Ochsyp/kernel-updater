#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater installer checks
#
# Runs install.sh into a KU_ROOT tree with stubs for id, flock and sync: what it installs and
# with which modes, the manifest, updates, refusals of files in the way or changed since,
# --uninstall, --dry-run and the root check.
# -------------------------------------------------------

# shellcheck disable=SC2030,SC2031 # each test runs in a subshell of its own, so do its exports
load helpers

# The targets install.sh writes and their modes, besides the libraries and data it lists by
# globbing the checkout.
TARGETS=("755 /usr/local/bin/kernel-updater" "755 /usr/local/lib/kernel-updater/apt-guard"
    "644 /usr/local/lib/kernel-updater/common.sh" "644 /usr/local/lib/kernel-updater/hook.sh"
    "644 /usr/local/lib/kernel-updater/lint.awk" "644 /usr/local/share/kernel-updater/VERSION"
    "644 /usr/local/share/kernel-updater/grub-2.02/commands.txt"
    "755 /etc/kernel/preinst.d/00-kernel-updater" "755 /etc/kernel/prerm.d/00-kernel-updater"
    "755 /etc/kernel/postinst.d/00-kernel-updater" "755 /etc/kernel/postinst.d/kernel-updater"
    "644 /etc/apt/apt.conf.d/50kernel-updater")
MANIFEST=/var/lib/kernel-updater/install.manifest

setup() {
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT"
    # ID_U is the user id; root unless a test says otherwise.
    mkstub id <<'EOF'
printf '%s\n' "${ID_U:-0}"
EOF
    mkstub flock
    mkstub sync
}

# Run install.sh with ARGS, the stubs first on PATH, KU_ROOT and the lock file in the test's
# temp directory, through bats' run with separate stderr.
run_install() {
    run --separate-stderr env PATH="$STUB_BIN:$PATH" KU_TEST=1 KU_ROOT="$ROOT" \
        KU_LOCKFILE="$BATS_TEST_TMPDIR/lock" bash "$REPO_DIR/install.sh" "$@"
}

# Print the number of files the checkout installs: the command, the libraries and data, the
# four kernel hooks and the APT configuration.
expected_count() {
    local libs share
    libs=$(cd "$REPO_DIR/lib/kernel-updater" && find . -maxdepth 1 -type f | wc -l)
    share=$(cd "$REPO_DIR/share/kernel-updater" && find . -type f | wc -l)
    printf '%s' $(( 1 + libs + share + 4 + 1 ))
}

@test "install.sh installs the tool, its hooks and apt-guard, and lists each file's SHA-256" {
    local entry mode path line hash count
    run_install
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    for entry in "${TARGETS[@]}"; do
        read -r mode path <<< "$entry"
        [ -f "$ROOT$path" ] || { printf 'missing %s\n' "$path" >&2; return 1; }
        [ "$(stat -c %a "$ROOT$path")" = "$mode" ] ||
            { printf '%s has mode %s\n' "$path" "$(stat -c %a "$ROOT$path")" >&2; return 1; }
    done
    cmp "$REPO_DIR/hooks/apt/50kernel-updater" "$ROOT/etc/apt/apt.conf.d/50kernel-updater"
    count=0
    while IFS= read -r line; do
        hash=${line%%  *}
        path=${line#*  }
        [ "$(sha256sum < "$ROOT$path" | cut -d ' ' -f 1)" = "$hash" ]
        count=$((count + 1))
    done < "$ROOT$MANIFEST"
    [ "$count" -eq "$(expected_count)" ]
    [[ "$stderr" == *"info: installed /usr/local/bin/kernel-updater"* ]]
    [[ "$stderr" == *"is installed: $count new, 0 replaced, 0 unchanged and 0 removed file(s)"* ]]
    # No temporary file is left behind.
    [ -z "$(find "$ROOT" -name '.kernel-updater.*' -o -name '.install.manifest.*')" ]
}

@test "The libraries go in before the command, which goes in before the hooks that run it" {
    local -a installed=()
    run_install
    [ "$status" -eq 0 ]
    mapfile -t installed < <(grep -o 'info: installed /[^ ]*' <<< "$stderr" | cut -d ' ' -f 3)
    [[ "${installed[0]}" == /usr/local/lib/kernel-updater/* ]]
    [ "${installed[-1]}" = /etc/apt/apt.conf.d/50kernel-updater ]
    local i bin=-1 guard=-1 hook=-1 last_lib=-1
    for i in "${!installed[@]}"; do
        case ${installed[i]} in
            /usr/local/bin/kernel-updater) bin=$i ;;
            /usr/local/lib/kernel-updater/apt-guard) guard=$i ;;
            /usr/local/lib/* | /usr/local/share/*) last_lib=$i ;;
            /etc/kernel/*) (( hook >= 0 )) || hook=$i ;;
        esac
    done
    (( last_lib < bin && bin < guard && guard < hook ))
}

@test "A run cut short leaves a manifest that a rerun and --uninstall both accept" {
    local real_mv old hook
    run_install
    # Make the install look older: a library and a kernel hook with other contents, listed
    # with their hashes.
    old="$ROOT/usr/local/lib/kernel-updater/hook.sh"
    hook="$ROOT/etc/kernel/preinst.d/00-kernel-updater"
    printf '# an older hook.sh\n' > "$old"
    printf '#!/bin/sh\n# an older hook\n' > "$hook"
    awk -v lib="$(sha256sum < "$old" | cut -d ' ' -f 1)" \
        -v hook="$(sha256sum < "$hook" | cut -d ' ' -f 1)" '
        /kernel-updater\/hook\.sh$/ { sub(/^[0-9a-f]+/, lib) }
        /preinst\.d\/00-kernel-updater$/ { sub(/^[0-9a-f]+/, hook) }
        { print }' "$ROOT$MANIFEST" > "$BATS_TEST_TMPDIR/manifest"
    cp "$BATS_TEST_TMPDIR/manifest" "$ROOT$MANIFEST"
    # The update dies at the kernel hook, after it replaced hook.sh.
    real_mv=$(command -v mv)
    export REAL_MV=$real_mv
    mkstub mv <<'EOF'
[[ ${*: -1} != */etc/kernel/* ]] || exit 1
exec "$REAL_MV" "$@"
EOF
    run_install
    [ "$status" -ne 0 ]
    cmp "$REPO_DIR/lib/kernel-updater/hook.sh" "$old"
    # The manifest lists the old and the new hook.sh, so --uninstall takes the new one too.
    [ "$(grep -c 'kernel-updater/hook\.sh$' "$ROOT$MANIFEST")" -eq 2 ]
    run_install --uninstall --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would remove /usr/local/lib/kernel-updater/hook.sh"* ]]
    # And a rerun finishes the update and lists each file once again.
    rm "$STUB_BIN/mv"
    run_install
    [ "$status" -eq 0 ]
    [ "$(grep -c 'kernel-updater/hook\.sh$' "$ROOT$MANIFEST")" -eq 1 ]
    [ -z "$(find "$ROOT" -name '.kernel-updater.*')" ]
}

@test "The installed command finds its libraries and data under the prefix" {
    run_install
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$ROOT/usr/local/bin/kernel-updater" version
    [ "$status" -eq 0 ]
    [ "$output" = "kernel-updater $(< "$REPO_DIR/share/kernel-updater/VERSION")" ]
}

@test "A second run changes nothing" {
    run_install
    cp "$ROOT$MANIFEST" "$BATS_TEST_TMPDIR/manifest.first"
    run_install
    [ "$status" -eq 0 ]
    [[ "$stderr" == *": 0 new, 0 replaced, $(expected_count) unchanged and 0 removed"* ]]
    [[ "$stderr" != *"info: installed"* ]]
    cmp "$BATS_TEST_TMPDIR/manifest.first" "$ROOT$MANIFEST"
}

@test "A file in the way that kernel-updater did not install is refused, and nothing changes" {
    mkdir -p "$ROOT/etc/kernel/postinst.d"
    printf '#!/bin/sh\nexit 0\n' > "$ROOT/etc/kernel/postinst.d/kernel-updater"
    run_install
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"error: /etc/kernel/postinst.d/kernel-updater is in the way and was not"* ]]
    [[ "$stderr" == *"nothing was changed"* ]]
    [ ! -e "$ROOT/usr/local/bin/kernel-updater" ]
    [ ! -e "$ROOT$MANIFEST" ]
    # A directory in the way is refused as well.
    rm "$ROOT/etc/kernel/postinst.d/kernel-updater"
    mkdir -p "$ROOT/etc/apt/apt.conf.d/50kernel-updater"
    run_install
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"/etc/apt/apt.conf.d/50kernel-updater is no regular file"* ]]
}

@test "A file changed since it was installed is refused by an update and by --uninstall" {
    run_install
    printf '// changed by hand\n' >> "$ROOT/etc/apt/apt.conf.d/50kernel-updater"
    run_install
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"/etc/apt/apt.conf.d/50kernel-updater changed since kernel-updater"* ]]
    run_install --uninstall
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"restore or remove those files"* ]]
    [ -f "$ROOT/usr/local/bin/kernel-updater" ]
    [ -f "$ROOT$MANIFEST" ]
}

@test "An update replaces what the manifest lists and removes files the checkout no longer has" {
    local old hash
    run_install
    # Make the install look like an older one: a library with other contents, and a file this
    # checkout does not have, both listed in the manifest with their hashes.
    old="$ROOT/usr/local/lib/kernel-updater/hook.sh"
    printf '# an older hook.sh\n' > "$old"
    printf '# a library that went away\n' > "$ROOT/usr/local/lib/kernel-updater/gone.sh"
    hash=$(sha256sum < "$old" | cut -d ' ' -f 1)
    awk -v hash="$hash" '/kernel-updater\/hook\.sh$/ { sub(/^[0-9a-f]+/, hash) } { print }' \
        "$ROOT$MANIFEST" > "$BATS_TEST_TMPDIR/manifest"
    printf '%s  %s\n' "$(sha256sum < "$ROOT/usr/local/lib/kernel-updater/gone.sh" |
        cut -d ' ' -f 1)" /usr/local/lib/kernel-updater/gone.sh >> "$BATS_TEST_TMPDIR/manifest"
    cp "$BATS_TEST_TMPDIR/manifest" "$ROOT$MANIFEST"
    run_install
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: replaced /usr/local/lib/kernel-updater/hook.sh"* ]]
    [[ "$stderr" == *"info: removed /usr/local/lib/kernel-updater/gone.sh, which"* ]]
    cmp "$REPO_DIR/lib/kernel-updater/hook.sh" "$old"
    [ ! -e "$ROOT/usr/local/lib/kernel-updater/gone.sh" ]
    run grep -c 'gone\.sh' "$ROOT$MANIFEST"
    [ "$output" = 0 ]
}

@test "--uninstall removes exactly what the manifest lists, the APT configuration first" {
    run_install
    printf 'other\n' > "$ROOT/etc/kernel/postinst.d/other-hook"
    printf 'mine\n' > "$ROOT/usr/local/lib/kernel-updater/notes.txt"
    run_install --uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT$MANIFEST" ]
    [ ! -e "$ROOT/usr/local/bin/kernel-updater" ]
    [ ! -e "$ROOT/etc/apt/apt.conf.d/50kernel-updater" ]
    [ ! -e "$ROOT/etc/kernel/postinst.d/kernel-updater" ]
    [ ! -e "$ROOT/usr/local/share/kernel-updater" ]
    [ ! -e "$ROOT/var/lib/kernel-updater" ]
    # Files it did not install stay, and so do the directories that hold them.
    [ -f "$ROOT/etc/kernel/postinst.d/other-hook" ]
    [ -f "$ROOT/usr/local/lib/kernel-updater/notes.txt" ]
    [ -d "$ROOT/usr/local/bin" ]
    [ "$(find "$ROOT/usr/local/lib/kernel-updater" -type f | wc -l)" -eq 1 ]
    # The APT configuration goes first and the kernel hooks next, before the tool they run.
    mapfile -t removed < <(grep -o 'info: removed /[^ ]*' <<< "$stderr" | cut -d ' ' -f 3)
    [ "${removed[0]}" = /etc/apt/apt.conf.d/50kernel-updater ]
    [[ "${removed[1]}" == /etc/kernel/* && "${removed[4]}" == /etc/kernel/* ]]
    [[ "${removed[5]}" == /usr/local/* ]]
    [[ "$stderr" == *"kernel-updater is uninstalled; /etc/kernel-updater.conf stays"* ]]
    run_install --uninstall
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"kernel-updater is not installed"* ]]
}

@test "--dry-run changes nothing, when installing and when uninstalling" {
    run_install --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: would install /usr/local/bin/kernel-updater"* ]]
    [[ "$stderr" == *"dry run: $(expected_count) new, 0 replaced"*"nothing was changed"* ]]
    [ -z "$(find "$ROOT" -mindepth 1)" ]
    run_install
    run_install -n --uninstall
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"info: would remove /etc/apt/apt.conf.d/50kernel-updater"* ]]
    [ -f "$ROOT/etc/apt/apt.conf.d/50kernel-updater" ]
    [ -f "$ROOT$MANIFEST" ]
}

@test "install.sh warns that the hooks only warn until boot_fs_uuid is set" {
    run_install
    [[ "$stderr" == *"warning: the hooks only warn until boot_fs_uuid is set"* ]]
    mkdir -p "$ROOT/etc"
    printf '# boot_fs_uuid = 5ca1ab1e-0000-4000-8000-000000000b01\n' \
        > "$ROOT/etc/kernel-updater.conf"
    run_install
    [[ "$stderr" == *"warning: the hooks only warn"* ]]
    printf 'boot_fs_uuid = 5ca1ab1e-0000-4000-8000-000000000b01\n' \
        > "$ROOT/etc/kernel-updater.conf"
    run_install
    [ "$status" -eq 0 ]
    [[ "$stderr" != *warning* ]]
}

@test "install.sh refuses a damaged manifest, a non-root user and unknown arguments" {
    mkdir -p "$ROOT/var/lib/kernel-updater"
    printf 'not a manifest line\n' > "$ROOT$MANIFEST"
    run_install
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"install.manifest:1 is not a 'SHA256  /PATH' line"* ]]
    [ ! -e "$ROOT/usr/local/bin/kernel-updater" ]
    export ID_U=1000
    run_install
    [ "$status" -eq 77 ]
    run_install --prefix /opt
    [ "$status" -eq 64 ]
    [[ "$stderr" == *"Try './install.sh --help'."* ]]
    run_install --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: sudo ./install.sh "* ]]
}
