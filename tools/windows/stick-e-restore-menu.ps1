# Step E, only if needed: copy the newest stick-grub-* folder that step A left for this stick in
# LOCALAPPDATA\kernel-updater\stick-grub back over BOOT's multibootusb\grub, once you typed yes.
# Only the files that differ from the stick's are written, each checked after the copy, and the
# SHA-256 of grub.cfg in the copy and on the stick is printed. A copy of another stick is never
# put back; one an older step A made, which names no stick, only when no copy of this stick is
# there, and with a warning. A kali.cfg the run wrote may stay beside it, which the old grub.cfg
# does not read. Exits 1, saying why, when BOOT or the copy is not there, or the hashes differ.

. (Join-Path $PSScriptRoot 'stick.ps1')

$drive = Get-BootDrive
$folder = Get-CopyFolder
$copies = @()
if (Test-Path -LiteralPath $folder -PathType Container) {
    $copies = @(Get-ChildItem -LiteralPath $folder -Directory -Filter 'stick-grub-*' |
        Sort-Object -Property Name)
}
if ($copies.Count -eq 0) {
    Stop-Step (('No stick-grub-* folder is in {0}, so there is nothing to put back. A copy ' +
        'that an older step A left on the Desktop must be moved into that folder first. ' +
        'Nothing was changed.') -f $folder)
}
# Each copy's stick, as step A noted it beside the copy; none for a copy of an older step A.
$id = Get-StickId $drive
$mine = @()
$untagged = @()
foreach ($copy in $copies) {
    $note = "$($copy.FullName).stick"
    if (-not (Test-Path -LiteralPath $note -PathType Leaf)) {
        $untagged += $copy
    } elseif ($id -and (Get-Content -LiteralPath $note -Raw) -eq $id) {
        $mine += $copy
    }
}
if ($mine.Count -gt 0) {
    $from = $mine[-1].FullName
} elseif ($untagged.Count -gt 0) {
    $from = $untagged[-1].FullName
    Write-Host (('{0} was made by an older step A and names no stick: check that it is a copy ' +
        'of this stick before you type yes.') -f $from)
} else {
    Stop-Step (('Every copy in {0} is of another stick, or Windows does not say which disk BOOT ' +
        'is on, so none is put back on BOOT ({1}). Nothing was changed.') -f $folder, $drive)
}
if (-not (Test-Path -LiteralPath "$from\grub.cfg" -PathType Leaf)) {
    Stop-Step "$from holds no grub.cfg, so it is no copy of step A. Nothing was changed."
}
$to = "$drive\multibootusb\grub"
Write-Host "This copies $from over BOOT ($drive) multibootusb\grub."
if ((Read-Host 'Type yes to go on') -ne 'yes') {
    Stop-Step 'Not copied. Nothing was changed.'
}
# Only what differs is written: FAT keeps no journal, so each file left alone, GRUB's modules
# among them, is one an unplug in the middle cannot damage.
$copied = 0
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $from -Recurse -File -Force -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($from.Length).TrimStart('\', '/')
        $dest = Join-Path $to $relative
        $want = Get-Sha256 $file.FullName
        if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Get-Sha256 $dest) -eq $want) {
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction Stop |
            Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
        if ((Get-Sha256 $dest) -ne $want) {
            throw "$relative on the stick differs from the copy after it was written"
        }
        $copied++
    }
} catch {
    Stop-Step (("The copy failed after {0} file(s): {1}. Run this again; if it fails again, " +
        'copy {2} to {3} in Explorer.') -f $copied, $_.Exception.Message, $from, $to)
}
Write-Host "Copied $copied changed file(s); every other file on the stick was the same already."
$savedSum = Get-Sha256 "$from\grub.cfg"
$stickSum = Get-Sha256 "$to\grub.cfg"
Write-Host "grub.cfg SHA-256 in the copy:  $savedSum"
Write-Host "grub.cfg SHA-256 on the stick: $stickSum"
if ($savedSum -ne $stickSum) {
    Stop-Step 'The two differ: the old menu is not back. Run this again.'
}
Write-Host "The stick's grub.cfg is the saved one again. Eject BOOT in Windows before you boot it."
