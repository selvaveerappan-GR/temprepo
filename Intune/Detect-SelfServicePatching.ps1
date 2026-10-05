#Requires -Version 5.1

<#
.SYNOPSIS
    Intune Win32 app custom detection script for Self Service Patching.

.DESCRIPTION
    Upload this as the app's "Use a custom detection script" rule. It is NOT part of the
    .intunewin - Intune stores and runs it separately - which is why it lives outside code\.

    HOW INTUNE READS THE RESULT

      installed      exit code 0 AND at least one line on STDOUT
      not installed  exit code 0 and STDOUT empty
      not installed  any non-zero exit code

    That makes STDOUT load-bearing: ANY stray output means "installed". So this script
    never uses Write-Host or a bare expression - Write-Host goes to the host, which is
    STDOUT under powershell.exe, and would report a missing app as present. Diagnostics go
    to a log file instead, and the single success line is the only thing ever written to
    STDOUT. An unexpected error exits non-zero with no output, which fails safe: Intune
    reads it as not installed and reinstalls.

    BITNESS

    Intune runs detection scripts in a 32-bit process unless "Run script as 32-bit process
    on 64-bit clients" is set to No. In a 32-bit process $env:ProgramFiles resolves to
    "Program Files (x86)", which is not where the app installs - so this resolves
    $env:ProgramW6432 first, the native path from either bitness. Getting this wrong is the
    classic cause of an app that installs successfully and then immediately reports as not
    installed, reinstalling forever.

    WHAT COUNTS AS INSTALLED

    Not just "a file exists". The app is a GUI plus three SYSTEM scheduled tasks, and
    without the tasks every button fails - so a machine with the files but no tasks is
    broken, not installed, and should be reinstalled. Checked:

      1. the payload files are present in the install folder
      2. version.txt is at least $EXPECTED_VERSION
      3. the all-users Start Menu shortcut exists
      4. all three scheduled tasks are registered in \GRIntune\
      5. the install task's action points inside the install folder - this catches a
         half-upgraded machine still pointing at the old C:\temp location, which runs as
         SYSTEM from a user-writable path

    VERSIONING

    $EXPECTED_VERSION must match $APP_VERSION in Install-SelfServicePatching.ps1. Bump both
    together when shipping a new package, or Intune will consider the old build current and
    never push the update. The comparison is >=, so a machine ahead of the expected version
    is left alone.

.NOTES
    Logs to <ProgramData>\GR\SelfServicePatching\detect.log regardless of outcome, which is
    where to look when Intune's install state disagrees with reality.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EXPECTED_VERSION = '1.0.0'          # keep in step with Install-SelfServicePatching.ps1
$VENDOR_FOLDER_NAME = 'GR'
$APP_FOLDER_NAME = 'SelfServicePatching'
$SHORTCUT_NAME = 'Self Service Patching'
$VERSION_FILE_NAME = 'version.txt'
$TASK_PATH = '\GRIntune\'
$REQUIRED_FILES = @(
    'GR-IntuneSelfServiceGui.ps1',
    'GR-InstallIntuneUpdates.ps1',
    'New-GRIntuneScheduledTasks.ps1'
)
$REQUIRED_TASKS = @(
    'GR-RunIntuneComplianceCheck',
    'GR-RunIntuneRestartIME',
    'GR-InstallIntuneUpdates'
)
$INSTALL_TASK = 'GR-InstallIntuneUpdates'

# Native Program Files from either bitness - see the BITNESS note above.
$installRoot = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$installDir = Join-Path (Join-Path $installRoot $VENDOR_FOLDER_NAME) $APP_FOLDER_NAME

$logDir = Join-Path $env:ProgramData "$VENDOR_FOLDER_NAME\$APP_FOLDER_NAME"
$logFile = Join-Path $logDir 'detect.log'

function Write-Log {
    # Deliberately never Write-Host or Write-Output: STDOUT is the detection signal.
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}Z [detect] {1}' -f (Get-Date).ToUniversalTime(), $Message
    Write-Verbose $line
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force
        }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    }
    catch { }   # detection must not fail because logging failed
}

try {
    # List[string], NOT ArrayList: List.Add returns void, whereas ArrayList.Add returns the
    # new index, which an unassigned call would emit to STDOUT - and any STDOUT means
    # "installed". Swapping the type here would make a missing app report as present.
    $missing = New-Object System.Collections.Generic.List[string]

    # --- 1. Payload -----------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $installDir)) {
        $missing.Add("install folder '$installDir'")
    }
    else {
        foreach ($file in $REQUIRED_FILES) {
            if (-not (Test-Path -LiteralPath (Join-Path $installDir $file))) {
                $missing.Add("file '$file'")
            }
        }
    }

    # --- 2. Version -----------------------------------------------------------------
    $installedVersion = $null
    $versionPath = Join-Path $installDir $VERSION_FILE_NAME
    if (-not (Test-Path -LiteralPath $versionPath)) {
        $missing.Add("$VERSION_FILE_NAME")
    }
    else {
        $raw = (Get-Content -LiteralPath $versionPath -Raw -ErrorAction SilentlyContinue)
        $raw = if ($raw) { $raw.Trim() } else { '' }
        # A malformed or empty file is treated as not installed rather than guessed at.
        $parsed = $null
        if ([System.Version]::TryParse($raw, [ref]$parsed)) {
            $installedVersion = $parsed
            if ($parsed -lt [System.Version]$EXPECTED_VERSION) {
                $missing.Add("version $parsed is older than $EXPECTED_VERSION")
            }
        }
        else {
            $missing.Add("unreadable version '$raw'")
        }
    }

    # --- 3. Start Menu shortcut -----------------------------------------------------
    $shortcutPath = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$SHORTCUT_NAME.lnk"
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        $missing.Add('Start Menu shortcut')
    }

    # --- 4 and 5. Scheduled tasks ---------------------------------------------------
    foreach ($name in $REQUIRED_TASKS) {
        $task = Get-ScheduledTask -TaskName $name -TaskPath $TASK_PATH -ErrorAction SilentlyContinue
        if (-not $task) {
            $missing.Add("scheduled task '$TASK_PATH$name'")
            continue
        }

        # The install task must run the copy under Program Files. If it still points at the
        # old user-writable default it is a SYSTEM task runnable from a writable path, so
        # treat the machine as needing a reinstall rather than as correctly installed.
        if ($name -eq $INSTALL_TASK) {
            $arguments = ''
            if ($task.Actions -and @($task.Actions).Count -gt 0) {
                $first = @($task.Actions)[0]
                if ($first.PSObject.Properties.Name -contains 'Arguments' -and $first.Arguments) {
                    $arguments = [string]$first.Arguments
                }
            }
            if ($arguments -notlike "*$installDir*") {
                $missing.Add("task '$name' action does not point at '$installDir'")
            }
        }
    }

    # --- Verdict --------------------------------------------------------------------
    if ($missing.Count -gt 0) {
        Write-Log "NOT DETECTED - $($missing -join '; ')"
        # Exit 0 with an empty STDOUT: Intune's "not installed".
        exit 0
    }

    Write-Log "DETECTED - version $installedVersion at $installDir"
    # The one and only write to STDOUT. Its presence is what marks the app installed; the
    # text itself is only surfaced in Intune's logs.
    Write-Output "Installed $EXPECTED_VERSION"
    exit 0
}
catch {
    # No STDOUT on the error path, so an unexpected failure reads as not installed and the
    # app is reinstalled - the safe direction.
    Write-Log "ERROR - $($_.Exception.Message)"
    exit 1
}
