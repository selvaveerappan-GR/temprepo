#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Registers the 'GR-RunIntuneComplianceCheck' scheduled task to run as SYSTEM with
    highest privileges, and grants the local Users group read + execute rights on it.

.DESCRIPTION
    Register-ScheduledTask creates a task whose default security descriptor lets
    non-administrators read the task but not start it. This script registers the task
    and then rewrites its DACL through the Schedule.Service COM interface to add an
    allow ACE for BUILTIN\Users (S-1-5-32-545) carrying GENERIC_READ | GENERIC_EXECUTE,
    which is what Task Scheduler checks when a standard user runs the task on demand.

    The task is registered with no trigger, so it only ever runs on demand:
        Start-ScheduledTask -TaskName 'GR-RunIntuneComplianceCheck'

    The action target is a placeholder - C:\temp\GR-RunIntuneComplianceCheck.ps1 does not
    need to exist at registration time, but the task will fail until it does. Because the
    task runs as SYSTEM, any user who can write to that path can run arbitrary code as
    SYSTEM; keep the script in an admin-only ACL'd directory for real use.

.PARAMETER TaskName
    Name of the scheduled task. Defaults to 'GR-RunIntuneComplianceCheck'.

.PARAMETER TaskPath
    Task Scheduler folder to register into. Defaults to the root folder '\'.

.PARAMETER ScriptPath
    The .ps1 the task executes. Defaults to 'C:\temp\GR-RunIntuneComplianceCheck.ps1'.

.EXAMPLE
    .\New-GRIntuneComplianceCheckTask.ps1

.EXAMPLE
    .\New-GRIntuneComplianceCheckTask.ps1 -ScriptPath 'C:\ProgramData\GR\Compliance.ps1'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'GR-RunIntuneComplianceCheck',

    [ValidateNotNullOrEmpty()]
    [string]$TaskPath = '\',

    [ValidateNotNullOrEmpty()]
    [string]$ScriptPath = 'C:\temp\GR-RunIntuneComplianceCheck.ps1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Task Scheduler evaluates the task DACL using generic rights, not file-style rights.
# GENERIC_READ | GENERIC_EXECUTE = 0xA0000000; PowerShell parses 32-bit hex literals as
# Int32, so this lands as -1610612736, which is the signed mask CommonAce expects.
$TASK_GENERIC_READ_EXECUTE = [int](0x80000000 -bor 0x20000000)
$DACL_SECURITY_INFORMATION = 0x4
$USERS_SID = 'S-1-5-32-545'   # BUILTIN\Users - well-known, locale-independent

function Grant-ScheduledTaskExecuteRight {
    <#
        Adds an allow ACE for $Sid with GENERIC_READ | GENERIC_EXECUTE to the task's DACL,
        leaving the owner, group and existing ACEs untouched. Idempotent: an existing ACE
        for the same SID is replaced rather than duplicated.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$Sid
    )

    $scheduler = New-Object -ComObject 'Schedule.Service'
    try {
        $scheduler.Connect()
        $task = $scheduler.GetFolder($TaskPath).GetTask($TaskName)

        # Fetch the DACL only - requesting or writing back the owner/group needs privileges
        # we do not want to depend on, and SetSecurityDescriptor infers which sections to
        # apply from the sections present in the SDDL we hand it.
        $sddl = $task.GetSecurityDescriptor($DACL_SECURITY_INFORMATION)
        Write-Verbose "Existing DACL: $sddl"

        $rawSd = New-Object System.Security.AccessControl.RawSecurityDescriptor($sddl)
        $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)

        for ($i = $rawSd.DiscretionaryAcl.Count - 1; $i -ge 0; $i--) {
            if ($rawSd.DiscretionaryAcl[$i].SecurityIdentifier -eq $identity) {
                Write-Verbose "Removing pre-existing ACE for $Sid at index $i"
                $rawSd.DiscretionaryAcl.RemoveAce($i)
            }
        }

        $ace = New-Object System.Security.AccessControl.CommonAce(
            [System.Security.AccessControl.AceFlags]::None,
            [System.Security.AccessControl.AceQualifier]::AccessAllowed,
            $TASK_GENERIC_READ_EXECUTE,
            $identity,
            $false,   # not a callback ACE
            $null)    # no opaque data
        $rawSd.DiscretionaryAcl.InsertAce($rawSd.DiscretionaryAcl.Count, $ace)

        $newSddl = $rawSd.GetSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        Write-Verbose "New DACL: $newSddl"

        if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Grant read + execute to $Sid")) {
            $task.SetSecurityDescriptor($newSddl, 0)
        }
    }
    finally {
        if ($scheduler) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler)
        }
    }
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Warning "Action target '$ScriptPath' does not exist yet. The task will register but fail until the script is in place."
}

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""

$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Write-Verbose "Registering '$TaskPath$TaskName'"
$null = Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath `
    -Action $action -Principal $principal -Settings $settings `
    -Description 'Runs the GR Intune compliance check as SYSTEM. Startable on demand by members of BUILTIN\Users.' `
    -Force

Grant-ScheduledTaskExecuteRight -TaskName $TaskName -TaskPath $TaskPath -Sid $USERS_SID

Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath |
    Select-Object TaskName, TaskPath, State, @{ Name = 'RunAs'; Expression = { $_.Principal.UserId } },
        @{ Name = 'RunLevel'; Expression = { $_.Principal.RunLevel } }
