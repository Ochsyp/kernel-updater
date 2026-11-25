# Step B: before the VM starts, take BOOT away from Windows with 'mountvol X:\ /p', as
# administrator, which Windows asks you to allow, and print whether the drive is gone. Plugging
# the stick in again brings BOOT back. Writes no file on the stick. Exits 1, saying why, when
# BOOT is not there or stays.
param([switch]$Window)

. (Join-Path $PSScriptRoot 'stick.ps1')
$script:KuWindow = $Window.IsPresent

$drive = Get-BootDrive
if (-not (Test-Admin)) {
    Restart-AsAdmin $PSCommandPath
}
Write-Host "Taking BOOT ($drive) offline: mountvol $drive\ /p"
& mountvol.exe "$drive\" /p
$status = $LASTEXITCODE
Start-Sleep -Seconds 2
if (Test-Path -LiteralPath "$drive\") {
    Stop-Step ("mountvol exited $status, and $drive is still there, so Windows still uses BOOT: " +
        'do not start the VM.')
}
Write-Host "BOOT is gone from Windows: Test-Path $drive\ prints False. Start the VM now."
Write-Host 'Plugging the stick in again later brings BOOT back.'
Wait-Close
