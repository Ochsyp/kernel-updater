# Step A: before the VM starts, copy the stick's multibootusb\grub folder to a dated folder in
# LOCALAPPDATA\kernel-updater\stick-grub, which it makes when it is missing, and print its path
# and the SHA-256 of grub.cfg on the stick and in the copy. Writes nothing on the stick or the
# Desktop. Exits 1, saying why, when BOOT is not there or the copy differs.

. (Join-Path $PSScriptRoot 'stick.ps1')

$drive = Get-BootDrive
$source = "$drive\multibootusb\grub"
$folder = Get-CopyFolder
try {
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
} catch {
    Stop-Step ('Cannot make {0}: {1}. The stick was not changed.' -f $folder,
        $_.Exception.Message)
}
$target = Join-Path $folder ('stick-grub-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
Write-Host 'The copy matches the stick. Next: start the VM through the launcher.'
