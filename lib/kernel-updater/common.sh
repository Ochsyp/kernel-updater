# shellcheck shell=bash
# -------------------------------------------------------
# kernel-updater common library
#
# Exit codes, logging and plan lines, the dry-run and confirmation rails, the root check, the
# single-instance lock, exit traps, and path, list and SHA-256 helpers. Defines functions and
# settings only.
# -------------------------------------------------------

# Exit codes, the same for every command and listed in the README; the global options set
# the verbosity (0 quiet, 1 normal, 2 verbose) and the other switches.
# shellcheck disable=SC2034 # read by the files that source this library
declare -g KU_EX_FAILURE=1 KU_EX_FINDINGS=2 KU_EX_REFUSED=3 KU_EX_WRITE=4 KU_EX_DECLINED=10 \
    KU_EX_USAGE=64 KU_EX_NOINPUT=66 KU_EX_BUSY=75 KU_EX_NOPERM=77 KU_EX_CONFIG=78 \
    KU_VERBOSITY=1 KU_DRY_RUN=0 KU_ASSUME_YES=0 KU_PORCELAIN=0

# Seams for the tests: the root every system path is resolved under, the terminal
# confirmations are read from, and the lock file. They come from the environment only with
# KU_TEST=1, which the tests set, so a KU_ROOT alone left in root's environment, as with
# sudo -E, never steers what the tool and the hooks dpkg and apt run as root read or write; one
# that comes with KU_TEST=1 does.
if [[ ${KU_TEST:-} == 1 ]]; then
    KU_ROOT=${KU_ROOT:-/}
    KU_TTY=${KU_TTY:-/dev/tty}
    KU_LOCKFILE=${KU_LOCKFILE:-/run/kernel-updater.lock}
else
    KU_ROOT=/ KU_TTY=/dev/tty KU_LOCKFILE=/run/kernel-updater.lock
fi

# How the lines that say what to run next name this tool: sudo and the path it was started
# from, resolved through any symlink and shell-quoted, which bin/kernel-updater sets as
# KU_SELF, or the installed path for code started without it. Never the bare name: sudo's
# secure_path may lack /usr/local/bin, as on Kali, and then answers "command not found".
# shellcheck disable=SC2034 # read by the files that source this library
printf -v KU_CMD 'sudo %q' "${KU_SELF:-/usr/local/bin/kernel-updater}"

# Functions ku_on_exit runs when the process ends, in reverse order of registration.
KU_CLEANUP=()

# The descriptor ku_ask reads the answers from, once it opened KU_TTY.
KU_TTY_FD=""

# A kernel release as uname -r prints it. Anything else is refused before it reaches a path
# or a command line.
KU_RELEASE_RE='^[0-9]+\.[0-9]+[0-9A-Za-z.+~_-]*$'

# =======================================================
#                       MESSAGES
# =======================================================

# Print "kernel-updater: LEVEL: MESSAGE" on stderr. info is dropped by --quiet and debug is
# shown only with --verbose. A closed stderr never turns a log line into a failure.
ku_log() {
    local level=$1
    shift
    case $level in
        debug) (( KU_VERBOSITY >= 2 )) || return 0 ;;
        info) (( KU_VERBOSITY >= 1 )) || return 0 ;;
    esac
    printf 'kernel-updater: %s: %s\n' "$level" "$*" >&2 || true
}

# Log MESSAGE as an error and exit with CODE. Call it in the main shell: inside $(...) the
# subshell's code reaches the caller only as a failure, which the ERR trap turns into 1.
ku_die() {
    local code=$1
    shift
    ku_log error "$*"
    exit "$code"
}

# Log MESSAGE as an error, point at --help, by the resolved path of the tool and without
# sudo, which --help needs not, and exit 64.
ku_usage_error() {
    ku_log error "$*"
    printf "Try '%s --help'.\n" "${KU_CMD#sudo }" >&2 || true
    exit "$KU_EX_USAGE"
}

# Print one line of a plan on stderr, whatever the verbosity, since a question follows it.
ku_plan() {
    printf 'kernel-updater: plan: %s\n' "$*" >&2 || true
}

# Print the WORDS as a list: "a", "a and b", "a, b and c".
ku_join() {
    local text=$1
    shift
    while (( $# > 1 )); do
        text+=", $1"
        shift
    done
    if (( $# )); then
        text+=" and $1"
    fi
    printf '%s' "$text"
}

# =======================================================
#                        RAILS
# =======================================================

# Run a command, or with --dry-run only print it on stderr, each argument shell-quoted.
# Returns the command's status; a dry run returns 0.
ku_run() {
    local quoted
    printf -v quoted ' %q' "$@"
    if (( KU_DRY_RUN )); then
        printf 'kernel-updater: would run:%s\n' "$quoted" >&2
        return 0
    fi
    ku_log debug "run:$quoted"
    "$@"
}

# Ask PROMPT on the terminal and return 0 on "y" or "yes" and 1 on any other answer; --yes
# answers yes for the user. Exits 10 when no terminal can be read, so nothing runs unconfirmed.
# The terminal stays open for the questions that follow, so that each reads the next line, of
# the terminal or of a file of answers, as the tests use.
ku_ask() {
    local answer=""
    if (( KU_ASSUME_YES )); then
        return 0
    fi
    _ku_tty_open "no terminal to confirm on; pass --yes to go ahead unattended"
    printf '%s [y/N] ' "$1" >&2
    _ku_tty_answer answer
    case ${answer,,} in
        y | yes) return 0 ;;
    esac
    return 1
}

# Ask PROMPT, all words given, on the terminal as ku_ask does, but always: --yes does not answer
# it, since it asks whether the person checked something outside this system. Returns 0 on "y"
# or "yes"; exits 10 on any other answer or when no terminal can be read.
ku_ask_person() {
    local answer=""
    _ku_tty_open "no terminal to answer on, which --yes does not do for this question;" \
        "nothing was changed"
    printf '%s [y/N] ' "$*" >&2
    _ku_tty_answer answer
    case ${answer,,} in
        y | yes) return 0 ;;
    esac
    ku_die "$KU_EX_DECLINED" "declined; nothing was changed"
}

# Open KU_TTY for the answers, once, or exit 10 with MESSAGE, all words given, when it cannot be
# read.
_ku_tty_open() {
    if [[ -z $KU_TTY_FD ]] && ! { exec {KU_TTY_FD}< "$KU_TTY"; } 2> /dev/null; then
        KU_TTY_FD=""
        ku_die "$KU_EX_DECLINED" "$*"
    fi
}

# Read the next answer from the terminal into the variable NAME, without the carriage return
# a CRLF line, as from a file of answers, ends in; empty when nothing can be read.
_ku_tty_answer() {
    local line=""
    IFS= read -r line <&"$KU_TTY_FD" || true
    printf -v "$1" '%s' "${line%$'\r'}"
}

# Ask PROMPT as ku_ask does and return 0 on "y" or "yes". Exits 10 on any other answer or when
# no terminal can be read, so nothing runs unconfirmed.
ku_confirm() {
    ku_ask "$1" || ku_die "$KU_EX_DECLINED" "declined; nothing was changed"
}

# Exit 77 unless the effective user is root.
ku_require_root() {
    [[ $(id -u) == 0 ]] || ku_die "$KU_EX_NOPERM" "this command must run as root"
}

# Take the single-instance lock for the rest of the process, or exit 75 when another run
# holds it or the lock file cannot be opened, and 1 when flock is missing or fails otherwise.
# The lock goes when the process exits. The file sits in /run, which only root can write.
ku_lock() {
    local fd status=0
    command -v flock > /dev/null || ku_die "$KU_EX_FAILURE" "flock (util-linux) is not installed"
    : 2> /dev/null >> "$KU_LOCKFILE" || ku_die "$KU_EX_BUSY" "cannot open the lock file $KU_LOCKFILE"
    exec {fd}>> "$KU_LOCKFILE"
    flock -n "$fd" || status=$?
    case $status in
        0) ;;
        1) ku_die "$KU_EX_BUSY" "another kernel-updater run holds the lock" ;;
        *) ku_die "$KU_EX_FAILURE" "flock failed with status $status" ;;
    esac
}

# =======================================================
#                    EXIT AND PATHS
# =======================================================

# Register the function NAME to run at exit, before those registered earlier.
ku_cleanup_add() {
    KU_CLEANUP+=("$1")
}

# EXIT trap: run the registered cleanups in reverse order and keep the exit status. A
# failing cleanup is logged and the others still run; signals are ignored meanwhile, so a
# second Ctrl-C cannot cut the cleanups short.
ku_on_exit() {
    local status=$? i
    trap '' INT TERM HUP
    trap - ERR
    for (( i = ${#KU_CLEANUP[@]} - 1; i >= 0; i-- )); do
        "${KU_CLEANUP[i]}" || ku_log warning "cleanup ${KU_CLEANUP[i]} failed"
    done
    exit "$status"
}

# Signal trap: exit with STATUS (128 plus the signal number) through the EXIT trap.
ku_on_signal() {
    trap - "$1"
    ku_log error "interrupted by SIG$1"
    exit "$2"
}

# ERR trap: report an unexpected failure with the function and line it happened in and exit
# 1, so a failed tool never ends with an exit code that means something else. A subshell
# only passes its status up, so the main shell reports each failure once.
ku_on_error() {
    local status=$?
    if [[ $BASHPID != "$$" ]]; then
        exit "$status"
    fi
    ku_log error "unexpected failure in ${FUNCNAME[1]:-main}, line $1"
    exit "$KU_EX_FAILURE"
}

# Install the EXIT, ERR and signal traps; INT, TERM and HUP exit 130, 143 and 129.
ku_install_traps() {
    trap ku_on_exit EXIT
    trap 'ku_on_error "$LINENO"' ERR
    trap 'ku_on_signal INT 130' INT
    trap 'ku_on_signal TERM 143' TERM
    trap 'ku_on_signal HUP 129' HUP
}

# Print the absolute PATH resolved under KU_ROOT.
ku_path() {
    printf '%s\n' "${KU_ROOT%/}$1"
}

# Return 0 when the directory DIR belongs to root and group and others cannot write it, or
# only with the sticky bit set, so that no other user can rename the entries root makes in it.
# mount and umount follow symlinks, so the commands mount only in such a directory.
ku_root_only_dir() {
    local info owner mode
    [[ -d $1 ]] || return 1
    info=$(stat -L -c '%u %a' -- "$1" 2> /dev/null) || return 1
    read -r owner mode <<< "$info"
    [[ $owner == 0 && $mode =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 || (8#$mode & 8#1000) != 0 ))
}

# Print the SHA-256 of FILE, or of stdin without one, as 64 hex digits. Returns 1 when it
# cannot be read.
ku_sha256() {
    local out
    if (( $# )); then
        out=$(sha256sum 2> /dev/null < "$1") || return 1
    else
        out=$(sha256sum) || return 1
    fi
    [[ ${out:0:64} =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${out:0:64}"
}

# Return 0 when RELEASE has the shape of a kernel release.
ku_valid_release() {
    [[ $1 =~ $KU_RELEASE_RE ]]
}
