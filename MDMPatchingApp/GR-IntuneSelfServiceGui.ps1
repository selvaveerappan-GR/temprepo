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

        Button                        Task started                    Runs as
        ----------------------------  ------------------------------  -------
        Check compliance              GR-RunIntunePushLaunch, then    SYSTEM
                                      GR-RunIntuneComplianceCheck
        Install updates               GR-InstallIntuneUpdates         SYSTEM
        Install updates and restart   GR-InstallIntuneUpdates         SYSTEM
                                      then shutdown.exe /r           user

    The pending-updates list is read in-process through the Windows Update Agent COM API,
    which a standard user may query read-only. Installing is what needs SYSTEM.

    CONTRACT WITH THE TASK SCRIPTS (they are placeholders right now - see Notes):

      GR-RunIntuneComplianceCheck.ps1 must write $ComplianceStatusFile as JSON:
          { "state": "Compliant" | "NonCompliant" | "Unknown",
            "checkedAt": "<ISO 8601 UTC>",
            "reasons": [ "<optional human-readable reason>", ... ] }
      and must grant Users read on that file. This GUI treats the file as the single
      source of truth for compliance and ignores results older than the run it just
      triggered, so a stale file cannot show a false green.

      GR-InstallIntuneUpdates.ps1 must install pending updates and MUST NOT reboot.
      Reboot is owned by this GUI so that "install only" is genuinely reboot-free and
      the user always gets the countdown and a chance to cancel.

      GR-RunIntunePushLaunch.ps1 is assumed to force an Intune/MDM policy sync, so
      compliance is evaluated against current policy rather than a cached verdict.
      If that is not its purpose, set -SkipPushLaunch or drop the task name.

.NOTES
    Compliance is NOT determined locally by this script. Intune evaluates compliance
    server-side, and there is no supported local API that returns the tenant's verdict,
    so the GUI reports whatever GR-RunIntuneComplianceCheck.ps1 writes to the status
    file. Until that script is implemented the indicator will show Unknown (grey), not
    a fabricated green or red. The MDM enrollment state shown underneath the indicator
    IS read locally, from HKLM\SOFTWARE\Microsoft\Enrollments, purely as context.

.PARAMETER ComplianceStatusFile
    JSON file written by GR-RunIntuneComplianceCheck.ps1 and read by this GUI.

.PARAMETER SkipPushLaunch
    Do not run GR-RunIntunePushLaunch before the compliance check.

.EXAMPLE
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\GR-IntuneSelfServiceGui.ps1
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ComplianceStatusFile = 'C:\ProgramData\GR\IntuneSelfService\compliance.json',

    [ValidateNotNullOrEmpty()]
    [string]$TaskPath = '\',

    [switch]$SkipPushLaunch
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
$TASK_PUSH_LAUNCH = 'GR-RunIntunePushLaunch'
$TASK_INSTALL_UPDATES = 'GR-InstallIntuneUpdates'
$TASK_TIMEOUT_SECONDS = 900          # 15 min ceiling for an update install
$RESTART_DELAY_SECONDS = 60          # user can abort with: shutdown /a

# UI state. Declared up front because Set-Busy/Update-ActionState read them and
# Set-StrictMode makes an unassigned variable a terminating error.
$script:PendingUpdates = @()
$script:IsBusy = $false

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

            <Grid Grid.Row="2" Margin="0,14,0,0">
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
                      ToolTip="Installs all pending updates, then restarts this machine."/>
            </Grid>
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
        'TxtUpdatesHeader', 'TxtUpdatesSub', 'BtnRescan', 'LstUpdates', 'TxtUpdatesEmpty',
        'BtnInstall', 'BtnInstallRestart', 'Progress', 'TxtStatus')) {
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
        })
}

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$pollTimer.Add_Tick({
        for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
            $job = $script:Jobs[$i]
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
    })
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

$runTaskWork = {
    param(
        [string[]]$TaskName,
        [string]$TaskPath,
        [int]$TimeoutSeconds
    )

    # Started, not created: these tasks already exist and run as SYSTEM. A standard user can
    # only get here because the task DACL grants BUILTIN\Users GENERIC_EXECUTE.
    foreach ($name in $TaskName) {
        $task = Get-ScheduledTask -TaskName $name -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if (-not $task) {
            throw "Scheduled task '$name' is not registered on this machine. An administrator must run New-GRIntuneScheduledTasks.ps1."
        }

        Start-ScheduledTask -TaskName $name -TaskPath $TaskPath

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $state = (Get-ScheduledTask -TaskName $name -TaskPath $TaskPath).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

        if ($state -eq 'Running') {
            throw "Task '$name' was still running after $TimeoutSeconds seconds; giving up on waiting for it."
        }

        $lastResult = (Get-ScheduledTaskInfo -TaskName $name -TaskPath $TaskPath).LastTaskResult
        if ($lastResult -ne 0) {
            throw "Task '$name' finished with exit code 0x{0:X8}." -f $lastResult
        }
    }

    [PSCustomObject]@{ Completed = $true }
}

$readComplianceWork = {
    param(
        [string[]]$TaskName,
        [string]$TaskPath,
        [string]$StatusFile,
        [int]$TimeoutSeconds,
        [datetime]$NotBeforeUtc
    )

    foreach ($name in $TaskName) {
        $task = Get-ScheduledTask -TaskName $name -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if (-not $task) {
            throw "Scheduled task '$name' is not registered on this machine. An administrator must run New-GRIntuneScheduledTasks.ps1."
        }
        Start-ScheduledTask -TaskName $name -TaskPath $TaskPath

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $state = (Get-ScheduledTask -TaskName $name -TaskPath $TaskPath).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
    }

    if (-not (Test-Path -LiteralPath $StatusFile)) {
        return [PSCustomObject]@{
            State  = 'Unknown'
            AsOf   = $null
            Reason = "No compliance result at '$StatusFile'. GR-RunIntuneComplianceCheck.ps1 is still a placeholder and has not written one."
        }
    }

    $status = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json

    $checkedAt = $null
    if ($status.PSObject.Properties.Name -contains 'checkedAt' -and $status.checkedAt) {
        $checkedAt = ([datetime]$status.checkedAt).ToUniversalTime()
    }

    # Refuse to present a verdict written before this run - otherwise a stale file could
    # show green for a device that is no longer compliant.
    if ($null -eq $checkedAt -or $checkedAt -lt $NotBeforeUtc) {
        return [PSCustomObject]@{
            State  = 'Unknown'
            AsOf   = $checkedAt
            Reason = 'The compliance result on disk predates this check, so it was not trusted. The task ran but did not publish a fresh result.'
        }
    }

    $reasons = @()
    if ($status.PSObject.Properties.Name -contains 'reasons' -and $status.reasons) {
        $reasons = @($status.reasons)
    }

    [PSCustomObject]@{
        State  = [string]$status.state
        AsOf   = $checkedAt
        Reason = ($reasons -join ' ')
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
    foreach ($key in @('BtnCheckCompliance', 'BtnRescan')) {
        $ui[$key].IsEnabled = -not $script:IsBusy
    }

    # The install buttons need both conditions: not busy AND something to install.
    $hasUpdates = @($script:PendingUpdates).Count -gt 0
    $ui['BtnInstall'].IsEnabled = (-not $script:IsBusy) -and $hasUpdates
    $ui['BtnInstallRestart'].IsEnabled = (-not $script:IsBusy) -and $hasUpdates
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

function Show-Failure {
    param([Parameter(Mandatory)]$ErrorRecord, [string]$Context)

    $message = $ErrorRecord.Exception.Message
    Set-Busy -Busy $false -Message "$Context failed: $message"
    [void][System.Windows.MessageBox]::Show($message, "$Context failed",
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}

function Start-UpdateScan {
    Set-Busy -Busy $true -Message 'Scanning Windows Update for pending updates...'
    $ui['TxtUpdatesSub'].Text = 'Scanning...'
    $ui['TxtUpdatesEmpty'].Visibility = 'Collapsed'

    Start-AsyncWork -Work $scanUpdatesWork -OnSuccess {
        param($result)
        Show-Updates -Updates $result
        Set-Busy -Busy $false -Message "Scan complete - $($script:PendingUpdates.Count) update(s) pending."
    } -OnFailure {
        param($err)
        Show-Updates -Updates @()
        $ui['TxtUpdatesEmpty'].Text = 'Could not read Windows Update.'
        $ui['TxtUpdatesEmpty'].Visibility = 'Visible'
        Show-Failure -ErrorRecord $err -Context 'Update scan'
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
        Set-Busy -Busy $true -Message 'Requesting a compliance evaluation...'
        Set-ComplianceIndicator -State 'Checking' -Detail 'Syncing policy and evaluating compliance. This can take a minute.'

        $tasks = if ($SkipPushLaunch) { @($TASK_COMPLIANCE) } else { @($TASK_PUSH_LAUNCH, $TASK_COMPLIANCE) }

        Start-AsyncWork -Work $readComplianceWork -Arguments @{
            TaskName       = $tasks
            TaskPath       = $TaskPath
            StatusFile     = $ComplianceStatusFile
            TimeoutSeconds = $TASK_TIMEOUT_SECONDS
            # Anything published before this instant is a stale verdict, not our result.
            NotBeforeUtc   = (Get-Date).ToUniversalTime()
        } -OnSuccess {
            param($result)
            $state = switch ($result.State) {
                'Compliant' { 'Compliant' }
                'NonCompliant' { 'NonCompliant' }
                default { 'Unknown' }
            }
            $detail = if ($result.Reason) { $result.Reason }
            elseif ($result.AsOf) { "Checked $($result.AsOf.ToLocalTime().ToString('HH:mm:ss')) against current Intune policy." }
            else { 'No detail reported.' }

            Set-ComplianceIndicator -State $state -Detail $detail
            Set-Busy -Busy $false -Message "Compliance: $state."
        } -OnFailure {
            param($err)
            Set-ComplianceIndicator -State 'Unknown' -Detail 'The compliance check could not be completed.'
            Show-Failure -ErrorRecord $err -Context 'Compliance check'
        }
    })

# 2. Install, no restart
$ui['BtnInstall'].Add_Click({
        Set-Busy -Busy $true -Message 'Installing updates. This machine will not restart.'

        Start-AsyncWork -Work $runTaskWork -Arguments @{
            TaskName       = @($TASK_INSTALL_UPDATES)
            TaskPath       = $TaskPath
            TimeoutSeconds = $TASK_TIMEOUT_SECONDS
        } -OnSuccess {
            param($result)
            Set-Busy -Busy $false -Message 'Updates installed. Rescanning to confirm what is left...'
            # Anything still listed either failed or needs a restart to complete.
            Start-UpdateScan
        } -OnFailure {
            param($err)
            Show-Failure -ErrorRecord $err -Context 'Update installation'
        }
    })

# 3. Install and restart
$ui['BtnInstallRestart'].Add_Click({
        $count = if ($null -ne $script:PendingUpdates) { @($script:PendingUpdates).Count } else { 0 }
        $answer = [System.Windows.MessageBox]::Show(
            "Install $count pending update(s) and restart this machine?`n`nThe restart happens automatically once installation finishes. You will get a $RESTART_DELAY_SECONDS second warning and can cancel it by running: shutdown /a",
            'Install updates and restart',
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::OK) {
            $ui['TxtStatus'].Text = 'Restart cancelled. Nothing was installed.'
            return
        }

        Set-Busy -Busy $true -Message 'Installing updates, then restarting...'

        Start-AsyncWork -Work $runTaskWork -Arguments @{
            TaskName       = @($TASK_INSTALL_UPDATES)
            TaskPath       = $TaskPath
            TimeoutSeconds = $TASK_TIMEOUT_SECONDS
        } -OnSuccess {
            param($result)
            Set-Busy -Busy $false -Message "Updates installed. Restarting in $RESTART_DELAY_SECONDS seconds - run 'shutdown /a' to cancel."
            # The GUI owns the reboot, not the SYSTEM task, so "install only" stays
            # genuinely reboot-free and the user always gets a cancellable countdown.
            & "$env:SystemRoot\System32\shutdown.exe" '/r' '/t' $RESTART_DELAY_SECONDS `
                '/c' 'Restarting to finish installing updates (requested from Device Self-Service).'
        } -OnFailure {
            param($err)
            Show-Failure -ErrorRecord $err -Context 'Update installation'
        }
    })

$window.Add_Loaded({
        $ui['TxtDeviceName'].Text = $env:COMPUTERNAME
        $ui['TxtUser'].Text = "$env:USERDOMAIN\$env:USERNAME"
        Set-ComplianceIndicator -State 'Unknown' -Detail 'Not checked yet.'

        Start-AsyncWork -Work $readEnrollmentWork -OnSuccess {
            param($result)
            $info = @($result)[0]
            $ui['TxtEnrollment'].Text = if ($info.Enrolled) {
                "MDM enrolled - $($info.ProviderID)"
            }
            else {
                'No MDM enrolment detected on this device.'
            }
        } -OnFailure {
            param($err)
            $ui['TxtEnrollment'].Text = 'Enrolment state unavailable.'
        }

        Start-UpdateScan
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
