#!/bin/bash
# Legacy script, imported as it ran on the stick and replaced phase by phase; do not run it.
# Points every kernel version in the given MultiBootUSB grub.cfg at the running kernel, then
# purges old kernels. The README lists what is wrong with it.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: ${0##*/} GRUB_CFG" >&2
    echo "Rewrites the kernel versions in GRUB_CFG, then purges old kernels." >&2
    exit 64
fi

TARGET_FILE="$1"

# -------------------------------------------------------------------
# Determine currently running kernel
# -------------------------------------------------------------------

CURRENT_KERNEL=$(uname -r)

if [[ -z "$CURRENT_KERNEL" ]]; then
    echo "ERROR: Could not determine running kernel."
    exit 1
fi

echo "Current kernel: $CURRENT_KERNEL"


# -------------------------------------------------------------------
# Verify target file
# -------------------------------------------------------------------

if [[ ! -f "$TARGET_FILE" ]]; then
    echo "ERROR: Target file does not exist: $TARGET_FILE"
    exit 1
fi


# -------------------------------------------------------------------
# Update kernel references in target file
#
# Kali kernel versions look like:
#
#   7.1.5+kali-amd64
#   7.0.12+kali-amd64
#   6.19.14+kali-amd64
#
# Replace all occurrences of a kernel-version-looking string.
# -------------------------------------------------------------------

KERNEL_REGEX='[0-9]+\.[0-9]+\.[0-9]+[+][A-Za-z0-9._+-]+'

sed -i -E \
    "s/$KERNEL_REGEX/$CURRENT_KERNEL/g" \
    "$TARGET_FILE"

echo "Updated kernel references in: $TARGET_FILE"


# -------------------------------------------------------------------
# Get installed linux-image packages
#
# IMPORTANT:
# Do not use /lib/modules for this.
#
# /lib/modules can contain orphaned directories.
# -------------------------------------------------------------------

mapfile -t IMAGE_PACKAGES < <(
    dpkg-query -W \
        -f='${binary:Package}\t${Status}\n' |
    awk '$1 ~ /^linux-image-[0-9]/ && $2 == "install" && $3 == "ok" && $4 == "installed" {
        sub(/^linux-image-/, "", $1)
        print $1
    }' |
    sort -V
)

if [[ ${#IMAGE_PACKAGES[@]} -eq 0 ]]; then
    echo "ERROR: No installed linux-image packages found."
    exit 1
fi


# -------------------------------------------------------------------
# Display installed kernels
# -------------------------------------------------------------------

echo
echo "Installed kernels:"

printf '  %s\n' "${IMAGE_PACKAGES[@]}"


# -------------------------------------------------------------------
# Verify that the currently running kernel has an installed package
# -------------------------------------------------------------------

CURRENT_INSTALLED=false

for KERNEL in "${IMAGE_PACKAGES[@]}"; do
    if [[ "$KERNEL" == "$CURRENT_KERNEL" ]]; then
        CURRENT_INSTALLED=true
        break
    fi
done

if [[ "$CURRENT_INSTALLED" != true ]]; then
    echo
    echo "WARNING: Running kernel is not represented by an installed"
    echo "linux-image package:"
    echo "  $CURRENT_KERNEL"
    echo
    echo "Refusing to remove any kernels."
    exit 1
fi


# -------------------------------------------------------------------
# Determine previous kernel
#
# IMAGE_PACKAGES is sorted with sort -V.
#
# The newest installed kernel that is NOT the current kernel is kept.
# -------------------------------------------------------------------

PREVIOUS_KERNEL=""

for KERNEL in "${IMAGE_PACKAGES[@]}"; do
    if [[ "$KERNEL" != "$CURRENT_KERNEL" ]]; then
        PREVIOUS_KERNEL="$KERNEL"
    fi
done


echo
echo "Kernels to keep:"
echo "  Current : $CURRENT_KERNEL"

if [[ -n "$PREVIOUS_KERNEL" ]]; then
    echo "  Previous: $PREVIOUS_KERNEL"
else
    echo "  Previous: none"
fi


# -------------------------------------------------------------------
# Purge old kernel packages
# -------------------------------------------------------------------

echo
echo "Kernel cleanup:"

for KERNEL in "${IMAGE_PACKAGES[@]}"; do

    # Never remove the running kernel
    if [[ "$KERNEL" == "$CURRENT_KERNEL" ]]; then
        echo "  KEEP   $KERNEL (running)"
        continue
    fi

    # Keep exactly one previous kernel
    if [[ -n "$PREVIOUS_KERNEL" && "$KERNEL" == "$PREVIOUS_KERNEL" ]]; then
        echo "  KEEP   $KERNEL (previous)"
        continue
    fi

    echo "  REMOVE $KERNEL"

    # ---------------------------------------------------------------
    # Kernel image
    # ---------------------------------------------------------------

    IMAGE_PACKAGE="linux-image-$KERNEL"

    if dpkg-query -W -f='${Status}' "$IMAGE_PACKAGE" 2>/dev/null |
        grep -q '^install ok installed$'; then

        apt-get purge -y "$IMAGE_PACKAGE"
    fi

    # ---------------------------------------------------------------
    # Architecture-specific headers
    # ---------------------------------------------------------------

    HEADER_PACKAGE="linux-headers-$KERNEL"

    if dpkg-query -W -f='${Status}' "$HEADER_PACKAGE" 2>/dev/null |
        grep -q '^install ok installed$'; then

        apt-get purge -y "$HEADER_PACKAGE"
    fi

    # ---------------------------------------------------------------
    # Common headers
    #
    # Example:
    #
    #   7.0.12+kali-amd64
    #       -> linux-headers-7.0.12+kali-common
    #
    # Strip "-amd64" from the kernel name.
    # ---------------------------------------------------------------

    COMMON_KERNEL="${KERNEL%-amd64}"
    COMMON_HEADERS="linux-headers-${COMMON_KERNEL}-common"

    if dpkg-query -W -f='${Status}' "$COMMON_HEADERS" 2>/dev/null |
        grep -q '^install ok installed$'; then

        apt-get purge -y "$COMMON_HEADERS"
    fi
done


# -------------------------------------------------------------------
# Remove automatically orphaned packages
#
# Do this after explicitly removing old kernels.
# -------------------------------------------------------------------

echo
echo "Removing unused dependencies..."

apt-get autoremove -y


# -------------------------------------------------------------------
# Re-read installed linux-image packages after cleanup
#
# This gives us the authoritative list of kernels that should have
# corresponding /lib/modules directories.
# -------------------------------------------------------------------

mapfile -t INSTALLED_KERNELS < <(
    dpkg-query -W \
        -f='${binary:Package}\t${Status}\n' |
    awk '$1 ~ /^linux-image-[0-9]/ && $2 == "install" && $3 == "ok" && $4 == "installed" {
        sub(/^linux-image-/, "", $1)
        print $1
    }'
)


# -------------------------------------------------------------------
# Remove orphaned /lib/modules directories
#
# This catches directories whose linux-image package no longer
# exists.
#
# The running kernel is explicitly protected as an additional safety
# measure.
# -------------------------------------------------------------------

echo
echo "Checking /lib/modules for orphaned kernels..."

for MODULE_DIR in /lib/modules/*; do

    [[ -d "$MODULE_DIR" ]] || continue

    KERNEL=$(basename "$MODULE_DIR")

    # Never remove the running kernel
    if [[ "$KERNEL" == "$CURRENT_KERNEL" ]]; then
        echo "  KEEP   $KERNEL (running)"
        continue
    fi

    # Check whether a corresponding installed linux-image exists
    INSTALLED=false

    for INSTALLED_KERNEL in "${INSTALLED_KERNELS[@]}"; do
        if [[ "$KERNEL" == "$INSTALLED_KERNEL" ]]; then
            INSTALLED=true
            break
        fi
    done

    if [[ "$INSTALLED" == true ]]; then
        echo "  KEEP   $KERNEL (installed kernel)"
    else
        echo "  REMOVE $KERNEL (orphaned)"
        rm -rf -- "$MODULE_DIR"
    fi
done


# -------------------------------------------------------------------
# Rebuild initramfs
# -------------------------------------------------------------------

echo
echo "Updating initramfs..."

update-initramfs -u -k all


# -------------------------------------------------------------------
# Regenerate GRUB
# -------------------------------------------------------------------

echo
echo "Updating GRUB..."

update-grub


# -------------------------------------------------------------------
# Final result
# -------------------------------------------------------------------

echo
echo "========================================"
echo "Kernel cleanup completed"
echo "========================================"
echo
echo "Running kernel:"
echo "  $CURRENT_KERNEL"
echo
echo "Previous kernel:"
echo "  ${PREVIOUS_KERNEL:-none}"
echo
echo "Remaining /lib/modules:"
ls -1 /lib/modules
