#Requires -RunAsAdministrator

$session = New-Object -ComObject Microsoft.Update.Session
$session.ClientApplicationID = 'PowerShell Windows Update'

Write-Host 'Scanning for applicable updates...'
$searcher = $session.CreateUpdateSearcher()
$searchResult = $searcher.Search(
    "IsInstalled=0 and IsHidden=0"
)

if ($searchResult.Updates.Count -eq 0) {
    Write-Host 'No applicable updates found.'
    return
}

$updates = New-Object -ComObject Microsoft.Update.UpdateColl

foreach ($update in $searchResult.Updates) {
    Write-Host "Found: $($update.Title)"

    if (-not $update.EulaAccepted) {
        $update.AcceptEula()
    }

    [void]$updates.Add($update)
}

Write-Host "Downloading $($updates.Count) update(s)..."
$downloader = $session.CreateUpdateDownloader()
$downloader.Updates = $updates
$downloadResult = $downloader.Download()

$downloaded = New-Object -ComObject Microsoft.Update.UpdateColl

foreach ($update in $updates) {
    if ($update.IsDownloaded) {
        [void]$downloaded.Add($update)
    }
    else {
        Write-Warning "Not downloaded: $($update.Title)"
    }
}

if ($downloaded.Count -eq 0) {
    throw 'No updates were successfully downloaded.'
}

Write-Host "Installing $($downloaded.Count) downloaded update(s)..."
$installer = $session.CreateUpdateInstaller()
$installer.Updates = $downloaded
$installResult = $installer.Install()

$resultNames = @{
    0 = 'Not started'
    1 = 'In progress'
    2 = 'Succeeded'
    3 = 'Succeeded with errors'
    4 = 'Failed'
    5 = 'Aborted'
}

for ($i = 0; $i -lt $downloaded.Count; $i++) {
    $itemResult = $installResult.GetUpdateResult($i)

    [pscustomobject]@{
        Update     = $downloaded.Item($i).Title
        Result     = $resultNames[[int]$itemResult.ResultCode]
        HResult    = ('0x{0:X8}' -f ($itemResult.HResult -band 0xffffffffL))
    }
}

Write-Host "Overall result: $($resultNames[[int]$installResult.ResultCode])"
Write-Host "Reboot required: $($installResult.RebootRequired)"
