<#
.SYNOPSIS
    AutoReset - Automated Windows deployment tool for WinPE.

.DESCRIPTION
    Started by winpeshl.ini when WinPE boots. Wipes a disk, applies Windows,
    injects drivers, configures recovery and boot, saves logs, and restarts
    to OOBE ready for Autopilot enrolment.

    USB copy of reset.json overrides the configuration baked into boot.wim.
    Press F3 at any time to open the log in Notepad.
    Press F8 at any time for a command prompt.
    Press Ctrl+Shift+W on the disk confirmation screen for secure wipe.
#>
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Version = '2.0.0'

# ── Console visibility ──────────────────────────────────────────────

try {
    Add-Type -Name ConsoleUtil -Namespace Ar -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    [void][Ar.ConsoleUtil]::ShowWindow([Ar.ConsoleUtil]::GetConsoleWindow(), 0)
}
catch { }

function Show-Console {
    try { [void][Ar.ConsoleUtil]::ShowWindow([Ar.ConsoleUtil]::GetConsoleWindow(), 5) } catch { }
}

# ── Logging ─────────────────────────────────────────────────────────

$logRoot = 'X:\Windows\Temp'
if (-not (Test-Path $logRoot)) { $logRoot = $env:TEMP }
$script:LogFile     = Join-Path $logRoot 'AutoReset.log'
$script:DetailLog   = Join-Path $logRoot 'AutoReset-Detail.log'
$script:SmsTsLogDir = Join-Path $logRoot 'SMSTSLog'
$script:SmsTsLog    = Join-Path $script:SmsTsLogDir 'smsts.log'
New-Item -ItemType Directory -Path $script:SmsTsLogDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:LogComponent = 'AutoReset'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $now = Get-Date
    $prefix = switch ($Level) {
        'WARN'  { '[WARN ]' }
        'ERROR' { '[ERROR]' }
        default { '[INFO ]' }
    }
    Add-Content -Path $script:LogFile -Value (
        '{0}  {1}  {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $prefix, $Message
    ) -ErrorAction SilentlyContinue

    $type = switch ($Level) { 'INFO' { 1 } 'WARN' { 2 } 'ERROR' { 3 } }
    Add-Content -Path $script:SmsTsLog -ErrorAction SilentlyContinue -Value (
        '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f
        $Message, $now.ToString('HH:mm:ss.fff+000'), $now.ToString('MM-dd-yyyy'), $script:LogComponent, $type, $PID)
}

function Write-Detail {
    param([string]$Text)
    Add-Content -Path $script:DetailLog -Value $Text -ErrorAction SilentlyContinue
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    $divider = '=' * 60
    Add-Content -Path $script:LogFile -Value '' -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFile -Value $divider -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFile -Value "  $Text" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFile -Value $divider -ErrorAction SilentlyContinue
    Write-Log $Text
}

function Write-LogBlock {
    param([AllowEmptyString()][Parameter(Mandatory)][string[]]$Lines)
    foreach ($line in $Lines) {
        Add-Content -Path $script:LogFile -Value "  $line" -ErrorAction SilentlyContinue
    }
}

# ── Media and configuration ─────────────────────────────────────────

function Find-MediaRoot {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        if (Test-Path (Join-Path $drive.Name 'Payload\UNE-Payload.tag')) {
            return (Join-Path $drive.Name 'Payload').TrimEnd('\')
        }
    }
    return $null
}

$script:MediaRoot        = $null
$script:ImagePayloadRoot = 'X:\Payload'
$script:ConfigJson       = $null

function Initialize-Configuration {
    $script:MediaRoot = Find-MediaRoot
    $configPath = $null
    foreach ($candidate in @(
        $(if ($script:MediaRoot) { Join-Path $script:MediaRoot 'Config\reset.json' }),
        (Join-Path $script:ImagePayloadRoot 'Config\reset.json'),
        (Join-Path $PSScriptRoot '..\Config\reset.json'))) {
        if ($candidate -and (Test-Path $candidate)) { $configPath = $candidate; break }
    }
    if ($configPath) {
        try { $script:ConfigJson = Get-Content -Path $configPath -Raw | ConvertFrom-Json } catch { }
    }
}

function Get-Config {
    param([Parameter(Mandatory)][string]$Name, $Default)
    if ($script:ConfigJson -and ($script:ConfigJson.PSObject.Properties.Name -contains $Name)) {
        $value = $script:ConfigJson.$Name
        if ($null -ne $value) { return $value }
    }
    return $Default
}

function Resolve-MediaFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    foreach ($root in @($script:MediaRoot, $script:ImagePayloadRoot)) {
        if (-not $root) { continue }
        $full = Join-Path $root $RelativePath
        if (Test-Path $full) { return $full }
    }
    return $null
}

# ── UI helpers ───────────────────────────────────────────────────────

function UiFont {
    param([double]$Size, [switch]$Bold)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font('Segoe UI', [single]$Size, $style)
}

$script:AccentColor = [System.Drawing.Color]::FromArgb(39, 178, 217)

function Set-PrimaryButtonStyle {
    param([Parameter(Mandatory)][System.Windows.Forms.Button]$Button)
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $script:AccentColor
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
}

function Update-Ui { [System.Windows.Forms.Application]::DoEvents() }

function Title { param([string]$Suffix) "AutoReset v$($script:Version)$(if ($Suffix) { " | $Suffix" })" }

# Pat - Dynamic form factory ----------------------------------------
#   Form is NOT auto-sized. FLP is NOT docked.
#   Caller adds controls to $f.Tag (the FLP), then calls
#   Set-FormSize -Form $f before ShowDialog() or after .Show().
#--------------------------------------------------------------------
function New-BaseForm {
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$TitleSuffix,
        [int]$Width = 560
    )
    $f                 = New-Object System.Windows.Forms.Form
    $f.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::Font
    $f.Font            = UiFont 10
    $f.Text            = Title $TitleSuffix
    $f.StartPosition   = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox     = $false
    $f.MinimizeBox     = $false
    $f.ControlBox      = $false
    $f.TopMost         = $true
    $f.BackColor       = [System.Drawing.SystemColors]::Window
    $f.KeyPreview      = $true
    $f.AutoSize        = $false

    $flp               = New-Object System.Windows.Forms.FlowLayoutPanel
    $flp.FlowDirection = 'TopDown'
    $flp.WrapContents  = $false
    $flp.AutoSize      = $true
    $flp.AutoSizeMode  = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flp.Padding       = New-Object System.Windows.Forms.Padding(20)
    $flp.Location      = New-Object System.Drawing.Point(0, 0)
    $f.Controls.Add($flp)
    $f.Tag             = $flp

    $f | Add-Member -NotePropertyName '_TargetWidth' -NotePropertyValue $Width

    $f.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F3) {
            if (Test-Path $script:LogFile) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList $script:LogFile
            }
        }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
            Start-Process -FilePath "$env:windir\System32\cmd.exe"
        }
    })
    return $f
}
# Pat - Calculate and apply form size after all controls are added --
#   Forces a layout pass on the FLP, then reads its ACTUAL rendered
#   height (not GetPreferredSize, which ignores non-AutoSize children
#   like ListView, ProgressBar, and TextBox).
#   Caps height at 90 % of the screen working area.
#--------------------------------------------------------------------
function Set-FormSize {
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form)

    $flp   = $Form.Tag
    $width = $Form._TargetWidth

    # Constrain FLP width so children stack in a single column
    $flp.MaximumSize = New-Object System.Drawing.Size($width, 0)

    # Force the FLP to lay out all children and resize itself.
    # Because AutoSize + GrowAndShrink is set, after PerformLayout
    # the FLP's Size.Height reflects the true content height —
    # including non-AutoSize children (ListView, ProgressBar, etc.)
    # that GetPreferredSize() would otherwise ignore.
    $flp.PerformLayout()
    $contentH = $flp.Size.Height

    # Safety fallback — if the FLP hasn't resized yet (edge case),
    # try GetPreferredSize as a backup
    if ($contentH -lt 50) {
        $pref     = $flp.GetPreferredSize(
                        (New-Object System.Drawing.Size($width, 0)))
        $contentH = [math]::Max($contentH, $pref.Height)
    }

    $screenH = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
    $maxH    = [math]::Floor($screenH * 0.9)
    $finalH  = [math]::Min($contentH, $maxH)

    $Form.ClientSize = New-Object System.Drawing.Size($width, $finalH)
}
#--------------------------------------------------------------------

# ── State ────────────────────────────────────────────────────────────

$script:StartTime    = Get-Date
$script:Model        = $null
$script:Serial       = $null
$script:Manufacturer = $null
$script:IsUefi       = $true
$script:TargetDisk   = $null
$script:DriverFolder = $null
$script:DriversAdded = 0
$script:StepWarnings = @()
$script:AllDisks     = @()

# ── External tool runner ────────────────────────────────────────────

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$What,
        [switch]$ParsePercent
    )
    if (-not $What) { $What = [IO.Path]::GetFileNameWithoutExtension($FilePath) }
    $started = Get-Date
    Write-Detail ''
    Write-Detail ("=== {0:HH:mm:ss}  {1} {2}" -f $started, $FilePath, $Arguments)

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stream  = $proc.StandardOutput.BaseStream
    $buffer  = New-Object byte[] 8192
    $sb      = New-Object System.Text.StringBuilder
    $pctRx   = [regex]'(\d{1,3}(?:\.\d)?)%'

    $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
    while ($true) {
        if ($readTask.IsCompleted) {
            $count = 0
            if (-not $readTask.IsFaulted) { $count = $readTask.Result }
            if ($count -le 0) {
                if ($proc.HasExited) { break }
                Start-Sleep -Milliseconds 100
            }
            else {
                $chunk = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                [void]$sb.Append($chunk)
                if ($ParsePercent) {
                    $hits = $pctRx.Matches($chunk)
                    if ($hits.Count -gt 0) { Set-StepPercent ([double]$hits[$hits.Count - 1].Groups[1].Value) }
                }
            }
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
        }
        else {
            Update-Ui
            Start-Sleep -Milliseconds 60
        }
    }
    $proc.WaitForExit()

    $stdErr = ''
    try { $stdErr = $errTask.Result } catch { }
    $output = $sb.ToString()
    Write-Detail $output
    if ($stdErr.Trim()) { Write-Detail "[stderr] $($stdErr.Trim())" }

    $elapsed = (Get-Date) - $started
    if ($proc.ExitCode -ne 0) {
        $bad = ($output -split "[`r`n]+") |
            Where-Object { $_.Trim() -and $_ -notmatch '^\[' -and $_ -match 'Error|error|failed|cannot|denied' } |
            Select-Object -Last 3
        Write-Log ("{0} failed (exit {1}, {2:mm\:ss})" -f $What, $proc.ExitCode, $elapsed) 'WARN'
        foreach ($b in $bad) { Write-Log ("  {0}" -f $b.Trim()) 'WARN' }
    }
    else {
        Write-Log ('{0} completed (exit 0, {1:mm\:ss})' -f $What, $elapsed)
    }

    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $output; Elapsed = $elapsed }
}

# ── Error helpers ────────────────────────────────────────────────────

function Get-FriendlyError {
    param([Parameter(Mandatory)][string]$StepName)
    switch ($StepName) {
        'Wipe and Partition'     { 'wiping and partitioning the drive. The drive may be faulty, or a BIOS setting like BitLocker or RAID may be preventing access.' }
        'Installing Windows'     { 'installing Windows onto the drive. The install image may be missing from the USB, or the drive may be faulty.' }
        'Installing Drivers'     { 'installing the hardware drivers for this model. The driver package may be missing or incompatible.' }
        'Create WinRE Partition' { 'setting up the Windows recovery environment.' }
        'Create Boot Data'       { 'making the computer bootable after installing Windows.' }
        'Verify Install'         { 'verifying the finished installation. Some critical files may be missing.' }
        'Save Logs'              { 'saving the deployment logs.' }
        default                  { "performing the step: $StepName." }
    }
}

function Save-DeviceLog {
    param([Parameter(Mandatory)][ValidateSet('SUCCESS', 'FAILED')][string]$Result)
    if (-not $script:MediaRoot) { return $null }
    try {
        $logDir = Join-Path ([System.IO.Path]::GetPathRoot($script:MediaRoot)) 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null

        $serial = if ($script:Serial) { $script:Serial } else { 'UNKNOWN' }
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmm'
        $dest   = Join-Path $logDir ('{0}_{1}_{2}.log' -f $serial, $stamp, $Result)

        $duration = (Get-Date) - $script:StartTime
        $header = @(
            '============================================================'
            "  AutoReset v$($script:Version) - $Result"
            '============================================================'
            "  Device       : $($script:Manufacturer) $($script:Model)"
            "  Service tag  : $serial"
            "  Firmware     : $(if ($script:IsUefi) { 'UEFI' } else { 'Legacy BIOS' })"
            "  Started      : $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
            "  Finished     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "  Duration     : $('{0:hh\:mm\:ss}' -f $duration)"
            '============================================================'
            ''
        )
        Set-Content -Path $dest -Value ($header -join [Environment]::NewLine) -Encoding UTF8
        Add-Content -Path $dest -Value (Get-Content -Path $script:LogFile -Raw -ErrorAction SilentlyContinue)
        Copy-Item $script:SmsTsLog  (Join-Path $logDir ('{0}_{1}_smsts.log'  -f $serial, $stamp)) -Force -ErrorAction SilentlyContinue
        Copy-Item $script:DetailLog (Join-Path $logDir ('{0}_{1}_detail.log' -f $serial, $stamp)) -Force -ErrorAction SilentlyContinue
        Write-Log "Logs saved to media: $dest"
        return $dest
    }
    catch {
        Write-Log "Could not write logs to the deployment media: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

# ── Copy logs to installed OS ────────────────────────────────────────

function Copy-LogsToTarget {
    New-Item -ItemType Directory -Path 'W:\Windows\Temp\SMSTSLog' -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item $script:LogFile   'W:\Windows\Temp\AutoReset.log'        -Force -ErrorAction SilentlyContinue
    Copy-Item $script:DetailLog 'W:\Windows\Temp\AutoReset-Detail.log' -Force -ErrorAction SilentlyContinue
    Copy-Item $script:SmsTsLog  'W:\Windows\Temp\SMSTSLog\smsts.log'   -Force -ErrorAction SilentlyContinue
}

# ── Get drive letter for a disk ─────────────────────────────────────

function Get-PrimaryDriveLetter {
    param([int]$DiskNumber)
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
        Sort-Object Size -Descending)
    if ($parts.Count -gt 0) { return "$($parts[0].DriveLetter):" }
    return '-'
}

# ═════════════════════════════════════════════════════════════════════
# STAGE 1: SPLASH - Preparing AutoReset (5-second minimum)
# ═════════════════════════════════════════════════════════════════════

$splashForm = New-BaseForm -TitleSuffix 'Preparing...' -Width 480

$lblSplash              = New-Object System.Windows.Forms.Label
$lblSplash.Text         = 'Preparing AutoReset and gathering info...'
$lblSplash.Font         = UiFont 10
$lblSplash.AutoSize     = $true
$lblSplash.MaximumSize  = New-Object System.Drawing.Size(444, 0)
$lblSplash.ForeColor    = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblSplash.BackColor    = [System.Drawing.Color]::Transparent
$splashForm.Tag.Controls.Add($lblSplash)

# Pat - Set-FormSize before Show ------------------------------------
Set-FormSize -Form $splashForm
#--------------------------------------------------------------------
$splashForm.Show()
$splashForm.Activate()
Update-Ui

$splashStart = Get-Date

# ── Splash work: logging, hardware, disks, config ───────────────────

Write-Section "AutoReset v$($script:Version)"
Write-LogBlock @(
    "Started      : $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    "Log file     : $($script:LogFile)"
    "Detail log   : $($script:DetailLog)"
    "SMSTS log    : $($script:SmsTsLog)"
)

Initialize-Configuration

if (-not $script:MediaRoot) {
    $splashForm.Close()
    $splashForm.Dispose()
    Show-Console
    [void][System.Windows.Forms.MessageBox]::Show(
        'AutoReset media not found. Ensure the USB contains Payload\UNE-Payload.tag.',
        (Title 'Error'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

$cs   = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$script:Model        = $cs.Model.Trim()
$script:Manufacturer = $cs.Manufacturer.Trim()
$script:Serial       = ($bios.SerialNumber -replace '[^A-Za-z0-9-]', '')
if (-not $script:Serial) {
    $script:Serial = 'NOSN{0:x6}' -f (Get-Random -Maximum 0xFFFFFF)
}

$peFw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction SilentlyContinue).PEFirmwareType
$script:IsUefi = ($peFw -eq 2)

& powercfg.exe /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null

$driverMap = Get-Config 'DriverMap' @()
foreach ($entry in $driverMap) {
    if ($script:Model -like "*$($entry.Match)*") { $script:DriverFolder = $entry.Folder; break }
}
if (-not $script:DriverFolder) { $script:DriverFolder = $script:Model }

$script:AllDisks = @(Get-Disk | Sort-Object Number)

$configured = Get-Config 'TargetDiskNumber' $null
if ($null -ne $configured -and "$configured" -ne '') {
    $script:TargetDisk = Get-Disk -Number ([int]$configured)
    Write-Log ("Target disk pre-configured in reset.json: disk {0}" -f $configured)
}
else {
    $script:TargetDisk = $script:AllDisks |
        Where-Object { $_.BusType -notin @('USB', 'iSCSI', 'File Backed Virtual') } |
        Sort-Object Size -Descending | Select-Object -First 1
}

$totalMem = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

Write-Section 'Device Information'
Write-LogBlock @(
    "Manufacturer : $($script:Manufacturer)"
    "Model        : $($script:Model)"
    "Service tag  : $($script:Serial)"
    "Firmware     : $(if ($script:IsUefi) { 'UEFI' } else { 'Legacy BIOS' })"
    "Memory       : ${totalMem} GB"
    "Driver match : $($script:DriverFolder)"
    "Media root   : $($script:MediaRoot)"
    "Config       : $(if ($script:ConfigJson) { 'reset.json loaded' } else { 'defaults (no reset.json)' })"
)

Write-Section 'Disk Inventory'
foreach ($d in $script:AllDisks) {
    $sizeGB = [math]::Round($d.Size / 1GB, 1)
    $letter = Get-PrimaryDriveLetter -DiskNumber $d.Number
    Write-LogBlock @(
        ("Disk {0}: {1} | {2} GB | {3} | {4} | Letter: {5}" -f
            $d.Number, $d.FriendlyName, $sizeGB, $d.BusType, $d.PartitionStyle, $letter)
    )
}

# ── Enforce 5-second minimum splash ─────────────────────────────────

$splashElapsed = (Get-Date) - $splashStart
$remaining = 5 - $splashElapsed.TotalSeconds
if ($remaining -gt 0) {
    $endWait = (Get-Date).AddSeconds($remaining)
    while ((Get-Date) -lt $endWait) {
        Update-Ui
        Start-Sleep -Milliseconds 100
    }
}

$splashForm.Close()
$splashForm.Dispose()

# ═════════════════════════════════════════════════════════════════════
# STAGE 2: CONFIRM DISK SELECTION
# ═════════════════════════════════════════════════════════════════════

if (-not $script:TargetDisk) {
    Show-Console
    [void][System.Windows.Forms.MessageBox]::Show(
        'No suitable internal drive was found (USB disks are excluded). This computer may need extra storage drivers in WinPE.',
        (Title 'Error'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

function Show-DiskConfirmation {
    $sizeGB = [math]::Round($script:TargetDisk.Size / 1GB, 1)
    $letter = Get-PrimaryDriveLetter -DiskNumber $script:TargetDisk.Number

    $dlg = New-BaseForm -TitleSuffix 'Confirm Disk Selection' -Width 560

    $lblIntro             = New-Object System.Windows.Forms.Label
    $lblIntro.Text        = 'AutoReset has found the following disk to re-install Windows to:'
    $lblIntro.AutoSize    = $true
    $lblIntro.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $dlg.Tag.Controls.Add($lblIntro)

    $lblDisk             = New-Object System.Windows.Forms.Label
    $lblDisk.Text        = "    -  $($script:TargetDisk.FriendlyName)  |  $sizeGB GB  |  $letter"
    $lblDisk.Font        = UiFont 10 -Bold
    $lblDisk.AutoSize    = $true
    $lblDisk.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $lblDisk.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
    $dlg.Tag.Controls.Add($lblDisk)

    $lblAsk             = New-Object System.Windows.Forms.Label
    $lblAsk.Text        = 'Is this the right disk?'
    $lblAsk.AutoSize    = $true
    $lblAsk.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $dlg.Tag.Controls.Add($lblAsk)

    $lblWarning           = New-Object System.Windows.Forms.Label
    $lblWarning.Text      = 'NOTE: Any actions performed after clicking Confirm are irreversible.'
    $lblWarning.Font      = UiFont 10 -Bold
    $lblWarning.ForeColor = [System.Drawing.Color]::Red
    $lblWarning.AutoSize  = $true
    $lblWarning.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $lblWarning.Margin    = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $dlg.Tag.Controls.Add($lblWarning)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 524
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    # Pat - AutoSize buttons to prevent text truncation at high DPI -
    #----------------------------------------------------------------
    $btnChoose              = New-Object System.Windows.Forms.Button
    $btnChoose.Text         = 'Choose Disk'
    $btnChoose.AutoSize     = $true
    $btnChoose.MinimumSize  = New-Object System.Drawing.Size(112, 32)
    $btnChoose.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnPanel.Controls.Add($btnChoose)

    $btnConfirm              = New-Object System.Windows.Forms.Button
    $btnConfirm.Text         = 'Confirm'
    $btnConfirm.AutoSize     = $true
    $btnConfirm.MinimumSize  = New-Object System.Drawing.Size(112, 32)
    $btnConfirm.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    Set-PrimaryButtonStyle -Button $btnConfirm
    $btnPanel.Controls.Add($btnConfirm)
    #----------------------------------------------------------------

    $dlg.Tag.Controls.Add($btnPanel)

    $dlg.AcceptButton = $btnConfirm
    $dlg.CancelButton = $btnChoose

    $confirmYesTimer          = New-Object System.Windows.Forms.Timer
    $confirmYesTimer.Interval = 50
    $confirmYesTimer.Add_Tick({
        $confirmYesTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    }.GetNewClosure())

    $confirmNoTimer          = New-Object System.Windows.Forms.Timer
    $confirmNoTimer.Interval = 50
    $confirmNoTimer.Add_Tick({
        $confirmNoTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::No
    }.GetNewClosure())

    $btnConfirm.Add_Click({ $confirmYesTimer.Start() }.GetNewClosure())
    $btnChoose.Add_Click({ $confirmNoTimer.Start() }.GetNewClosure())

    # Pat - Ctrl+Shift+W launches KillDisk -------------------------
    #----------------------------------------------------------------
    $script:WipeRequested = $false

    $wipeTimer          = New-Object System.Windows.Forms.Timer
    $wipeTimer.Interval = 50
    $wipeTimer.Add_Tick({
        $wipeTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Abort
    }.GetNewClosure())

    $dlg.Add_KeyDown({
        if ($_.Control -and $_.Shift -and $_.KeyCode -eq [System.Windows.Forms.Keys]::W) {
            $_.Handled          = $true
            $_.SuppressKeyPress = $true
            $script:WipeRequested = $true
            $wipeTimer.Start()
        }
    }.GetNewClosure())
    #----------------------------------------------------------------

    # Pat - Set-FormSize before ShowDialog --------------------------
    Set-FormSize -Form $dlg
    #----------------------------------------------------------------
    $result = $dlg.ShowDialog()
    $confirmYesTimer.Dispose()
    $confirmNoTimer.Dispose()
    $wipeTimer.Stop()
    $wipeTimer.Dispose()
    $dlg.Dispose()
    return $result
}

function Show-DiskPicker {
    $dlg = New-BaseForm -TitleSuffix 'Disk Selection' -Width 580

    $lbl             = New-Object System.Windows.Forms.Label
    $lbl.Text        = 'Please select the drive you would like to install Windows onto!'
    $lbl.AutoSize    = $true
    $lbl.MaximumSize = New-Object System.Drawing.Size(544, 0)
    $dlg.Tag.Controls.Add($lbl)

    $list               = New-Object System.Windows.Forms.ListView
    $list.View          = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect   = $false
    $list.GridLines     = $true
    $list.Margin        = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    [void]$list.Columns.Add('Name', 260)
    [void]$list.Columns.Add('Size (GB)', 100)
    [void]$list.Columns.Add('Drive', 80)

    # Pat - DPI-aware ListView height using font measurement --------
    #----------------------------------------------------------------
    $rowHeight    = [System.Windows.Forms.TextRenderer]::MeasureText(
        'X', (UiFont 9)).Height + 4
    $headerHeight = $rowHeight + 4
    $listHeight   = [math]::Max(
        $headerHeight + 22,
        $headerHeight + ($script:AllDisks.Count * $rowHeight))
    $list.Size        = New-Object System.Drawing.Size(544, $listHeight)
    $list.MinimumSize = New-Object System.Drawing.Size(544, $listHeight)
    #----------------------------------------------------------------

    foreach ($d in $script:AllDisks) {
        $sizeGB     = [math]::Round($d.Size / 1GB, 1)
        $letter     = Get-PrimaryDriveLetter -DiskNumber $d.Number
        $item       = New-Object System.Windows.Forms.ListViewItem($d.FriendlyName)
        [void]$item.SubItems.Add("$sizeGB")
        [void]$item.SubItems.Add($letter)
        $selectable = $d.BusType -notin @('USB', 'iSCSI', 'File Backed Virtual')
        $item.Tag   = if ($selectable) { $d.Number } else { $null }
        if (-not $selectable) {
            $item.ForeColor = [System.Drawing.SystemColors]::GrayText
        }
        [void]$list.Items.Add($item)
    }
    $dlg.Tag.Controls.Add($list)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 544
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    # Pat - AutoSize buttons ----------------------------------------
    #----------------------------------------------------------------
    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.AutoSize     = $true
    $btnCancel.MinimumSize  = New-Object System.Drawing.Size(96, 32)
    $btnCancel.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnPanel.Controls.Add($btnCancel)

    $btnSelect              = New-Object System.Windows.Forms.Button
    $btnSelect.Text         = 'Select'
    $btnSelect.AutoSize     = $true
    $btnSelect.MinimumSize  = New-Object System.Drawing.Size(112, 32)
    $btnSelect.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnSelect.Enabled      = $false
    Set-PrimaryButtonStyle -Button $btnSelect
    $btnPanel.Controls.Add($btnSelect)
    #----------------------------------------------------------------

    $dlg.Tag.Controls.Add($btnPanel)

    $list.Add_ItemSelectionChanged({
        if ($null -eq $_.Item.Tag) { $_.Item.Selected = $false }
        $btnSelect.Enabled = ($list.SelectedItems.Count -gt 0 -and $null -ne $list.SelectedItems[0].Tag)
    }.GetNewClosure())

    $firstSelectable = $list.Items | Where-Object { $null -ne $_.Tag } | Select-Object -First 1
    if ($firstSelectable) { $firstSelectable.Selected = $true }

    $pickerOkTimer          = New-Object System.Windows.Forms.Timer
    $pickerOkTimer.Interval = 50
    $pickerOkTimer.Add_Tick({
        $pickerOkTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }.GetNewClosure())

    $pickerCancelTimer          = New-Object System.Windows.Forms.Timer
    $pickerCancelTimer.Interval = 50
    $pickerCancelTimer.Add_Tick({
        $pickerCancelTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }.GetNewClosure())

    $btnSelect.Add_Click({
        if ($list.SelectedItems.Count -gt 0 -and $null -ne $list.SelectedItems[0].Tag) {
            $pickerOkTimer.Start()
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({ $pickerCancelTimer.Start() }.GetNewClosure())
    $dlg.AcceptButton = $btnSelect
    $dlg.CancelButton = $btnCancel

    # Pat - Set-FormSize before ShowDialog --------------------------
    Set-FormSize -Form $dlg
    #----------------------------------------------------------------
    $result = $dlg.ShowDialog()
    $chosen = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedItems.Count -gt 0) {
        $chosen = [int]$list.SelectedItems[0].Tag
    }
    $pickerOkTimer.Dispose()
    $pickerCancelTimer.Dispose()
    $dlg.Dispose()
    if ($null -eq $chosen) { return $null }
    return (Get-Disk -Number $chosen)
}

# ── Disk confirmation loop ──────────────────────────────────────────

if (Get-Config 'ConfirmBeforeWipe' $true) {
    while ($true) {
        $sizeGB = [math]::Round($script:TargetDisk.Size / 1GB, 1)
        $letter = Get-PrimaryDriveLetter -DiskNumber $script:TargetDisk.Number
        Write-Log ("Presenting disk for confirmation: {0} | {1} GB | {2}" -f $script:TargetDisk.FriendlyName, $sizeGB, $letter)

        $confirmResult = Show-DiskConfirmation

        # Pat - Ctrl+Shift+W: launch KillDisk -------------------------
        #---------------------------------------------------------------
        if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Abort) {
            try {
                Write-Log 'User triggered KillDisk launch (Ctrl+Shift+W).'

                $wipeScript = $null
                foreach ($root in @($script:MediaRoot, $script:ImagePayloadRoot)) {
                    if (-not $root) { continue }
                    $candidate = Join-Path $root 'Scripts\Invoke-KillDisk.ps1'
                    Write-Log "Checking for wipe script: $candidate"
                    if (Test-Path $candidate) { $wipeScript = $candidate; break }
                }

                Write-Log "MediaRoot: $($script:MediaRoot)"
                Write-Log "ImagePayloadRoot: $($script:ImagePayloadRoot)"
                Write-Log "Resolved wipe script: $wipeScript"

                if ($wipeScript) {
                    $wipeArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Serial "{1}"' -f
                        $wipeScript, $script:Serial
                    Write-Log "Launching: powershell.exe $wipeArgs"
                    Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
                        -ArgumentList $wipeArgs -Wait
                    exit 0
                }
                else {
                    Write-Log 'Invoke-KillDisk.ps1 not found on media.' 'ERROR'
                    [void][System.Windows.Forms.MessageBox]::Show(
                        'Invoke-KillDisk.ps1 was not found on the deployment media.',
                        (Title 'Error'),
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error)
                }
            }
            catch {
                Write-Log "KillDisk launch FAILED: $($_.Exception.Message)" 'ERROR'
                Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
                if ($_.ScriptStackTrace) {
                    Write-Log "Stack: $($_.ScriptStackTrace -replace "`n", ' -> ')" 'ERROR'
                }
                Show-Console
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch KillDisk:`r`n`r`n$($_.Exception.Message)`r`n`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`n`r`nCheck log: $($script:LogFile)",
                    (Title 'KillDisk Error'),
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error)
            }
            continue
        }
        #---------------------------------------------------------------

        if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Disk confirmed by user.'
            break
        }

        Write-Log 'User chose to pick a different disk.'
        $picked = Show-DiskPicker
        if (-not $picked) {
            Write-Log 'User cancelled disk selection.' 'ERROR'
            exit 1
        }
        $script:TargetDisk = $picked
    }
}
else {
    Write-Log 'Disk confirmation skipped (ConfirmBeforeWipe = false).'
}

$sizeGB = [math]::Round($script:TargetDisk.Size / 1GB, 1)
Write-Section 'Target Disk'
Write-LogBlock @(
    "Disk         : $($script:TargetDisk.Number)"
    "Name         : $($script:TargetDisk.FriendlyName)"
    "Size         : $sizeGB GB"
    "Bus type     : $($script:TargetDisk.BusType)"
    "Style        : $($script:TargetDisk.PartitionStyle)"
)

# ═════════════════════════════════════════════════════════════════════
# STAGE 3: MAIN DEPLOYMENT
# ═════════════════════════════════════════════════════════════════════

try {

$form = New-BaseForm -TitleSuffix '' -Width 500
$form.Text = Title

$tlpTop = New-Object System.Windows.Forms.TableLayoutPanel
$tlpTop.ColumnCount = 2
$tlpTop.RowCount = 1
$tlpTop.Width = 464
$tlpTop.AutoSize = $true
$tlpTop.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$tlpTop.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$lblTime              = New-Object System.Windows.Forms.Label
$lblTime.Text         = 'Time Remaining: estimating...'
$lblTime.Font         = UiFont 9
$lblTime.AutoSize     = $true
$lblTime.Dock         = 'Fill'
$lblTime.ForeColor    = [System.Drawing.Color]::FromArgb(100, 100, 100)
$lblTime.BackColor    = [System.Drawing.Color]::Transparent
$tlpTop.Controls.Add($lblTime, 0, 0)

$lblPct              = New-Object System.Windows.Forms.Label
$lblPct.Text         = '0%'
$lblPct.Font         = UiFont 10 -Bold
$lblPct.AutoSize     = $true
$lblPct.Dock         = 'Fill'
$lblPct.TextAlign    = 'MiddleRight'
$lblPct.ForeColor    = [System.Drawing.Color]::Black
$lblPct.BackColor    = [System.Drawing.Color]::Transparent
$tlpTop.Controls.Add($lblPct, 1, 0)

$form.Tag.Controls.Add($tlpTop)

$pbMain                       = New-Object System.Windows.Forms.ProgressBar
$pbMain.Minimum               = 0
$pbMain.Maximum               = 100
$pbMain.Style                 = 'Continuous'
$pbMain.MarqueeAnimationSpeed = 0
$pbMain.Value                 = 0
$pbMain.Size                  = New-Object System.Drawing.Size(464, 20)
$pbMain.Margin                = New-Object System.Windows.Forms.Padding(0, 5, 0, 10)
$form.Tag.Controls.Add($pbMain)

$lblStep              = New-Object System.Windows.Forms.Label
$lblStep.Text         = ''
$lblStep.Font         = UiFont 10 -Bold
$lblStep.AutoSize     = $true
$lblStep.MinimumSize  = New-Object System.Drawing.Size(464, 0)
$lblStep.MaximumSize  = New-Object System.Drawing.Size(464, 0)
$lblStep.TextAlign    = 'MiddleCenter'
$lblStep.ForeColor    = [System.Drawing.Color]::Black
$lblStep.BackColor    = [System.Drawing.Color]::Transparent
$lblStep.Visible      = $false
$form.Tag.Controls.Add($lblStep)

$pbStep         = New-Object System.Windows.Forms.ProgressBar
$pbStep.Minimum = 0
$pbStep.Maximum = 100
$pbStep.Size    = New-Object System.Drawing.Size(464, 20)
$pbStep.Visible = $false
$form.Tag.Controls.Add($pbStep)

function Update-TimeRemaining {
    $elapsed = (Get-Date) - $script:DeployStart
    $pct     = 0
    if ($script:WeightTotal -gt 0) {
        $pct = ($script:WeightDone + ($script:CurrentWeight * $pbStep.Value / 100)) / $script:WeightTotal
    }
    if ($pct -le 0.02 -or $elapsed.TotalSeconds -lt 5) {
        $lblTime.Text = 'Time Remaining: estimating...'
        return
    }
    $totalEstimate = [TimeSpan]::FromSeconds($elapsed.TotalSeconds / $pct)
    $remaining     = $totalEstimate - $elapsed
    if ($remaining.TotalSeconds -lt 0) { $remaining = [TimeSpan]::Zero }

    if ($remaining.TotalHours -ge 1) {
        $lblTime.Text = 'Time Remaining: {0}h {1}m' -f [int]$remaining.TotalHours, $remaining.Minutes
    }
    elseif ($remaining.TotalMinutes -ge 1) {
        $lblTime.Text = 'Time Remaining: {0}m {1}s' -f [int]$remaining.TotalMinutes, $remaining.Seconds
    }
    else {
        $lblTime.Text = 'Time Remaining: less than a minute'
    }
}

function Set-Action {
    param([string]$Text, [switch]$Quiet)
    $lblStep.Text    = $Text
    $lblStep.Visible = $true
    if (-not $Quiet) { Write-Log $Text }
    Update-Ui
}

function Set-StepPercent {
    param([double]$Percent)
    if ($Percent -ge 0) {
        $stepPercent = [int][math]::Min(100, [math]::Round($Percent))

        if ($stepPercent -gt 0 -and $stepPercent -lt 100) {
            if (-not $pbStep.Visible) {
                $pbStep.Visible               = $true
                $pbStep.Style                 = 'Continuous'
                $pbStep.MarqueeAnimationSpeed = 0
            }
        }
        else {
            if ($pbStep.Visible) {
                $pbStep.Visible = $false
            }
        }

        $pbStep.Value = $stepPercent
        $overall = $script:WeightDone + ($script:CurrentWeight * $stepPercent / 100)
        $overallPct = [int][math]::Min(100, [math]::Round(100 * $overall / $script:WeightTotal))
        $pbMain.Style                 = 'Continuous'
        $pbMain.MarqueeAnimationSpeed = 0
        $pbMain.Value                 = $overallPct
        $lblPct.Text                  = "${overallPct}%"

        Update-TimeRemaining
    }
    Update-Ui
}

# ── Deployment steps ─────────────────────────────────────────────────

$steps = @(
    @{
        Name   = 'Wipe and Partition'
        Weight = 5
        Action = {
            $diskNum = $script:TargetDisk.Number
            if ($script:IsUefi) {
                $dp = @"
select disk $diskNum
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label=System
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=1024
format quick fs=ntfs label=Windows
assign letter=W
create partition primary
format quick fs=ntfs label=Recovery
assign letter=R
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
exit
"@
                Write-Log 'Partition layout: GPT (EFI 260 MB, MSR 16 MB, Windows, Recovery 1 GB)'
            }
            else {
                $dp = @"
select disk $diskNum
clean
create partition primary size=260
format quick fs=ntfs label=System
assign letter=S
active
create partition primary
format quick fs=ntfs label=Windows
assign letter=W
exit
"@
                Write-Log 'Partition layout: MBR (System 260 MB active, Windows)'
            }
            $dpFile = Join-Path $logRoot 'autoreset-partition.txt'
            Set-Content -Path $dpFile -Value $dp -Encoding Ascii

            $result = Invoke-External -FilePath 'diskpart.exe' -Arguments "/s $dpFile" -What 'diskpart'
            if ($result.ExitCode -ne 0) { throw "diskpart failed (exit code $($result.ExitCode))." }
            if (-not (Test-Path 'W:\')) { throw 'Windows partition (W:) not available after partitioning.' }
            if (-not (Test-Path 'S:\')) { throw 'System partition (S:) not available after partitioning.' }
            Write-Log 'Disk wiped and partitions created successfully.'
        }
    }
    @{
        Name   = 'Installing Windows'
        Weight = 50
        Action = {
            $imageRel = Get-Config 'ImageFile' 'Images\install.wim'
            $wim = Resolve-MediaFile $imageRel
            if (-not $wim) {
                throw "Image file '$imageRel' not found on the media."
            }
            $wimSize = (Get-Item -LiteralPath $wim).Length
            Write-Log ('Source image : {0}' -f $wim)
            Write-Log ('Image size   : {0:N2} GB' -f ($wimSize / 1GB))

            $info = Invoke-External -FilePath 'dism.exe' -What 'dism /Get-WimInfo' -Arguments "/Get-WimInfo /WimFile:`"$wim`""
            if ($info.ExitCode -ne 0) {
                throw "DISM cannot read the image file (exit $($info.ExitCode))."
            }
            $images = @(); $curIndex = $null
            foreach ($line in ($info.Output -split "[`r`n]+")) {
                if ($line -match '^\s*Index\s*:\s*(\d+)') { $curIndex = [int]$Matches[1] }
                elseif ($line -match '^\s*Name\s*:\s*(.+)$' -and $null -ne $curIndex) {
                    $images += [pscustomobject]@{ ImageIndex = $curIndex; ImageName = $Matches[1].Trim() }
                    $curIndex = $null
                }
            }
            if ($images.Count -eq 0) { throw "No images found inside $wim." }

            $index   = Get-Config 'ImageIndex' $null
            $edition = Get-Config 'ImageEdition' 'Windows 11 Enterprise'
            if ($null -ne $index -and "$index" -ne '') {
                $index = [int]$index
            }
            else {
                $match = $images | Where-Object { $_.ImageName -eq $edition } | Select-Object -First 1
                if (-not $match -and $images.Count -eq 1) { $match = $images[0] }
                if (-not $match) {
                    throw ("Edition '$edition' not found. Available: " +
                           (($images | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" }) -join ', '))
                }
                $index = $match.ImageIndex
            }
            $chosen = ($images | Where-Object { $_.ImageIndex -eq $index } | Select-Object -First 1).ImageName
            Write-Log ("Edition      : {0} (index {1})" -f $chosen, $index)

            $result = Invoke-External -FilePath 'dism.exe' -What 'dism /Apply-Image' -ParsePercent -Arguments (
                "/Apply-Image /ImageFile:`"$wim`" /Index:$index /ApplyDir:W:\")
            if ($result.ExitCode -ne 0) { throw "Applying the image failed (exit $($result.ExitCode))." }
            if (-not (Test-Path 'W:\Windows\System32')) { throw 'Image applied but W:\Windows\System32 is missing.' }
            Write-Log ('Image applied successfully in {0:mm\:ss}.' -f $result.Elapsed)
        }
    }
    @{
        Name   = 'Installing Drivers'
        Weight = 20
        Action = {
            $driverArchive = $null
            foreach ($archiveName in @('Drivers.7z', 'Drivers.zip')) {
                $driverArchive = Resolve-MediaFile ("Drivers\$($script:DriverFolder)\$archiveName")
                if ($driverArchive) { break }
                $driverArchive = Resolve-MediaFile "Drivers\$archiveName"
                if ($driverArchive) { break }
            }

            $driverPath = $null
            if ($driverArchive) {
                $driverPath = 'W:\Windows\Temp\AutoReset-Drivers'
                Remove-Item -LiteralPath $driverPath -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Path $driverPath -Force | Out-Null
                Write-Log ("Extracting driver archive: {0}" -f $driverArchive)

                if ($driverArchive -match '\.7z$') {
                    $sevenZip = Resolve-MediaFile 'Tools\7za.exe'
                    if (-not $sevenZip) {
                        $sevenZip = 'X:\Payload\Tools\7za.exe'
                        if (-not (Test-Path $sevenZip)) {
                            throw '7za.exe not found. Add it to Payload\Tools to extract .7z driver archives.'
                        }
                    }
                    $r = Invoke-External -FilePath $sevenZip -What '7za extract' -ParsePercent `
                        -Arguments "x `"$driverArchive`" -o`"$driverPath`" -y"
                    if ($r.ExitCode -ne 0) { throw "7-Zip extraction failed (exit $($r.ExitCode))." }
                }
                else {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($driverArchive, $driverPath)
                }

                $modelPath = Join-Path $driverPath $script:DriverFolder
                if (Test-Path -LiteralPath $modelPath) { $driverPath = $modelPath }
            }
            else {
                $driverPath = Resolve-MediaFile ("Drivers\" + $script:DriverFolder)
            }

            if (-not $driverPath -or -not (Test-Path $driverPath)) {
                Write-Log ("No drivers found for model '{0}'. Continuing without model-specific drivers." -f $script:Model) 'WARN'
                $script:StepWarnings += "No drivers injected for $($script:Model)."
                return 'SKIPPED'
            }

            $infs = @(Get-ChildItem -Path $driverPath -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
            if ($infs.Count -eq 0) {
                Write-Log ("Driver folder '{0}' contains no .inf packages." -f $script:DriverFolder) 'WARN'
                $script:StepWarnings += "No .inf files found in Drivers\$($script:DriverFolder)."
                return 'SKIPPED'
            }

            Write-Log ("Driver source: {0}" -f $driverPath)
            Write-Log ("Packages     : {0} .inf file(s)" -f $infs.Count)
            $r = Invoke-External -FilePath 'dism.exe' -What 'dism /Add-Driver' -ParsePercent -Arguments (
                "/Image:W:\ /Add-Driver /Driver:`"$driverPath`" /Recurse")

            if ($r.ExitCode -eq 0) {
                $script:DriversAdded = $infs.Count
                Write-Log ('{0} driver package(s) injected successfully.' -f $infs.Count)
            }
            else {
                if (Get-Config 'ContinueOnDriverError' $true) {
                    Write-Log ("Driver injection returned exit code {0}. Some packages may have failed." -f $r.ExitCode) 'WARN'
                    $script:StepWarnings += 'Some drivers failed to install.'
                }
                else { throw "Driver injection failed (exit $($r.ExitCode))." }
            }

            if ($driverArchive -and (Test-Path 'W:\Windows\Temp\AutoReset-Drivers')) {
                Remove-Item -LiteralPath 'W:\Windows\Temp\AutoReset-Drivers' -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    @{
        Name   = 'Create WinRE Partition'
        Weight = 4
        Action = {
            if (-not $script:IsUefi) {
                Write-Log 'Skipped: Legacy BIOS layout does not use a recovery partition.'
                return 'SKIPPED'
            }
            if (-not (Get-Config 'SetupRecovery' $true)) {
                Write-Log 'Skipped: SetupRecovery is disabled in reset.json.'
                return 'SKIPPED'
            }
            $winre = 'W:\Windows\System32\Recovery\Winre.wim'
            if (-not (Test-Path $winre)) {
                Write-Log 'Winre.wim not found in the applied image.' 'WARN'
                return 'SKIPPED'
            }
            if (-not (Test-Path 'R:\')) {
                Write-Log 'Recovery partition (R:) not available.' 'WARN'
                return 'SKIPPED'
            }
            New-Item -ItemType Directory -Path 'R:\Recovery\WindowsRE' -Force | Out-Null
            Copy-Item -Path $winre -Destination 'R:\Recovery\WindowsRE\Winre.wim' -Force
            Write-Log 'Winre.wim copied to R:\Recovery\WindowsRE.'
            $result = Invoke-External -FilePath 'W:\Windows\System32\ReAgentc.exe' -What 'reagentc' -Arguments (
                '/SetREImage /Path R:\Recovery\WindowsRE /Target W:\Windows')
            if ($result.ExitCode -ne 0) {
                Write-Log 'ReAgentc registration failed. WinRE will be configured on first boot.' 'WARN'
                $script:StepWarnings += 'WinRE registration deferred to first boot.'
            }
            else {
                Write-Log 'Recovery environment staged and registered.'
            }
        }
    }
    @{
        Name   = 'Create Boot Data'
        Weight = 5
        Action = {
            if ($script:IsUefi) {
                $result = Invoke-External -FilePath 'bcdboot.exe' -What 'bcdboot' -Arguments 'W:\Windows /s S: /f UEFI'
                if ($result.ExitCode -ne 0) { throw "bcdboot failed (exit $($result.ExitCode))." }
                $result = Invoke-External -FilePath 'bcdedit.exe' `
                    -What 'bcdedit displayorder' -Arguments '/set {fwbootmgr} displayorder {bootmgr} /addfirst'
                if ($result.ExitCode -ne 0) { throw 'Could not set Windows Boot Manager as the first UEFI boot entry.' }
                Write-Log 'UEFI boot configuration created.'
            }
            else {
                $result = Invoke-External -FilePath 'bcdboot.exe' -What 'bcdboot' -Arguments 'W:\Windows /s S: /f BIOS'
                if ($result.ExitCode -ne 0) { throw "bcdboot failed (exit $($result.ExitCode))." }
                Write-Log 'Legacy BIOS boot configuration created.'
            }
        }
    }
    @{
        Name   = 'Verify Install'
        Weight = 3
        Action = {
            Write-Log 'Running post-installation verification...'
            $problems = @()
            if (-not (Test-Path 'W:\Windows\System32\ntoskrnl.exe')) { $problems += 'ntoskrnl.exe missing.' }
            if (-not (Test-Path 'W:\Windows\System32\config\SYSTEM')) { $problems += 'SYSTEM registry hive missing.' }

            $bootOk = if ($script:IsUefi) { Test-Path 'S:\EFI\Microsoft\Boot\BCD' } else { Test-Path 'S:\Boot\BCD' }
            if (-not $bootOk) { $problems += 'Boot Configuration Data (BCD) not found.' }

            $free = (Get-Volume -DriveLetter W -ErrorAction SilentlyContinue).SizeRemaining
            if ($free) { Write-Log ('Windows volume free space: {0:N1} GB' -f ($free / 1GB)) }
            if ($script:DriversAdded -gt 0) {
                Write-Log ('{0} driver package(s) were injected.' -f $script:DriversAdded)
            }

            if ($problems.Count -gt 0) {
                foreach ($p in $problems) { Write-Log "VERIFICATION FAILED: $p" 'ERROR' }
                throw ('Verification failed: ' + ($problems -join ' | '))
            }
            Write-Log 'All verification checks passed.'
        }
    }
    @{
        Name   = 'Save Logs'
        Weight = 6
        Action = {
            Write-Log 'Saving logs to the installed OS and deployment media...'
            try { Copy-LogsToTarget } catch { Write-Log "Copy-LogsToTarget failed: $($_.Exception.Message)" 'WARN' }
            Write-Log 'Logs copied to W:\Windows\Temp.'
            [void](Save-DeviceLog -Result 'SUCCESS')
        }
    }
)

# ── Engine ───────────────────────────────────────────────────────────

$script:WeightTotal   = 0.0
foreach ($s in $steps) { $script:WeightTotal += [double]$s.Weight }
$script:WeightDone    = 0.0
$script:CurrentWeight = 0.0
$script:DeployStart   = Get-Date

# Pat - Set-FormSize before Show ------------------------------------
Set-FormSize -Form $form
#--------------------------------------------------------------------
$form.Show()
$form.Activate()
Update-Ui

}
catch {
    Write-Log "Stage 3 setup crash: $($_.Exception.Message)" 'ERROR'
    Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-Log "Stack: $($_.ScriptStackTrace -replace "`n", ' -> ')" 'ERROR'
    }
    $crashForm = New-BaseForm -TitleSuffix 'CRASH CAUGHT' -Width 600

    $crashLbl             = New-Object System.Windows.Forms.Label
    $crashLbl.Text        = "Crash during form setup!`r`n`r`n$($_.Exception.Message)`r`n`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`n`r`nPress F3 for log, F8 for cmd. Close this to reboot."
    $crashLbl.AutoSize    = $true
    $crashLbl.MaximumSize = New-Object System.Drawing.Size(564, 0)
    $crashForm.Tag.Controls.Add($crashLbl)

    $crashForm.ControlBox = $true
    # Pat - Set-FormSize before ShowDialog --------------------------
    Set-FormSize -Form $crashForm
    #----------------------------------------------------------------
    [void]$crashForm.ShowDialog()
    $crashForm.Dispose()
    exit 1
}

# Pat - Wrap entire deployment engine + Stage 4 in try/catch -------
#-------------------------------------------------------------------
try {

Write-Section 'Deployment Started'

$failed     = $false
$failedStep = $null
$stepNumber = 0
$results    = New-Object System.Collections.Generic.List[object]

foreach ($step in $steps) {
    $stepNumber++
    $script:CurrentWeight = [double]$step.Weight
    $script:LogComponent  = $step.Name
    $stepStart = Get-Date

    Write-Section ("Step {0}/{1}: {2}" -f $stepNumber, $steps.Count, $step.Name)

    $pbStep.Visible  = $false
    $pbStep.Value    = 0
    $lblStep.Visible = $false
    $lblStep.Text    = ''
    Set-Action $step.Name -Quiet
    Update-Ui

    try {
        $outcome = & $step.Action
        $elapsed = (Get-Date) - $stepStart
        $state   = if ("$outcome" -eq 'SKIPPED') { 'SKIPPED' } else { 'OK' }
        Write-Log ("{0} completed: {1} ({2:mm\:ss})" -f $step.Name, $state, $elapsed)
        $results.Add([pscustomobject]@{ Step = $step.Name; State = $state; Elapsed = $elapsed })

        Set-StepPercent 100
        $script:WeightDone += $script:CurrentWeight
        Update-Ui
    }
    catch {
        $failed     = $true
        $failedStep = $step.Name
        $elapsed    = (Get-Date) - $stepStart
        $results.Add([pscustomobject]@{ Step = $step.Name; State = 'FAILED'; Elapsed = $elapsed })
        Write-Log ("{0} FAILED after {1:mm\:ss}" -f $step.Name, $elapsed) 'ERROR'
        Write-Log ("Exception: {0}" -f $_.Exception.Message) 'ERROR'
        if ($_.ScriptStackTrace) {
            Write-Log ("Stack: {0}" -f ($_.ScriptStackTrace -replace "`n", ' -> ')) 'ERROR'
        }
        break
    }
}

# ── Summary ──────────────────────────────────────────────────────────

$script:LogComponent = 'AutoReset'
$totalDuration = (Get-Date) - $script:StartTime
$outcome = if ($failed) { 'FAILED' } else { 'SUCCESS' }

Write-Section 'Run Summary'
Write-LogBlock @(
    "Result       : $outcome"
    "Device       : $($script:Manufacturer) $($script:Model)"
    "Service tag  : $(if ($script:Serial) { $script:Serial } else { 'UNKNOWN' })"
    "Duration     : $('{0:hh\:mm\:ss}' -f $totalDuration)"
    ''
    ('{0,-28} {1,-10} {2}' -f 'Step', 'Result', 'Duration')
    ('{0,-28} {1,-10} {2}' -f '----', '------', '--------')
)
foreach ($r in $results) {
    Write-LogBlock @(
        ('{0,-28} {1,-10} {2:mm\:ss}' -f $r.Step, $r.State, $r.Elapsed)
    )
}
Write-LogBlock @(
    ''
    ('{0,-28} {1,-10} {2:hh\:mm\:ss}' -f 'TOTAL', $outcome, $totalDuration)
)
if ($script:StepWarnings.Count -gt 0) {
    Write-LogBlock @('', 'Warnings:')
    foreach ($w in $script:StepWarnings) { Write-LogBlock @("  - $w") }
}

try { Copy-LogsToTarget } catch { Write-Log "Final log copy failed: $($_.Exception.Message)" 'WARN' }

# ═════════════════════════════════════════════════════════════════════
# STAGE 4: COMPLETION OR ERROR
# ═════════════════════════════════════════════════════════════════════

$form.Visible = $false

if (-not $failed) {
    try {
        Write-Section 'AutoReset completed successfully'

        $dlg = New-BaseForm -TitleSuffix 'Complete!' -Width 580

        $serial = if ($script:Serial) { $script:Serial } else { 'this device' }

        $lblDone             = New-Object System.Windows.Forms.Label
        $lblDone.Text        = 'AutoReset has now installed a fresh copy of Windows on this device. Please ensure the following:'
        $lblDone.AutoSize    = $true
        $lblDone.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $dlg.Tag.Controls.Add($lblDone)

        $lblChecklist             = New-Object System.Windows.Forms.Label
        $lblChecklist.Text        = "    -  $serial is unblocked in Intune`r`n    -  $serial is removed from Active Directory`r`n    -  $serial is removed from SCCM"
        $lblChecklist.AutoSize    = $true
        $lblChecklist.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $lblChecklist.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
        $dlg.Tag.Controls.Add($lblChecklist)

        $lblRemoveUsb             = New-Object System.Windows.Forms.Label
        $lblRemoveUsb.Text        = 'To restart the device, remove the USB and click Restart.'
        $lblRemoveUsb.Font        = UiFont 10 -Bold
        $lblRemoveUsb.ForeColor   = [System.Drawing.Color]::Red
        $lblRemoveUsb.AutoSize    = $true
        $lblRemoveUsb.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $dlg.Tag.Controls.Add($lblRemoveUsb)

        $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
        $btnPanel.FlowDirection = 'RightToLeft'
        $btnPanel.AutoSize      = $true
        $btnPanel.Width         = 544
        $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

        # Pat - AutoSize button -------------------------------------
        #------------------------------------------------------------
        $btnRestart              = New-Object System.Windows.Forms.Button
        $btnRestart.Text         = 'Remove USB first'
        $btnRestart.AutoSize     = $true
        $btnRestart.MinimumSize  = New-Object System.Drawing.Size(132, 32)
        $btnRestart.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
        $btnRestart.Enabled      = $false
        Set-PrimaryButtonStyle -Button $btnRestart
        #------------------------------------------------------------

        $btnPanel.Controls.Add($btnRestart)
        $dlg.Tag.Controls.Add($btnPanel)
        $dlg.AcceptButton = $btnRestart

        $successTimer          = New-Object System.Windows.Forms.Timer
        $successTimer.Interval = 50
        $successTimer.Add_Tick({
            $successTimer.Stop()
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }.GetNewClosure())
        $btnRestart.Add_Click({ $successTimer.Start() }.GetNewClosure())

        $qualifier = if ($script:MediaRoot) { Split-Path -Path ($script:MediaRoot + '\') -Qualifier } else { $null }

        $usbTimer          = New-Object System.Windows.Forms.Timer
        $usbTimer.Interval = 1000
        $usbTimer.Add_Tick({
            $present = $qualifier -and (Test-Path ($qualifier + '\'))
            if (-not $present) {
                $btnRestart.Enabled = $true
                $btnRestart.Text    = 'Restart'
                $usbTimer.Stop()
            }
        }.GetNewClosure())

        if (-not $qualifier -or -not (Test-Path ($qualifier + '\'))) {
            $btnRestart.Enabled = $true
            $btnRestart.Text    = 'Restart'
        }
        else { $usbTimer.Start() }

        # Pat - Set-FormSize before ShowDialog ----------------------
        Set-FormSize -Form $dlg
        #------------------------------------------------------------
        [void]$dlg.ShowDialog()
        $successTimer.Dispose()
        $usbTimer.Stop()
        $usbTimer.Dispose()
        $dlg.Dispose()

        Write-Log 'User clicked Restart. Rebooting device.'
        try { Copy-LogsToTarget } catch { }
        & wpeutil.exe reboot
        exit 0
    }
    catch {
        Show-Console
        try {
            Write-Log "Completion screen failed: $($_.Exception.Message)" 'ERROR'
            Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
            try { Copy-LogsToTarget } catch { }
        } catch { }
        Write-Host ''
        Write-Host '  AutoReset completed successfully but the completion screen failed.' -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Line:  $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Logs: $($script:LogFile)" -ForegroundColor Yellow
        Write-Host '  Press any key to reboot...' -ForegroundColor Gray
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        & wpeutil.exe reboot
        exit 0
    }
}
else {
    try {
        $friendly = Get-FriendlyError -StepName $failedStep
        $dlg = New-BaseForm -TitleSuffix 'Error' -Width 580

        Show-Console

        [void](Save-DeviceLog -Result 'FAILED')

        $lblError             = New-Object System.Windows.Forms.Label
        $lblError.Text        = "AutoReset has encountered an error $friendly"
        $lblError.AutoSize    = $true
        $lblError.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $dlg.Tag.Controls.Add($lblError)

        $lblLogHint             = New-Object System.Windows.Forms.Label
        $lblLogHint.Text        = "Service tag: $($script:Serial)  |  Logs: $($script:LogFile)"
        $lblLogHint.Font        = UiFont 8
        $lblLogHint.AutoSize    = $true
        $lblLogHint.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $lblLogHint.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
        $lblLogHint.ForeColor   = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $dlg.Tag.Controls.Add($lblLogHint)

        $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
        $btnPanel.FlowDirection = 'RightToLeft'
        $btnPanel.AutoSize      = $true
        $btnPanel.Width         = 544
        $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

        $errorRestartTimer          = New-Object System.Windows.Forms.Timer
        $errorRestartTimer.Interval = 50
        $errorRestartTimer.Add_Tick({
            $errorRestartTimer.Stop()
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }.GetNewClosure())

        $errorRetryTimer          = New-Object System.Windows.Forms.Timer
        $errorRetryTimer.Interval = 50
        $errorRetryTimer.Add_Tick({
            $errorRetryTimer.Stop()
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Retry
        }.GetNewClosure())

        # Pat - AutoSize buttons ------------------------------------
        #------------------------------------------------------------
        $btnRestart              = New-Object System.Windows.Forms.Button
        $btnRestart.Text         = 'Restart'
        $btnRestart.AutoSize     = $true
        $btnRestart.MinimumSize  = New-Object System.Drawing.Size(120, 32)
        $btnRestart.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
        $btnRestart.Add_Click({ $errorRestartTimer.Start() }.GetNewClosure())

        $retryable = $failedStep -in @('Installing Drivers', 'Create WinRE Partition')
        if ($retryable) {
            $btnRetry              = New-Object System.Windows.Forms.Button
            $btnRetry.Text         = 'Try Again'
            $btnRetry.AutoSize     = $true
            $btnRetry.MinimumSize  = New-Object System.Drawing.Size(120, 32)
            $btnRetry.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
            $btnRetry.Add_Click({ $errorRetryTimer.Start() }.GetNewClosure())
            Set-PrimaryButtonStyle -Button $btnRetry

            $btnPanel.Controls.Add($btnRestart)
            $btnPanel.Controls.Add($btnRetry)
        } else {
            Set-PrimaryButtonStyle -Button $btnRestart
            $btnPanel.Controls.Add($btnRestart)
        }
        #------------------------------------------------------------

        $dlg.Tag.Controls.Add($btnPanel)
        $dlg.AcceptButton = $btnRestart

        # Pat - Set-FormSize before ShowDialog ----------------------
        Set-FormSize -Form $dlg
        #------------------------------------------------------------
        $errorResult = $dlg.ShowDialog()
        $errorRestartTimer.Dispose()
        $errorRetryTimer.Dispose()
        $dlg.Dispose()

        if ($errorResult -eq [System.Windows.Forms.DialogResult]::Retry) {
            Write-Log 'User chose to retry. Restarting device.'
            & wpeutil.exe reboot
            exit 0
        }

        Write-Section 'AutoReset FAILED'
        Write-Log 'User clicked Restart after failure.'
        try { Copy-LogsToTarget } catch { }
        & wpeutil.exe reboot
        exit 1
    }
    catch {
        Show-Console
        try { Write-Log "Error handler itself failed: $($_.Exception.Message)" 'ERROR' } catch { }
        Write-Host ''
        Write-Host '  AutoReset FAILED and the error dialog could not be shown.' -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Logs: $($script:LogFile)" -ForegroundColor Yellow
        Write-Host "  Service tag: $($script:Serial)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Type EXIT to reboot, or press F8 to open another command prompt.' -ForegroundColor Gray
        Write-Host ''
        Start-Process -FilePath (Join-Path $env:windir 'System32\cmd.exe') `
            -ArgumentList '/k echo AutoReset FAILED. Type EXIT to reboot.' -Wait
        exit 1
    }
}

# Pat - Outer catch for entire deployment engine + Stage 4 ---------
#-------------------------------------------------------------------
}
catch {
    Show-Console
    try {
        Write-Log "UNHANDLED deployment crash: $($_.Exception.Message)" 'ERROR'
        Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
        if ($_.ScriptStackTrace) {
            Write-Log "Stack: $($_.ScriptStackTrace -replace "`n", ' -> ')" 'ERROR'
        }
        try { Copy-LogsToTarget } catch { }
        try { [void](Save-DeviceLog -Result 'FAILED') } catch { }
    } catch { }

    try {
        $crashForm = New-BaseForm -TitleSuffix 'UNHANDLED ERROR' -Width 600

        $crashLbl             = New-Object System.Windows.Forms.Label
        $crashLbl.Text        = "Unhandled error during deployment!`r`n`r`n$($_.Exception.Message)`r`n`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`n`r`nPress F3 for log, F8 for cmd. Close this to reboot."
        $crashLbl.AutoSize    = $true
        $crashLbl.MaximumSize = New-Object System.Drawing.Size(564, 0)
        $crashForm.Tag.Controls.Add($crashLbl)

        $crashForm.ControlBox = $true
        # Pat - Set-FormSize before ShowDialog ----------------------
        Set-FormSize -Form $crashForm
        #------------------------------------------------------------
        [void]$crashForm.ShowDialog()
        $crashForm.Dispose()
    }
    catch {
        Write-Host ''
        Write-Host '  UNHANDLED ERROR and crash dialog failed.' -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Logs: $($script:LogFile)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press any key to reboot...' -ForegroundColor Gray
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    & wpeutil.exe reboot
    exit 1
}