# Triggers the compliance evaluation completely inside the current user context
$IME = New-Object -ComObject Shell.Application
$IME.Open("intunemanagementextension://synccompliance")

 [InternetShortcut]
  URL=intunemanagementextension://synccompliance
  IconFile=%SystemRoot%\System32\SHELL32.dll
  IconIndex=238

  [InternetShortcut]
  URL=ms-settings:workplace
  IconFile=%SystemRoot%\System32\SHELL32.dll
  IconIndex=269

  [InternetShortcut]
  URL=ms-settings:windowsupdate-action
  IconFile=%SystemRoot%\System32\SHELL32.dll
  IconIndex=46


# Sync + compliance
  Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName PushLaunch | Start-ScheduledTask
  Restart-Service IntuneManagementExtension   # forces app/script/remediation re-eval

  # Updates — scan, download, install
  UsoClient StartScan
  UsoClient StartDownload
  UsoClient StartInstall
