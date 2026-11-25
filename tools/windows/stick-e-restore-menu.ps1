# Step E, only if needed: copy the newest stick-grub-* folder that step A left on the Desktop
# back over BOOT's multibootusb\grub, once you typed yes, and print the SHA-256 of grub.cfg in
# the copy and on the stick. A kali.cfg the run wrote may stay beside it, which the old grub.cfg
# does not read. Exits 1, saying why, when BOOT or the copy is not there, or the hashes differ.

. (Join-Path $PSScriptRoot 'stick.ps1')

$drive = Get-BootDrive
$desktop = [Environment]::GetFolderPath('Desktop')
$copies = @(Get-ChildItem -LiteralPath $desktop -Directory -Filter 'stick-grub-*' |
    Sort-Object -Property Name)
if ($copies.Count -eq 0) {
    Stop-Step ('No stick-grub-* folder is on the Desktop, so there is nothing to put back. ' +
        'Nothing was changed.')
}
$from = $copies[-1].FullName
if (-not (Test-Path -LiteralPath "$from\grub.cfg" -PathType Leaf)) {
    Stop-Step "$from holds no grub.cfg, so it is no copy of step A. Nothing was changed."
}
$to = "$drive\multibootusb\grub"
Write-Host "This copies $from over BOOT ($drive) multibootusb\grub."
if ((Read-Host 'Type yes to go on') -ne 'yes') {
    Stop-Step 'Not copied. Nothing was changed.'
}
try {
    # By literal paths, as a folder name may hold [ or ], which -Path reads as a wildcard.
    Get-ChildItem -LiteralPath $from -Force -ErrorAction Stop |
        Copy-Item -Destination $to -Recurse -Force -ErrorAction Stop
} catch {
    Stop-Step (("The copy failed: {0}. Run this again; if it fails again, copy {1} to {2} in " +
        'Explorer.') -f $_.Exception.Message, $from, $to)
}
$savedSum = Get-Sha256 "$from\grub.cfg"
$stickSum = Get-Sha256 "$to\grub.cfg"
Write-Host "grub.cfg SHA-256 in the copy:  $savedSum"
Write-Host "grub.cfg SHA-256 on the stick: $stickSum"
if ($savedSum -ne $stickSum) {
    Stop-Step 'The two differ: the old menu is not back. Run this again.'
}
Write-Host "The stick's grub.cfg is the saved one again. Eject BOOT in Windows before you boot it."
