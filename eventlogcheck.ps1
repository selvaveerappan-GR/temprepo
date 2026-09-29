$log = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'

Get-WinEvent -LogName $log -MaxEvents 1000 |
    Where-Object {
        $_.Message -match
        'LocalUsersAndGroups|RestrictedGroups|ConfigureGroupMembership'
    } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List
