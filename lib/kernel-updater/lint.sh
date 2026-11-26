# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater lint
#
# The lint command: checks GRUB configs with grub-script-check when it is installed and with
# lint.awk for errors GRUB reports only at boot. Defines functions only.
# -------------------------------------------------------

# The awk that runs lint.awk. A seam for the tests, which run it under mawk and gawk, and so,
# like the seams of common.sh, taken from the environment only with KU_TEST=1: check runs lint
# as root, and a KU_AWK left in root's environment, as with sudo -E, must not choose what runs.
if [[ ${KU_TEST:-} == 1 ]]; then
    KU_AWK=${KU_AWK:-awk}
else
    KU_AWK="awk"
fi

# Print the lint command's usage on stdout.
ku_lint_usage() {
    cat << 'EOF'
Usage: kernel-updater lint [--floor VERSION] [--grub-dir DIR]... [--strict] [--porcelain] FILE...

Checks GRUB config files for errors GRUB reports only at boot: syntax errors (through
grub-script-check from grub-common, when it is installed), unknown commands and modules,
malformed or misused LUKS and filesystem UUIDs, kernel parameters that do nothing, and
hard-coded drives. Findings name the kind of identifier, never its value.

  --floor VERSION  oldest GRUB the files must run on: 2.02 (the default), 2.06, 2.12 or 2.14
  --grub-dir DIR   take command and module names from DIR/command.lst and DIR/moddep.lst
                   instead of GRUB 2.02's; repeat it for each platform, for example the
                   stick's multibootusb/grub/i386-pc and multibootusb/grub/x86_64-efi
  --strict         exit 2 on warnings too
  --porcelain      print FILE, LINE, SEVERITY, RULE and MESSAGE, tab-separated

Unknown names are errors with GRUB 2.02's lists or --grub-dir, and warnings with a newer
--floor and no --grub-dir. Exits 0 when no file has an error, 2 when one has, 64 on a usage
error and 66 when a FILE or a list cannot be read.
EOF
}

# Lint every FILE and print the findings on stdout, file by file and sorted by line, then a
# summary on stderr. Exits 0 when no file has an error (or, with --strict, a warning), 2 when
# one has, 64 on a usage error and 66 when a FILE or a list from --grub-dir cannot be read.
ku_cmd_lint() {
    local floor="" strict=0 syntax=1 exact=0 errors=0 warnings=0
    local file findings ln severity rule message
    local -a files=() cmds=() mods=()
    while (( $# )); do
        case $1 in
            --floor | --grub-dir)
                (( $# >= 2 )) || ku_usage_error "lint: $1 needs a value"
                if [[ $1 == --floor ]]; then
                    floor=$2
                else
                    cmds+=("$2/command.lst") mods+=("$2/moddep.lst")
                fi
                shift 2
                ;;
            --floor=*) floor=${1#*=}; shift ;;
            --grub-dir=*) cmds+=("${1#*=}/command.lst") mods+=("${1#*=}/moddep.lst"); shift ;;
            --strict) strict=1; shift ;;
            --porcelain) KU_PORCELAIN=1; shift ;;
            -h | --help) ku_lint_usage; exit 0 ;;
            --) shift; files+=("$@"); break ;;
            -*) ku_usage_error "lint: unknown option $1" ;;
            *) files+=("$1"); shift ;;
        esac
    done
    (( ${#files[@]} )) || ku_usage_error "lint: no file given"
    ku_load_config
    floor=${floor:-${KU_CONF[grub_floor]}}
    _ku_valid_grub_version "$floor" || ku_usage_error "lint: --floor takes 2.02, 2.06, 2.12 or 2.14"
    if (( ${#cmds[@]} )); then
        exact=1
    else
        cmds=("$KU_SHAREDIR/grub-2.02/commands.txt") mods=("$KU_SHAREDIR/grub-2.02/modules.txt")
    fi
    for file in "${cmds[@]}" "${mods[@]}" "${files[@]}"; do
        [[ -f $file && -r $file ]] || ku_die "$KU_EX_NOINPUT" "lint: cannot read $file"
    done
    if ! command -v grub-script-check > /dev/null; then
        syntax=0
        ku_log warning "grub-script-check (Debian package grub-common) is not installed; syntax is not checked"
    fi
    for file in "${files[@]}"; do
        findings=$(_ku_lint_file "$file" "$floor" "$syntax" "$exact" \
            "$(printf '%s\n' "${cmds[@]}")" "$(printf '%s\n' "${mods[@]}")")
        [[ -n $findings ]] || continue
        while IFS=$'\t' read -r ln severity rule message; do
            case $severity in
                error) errors=$((errors + 1)) ;;
                warning) warnings=$((warnings + 1)) ;;
            esac
            if (( KU_PORCELAIN )); then
                printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$ln" "$severity" "$rule" "$message"
            else
                printf '%s:%s: %s: %s [%s]\n' "$file" "$ln" "$severity" "$message" "$rule"
            fi
        done <<< "$findings"
    done
    ku_log info "lint: ${#files[@]} file(s), $errors error(s), $warnings warning(s)"
    if (( errors || (strict && warnings) )); then
        exit "$KU_EX_FINDINGS"
    fi
}

# Print the findings for FILE as lint does, as LINE<TAB>SEVERITY<TAB>RULE<TAB>MESSAGE lines
# sorted by line: for GRUB FLOOR, with grub-script-check when SYNTAX is 1, and with the command
# and module names of GRUB_DIR's command.lst and moddep.lst, as --grub-dir takes them, or with
# GRUB 2.02's when GRUB_DIR is empty. Shared with check's kali-cfg item.
ku_lint_findings() {
    local file=$1 floor=$2 syntax=$3 dir=${4-}
    if [[ -n $dir ]]; then
        _ku_lint_file "$file" "$floor" "$syntax" 1 "$dir/command.lst" "$dir/moddep.lst"
    else
        _ku_lint_file "$file" "$floor" "$syntax" 0 "$KU_SHAREDIR/grub-2.02/commands.txt" \
            "$KU_SHAREDIR/grub-2.02/modules.txt"
    fi
}

# Print the findings for FILE as LINE<TAB>SEVERITY<TAB>RULE<TAB>MESSAGE lines sorted by line:
# a rejection by grub-script-check when SYNTAX is 1, then those of lint.awk, which reads the
# name lists CMD_LISTS and MOD_LISTS (newline-separated paths). Never echoes the file's text.
# When boot_fs_uuid and boot_luks_uuid name the same UUID, /boot's filesystem has its
# container's UUID, so lint.awk does not warn when search --fs-uuid is given that one.
_ku_lint_file() {
    local file=$1 floor=$2 syntax=$3 exact=$4 cmd_lists=$5 mod_lists=$6 out ln=1 same=""
    local fs=${KU_CONF[boot_fs_uuid]-} luks=${KU_CONF[boot_luks_uuid]-}
    if [[ -n $fs && ${fs//-/} == "${luks//-/}" ]]; then
        same=${fs//-/}
    fi
    {
        if (( syntax )) && ! out=$(LC_ALL=C grub-script-check "$file" 2>&1); then
            if [[ $out =~ line\ ([0-9]+) ]]; then
                ln=${BASH_REMATCH[1]}
            fi
            printf '%s\terror\tsyntax\tgrub-script-check rejects the file: a syntax error, or no commands at all\n' "$ln"
        fi
        KU_LINT_CFG=$file KU_LINT_CMDS=$cmd_lists KU_LINT_MODS=$mod_lists KU_LINT_FLOOR=$floor \
            KU_LINT_EXACT=$exact KU_LINT_SAME_UUID=$same "$KU_AWK" -f "$KU_LIBDIR/lint.awk"
    } | sort -t $'\t' -k1,1n -s
}
