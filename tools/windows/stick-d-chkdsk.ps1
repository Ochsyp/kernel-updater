# Step D: after the VM is shut down and BOOT is back in Windows, run chkdsk on BOOT read-only,
# without /f, as administrator, and print its result. Changes nothing. Started without
# administrator rights, it starts itself again as administrator, which Windows asks you to
# allow, in a window of its own that shows the result and its exit status; the first one then
# exits 0. Exits 1, saying why, when BOOT is not there or chkdsk reports problems.
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
    Stop-Step ("chkdsk did not report BOOT ($drive) clean, exit ${status}: read its output above. " +
        "If it lists errors, run 'chkdsk $drive /f' as administrator, then step E; if it could " +
        'not check the drive, run this again.')
}
Write-Host "chkdsk found no problems on BOOT ($drive), exit 0."
Wait-Close
