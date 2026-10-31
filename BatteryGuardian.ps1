
# ==========================================================
# SMART BATTERY GUARDIAN
# Version 1.5
# Windows 11 | Windows PowerShell 5.1
# ==========================================================

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------------------------------------
# WINDOWS BATTERY STATUS
# ----------------------------------------------------------

if (-not ("SBGPowerStatus" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class SBGPowerStatus {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte Reserved;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(
        out SYSTEM_POWER_STATUS status
    );
}
"@
}

function Get-BatteryStatus {
    $status = New-Object SBGPowerStatus+SYSTEM_POWER_STATUS

    if ([SBGPowerStatus]::GetSystemPowerStatus([ref]$status)) {
        return @{
            PluggedIn = ($status.ACLineStatus -eq 1)
            Percentage = [int]$status.BatteryLifePercent
        }
    }

    return @{
        PluggedIn = $false
        Percentage = 0
    }
}

# ----------------------------------------------------------
# CREATE CHIME WAV
# ----------------------------------------------------------

$folder = Join-Path $env:LOCALAPPDATA "SmartBatteryGuardian"
$wavPath = Join-Path $folder "BatteryFull.wav"

New-Item -ItemType Directory -Path $folder -Force | Out-Null

function New-Chime {
    $sampleRate = 44100
    $bitsPerSample = 16
    $channels = 1

    $notes = @(
        @{ Frequency = 880; Duration = 0.20 },
        @{ Frequency = 1100; Duration = 0.20 },
        @{ Frequency = 1320; Duration = 0.30 },
        @{ Frequency = 0; Duration = 0.40 }
    )

    $samples = New-Object System.Collections.Generic.List[byte]

    foreach ($note in $notes) {
        $count = [int]($sampleRate * $note.Duration)

        for ($i = 0; $i -lt $count; $i++) {
            if ($note.Frequency -eq 0) {
                $value = 0
            }
            else {
                $fade = [Math]::Min(1, $i / 300)
                $wave = [Math]::Sin(
                    2 * [Math]::PI * $note.Frequency * $i / $sampleRate
                )

                $value = [int](12000 * $wave * $fade)
            }

            $bytes = [BitConverter]::GetBytes([int16]$value)
            $samples.AddRange($bytes)
        }
    }

    $data = $samples.ToArray()
    $dataLength = $data.Length

    $stream = [System.IO.File]::Create($wavPath)
    $writer = New-Object System.IO.BinaryWriter($stream)

    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
        $writer.Write([int](36 + $dataLength))
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
        $writer.Write([int]16)
        $writer.Write([int16]1)
        $writer.Write([int16]$channels)
        $writer.Write([int]$sampleRate)
        $writer.Write([int]($sampleRate * $channels * 2))
        $writer.Write([int16]($channels * 2))
        $writer.Write([int16]$bitsPerSample)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
        $writer.Write([int]$dataLength)
        $writer.Write($data)
    }
    finally {
        $writer.Dispose()
    }
}

New-Chime

# ----------------------------------------------------------
# SOUND PLAYER
# ----------------------------------------------------------

$script:player = New-Object System.Media.SoundPlayer($wavPath)
$script:player.Load()

# ----------------------------------------------------------
# CREATE TRAY ICONS
# ----------------------------------------------------------

function New-TrayIcon {
    param(
        [string]$Mode
    )

    $bitmap = New-Object System.Drawing.Bitmap(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $background = $null
    $batteryBrush = $null
    $boltBrush = $null
    $outlinePen = $null

    try {
        # Background
        if ($Mode -eq "Charging") {
            $background = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(30, 150, 70)
            )
            $graphics.FillEllipse($background, 1, 1, 30, 30)
        }
        elseif ($Mode -eq "Full") {
            $background = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(120, 60, 180)
            )
            $graphics.FillEllipse($background, 1, 1, 30, 30)
        }

        # Battery outline
        $outlinePen = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::White, 2
        )

        $batteryBrush = New-Object System.Drawing.SolidBrush(
            [System.Drawing.Color]::White
        )

        $graphics.DrawRectangle($outlinePen, 5, 10, 20, 13)
        $graphics.FillRectangle($batteryBrush, 25, 14, 3, 5)

        # Battery level
        $levelBrush = New-Object System.Drawing.SolidBrush(
            [System.Drawing.Color]::LimeGreen
        )
        $graphics.FillRectangle($levelBrush, 8, 13, 14, 7)
        $levelBrush.Dispose()

        # Lightning bolt for charging and full
        if ($Mode -eq "Charging" -or $Mode -eq "Full") {
            $boltBrush = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::DarkOrange
            )

            $points = @(
                (New-Object System.Drawing.Point(18, 5)),
                (New-Object System.Drawing.Point(12, 16)),
                (New-Object System.Drawing.Point(17, 16)),
                (New-Object System.Drawing.Point(13, 27)),
                (New-Object System.Drawing.Point(23, 13)),
                (New-Object System.Drawing.Point(18, 13))
            )

            $graphics.FillPolygon($boltBrush, $points)
        }

        $iconHandle = $bitmap.GetHicon()

        try {
            return [System.Drawing.Icon]::FromHandle($iconHandle).Clone()
        }
        finally {
            [SBGIconCleanupGuardian]::DestroyIcon($iconHandle) | Out-Null
        }
    }
    finally {
        if ($background) { $background.Dispose() }
        if ($batteryBrush) { $batteryBrush.Dispose() }
        if ($boltBrush) { $boltBrush.Dispose() }
        if ($outlinePen) { $outlinePen.Dispose() }

        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

# Native icon cleanup
if (-not ("SBGIconCleanupGuardian" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class SBGIconCleanupGuardian {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@
}

# ----------------------------------------------------------
# ICON CACHE
# ----------------------------------------------------------

$script:icons = @{
    Standby = New-TrayIcon "Standby"
    Charging = New-TrayIcon "Charging"
    Full = New-TrayIcon "Full"
}

# ----------------------------------------------------------
# NOTIFICATION ICON
# ----------------------------------------------------------

$script:tray = New-Object System.Windows.Forms.NotifyIcon

$script:tray.Icon = $script:icons.Standby
$script:tray.Text = "Smart Battery Guardian"
$script:tray.Visible = $true

# ----------------------------------------------------------
# TRAY MENU
# ----------------------------------------------------------

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$openItem = New-Object System.Windows.Forms.ToolStripMenuItem
$openItem.Text = "Smart Battery Guardian is running"
$openItem.Enabled = $false

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"

[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add("-")
[void]$menu.Items.Add($exitItem)

$script:tray.ContextMenuStrip = $menu

# ----------------------------------------------------------
# ALERT STATE
# ----------------------------------------------------------

$script:alerting = $false
$script:lastNotification = [DateTime]::MinValue

# ----------------------------------------------------------
# UPDATE TRAY STATUS
# ----------------------------------------------------------

function Update-TrayStatus {
    param($Battery)

    if ($Battery.PluggedIn -and $Battery.Percentage -ge 100) {
        $script:tray.Icon = $script:icons.Full
        $script:tray.Text = "Battery FULL - Unplug charger!"
    }
    elseif ($Battery.PluggedIn) {
        $script:tray.Icon = $script:icons.Charging
        $script:tray.Text = "Battery: $($Battery.Percentage)% - Charging"
    }
    else {
        $script:tray.Icon = $script:icons.Standby
        $script:tray.Text = "Battery: $($Battery.Percentage)% - Not charging"
    }
}

# ----------------------------------------------------------
# START ALERT
# ----------------------------------------------------------

function Start-GuardianAlert {
    if (-not $script:alerting) {
        $script:alerting = $true

        # Start continuous chime looping.
        $script:player.PlayLooping()

        # First notification immediately.
        $script:tray.ShowBalloonTip(
            3000,
            "Battery fully charged!",
            "Unplug your charger to stop the alert.",
            [System.Windows.Forms.ToolTipIcon]::Warning
        )

        $script:lastNotification = Get-Date
    }
}

# ----------------------------------------------------------
# STOP ALERT
# ----------------------------------------------------------

function Stop-GuardianAlert {
    if ($script:alerting) {
        $script:alerting = $false

        # Stop continuous sound.
        $script:player.Stop()

        $script:lastNotification = [DateTime]::MinValue
    }
}

# ----------------------------------------------------------
# BATTERY CHECK TIMER
# ----------------------------------------------------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

$timer.Add_Tick({
    try {
        $battery = Get-BatteryStatus

        Update-TrayStatus $battery

        # Start alert when plugged in and fully charged.
        if (-not $script:alerting) {
            if ($battery.PluggedIn -and $battery.Percentage -ge 100) {
                Start-GuardianAlert
            }
        }

        # Keep alerting until charger is unplugged.
        if ($script:alerting) {

            if (-not $battery.PluggedIn) {
                Stop-GuardianAlert
            }
            else {
                $now = Get-Date

                # Repeat notification every 3 seconds.
                if (($now - $script:lastNotification).TotalSeconds -ge 3) {
                    $script:tray.ShowBalloonTip(
                        3000,
                        "Battery still fully charged!",
                        "Your charger is still connected. Unplug it!",
                        [System.Windows.Forms.ToolTipIcon]::Warning
                    )

                    $script:lastNotification = $now
                }
            }
        }
    }
    catch {
        Write-Warning "Battery Guardian error: $_"
    }
})

# ----------------------------------------------------------
# EXIT HANDLER
# ----------------------------------------------------------

$context = New-Object System.Windows.Forms.ApplicationContext

$exitItem.Add_Click({
    $timer.Stop()

    Stop-GuardianAlert

    $script:tray.Visible = $false
    $script:tray.Dispose()

    $timer.Dispose()
    $script:player.Dispose()

    foreach ($icon in $script:icons.Values) {
        $icon.Dispose()
    }

    $menu.Dispose()

    $context.ExitThread()
})

# ----------------------------------------------------------
# START
# ----------------------------------------------------------

$timer.Start()

Write-Host "Smart Battery Guardian is running."
Write-Host "Look for its icon in the system tray."
Write-Host "Right-click the icon to exit."

# Keep Windows Forms alive in the background.
[System.Windows.Forms.Application]::Run($context)
