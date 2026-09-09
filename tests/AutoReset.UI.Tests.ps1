# These tests display harmless forms only; they never import a deployment entry point.
Describe 'WinPE UI startup fallbacks' {
    BeforeAll {
        $script:UiSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\usb-scripts\autoreset.ui.ps1') -Raw
    }
    It 'treats DPI and visual-style setup as optional' {
        $script:UiSource | Should -Match 'try \{ \[void\]\[AutoReset\.Display\]::SetProcessDPIAware\(\) \} catch \{ \}'
        $script:UiSource | Should -Match 'try \{ \[System\.Windows\.Forms\.Application\]::EnableVisualStyles\(\) \} catch \{ \}'
    }
    It 'falls back to 100 percent scaling when graphics initialization fails' {
        $script:UiSource | Should -Match '(?s)\$graphics = \$null.*?catch \{ \$scale = 1\.0 \}.*?finally \{ if \(\$null -ne \$graphics\)'
    }
    It 'centers forms through the public StartPosition property' {
        $script:UiSource | Should -Match '\$form\.StartPosition\s*=\s*''CenterScreen'''
    }
    It 'never calls protected form-centering methods in <Name>' -ForEach @(
        @{ Name = 'autoreset.ps1' }, @{ Name = 'killdisk.ps1' }, @{ Name = 'autoreset.ui.ps1' }
    ) {
        $path = Join-Path $PSScriptRoot "../usb-scripts/$Name"
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        # These .NET methods are protected: PowerShell cannot call them on a Form.
        $calls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Value -in @('CenterToScreen', 'CenterToParent')
        }, $true))
        $calls.Count | Should -Be 0
    }
    It 'does not repeat optional visual-style initialization in KillDisk' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../usb-scripts/killdisk.ps1') -Raw
        $source | Should -Not -Match '::EnableVisualStyles\('
    }
    It 'records failure locations and stacks in <Name>' -ForEach @(
        @{ Name = 'autoreset.ps1' }, @{ Name = 'killdisk.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../usb-scripts/$Name") -Raw
        $source | Should -Match 'Write-(BootstrapLog|Log) "Location: .*InvocationInfo\.PositionMessage'
        $source | Should -Match 'Write-(BootstrapLog|Log) "Stack: .*ScriptStackTrace'
    }
}

Describe 'WinForms disk layout' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../usb-scripts/autoreset.ui.ps1')
    }
    It 'keeps one-disk rows visible and all content reachable' {
        $form = New-ResetForm -Title 'Layout test' -Width 800 -MinimumHeight 450
        try {
            $form.StartPosition | Should -Be 'CenterScreen'
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
    It 'keeps compact form targets when a smaller width is requested' {
        $form = New-ResetForm -Title 'Compact test' -Width 500
        try {
            $form._TargetWidth | Should -Be 500
            Set-FormSize -Form $form
            $form.ClientSize.Width | Should -BeLessOrEqual ([int](500 * $form._UiScale))
        }
        finally { $form.Dispose() }
    }
}
