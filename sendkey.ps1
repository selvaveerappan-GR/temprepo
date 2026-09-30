Start-Process 'companyportal:'
Start-Sleep -Seconds 3

$companyPortal = Get-Process -Name 'CompanyPortal' -ErrorAction SilentlyContinue |
    Sort-Object StartTime -Descending |
    Select-Object -First 1

if (-not $companyPortal) {
    throw 'Unable to locate the Company Portal process.'
}

$shell = New-Object -ComObject WScript.Shell

if ($shell.AppActivate($companyPortal.Id)) {
    Start-Sleep -Milliseconds 500

    # Documented Company Portal shortcut: All devices
    $shell.SendKeys('%d')
}
else {
    throw 'Unable to activate the Company Portal window.'
}
