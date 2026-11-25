# Step D: after the VM is shut down and the stick plugged in again, run chkdsk on BOOT
# read-only, without /f, as administrator, which Windows asks you to allow, and print its
# result. Changes nothing. Exits 1, saying why, when BOOT is not there or chkdsk reports
# problems.
param([switch]$Window)

. (Join-Path $PSScriptRoot 'stick.ps1')
$script:KuWindow = $Window.IsPresent

$drive = Get-BootDrive
if (-not (Test-Admin)) {
    Restart-AsAdmin $PSCommandPath
}
Write-Host "chkdsk $drive, read-only:"
& chkdsk.exe $drive
$status = $LASTEXITCODE
if ($status -ne 0) {
    Stop-Step ("chkdsk reported problems on BOOT ($drive), exit ${status}: run 'chkdsk $drive /f' " +
        'as administrator, then step E.')
}
Write-Host "chkdsk found no problems on BOOT ($drive), exit 0."
Wait-Close
