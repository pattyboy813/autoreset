param(
    [string]$Serial = 'Unknown'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

# ── UI helpers ───────────────────────────────────────────────────────

function UiFont {
    param([double]$Size, [switch]$Bold)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font('Segoe UI', [single]$Size, $style)
}

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

# Pat - Dynamic form factory ----------------------------------------
#   Form is NOT auto-sized. FLP is NOT docked.
#   Caller adds controls to $f.Tag (the FLP), then calls
#   Set-FormSize -Form $f before ShowDialog().
#   This avoids the Dock+AutoSize layout bug entirely.
#--------------------------------------------------------------------
function New-WipeForm {
    param([string]$Title, [int]$Width = 540)
    $f                 = New-Object System.Windows.Forms.Form
    $f.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::Font
    $f.Font            = UiFont 10
    $f.Text            = "KillDisk | $Title"
    $f.StartPosition   = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox     = $false
    $f.MinimizeBox     = $false
    $f.ControlBox      = $false
    $f.TopMost         = $true
    $f.BackColor       = [System.Drawing.SystemColors]::Window
    $f.AutoSize        = $false

    $flp               = New-Object System.Windows.Forms.FlowLayoutPanel
    $flp.FlowDirection = 'TopDown'
    $flp.WrapContents  = $false
    $flp.AutoSize      = $true
    $flp.AutoSizeMode  = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flp.Padding       = New-Object System.Windows.Forms.Padding(18, 16, 18, 16)
    $flp.Location      = New-Object System.Drawing.Point(0, 0)
    $f.Controls.Add($flp)
    $f.Tag             = $flp

    $f | Add-Member -NotePropertyName '_TargetWidth' -NotePropertyValue $Width

    Add-FormHotkeys -Form $f
    return $f
}
#--------------------------------------------------------------------

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

# ── Gather disks ─────────────────────────────────────────────────────

$allDisks = @(Get-Disk | Sort-Object Number)
$internalDisks = @($allDisks | Where-Object {
    $_.BusType -notin @('USB', 'iSCSI', 'File Backed Virtual')
})

if ($internalDisks.Count -eq 0) {
    $errDlg = New-WipeForm -Title 'ERROR' -Width 520

    $errLbl             = New-Object System.Windows.Forms.Label
    $errLbl.Text        = 'No internal disks found. Only USB and virtual disks are present.'
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

    $dlgSelect = New-WipeForm -Title 'Select Disk(s)' -Width 560

    $lblTitle             = New-Object System.Windows.Forms.Label
    $lblTitle.Text        = 'KillDisk - Disk Selection'
    $lblTitle.Font        = UiFont 12 -Bold
    $lblTitle.AutoSize    = $true
    $lblTitle.MaximumSize = New-Object System.Drawing.Size(508, 0)
    $dlgSelect.Tag.Controls.Add($lblTitle)

    $lblInstr             = New-Object System.Windows.Forms.Label
    $lblInstr.Text        = 'Select the disk(s) you wish to wipe. Note this process can take a while.'
    $lblInstr.AutoSize    = $true
    $lblInstr.MaximumSize = New-Object System.Drawing.Size(508, 0)
    $lblInstr.Margin      = New-Object System.Windows.Forms.Padding(0, 5, 0, 10)
    $dlgSelect.Tag.Controls.Add($lblInstr)

    # Pat - DPI-aware row height calculation ----------------------------
    $rowHeight    = [System.Windows.Forms.TextRenderer]::MeasureText(
        'X', (UiFont 9)).Height + 4
    $headerHeight = $rowHeight + 4
    $listHeight   = [math]::Max(
        $headerHeight + 22,
        $headerHeight + ($internalDisks.Count * $rowHeight))
    $list.Size        = New-Object System.Drawing.Size(508, $listHeight)
    # Pat - MinimumSize ensures the FLP respects this height during layout
    $list.MinimumSize = New-Object System.Drawing.Size(508, $listHeight)
    #--------------------------------------------------------------------
    $list               = New-Object System.Windows.Forms.ListView
    $list.View          = 'Details'
    $list.CheckBoxes    = $true
    $list.FullRowSelect = $true
    $list.MultiSelect   = $false
    $list.GridLines     = $true
    $list.Size          = New-Object System.Drawing.Size(508, $listHeight)
    $list.MinimumSize   = New-Object System.Drawing.Size(508, $listHeight)
    $list.Font          = UiFont 9
    #------------------------------------------------------------------

    [void]$list.Columns.Add('Disk', 50)
    [void]$list.Columns.Add('Name', 218)
    [void]$list.Columns.Add('Size', 80)
    [void]$list.Columns.Add('Bus', 75)
    [void]$list.Columns.Add('Type', 75)

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
        $item.Checked = $true
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
        $d = Get-Disk -Number $dn
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
        Write-Log 'User confirmed secure wipe by typing WIPE.'
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
    $disk   = Get-Disk -Number $diskNum
    $sizeGB = [math]::Round($disk.Size / 1GB, 1)

    $lblCurrent.Text = "Wiping disk ${diskNum}: $($disk.FriendlyName) ($sizeGB GB)..."
    $lblOverall.Text = "Disk $diskIndex of $($selectedDisks.Count)"
    [System.Windows.Forms.Application]::DoEvents()

    Write-Log "Starting clean all on disk ${diskNum}: $($disk.FriendlyName) ($sizeGB GB)"
    $diskStart = Get-Date

    $dpScript = @"
select disk $diskNum
clean all
exit
"@
    $dpFile = Join-Path $logRoot "securewipe-disk${diskNum}.txt"
    Set-Content -Path $dpFile -Value $dpScript -Encoding Ascii

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'diskpart.exe'
    $psi.Arguments              = "/s $dpFile"
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $sb      = New-Object System.Text.StringBuilder
    $stream  = $proc.StandardOutput.BaseStream
    $buffer  = New-Object byte[] 4096
    $pctRx   = [regex]'(\d{1,3})%'

    $baseProgress = ($diskIndex - 1) * 100

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
                $hits = $pctRx.Matches($chunk)
                if ($hits.Count -gt 0) {
                    $pct = [int]$hits[$hits.Count - 1].Groups[1].Value
                    $lblCurrent.Text = "Wiping disk ${diskNum}: $($disk.FriendlyName) ($sizeGB GB)... ${pct}%"
                    $pbWipe.Value = [math]::Min($pbWipe.Maximum, $baseProgress + $pct)
                }
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

    $passed = ($proc.ExitCode -eq 0)
    $state  = if ($passed) { 'OK' } else { 'FAILED' }
    Write-Log ("Disk {0} clean all: {1} (exit {2}, {3:hh\:mm\:ss})" -f $diskNum, $state, $proc.ExitCode, $diskElapsed)

    $pbWipe.Value = [math]::Min($pbWipe.Maximum, $diskIndex * 100)

    $wipeResults += [pscustomobject]@{
        DiskNumber = $diskNum
        Name       = $disk.FriendlyName
        SizeGB     = $sizeGB
        State      = $state
        ExitCode   = $proc.ExitCode
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
Write-Log "  Secure Wipe $resultText"
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
$lblSanit.Text        = "Service tag: $Serial`r`nDuration: $('{0:hh\:mm\:ss}' -f $totalElapsed)"
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
& wpeutil.exe shutdown
exit 0