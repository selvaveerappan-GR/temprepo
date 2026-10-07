#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Registers the GR Intune scheduled tasks to run as SYSTEM with highest privileges, and
    grants the local Users group read + execute rights on each so standard users can start
    them on demand.

.DESCRIPTION
    Creates one task per name in -TaskName, in the \GRIntune\ folder, all sharing:
      - runs as SYSTEM (S-1-5-18), LogonType ServiceAccount, RunLevel Highest
      - no trigger, so the task only ever runs on demand
      - BUILTIN\Users granted read + execute on the task itself

    The actions differ by task:

      GR-RunIntuneComplianceCheck  deviceenroller.exe /o <EnrollmentID> /c /b
                                   Triggers an on-demand MDM sync so Intune re-evaluates
                                   compliance. <EnrollmentID> is resolved at registration
                                   time from the device's MDM enrollment and baked into the
                                   argument, so it is fixed until this script is re-run.
      GR-RunIntuneRestartIME       powershell.exe -Command Restart-Service
                                   IntuneManagementExtension, which forces the Intune
                                   Management Extension to check in. Exits 0 or 1 so
                                   LastTaskResult reflects whether the restart worked.
      everything else              powershell.exe -File <ScriptDirectory>\<TaskName>.ps1

    Re-running also unregisters tasks this script used to create but no longer does
    (currently GR-RunIntunePushLaunch), in both -TaskPath and the root folder, so the
    \GRIntune\ folder ends up matching the current design rather than accumulating dead
    tasks that standard users can still execute. Use -WhatIf to see what would be removed.

    Register-ScheduledTask creates a task whose default security descriptor lets
    non-administrators read the task but not start it, and the ScheduledTasks module exposes
    no way to change that. So each task is registered first, then reopened through the
    Schedule.Service COM interface to rewrite its DACL with an allow ACE for BUILTIN\Users
    (S-1-5-32-545) carrying GENERIC_READ | GENERIC_EXECUTE - the generic rights Task
    Scheduler checks when a standard user starts a task.

    Each task is registered with -Force, so re-running this replaces existing definitions.
    A failure on one task does not abort the others; the script reports per-task results and
    exits with a terminating error if any task failed.

    The .ps1 action targets are placeholders. They do not need to exist at registration
    time, but those tasks will fail until the scripts are in place. Because these run as
    SYSTEM, any user who can write to the target path gets code execution as SYSTEM -
    C:\temp is typically user-writable, so move the scripts to an admin-only ACL'd
    directory for real use. GR-RunIntuneComplianceCheck is not exposed to this, since it
    invokes a system binary directly rather than a script.

.PARAMETER TaskName
    One or more task names. For any name other than GR-RunIntuneComplianceCheck, the action
    script is derived from the name, so 'GR-RunIntunePushLaunch' runs
    <ScriptDirectory>\GR-RunIntunePushLaunch.ps1.

.PARAMETER TaskPath
    Task Scheduler folder to register into. Defaults to '\GRIntune\'. Must match the
    -TaskPath that GR-IntuneSelfServiceGui.ps1 uses, or the GUI will not find the tasks.

.PARAMETER ScriptDirectory
    Directory holding the .ps1 action scripts. Defaults to 'C:\temp'. Not used by
    GR-RunIntuneComplianceCheck.

.PARAMETER EnrollmentId
    MDM enrollment GUID for the deviceenroller.exe argument. Resolved automatically from
    the registry; pass it explicitly if this device has more than one device enrollment.

.EXAMPLE
    .\New-GRIntuneScheduledTasks.ps1

    Registers all three GR Intune tasks into \GRIntune\.

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
        'GR-RunIntuneRestartIME',
        'GR-InstallIntuneUpdates'
    ),

    [ValidateNotNullOrEmpty()]
    [string]$TaskPath = '\GRIntune\',

    [ValidateNotNullOrEmpty()]
    [string]$ScriptDirectory = 'C:\temp',

    [string]$EnrollmentId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Task Scheduler evaluates the task DACL using generic rights, not file-style rights.
# GENERIC_READ | GENERIC_EXECUTE = 0xA0000000; PowerShell parses 32-bit hex literals as
# Int32, so this lands as -1610612736, which is the signed mask CommonAce expects.
$TASK_GENERIC_READ_EXECUTE = [int](0x80000000 -bor 0x20000000)
$DACL_SECURITY_INFORMATION = 0x4
$USERS_SID = 'S-1-5-32-545'   # BUILTIN\Users - well-known, locale-independent
$TASK_COMPLIANCE = 'GR-RunIntuneComplianceCheck'
$TASK_RESTART_IME = 'GR-RunIntuneRestartIME'
$MDM_DEVICE_ENROLLMENT_TYPE = 6   # device (not user) MDM enrollment
$IME_SERVICE_NAME = 'IntuneManagementExtension'

# Tasks this script used to create. Re-running removes them, so the \GRIntune\ folder ends
# up matching the current design instead of accumulating dead tasks that standard users can
# still execute.
$OBSOLETE_TASK_NAMES = @('GR-RunIntunePushLaunch')

function Get-MdmEnrollmentId {
    <#
        Resolves the device's MDM enrollment GUID. Several GUID subkeys usually exist under
        Enrollments, most of them stale, so select on EnrollmentType 6 - the device
        enrollment deviceenroller.exe expects.

        READS THE 64-BIT REGISTRY VIEW EXPLICITLY, and that is the whole point of this
        function's shape. Intune runs Win32 app install commands in a 32-bit process, and
        for a 32-bit process on 64-bit Windows the registry provider redirects
        HKLM\SOFTWARE to HKLM\SOFTWARE\WOW6432Node - where Enrollments does not exist. So
        'HKLM:\SOFTWARE\Microsoft\Enrollments' silently finds nothing when installed from
        Company Portal while working perfectly in a 64-bit console or ISE. Going through
        RegistryKey.OpenBaseKey with RegistryView.Registry64 bypasses redirection and gives
        the same answer from either bitness.

        Do not "simplify" this back to Get-ChildItem 'HKLM:\...'.
    #>
    [CmdletBinding()]
    param()

    # Registry64 is meaningless on a 32-bit OS, where there is only one view.
    $view = if ([Environment]::Is64BitOperatingSystem) {
        [Microsoft.Win32.RegistryView]::Registry64
    }
    else {
        [Microsoft.Win32.RegistryView]::Default
    }
    Write-Verbose "Reading enrollments from the $view registry view (process is $(if ([Environment]::Is64BitProcess) { '64' } else { '32' })-bit)"

    $ids = @()
    $seen = @()          # every subkey and its EnrollmentType, for the failure message
    $subKeyCount = 0

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    try {
        $enrollments = $base.OpenSubKey('SOFTWARE\Microsoft\Enrollments')
        if (-not $enrollments) {
            throw "Registry key HKLM\SOFTWARE\Microsoft\Enrollments was not found in the $view view. This device does not appear to be MDM-enrolled."
        }
        try {
            # GetValue returns $null for a missing value, so unlike the Get-ItemProperty
            # form this needs no StrictMode property-existence guard.
            foreach ($name in $enrollments.GetSubKeyNames()) {
                $subKeyCount++
                $sub = $enrollments.OpenSubKey($name)
                if (-not $sub) { continue }
                try {
                    $type = $sub.GetValue('EnrollmentType', $null)
                    if ($null -eq $type) { continue }
                    $seen += "$name=$type"
                    if ([int]$type -eq $MDM_DEVICE_ENROLLMENT_TYPE) { $ids += $name }
                }
                finally { $sub.Dispose() }
            }
        }
        finally { $enrollments.Dispose() }
    }
    finally { $base.Dispose() }

    if ($ids.Count -eq 0) {
        # Report what was actually read, so the next failure is diagnosable from the log
        # rather than needing this to be reproduced by hand.
        $detail = if ($seen.Count -gt 0) { "Enrollments seen: $($seen -join ', ')." }
        else { "None of the $subKeyCount subkey(s) carried an EnrollmentType value." }
        throw "No MDM device enrollment (EnrollmentType $MDM_DEVICE_ENROLLMENT_TYPE) found under HKLM\SOFTWARE\Microsoft\Enrollments in the $view view. $detail So $TASK_COMPLIANCE cannot be given a sync target."
    }
    if ($ids.Count -gt 1) {
        # Interpolating an array would silently produce '/o id1 id2 /c /b', so refuse rather
        # than pick one and leave a task that quietly syncs nothing.
        throw "Found $($ids.Count) MDM device enrollments ($($ids -join ', ')). Re-run with -EnrollmentId to say which one $TASK_COMPLIANCE should sync."
    }

    $ids[0]
}

function New-GRTaskAction {
    <#
        Two tasks drive something directly rather than running a script; the rest run a .ps1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptDirectory,
        [string]$EnrollmentId
    )

    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    if ($TaskName -eq $TASK_COMPLIANCE) {
        # An on-demand MDM sync, which is what makes Intune re-evaluate compliance.
        return New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\deviceenroller.exe" `
            -Argument "/o $EnrollmentId /c /b"
    }

    if ($TaskName -eq $TASK_RESTART_IME) {
        # Restarting the Intune Management Extension forces it to check in with Intune.
        # Wrapped in try/catch with explicit exit codes so LastTaskResult distinguishes a
        # failed restart from a successful one - the GUI keys its outcome off that.
        $command = "try { Restart-Service -Name '$IME_SERVICE_NAME' -Force -ErrorAction Stop; exit 0 } catch { exit 1 }"
        return New-ScheduledTaskAction -Execute $powershell `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""
    }

    # [IO.Path]::Combine rather than Join-Path: Join-Path resolves the drive qualifier and
    # fails outright if that drive is not mounted, which we do not need here.
    $scriptPath = [System.IO.Path]::Combine($ScriptDirectory, "$TaskName.ps1")
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Warning "[$TaskName] action target '$scriptPath' does not exist yet. The task will register but fail until the script is in place."
    }

    New-ScheduledTaskAction -Execute $powershell `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
}

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

    # Register-ScheduledTask accepts '\GRIntune\', but ITaskService::GetFolder wants
    # '\GRIntune' - a trailing separator makes it fail to find the folder.
    $folderPath = if ($TaskPath -eq '\') { '\' } else { $TaskPath.TrimEnd('\') }
    $task = $Scheduler.GetFolder($folderPath).GetTask($TaskName)

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

# Resolve the enrollment GUID once, and only if a task actually needs it, so a machine that
# is not MDM-enrolled can still get the other tasks registered.
if ($TaskName -contains $TASK_COMPLIANCE -and -not $EnrollmentId) {
    $EnrollmentId = Get-MdmEnrollmentId
    Write-Verbose "Resolved MDM device enrollment: $EnrollmentId"
}

$scheduler = New-Object -ComObject 'Schedule.Service'
try {
    $scheduler.Connect()

    foreach ($name in $TaskName) {
        if (-not $PSCmdlet.ShouldProcess("$TaskPath$name", 'Register as SYSTEM, grant read + execute to BUILTIN\Users')) {
            continue
        }

        try {
            $action = New-GRTaskAction -TaskName $name -ScriptDirectory $ScriptDirectory -EnrollmentId $EnrollmentId

            Write-Verbose "[$name] registering '$TaskPath$name'"
            $description = switch ($name) {
                $TASK_COMPLIANCE {
                    "Triggers an on-demand Intune MDM sync (deviceenroller.exe) as SYSTEM so compliance is re-evaluated. Startable on demand by members of BUILTIN\Users."
                }
                $TASK_RESTART_IME {
                    "Restarts the $IME_SERVICE_NAME service as SYSTEM, forcing the Intune Management Extension to check in. Startable on demand by members of BUILTIN\Users."
                }
                default {
                    "Runs $name as SYSTEM. Startable on demand by members of BUILTIN\Users."
                }
            }

            $null = Register-ScheduledTask -TaskName $name -TaskPath $TaskPath `
                -Action $action -Principal $principal -Settings $settings `
                -Description $description -Force

            Grant-ScheduledTaskExecuteRight -Scheduler $scheduler -TaskName $name -TaskPath $TaskPath -Sid $USERS_SID

            $registered.Add($name)
        }
        catch {
            # Keep going so one bad task does not leave the rest unregistered.
            $failures.Add([PSCustomObject]@{ TaskName = $name; Reason = $_.Exception.Message })
            Write-Error -ErrorRecord $_ -ErrorAction Continue
        }
    }

    # Clear out tasks this script used to create. Checked in the root folder too, since
    # earlier revisions registered into '\' before \GRIntune\ existed.
    foreach ($obsolete in $OBSOLETE_TASK_NAMES) {
        foreach ($path in @($TaskPath, '\') | Select-Object -Unique) {
            $stale = Get-ScheduledTask -TaskName $obsolete -TaskPath $path -ErrorAction SilentlyContinue
            if (-not $stale) { continue }
            if ($PSCmdlet.ShouldProcess("$path$obsolete", 'Unregister obsolete task')) {
                try {
                    Unregister-ScheduledTask -TaskName $obsolete -TaskPath $path -Confirm:$false
                    Write-Verbose "Removed obsolete task '$path$obsolete'"
                }
                catch {
                    Write-Warning "Could not remove obsolete task '$path$obsolete': $($_.Exception.Message)"
                }
            }
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
            # Both halves: the compliance task's Execute is what distinguishes it.
            @{ Name = 'Action'; Expression = { "$($_.Actions[0].Execute) $($_.Actions[0].Arguments)".Trim() } }
}

if ($failures.Count -gt 0) {
    $summary = ($failures | ForEach-Object { "$($_.TaskName): $($_.Reason)" }) -join '; '
    throw "Failed to configure $($failures.Count) of $($TaskName.Count) task(s) - $summary"
}
