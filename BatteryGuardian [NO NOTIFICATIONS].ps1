
# ==========================================================
# SMART BATTERY GUARDIAN
# Version 1.3
# Windows 11 | Windows PowerShell 5.1
# No external dependencies
# ==========================================================

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------
# LOAD REQUIRED WINDOWS LIBRARIES
# ----------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ----------------------------------------------------------
# NATIVE BATTERY DETECTION
# ----------------------------------------------------------

if (-not ("SBGPowerGuardian" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class SBGPowerGuardian
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(out POWER_STATUS status);
}
'@
}

if (-not ("SBGIconCleanupGuardian" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class SBGIconCleanupGuardian
{
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@
}

# ----------------------------------------------------------
# VARIABLES
# ----------------------------------------------------------

$script:alerting = $false
$script:alertStart = $null
$script:soundUntil = $null
$script:nextBeep = $null
$script:nextReminder = $null
$script:currentMode = ""
$script:quitting = $false
$script:icons = @{}
$script:toastAvailable = $false
$script:lastError = ""
$script:soundPlayer = $null
$script:soundFile = Join-Path $env:LOCALAPPDATA "SmartBatteryGuardian\BatteryFull.wav"

# ----------------------------------------------------------
# WINDOWS TOAST NOTIFICATIONS
# ----------------------------------------------------------

try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $script:toastAvailable = $true
}
catch {
    $script:toastAvailable = $false
}

function Send-Notification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $sent = $false

    if ($script:toastAvailable) {
        try {
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument

            $safeMessage = [System.Security.SecurityElement]::Escape($Message)

            $xml.LoadXml(@"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>Smart Battery Guardian</text>
            <text>$safeMessage</text>
        </binding>
    </visual>
    <audio silent="true"/>
</toast>
"@)

            $toast = New-Object Windows.UI.Notifications.ToastNotification $xml

            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
                "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
            )

            $notifier.Show($toast)
            $sent = $true
        }
        catch {
            $sent = $false
        }
    }

    # Fallback if Windows toast notifications are unavailable.
    if (-not $sent -and $script:trayIcon) {
        $script:trayIcon.BalloonTipTitle = "Smart Battery Guardian"
        $script:trayIcon.BalloonTipText = $Message
        $script:trayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $script:trayIcon.ShowBalloonTip(5000)
    }
}

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

    # Coloured background
    if ($Mode -eq "Charging") {
        $brush = New-Object System.Drawing.SolidBrush(
            [System.Drawing.Color]::FromArgb(22, 163, 74)
        )

        $graphics.FillRectangle($brush, 1, 1, 30, 30)
        $brush.Dispose()
    }
    elseif ($Mode -eq "Full") {
        $brush = New-Object System.Drawing.SolidBrush(
            [System.Drawing.Color]::FromArgb(147, 51, 234)
        )

        $graphics.FillRectangle($brush, 1, 1, 30, 30)
        $brush.Dispose()
    }

    # Battery body
    $bodyBrush = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::White
    )

    $graphics.FillRectangle($bodyBrush, 5, 9, 21, 16)

    $outline = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::Black, 2
    )

    $graphics.DrawRectangle($outline, 5, 9, 21, 16)
    $graphics.FillRectangle($bodyBrush, 26, 14, 3, 6)

    # Charging symbol
    if ($Mode -eq "Charging") {
        $bolt = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::DarkOrange, 3
        )

        $points = [System.Drawing.Point[]]@(
            [System.Drawing.Point]::new(18, 10),
            [System.Drawing.Point]::new(12, 18),
            [System.Drawing.Point]::new(17, 18),
            [System.Drawing.Point]::new(14, 24),
            [System.Drawing.Point]::new(22, 15),
            [System.Drawing.Point]::new(17, 15)
        )

        $graphics.DrawLines($bolt, $points)
        $bolt.Dispose()
    }

    # Fully charged symbol
    elseif ($Mode -eq "Full") {
        $check = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::DarkGreen, 3
        )

        $graphics.DrawLines(
            $check,
            [System.Drawing.Point[]]@(
                [System.Drawing.Point]::new(10, 17),
                [System.Drawing.Point]::new(15, 22),
                [System.Drawing.Point]::new(23, 12)
            )
        )

        $check.Dispose()
    }

    $graphics.Dispose()
    $outline.Dispose()
    $bodyBrush.Dispose()

    $handle = $bitmap.GetHicon()

    try {
        $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
    }
    finally {
        [SBGIconCleanupGuardian]::DestroyIcon($handle) | Out-Null
        $bitmap.Dispose()
    }

    return $icon
}

# Cache icons
$script:icons["Unplugged"] = New-TrayIcon "Unplugged"
$script:icons["Charging"] = New-TrayIcon "Charging"
$script:icons["Full"] = New-TrayIcon "Full"

# ----------------------------------------------------------
# SYSTEM TRAY
# ----------------------------------------------------------

$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon

$script:trayIcon.Icon = $script:icons["Unplugged"]
$script:trayIcon.Text = "Smart Battery Guardian"
$script:trayIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Text = "Battery status: Checking..."
$statusItem.Enabled = $false

[void]$menu.Items.Add($statusItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$quitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$quitItem.Text = "Quit Smart Battery Guardian"

$quitItem.Add_Click({
    $script:quitting = $true
    $script:timer.Stop()
    [System.Windows.Forms.Application]::Exit()
})

[void]$menu.Items.Add($quitItem)

$script:trayIcon.ContextMenuStrip = $menu

# ----------------------------------------------------------
# UPDATE TRAY STATUS
# ----------------------------------------------------------

function Update-TrayStatus {
    param(
        [string]$Mode,
        [string]$Status
    )

    if ($script:currentMode -ne $Mode) {
        $script:trayIcon.Icon = $script:icons[$Mode]
        $script:currentMode = $Mode
    }

    $script:trayIcon.Text = "Smart Battery Guardian - $Status"
    $statusItem.Text = "Battery status: $Status"
}

# ----------------------------------------------------------
# SOUND SYSTEM
# ----------------------------------------------------------

function Initialize-CustomSound {
    $folder = Split-Path -Parent $script:soundFile
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    # Generate an original three-note chime (G5, B5, D6).
    # PCM WAV: 44.1 kHz, 16-bit, mono.
    $sampleRate = 44100
    $duration = 0.65
    $sampleCount = [int]($sampleRate * $duration)
    $dataBytes = $sampleCount * 2
    $stream = [System.IO.File]::Open(
        $script:soundFile,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )

    try {
    $writer = New-Object System.IO.BinaryWriter($stream)

    $writer.Write([char[]]"RIFF")
    $writer.Write([System.Int32](36 + $dataBytes))
    $writer.Write([char[]]"WAVE")
    $writer.Write([char[]]"fmt ")
    $writer.Write([System.Int32]16)

    $writer.Write([System.Int16]1)
    $writer.Write([System.Int16]1)

    $writer.Write([System.Int32]$sampleRate)
    $writer.Write([System.Int32]($sampleRate * 2))

    $writer.Write([System.Int16]2)
    $writer.Write([System.Int16]16)

    $writer.Write([char[]]"data")
    $writer.Write([System.Int32]$dataBytes)

        for ($i = 0; $i -lt $sampleCount; $i++) {
            $t = $i / $sampleRate
            $envelope = [Math]::Min(1.0, $t / 0.025) *
                        [Math]::Min(1.0, ($duration - $t) / 0.12)

            if ($t -lt 0.22) {
                $frequency = 783.99
            }
            elseif ($t -lt 0.43) {
                $frequency = 987.77
            }
            else {
                $frequency = 1174.66
            }

            $sample = [Math]::Sin(2.0 * [Math]::PI * $frequency * $t)
            $sample += 0.22 * [Math]::Sin(2.0 * [Math]::PI * ($frequency * 2) * $t)
            $value = [int16]([Math]::Max(-32767, [Math]::Min(32767, $sample * $envelope * 10500)))
            $writer.Write([int16]$value)
        }

        $writer.Flush()
        $writer.Dispose()
    }
    finally {
        $stream.Dispose()
    }

    if ($script:soundPlayer) {
        $script:soundPlayer.Dispose()
    }

    $script:soundPlayer = New-Object System.Media.SoundPlayer($script:soundFile)
    $script:soundPlayer.Load()
}

function Play-AlertSound {
    try {
        if (-not $script:soundPlayer) {
            Initialize-CustomSound
        }

        $script:soundPlayer.Stop()
        $script:soundPlayer.Play()
    }
    catch {
        $script:lastError = "Custom sound error: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------
# RESET ALERT SEQUENCE
# ----------------------------------------------------------

function Reset-Alerts {
    $script:alerting = $false
    $script:alertStart = $null
    $script:soundUntil = $null
    $script:nextBeep = $null
    $script:nextReminder = $null
}

# ----------------------------------------------------------
# BATTERY MONITOR
# ----------------------------------------------------------

$script:timer = New-Object System.Windows.Forms.Timer

# Fast enough to manage the sound schedule accurately.
$script:timer.Interval = 250

$script:timer.Add_Tick({

    if ($script:quitting) {
        return
    }

    try {
        $power = New-Object SBGPowerGuardian+POWER_STATUS

        $success = [SBGPowerGuardian]::GetSystemPowerStatus([ref]$power)

        if (-not $success) {
            return
        }

        $pluggedIn = ($power.ACLineStatus -eq 1)
        $battery = [int]$power.BatteryLifePercent

        # 255 means Windows cannot determine the percentage.
        if ($battery -gt 100) {
            return
        }

        $now = Get-Date

        # --------------------------------------------------
        # TRAY STATUS
        # --------------------------------------------------

        if ($pluggedIn -and $battery -ge 100) {
            Update-TrayStatus "Full" "Fully charged (100%)"
        }
        elseif ($pluggedIn) {
            Update-TrayStatus "Charging" "Charging ($battery%)"
        }
        else {
            Update-TrayStatus "Unplugged" "Unplugged ($battery%)"
        }

        # --------------------------------------------------
        # FULL BATTERY ALERT
        # --------------------------------------------------

        if ($pluggedIn -and $battery -ge 100) {

            # First detection
            if (-not $script:alerting) {

                $script:alerting = $true
                $script:alertStart = $now

                $script:soundUntil = $null
                $script:nextBeep = $null
                $script:nextReminder = $null

                Send-Notification "Your laptop is fully charged! Please unplug your charger."
            }

            $elapsed = ($now - $script:alertStart).TotalSeconds

            # Wait 3 seconds before the custom chime.
            if (
                $elapsed -ge 3 -and
                -not $script:soundUntil
            ) {
                $script:soundUntil = $now.AddSeconds(3)
                $script:nextBeep = $now
            }

            # Beep repeatedly for 3 seconds.
            if ($script:soundUntil) {

                if ($now -lt $script:soundUntil) {

                    if ($now -ge $script:nextBeep) {
                        Play-AlertSound
                        $script:nextBeep = $now.AddMilliseconds(750)
                    }

                }
                else {

                    $script:soundUntil = $null
                    $script:nextBeep = $null
                    $script:nextReminder = $now.AddSeconds(3)

                }
            }

            # Reminders every 3 seconds after the sound.
            elseif (
                $script:nextReminder -and
                $now -ge $script:nextReminder
            ) {

                Send-Notification "CHARGER STILL CONNECTED! Please unplug your laptop."

                $script:nextReminder = $now.AddSeconds(3)
            }

        }
        else {

            # Charger removed or battery no longer full.
            if ($script:alerting) {
                Reset-Alerts
            }

        }
    }
    catch {
        $script:lastError = $_.Exception.Message
        $statusItem.Text = "Battery monitor error: $($script:lastError)"
    }

})

# ----------------------------------------------------------
# START APPLICATION
# ----------------------------------------------------------

try {

    Initialize-CustomSound

    Send-Notification "Smart Battery Guardian is now running in the system tray."

    $script:timer.Start()

    [System.Windows.Forms.Application]::Run()

}
catch {

    [System.Windows.Forms.MessageBox]::Show(
        ($_ | Out-String),
        "Smart Battery Guardian - Error"
    ) | Out-Null

}
finally {

    $script:quitting = $true

    if ($script:timer) {
        $script:timer.Stop()
        $script:timer.Dispose()
    }

    if ($script:trayIcon) {
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
    }

    if ($script:soundPlayer) {
        $script:soundPlayer.Stop()
        $script:soundPlayer.Dispose()
    }

    foreach ($icon in $script:icons.Values) {
        if ($icon) {
            $icon.Dispose()
        }
    }

}
