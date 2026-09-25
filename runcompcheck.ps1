# Triggers the compliance evaluation completely inside the current user context
$IME = New-Object -ComObject Shell.Application
$IME.Open("intunemanagementextension://synccompliance")
