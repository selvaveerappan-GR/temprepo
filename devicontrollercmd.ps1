$EnrollmentID = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
    Where-Object { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).EnrollmentType -eq 6 }
).PSChildName

$action    = New-ScheduledTaskAction -Execute "C:\Windows\System32\deviceenroller.exe" `
                -Argument "/o $EnrollmentID /c /b"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "OnDemandIntuneSync" -TaskPath "\Custom\" `
    -Action $action -Principal $principal -Settings $settings
