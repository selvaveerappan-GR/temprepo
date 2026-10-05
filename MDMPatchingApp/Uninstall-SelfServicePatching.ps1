#Requires -Version 5.1

<#
.SYNOPSIS
    Removes the Self Service Patching app. Intended as the uninstall command of the Intune
    Win32 app, running in SYSTEM context.

.DESCRIPTION
    Reverses Install-SelfServicePatching.ps1, in the order that leaves least behind if a
    step fails:

      1. Clear every user's resume-at-logon hook. First, because it is the only leftover
         that would actively misbehave - a stale RunOnce entry points at a script this
         uninstall is about to delete, so leaving it would launch a broken command at the
         next logon.
      2. Unregister the scheduled tasks, and remove the \GRIntune\ task folder once empty.
      3. Remove the Start Menu shortcut.
      4. Remove the install folder, and the GR parent folder ONLY if it is now empty -
         other GR apps may live alongside, so an unconditional delete would take them out.
      5. Remove the machine-wide state under ProgramData.

    Every step is independent and best-effort: a failure is logged and the rest still run,
    because a partial uninstall that stops at the first problem is worse than one that
    clears what it can. The exit code reflects whether anything failed.

    Uninstall command:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-SelfServicePatching.ps1

.PARAMETER InstallRoot
    Parent of the GR folder. Defaults to the native Program Files - see the bitness note in
    Install-SelfServicePatching.ps1.

.PARAMETER KeepScheduledTasks
    Leave the SYSTEM scheduled tasks registered.

.NOTES
    Exit codes: 0 success, 1 one or more steps failed. Logs to
    <ProgramData>\GR\SelfServicePatching\uninstall.log, which is written before the
    ProgramData folder is cleaned and therefore survives as the record of the run.

    Per-user leftovers under %LOCALAPPDATA%\GR\IntuneSelfService (the update-loop state
    file) are not removed for users whose profile is not loaded - a SYSTEM process cannot
    reach an unloaded hive. They are inert: a few hundred bytes of JSON that nothing reads
    once the app is gone.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }),
    [switch]$KeepScheduledTasks
)

Set-StrictMode -Version Latest
# Steps are independently best-effort, so errors are handled per step rather than globally.
$ErrorActionPreference = 'Continue'

$APP_FOLDER_NAME = 'SelfServicePatching'
$VENDOR_FOLDER_NAME = 'GR'
$SHORTCUT_NAME = 'Self Service Patching'
$TASK_PATH = '\GRIntune\'
$TASK_NAMES = @(
    'GR-RunIntuneComplianceCheck',
    'GR-RunIntuneRestartIME',
    'GR-InstallIntuneUpdates',
    'GR-RunIntunePushLaunch'      # retired, but may still exist on older installs
)
$RUNONCE_SUBKEY = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
$RUNONCE_VALUE = 'GRIntuneSelfServiceResumeUpdates'

$logDir = Join-Path $env:ProgramData "$VENDOR_FOLDER_NAME\$APP_FOLDER_NAME"
$logFile = Join-Path $logDir 'uninstall.log'
$script:Failures = 0

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss}Z [{1}] {2}' -f (Get-Date).ToUniversalTime(), $Level, $Message
    Write-Verbose $line -Verbose
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    }
    catch { }
}

function Invoke-Step {
    <#
        Runs one removal step, logging and counting a failure rather than aborting, so a
        single stuck step cannot leave everything after it in place.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    }
    catch {
        $script:Failures++
        Write-Log "$Name failed: $($_.Exception.Message)" 'ERROR'
    }
}

Write-Log '=== Uninstall-SelfServicePatching starting ==='
Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# --- 1. Resume-at-logon hooks, for every reachable profile -------------------------
Invoke-Step 'Resume hook removal' {
    # HKCU as SYSTEM is SYSTEM's own profile, which is not where the hook was written, so
    # walk the loaded user hives under HKEY_USERS instead. Unloaded profiles are missed;
    # RunOnce self-deletes when it fires, so the worst case is one failed command.
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Script
    }

    $removed = 0
    foreach ($hive in Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue) {
        # Skip the _Classes companion hives; they never hold a Run key.
        if ($hive.PSChildName -like '*_Classes') { continue }
        $key = Join-Path "HKU:\$($hive.PSChildName)" $RUNONCE_SUBKEY
        if (-not (Test-Path -LiteralPath $key)) { continue }

        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        # Property must be tested for existence before it is read: under StrictMode,
        # reading a missing property on the object (or on $null) is a terminating error.
        if ($props -and $props.PSObject.Properties.Name -contains $RUNONCE_VALUE) {
            Remove-ItemProperty -LiteralPath $key -Name $RUNONCE_VALUE -ErrorAction SilentlyContinue
            $removed++
            Write-Log "Removed resume hook for $($hive.PSChildName)"
        }
    }
    Write-Log "Resume hooks removed: $removed"
}

# --- 2. Scheduled tasks ------------------------------------------------------------
if (-not $KeepScheduledTasks) {
    Invoke-Step 'Scheduled task removal' {
        foreach ($name in $TASK_NAMES) {
            # Check both the app's folder and the root, where earlier revisions registered.
            foreach ($path in @($TASK_PATH, '\') | Select-Object -Unique) {
                $task = Get-ScheduledTask -TaskName $name -TaskPath $path -ErrorAction SilentlyContinue
                if (-not $task) { continue }
                Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction Stop
                Write-Log "Unregistered task $path$name"
            }
        }

        # Drop the now-empty folder so Task Scheduler is not left with an orphan. Only if
        # empty: something else may have been put there.
        $scheduler = New-Object -ComObject 'Schedule.Service'
        try {
            $scheduler.Connect()
            $folderPath = $TASK_PATH.TrimEnd('\')
            if ($folderPath) {
                $root = $scheduler.GetFolder('\')
                $folder = $null
                try { $folder = $scheduler.GetFolder($folderPath) } catch { }
                if ($folder -and $folder.GetTasks(1).Count -eq 0 -and $folder.GetFolders(0).Count -eq 0) {
                    $root.DeleteFolder($folderPath.TrimStart('\'), 0)
                    Write-Log "Removed empty task folder $folderPath"
                }
                elseif ($folder) {
                    Write-Log "Task folder $folderPath is not empty; leaving it." 'WARN'
                }
            }
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler)
        }
    }
}
else {
    Write-Log 'Keeping scheduled tasks (-KeepScheduledTasks).'
}

# --- 3. Start Menu shortcut --------------------------------------------------------
Invoke-Step 'Shortcut removal' {
    $shortcutPath = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$SHORTCUT_NAME.lnk"
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
        Write-Log "Removed shortcut $shortcutPath"
    }
    else {
        Write-Log 'No Start Menu shortcut found.'
    }
}

# --- 4. Install folder -------------------------------------------------------------
Invoke-Step 'Install folder removal' {
    $vendorDir = Join-Path $InstallRoot $VENDOR_FOLDER_NAME
    $installDir = Join-Path $vendorDir $APP_FOLDER_NAME

    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
        Write-Log "Removed $installDir"
    }
    else {
        Write-Log "Install folder not present: $installDir"
    }

    # GR is shared ground - it pre-dated this app and may hold others. Remove it only if
    # this app was the last thing in it.
    if (Test-Path -LiteralPath $vendorDir) {
        $remaining = @(Get-ChildItem -LiteralPath $vendorDir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $vendorDir -Force -ErrorAction Stop
            Write-Log "Removed now-empty $vendorDir"
        }
        else {
            Write-Log "Leaving $vendorDir - still holds $($remaining.Count) item(s)."
        }
    }
}

# --- 5. Machine-wide state --------------------------------------------------------
# Last, because the log lives here. Files are named individually so an unrelated GR app
# sharing ProgramData\GR cannot be caught by a recursive delete.
Invoke-Step 'ProgramData cleanup' {
    foreach ($leaf in @('install-result.json', 'install-updates.log', 'compliance.json')) {
        $path = Join-Path $env:ProgramData "$VENDOR_FOLDER_NAME\IntuneSelfService\$leaf"
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Write-Log "Removed $path"
        }
    }

    $stateDir = Join-Path $env:ProgramData "$VENDOR_FOLDER_NAME\IntuneSelfService"
    if (Test-Path -LiteralPath $stateDir) {
        $left = @(Get-ChildItem -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue
            Write-Log "Removed now-empty $stateDir"
        }
    }
}

if ($script:Failures -gt 0) {
    Write-Log "=== Uninstall finished with $script:Failures failed step(s) ===" 'ERROR'
    exit 1
}

Write-Log '=== Uninstall completed ==='
exit 0
