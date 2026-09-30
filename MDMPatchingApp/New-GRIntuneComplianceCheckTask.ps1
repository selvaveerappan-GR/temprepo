#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Registers the GR Intune scheduled tasks to run as SYSTEM with highest privileges, and
    grants the local Users group read + execute rights on each so standard users can start
    them on demand.

.DESCRIPTION
    Creates one task per name in -TaskName, all with identical properties:
      - runs as SYSTEM (S-1-5-18), LogonType ServiceAccount, RunLevel Highest
      - action is powershell.exe against <ScriptDirectory>\<TaskName>.ps1
      - no trigger, so the task only ever runs on demand
      - BUILTIN\Users granted read + execute on the task itself

    Register-ScheduledTask creates a task whose default security descriptor lets
    non-administrators read the task but not start it, and the ScheduledTasks module exposes
    no way to change that. So each task is registered first, then reopened through the
    Schedule.Service COM interface to rewrite its DACL with an allow ACE for BUILTIN\Users
    (S-1-5-32-545) carrying GENERIC_READ | GENERIC_EXECUTE - the generic rights Task
    Scheduler checks when a standard user starts a task.

    Each task is registered with -Force, so re-running this replaces existing definitions.
    A failure on one task does not abort the others; the script reports per-task results and
    exits with a terminating error if any task failed.

    The action targets are placeholders. They do not need to exist at registration time, but
    a task will fail until its script is in place. Because these run as SYSTEM, any user who
    can write to the target path gets code execution as SYSTEM - C:\temp is typically
    user-writable, so move the scripts to an admin-only ACL'd directory for real use.

.PARAMETER TaskName
    One or more task names. Each task's action script is derived from its name, so
    'GR-RunIntunePushLaunch' runs <ScriptDirectory>\GR-RunIntunePushLaunch.ps1.

.PARAMETER TaskPath
    Task Scheduler folder to register into. Defaults to the root folder '\'.

.PARAMETER ScriptDirectory
    Directory holding the action scripts. Defaults to 'C:\temp'.

.EXAMPLE
    .\New-GRIntuneScheduledTasks.ps1

    Registers all three GR Intune tasks against C:\temp.

.EXAMPLE
    .\New-GRIntuneScheduledTasks.ps1 -TaskName 'GR-InstallIntuneUpdates' -WhatIf

    Shows what would be done for a single task without changing anything.

.EXAMPLE
    .\New-GRIntuneScheduledTasks.ps1 -ScriptDirectory 'C:\ProgramData\GR\Intune'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$TaskName = @(
        'GR-RunIntuneComplianceCheck',
        'GR-RunIntunePushLaunch',
        'GR-InstallIntuneUpdates'
    ),

    [ValidateNotNullOrEmpty()]
    [string]$TaskPath = '\',

    [ValidateNotNullOrEmpty()]
    [string]$ScriptDirectory = 'C:\temp'
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
        [Parameter(Mandatory)]$Scheduler,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$Sid
    )

    $task = $Scheduler.GetFolder($TaskPath).GetTask($TaskName)

    # Fetch the DACL only - requesting or writing back the owner/group needs privileges we
    # do not want to depend on, and SetSecurityDescriptor infers which sections to apply
    # from the sections present in the SDDL we hand it.
    $sddl = $task.GetSecurityDescriptor($DACL_SECURITY_INFORMATION)
    Write-Verbose "[$TaskName] existing DACL: $sddl"

    $rawSd = New-Object System.Security.AccessControl.RawSecurityDescriptor($sddl)
    $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)

    for ($i = $rawSd.DiscretionaryAcl.Count - 1; $i -ge 0; $i--) {
        if ($rawSd.DiscretionaryAcl[$i].SecurityIdentifier -eq $identity) {
            Write-Verbose "[$TaskName] removing pre-existing ACE for $Sid at index $i"
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
    Write-Verbose "[$TaskName] new DACL: $newSddl"

    if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Grant read + execute to $Sid")) {
        $task.SetSecurityDescriptor($newSddl, 0)
    }
}

# Identical for every task, so build these once.
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$registered = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[object]]::new()

$scheduler = New-Object -ComObject 'Schedule.Service'
try {
    $scheduler.Connect()

    foreach ($name in $TaskName) {
        # [IO.Path]::Combine rather than Join-Path: Join-Path resolves the drive qualifier
        # and fails outright if that drive is not mounted, which we do not need here.
        $scriptPath = [System.IO.Path]::Combine($ScriptDirectory, "$name.ps1")

        if (-not $PSCmdlet.ShouldProcess("$TaskPath$name", "Register as SYSTEM running '$scriptPath', grant read + execute to BUILTIN\Users")) {
            continue
        }

        try {
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                Write-Warning "[$name] action target '$scriptPath' does not exist yet. The task will register but fail until the script is in place."
            }

            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""

            Write-Verbose "[$name] registering '$TaskPath$name'"
            $null = Register-ScheduledTask -TaskName $name -TaskPath $TaskPath `
                -Action $action -Principal $principal -Settings $settings `
                -Description "Runs $name as SYSTEM. Startable on demand by members of BUILTIN\Users." `
                -Force

            Grant-ScheduledTaskExecuteRight -Scheduler $scheduler -TaskName $name -TaskPath $TaskPath -Sid $USERS_SID

            $registered.Add($name)
        }
        catch {
            # Keep going so one bad task does not leave the rest unregistered.
            $failures.Add([PSCustomObject]@{ TaskName = $name; Reason = $_.Exception.Message })
            Write-Error -ErrorRecord $_ -ErrorAction Continue
        }
    }
}
finally {
    if ($scheduler) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler)
    }
}

foreach ($name in $registered) {
    Get-ScheduledTask -TaskName $name -TaskPath $TaskPath |
        Select-Object TaskName, TaskPath, State,
            @{ Name = 'RunAs'; Expression = { $_.Principal.UserId } },
            @{ Name = 'RunLevel'; Expression = { $_.Principal.RunLevel } },
            @{ Name = 'Action'; Expression = { $_.Actions[0].Arguments } }
}

if ($failures.Count -gt 0) {
    $summary = ($failures | ForEach-Object { "$($_.TaskName): $($_.Reason)" }) -join '; '
    throw "Failed to configure $($failures.Count) of $($TaskName.Count) task(s) - $summary"
}
