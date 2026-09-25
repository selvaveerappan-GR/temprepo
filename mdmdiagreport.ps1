$out = "C:\Temp\MDMDiag"
Start-Process MdmDiagnosticsTool.exe -ArgumentList "-out `"$out`"" -Wait -NoNewWindow

# Report lands in $out\MDMDiagReport.xml (and .html)
[xml]$report = Get-Content "$out\MDMDiagReport.xml"


#############


Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_Policy_Result01_Experience02"


#############


$cache = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.CompanyPortal_8wekyb3d8bbwe\TempState\ApplicationCache" -Filter *.tmp* -Recurse |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
(($cache | Get-Content | ConvertFrom-Json).data | ConvertFrom-Json).ComplianceState
