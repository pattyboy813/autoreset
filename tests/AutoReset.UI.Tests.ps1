# These tests display harmless forms only; they never import a deployment entry point.
Describe 'WinForms disk layout' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../usb-scripts/autoreset.ui.ps1')
    }
    It 'keeps one-disk rows visible and all content reachable' {
        $form = New-ResetForm -Title 'Layout test' -Width 800 -MinimumHeight 450
        try {
            $label = New-Object System.Windows.Forms.Label
            $label.AutoSize = $true
            $label.Text = ('A long safety warning with a model name. ' * 20)
            $form.Tag.Controls.Add($label)
            $list = New-Object System.Windows.Forms.ListView
            $list.View = 'Details'
            [void]$list.Columns.Add('Disk', 50)
            [void]$list.Columns.Add('Name', 400)
            [void]$list.Items.Add('0')
            Initialize-DiskList -List $list -RowCount 1
            $form.Tag.Controls.Add($list)
            Set-FormSize -Form $form
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $list.Height | Should -BeGreaterThan (6 * $list.Font.Height)
            $list.Right | Should -BeLessOrEqual ($form.Tag.Width - $form.Tag.Padding.Right)
            $form.AutoScroll | Should -BeTrue
            $form.Tag.Height | Should -BeGreaterOrEqual ($list.Bottom + $form.Tag.Padding.Bottom)
            $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $form.Width | Should -BeLessOrEqual $area.Width
            $form.Height | Should -BeLessOrEqual $area.Height
        }
        finally { $form.Dispose() }
    }
    It 'reserves hidden progress controls without repeated DPI growth' {
        $form = New-ResetForm -Title 'Progress test'
        try {
            $progress = New-Object System.Windows.Forms.ProgressBar
            $progress.Height = 24
            $progress.Visible = $false
            $form.Tag.Controls.Add($progress)
            Set-FormSize -Form $form
            $height = $progress.Height
            $form.Show()
            $progress.Visible = $true
            1..5 | ForEach-Object { Set-FormSize -Form $form }
            $progress.Height | Should -Be $height
            $form.Tag.Height | Should -BeGreaterOrEqual ($progress.Bottom + $form.Tag.Padding.Bottom)
        }
        finally { $form.Dispose() }
    }
}
