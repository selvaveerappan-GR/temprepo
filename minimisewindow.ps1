$app = Get-StartApps |
    Where-Object AppID -like '*CompanyPortal*' |
    Select-Object -First 1

if (-not $app) {
    throw 'Company Portal is not installed.'
}

Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($app.AppID)"
Start-Sleep -Seconds 3

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WindowApi
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@

$window = Get-Process |
    Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.MainWindowTitle -match 'Company Portal'
    } |
    Select-Object -First 1

if ($window) {
    [WindowApi]::ShowWindowAsync($window.MainWindowHandle, 6) | Out-Null
}
