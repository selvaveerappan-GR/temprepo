#Requires -Version 5.1

<#
.SYNOPSIS
    Installs all pending Windows updates and publishes a machine-readable result.
    Action script for the GR-InstallIntuneUpdates scheduled task.

.DESCRIPTION
    Runs as SYSTEM, started on demand by GR-IntuneSelfServiceGui.ps1. Searches for pending
    updates through the Windows Update Agent COM API, downloads and installs them, then
    writes a result file the GUI reads to report the outcome.

    DOES NOT REBOOT, ever. That is a hard contract with the GUI: the GUI owns reboot so its
    "Install updates" button is genuinely reboot-free and its "Install updates and restart"
    button can always offer a cancellable countdown. If this script rebooted, both would
    pull the machine out from under the user with no warning. Where a reboot is needed to
    finish an install, that is reported via RebootRequired instead.

    Exit code is 0 when the run completed - including when individual updates failed, which
    the GUI surfaces from the result file - and non-zero only when the run itself could not
    be carried out. The GUI treats a non-zero LastTaskResult as "the operation failed" and
    will not restart the machine on the back of it.

.PARAMETER ResultFile
    Where to publish the outcome. Must match the GUI's -InstallResultFile.

.PARAMETER LogFile
    Transcript of the run, for diagnosing what the result file only summarises.

.NOTES
    Runs as SYSTEM, so the result and log directory is created with ProgramData's
    inherited ACL: administrators and SYSTEM write, standard users read. The GUI only
    needs to read it.

    The GUI rejects a result whose StartedAt predates the run it just triggered, so a
    stale file cannot be reported as a fresh outcome.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ResultFile = 'C:\ProgramData\GR\IntuneSelfService\install-result.json',

    [ValidateNotNullOrEmpty()]
    [string]$LogFile = 'C:\ProgramData\GR\IntuneSelfService\install-updates.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$startedAt = (Get-Date).ToUniversalTime()

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss}Z [{1}] {2}' -f (Get-Date).ToUniversalTime(), $Level, $Message
    Write-Verbose $line -Verbose
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Save-Result {
    <#
        Always called, including on failure, so the GUI never has to distinguish "the task
        died" from "the task is still going".
    #>
    param([hashtable]$Result)

    $Result['StartedAt'] = $startedAt.ToString('o')
    $Result['FinishedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    try {
        $Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
        Write-Log "Result written to '$ResultFile'."
    }
    catch {
        Write-Log "Could not write result file '$ResultFile': $($_.Exception.Message)" 'ERROR'
    }
}

# --- Prepare output location ----------------------------------------------------------
foreach ($dir in @([System.IO.Path]::GetDirectoryName($ResultFile),
        [System.IO.Path]::GetDirectoryName($LogFile)) | Select-Object -Unique) {
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
}

Write-Log '=== GR-InstallIntuneUpdates starting ==='

$session = $null
try {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()

    Write-Log 'Searching for pending updates...'
    $searchResult = $searcher.Search('IsInstalled=0 AND IsHidden=0')
    $pending = @($searchResult.Updates)
    Write-Log "Search returned $($pending.Count) pending update(s)."

    if ($pending.Count -eq 0) {
        Save-Result @{
            Outcome        = 'NothingToDo'
            Searched       = 0
            Attempted      = 0
            Succeeded      = 0
            Failed         = 0
            RebootRequired = $false
            Failures       = @()
            Message        = 'No pending updates were found.'
        }
        Write-Log '=== Nothing to install; finished ==='
        exit 0
    }

    # Accept licence terms where required, otherwise those updates silently refuse to
    # download. Collected into a fresh UpdateColl because the search result is read-only.
    $toProcess = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in $pending) {
        if (-not $update.EulaAccepted) {
            try { $update.AcceptEula() } catch { Write-Log "EULA accept failed for '$($update.Title)': $($_.Exception.Message)" 'WARN' }
        }
        $null = $toProcess.Add($update)
    }

    # --- Download ---------------------------------------------------------------------
    # Updates already in the cache report IsDownloaded, and asking the downloader for an
    # empty collection throws, so only download what actually needs it.
    $toDownload = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in $toProcess) {
        if (-not $update.IsDownloaded) { $null = $toDownload.Add($update) }
    }

    if ($toDownload.Count -gt 0) {
        Write-Log "Downloading $($toDownload.Count) update(s)..."
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toDownload
        $downloadResult = $downloader.Download()
        Write-Log "Download finished with ResultCode $($downloadResult.ResultCode), HResult $($downloadResult.HResult)."
    }
    else {
        Write-Log 'All updates are already downloaded.'
    }

    # --- Install ----------------------------------------------------------------------
    $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in $toProcess) {
        if ($update.IsDownloaded) { $null = $toInstall.Add($update) }
    }

    if ($toInstall.Count -eq 0) {
        Save-Result @{
            Outcome        = 'Failed'
            Searched       = $pending.Count
            Attempted      = 0
            Succeeded      = 0
            Failed         = $pending.Count
            RebootRequired = $false
            Failures       = @('No updates could be downloaded, so none were installed.')
            Message        = 'Updates were found but none could be downloaded.'
        }
        Write-Log 'Nothing downloaded successfully; aborting install.' 'ERROR'
        exit 2
    }

    Write-Log "Installing $($toInstall.Count) update(s)..."
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    # Explicitly never reboot - see the contract in .DESCRIPTION.
    $installer.ForceQuiet = $true
    $installResult = $installer.Install()
    Write-Log "Install finished with ResultCode $($installResult.ResultCode), RebootRequired $($installResult.RebootRequired)."

    # --- Per-update outcomes ----------------------------------------------------------
    # OperationResultCode: 2 = Succeeded, 3 = SucceededWithErrors, everything else is a
    # failure. Indices line up with $toInstall.
    $succeeded = 0
    $failed = 0
    $failures = @()
    for ($i = 0; $i -lt $toInstall.Count; $i++) {
        $title = $toInstall.Item($i).Title
        $code = $installResult.GetUpdateResult($i).ResultCode
        $hresult = $installResult.GetUpdateResult($i).HResult
        if ($code -eq 2 -or $code -eq 3) {
            $succeeded++
            Write-Log "OK   $title (ResultCode $code)"
        }
        else {
            $failed++
            $failures += ('{0} (ResultCode {1}, HResult 0x{2:X8})' -f $title, $code, $hresult)
            Write-Log "FAIL $title (ResultCode $code, HResult 0x$('{0:X8}' -f $hresult))" 'WARN'
        }
    }

    $outcome = if ($failed -eq 0) { 'Success' } elseif ($succeeded -gt 0) { 'PartialSuccess' } else { 'Failed' }
    $message = if ($failed -eq 0) {
        "Installed $succeeded update(s)."
    }
    elseif ($succeeded -gt 0) {
        "Installed $succeeded update(s); $failed failed."
    }
    else {
        "All $failed update(s) failed to install."
    }

    Save-Result @{
        Outcome        = $outcome
        Searched       = $pending.Count
        Attempted      = $toInstall.Count
        Succeeded      = $succeeded
        Failed         = $failed
        RebootRequired = [bool]$installResult.RebootRequired
        Failures       = $failures
        Message        = $message
    }

    Write-Log "=== Finished: $outcome - $message ==="
    # 0 even with individual failures: the run completed, and the GUI reports the detail
    # from the result file. Non-zero is reserved for "the run could not be carried out".
    exit 0
}
catch {
    Write-Log "Unhandled failure: $($_.Exception.Message)" 'ERROR'
    Save-Result @{
        Outcome        = 'Failed'
        Searched       = 0
        Attempted      = 0
        Succeeded      = 0
        Failed         = 0
        RebootRequired = $false
        Failures       = @($_.Exception.Message)
        Message        = "The update run failed: $($_.Exception.Message)"
    }
    exit 1
}
finally {
    if ($session) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($session)
    }
}
