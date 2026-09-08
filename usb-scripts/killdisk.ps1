<#
.SYNOPSIS
    Overwrites explicitly selected internal disks with zeros inside WinPE.
.DESCRIPTION
    Uses DiskPart clean all, not a vendor SSD/NVMe sanitize command. An exit-zero
    result is not a sanitization certificate or a read-back verification.
    All disks start unchecked. Type WIPE after reviewing the selected disks.
    Logs include the running script path/hash and are copied to writable media.
#>
param(
    [string]$Serial = 'Unknown'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autoreset.common.ps1')
Assert-WinPEEnvironment
. (Join-Path $PSScriptRoot 'autoreset.ui.ps1')

# Pat - Hide the PowerShell console window -------------------------
#-------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Console {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@

$consoleHwnd = [Win32Console]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [void][Win32Console]::ShowWindow($consoleHwnd, 0)
}
#-------------------------------------------------------------------

[System.Windows.Forms.Application]::EnableVisualStyles()

# ── Logging ──────────────────────────────────────────────────────────

$logRoot = 'X:\Windows\Temp'
if (-not (Test-Path $logRoot)) { $logRoot = $env:TEMP }
$script:LogFile = Join-Path $logRoot 'KillDisk.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $prefix = switch ($Level) {
        'WARN'  { '[WARN ]' }
        'ERROR' { '[ERROR]' }
        default { '[INFO ]' }
    }
    Add-Content -Path $script:LogFile -Value (
        '{0}  {1}  {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $prefix, $Message
    ) -ErrorAction SilentlyContinue
}

Write-Log "Runtime script: $PSCommandPath"
Write-Log "Runtime SHA256: $((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash)"

function Save-WipeLog {
    foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue)) {
        if (-not $volume.DriveLetter) { continue }
        $root = "$($volume.DriveLetter):\"
        if (-not (Test-Path -LiteralPath (Join-Path $root 'Payload\UNE-Payload.tag'))) { continue }
        try {
            $folder = Join-Path $root 'Logs'
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            $safeSerial = $Serial -replace '[^A-Za-z0-9-]', '_'
            Copy-Item -LiteralPath $script:LogFile -Destination (
                Join-Path $folder ("{0}_{1}_ZeroOverwrite.log" -f $safeSerial, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            ) -Force -ErrorAction Stop
        }
        catch { Write-Log "Could not save wipe log to media: $($_.Exception.Message)" 'WARN' }
    }
}

# ── UI helpers ───────────────────────────────────────────────────────

$script:AccentColor = [System.Drawing.Color]::FromArgb(39, 178, 217)

function Set-PrimaryButtonStyle {
    param([System.Windows.Forms.Button]$Button)
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $script:AccentColor
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
}

function Add-FormHotkeys {
    param([System.Windows.Forms.Form]$Form)
    $Form.KeyPreview = $true
    $Form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F3) {
            if (Test-Path $script:LogFile) { Start-Process 'notepad.exe' $script:LogFile }
        }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
            $hwnd = [Win32Console]::GetConsoleWindow()
            if ($hwnd -ne [IntPtr]::Zero) {
                [void][Win32Console]::ShowWindow($hwnd, 5)
            }
            Start-Process "$env:windir\System32\cmd.exe"
        }
    })
}

function New-WipeForm {
    param([string]$Title, [int]$Width = 720, [int]$MinimumHeight = 260)
    $f = New-ResetForm -Title "KillDisk | $Title" -Width $Width -MinimumHeight $MinimumHeight
    Add-FormHotkeys -Form $f
    return $f
}

# ── Gather disks ─────────────────────────────────────────────────────

try {
$null = Get-Command diskpart.exe -ErrorAction Stop
$protectedDisks = @(Get-DeploymentMediaDiskNumbers)
$allDisks = @(Get-Disk | Sort-Object Number)
$internalDisks = @($allDisks | Where-Object {
    Test-EligibleTargetDisk -Disk $_ -ProtectedDiskNumbers $protectedDisks
})
$diskIdentities = @{}
foreach ($disk in $internalDisks) {
    $diskIdentities[[int]$disk.Number] = Get-DiskIdentity -Disk $disk
}

if ($internalDisks.Count -eq 0) {
    $errDlg = New-WipeForm -Title 'ERROR' -Width 520

    $errLbl             = New-Object System.Windows.Forms.Label
    $errLbl.Text        = 'No eligible disks found. Deployment media, boot/system, USB, offline, read-only and unidentified disks are protected.'
    $errLbl.AutoSize    = $true
    $errLbl.MaximumSize = New-Object System.Drawing.Size(468, 0)
    $errDlg.Tag.Controls.Add($errLbl)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 468
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    $errBtn             = New-Object System.Windows.Forms.Button
    $errBtn.Text        = 'Shut Down'
    $errBtn.AutoSize    = $true
    $errBtn.MinimumSize = New-Object System.Drawing.Size(112, 32)
    $errBtn.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    Set-PrimaryButtonStyle -Button $errBtn
    $btnPanel.Controls.Add($errBtn)
    $errDlg.Tag.Controls.Add($btnPanel)

    $errCloseTimer          = New-Object System.Windows.Forms.Timer
    $errCloseTimer.Interval = 50
    $errCloseTimer.Add_Tick({
        $errCloseTimer.Stop()
        $errDlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }.GetNewClosure())
    $errBtn.Add_Click({
        $errCloseTimer.Start()
    }.GetNewClosure())

    Set-FormSize -Form $errDlg
    [void]$errDlg.ShowDialog()
    $errCloseTimer.Dispose()
    $errDlg.Dispose()
    Write-Log 'No internal disks found. Shutting down.'
    & wpeutil.exe shutdown
    exit 0
}

Write-Log '============================================================'
Write-Log '  KillDisk'
Write-Log "  Service tag: $Serial"
Write-Log '============================================================'

# ── Disk selection + confirmation loop ───────────────────────────────

$selectedDisks = @()
$confirmed = $false

while (-not $confirmed) {

    # ── Disk selection ───────────────────────────────────────────────

    $dlgSelect = New-WipeForm -Title 'Select Disk(s)' -Width 800 -MinimumHeight 450

    $lblTitle             = New-Object System.Windows.Forms.Label
    $lblTitle.Text        = 'KillDisk - Disk Selection'
    $lblTitle.Font        = UiFont 12 -Bold
    $lblTitle.AutoSize    = $true
    $lblTitle.MaximumSize = New-Object System.Drawing.Size(508, 0)
    $dlgSelect.Tag.Controls.Add($lblTitle)

    $lblInstr             = New-Object System.Windows.Forms.Label
    $lblInstr.Text        = 'Select disks for a full logical zero overwrite. This can take hours. SSD/NVMe spare or remapped areas are not sanitized; use an approved device sanitization tool when required.'
    $lblInstr.AutoSize    = $true
    $lblInstr.MaximumSize = New-Object System.Drawing.Size(508, 0)
    $lblInstr.Margin      = New-Object System.Windows.Forms.Padding(0, 5, 0, 10)
    $dlgSelect.Tag.Controls.Add($lblInstr)

    $list               = New-Object System.Windows.Forms.ListView
    $list.View          = 'Details'
    $list.CheckBoxes    = $true
    $list.FullRowSelect = $true
    $list.MultiSelect   = $false
    $list.GridLines     = $true

    [void]$list.Columns.Add('Disk', 50)
    [void]$list.Columns.Add('Name', 218)
    [void]$list.Columns.Add('Size', 80)
    [void]$list.Columns.Add('Bus', 75)
    [void]$list.Columns.Add('Type', 75)
    Initialize-DiskList -List $list -RowCount $internalDisks.Count

    $list.BeginUpdate()
    foreach ($d in $internalDisks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        $mediaType = if ($d.MediaType) { "$($d.MediaType)" } else { 'Unknown' }
        $item = New-Object System.Windows.Forms.ListViewItem("$($d.Number)")
        [void]$item.SubItems.Add($d.FriendlyName)
        [void]$item.SubItems.Add("$sizeGB GB")
        [void]$item.SubItems.Add("$($d.BusType)")
        [void]$item.SubItems.Add($mediaType)
        $item.Tag     = $d.Number
        $item.Checked = $false
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()
    $dlgSelect.Tag.Controls.Add($list)

    $lblCaution             = New-Object System.Windows.Forms.Label
    $lblCaution.Text        = 'THIS CANNOT BE UNDONE. All data on selected disks will be permanently destroyed.'
    $lblCaution.Font        = UiFont 10 -Bold
    $lblCaution.ForeColor   = [System.Drawing.Color]::Red
    $lblCaution.AutoSize    = $true
    $lblCaution.MaximumSize = New-Object System.Drawing.Size(508, 0)
    $lblCaution.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $dlgSelect.Tag.Controls.Add($lblCaution)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 508
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    $btnCancel             = New-Object System.Windows.Forms.Button
    $btnCancel.Text        = 'Cancel'
    $btnCancel.AutoSize    = $true
    $btnCancel.MinimumSize = New-Object System.Drawing.Size(108, 32)
    $btnCancel.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnPanel.Controls.Add($btnCancel)

    $btnWipe             = New-Object System.Windows.Forms.Button
    $btnWipe.Text        = 'Wipe Selected'
    $btnWipe.Enabled     = $false
    $btnWipe.AutoSize    = $true
    $btnWipe.MinimumSize = New-Object System.Drawing.Size(120, 32)
    $btnWipe.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnWipe.ForeColor   = [System.Drawing.Color]::White
    $btnWipe.BackColor   = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $btnWipe.FlatStyle   = [System.Windows.Forms.FlatStyle]::Standard
    $btnPanel.Controls.Add($btnWipe)

    $dlgSelect.Tag.Controls.Add($btnPanel)

    $list.Add_ItemCheck({
        $dlgSelect.BeginInvoke([Action]{
            $anyChecked = $false
            foreach ($item in $list.Items) { if ($item.Checked) { $anyChecked = $true; break } }
            $btnWipe.Enabled = $anyChecked
        })
    }.GetNewClosure())

    $selectWipeTimer          = New-Object System.Windows.Forms.Timer
    $selectWipeTimer.Interval = 50
    $selectWipeTimer.Add_Tick({
        $selectWipeTimer.Stop()
        $dlgSelect.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    }.GetNewClosure())

    $selectCancelTimer          = New-Object System.Windows.Forms.Timer
    $selectCancelTimer.Interval = 50
    $selectCancelTimer.Add_Tick({
        $selectCancelTimer.Stop()
        $dlgSelect.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }.GetNewClosure())

    $btnWipe.Add_Click({
        $selectWipeTimer.Start()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $selectCancelTimer.Start()
    }.GetNewClosure())

    $dlgSelect.Add_Shown({
        $list.Refresh()
    }.GetNewClosure())

    Set-FormSize -Form $dlgSelect
    $selectResult = $dlgSelect.ShowDialog()
    $selectWipeTimer.Dispose()
    $selectCancelTimer.Dispose()

    $selectedDisks = @()
    if ($selectResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        foreach ($item in $list.Items) {
            if ($item.Checked) {
                $selectedDisks += [int]$item.Tag
            }
        }
    }
    $dlgSelect.Dispose()

    if ($selectedDisks.Count -eq 0) {
        Write-Log 'User cancelled or selected no disks. Shutting down.'
        & wpeutil.exe shutdown
        exit 0
    }

    Write-Log "Selected disks for wipe: $($selectedDisks -join ', ')"

    # ── Second confirmation ──────────────────────────────────────────

    $diskSummary = @()
    foreach ($dn in $selectedDisks) {
        $d = Assert-TargetDiskSafe -DiskNumber $dn -ExpectedIdentity $diskIdentities[$dn] -ProtectedDiskNumbers $protectedDisks
        $diskSummary += "    Disk $dn  |  $($d.FriendlyName)  |  $([math]::Round($d.Size / 1GB, 1)) GB"
    }

    $dlgConfirm2 = New-WipeForm -Title 'Confirm Wipe'

    $lblConfirm             = New-Object System.Windows.Forms.Label
    $lblConfirm.Text        = "You are about to permanently destroy all data on $($selectedDisks.Count) disk(s):"
    $lblConfirm.Font        = UiFont 10 -Bold
    $lblConfirm.AutoSize    = $true
    $lblConfirm.MaximumSize = New-Object System.Drawing.Size(504, 0)
    $dlgConfirm2.Tag.Controls.Add($lblConfirm)

    $lblDisks             = New-Object System.Windows.Forms.Label
    $lblDisks.Text        = $diskSummary -join "`r`n"
    $lblDisks.AutoSize    = $true
    $lblDisks.MaximumSize = New-Object System.Drawing.Size(504, 0)
    $lblDisks.Margin      = New-Object System.Windows.Forms.Padding(0, 5, 0, 10)
    $dlgConfirm2.Tag.Controls.Add($lblDisks)

    $typePanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $typePanel.FlowDirection = 'LeftToRight'
    $typePanel.AutoSize      = $true
    $typePanel.Margin        = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)

    $lblType          = New-Object System.Windows.Forms.Label
    $lblType.Text     = 'Type WIPE to confirm:'
    $lblType.AutoSize = $true
    $typePanel.Controls.Add($lblType)

    $txtConfirm             = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Font        = UiFont 10
    $txtConfirm.Size        = New-Object System.Drawing.Size(120, 26)
    # Pat - MinimumSize so FLP layout accounts for the text box height
    $txtConfirm.MinimumSize = New-Object System.Drawing.Size(120, 26)
    $typePanel.Controls.Add($txtConfirm)
    $dlgConfirm2.Tag.Controls.Add($typePanel)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 504
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    $btnBack             = New-Object System.Windows.Forms.Button
    $btnBack.Text        = 'Go Back'
    $btnBack.AutoSize    = $true
    $btnBack.MinimumSize = New-Object System.Drawing.Size(96, 32)
    $btnBack.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnPanel.Controls.Add($btnBack)

    $btnGo             = New-Object System.Windows.Forms.Button
    $btnGo.Text        = 'Confirm Wipe'
    $btnGo.AutoSize    = $true
    $btnGo.MinimumSize = New-Object System.Drawing.Size(120, 32)
    $btnGo.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnGo.Enabled     = $false
    $btnGo.ForeColor   = [System.Drawing.Color]::White
    $btnGo.BackColor   = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $btnGo.FlatStyle   = [System.Windows.Forms.FlatStyle]::Standard
    $btnPanel.Controls.Add($btnGo)

    $dlgConfirm2.Tag.Controls.Add($btnPanel)

    $txtConfirm.Add_TextChanged({
        $btnGo.Enabled = ($txtConfirm.Text.Trim() -ceq 'WIPE')
    }.GetNewClosure())

    $confirmGoTimer          = New-Object System.Windows.Forms.Timer
    $confirmGoTimer.Interval = 50
    $confirmGoTimer.Add_Tick({
        $confirmGoTimer.Stop()
        $dlgConfirm2.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    }.GetNewClosure())

    $confirmBackTimer          = New-Object System.Windows.Forms.Timer
    $confirmBackTimer.Interval = 50
    $confirmBackTimer.Add_Tick({
        $confirmBackTimer.Stop()
        $dlgConfirm2.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }.GetNewClosure())

    $btnGo.Add_Click({
        $confirmGoTimer.Start()
    }.GetNewClosure())

    $btnBack.Add_Click({
        $confirmBackTimer.Start()
    }.GetNewClosure())

    Set-FormSize -Form $dlgConfirm2
    $confirm2Result = $dlgConfirm2.ShowDialog()
    $confirmGoTimer.Dispose()
    $confirmBackTimer.Dispose()
    $dlgConfirm2.Dispose()

    if ($confirm2Result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log 'User confirmed logical zero overwrite by typing WIPE.'
        $confirmed = $true
    }
    else {
        Write-Log 'User clicked Go Back - returning to disk selection.'
    }
}

# ── Wipe progress ───────────────────────────────────────────────────

$dlgProgress = New-WipeForm -Title 'Wiping Disk(s)' -Width 500

$lblCurrent             = New-Object System.Windows.Forms.Label
$lblCurrent.Text        = 'Preparing...'
$lblCurrent.Font        = UiFont 10 -Bold
$lblCurrent.AutoSize    = $true
$lblCurrent.MaximumSize = New-Object System.Drawing.Size(464, 0)
$dlgProgress.Tag.Controls.Add($lblCurrent)

$lblDetail             = New-Object System.Windows.Forms.Label
$lblDetail.Text        = 'Do not remove the USB or power off the device.'
$lblDetail.AutoSize    = $true
$lblDetail.MaximumSize = New-Object System.Drawing.Size(464, 0)
$lblDetail.ForeColor   = [System.Drawing.Color]::FromArgb(100, 100, 100)
$dlgProgress.Tag.Controls.Add($lblDetail)

$pbWipe          = New-Object System.Windows.Forms.ProgressBar
$pbWipe.Minimum    = 0
$pbWipe.Maximum    = $selectedDisks.Count * 100
$pbWipe.Value      = 0
$pbWipe.Size        = New-Object System.Drawing.Size(448, 24)
# Pat - MinimumSize so FLP layout accounts for the progress bar height
$pbWipe.MinimumSize = New-Object System.Drawing.Size(448, 24)
$pbWipe.Margin   = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
$dlgProgress.Tag.Controls.Add($pbWipe)

$statsPanel             = New-Object System.Windows.Forms.TableLayoutPanel
$statsPanel.ColumnCount = 2
$statsPanel.RowCount    = 1
$statsPanel.Width       = 464
$statsPanel.AutoSize    = $true
$statsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$statsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$lblElapsed           = New-Object System.Windows.Forms.Label
$lblElapsed.Text      = 'Elapsed: 00:00:00'
$lblElapsed.AutoSize  = $true
$lblElapsed.Dock      = 'Fill'
$lblElapsed.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$statsPanel.Controls.Add($lblElapsed, 0, 0)

$lblOverall           = New-Object System.Windows.Forms.Label
$lblOverall.Text      = "Disk 0 of $($selectedDisks.Count)"
$lblOverall.AutoSize  = $true
$lblOverall.Dock      = 'Fill'
$lblOverall.TextAlign = 'MiddleRight'
$lblOverall.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$statsPanel.Controls.Add($lblOverall, 1, 0)

$dlgProgress.Tag.Controls.Add($statsPanel)

Set-FormSize -Form $dlgProgress
$dlgProgress.Show()
[System.Windows.Forms.Application]::DoEvents()

$wipeStart = Get-Date

$elapsedTimer          = New-Object System.Windows.Forms.Timer
$elapsedTimer.Interval = 1000
$elapsedTimer.Add_Tick({
    $lblElapsed.Text = 'Elapsed: {0:hh\:mm\:ss}' -f ((Get-Date) - $wipeStart)
}.GetNewClosure())
$elapsedTimer.Start()

$wipeResults = @()
$diskIndex   = 0

foreach ($diskNum in $selectedDisks) {
    $diskIndex++
    $disk   = Assert-TargetDiskSafe -DiskNumber $diskNum -ExpectedIdentity $diskIdentities[$diskNum] -ProtectedDiskNumbers $protectedDisks
    $sizeGB = [math]::Round($disk.Size / 1GB, 1)

    $lblCurrent.Text = "Wiping disk ${diskNum}: $($disk.FriendlyName) ($sizeGB GB)..."
    $lblOverall.Text = "Disk $diskIndex of $($selectedDisks.Count)"
    Set-FormSize -Form $dlgProgress
    [System.Windows.Forms.Application]::DoEvents()

    Write-Log "Starting clean all on disk ${diskNum}: $($disk.FriendlyName) ($sizeGB GB)"
    $diskStart = Get-Date

    $dpScript = @"
select disk $diskNum
clean all
exit
"@
    $dpFile = Join-Path $logRoot "zero-overwrite-disk${diskNum}.txt"
    Set-Content -Path $dpFile -Value $dpScript -Encoding Ascii

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'diskpart.exe'
    $psi.Arguments              = "/s `"$dpFile`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $sb      = New-Object System.Text.StringBuilder
    $stream  = $proc.StandardOutput.BaseStream
    $buffer  = New-Object byte[] 4096

    # DiskPart clean all does not supply a reliable percentage or time estimate.
    $pbWipe.Style = 'Marquee'

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
            }
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
        }
        else {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 120
        }
    }
    $proc.WaitForExit()

    $stdErr = ''
    try { $stdErr = $errTask.Result } catch { }
    $output = $sb.ToString()
    $diskElapsed = (Get-Date) - $diskStart

    Write-Log "diskpart output for disk ${diskNum}`:`n$output"
    if ($stdErr.Trim()) { Write-Log "diskpart stderr: $stdErr" }

    $exitCode = $proc.ExitCode
    $passed = ($exitCode -eq 0)
    $state  = if ($passed) { 'OK' } else { 'FAILED' }
    Write-Log ("Disk {0} clean all: {1} (exit {2}, {3:hh\:mm\:ss})" -f $diskNum, $state, $proc.ExitCode, $diskElapsed)

    $proc.Dispose()
    $pbWipe.Style = 'Continuous'
    $pbWipe.Value = [math]::Min($pbWipe.Maximum, $diskIndex * 100)

    $wipeResults += [pscustomobject]@{
        DiskNumber = $diskNum
        Name       = $disk.FriendlyName
        SizeGB     = $sizeGB
        State      = $state
        ExitCode   = $exitCode
        Elapsed    = $diskElapsed
    }
}

$elapsedTimer.Stop()
$elapsedTimer.Dispose()
$totalElapsed = (Get-Date) - $wipeStart
$dlgProgress.Visible = $false

# ── Results ──────────────────────────────────────────────────────────

$allPassed  = ($wipeResults | Where-Object State -ne 'OK').Count -eq 0
$resultText = if ($allPassed) { 'Complete' } else { 'Complete (with errors)' }

Write-Log ''
Write-Log '============================================================'
Write-Log "  Logical Zero Overwrite $resultText"
Write-Log '============================================================'
Write-Log "  Service tag  : $Serial"
Write-Log "  Duration     : $('{0:hh\:mm\:ss}' -f $totalElapsed)"
Write-Log ''
Write-Log ('{0,-8} {1,-30} {2,-10} {3,-10} {4}' -f 'Disk', 'Name', 'Size', 'Result', 'Duration')
Write-Log ('{0,-8} {1,-30} {2,-10} {3,-10} {4}' -f '----', '----', '----', '------', '--------')
foreach ($r in $wipeResults) {
    Write-Log ('{0,-8} {1,-30} {2,-10} {3,-10} {4:mm\:ss}' -f
        $r.DiskNumber, $r.Name, "$($r.SizeGB) GB", $r.State, $r.Elapsed)
}
Write-Log ''
Save-WipeLog

$summaryLines = @()
foreach ($r in $wipeResults) {
    $icon = if ($r.State -eq 'OK') { 'OK' } else { 'FAILED' }
    $summaryLines += "    Disk $($r.DiskNumber): $($r.Name) ($($r.SizeGB) GB) - $icon $('{0:hh\:mm\:ss}' -f $r.Elapsed)"
}

$dlgResult = New-WipeForm -Title " $resultText" -Width 560

$lblResultTitle             = New-Object System.Windows.Forms.Label
$lblResultTitle.Text        = "KillDisk | $resultText"
$lblResultTitle.Font        = UiFont 12 -Bold
$lblResultTitle.AutoSize    = $true
$lblResultTitle.MaximumSize = New-Object System.Drawing.Size(508, 0)
if (-not $allPassed) { $lblResultTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38) }
$dlgResult.Tag.Controls.Add($lblResultTitle)

$lblSummary             = New-Object System.Windows.Forms.Label
$lblSummary.Text        = $summaryLines -join "`r`n"
$lblSummary.AutoSize    = $true
$lblSummary.MaximumSize = New-Object System.Drawing.Size(508, 0)
$lblSummary.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
$dlgResult.Tag.Controls.Add($lblSummary)

$lblSanit             = New-Object System.Windows.Forms.Label
$lblSanit.Text        = "Service tag: $Serial`r`nDuration: $('{0:hh\:mm\:ss}' -f $totalElapsed)`r`nResults reflect DiskPart exit status, not verified SSD/NVMe sanitization."
$lblSanit.AutoSize    = $true
$lblSanit.MaximumSize = New-Object System.Drawing.Size(508, 0)
$lblSanit.ForeColor   = [System.Drawing.Color]::FromArgb(100, 100, 100)
$dlgResult.Tag.Controls.Add($lblSanit)

$btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
$btnPanel.FlowDirection = 'RightToLeft'
$btnPanel.AutoSize      = $true
$btnPanel.Width         = 508
$btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

$btnShutdown             = New-Object System.Windows.Forms.Button
$btnShutdown.Text        = 'Shut Down'
$btnShutdown.AutoSize    = $true
$btnShutdown.MinimumSize = New-Object System.Drawing.Size(120, 32)
$btnShutdown.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
Set-PrimaryButtonStyle -Button $btnShutdown
$btnPanel.Controls.Add($btnShutdown)
$dlgResult.Tag.Controls.Add($btnPanel)

$resultCloseTimer          = New-Object System.Windows.Forms.Timer
$resultCloseTimer.Interval = 50
$resultCloseTimer.Add_Tick({
    $resultCloseTimer.Stop()
    $dlgResult.DialogResult = [System.Windows.Forms.DialogResult]::OK
}.GetNewClosure())
$btnShutdown.Add_Click({
    $resultCloseTimer.Start()
}.GetNewClosure())

Set-FormSize -Form $dlgResult
[void]$dlgResult.ShowDialog()
$resultCloseTimer.Dispose()
$dlgResult.Dispose()

Write-Log 'User clicked Shut Down. Powering off.'
Save-WipeLog
& wpeutil.exe shutdown
exit 0
}
catch {
    Write-Log "Wipe stopped: $($_.Exception.Message)" 'ERROR'
    Save-WipeLog
    [void][Win32Console]::ShowWindow([Win32Console]::GetConsoleWindow(), 5)
    [void][System.Windows.Forms.MessageBox]::Show(
        "Wipe stopped: $($_.Exception.Message)`r`nReview $script:LogFile before restarting. Previously completed disks may already be erased.",
        'KillDisk stopped', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}