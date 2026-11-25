# kernel-updater: what the stick-*.ps1 scripts beside this file share. They are the steps in
# Windows around 'kernel-updater migrate --write-fat' in the VM, as docs/migration.md lists
# them. Each finds the stick's BOOT drive by its label, refuses with a plain sentence when it
# is not there, and changes nothing else.

# Set by a script that runs in a window of its own as administrator, which then stays open.
$script:KuWindow = $false

# Wait for Enter in a window of its own, so that the result stays readable.
function Wait-Close {
    if ($script:KuWindow) {
        Read-Host 'Press Enter to close this window' | Out-Null
    }
}

# Print MESSAGE and stop the script with exit status 1.
function Stop-Step([string]$Message) {
    Write-Host $Message
    Wait-Close
    exit 1
}

# Return the drive of the one FAT volume labelled BOOT that holds multibootusb\grub\grub.cfg,
# as "X:", or stop with a sentence that says why there is none.
function Get-BootDrive {
    $found = @(Get-Volume | Where-Object { $_.FileSystemLabel -eq 'BOOT' -and $_.DriveLetter })
    if ($found.Count -eq 0) {
        Stop-Step ('No drive labelled BOOT is mounted on this PC: plug the stick in, wait until ' +
            'Explorer shows BOOT, and run this again. Nothing was changed.')
    }
    if ($found.Count -gt 1) {
        Stop-Step ('More than one drive is labelled BOOT, so this cannot tell which is the stick: ' +
            'unplug the others and run this again. Nothing was changed.')
    }
    $drive = '{0}:' -f $found[0].DriveLetter
    if ($found[0].FileSystem -notmatch '^FAT') {
        Stop-Step (('BOOT ({0}) is {1}, not FAT: these steps are for a FAT stick. Nothing was ' +
            'changed.') -f $drive, $found[0].FileSystem)
    }
    if (-not (Test-Path -LiteralPath "$drive\multibootusb\grub\grub.cfg" -PathType Leaf)) {
        Stop-Step (('BOOT ({0}) holds no multibootusb\grub\grub.cfg, so it is not the ' +
            'MultiBootUSB stick. Nothing was changed.') -f $drive)
    }
    # A disk inside the PC may hold a copy of the stick; the stick itself is on USB.
    $bus = ''
    try {
        $bus = [string](Get-Partition -DriveLetter $found[0].DriveLetter -ErrorAction Stop |
            Get-Disk -ErrorAction Stop).BusType
    } catch {
        $bus = ''
    }
    if ($bus -ne 'USB') {
        Stop-Step (('BOOT ({0}) is not on a USB disk, so it is not the stick. Nothing was ' +
            'changed.') -f $drive)
    }
    return $drive
}

# Return $true when this PowerShell runs as administrator.
function Test-Admin {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run the script SCRIPT again as administrator in a window of its own, which Windows asks
# you to allow, and stop this one.
function Restart-AsAdmin([string]$Script) {
    Write-Host 'Windows asks for administrator rights now; the result shows in the new window.'
    try {
        Start-Process -FilePath powershell.exe -Verb RunAs -ErrorAction Stop -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Script), '-Window')
    } catch {
        Stop-Step 'Administrator rights were not given. Nothing was changed.'
    }
    exit 0
}

# Print the SHA-256 of the file PATH, in lower case.
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
