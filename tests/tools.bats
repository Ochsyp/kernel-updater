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

# No step B (tests/repo.bats checks that it stays gone).
SCRIPTS=(stick-a-copy-menu stick-d-chkdsk stick-e-restore-menu)
# A volume of the stub's, labelled BOOT, on the drive letter Q, with the filesystem given.
fat_boot() {
    printf "[pscustomobject]@{ FileSystemLabel = 'BOOT'; DriveLetter = '%s'; FileSystem = '%s' }" \
        "${2:-Q}" "${1:-FAT32}"
}

setup() {
    command -v pwsh > /dev/null || skip "pwsh is not installed"
    export HOME="$BATS_TEST_TMPDIR/home"
    # Where steps A and E keep the copies of the menu, under kernel-updater\stick-grub.
    export LOCALAPPDATA="$HOME/AppData/Local"
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

# Fail, naming them, when anything but pwsh's own folders is under HOME: pwsh on Linux keeps
# its caches and settings there, under .cache, .local/share and .config, while a script that
# refuses makes nothing, such as step A's copy or its folder. Lists HOME in the TAP output.
home_untouched() {
    local left
    (cd "$HOME" && find . -mindepth 1 -maxdepth 4 | sort) | sed 's/^/# HOME: /' >&3
    left=$(cd "$HOME" && find . -mindepth 1 |
        grep -v -E '^\./\.(cache|config|local|local/share)(/powershell(/.*)?)?$' || true)
    if [[ -n $left ]]; then
        printf 'Left in HOME:\n%s\n' "$left" >&2
        return 1
    fi
}

@test "Each Windows script refuses, changing nothing, when no drive labelled BOOT is there" {
    local name
    for name in "${SCRIPTS[@]}"; do
        run_script "$name" ""
        [ "$status" -eq 1 ]
        [[ "$output" == "No drive labelled BOOT is mounted on this PC: plug the stick in,"* ]]
        [[ "$output" == *"Nothing was changed." ]]
        # One without a drive letter, as an offline volume has, is not there either.
        run_script "$name" "[pscustomobject]@{ FileSystemLabel = 'BOOT'; DriveLetter = \$null }"
        [ "$status" -eq 1 ]
        [[ "$output" == "No drive labelled BOOT is mounted on this PC:"* ]]
    done
    home_untouched
}

# Run the script NAME under pwsh on Linux, with partition 1's files in the folder STICK as the
# drive Q:, which Get-Volume names BOOT on a disk on BUS, USB by default, and with ANSWER, yes by
# default, as what Read-Host returns. LOCALAPPDATA is under HOME.
run_on_stick() {
    local name=$1 stick=$2 bus=${3:-USB} answer=${4:-yes}
    run pwsh -NoProfile -NonInteractive -Command "
        New-PSDrive -Name Q -PSProvider FileSystem -Root '$stick' -Scope Global | Out-Null
        function global:Get-Volume { $(fat_boot) }
        function global:Get-Partition { [CmdletBinding()] param(\$DriveLetter)
            [pscustomobject]@{ DriveLetter = \$DriveLetter } }
        function global:Get-Disk { [CmdletBinding()] param([Parameter(ValueFromPipeline)]\$Partition)
            process { [pscustomobject]@{ BusType = '$bus' } } }
        function global:Read-Host { param(\$Prompt) Write-Host \"\${Prompt}: $answer\"; '$answer' }
        & '$REPO_DIR/tools/windows/$name.ps1'
        exit \$LASTEXITCODE"
}

@test "Step A copies the stick's menu to LOCALAPPDATA, not the Desktop; E copies it back" {
    [[ $(uname -s) == Linux ]] || skip "gives pwsh Linux paths, which only Linux's pwsh takes"
    local stick="$BATS_TEST_TMPDIR/stick" copies="$LOCALAPPDATA/kernel-updater/stick-grub"
    local copy name
    mkdir -p "$stick/multibootusb/grub/i386-pc" "$HOME/Desktop"
    printf 'menuentry "Old" {\r\n}\r\n' > "$stick/multibootusb/grub/grub.cfg"
    printf 'module\n' > "$stick/multibootusb/grub/i386-pc/linux.mod"
    cp "$stick/multibootusb/grub/grub.cfg" "$BATS_TEST_TMPDIR/old.cfg"
    # With no copy yet, E refuses and makes no folder.
    run_on_stick stick-e-restore-menu "$stick"
    [ "$status" -eq 1 ]
    [[ "$output" == "No stick-grub-* folder is in $copies, so there is nothing to put back."* ]]
    [[ "$output" == *"Nothing was changed." ]]
    [ ! -e "$LOCALAPPDATA/kernel-updater" ]
    # Without LOCALAPPDATA, A refuses and copies nothing.
    LOCALAPPDATA="" run_on_stick stick-a-copy-menu "$stick"
    [ "$status" -eq 1 ]
    [[ "$output" == "LOCALAPPDATA is not set, so the menu has no folder to go to."* ]]
    [[ "$output" == *"Nothing was changed." ]]
    [ ! -e "$LOCALAPPDATA/kernel-updater" ]
    # A makes the folder when it is missing.
    run_on_stick stick-a-copy-menu "$stick"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
    [[ "$output" == *"Copied BOOT (Q:) multibootusb\\grub to: $copies/stick-grub-"* ]]
    [[ "$output" == *"Files: 2 on the stick, 2 in the copy"* ]]
    [[ "$output" == *"The copy matches the stick. Next: start the VM through the launcher." ]]
    copy=$(find "$copies" -mindepth 1 -maxdepth 1)
    [[ "$copy" == "$copies/stick-grub-"* ]]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$copy/grub.cfg"
    cmp "$stick/multibootusb/grub/i386-pc/linux.mod" "$copy/i386-pc/linux.mod"
    # Nothing lands on the Desktop.
    [ -z "$(find "$HOME/Desktop" -mindepth 1)" ]
    # E takes the newest copy and passes over an older one, as one moved there by hand.
    mkdir "$copies/stick-grub-20000101-0000"
    printf 'older\n' > "$copies/stick-grub-20000101-0000/grub.cfg"
    # The write changes grub.cfg and adds kali.cfg; E puts grub.cfg back only after a yes.
    printf 'menuentry "New" {\r\n}\r\n' > "$stick/multibootusb/grub/grub.cfg"
    printf 'kali\n' > "$stick/multibootusb/grub/kali.cfg"
    run_on_stick stick-e-restore-menu "$stick" USB no
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not copied. Nothing was changed." ]]
    grep -q New "$stick/multibootusb/grub/grub.cfg"
    run_on_stick stick-e-restore-menu "$stick"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
    [[ "$output" == *"This copies $copy over BOOT (Q:) multibootusb\\grub."* ]]
    [[ "$output" == *"The stick's grub.cfg is the saved one again."* ]]
    cmp "$BATS_TEST_TMPDIR/old.cfg" "$stick/multibootusb/grub/grub.cfg"
    [ -f "$stick/multibootusb/grub/kali.cfg" ]
    # Folders go back in place, not into themselves.
    [ ! -e "$stick/multibootusb/grub/i386-pc/i386-pc" ]
    # A BOOT that is not on a USB disk is no stick, for every script.
    for name in "${SCRIPTS[@]}"; do
        run_on_stick "$name" "$stick" SATA
        [ "$status" -eq 1 ]
        [ "$output" = "BOOT (Q:) is not on a USB disk, so it is not the stick. Nothing was changed." ]
    done
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
    home_untouched
}
