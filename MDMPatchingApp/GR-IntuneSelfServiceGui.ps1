#Requires -Version 5.1

<#
.SYNOPSIS
    Sleek WPF self-service console for Intune-managed devices: check compliance, list
    pending updates, install them with or without a restart.

.DESCRIPTION
    Runs in the *standard user* context. It performs no privileged work itself - every
    privileged operation is delegated to the SYSTEM scheduled tasks registered by
    New-GRIntuneScheduledTasks.ps1, which is why that script grants BUILTIN\Users
    GENERIC_READ | GENERIC_EXECUTE on each task. The user can start them; only SYSTEM
    can change what they do.

        Button                        Privileged work                 Runs as
        ----------------------------  ------------------------------  -------
        Check compliance              GR-RunIntuneComplianceCheck     SYSTEM
                                      (deviceenroller.exe)
        Sync Device                   GR-RunIntuneRestartIME          SYSTEM
        Install updates               GR-InstallIntuneUpdates         SYSTEM
        Install updates and restart   GR-InstallIntuneUpdates         SYSTEM
                                      then shutdown.exe /r            user

    The pending-updates list is read in-process through the Windows Update Agent COM API,
    which a standard user may query read-only. Installing is what needs SYSTEM.

    SYNC DEVICE

    Presented purely as an Intune sync. The mechanism is a restart of the
    IntuneManagementExtension service, but the UI must never say so - the user is being
    told whether their device synced, not which service was bounced.

    A restarted service is not evidence of a sync, so three things are checked:
      1. the task's exit code (its action wraps Restart-Service and exits 0 or 1)
      2. the service's host PID changed and it is Running again - this is what proves a
         real restart happened rather than nothing at all. Read via CIM, because
         Get-Process .StartTime on a SYSTEM-owned process is denied to a standard user.
      3. the IME log directory grew afterwards, which is the only local evidence that the
         agent is doing check-in work rather than merely being started.

    1 and 2 must both hold for a green tick. Without 3 the result is reported as
    "Sync not confirmed" (amber), because a service that restarted but never checked in
    has not synced anything. If the log is unreadable, that is also reported as
    unconfirmed rather than claimed as success.

    INSTALL UPDATES

    Both install buttons wait for the installation itself to finish, then report the
    outcome from the result file GR-InstallIntuneUpdates.ps1 publishes - counts, failures
    and whether a reboot is needed - rather than inferring it from an exit code. A result
    stamped before the run just triggered is rejected, so a previous outcome cannot be
    shown as this one's. "Install updates and restart" skips the restart when nothing was
    installed, since a reboot would then be disruption for no benefit, and is enabled only
    when a pending update actually reports needing a restart.

    REPEAT UNTIL CLEAR

    Ticking the checkbox makes "Install updates and restart" run unattended cycles:
    install, restart, reopen at logon, rescan, repeat. State lives in
    -UpdateLoopStateFile and the relaunch is an HKCU RunOnce entry, re-registered each
    cycle; RunOnce self-deletes when it fires, so an interrupted loop leaves nothing that
    would relaunch this app at every future logon. The user still logs in by hand - no
    credentials are stored anywhere.

    Because this reboots the machine on its own, it is bounded three independent ways and
    stops on any of them, clearing both the state file and the logon hook:
      - nothing pending (the success case)
      - -MaxUpdateLoopCycles cycles reached
      - the pending count stopped falling, so another restart would not help
    It also stops if an install or a scan fails, if the box is unticked mid-loop, and it
    will not resume if the app is reopened without -ResumeUpdateLoop.

    Note the RunOnce command line is capped at 260 characters, so settings a resumed run
    needs are carried in the state file rather than as arguments; Register-ResumeAtLogon
    throws if the command would still exceed it, rather than silently not resuming.

    COMPLIANCE SEQUENCE (Check compliance button)

    The verdict is read out of the per-user Company Portal cache, which only gets
    populated while Company Portal is running. So the check is a sequence, not a single
    call, and each step must happen in this order:

      1. If the user's cache directory holds no cache files, prime it: launch Company
         Portal in the background via 'companyportal:', wait -CachePrimeWaitSeconds,
         then kill CompanyPortal.exe. Skipped when the cache is already populated.
      2. Start GR-RunIntuneComplianceCheck, which runs deviceenroller.exe elevated.
         Wait for the task to leave the Running state.
      3. Wait -PostTaskWaitSeconds so the refreshed state lands in the cache.
      4. Relaunch Company Portal in the background so it refreshes the cache.
      5. Read the verdict out of the newest cache file (see Get-ComplianceVerdictFromCache),
         then close Company Portal - read first, close second, since the cache has to still
         be maintained while it is read. The user is warned up front to leave it alone.

      GR-InstallIntuneUpdates.ps1 must install pending updates and MUST NOT reboot.
      Reboot is owned by this GUI so that "install only" is genuinely reboot-free and
      the user always gets the countdown and a chance to cancel.

.NOTES
    The compliance parse comes from intunecompcheck.ps1: cache files are JSON whose
    'data' member is itself a JSON string, and that inner payload carries
    ComplianceState ("Compliant", "NotCompliant", "Error").

    One deliberate difference from that script. It collapses every outcome to a single
    boolean, so "not compliant", "cache file missing" and "parse failed" all become
    $IsCompliant = $false. Here, only a literal ComplianceState of Compliant goes green
    - same as the original - but the cases where nothing could be read report Unknown
    (grey) rather than red, because telling a user their device is non-compliant when
    the truth is that the cache was unreadable is a different and worse claim. Intune's
    'Error' state is likewise reported verbatim rather than shown as red.

    Company Portal is launched directly here, in the user's own session, rather than via a
    task, because the cache it populates is per-user and a SYSTEM task cannot populate it.
    (GR-RunIntunePushLaunch previously covered this and no longer exists; re-running
    New-GRIntuneScheduledTasks.ps1 unregisters it.)

    Keeping Company Portal in the background is best-effort, and deliberately cannot
    fail the check. It is a UWP app, so ShellExecute's minimise request is generally
    ignored and its top-level window belongs to ApplicationFrameHost.exe. Each launch
    therefore: waits -CompanyPortalLaunchWaitSeconds for it to start, calls
    ShowWindowAsync with SW_SHOWMINNOACTIVE (minimise *without* activating) once its
    window is found, and calls SetForegroundWindow on this GUI's own HWND to take focus
    back. Windows only honours SetForegroundWindow for a process that already owns the
    foreground, so it can legitimately fail and the app may flash into view. Priming the
    cache is the functional part; window placement is cosmetic.

    The MDM enrollment state shown under the indicator is read locally from
    HKLM\SOFTWARE\Microsoft\Enrollments, purely as context. It is not a verdict.

.PARAMETER ComplianceCacheDirectory
    The current user's Company Portal application cache. Defaults to the UWP package
    path from intunecompcheck.ps1:
    %LOCALAPPDATA%\Packages\Microsoft.CompanyPortal_8wekyb3d8bbwe\TempState\ApplicationCache
    Supports environment variables.

.PARAMETER CachePrimeWaitSeconds
    How long Company Portal stays open to populate an empty cache before being killed.

.PARAMETER PostTaskWaitSeconds
    Settle time after GR-RunIntuneComplianceCheck finishes, before Company Portal is
    relaunched and the cache is read.

.PARAMETER CompanyPortalLaunchWaitSeconds
    How long to wait after each 'companyportal:' launch for the app to start, before
    pushing its window into the background. Applies to both launches, so raising it adds
    twice as much to a full priming run.

.PARAMETER TaskPath
    Task Scheduler folder holding the GR tasks. Must match the -TaskPath that
    New-GRIntuneScheduledTasks.ps1 registered them into.

.EXAMPLE
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\GR-IntuneSelfServiceGui.ps1

.EXAMPLE
    # Shorter waits for testing the sequence.
    .\GR-IntuneSelfServiceGui.ps1 -CachePrimeWaitSeconds 5 -PostTaskWaitSeconds 5 `
        -CompanyPortalLaunchWaitSeconds 5
#>
[CmdletBinding()]
param(
    # Per-user UWP package cache for Company Portal, from intunecompcheck.ps1.
    [string]$ComplianceCacheDirectory = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.CompanyPortal_8wekyb3d8bbwe\TempState\ApplicationCache'),

    [ValidateNotNullOrEmpty()]
    [string]$TaskPath = '\GRIntune\',

    [ValidateRange(1, 300)]
    [int]$CachePrimeWaitSeconds = 10,

    [ValidateRange(1, 300)]
    [int]$PostTaskWaitSeconds = 10,

    [ValidateRange(1, 300)]
    [int]$CompanyPortalLaunchWaitSeconds = 15,

    # Published by GR-InstallIntuneUpdates.ps1; must match that script's -ResultFile.
    [ValidateNotNullOrEmpty()]
    [string]$InstallResultFile = 'C:\ProgramData\GR\IntuneSelfService\install-result.json',

    [ValidateNotNullOrEmpty()]
    [string]$ImeLogDirectory = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs',

    # Set by the logon hook this app registers for itself; not meant to be passed by hand.
    [switch]$ResumeUpdateLoop,

    [ValidateNotNullOrEmpty()]
    [string]$UpdateLoopStateFile = (Join-Path $env:LOCALAPPDATA 'GR\IntuneSelfService\update-loop.json'),
    # Keep in step with the default above; Register-ResumeAtLogon only passes the path when
    # it differs, to stay inside the RunOnce length cap.

    [ValidateRange(1, 20)]
    [int]$MaxUpdateLoopCycles = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WPF requires a single-threaded apartment. powershell.exe is STA by default; pwsh is not.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'This GUI must run in an STA thread. Relaunch with: powershell.exe -STA -NoProfile -File "' +
        $PSCommandPath + '"'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$TASK_COMPLIANCE = 'GR-RunIntuneComplianceCheck'
$TASK_RESTART_IME = 'GR-RunIntuneRestartIME'
$TASK_INSTALL_UPDATES = 'GR-InstallIntuneUpdates'
$TASK_TIMEOUT_SECONDS = 900          # 15 min ceiling for an update install
$COMPLIANCE_TIMEOUT_SECONDS = 300    # deviceenroller.exe should be far quicker than this
$RESTART_DELAY_SECONDS = 60          # user can abort with: shutdown /a
$IME_SERVICE_NAME = 'IntuneManagementExtension'
$SYNC_TASK_TIMEOUT_SECONDS = 120     # a service restart should be seconds, not minutes
$SYNC_SERVICE_WAIT_SECONDS = 60      # for the service to come back with a new PID
$SYNC_CONFIRM_WAIT_SECONDS = 45      # for the agent to show check-in activity

# UI state. Declared up front because Set-Busy/Update-ActionState read them and
# Set-StrictMode makes an unassigned variable a terminating error.
$script:PendingUpdates = @()
$script:IsBusy = $false
# This window's HWND, resolved once the window has a handle. Handed to the compliance
# worker so it can give focus back after launching Company Portal.
$script:OwnWindowHandle = [System.IntPtr]::Zero
$script:InPollTick = $false
$script:LoopActive = $false
$script:InstallWillRestart = $false

# RunOnce, not Run: it self-deletes when it fires, so an interrupted loop cannot relaunch
# this app at every future logon. Each cycle re-registers it.
$RUNONCE_KEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$RUNONCE_VALUE = 'GRIntuneSelfServiceResumeUpdates'
$RUNONCE_MAX_LENGTH = 260    # documented cap on Run/RunOnce command lines
$DEFAULT_LOOP_STATE_FILE = (Join-Path $env:LOCALAPPDATA 'GR\IntuneSelfService\update-loop.json')

# A resumed run is launched by RunOnce with almost no arguments, so anything overridable is
# recovered from the state file - unless it was passed explicitly, which wins. Done here at
# script scope, before the window exists, so the handlers see the final values.
if ($ResumeUpdateLoop -and (Test-Path -LiteralPath $UpdateLoopStateFile)) {
    try {
        $carried = Get-Content -LiteralPath $UpdateLoopStateFile -Raw | ConvertFrom-Json
        foreach ($name in @('TaskPath', 'InstallResultFile')) {
            if (-not $PSBoundParameters.ContainsKey($name) -and
                $carried.PSObject.Properties.Name -contains $name -and $carried.$name) {
                Set-Variable -Name $name -Scope Script -Value ([string]$carried.$name)
            }
        }
    }
    catch {
        Write-Verbose "Could not read carried settings from loop state: $_"
    }
}

#region XAML
# Single-quoted here-string: XAML must not be subject to PowerShell interpolation.
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GR Device Self-Service"
        Height="660" Width="900"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanMinimize"
        AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Ideal">
  <Window.Resources>
    <SolidColorBrush x:Key="AppBg"      Color="#FF101018"/>
    <SolidColorBrush x:Key="CardBg"     Color="#FF1A1A26"/>
    <SolidColorBrush x:Key="CardStroke" Color="#FF2B2B3C"/>
    <SolidColorBrush x:Key="Fg"         Color="#FFEDEDF5"/>
    <SolidColorBrush x:Key="FgMuted"    Color="#FF9797AE"/>
    <SolidColorBrush x:Key="Accent"     Color="#FF4C8DFF"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#FF27314A"/>
    <SolidColorBrush x:Key="Good"       Color="#FF22C55E"/>
    <SolidColorBrush x:Key="Bad"        Color="#FFEF4444"/>
    <SolidColorBrush x:Key="Warn"       Color="#FFF59E0B"/>
    <SolidColorBrush x:Key="Neutral"    Color="#FF4A4A5E"/>

    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardStroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20"/>
    </Style>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource FgMuted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <!-- Flat rounded button; Background supplies the accent so one template serves all. -->
    <Style x:Key="FlatButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    Padding="18,0" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.72"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.30"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource FlatButton}">
      <Setter Property="Background" Value="{StaticResource AccentSoft}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    </Style>

    <Style x:Key="AppCheckBox" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="17" Height="17" CornerRadius="4"
                      Background="#FF14141E" BorderBrush="{StaticResource CardStroke}"
                      BorderThickness="1" VerticalAlignment="Top">
                <TextBlock x:Name="Tick" Text="&#x2713;" Foreground="#FF101018"
                           FontSize="11" FontWeight="Bold" Visibility="Collapsed"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Center"
                                RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TitleBarButton" TargetType="Button">
      <Setter Property="Width" Value="44"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Foreground" Value="{StaticResource FgMuted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF2B2B3C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- Rounded outer shell, since WindowStyle=None removes the system chrome. -->
  <Border Background="{StaticResource AppBg}" CornerRadius="12" BorderThickness="1"
          BorderBrush="{StaticResource CardStroke}">
    <Grid Margin="2">
      <Grid.RowDefinitions>
        <RowDefinition Height="46"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
          <Border Width="9" Height="9" CornerRadius="4.5" Background="{StaticResource Accent}"
                  Margin="0,0,10,0"/>
          <TextBlock Text="Device Self-Service" Foreground="{StaticResource Fg}"
                     FontSize="13" FontWeight="SemiBold"/>
          <TextBlock x:Name="TxtDeviceName" Style="{StaticResource Muted}" Margin="12,1,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,8,0">
          <Button x:Name="BtnMinimize" Content="&#xE921;" Style="{StaticResource TitleBarButton}"
                  FontFamily="Segoe MDL2 Assets" ToolTip="Minimise"/>
          <Button x:Name="BtnClose" Content="&#xE8BB;" Style="{StaticResource TitleBarButton}"
                  FontFamily="Segoe MDL2 Assets" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- Body -->
      <Grid Grid.Row="1" Margin="20,4,20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="312"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- 1. Compliance -->
        <Border Grid.Column="0" Style="{StaticResource CardStyle}" Margin="0,0,10,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Device compliance" Style="{StaticResource H1}"/>

            <StackPanel Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center">
              <Grid Width="132" Height="132">
                <Ellipse x:Name="ComplianceHalo" Fill="{StaticResource Neutral}" Opacity="0.14"/>
                <Ellipse x:Name="ComplianceDot" Width="74" Height="74"
                         Fill="{StaticResource Neutral}"/>
                <TextBlock x:Name="ComplianceGlyph" Text="?" Foreground="#FF101018"
                           FontSize="34" FontWeight="Bold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
              <TextBlock x:Name="TxtComplianceState" Text="Unknown"
                         Foreground="{StaticResource Fg}" FontSize="21" FontWeight="SemiBold"
                         HorizontalAlignment="Center" Margin="0,18,0,0"/>
              <TextBlock x:Name="TxtComplianceDetail" Style="{StaticResource Muted}"
                         Text="Not checked yet." TextAlignment="Center" Margin="0,7,0,0"
                         MaxWidth="240"/>
            </StackPanel>

            <StackPanel Grid.Row="2">
              <TextBlock x:Name="TxtEnrollment" Style="{StaticResource Muted}"
                         Margin="0,0,0,12" TextAlignment="Center"/>
              <Button x:Name="BtnCheckCompliance" Content="Check compliance"
                      Style="{StaticResource FlatButton}"/>

              <Button x:Name="BtnSyncDevice" Content="Sync Device" Margin="0,10,0,0"
                      Style="{StaticResource SecondaryButton}"
                      ToolTip="Sync this device with Intune to pick up the latest policies and apps."/>

              <!-- Sync outcome: same tick/cross language as the compliance indicator,
                   scaled down so it reads as a status line under its own button. -->
              <Grid x:Name="SyncStatusRow" Margin="0,10,0,0" Visibility="Collapsed">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Width="22" Height="22" VerticalAlignment="Top">
                  <Ellipse x:Name="SyncDot" Width="22" Height="22"
                           Fill="{StaticResource Neutral}"/>
                  <TextBlock x:Name="SyncGlyph" Text="?" Foreground="#FF101018"
                             FontSize="12" FontWeight="Bold"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
                <StackPanel Grid.Column="1" Margin="9,0,0,0">
                  <TextBlock x:Name="TxtSyncState" Text="Not synced"
                             Foreground="{StaticResource Fg}" FontSize="13"
                             FontWeight="SemiBold"/>
                  <TextBlock x:Name="TxtSyncDetail" Style="{StaticResource Muted}"
                             Margin="0,2,0,0"/>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Grid>
        </Border>

        <!-- 2 + 3. Updates -->
        <Border Grid.Column="1" Style="{StaticResource CardStyle}" Margin="10,0,0,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock x:Name="TxtUpdatesHeader" Text="Pending updates"
                           Style="{StaticResource H1}"/>
                <TextBlock x:Name="TxtUpdatesSub" Style="{StaticResource Muted}"
                           Text="Scanning..." Margin="0,3,0,0"/>
              </StackPanel>
              <Button x:Name="BtnRescan" Grid.Column="1" Content="Rescan" Height="32"
                      Style="{StaticResource SecondaryButton}" FontWeight="Normal"
                      VerticalAlignment="Top"/>
            </Grid>

            <Border Grid.Row="1" CornerRadius="8" Background="#FF14141E"
                    BorderBrush="{StaticResource CardStroke}" BorderThickness="1">
              <Grid>
                <ListBox x:Name="LstUpdates" Background="Transparent" BorderThickness="0"
                         Foreground="{StaticResource Fg}" Padding="4"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                         HorizontalContentAlignment="Stretch">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Padding" Value="10,9"/>
                      <Setter Property="Background" Value="Transparent"/>
                      <Setter Property="BorderThickness" Value="0"/>
                      <Setter Property="Template">
                        <Setter.Value>
                          <ControlTemplate TargetType="ListBoxItem">
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    CornerRadius="6" Padding="{TemplateBinding Padding}">
                              <ContentPresenter/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#FF20202E"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Setter.Value>
                      </Setter>
                    </Style>
                  </ListBox.ItemContainerStyle>
                  <ListBox.ItemTemplate>
                    <DataTemplate>
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" Margin="0,0,12,0">
                          <TextBlock Text="{Binding Title}" TextWrapping="Wrap"
                                     Foreground="#FFEDEDF5" FontSize="13"/>
                          <TextBlock Text="{Binding Detail}" Foreground="#FF8B8BA2"
                                     FontSize="11" Margin="0,3,0,0"/>
                        </StackPanel>
                        <Border Grid.Column="1" VerticalAlignment="Center" CornerRadius="10"
                                Background="#FF3A2E12" Padding="8,3"
                                Visibility="{Binding RebootChipVisibility}">
                          <TextBlock Text="Needs restart" Foreground="#FFF59E0B" FontSize="10"
                                     FontWeight="SemiBold"/>
                        </Border>
                      </Grid>
                    </DataTemplate>
                  </ListBox.ItemTemplate>
                </ListBox>

                <TextBlock x:Name="TxtUpdatesEmpty" Visibility="Collapsed"
                           HorizontalAlignment="Center" VerticalAlignment="Center"
                           Foreground="{StaticResource FgMuted}" FontSize="13"/>
              </Grid>
            </Border>

            <StackPanel Grid.Row="2" Margin="0,14,0,0">
              <CheckBox x:Name="ChkRepeatUntilClear" Style="{StaticResource AppCheckBox}"
                        Margin="2,0,0,12"
                        ToolTip="Installs, restarts, reopens this app at logon and repeats until nothing is pending.">
                <TextBlock TextWrapping="Wrap">Keep installing and restarting until no updates remain<LineBreak/><Run Foreground="#FF9797AE" FontSize="11">Reopens this app automatically after each restart. You will be asked to log back in each time.</Run></TextBlock>
              </CheckBox>

              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="BtnInstall" Grid.Column="0" Content="Install updates"
                        Style="{StaticResource FlatButton}"
                        ToolTip="Installs all pending updates. The machine will not restart."/>
                <Button x:Name="BtnInstallRestart" Grid.Column="2"
                        Content="Install updates and restart"
                        Style="{StaticResource SecondaryButton}"
                        ToolTip="Enabled only when a pending update needs a restart to finish."/>
              </Grid>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- Status bar -->
      <Grid Grid.Row="2" Margin="20,14,20,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <ProgressBar x:Name="Progress" Height="3" IsIndeterminate="False" Value="0"
                       Background="#FF1E1E2C" Foreground="{StaticResource Accent}"
                       BorderThickness="0" Visibility="Hidden"/>
          <TextBlock x:Name="TxtStatus" Style="{StaticResource Muted}" Margin="0,8,0,0"
                     Text="Ready."/>
        </StackPanel>
        <TextBlock Grid.Column="1" x:Name="TxtUser" Style="{StaticResource Muted}"
                   VerticalAlignment="Bottom"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
#endregion XAML

#region Dialog XAML
# A dialog window styled like the app, replacing System.Windows.MessageBox - whose Win32
# chrome looks nothing like the rest of this. Carries its own copy of the styles it needs,
# because a separate Window cannot see the main window's resources.
$dialogXamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        AllowsTransparency="True" Background="Transparent"
        SizeToContent="Height" Width="460"
        WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="CardBg"     Color="#FF1A1A26"/>
    <SolidColorBrush x:Key="CardStroke" Color="#FF2B2B3C"/>
    <SolidColorBrush x:Key="Fg"         Color="#FFEDEDF5"/>
    <SolidColorBrush x:Key="FgMuted"    Color="#FFA6A6BC"/>
    <SolidColorBrush x:Key="Accent"     Color="#FF4C8DFF"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#FF27314A"/>

    <Style x:Key="DlgButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="MinWidth" Value="104"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    Padding="16,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.72"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DlgButtonQuiet" TargetType="Button" BasedOn="{StaticResource DlgButton}">
      <Setter Property="Background" Value="{StaticResource AccentSoft}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource CardBg}" CornerRadius="12"
          BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="24">
    <StackPanel>
      <Grid x:Name="DlgDragArea" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid Width="36" Height="36" VerticalAlignment="Top">
          <Ellipse x:Name="DlgIconDot" Width="36" Height="36" Fill="{StaticResource Accent}"/>
          <TextBlock x:Name="DlgIconGlyph" Text="i" Foreground="#FF101018"
                     FontSize="19" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel Grid.Column="1" Margin="15,0,0,0">
          <TextBlock x:Name="DlgTitle" Foreground="{StaticResource Fg}" FontSize="15.5"
                     FontWeight="SemiBold" TextWrapping="Wrap"/>
          <TextBlock x:Name="DlgMessage" Foreground="{StaticResource FgMuted}" FontSize="12.5"
                     TextWrapping="Wrap" Margin="0,9,0,0" LineHeight="19"/>
        </StackPanel>
      </Grid>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button x:Name="DlgSecondary" Content="Cancel" Margin="0,0,10,0"
                Style="{StaticResource DlgButtonQuiet}" Visibility="Collapsed"/>
        <Button x:Name="DlgPrimary" Content="OK" Style="{StaticResource DlgButton}"
                IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
#endregion Dialog XAML

[xml]$xamlDoc = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
$window = [Windows.Markup.XamlReader]::Load($reader)

# Resolve every named control once into a hashtable, so a XAML rename fails loudly here
# rather than as a null-reference deep inside an event handler.
$ui = @{}
foreach ($name in @(
        'TitleBar', 'BtnMinimize', 'BtnClose', 'TxtDeviceName', 'TxtUser',
        'ComplianceHalo', 'ComplianceDot', 'ComplianceGlyph', 'TxtComplianceState',
        'TxtComplianceDetail', 'TxtEnrollment', 'BtnCheckCompliance',
        'BtnSyncDevice', 'SyncStatusRow', 'SyncDot', 'SyncGlyph', 'TxtSyncState', 'TxtSyncDetail',
        'TxtUpdatesHeader', 'TxtUpdatesSub', 'BtnRescan', 'LstUpdates', 'TxtUpdatesEmpty',
        'BtnInstall', 'BtnInstallRestart', 'ChkRepeatUntilClear', 'Progress', 'TxtStatus')) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "XAML is missing an element named '$name'." }
    $ui[$name] = $control
}

#region Async plumbing
# WPF event handlers run on the UI thread, so any work that blocks - a WUA scan takes tens
# of seconds, an update install takes minutes - has to leave that thread or the window
# freezes. Each job runs in its own runspace; a DispatcherTimer polls for completion and
# invokes the continuation back on the UI thread, which avoids marshalling a callback
# across threads by hand.
$script:Jobs = New-Object System.Collections.ArrayList

function Start-AsyncWork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$Arguments = @{},
        [Parameter(Mandatory)][scriptblock]$OnSuccess,
        [Parameter(Mandatory)][scriptblock]$OnFailure
    )

    $shell = [PowerShell]::Create()
    $null = $shell.AddScript($Work.ToString())
    foreach ($key in $Arguments.Keys) { $null = $shell.AddParameter($key, $Arguments[$key]) }

    $null = $script:Jobs.Add([PSCustomObject]@{
            Shell     = $shell
            Handle    = $shell.BeginInvoke()
            OnSuccess = $OnSuccess
            OnFailure = $OnFailure
            # How many Information records have already been shown, so the poll tick only
            # surfaces new ones. A multi-step sequence reports progress through this stream.
            Reported  = 0
        })
}

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$pollTimer.Add_Tick({
        # Continuations can open a modal dialog, and ShowDialog pumps a nested message loop
        # that keeps firing this timer. Without a guard the same job list would be processed
        # re-entrantly while an earlier tick is still blocked on the dialog.
        if ($script:InPollTick) { return }
        $script:InPollTick = $true
        try {
            Invoke-JobPoll
        }
        finally {
            $script:InPollTick = $false
        }
    })

function Invoke-JobPoll {
    [CmdletBinding()]
    param()

    for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
        $job = $script:Jobs[$i]

        # Drain any new progress lines the worker wrote, whether or not it has finished.
        $info = $job.Shell.Streams.Information
        if ($info.Count -gt $job.Reported) {
            $ui['TxtStatus'].Text = [string]$info[$info.Count - 1].MessageData
            $job.Reported = $info.Count
        }

        if (-not $job.Handle.IsCompleted) { continue }

        $script:Jobs.RemoveAt($i)
        try {
            $output = $job.Shell.EndInvoke($job.Handle)
            # A terminating error inside the runspace surfaces here, not as an exception.
            if ($job.Shell.HadErrors -and $job.Shell.Streams.Error.Count -gt 0) {
                throw $job.Shell.Streams.Error[0].Exception
            }
            & $job.OnSuccess $output
        }
        catch {
            & $job.OnFailure $_
        }
        finally {
            $job.Shell.Dispose()
        }
    }
}
#endregion Async plumbing

#region Worker scriptblocks
# These execute in a separate runspace and therefore cannot see anything defined above -
# each one must be self-contained and take everything it needs as a parameter.

$scanUpdatesWork = {
    # Read-only WUA query; permitted for standard users. Slow, hence off the UI thread.
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    try {
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search('IsInstalled=0 AND IsHidden=0')

        foreach ($update in $result.Updates) {
            $kb = @($update.KBArticleIDs | ForEach-Object { "KB$_" }) -join ', '
            $sizeMb = [math]::Round($update.MaxDownloadSize / 1MB, 1)
            # 1 = alwaysRequiresReboot, 2 = canRequestReboot
            $needsReboot = $update.InstallationBehavior.RebootBehavior -ne 0

            $detail = @()
            if ($kb) { $detail += $kb }
            if ($sizeMb -gt 0) { $detail += "$sizeMb MB" }
            if ($update.IsMandatory) { $detail += 'Mandatory' }

            [PSCustomObject]@{
                Title                = $update.Title
                Detail               = ($detail -join '  -  ')
                NeedsReboot          = $needsReboot
                RebootChipVisibility = if ($needsReboot) { 'Visible' } else { 'Collapsed' }
            }
        }
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($session)
    }
}

$installUpdatesWork = {
    <#
        Starts GR-InstallIntuneUpdates, waits for the whole installation to finish, then
        reads the result file that script publishes, so the GUI can report what actually
        happened rather than just "the task exited".
    #>
    param(
        [string]$TaskName,
        [string]$TaskPath,
        [string]$ResultFile,
        [int]$TimeoutSeconds,
        [datetime]$NotBeforeUtc
    )

    $InformationPreference = 'Continue'
    $ErrorActionPreference = 'Stop'

    # Started, not created: the task already exists and runs as SYSTEM. A standard user can
    # only get here because the task DACL grants BUILTIN\Users GENERIC_EXECUTE.
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "Scheduled task '$TaskName' is not registered on this machine. An administrator must run New-GRIntuneScheduledTasks.ps1."
    }

    Write-Information 'Starting the update installation...'
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

    # Wait for the installation itself to finish, not merely for the task to have started.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $elapsed = 0
    do {
        Start-Sleep -Seconds 5
        $elapsed += 5
        $state = (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath).State
        if ($state -eq 'Running' -and $elapsed % 30 -eq 0) {
            Write-Information "Still installing - $([int]($elapsed / 60)) min elapsed..."
        }
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($state -eq 'Running') {
        throw "The installation was still running after $TimeoutSeconds seconds. It may finish in the background; check Windows Update later."
    }

    $lastResult = (Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath).LastTaskResult

    # The run publishes its own outcome; prefer that over inferring from an exit code.
    $result = $null
    if ($ResultFile -and (Test-Path -LiteralPath $ResultFile)) {
        try {
            $parsed = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
            $startedAt = $null
            if ($parsed.PSObject.Properties.Name -contains 'StartedAt' -and $parsed.StartedAt) {
                $startedAt = ([datetime]$parsed.StartedAt).ToUniversalTime()
            }
            # Reject a result written before this run, so a previous outcome can never be
            # reported as if it were this one's. Small allowance for clock granularity.
            if ($startedAt -and $startedAt -ge $NotBeforeUtc.AddSeconds(-5)) { $result = $parsed }
        }
        catch { }
    }

    if ($result) {
        return [PSCustomObject]@{
            Outcome        = [string]$result.Outcome
            Message        = [string]$result.Message
            RebootRequired = [bool]$result.RebootRequired
            ExitCode       = $lastResult
        }
    }

    # No usable result file: fall back to the exit code alone, and say that is all we have.
    if ($lastResult -ne 0) {
        throw ("The installation failed (exit code 0x{0:X8}) and published no result." -f $lastResult)
    }

    [PSCustomObject]@{
        Outcome        = 'Unknown'
        Message        = 'The installation finished but did not report what it did. Check the pending list.'
        RebootRequired = $false
        ExitCode       = $lastResult
    }
}

$checkComplianceWork = {
    <#
        The full compliance sequence. Runs in the user's own session, which matters: the
        Company Portal cache is per-user, so a SYSTEM task cannot populate it. Only the
        deviceenroller.exe step needs elevation, and that is what the scheduled task is for.

        Progress is reported through Write-Information, which the UI thread drains from
        $shell.Streams.Information and shows in the status bar.
    #>
    param(
        [string]$CacheDirectory,
        [string]$TaskName,
        [string]$TaskPath,
        [int]$CachePrimeWaitSeconds,
        [int]$PostTaskWaitSeconds,
        [int]$TaskTimeoutSeconds,
        [int]$LaunchWaitSeconds,
        [System.IntPtr]$OwnerWindowHandle
    )

    $InformationPreference = 'Continue'
    $ErrorActionPreference = 'Stop'

    # Company Portal is a UWP app: ShellExecute's minimise request is generally ignored and
    # the top-level window belongs to ApplicationFrameHost.exe, so it has to be pushed into
    # the background explicitly once it appears. Guarded because each job is a new runspace
    # in the same AppDomain and re-adding an existing type throws.
    if (-not ('GRNativeWindow' -as [type])) {
        Add-Type -Namespace '' -Name 'GRNativeWindow' -MemberDefinition @'
            [DllImport("user32.dll")]
            public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
            [DllImport("user32.dll")]
            public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
    }
    # SHOWMINNOACTIVE, not MINIMIZE: minimise *without activating*, so pushing Company
    # Portal down does not itself hand focus to whatever is behind it.
    $SW_SHOWMINNOACTIVE = 7

    function Get-CompanyPortalWindow {
        # The CompanyPortal process often reports MainWindowHandle 0 because its frame is
        # owned by ApplicationFrameHost, so check both.
        $candidates = @(Get-Process -Name 'CompanyPortal' -ErrorAction SilentlyContinue) +
        @(Get-Process -Name 'ApplicationFrameHost' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle -like '*Company Portal*' })
        $candidates | Where-Object { $_.MainWindowHandle -ne [System.IntPtr]::Zero } |
            Select-Object -First 1
    }

    function Set-OwnerWindowForeground {
        # Launching a UWP app steals focus, so hand it straight back to this GUI. Best
        # effort: Windows only honours SetForegroundWindow for a process that already owns
        # the foreground, so this can legitimately fail - never let it break the sequence.
        if ($OwnerWindowHandle -ne [System.IntPtr]::Zero) {
            [void][GRNativeWindow]::SetForegroundWindow($OwnerWindowHandle)
        }
    }

    function Start-CompanyPortalInBackground {
        Write-Information 'Opening Company Portal in the background...'
        Start-Process 'companyportal:' -WindowStyle Minimized

        # A fixed settle period after launch: Company Portal needs time to start before its
        # window exists to be pushed down, and before it begins writing the cache.
        Write-Information "Waiting $LaunchWaitSeconds s for Company Portal to start..."
        Start-Sleep -Seconds $LaunchWaitSeconds
        Set-OwnerWindowForeground

        # Then push its window down, giving it a little longer to appear if it has not yet.
        # A briefly visible window is cosmetic; populating the cache is the functional part,
        # so failing to background it must not fail the check.
        for ($i = 0; $i -lt 20; $i++) {
            $proc = Get-CompanyPortalWindow
            if ($proc) {
                [void][GRNativeWindow]::ShowWindowAsync($proc.MainWindowHandle, $SW_SHOWMINNOACTIVE)
                Set-OwnerWindowForeground
                return
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Information 'Company Portal window did not appear in time to be backgrounded; continuing.'
    }

    function Stop-CompanyPortal {
        Write-Information 'Closing Company Portal...'
        Get-Process -Name 'CompanyPortal' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # The emptiness probe and the parser must look at the same file set, or the sequence can
    # skip priming on files it then turns out to be unable to read.
    $cacheInclude = @('*.tmp*', '*.json')

    function Get-CacheFile {
        param([string]$Path)
        Get-ChildItem -Path $Path -Include $cacheInclude -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    }

    function Test-CacheIsEmpty {
        param([string]$Path)
        if (-not $Path) { return $true }
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        return (@(Get-CacheFile -Path $Path).Count -eq 0)
    }

    function Get-ComplianceVerdictFromCache {
        <#
            Parses the Company Portal application cache, per intunecompcheck.ps1: the cache
            file holds JSON whose 'data' member is itself a JSON string, and that inner
            payload carries ComplianceState.

            Deviation from intunecompcheck.ps1, which collapses everything to a single
            boolean: that script sets $IsCompliant = $false for "not compliant", "cache
            file missing" and "parse failed" alike. This GUI has a three-state indicator,
            and showing red for "we could not read the cache" would tell the user their
            device is non-compliant when the truth is that we do not know. Only a literal
            ComplianceState of Compliant goes green - matching the original - but the
            unreadable cases report Unknown/grey instead of red.
        #>
        param([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) {
            return [PSCustomObject]@{
                State  = 'Unknown'
                Reason = "Company Portal cache directory not found at '$Path'. Ensure the user has signed in to the Company Portal app at least once."
            }
        }

        $files = @(Get-CacheFile -Path $Path)
        if ($files.Count -eq 0) {
            return [PSCustomObject]@{
                State  = 'Unknown'
                Reason = 'Company Portal cache file not found. Ensure the user has signed in to the Company Portal app at least once.'
            }
        }

        # Newest first, as in intunecompcheck.ps1, but keep going until one actually yields a
        # ComplianceState: the most recently written file is not always the one holding sync
        # telemetry, and stopping at the first file makes the check flaky. Bounded so a large
        # cache cannot stall the UI.
        $examined = 0
        foreach ($file in $files) {
            if ($examined -ge 25) { break }
            $examined++

            try {
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            }
            catch { continue }

            if (-not $raw -or $raw.PSObject.Properties.Name -notcontains 'data' -or -not $raw.data) { continue }

            try {
                $payload = $raw.data | ConvertFrom-Json
            }
            catch { continue }

            $state = [string]$payload.ComplianceState
            if (-not $state) { continue }

            $stamp = $file.LastWriteTime.ToString('HH:mm:ss')
            switch -Regex ($state) {
                '^Compliant$' {
                    return [PSCustomObject]@{
                        State  = 'Compliant'
                        Reason = "Company Portal reported ComplianceState = Compliant (cache written $stamp)."
                    }
                }
                '^(Not|Non)Compliant$' {
                    return [PSCustomObject]@{
                        State  = 'NonCompliant'
                        Reason = "Company Portal reported ComplianceState = $state (cache written $stamp)."
                    }
                }
                default {
                    # Intune's 'Error' state lands here: not a confirmed failure, so it is
                    # reported as-is rather than shown as non-compliant. Move this into the
                    # NonCompliant branch if you would rather treat Error as red.
                    return [PSCustomObject]@{
                        State  = 'Unknown'
                        Reason = "Company Portal reported ComplianceState = '$state', which is neither Compliant nor NotCompliant, so no verdict was assumed (cache written $stamp)."
                    }
                }
            }
        }

        [PSCustomObject]@{
            State  = 'Unknown'
            Reason = "Read $examined cache file(s) but none contained a readable data.ComplianceState value."
        }
    }

    # --- Preconditions -----------------------------------------------------------------
    if (-not $CacheDirectory) {
        throw 'No Company Portal cache directory configured. Pass -ComplianceCacheDirectory with the path defined in intunecompcheck.ps1.'
    }
    $CacheDirectory = [System.Environment]::ExpandEnvironmentVariables($CacheDirectory)

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "Scheduled task '$TaskName' is not registered on this machine. An administrator must run New-GRIntuneScheduledTasks.ps1."
    }

    # --- 1. Prime the cache, but only if it is empty ------------------------------------
    if (Test-CacheIsEmpty -Path $CacheDirectory) {
        Write-Information 'Cache is empty - priming it with Company Portal...'
        Start-CompanyPortalInBackground
        Write-Information "Letting Company Portal populate the cache ($CachePrimeWaitSeconds s)..."
        Start-Sleep -Seconds $CachePrimeWaitSeconds
        Stop-CompanyPortal
    }
    else {
        Write-Information 'Cache already populated - skipping the priming step.'
    }

    # --- 2. Elevated compliance evaluation ----------------------------------------------
    # Started, not created: the task already exists and runs as SYSTEM. A standard user can
    # only get here because its DACL grants BUILTIN\Users GENERIC_EXECUTE.
    Write-Information 'Running the compliance check as SYSTEM (deviceenroller.exe)...'
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

    $deadline = (Get-Date).AddSeconds($TaskTimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($state -eq 'Running') {
        throw "Task '$TaskName' was still running after $TaskTimeoutSeconds seconds; giving up on waiting for it."
    }

    $lastResult = (Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath).LastTaskResult
    if ($lastResult -ne 0) {
        throw ("Task '$TaskName' finished with exit code 0x{0:X8}." -f $lastResult)
    }

    # --- 3. Let the refreshed state land ------------------------------------------------
    Write-Information "Waiting $PostTaskWaitSeconds s for the refreshed state to reach the cache..."
    Start-Sleep -Seconds $PostTaskWaitSeconds

    # --- 4. Reopen Company Portal so it refreshes the cache -----------------------------
    Start-CompanyPortalInBackground

    # --- 5. Read the verdict, then close Company Portal ---------------------------------
    Write-Information 'Reading compliance state from the cache...'
    $verdict = Get-ComplianceVerdictFromCache -Path $CacheDirectory

    # Read first, close second: the cache must still be being maintained while it is read.
    # Closing it afterwards means the user is not left with a window they did not open.
    Stop-CompanyPortal

    $verdict
}

$syncDeviceWork = {
    <#
        Starts GR-RunIntuneRestartIME and then establishes whether the Intune Management
        Extension actually went away and came back and started talking to Intune - not
        merely that a service is running, which would also be true if nothing had happened.

        Three pieces of evidence, strongest first:
          1. the task's own exit code (its action wraps Restart-Service and exits 0 or 1)
          2. the service's host PID changed and the service is Running again - this is what
             proves a genuine restart. Read via CIM, because Get-Process .StartTime on a
             SYSTEM-owned process is access-denied for a standard user.
          3. the IME log grew after the restart, which is the only local evidence that the
             agent is doing check-in work rather than just sitting there started.

        1 and 2 must hold to report success. 3 is corroborating: without it the sync is
        reported as started-but-unconfirmed rather than successful, because a restarted
        service that never checks in has not synced anything.
    #>
    param(
        [string]$TaskName,
        [string]$TaskPath,
        [string]$ServiceName,
        [string]$LogDirectory,
        [int]$TaskTimeoutSeconds,
        [int]$ServiceWaitSeconds,
        [int]$LogWaitSeconds
    )

    $InformationPreference = 'Continue'
    $ErrorActionPreference = 'Stop'

    function Get-ServicePid {
        param([string]$Name)
        try {
            $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
            if ($svc) { return [int]$svc.ProcessId }
        }
        catch { }
        return -1
    }

    function Get-ServiceState {
        param([string]$Name)
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc) { return [string]$svc.Status }
        return 'NotFound'
    }

    function Get-LogFingerprint {
        # Total bytes across the IME logs. Cheap, and a strictly increasing signal: if this
        # grows after the restart, the agent is writing, which means it is working.
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return -1 }
        try {
            $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.log' -File -ErrorAction Stop)
            if ($files.Count -eq 0) { return 0 }
            return [int64](($files | Measure-Object -Property Length -Sum).Sum)
        }
        catch { return -1 }   # unreadable (ACL); corroboration simply unavailable
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "The $ServiceName service is not installed on this device, so it cannot be synced with Intune."
    }

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "Scheduled task '$TaskName' is not registered on this machine. An administrator must run New-GRIntuneScheduledTasks.ps1."
    }

    # --- Baseline, before anything is disturbed -----------------------------------------
    $pidBefore = Get-ServicePid -Name $ServiceName
    $logBefore = Get-LogFingerprint -Path $LogDirectory
    Write-Information 'Requesting a sync with Intune...'

    # --- Trigger ------------------------------------------------------------------------
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

    $deadline = (Get-Date).AddSeconds($TaskTimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $state = (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($state -eq 'Running') {
        throw "The sync request was still running after $TaskTimeoutSeconds seconds; giving up on waiting for it."
    }

    $lastResult = (Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath).LastTaskResult
    if ($lastResult -ne 0) {
        return [PSCustomObject]@{
            State  = 'Failed'
            Reason = ('The sync request could not be completed (exit code 0x{0:X8}). The Intune agent may be in a bad state; try again, then contact IT if it keeps failing.' -f $lastResult)
        }
    }

    # --- Evidence 2: the agent really did restart ---------------------------------------
    Write-Information 'Waiting for the Intune agent to come back...'
    $pidAfter = -1
    $running = $false
    $serviceDeadline = (Get-Date).AddSeconds($ServiceWaitSeconds)
    while ((Get-Date) -lt $serviceDeadline) {
        Start-Sleep -Seconds 1
        $running = (Get-ServiceState -Name $ServiceName) -eq 'Running'
        $pidAfter = Get-ServicePid -Name $ServiceName
        if ($running -and $pidAfter -gt 0 -and $pidAfter -ne $pidBefore) { break }
    }

    if (-not $running) {
        return [PSCustomObject]@{
            State  = 'Failed'
            Reason = "The Intune agent did not come back within $ServiceWaitSeconds seconds, so the device was not synced. Try again, then contact IT if it keeps failing."
        }
    }

    $restartConfirmed = ($pidAfter -gt 0 -and $pidAfter -ne $pidBefore)

    # --- Evidence 3: it is actually doing check-in work ---------------------------------
    Write-Information 'Confirming the sync with Intune...'
    $logGrew = $false
    if ($logBefore -ge 0) {
        $logDeadline = (Get-Date).AddSeconds($LogWaitSeconds)
        while ((Get-Date) -lt $logDeadline) {
            Start-Sleep -Seconds 2
            if ((Get-LogFingerprint -Path $LogDirectory) -gt $logBefore) { $logGrew = $true; break }
        }
    }

    if ($restartConfirmed -and $logGrew) {
        return [PSCustomObject]@{
            State  = 'Synced'
            Reason = 'This device has checked in with Intune. New policies and apps will apply shortly.'
        }
    }

    if ($restartConfirmed -and $logBefore -lt 0) {
        # Log unreadable, so step 3 could not be attempted either way. Say so rather than
        # claiming a confirmed sync off the back of a restart alone.
        return [PSCustomObject]@{
            State  = 'Unconfirmed'
            Reason = 'The sync was requested and the Intune agent restarted, but it could not be confirmed on this device. Check again in a few minutes.'
        }
    }

    [PSCustomObject]@{
        State  = 'Unconfirmed'
        Reason = "The sync was requested but Intune did not confirm it within $LogWaitSeconds seconds. It may still complete in the background; check again in a few minutes."
    }
}

$readEnrollmentWork = {
    # Local, read-only context only - this is enrollment state, not a compliance verdict.
    $enrollments = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\{?[0-9A-Fa-f-]{36}\}?$' }

    foreach ($key in $enrollments) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($props -and $props.PSObject.Properties.Name -contains 'EnrollmentState' -and
            $props.PSObject.Properties.Name -contains 'ProviderID' -and $props.ProviderID) {
            return [PSCustomObject]@{
                Enrolled   = ($props.EnrollmentState -eq 1)
                ProviderID = [string]$props.ProviderID
            }
        }
    }

    [PSCustomObject]@{ Enrolled = $false; ProviderID = $null }
}
#endregion Worker scriptblocks

#region UI helpers
function Update-ActionState {
    <#
        Single place that decides button enablement, derived from busy state + update count.
        Keeping it here means Set-Busy and Show-Updates can run in either order without one
        silently re-enabling what the other just disabled.
    #>
    foreach ($key in @('BtnCheckCompliance', 'BtnSyncDevice', 'BtnRescan')) {
        $ui[$key].IsEnabled = -not $script:IsBusy
    }

    # Install needs something to install; install-and-restart additionally needs at least
    # one update that actually wants a restart, so the button cannot offer a pointless reboot.
    $hasUpdates = @($script:PendingUpdates).Count -gt 0
    $needsRestart = @($script:PendingUpdates | Where-Object { $_.NeedsReboot }).Count -gt 0

    $ui['BtnInstall'].IsEnabled = (-not $script:IsBusy) -and $hasUpdates
    $ui['BtnInstallRestart'].IsEnabled = (-not $script:IsBusy) -and $needsRestart
    $ui['ChkRepeatUntilClear'].IsEnabled = (-not $script:IsBusy) -and $needsRestart
}

function Set-Busy {
    param([Parameter(Mandatory)][bool]$Busy, [string]$Message)

    $script:IsBusy = $Busy
    Update-ActionState

    $ui['Progress'].IsIndeterminate = $Busy
    $ui['Progress'].Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    if ($PSBoundParameters.ContainsKey('Message')) { $ui['TxtStatus'].Text = $Message }
}

function Set-ComplianceIndicator {
    param(
        [Parameter(Mandatory)][ValidateSet('Compliant', 'NonCompliant', 'Checking', 'Unknown')]
        [string]$State,
        [string]$Detail
    )

    $look = switch ($State) {
        'Compliant' { @{ Brush = 'Good'; Glyph = [char]0x2713; Label = 'Compliant' } }
        'NonCompliant' { @{ Brush = 'Bad'; Glyph = [char]0x2715; Label = 'Not compliant' } }
        'Checking' { @{ Brush = 'Warn'; Glyph = [char]0x22EF; Label = 'Checking...' } }
        default { @{ Brush = 'Neutral'; Glyph = '?'; Label = 'Unknown' } }
    }

    $brush = $window.FindResource($look.Brush)
    $ui['ComplianceDot'].Fill = $brush
    $ui['ComplianceHalo'].Fill = $brush
    $ui['ComplianceGlyph'].Text = [string]$look.Glyph
    $ui['TxtComplianceState'].Text = $look.Label
    if ($PSBoundParameters.ContainsKey('Detail')) { $ui['TxtComplianceDetail'].Text = $Detail }
}

function Show-AppDialog {
    <#
        Modal dialog in the app's own styling. Returns $true when the primary button was
        pressed, $false otherwise (including the Esc key), so an OKCancel dialog reads as
        `if (Show-AppDialog ...) { ... }`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Message = '',
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Question')][string]$Icon = 'Info',
        [switch]$Cancellable,
        [string]$PrimaryText = 'OK',
        [string]$SecondaryText = 'Cancel'
    )

    [xml]$doc = $dialogXamlText
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))

    $look = switch ($Icon) {
        'Success' { @{ Colour = '#FF22C55E'; Glyph = [char]0x2713 } }
        'Warning' { @{ Colour = '#FFF59E0B'; Glyph = '!' } }
        'Error' { @{ Colour = '#FFEF4444'; Glyph = [char]0x2715 } }
        'Question' { @{ Colour = '#FF4C8DFF'; Glyph = '?' } }
        default { @{ Colour = '#FF4C8DFF'; Glyph = 'i' } }
    }

    $dlg.FindName('DlgIconDot').Fill =
    (New-Object System.Windows.Media.BrushConverter).ConvertFromString($look.Colour)
    $dlg.FindName('DlgIconGlyph').Text = [string]$look.Glyph
    $dlg.FindName('DlgTitle').Text = $Title
    $dlg.FindName('DlgMessage').Text = $Message
    $dlg.FindName('DlgPrimary').Content = $PrimaryText

    # GetNewClosure so the handlers capture *this* dialog rather than resolving $dlg from
    # whatever scope happens to be current when the click fires.
    $secondary = $dlg.FindName('DlgSecondary')
    if ($Cancellable) {
        $secondary.Content = $SecondaryText
        $secondary.Visibility = 'Visible'
        $secondary.IsCancel = $true   # Esc also closes with $false
        $secondary.Add_Click({ $dlg.DialogResult = $false }.GetNewClosure())
    }

    $dlg.FindName('DlgPrimary').Add_Click({ $dlg.DialogResult = $true }.GetNewClosure())
    # No chrome, so the header doubles as the drag handle.
    $dlg.FindName('DlgDragArea').Add_MouseLeftButtonDown({ $dlg.DragMove() }.GetNewClosure())

    # Owned and centred on the app, so it behaves like part of it rather than a stray window.
    if ($window.IsVisible) { $dlg.Owner = $window }

    $result = $dlg.ShowDialog()
    return ($result -eq $true)
}

function Set-SyncIndicator {
    <#
        Deliberately phrased as an Intune sync outcome, never as "the service restarted".
        Restarting the IME is the mechanism; what the user cares about is whether the
        device synced, and the mechanism should not leak into the UI.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Synced', 'Unconfirmed', 'Failed', 'Syncing')]
        [string]$State,
        [string]$Detail
    )

    $look = switch ($State) {
        'Synced' { @{ Brush = 'Good'; Glyph = [char]0x2713; Label = 'Synced with Intune' } }
        'Failed' { @{ Brush = 'Bad'; Glyph = [char]0x2715; Label = 'Sync failed' } }
        'Syncing' { @{ Brush = 'Warn'; Glyph = [char]0x22EF; Label = 'Syncing...' } }
        default { @{ Brush = 'Warn'; Glyph = '!'; Label = 'Sync not confirmed' } }
    }

    $ui['SyncStatusRow'].Visibility = 'Visible'
    $ui['SyncDot'].Fill = $window.FindResource($look.Brush)
    $ui['SyncGlyph'].Text = [string]$look.Glyph
    $ui['TxtSyncState'].Text = $look.Label
    if ($PSBoundParameters.ContainsKey('Detail')) { $ui['TxtSyncDetail'].Text = $Detail }
}

function Show-Updates {
    param([object[]]$Updates)

    # A runspace that produced no output hands back $null, and @($null) is a one-element
    # array, so filter rather than wrapping or an empty scan reports "1 update pending".
    $script:PendingUpdates = @($Updates | Where-Object { $null -ne $_ })
    $ui['LstUpdates'].ItemsSource = $script:PendingUpdates

    $count = $script:PendingUpdates.Count
    $ui['TxtUpdatesHeader'].Text = if ($count) { "Pending updates ($count)" } else { 'Pending updates' }

    if ($count -eq 0) {
        $ui['TxtUpdatesEmpty'].Text = 'No pending updates - this device is up to date.'
        $ui['TxtUpdatesEmpty'].Visibility = 'Visible'
        $ui['TxtUpdatesSub'].Text = 'Nothing to install.'
    }
    else {
        $ui['TxtUpdatesEmpty'].Visibility = 'Collapsed'
        $rebootCount = @($script:PendingUpdates | Where-Object { $_.NeedsReboot }).Count
        $ui['TxtUpdatesSub'].Text = if ($rebootCount) {
            "$rebootCount of $count will need a restart to finish."
        }
        else {
            'None of these require a restart.'
        }
    }

    # Reflect the new count onto the install buttons without touching the busy state.
    Update-ActionState
}

#region Repeat-until-clear loop
# An unattended install/restart cycle, so it is bounded on three independent axes: a cycle
# ceiling, a no-progress detector, and a user-visible stop. Without those, one update that
# fails and re-offers itself forever would reboot the machine forever.

function Get-UpdateLoopState {
    if (-not (Test-Path -LiteralPath $UpdateLoopStateFile)) { return $null }
    try {
        return Get-Content -LiteralPath $UpdateLoopStateFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Unreadable loop state, ignoring: $_"
        return $null
    }
}

function Save-UpdateLoopState {
    param([Parameter(Mandatory)][hashtable]$State)

    # Carried in the file rather than on the RunOnce command line, which is length-capped.
    # A resumed run picks these up unless they were passed explicitly.
    $State['TaskPath'] = $TaskPath
    $State['InstallResultFile'] = $InstallResultFile

    $dir = [System.IO.Path]::GetDirectoryName($UpdateLoopStateFile)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $UpdateLoopStateFile -Encoding UTF8
}

function Clear-UpdateLoop {
    <#
        Belt and braces: remove both the state file and the logon hook, so an abandoned loop
        cannot resurrect itself after the user thinks it has stopped.
    #>
    Unregister-ResumeAtLogon
    if (Test-Path -LiteralPath $UpdateLoopStateFile) {
        Remove-Item -LiteralPath $UpdateLoopStateFile -Force -ErrorAction SilentlyContinue
    }
    $script:LoopActive = $false
}

function Register-ResumeAtLogon {
    <#
        RunOnce rather than Run: it self-deletes when it fires, so a crash mid-cycle leaves
        nothing behind that would relaunch this app at every future logon. Each cycle
        re-registers it. HKCU, so no elevation and it only affects this user.

        Run/RunOnce command lines are capped at 260 characters, which is easily blown by a
        few quoted paths. So the settings a resumed run needs live in the state file, and
        only the state file path is passed - and only when it is not the default.
    #>
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $parts = @(
        "`"$exe`"", '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", '-ResumeUpdateLoop'
    )
    if ($UpdateLoopStateFile -ne $DEFAULT_LOOP_STATE_FILE) {
        $parts += @('-UpdateLoopStateFile', "`"$UpdateLoopStateFile`"")
    }
    $command = $parts -join ' '

    if ($command.Length -gt $RUNONCE_MAX_LENGTH) {
        # Fail loudly here rather than silently not resuming after the restart.
        throw ("Cannot set up the restart hook: the command is $($command.Length) characters " +
            "and RunOnce accepts at most $RUNONCE_MAX_LENGTH. Move this script to a shorter path, " +
            'or run without the repeat option.')
    }

    $null = New-ItemProperty -Path $RUNONCE_KEY -Name $RUNONCE_VALUE `
        -Value $command -PropertyType String -Force
}

function Unregister-ResumeAtLogon {
    Remove-ItemProperty -Path $RUNONCE_KEY -Name $RUNONCE_VALUE -ErrorAction SilentlyContinue
}

function Resolve-UpdateLoop {
    <#
        Called after a scan completes while a loop is active. Decides whether to run another
        install/restart cycle or stop, and reports why.
    #>
    $state = Get-UpdateLoopState
    if (-not $state) { $script:LoopActive = $false; Update-ActionState; return }

    $pending = @($script:PendingUpdates).Count
    $cycle = [int]$state.Cycle
    $max = [int]$state.MaxCycles
    $previous = [int]$state.LastPendingCount

    # Done: nothing left to install.
    if ($pending -eq 0) {
        Clear-UpdateLoop
        Update-ActionState
        Set-Busy -Busy $false -Message "Finished - no updates pending after $cycle restart(s)."
        [void](Show-AppDialog -Title 'All updates installed' -Icon 'Success' -Message (
                "This device is now up to date. It took $cycle install/restart cycle(s)." ))
        return
    }

    # Give up: too many cycles.
    if ($cycle -ge $max) {
        Clear-UpdateLoop
        Update-ActionState
        Set-Busy -Busy $false -Message "Stopped after $cycle cycles with $pending update(s) still pending."
        [void](Show-AppDialog -Title 'Stopped repeating' -Icon 'Warning' -Message (
                "After $cycle install and restart cycles, $pending update(s) are still pending, " +
                'so the loop was stopped rather than restarting again. Install them manually or contact IT.' ))
        return
    }

    # Give up: the pending count is not coming down, so another reboot will not help.
    if ($previous -gt 0 -and $pending -ge $previous) {
        Clear-UpdateLoop
        Update-ActionState
        Set-Busy -Busy $false -Message "Stopped - $pending update(s) pending and not reducing."
        [void](Show-AppDialog -Title 'Stopped repeating' -Icon 'Warning' -Message (
                "The same $pending update(s) are still pending after a restart, so repeating " +
                'would not help. They may need manual attention - contact IT if they keep failing.' ))
        return
    }

    # Another go.
    $next = $cycle + 1
    Save-UpdateLoopState @{
        Active           = $true
        Cycle            = $next
        MaxCycles        = $max
        StartedAt        = [string]$state.StartedAt
        LastPendingCount = $pending
    }
    Register-ResumeAtLogon
    Set-Busy -Busy $false -Message "Cycle $next of $max - installing $pending update(s), then restarting..."
    Start-UpdateInstall -WithRestart
}
#endregion Repeat-until-clear loop

function Get-InstallReport {
    <#
        Normalises whatever the install worker returned into a status line plus a
        user-facing message, so the two install buttons report outcomes identically.
    #>
    param($Result)

    $candidates = @($Result | Where-Object { $null -ne $_ })
    $r = if ($candidates.Count -gt 0) { $candidates[-1] } else { $null }

    if (-not $r -or $r.PSObject.Properties.Name -notcontains 'Outcome') {
        return [PSCustomObject]@{
            Outcome        = 'Unknown'
            Status         = 'Installation finished with no reported outcome.'
            Message        = 'The installation finished but did not report what it did.'
            RebootRequired = $false
        }
    }

    $message = if ($r.Message) { [string]$r.Message } else { 'No detail reported.' }
    $status = switch ($r.Outcome) {
        'Success' { $message }
        'PartialSuccess' { $message }
        'NothingToDo' { 'Nothing to install - this device is already up to date.' }
        'Failed' { "Installation failed. $message" }
        default { $message }
    }

    [PSCustomObject]@{
        Outcome        = [string]$r.Outcome
        Status         = $status
        Message        = $message
        RebootRequired = [bool]$r.RebootRequired
    }
}

function Show-InstallOutcome {
    <#
        Surfaces the install result in a dialog as well as the status bar: an install can
        take many minutes, by which time the user is probably not watching the status line.
    #>
    param(
        [Parameter(Mandatory)]$Report,
        [switch]$SuppressedRestart
    )

    $body = $Report.Message
    if ($Report.RebootRequired) {
        $body += "`n`nA restart is needed to finish applying these updates."
    }
    if ($SuppressedRestart) {
        $body += "`n`nThe machine was not restarted, because no updates were installed."
    }

    $icon = switch ($Report.Outcome) {
        'Success' { 'Success' }
        'NothingToDo' { 'Info' }
        'PartialSuccess' { 'Warning' }
        'Failed' { 'Error' }
        default { 'Info' }
    }

    $title = switch ($Report.Outcome) {
        'Success' { 'Updates installed' }
        'NothingToDo' { 'Already up to date' }
        'PartialSuccess' { 'Some updates failed' }
        'Failed' { 'Installation failed' }
        default { 'Update installation' }
    }

    [void](Show-AppDialog -Title $title -Message $body -Icon $icon)
}

function Show-Failure {
    param([Parameter(Mandatory)]$ErrorRecord, [string]$Context)

    $message = $ErrorRecord.Exception.Message
    Set-Busy -Busy $false -Message "$Context failed: $message"
    [void](Show-AppDialog -Title "$Context failed" -Message $message -Icon 'Error')
}

function Start-UpdateScan {
    Set-Busy -Busy $true -Message 'Scanning Windows Update for pending updates...'
    $ui['TxtUpdatesSub'].Text = 'Scanning...'
    $ui['TxtUpdatesEmpty'].Visibility = 'Collapsed'

    Start-AsyncWork -Work $scanUpdatesWork -OnSuccess {
        param($result)
        Show-Updates -Updates $result
        Set-Busy -Busy $false -Message "Scan complete - $($script:PendingUpdates.Count) update(s) pending."
        # A scan is the loop's decision point: it is what tells us whether to go round again.
        if ($script:LoopActive) { Resolve-UpdateLoop }
    } -OnFailure {
        param($err)
        Show-Updates -Updates @()
        $ui['TxtUpdatesEmpty'].Text = 'Could not read Windows Update.'
        $ui['TxtUpdatesEmpty'].Visibility = 'Visible'
        if ($script:LoopActive) {
            # Can't decide without a scan, so stop rather than reboot blindly.
            Clear-UpdateLoop
            Update-ActionState
        }
        Show-Failure -ErrorRecord $err -Context 'Update scan'
    }
}

function Start-UpdateInstall {
    <#
        Single install path for all three entry points - the two buttons and a loop cycle.
        The intent is stashed in script scope rather than captured in the continuation,
        because a scriptblock that is not GetNewClosure()'d resolves variables when it runs,
        by which time this function's locals are gone.
    #>
    param([switch]$WithRestart)

    $script:InstallWillRestart = [bool]$WithRestart
    Set-Busy -Busy $true -Message $(if ($WithRestart) {
            'Installing updates, then restarting...'
        }
        else {
            'Installing updates. This machine will not restart.'
        })

    Start-AsyncWork -Work $installUpdatesWork -Arguments @{
        TaskName       = $TASK_INSTALL_UPDATES
        TaskPath       = $TaskPath
        ResultFile     = $InstallResultFile
        TimeoutSeconds = $TASK_TIMEOUT_SECONDS
        NotBeforeUtc   = (Get-Date).ToUniversalTime()
    } -OnSuccess {
        param($result)
        $report = Get-InstallReport -Result $result
        $restart = $script:InstallWillRestart
        $looping = $script:LoopActive

        # Never restart for an install that put nothing on the machine - that is disruption
        # with no benefit, and in a loop it would spin forever.
        $pointless = $report.Outcome -eq 'Failed' -or $report.Outcome -eq 'NothingToDo'

        if ($restart -and -not $pointless) {
            $suffix = if ($looping) { " Cycle continues after you log back in." } else { '' }
            Set-Busy -Busy $false -Message "$($report.Status) Restarting in $RESTART_DELAY_SECONDS seconds - run 'shutdown /a' to cancel.$suffix"
            # The GUI owns the reboot, not the SYSTEM task, so "install only" stays genuinely
            # reboot-free and the user always gets a cancellable countdown.
            & "$env:SystemRoot\System32\shutdown.exe" '/r' '/t' $RESTART_DELAY_SECONDS `
                '/c' 'Restarting to finish installing updates (requested from Device Self-Service).'
            return
        }

        if ($restart -and $pointless) {
            if ($looping) { Clear-UpdateLoop }
            Set-Busy -Busy $false -Message "$($report.Status) Not restarting."
            Show-InstallOutcome -Report $report -SuppressedRestart
            Start-UpdateScan
            return
        }

        Set-Busy -Busy $false -Message $report.Status
        Show-InstallOutcome -Report $report
        Start-UpdateScan
    } -OnFailure {
        param($err)
        if ($script:LoopActive) { Clear-UpdateLoop; Update-ActionState }
        Show-Failure -ErrorRecord $err -Context 'Update installation'
    }
}
#endregion UI helpers

#region Event handlers
$ui['TitleBar'].Add_MouseLeftButtonDown({ $window.DragMove() })
$ui['BtnMinimize'].Add_Click({ $window.WindowState = 'Minimized' })
$ui['BtnClose'].Add_Click({ $window.Close() })
$ui['BtnRescan'].Add_Click({ Start-UpdateScan })

# 1. Compliance
$ui['BtnCheckCompliance'].Add_Click({
        # The check drives Company Portal, and a user closing it mid-sequence would empty
        # the cache the verdict is read from. Say so before starting, not after it fails.
        $proceed = Show-AppDialog -Title 'Company Portal will open' -Icon 'Question' -Cancellable `
            -PrimaryText 'Start check' -Message (
            'Company Portal will open in the background while this device is checked. ' +
            "Please leave it alone - do not close it - until the check finishes.`n`n" +
            'It will be closed automatically once the compliance status has been read. ' +
            'The check takes about a minute.')
        if (-not $proceed) {
            $ui['TxtStatus'].Text = 'Compliance check cancelled.'
            return
        }

        Set-Busy -Busy $true -Message 'Starting compliance check...'
        Set-ComplianceIndicator -State 'Checking' -Detail 'Company Portal is open - please leave it alone until this finishes.'

        Start-AsyncWork -Work $checkComplianceWork -Arguments @{
            CacheDirectory        = $ComplianceCacheDirectory
            TaskName              = $TASK_COMPLIANCE
            TaskPath              = $TaskPath
            CachePrimeWaitSeconds = $CachePrimeWaitSeconds
            PostTaskWaitSeconds   = $PostTaskWaitSeconds
            TaskTimeoutSeconds    = $COMPLIANCE_TIMEOUT_SECONDS
            LaunchWaitSeconds     = $CompanyPortalLaunchWaitSeconds
            OwnerWindowHandle     = $script:OwnWindowHandle
        } -OnSuccess {
            param($result)
            # Continuations run on the UI thread, so Set-StrictMode applies: reading .State
            # off a null result would raise a property error instead of saying anything
            # useful. Count before indexing - [-1] on an empty array is out of bounds.
            $candidates = @($result | Where-Object { $null -ne $_ })
            $verdict = if ($candidates.Count -gt 0) { $candidates[-1] } else { $null }
            $state = 'Unknown'
            $detail = 'The compliance check returned no result.'
            if ($verdict -and $verdict.PSObject.Properties.Name -contains 'State') {
                $state = switch ($verdict.State) {
                    'Compliant' { 'Compliant' }
                    'NonCompliant' { 'NonCompliant' }
                    default { 'Unknown' }
                }
                $detail = if ($verdict.Reason) { $verdict.Reason } else { 'No detail reported.' }
            }

            Set-ComplianceIndicator -State $state -Detail $detail
            Set-Busy -Busy $false -Message "Compliance: $state."
            # Company Portal is left running, so make sure this window ends up in front.
            $window.Activate()
        } -OnFailure {
            param($err)
            Set-ComplianceIndicator -State 'Unknown' -Detail 'The compliance check could not be completed.'
            Show-Failure -ErrorRecord $err -Context 'Compliance check'
        }
    })

# 1b. Sync Device
$ui['BtnSyncDevice'].Add_Click({
        Set-Busy -Busy $true -Message 'Syncing this device with Intune...'
        Set-SyncIndicator -State 'Syncing' -Detail 'Asking Intune for the latest policies and apps.'

        Start-AsyncWork -Work $syncDeviceWork -Arguments @{
            TaskName           = $TASK_RESTART_IME
            TaskPath           = $TaskPath
            ServiceName        = $IME_SERVICE_NAME
            LogDirectory       = $ImeLogDirectory
            TaskTimeoutSeconds = $SYNC_TASK_TIMEOUT_SECONDS
            ServiceWaitSeconds = $SYNC_SERVICE_WAIT_SECONDS
            LogWaitSeconds     = $SYNC_CONFIRM_WAIT_SECONDS
        } -OnSuccess {
            param($result)
            $candidates = @($result | Where-Object { $null -ne $_ })
            $outcome = if ($candidates.Count -gt 0) { $candidates[-1] } else { $null }

            $state = 'Unconfirmed'
            $detail = 'The sync returned no result.'
            if ($outcome -and $outcome.PSObject.Properties.Name -contains 'State') {
                $state = switch ($outcome.State) {
                    'Synced' { 'Synced' }
                    'Failed' { 'Failed' }
                    default { 'Unconfirmed' }
                }
                if ($outcome.Reason) { $detail = $outcome.Reason }
            }

            Set-SyncIndicator -State $state -Detail $detail
            $summary = switch ($state) {
                'Synced' { 'Device synced with Intune.' }
                'Failed' { 'Sync failed.' }
                default { 'Sync requested but not confirmed.' }
            }
            Set-Busy -Busy $false -Message $summary
        } -OnFailure {
            param($err)
            Set-SyncIndicator -State 'Failed' -Detail 'The sync could not be completed.'
            Show-Failure -ErrorRecord $err -Context 'Device sync'
        }
    })

# 2. Install, no restart
$ui['BtnInstall'].Add_Click({ Start-UpdateInstall })

# 3. Install and restart, optionally repeating until nothing is pending
$ui['BtnInstallRestart'].Add_Click({
        $count = @($script:PendingUpdates).Count
        $repeat = [bool]$ui['ChkRepeatUntilClear'].IsChecked

        $message = if ($repeat) {
            "This device will install $count pending update(s) and restart, then keep " +
            "repeating until nothing is pending.`n`n" +
            "After each restart you will need to log back in, and this app will reopen " +
            "and continue on its own. It stops automatically when no updates remain, " +
            "after $MaxUpdateLoopCycles cycles, or if the pending list stops shrinking.`n`n" +
            "Each restart gives you $RESTART_DELAY_SECONDS seconds' warning, cancellable with: shutdown /a"
        }
        else {
            "Install $count pending update(s) and restart this machine?`n`n" +
            "The restart happens automatically once installation finishes. You will get " +
            "$RESTART_DELAY_SECONDS seconds' warning and can cancel it by running: shutdown /a"
        }

        $title = if ($repeat) { 'Install, restart and repeat' } else { 'Install updates and restart' }
        if (-not (Show-AppDialog -Title $title -Message $message -Icon 'Warning' -Cancellable `
                    -PrimaryText $(if ($repeat) { 'Start' } else { 'Install and restart' }))) {
            $ui['TxtStatus'].Text = 'Cancelled. Nothing was installed.'
            return
        }

        if ($repeat) {
            # Record the loop before installing: the restart can land at any point after
            # this, and the state file plus the RunOnce hook are what survive it.
            $script:LoopActive = $true
            Save-UpdateLoopState @{
                Active           = $true
                Cycle            = 1
                MaxCycles        = $MaxUpdateLoopCycles
                StartedAt        = (Get-Date).ToUniversalTime().ToString('o')
                LastPendingCount = $count
            }
            Register-ResumeAtLogon
        }

        Start-UpdateInstall -WithRestart
    })

$window.Add_Loaded({
        $ui['TxtDeviceName'].Text = $env:COMPUTERNAME
        $ui['TxtUser'].Text = "$env:USERDOMAIN\$env:USERNAME"

        # The HWND only exists once the window is sourced, so capture it here rather than
        # at script scope. The compliance worker uses it to take focus back off Company Portal.
        $script:OwnWindowHandle =
            (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle

        # Say up front that compliance cannot be read, rather than only on click.
        if ($ComplianceCacheDirectory) {
            Set-ComplianceIndicator -State 'Unknown' -Detail 'Not checked yet.'
        }
        else {
            Set-ComplianceIndicator -State 'Unknown' `
                -Detail 'No cache directory configured. Pass -ComplianceCacheDirectory with the path from intunecompcheck.ps1.'
        }

        Start-AsyncWork -Work $readEnrollmentWork -OnSuccess {
            param($result)
            $found = @($result | Where-Object { $null -ne $_ })
            $info = if ($found.Count -gt 0) { $found[0] } else { $null }
            $ui['TxtEnrollment'].Text = if ($info -and $info.Enrolled) {
                "MDM enrolled - $($info.ProviderID)"
            }
            else {
                'No MDM enrolment detected on this device.'
            }
        } -OnFailure {
            param($err)
            $ui['TxtEnrollment'].Text = 'Enrolment state unavailable.'
        }

        # Resuming a repeat-until-clear loop after a restart. The scan that Start-UpdateScan
        # kicks off is the decision point: its continuation calls Resolve-UpdateLoop, which
        # either starts another cycle or stops and explains why.
        $resumeState = Get-UpdateLoopState
        if ($ResumeUpdateLoop -and $resumeState -and $resumeState.Active) {
            $script:LoopActive = $true
            $ui['ChkRepeatUntilClear'].IsChecked = $true
            Set-Busy -Busy $true -Message "Resuming after restart - cycle $($resumeState.Cycle) of $($resumeState.MaxCycles). Checking what is still pending..."
        }
        elseif ($resumeState) {
            # State left over without the matching -ResumeUpdateLoop: the loop was abandoned
            # (app reopened by hand, or a crash). Clear it rather than resume unprompted.
            Clear-UpdateLoop
        }

        Start-UpdateScan
    })

$ui['ChkRepeatUntilClear'].Add_Unchecked({
        # Unticking mid-loop is the user's stop button: drop the state and the logon hook so
        # nothing resumes after the next restart.
        if ($script:LoopActive) {
            Clear-UpdateLoop
            Update-ActionState
            $ui['TxtStatus'].Text = 'Repeat stopped. Any restart already counting down still happens - cancel it with: shutdown /a'
        }
    })

$window.Add_Closed({
        $pollTimer.Stop()
        foreach ($job in @($script:Jobs)) {
            try { $job.Shell.Dispose() } catch { Write-Verbose "Job dispose failed: $_" }
        }
        $script:Jobs.Clear()
    })
#endregion Event handlers

$pollTimer.Start()
$null = $window.ShowDialog()
