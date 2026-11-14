#!/bin/bash
# -------------------------------------------------------
# kernel-updater installer
#
# Installs kernel-updater from this checkout: the command in /usr/local/bin, its libraries and
# data in /usr/local/lib and /usr/local/share, the kernel hooks in /etc/kernel and apt-guard's
# APT configuration. A manifest records every file with its SHA-256, and --uninstall removes
# exactly what it lists. A file in the way that it did not install, or that changed since it
# did, makes it refuse before it changes anything.
# -------------------------------------------------------

set -Eeuo pipefail
shopt -s inherit_errexit

KU_SRC=$(readlink -f -- "${BASH_SOURCE[0]}")
KU_SRC=${KU_SRC%/*}
# shellcheck source=lib/kernel-updater/common.sh
. "$KU_SRC/lib/kernel-updater/common.sh"

# Where the tool goes, and the manifest, which lives outside the prefix so --uninstall finds it.
KI_PREFIX=/usr/local
KI_MANIFEST=/var/lib/kernel-updater/install.manifest

# The files to install, in order: the source in the checkout, the target and its mode.
KI_SRC=() KI_DEST=() KI_MODE=()
# The installed manifest's entries: each target and the SHA-256 sums, space-separated, of the
# contents it may have; a run that was cut short leaves two, the old and the new. And the
# temporary file being written.
declare -A KI_OLD=()
KI_TMP=""

# Print the usage on stdout.
ki_usage() {
    cat << 'EOF'
Usage: sudo ./install.sh [--dry-run] [--uninstall]

Installs kernel-updater from this checkout under /usr/local, its kernel hooks in /etc/kernel
and apt-guard in /etc/apt/apt.conf.d, and lists every file with its SHA-256 in
/var/lib/kernel-updater/install.manifest. Run it again after updating the checkout.

  -n, --dry-run   print what would change, change nothing
      --uninstall remove every file the manifest lists; /etc/kernel-updater.conf stays
  -h, --help      show this help

Refuses with exit 3, changing nothing, when a file in the way was not installed by
kernel-updater or changed since. Exits 64 on a usage error, 66 when the checkout lacks a file,
75 when another kernel-updater run holds the lock and 77 when not run as root.
EOF
}

# Log MESSAGE as an error, point at --help and exit 64.
ki_usage_error() {
    ku_log error "$*"
    printf "Try './install.sh --help'.\n" >&2 || true
    exit "$KU_EX_USAGE"
}

# Parse the options, then install or uninstall as root, under the single-instance lock.
ki_main() {
    local uninstall=0
    while (( $# )); do
        case $1 in
            -n | --dry-run) KU_DRY_RUN=1 ;;
            --uninstall) uninstall=1 ;;
            -h | --help) ki_usage; exit 0 ;;
            *) ki_usage_error "unknown argument '$1'" ;;
        esac
        shift
    done
    ku_install_traps
    ku_cleanup_add _ki_cleanup
    ku_require_root
    ku_lock
    umask 022
    _ki_read_manifest
    if (( uninstall )); then
        _ki_uninstall
    else
        _ki_install
    fi
}

# Exit trap: remove the temporary file a cut-short copy left behind.
_ki_cleanup() {
    [[ -z $KI_TMP ]] || rm -f -- "$KI_TMP"
}

# Read the manifest into KI_OLD. A target may be listed more than once. Exits 3 when a line is
# not "SHA256  /PATH".
_ki_read_manifest() {
    local file line n=0 re='^([0-9a-f]{64})  (/[^[:cntrl:]]+)$'
    file=$(ku_path "$KI_MANIFEST")
    [[ -e $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ $re ]] ||
            ku_die "$KU_EX_REFUSED" "$KI_MANIFEST:$n is not a 'SHA256  /PATH' line; nothing was changed"
        KI_OLD[${BASH_REMATCH[2]}]+="${KI_OLD[${BASH_REMATCH[2]}]:+ }${BASH_REMATCH[1]}"
    done < "$file"
}

# Return 0 when the manifest lists TARGET with the SHA-256 HASH.
_ki_listed() {
    [[ " ${KI_OLD[$1]-} " == *" $2 "* ]]
}

# Print the manifest lines that list TARGET with each SHA-256 the manifest has for it, but
# SKIP.
_ki_old_lines() {
    local hash
    for hash in ${KI_OLD[$1]-}; do
        [[ $hash == "${2-}" ]] || printf '%s  %s\n' "$hash" "$1"
    done
}

# Print the SHA-256 of FILE.
_ki_hash() {
    local out
    out=$(sha256sum -- "$1")
    printf '%s' "${out%% *}"
}

# Add SOURCE, a path in the checkout, to the files to install as TARGET with MODE. Exits 66
# when the checkout lacks it.
_ki_add() {
    [[ -f $KU_SRC/$1 ]] || ku_die "$KU_EX_NOINPUT" "the checkout lacks $1"
    KI_SRC+=("$1")
    KI_DEST+=("$2")
    KI_MODE+=("$3")
}

# List the files to install in the order they go in: the libraries and data first, then the
# command that sources them, apt-guard and the kernel hooks that run the command, and last the
# APT configuration that runs apt-guard. So no file is ever run before what it needs is in.
_ki_plan() {
    local file
    for file in "$KU_SRC"/lib/kernel-updater/*.sh "$KU_SRC"/lib/kernel-updater/*.awk; do
        file=${file#"$KU_SRC"/}
        _ki_add "$file" "$KI_PREFIX/$file" 644
    done
    while IFS= read -r -d '' file; do
        file=${file#"$KU_SRC"/}
        _ki_add "$file" "$KI_PREFIX/$file" 644
    done < <(find "$KU_SRC/share/kernel-updater" -type f -print0 | sort -z)
    _ki_add bin/kernel-updater "$KI_PREFIX/bin/kernel-updater" 755
    _ki_add lib/kernel-updater/apt-guard "$KI_PREFIX/lib/kernel-updater/apt-guard" 755
    for file in "$KU_SRC"/hooks/kernel/*.d/*; do
        file=${file#"$KU_SRC"/}
        _ki_add "$file" "/etc/kernel/${file#hooks/kernel/}" 755
    done
    _ki_add hooks/apt/50kernel-updater /etc/apt/apt.conf.d/50kernel-updater 644
}

# Install or update the files. Refuses with exit 3, before changing anything, when a target is
# no regular file, or holds something other than what the manifest or this checkout says.
# Files the manifest lists that this checkout no longer has are removed, when unchanged.
# Before it changes a file it lists both the old and the new contents of each target in the
# manifest, so a run cut short leaves nothing that a rerun or --uninstall would not accept.
_ki_install() {
    local i dest target new cur file conflict manifest="" both="" count_new=0 count_replaced=0
    local count_same=0 version done_verb
    local -a action=() obsolete=() conflicts=()
    local -A planned=()
    _ki_plan
    for i in "${!KI_DEST[@]}"; do
        dest=${KI_DEST[i]}
        planned[$dest]=1
        target=$(ku_path "$dest")
        new=$(_ki_hash "$KU_SRC/${KI_SRC[i]}")
        manifest+="$new  $dest"$'\n'
        both+="$new  $dest"$'\n'$(_ki_old_lines "$dest" "$new")
        both=${both%$'\n'}$'\n'
        if [[ ! -e $target && ! -L $target ]]; then
            action[i]=install
        elif [[ -L $target || ! -f $target ]]; then
            conflicts+=("$dest is no regular file")
        else
            cur=$(_ki_hash "$target")
            if [[ $cur == "$new" && $(stat -c %a -- "$target") == "${KI_MODE[i]}" ]]; then
                action[i]=keep
            elif [[ $cur == "$new" ]] || _ki_listed "$dest" "$cur"; then
                action[i]=replace
            elif [[ -n ${KI_OLD[$dest]+set} ]]; then
                conflicts+=("$dest changed since kernel-updater installed it")
            else
                conflicts+=("$dest is in the way and was not installed by kernel-updater")
            fi
        fi
    done
    for dest in "${!KI_OLD[@]}"; do
        [[ -z ${planned[$dest]+set} ]] || continue
        target=$(ku_path "$dest")
        if [[ ! -e $target && ! -L $target ]]; then
            continue
        elif [[ -L $target || ! -f $target ]] || ! _ki_listed "$dest" "$(_ki_hash "$target")"; then
            conflicts+=("$dest changed since kernel-updater installed it")
        else
            obsolete+=("$dest")
            both+=$(_ki_old_lines "$dest")$'\n'
        fi
    done
    if (( ${#conflicts[@]} )); then
        for conflict in "${conflicts[@]}"; do
            ku_log error "$conflict"
        done
        ku_die "$KU_EX_REFUSED" "move those files away, then run install.sh again; nothing was changed"
    fi
    file=$(ku_path "$KI_MANIFEST")
    if (( ! KU_DRY_RUN )) && [[ ! -f $file || $(< "$file")$'\n' != "$manifest" ]]; then
        _ki_write "$file" "$both"
    fi
    for i in "${!KI_DEST[@]}"; do
        case ${action[i]} in
            keep) count_same=$((count_same + 1)); continue ;;
            install) count_new=$((count_new + 1)) done_verb=installed ;;
            replace) count_replaced=$((count_replaced + 1)) done_verb=replaced ;;
        esac
        if (( KU_DRY_RUN )); then
            ku_log info "would ${action[i]} ${KI_DEST[i]}"
        else
            _ki_put "$KU_SRC/${KI_SRC[i]}" "$(ku_path "${KI_DEST[i]}")" "${KI_MODE[i]}"
            ku_log info "$done_verb ${KI_DEST[i]}"
        fi
    done
    for dest in "${obsolete[@]}"; do
        if (( KU_DRY_RUN )); then
            ku_log info "would remove $dest, which kernel-updater no longer has"
        else
            rm -f -- "$(ku_path "$dest")"
            ku_log info "removed $dest, which kernel-updater no longer has"
        fi
    done
    if [[ ! -f $file || $(< "$file")$'\n' != "$manifest" ]]; then
        if (( KU_DRY_RUN )); then
            ku_log info "would write $KI_MANIFEST"
        else
            _ki_write "$file" "$manifest"
        fi
    fi
    version=$(< "$KU_SRC/share/kernel-updater/VERSION")
    if (( KU_DRY_RUN )); then
        ku_log info "kernel-updater $version, dry run: $count_new new, $count_replaced replaced," \
            "$count_same unchanged and ${#obsolete[@]} removed file(s); nothing was changed"
    else
        sync
        ku_log info "kernel-updater $version is installed: $count_new new, $count_replaced" \
            "replaced, $count_same unchanged and ${#obsolete[@]} removed file(s)"
    fi
    if ! grep -Eq '^[[:space:]]*boot_fs_uuid[[:space:]]*=' \
        "$(ku_path /etc/kernel-updater.conf)" 2> /dev/null; then
        ku_log warning "the hooks only warn until boot_fs_uuid is set in" \
            "/etc/kernel-updater.conf; examples/kernel-updater.conf shows how"
    fi
}

# Remove every file the manifest lists: the APT configuration first and the kernel hooks next,
# so nothing runs a file already gone, then the manifest, the tool's library and data
# directories once they are empty, and /var/lib/kernel-updater only when nothing else is left in
# it: the baseline and cleanup's quarantine stay, empty directories in a quarantined module tree
# included. Refuses with exit 3, before removing anything, when a listed file changed since.
_ki_uninstall() {
    local dest target conflict dir state=0
    local -a order=() present=() conflicts=()
    if [[ ! -e $(ku_path "$KI_MANIFEST") ]]; then
        ku_log info "kernel-updater is not installed: $KI_MANIFEST does not exist"
        return 0
    fi
    mapfile -t order < <(for dest in "${!KI_OLD[@]}"; do
        case $dest in
            /etc/apt/*) printf '1 %s\n' "$dest" ;;
            /etc/kernel/*) printf '2 %s\n' "$dest" ;;
            *) printf '3 %s\n' "$dest" ;;
        esac
    done | sort | cut -d ' ' -f 2-)
    for dest in "${order[@]}"; do
        target=$(ku_path "$dest")
        if [[ ! -e $target && ! -L $target ]]; then
            continue
        elif [[ -L $target || ! -f $target ]] || ! _ki_listed "$dest" "$(_ki_hash "$target")"; then
            conflicts+=("$dest changed since kernel-updater installed it")
        else
            present+=("$dest")
        fi
    done
    if (( ${#conflicts[@]} )); then
        for conflict in "${conflicts[@]}"; do
            ku_log error "$conflict"
        done
        ku_die "$KU_EX_REFUSED" "restore or remove those files, then run install.sh --uninstall" \
            "again; nothing was changed"
    fi
    for dest in "${present[@]}"; do
        if (( KU_DRY_RUN )); then
            ku_log info "would remove $dest"
        else
            rm -f -- "$(ku_path "$dest")"
            ku_log info "removed $dest"
        fi
    done
    if (( KU_DRY_RUN )); then
        ku_log info "would remove $KI_MANIFEST and the empty kernel-updater directories"
        return 0
    fi
    rm -f -- "$(ku_path "$KI_MANIFEST")"
    # Only directories of the tool's own, and only empty ones.
    for dir in "$KI_PREFIX/lib/kernel-updater" "$KI_PREFIX/share/kernel-updater"; do
        dir=$(ku_path "$dir")
        if [[ -d $dir ]]; then
            find "$dir" -depth -type d -empty -delete
        fi
    done
    # The state directory goes only when it is empty: an empty directory within it may belong
    # to a module tree in cleanup's quarantine, which a move back must find as it was.
    dir=$(ku_path "${KI_MANIFEST%/*}")
    if [[ -d $dir ]] && ! rmdir -- "$dir" 2> /dev/null; then
        state=1
    fi
    sync
    ku_log info "kernel-updater is uninstalled; /etc/kernel-updater.conf stays"
    if (( state )); then
        ku_log info "${KI_MANIFEST%/*} stays, with what kernel-updater keeps there besides the" \
            "manifest, such as the baseline and the module trees cleanup moved into its quarantine"
    fi
}

# Write SOURCE to TARGET with MODE through a temporary file in TARGET's directory renamed over
# it, so TARGET is never seen half written.
_ki_put() {
    local source=$1 target=$2 mode=$3 dir
    dir=${target%/*}
    mkdir -p -- "$dir"
    KI_TMP=$(mktemp -- "$dir/.kernel-updater.XXXXXXXX")
    cp -- "$source" "$KI_TMP"
    chmod -- "$mode" "$KI_TMP"
    mv -f -- "$KI_TMP" "$target"
    KI_TMP=""
}

# Write the TEXT of the manifest to FILE, mode 644, as _ki_put writes a file.
_ki_write() {
    local file=$1 text=$2 dir
    dir=${file%/*}
    mkdir -p -- "$dir"
    KI_TMP=$(mktemp -- "$dir/.install.manifest.XXXXXXXX")
    printf '%s' "$text" > "$KI_TMP"
    chmod -- 644 "$KI_TMP"
    mv -f -- "$KI_TMP" "$file"
    KI_TMP=""
}

ki_main "$@"
