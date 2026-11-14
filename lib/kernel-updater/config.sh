# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater configuration
#
# Reads /etc/kernel-updater.conf: "key = value" lines, lines that start with # and blank
# lines. The file is parsed, never sourced, and every value must pass its key's check.
# -------------------------------------------------------

# Known keys and the check their values must pass (the _ku_valid_* function of that name),
# and the defaults; an empty default leaves an optional key unset. Later phases add keys here.
declare -gA KU_CONF_SCHEMA=([grub_floor]=grub_version [boot_fs_uuid]=uuid [boot_luks_uuid]=uuid
    [verify_action]=verify_action [disk_ptuuid]=ptuuid [p1_fs_uuid]=ntfs_serial [deploy]=deploy
    [p1_path]=abs_path [output_dir]=abs_path [backups_keep]=count [root_device]=root_device
    [menu_variants]=menu_variants [previous_variants]=variants [quarantine_days]=days)
declare -gA KU_CONF=([grub_floor]=2.02 [boot_fs_uuid]="" [boot_luks_uuid]="" [verify_action]=fail
    [disk_ptuuid]="" [p1_fs_uuid]="" [deploy]=auto [p1_path]=""
    [output_dir]=/root/kernel-updater/out [backups_keep]=5 [root_device]=""
    [menu_variants]="default,failsafe" [previous_variants]="default,failsafe"
    [quarantine_days]=30)

# The keys the config file read last sets, each with its line number, so that migrate can tell
# a key the file sets from a default.
# shellcheck disable=SC2034 # read by migrate
declare -gA KU_CONF_SET=()

# The config file named by --config, or empty for the default path. Set by the option parser.
KU_CONFIG_FILE=""

# Load the config file a command runs with: the one given with --config, which must exist
# (else exit 78), or /etc/kernel-updater.conf under KU_ROOT, whose absence keeps the defaults.
ku_load_config() {
    if [[ -n $KU_CONFIG_FILE ]]; then
        [[ -e $KU_CONFIG_FILE ]] || ku_die "$KU_EX_CONFIG" "config file $KU_CONFIG_FILE not found"
        ku_config_load "$KU_CONFIG_FILE"
    else
        ku_config_load "$(ku_path /etc/kernel-updater.conf)"
    fi
}

# Read FILE into KU_CONF. A missing FILE keeps the defaults; an unknown key is ignored with a
# warning. Exits 78 when FILE cannot be read, a line is not "key = value", a value fails its
# check, a key repeats, or, as root, FILE is not owned by root or is writable by group or
# others. The checks and the reads use one open file, so a swap in between cannot slip by.
ku_config_load() {
    local file=$1 fd line key value n=0
    # A key is lower case letters, digits, as in p1_path, and underscores, but no leading digit.
    local re='^[[:space:]]*([a-z_][a-z0-9_]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$'
    local -A seen=()
    KU_CONF_SET=()
    if [[ ! -e $file ]]; then
        ku_log debug "no config file at $file; using the defaults"
        return 0
    fi
    [[ -f $file && -r $file ]] || ku_die "$KU_EX_CONFIG" "cannot read the config file $file"
    exec {fd}< "$file"
    _ku_config_check_owner "$file" "/dev/fd/$fd"
    while IFS= read -r line <&"$fd" || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! $line =~ $re ]]; then
            ku_die "$KU_EX_CONFIG" "$file:$n: expected a 'key = value' line"
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        if [[ -z ${KU_CONF_SCHEMA[$key]+set} ]]; then
            ku_log warning "$file:$n: unknown key '$key' ignored"
            continue
        fi
        [[ -z ${seen[$key]+set} ]] || ku_die "$KU_EX_CONFIG" "$file:$n: '$key' is set twice"
        seen[$key]=$n
        "_ku_valid_${KU_CONF_SCHEMA[$key]}" "$value" ||
            ku_die "$KU_EX_CONFIG" "$file:$n: invalid value for '$key'"
        # UUIDs and disk signatures are kept lower case, as blkid, cryptsetup and lsblk print
        # them, and NTFS serials upper case, as blkid prints those.
        case ${KU_CONF_SCHEMA[$key]} in
            uuid | ptuuid) value=${value,,} ;;
            ntfs_serial) value=${value^^} ;;
            # A path loses its trailing slashes, so that output_dir/ names its directory and
            # not, to mkdir, its own parent.
            abs_path)
                while [[ $value == ?*/ ]]; do
                    value=${value%/}
                done
                ;;
            # A list of variants loses the blanks around its commas.
            menu_variants | variants) value=${value//[[:space:]]/} ;;
        esac
        # shellcheck disable=SC2034 # read by the commands
        KU_CONF[$key]=$value
        # shellcheck disable=SC2034 # read by migrate
        KU_CONF_SET[$key]=$n
    done
    exec {fd}<&-
}

# When run as root, exit 78 if the open config file (OPENED, a /dev/fd path for NAME) is not
# owned by root or group or others can write it: the configuration steers what root does.
_ku_config_check_owner() {
    local name=$1 opened=$2 info owner mode
    [[ $(id -u) == 0 ]] || return 0
    info=$(stat -L -c '%u %a' -- "$opened") || ku_die "$KU_EX_CONFIG" "cannot stat the config file $name"
    read -r owner mode <<< "$info"
    [[ $owner == 0 ]] || ku_die "$KU_EX_CONFIG" "the config file $name must be owned by root"
    (( (8#$mode & 8#022) == 0 )) ||
        ku_die "$KU_EX_CONFIG" "the config file $name must not be writable by group or others"
}

# A GRUB version whose features lint and check know: 2.02, 2.06, 2.12 or 2.14.
_ku_valid_grub_version() {
    [[ $1 =~ ^2\.(02|06|12|14)$ ]]
}

# A filesystem or LUKS UUID in the 8-4-4-4-12 hex form blkid and cryptsetup print, in either
# case.
_ku_valid_uuid() {
    [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# What the kernel postinst hook does when a new kernel would not boot: fail, which stops the
# package's configuration, or warn.
_ku_valid_verify_action() {
    [[ $1 =~ ^(fail|warn)$ ]]
}

# A disk's PTUUID as lsblk prints it: an MBR disk's 32-bit disk signature, 8 hex digits, or a
# GPT disk's UUID in the 8-4-4-4-12 form, in either case.
_ku_valid_ptuuid() {
    [[ $1 =~ ^[0-9A-Fa-f]{8}$ ]] || _ku_valid_uuid "$1"
}

# An NTFS volume serial as blkid prints it: 16 hex digits, in either case.
_ku_valid_ntfs_serial() {
    [[ $1 =~ ^[0-9A-Fa-f]{16}$ ]]
}

# How a writer deploys to partition 1: auto, direct, export or path.
_ku_valid_deploy() {
    [[ $1 =~ ^(auto|direct|export|path)$ ]]
}

# An absolute path without control characters and without . or .. components.
_ku_valid_abs_path() {
    [[ $1 == /* && $1 != *[[:cntrl:]]* && /$1/ != */./* && /$1/ != */../* ]]
}

# How many backups of a file on partition 1 to keep: 1 to 99.
_ku_valid_count() {
    [[ $1 =~ ^[1-9][0-9]?$ ]]
}

# How many days a module tree stays in cleanup's quarantine once a later run saw it: 0 to 999,
# where 0 keeps it until it is deleted by hand. A leading zero is refused, as bash arithmetic
# would read 030 as octal and 08 as no number at all.
_ku_valid_days() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,2})$ ]]
}

# What the Kali kernel line gets as root=: an absolute device path without . or ..
# components, made of letters, digits and ._+:@- between its slashes, such as
# /dev/mapper/kali--vg-root, or UUID= and a UUID in the 8-4-4-4-12 form.
_ku_valid_root_device() {
    if [[ $1 == UUID=* ]]; then
        _ku_valid_uuid "${1#UUID=}"
    else
        [[ $1 =~ ^(/[A-Za-z0-9._+:@-]+)+$ && /$1/ != */./* && /$1/ != */../* ]]
    fi
}

# The variants of the Kali entries migrate writes: a list as _ku_valid_variants takes it that
# starts with default.
_ku_valid_menu_variants() {
    _ku_valid_variants "$1" && [[ ${1//[[:space:]]/} =~ ^default(,|$) ]]
}

# A comma-separated list of the variants default, failsafe, live and forensic, each named once,
# with blanks allowed around the commas.
_ku_valid_variants() {
    local item commas=${1//[^,]/}
    local -a items=()
    local -A seen=()
    IFS=, read -r -a items <<< "$1"
    # read drops an empty last field, so a trailing comma shows only in the count.
    (( ${#items[@]} && ${#commas} == ${#items[@]} - 1 )) || return 1
    for item in "${items[@]}"; do
        item=${item#"${item%%[![:space:]]*}"}
        item=${item%"${item##*[![:space:]]}"}
        [[ $item =~ ^(default|failsafe|live|forensic)$ && -z ${seen[$item]+set} ]] || return 1
        seen[$item]=1
    done
}
