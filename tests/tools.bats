#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater's Windows scripts
#
# Runs tools/windows/stick-*.ps1 under pwsh, where one is installed, as on GitHub's runners,
# with a stub Get-Volume in place of Windows' list of volumes: each script refuses with a plain
# sentence and exit status 1 when BOOT is not there, is there twice, is not FAT or holds no
# MultiBootUSB menu, before it asks for administrator rights or changes anything. Skips
# without pwsh.
# -------------------------------------------------------

load helpers

SCRIPTS=(stick-a-copy-menu stick-b-take-offline stick-d-chkdsk stick-e-restore-menu)
# A volume of the stub's, labelled BOOT, on the drive letter Q, with the filesystem given.
fat_boot() {
    printf "[pscustomobject]@{ FileSystemLabel = 'BOOT'; DriveLetter = '%s'; FileSystem = '%s' }" \
        "${2:-Q}" "${1:-FAT32}"
}

setup() {
    command -v pwsh > /dev/null || skip "pwsh is not installed"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

# Run the script NAME under pwsh, where Get-Volume returns what the PowerShell code VOLUMES
# makes, nothing when it is empty.
run_script() {
    local script="$REPO_DIR/tools/windows/$1.ps1"
    # A Windows pwsh, as under Git Bash, takes a Windows path.
    if command -v cygpath > /dev/null; then
        script=$(cygpath -w "$script")
    fi
    run pwsh -NoProfile -NonInteractive -Command "function global:Get-Volume { $2 }
        & '$script'
        exit \$LASTEXITCODE"
}

@test "Each Windows script refuses, changing nothing, when no drive labelled BOOT is there" {
    local name
    for name in "${SCRIPTS[@]}"; do
        run_script "$name" ""
        [ "$status" -eq 1 ]
        [[ "$output" == "No drive labelled BOOT is mounted on this PC: plug the stick in,"* ]]
        [[ "$output" == *"Nothing was changed." ]]
        # One without a drive letter, as mountvol /p leaves it, is not there either.
        run_script "$name" "[pscustomobject]@{ FileSystemLabel = 'BOOT'; DriveLetter = \$null }"
        [ "$status" -eq 1 ]
        [[ "$output" == "No drive labelled BOOT is mounted on this PC:"* ]]
    done
    [ -z "$(ls -A "$HOME")" ]
}

@test "Each Windows script refuses two BOOT drives, an NTFS BOOT and one without the menu" {
    local name
    for name in "${SCRIPTS[@]}"; do
        run_script "$name" "$(fat_boot); $(fat_boot FAT32 R)"
        [ "$status" -eq 1 ]
        [[ "$output" == "More than one drive is labelled BOOT, so this cannot tell which"* ]]
        run_script "$name" "$(fat_boot NTFS)"
        [ "$status" -eq 1 ]
        [ "$output" = "BOOT (Q:) is NTFS, not FAT: these steps are for a FAT stick. Nothing was changed." ]
        run_script "$name" "$(fat_boot)"
        [ "$status" -eq 1 ]
        [[ "$output" == "BOOT (Q:) holds no multibootusb\\grub\\grub.cfg, so it is not the"* ]]
        [[ "$output" == *"MultiBootUSB stick. Nothing was changed." ]]
    done
    [ -z "$(ls -A "$HOME")" ]
}
