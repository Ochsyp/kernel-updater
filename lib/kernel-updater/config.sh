# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater configuration
#
# Reads /etc/kernel-updater.conf: "key = value" lines, lines that start with # and blank
# lines. The file is parsed, never sourced, and every value must pass its key's check.
# -------------------------------------------------------

# Known keys and the check their values must pass (the _ku_valid_* function of that name),
# and the defaults; an empty default leaves an optional key unset. Later phases add keys here.
declare -gA KU_CONF_SCHEMA=([grub_floor]=grub_version [boot_fs_uuid]=uuid [boot_luks_uuid]=uuid)
declare -gA KU_CONF=([grub_floor]=2.02 [boot_fs_uuid]="" [boot_luks_uuid]="")

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
    local -A seen=()
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
        if [[ ! $line =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
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
        # UUIDs are kept lower case, as blkid and cryptsetup print them.
        [[ ${KU_CONF_SCHEMA[$key]} != uuid ]] || value=${value,,}
        # shellcheck disable=SC2034 # read by the commands
        KU_CONF[$key]=$value
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
