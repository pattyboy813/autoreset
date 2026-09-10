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
    It 'uses a splash-only compact minimum while retaining content-aware sizing' {
        $path = Join-Path $PSScriptRoot '../usb-scripts/autoreset.ps1'
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        $assignment = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$splashForm'
        }, $true))
        $assignment.Count | Should -Be 1
        $assignment[0].Right.Extent.Text | Should -Be "New-BaseForm -TitleSuffix 'Preparing...' -Width 480 -MinimumHeight 80"
        $source = [IO.File]::ReadAllText($path)
        $source | Should -Match '(?s)Set-FormSize -Form \$splashForm.*?\$splashForm\.Show\(\)'
        $source | Should -Match '\[int\]\$MinimumHeight = 260'
        $script:UiSource | Should -Match '\[int\]\$MinimumHeight = 260'
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
        if ($Name -eq 'autoreset.ps1') {
            $source | Should -Match '"Position: .*InvocationInfo\.PositionMessage'
            $source | Should -Match '"ScriptStackTrace: .*ScriptStackTrace'
            $source | Should -Match '\[Console\]::Error\.WriteLine\(\$failureDetails\)'
        }
        else {
            $source | Should -Match 'Write-Log "Location: .*InvocationInfo\.PositionMessage'
            $source | Should -Match 'Write-Log "Stack: .*ScriptStackTrace'
        }
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
    It 'fits the actual text-only splash in compact bounds without cropping' {
        $path = Join-Path $PSScriptRoot '../usb-scripts/autoreset.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $helpers = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Title', 'New-BaseForm')
        }, $true)
        . ([scriptblock]::Create(($helpers.Extent.Text -join "`n")))
        # Extract only form construction and layout; never run deployment entrypoints.
        $statements = @($ast.EndBlock.Statements)
        $start = 0
        while ($statements[$start].Extent.Text -notlike '$splashForm =*') { $start++ }
        $end = $start
        while ($statements[$end].Extent.Text -ne 'Set-FormSize -Form $splashForm') { $end++ }
        $splashForm = $null
        try {
            . ([scriptblock]::Create(($statements[$start..$end].Extent.Text -join "`n")))
            $splashForm.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $splashForm.Tag.Controls.Count | Should -Be 1
            $label = $splashForm.Tag.Controls[0]
            $label | Should -BeOfType ([System.Windows.Forms.Label])
            $label.Text | Should -Be 'Preparing AutoReset and gathering info...'
            $splashForm.ClientSize.Height | Should -BeLessThan (260 * $splashForm._UiScale)
            $splashForm.ClientSize.Height | Should -BeGreaterOrEqual $splashForm.Tag.Height
            $preferred = $label.GetPreferredSize((New-Object System.Drawing.Size($label.Width, 0)))
            $label.Height | Should -BeGreaterOrEqual $preferred.Height
            $label.Right | Should -BeLessOrEqual ($splashForm.Tag.Width - $splashForm.Tag.Padding.Right)
            $label.Bottom | Should -BeLessOrEqual ($splashForm.Tag.Height - $splashForm.Tag.Padding.Bottom)
            $viewport = $splashForm.RectangleToScreen($splashForm.ClientRectangle)
            $labelBounds = $splashForm.Tag.RectangleToScreen($label.Bounds)
            $viewport.Contains($labelBounds) | Should -BeTrue
        }
        finally { if ($null -ne $splashForm) { $splashForm.Dispose() } }
    }
}
