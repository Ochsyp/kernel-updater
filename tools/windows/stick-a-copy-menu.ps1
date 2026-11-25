# Step A: before the VM starts, copy the stick's multibootusb\grub folder to a dated folder on
# the Desktop, and print its path and the SHA-256 of grub.cfg on the stick and in the copy.
# Writes nothing on the stick. Exits 1, saying why, when BOOT is not there or the copy differs.

. (Join-Path $PSScriptRoot 'stick.ps1')

$drive = Get-BootDrive
$source = "$drive\multibootusb\grub"
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
    Stop-Step 'This account has no Desktop folder to copy the menu to. Nothing was changed.'
}
$target = Join-Path $desktop ('stick-grub-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (Test-Path -LiteralPath $target) {
    Stop-Step "$target exists already: run this again in a second. Nothing was changed."
}
try {
    Copy-Item -LiteralPath $source -Destination $target -Recurse -ErrorAction Stop
} catch {
    Stop-Step (("The copy failed: {0}. Delete {1} if it exists, and run this again. The stick " +
        "was not changed.") -f $_.Exception.Message, $target)
}
$onStick = @(Get-ChildItem -LiteralPath $source -Recurse -File).Count
$inCopy = @(Get-ChildItem -LiteralPath $target -Recurse -File).Count
$stickSum = Get-Sha256 "$source\grub.cfg"
$copySum = Get-Sha256 "$target\grub.cfg"
Write-Host "Copied BOOT ($drive) multibootusb\grub to: $target"
Write-Host "Files: $onStick on the stick, $inCopy in the copy"
Write-Host "grub.cfg SHA-256 on the stick: $stickSum"
Write-Host "grub.cfg SHA-256 in the copy:  $copySum"
if ($onStick -ne $inCopy -or $stickSum -ne $copySum) {
    Stop-Step "The copy differs from the stick: do not go on. Delete $target and run this again."
}
Write-Host 'The copy matches the stick. Next: step B.'
