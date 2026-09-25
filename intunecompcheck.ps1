# 1. Define the UWP Company Portal application cache directory
$CachePath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.CompanyPortal_8wekyb3d8bbwe\TempState\ApplicationCache"

# 2. Grab the most recently modified cache file containing sync telemetry
$LatestCacheFile = Get-ChildItem -Path $CachePath -Include *.tmp*, *.json -File -Recurse -ErrorAction SilentlyContinue | 
                   Sort-Object LastWriteTime -Descending | 
                   Select-Object -First 1

if ($null -eq $LatestCacheFile) {
    Write-Warning "Company Portal cache file not found. Ensure the user has signed in to the Company Portal app at least once."
    $IsCompliant = $false
} else {
    try {
        # 3. Read and parse the nested JSON layers stored in the cache
        $RawJson = Get-Content -Path $LatestCacheFile.FullName -Raw | ConvertFrom-Json
        $DataPayload = $RawJson.data | ConvertFrom-Json
        
        # 4. Extract the direct Boolean state
        # The value natively returns strings like "Compliant" or "NotCompliant" / "Error"
        $ComplianceString = $DataPayload.ComplianceState
        
        if ($ComplianceString -eq "Compliant") {
            $IsCompliant = $true
        } else {
            $IsCompliant = $false
        }
    } catch {
        Write-Warning "Failed to parse Company Portal cache."
        $IsCompliant = $false
    }
}

# 5. Output the result
Write-Output "Is Device Compliant: $IsCompliant"
