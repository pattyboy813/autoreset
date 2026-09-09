<#
.SYNOPSIS
    Shared, screen-bounded WinForms layout for both WinPE applications.
.DESCRIPTION
    Dialog dimensions are logical pixels. Font sizes remain points. A single
    system-DPI scale converts control geometry; no second Font autoscaling runs.
    A scrollable viewport keeps large warnings and button rows accessible.
    Run tests/AutoReset.UI.Tests.ps1 with Pester on Windows. Before deploying to
    real disks, also check WinPE at 1024x768, 1366x768 and 1920x1200, 100/150/200%
    scaling, one/many disks, long model names, keyboard navigation and scrolling.
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('AutoReset.Display' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace AutoReset {
    public static class Display {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
'@
}
[void][AutoReset.Display]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

function UiFont {
    param([double]$Size, [switch]$Bold)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font('Segoe UI', [single]$Size, $style)
}

function New-ResetForm {
    param(
        [Parameter(Mandatory)][string]$Title,
        [int]$Width = 720,
        [int]$MinimumHeight = 260
    )
    $form = New-Object System.Windows.Forms.Form
    # Fonts use points; geometry is scaled once below, never by two competing systems.
    $form.AutoScaleMode = 'None'
    $form.Font = UiFont 10
    $form.Text = $Title
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.SystemColors]::Window
    $form.AutoScroll = $true
    $form.KeyPreview = $true

    $graphics = $form.CreateGraphics()
    try { $scale = [math]::Max(1.0, $graphics.DpiX / 96.0) }
    finally { $graphics.Dispose() }
    $form | Add-Member -NotePropertyMembers @{
        _UiScale = $scale
        _TargetWidth = [math]::Max(360, $Width)
        _MinimumHeight = $MinimumHeight
        _Sizing = $false
        _LayoutReady = $false
    }
    $content = New-Object System.Windows.Forms.FlowLayoutPanel
    $content.FlowDirection = 'TopDown'
    $content.WrapContents = $false
    $content.AutoSize = $false
    $content.Padding = New-Object System.Windows.Forms.Padding([int](20 * $scale))
    $content.Location = New-Object System.Drawing.Point(0, 0)
    $form.Controls.Add($content)
    $form.Tag = $content
    $form.Add_Resize({
        if ($this._LayoutReady -and -not $this._Sizing) {
            Set-FormSize -Form $this -KeepWindowSize
        }
    })
    $form.Add_Shown({ Set-FormSize -Form $this })
    return $form
}

function Initialize-ControlMetrics {
    param([System.Windows.Forms.Control]$Control, [double]$Scale)
    if (-not $Control.PSObject.Properties['_MetricsScaled']) {
        $Control | Add-Member -NotePropertyName '_MetricsScaled' -NotePropertyValue $true
        $m = $Control.Margin
        $Control.Margin = New-Object System.Windows.Forms.Padding(
            [int]($m.Left * $Scale), [int]($m.Top * $Scale),
            [int]($m.Right * $Scale), [int]($m.Bottom * $Scale))
        $p = $Control.Padding
        $Control.Padding = New-Object System.Windows.Forms.Padding(
            [int]($p.Left * $Scale), [int]($p.Top * $Scale),
            [int]($p.Right * $Scale), [int]($p.Bottom * $Scale))
        $Control.MinimumSize = New-Object System.Drawing.Size(
            [int]($Control.MinimumSize.Width * $Scale), [int]($Control.MinimumSize.Height * $Scale))
        if (-not $Control.AutoSize -and $Control -isnot [System.Windows.Forms.ListView]) {
            $Control.Size = New-Object System.Drawing.Size(
                [int]($Control.Width * $Scale), [int]($Control.Height * $Scale))
        }
    }
    foreach ($child in $Control.Controls) { Initialize-ControlMetrics -Control $child -Scale $Scale }
}

function Initialize-DiskList {
    param([Parameter(Mandatory)][System.Windows.Forms.ListView]$List, [int]$RowCount)
    if (-not $List.PSObject.Properties['_RowCount']) { $List.Font = UiFont 10 }
    $List | Add-Member -NotePropertyName '_RowCount' -NotePropertyValue $RowCount -Force
    $graphics = $List.CreateGraphics()
    try {
        $scale = [math]::Max(1.0, $graphics.DpiX / 96.0)
        $rowHeight = [System.Windows.Forms.TextRenderer]::MeasureText(
            $graphics, 'Ag', $List.Font).Height + [int](6 * $scale)
    }
    finally { $graphics.Dispose() }
    # Reserve several rows even for one disk, including the header, borders and scrollbar.
    $height = ([math]::Max(6, [math]::Min(10, $RowCount)) + 1) * $rowHeight +
        [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight +
        2 * [System.Windows.Forms.SystemInformation]::Border3DSize.Height
    $List.MinimumSize = New-Object System.Drawing.Size(0, [int]$height)
    $List.Height = [int]$height
    $List.HideSelection = $false
}

function Set-FormSize {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Form,
        [switch]$KeepWindowSize
    )
    if ($Form._Sizing) { return }
    $Form._Sizing = $true
    try {
        $scale = $Form._UiScale
        $area = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
        $frame = $Form.Size - $Form.ClientSize
        $maxWidth = [int]([math]::Floor($area.Width * 0.95) - $frame.Width)
        $maxHeight = [int]([math]::Floor($area.Height * 0.95) - $frame.Height)
        $width = [int][math]::Min($maxWidth, $Form._TargetWidth * $scale)
        if ($KeepWindowSize) { $width = [math]::Min($maxWidth, $Form.ClientSize.Width) }
        $content = $Form.Tag
        # Keep a scrollbar gutter even when it is not needed, avoiding width/height feedback loops.
        $content.Width = $width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        $height = $content.Padding.Vertical
        $content.SuspendLayout()
        try {
            foreach ($control in $content.Controls) {
                Initialize-ControlMetrics -Control $control -Scale $scale
                $innerWidth = [math]::Max(1, $content.Width - $content.Padding.Horizontal - $control.Margin.Horizontal)
                $control.MinimumSize = New-Object System.Drawing.Size(0, 0)
                $control.MaximumSize = New-Object System.Drawing.Size($innerWidth, 0)
                $control.Width = $innerWidth
                if ($control -is [System.Windows.Forms.ListView]) {
                    Initialize-DiskList -List $control -RowCount $control._RowCount
                    if (-not $control.PSObject.Properties['_ColumnWidths']) {
                        $control | Add-Member -NotePropertyName '_ColumnWidths' -NotePropertyValue @($control.Columns | ForEach-Object { $_.Width })
                    }
                    $total = ($control._ColumnWidths | Measure-Object -Sum).Sum
                    $available = $innerWidth - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth -
                        2 * [System.Windows.Forms.SystemInformation]::Border3DSize.Width - 4
                    for ($i = 0; $i -lt $control.Columns.Count; $i++) {
                        $control.Columns[$i].Width = [math]::Max(
                            [int](45 * $scale), [int][math]::Floor($available * $control._ColumnWidths[$i] / $total))
                    }
                }
                elseif ($control.AutoSize) {
                    if ($control -is [System.Windows.Forms.FlowLayoutPanel]) {
                        $control.AutoSizeMode = 'GrowAndShrink'
                    }
                    $control.MinimumSize = New-Object System.Drawing.Size($innerWidth, 0)
                    $control.PerformLayout()
                    $control.Height = $control.GetPreferredSize(
                        (New-Object System.Drawing.Size($innerWidth, 0))).Height
                }
                # Also reserve hidden progress controls so revealing them never clips the window.
                $height += $control.Height + $control.Margin.Vertical
            }
            $content.Height = $height
        }
        finally { $content.ResumeLayout($true) }
        $minimumWidth = [int][math]::Min($maxWidth, [math]::Max(360 * $scale, [math]::Min($width, 640 * $scale)))
        $minimumHeight = [int][math]::Min($maxHeight, $Form._MinimumHeight * $scale)
        $Form.MinimumSize = New-Object System.Drawing.Size(
            ($minimumWidth + $frame.Width), ($minimumHeight + $frame.Height))
        $finalHeight = [math]::Min($maxHeight, [math]::Max($minimumHeight, $height))
        if ($KeepWindowSize) { $finalHeight = [math]::Min($maxHeight, $Form.ClientSize.Height) }
        $Form.ClientSize = New-Object System.Drawing.Size($width, $finalHeight)
        $Form.AutoScrollMinSize = New-Object System.Drawing.Size(0, $height)
        $Form._LayoutReady = $true
    }
    finally { $Form._Sizing = $false }
}
