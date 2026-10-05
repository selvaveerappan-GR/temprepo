#Requires -Version 5.1

<#
.SYNOPSIS
    Installs the Self Service Patching app. Intended as the install command of an Intune
    Win32 app (.intunewin) deployed in SYSTEM context.

.DESCRIPTION
    Copies the app payload to <Program Files>\GR\SelfServicePatching, creates an all-users
    Start Menu shortcut called "Self Service Patching", and registers the SYSTEM scheduled
    tasks the app drives.

    PACKAGING

        IntuneWinAppUtil.exe -c <this folder> -s Install-SelfServicePatching.ps1 -o <out>

      Install command:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-SelfServicePatching.ps1
      Uninstall command:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-SelfServicePatching.ps1
      Install behaviour: System
      Detection rule, preferred: custom script ->
        intune\Detect-SelfServicePatching.ps1
        It checks the files, the version stamp, the shortcut and all three scheduled
        tasks, so a machine with the files but no tasks - which looks installed but has
        no working buttons - is correctly reported as needing a reinstall.
      Detection rule, minimal alternative: File exists ->
        %ProgramFiles%\GR\SelfServicePatching\GR-IntuneSelfServiceGui.ps1
        (leave the "32-bit app on 64-bit clients" box UNCHECKED, or Intune will look in
        Program Files (x86), which is not where this installs.) This cannot tell versions
        apart, so it will not trigger upgrades.

    BITNESS
      Intune runs Win32 app commands in a 32-bit process unless told otherwise, and in a
      32-bit process $env:ProgramFiles resolves to "Program Files (x86)". $env:ProgramW6432
      is the native Program Files from either bitness, so it is preferred and
      $env:ProgramFiles is only the fallback for genuinely 32-bit Windows.

    WHY IT REGISTERS THE TASKS
      The GUI runs as the standard user and performs no privileged work itself - every
      privileged action is Start-ScheduledTask against a SYSTEM task whose DACL grants
      BUILTIN\Users execute. Without those tasks the app installs but does nothing, so
      registering them is part of installing. This install runs as SYSTEM, which is what
      makes that possible. Use -SkipTaskRegistration to deploy the files alone.

      Registering them here also points GR-InstallIntuneUpdates at the Program Files copy
      rather than the C:\temp default. That matters: these tasks run as SYSTEM, so anyone
      who can write to the action script's folder gets SYSTEM. C:\temp is usually
      user-writable; Program Files is not.

.PARAMETER InstallRoot
    Parent of the GR folder. Defaults to the native Program Files.

.PARAMETER SkipTaskRegistration
    Copy files and create the shortcut, but do not register the scheduled tasks.

.PARAMETER SkipShortcut
    Do not create the Start Menu shortcut.

.NOTES
    Exit codes: 0 success, 1 failure. Logs to
    <ProgramData>\GR\SelfServicePatching\install.log.

    The icon is optional. Drop SelfServicePatching.ico into the package next to this
    script and the shortcut picks it up; without it the shortcut falls back to the
    PowerShell icon rather than failing.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }),
    [switch]$SkipTaskRegistration,
    [switch]$SkipShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stamped into version.txt and compared by intune\Detect-SelfServicePatching.ps1. Bump both
# together when shipping a new package: if the detection script's $EXPECTED_VERSION stays
# behind, Intune considers the old build current and never pushes the update.
$APP_VERSION = '1.0.0'

$APP_FOLDER_NAME = 'SelfServicePatching'
$VENDOR_FOLDER_NAME = 'GR'
$VERSION_FILE_NAME = 'version.txt'
$SHORTCUT_NAME = 'Self Service Patching'
$ICON_FILE_NAME = 'SelfServicePatching.ico'
$GUI_FILE_NAME = 'GR-IntuneSelfServiceGui.ps1'
$TASK_SCRIPT_NAME = 'New-GRIntuneScheduledTasks.ps1'

# Everything the installed app needs. The task registration script is payload too: the
# uninstaller does not need it, but keeping it installed means the tasks can be re-created
# on a machine without re-downloading the package.
$PAYLOAD = @(
    $GUI_FILE_NAME,
    'GR-InstallIntuneUpdates.ps1',
    $TASK_SCRIPT_NAME
)

$logDir = Join-Path $env:ProgramData "$VENDOR_FOLDER_NAME\$APP_FOLDER_NAME"
$logFile = Join-Path $logDir 'install.log'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss}Z [{1}] {2}' -f (Get-Date).ToUniversalTime(), $Level, $Message
    Write-Verbose $line -Verbose
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    }
    catch { }   # never fail an install because logging failed
}

try {
    Write-Log '=== Install-SelfServicePatching starting ==='
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Process bitness: $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }); OS 64-bit: $([Environment]::Is64BitOperatingSystem)"

    $source = $PSScriptRoot
    if (-not $source) { throw 'Cannot determine the package folder ($PSScriptRoot is empty).' }
    Write-Log "Source: $source"

    # --- Target folders -------------------------------------------------------------
    # GR is expected to exist already and may well hold other GR apps, so it is created
    # only if missing and never touched beyond that.
    $vendorDir = Join-Path $InstallRoot $VENDOR_FOLDER_NAME
    if (Test-Path -LiteralPath $vendorDir) {
        Write-Log "Vendor folder already present: $vendorDir"
    }
    else {
        Write-Log "Creating vendor folder: $vendorDir"
        $null = New-Item -ItemType Directory -Path $vendorDir -Force
    }

    $installDir = Join-Path $vendorDir $APP_FOLDER_NAME
    if (-not (Test-Path -LiteralPath $installDir)) {
        Write-Log "Creating install folder: $installDir"
        $null = New-Item -ItemType Directory -Path $installDir -Force
    }
    else {
        Write-Log "Install folder already present, files will be replaced: $installDir"
    }

    # --- Payload --------------------------------------------------------------------
    $missing = @($PAYLOAD | Where-Object { -not (Test-Path -LiteralPath (Join-Path $source $_)) })
    if ($missing.Count -gt 0) {
        throw "Package is incomplete - missing: $($missing -join ', ')"
    }

    foreach ($file in $PAYLOAD) {
        Copy-Item -LiteralPath (Join-Path $source $file) -Destination $installDir -Force
        Write-Log "Copied $file"
    }

    # Optional, supplied separately.
    $iconSource = Join-Path $source $ICON_FILE_NAME
    $iconTarget = Join-Path $installDir $ICON_FILE_NAME
    if (Test-Path -LiteralPath $iconSource) {
        Copy-Item -LiteralPath $iconSource -Destination $installDir -Force
        Write-Log "Copied $ICON_FILE_NAME"
    }
    else {
        Write-Log "No $ICON_FILE_NAME in the package; the shortcut will use the default PowerShell icon." 'WARN'
    }

    $guiPath = Join-Path $installDir $GUI_FILE_NAME

    # --- Start Menu shortcut --------------------------------------------------------
    # All-users Start Menu, not the installing account's: this runs as SYSTEM, so a
    # per-user shortcut would land in SYSTEM's own profile where nobody would see it.
    if (-not $SkipShortcut) {
        $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        $shortcutPath = Join-Path $startMenu "$SHORTCUT_NAME.lnk"
        # -STA because WPF needs a single-threaded apartment; Hidden to suppress the
        # console window that would otherwise sit behind the GUI.
        $arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guiPath`""

        $shell = New-Object -ComObject 'WScript.Shell'
        try {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $shortcut.Arguments = $arguments
            $shortcut.WorkingDirectory = $installDir
            $shortcut.Description = 'Check compliance, sync with Intune and install pending updates'
            $shortcut.WindowStyle = 7   # launch minimised: the WPF window is the real UI
            if (Test-Path -LiteralPath $iconTarget) { $shortcut.IconLocation = "$iconTarget,0" }
            $shortcut.Save()
            Write-Log "Created Start Menu shortcut: $shortcutPath"
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
    else {
        Write-Log 'Skipping Start Menu shortcut (-SkipShortcut).'
    }

    # --- Scheduled tasks ------------------------------------------------------------
    if (-not $SkipTaskRegistration) {
        Write-Log 'Registering the SYSTEM scheduled tasks...'
        $taskScript = Join-Path $installDir $TASK_SCRIPT_NAME
        # -ScriptDirectory is the installed folder, so the SYSTEM task runs the copy under
        # Program Files rather than the user-writable C:\temp default.
        & $taskScript -ScriptDirectory $installDir 4>&1 | ForEach-Object { Write-Log "  $_" }
        Write-Log 'Scheduled tasks registered.'
    }
    else {
        Write-Log 'Skipping scheduled task registration (-SkipTaskRegistration).'
    }

    # --- Version stamp --------------------------------------------------------------
    # Written last, so a run that failed part way through does not leave a stamp claiming
    # a complete install. Detection keys off this, so it is the commit point.
    Set-Content -LiteralPath (Join-Path $installDir $VERSION_FILE_NAME) `
        -Value $APP_VERSION -Encoding ASCII -NoNewline
    Write-Log "Stamped version $APP_VERSION"

    Write-Log "=== Install completed: $installDir ==="
    exit 0
}
catch {
    Write-Log "Install failed: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    exit 1
}
