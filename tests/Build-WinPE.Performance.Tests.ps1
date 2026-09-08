BeforeAll {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1'
    $errors = $null
    $script:BuilderAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join "`n") }
    # Load definitions only: a performance test must never build or erase a USB.
    $functions = $script:BuilderAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Parent.Parent -eq $script:BuilderAst
    }, $true)
    . ([scriptblock]::Create(($functions.Extent.Text -join "`n")))

    function New-ManifestEntry {
        param([string]$Source, [string]$Relative)
        [pscustomobject]@{
            SourcePath = $Source
            RelativePath = $Relative
            Length = (Get-Item -LiteralPath $Source).Length
        }
    }
}

Describe 'Independent serviced and customized WinPE caches' {
    BeforeEach {
        $base = @('source:wim-a', 'packages:cabs-a', 'drivers:storage-a', 'recipe:base-v1')
        $runtime = @('scripts:ui-a', 'config:config-a', 'tools:tools-a', 'display:auto', 'recipe:runtime-v1')
        $cache = Join-Path $TestDrive 'cache'
    }
    It 'reuses both keys for identical inputs' {
        $first = Get-WinPECachePlan -CacheDirectory $cache -BaseParts $base -RuntimeParts $runtime
        $second = Get-WinPECachePlan -CacheDirectory $cache -BaseParts $base -RuntimeParts $runtime
        $first.BaseKey | Should -Be $second.BaseKey
        $first.FinalKey | Should -Be $second.FinalKey
        $first.BasePath | Should -Not -Be $first.FinalPath
        $first.BasePath | Should -BeLike "$cache*"
        $first.FinalPath | Should -BeLike "$cache*"
    }
    It 'keeps serviced packages when <Input> changes' -ForEach @(
        @{ Input = 'script'; Change = 'scripts:ui-b' }
        @{ Input = 'configuration'; Change = 'config:config-b' }
        @{ Input = 'tools'; Change = 'tools:tools-b' }
        @{ Input = 'display'; Change = 'display:1280x720' }
        @{ Input = 'runtime recipe'; Change = 'recipe:runtime-v2' }
    ) {
        $first = Get-WinPECachePlan -CacheDirectory $cache -BaseParts $base -RuntimeParts $runtime
        $second = Get-WinPECachePlan -CacheDirectory $cache -BaseParts $base -RuntimeParts ($runtime + $Change)
        $first.BaseKey | Should -Be $second.BaseKey
        $first.FinalKey | Should -Not -Be $second.FinalKey
    }
    It 'invalidates both layers when <Input> changes' -ForEach @(
        @{ Input = 'ADK image'; Change = 'source:wim-b' }
        @{ Input = 'optional packages'; Change = 'packages:cabs-b' }
        @{ Input = 'boot drivers'; Change = 'drivers:storage-b' }
        @{ Input = 'servicing recipe'; Change = 'recipe:base-v2' }
    ) {
        $first = Get-WinPECachePlan -CacheDirectory $cache -BaseParts $base -RuntimeParts $runtime
        $second = Get-WinPECachePlan -CacheDirectory $cache -BaseParts ($base + $Change) -RuntimeParts $runtime
        $first.BaseKey | Should -Not -Be $second.BaseKey
        $first.FinalKey | Should -Not -Be $second.FinalKey
    }
    It 'does not confuse delimiter characters with part boundaries' {
        $first = Get-WinPECachePlan -CacheDirectory $cache -BaseParts @('a;b', 'c') -RuntimeParts $runtime
        $second = Get-WinPECachePlan -CacheDirectory $cache -BaseParts @('a', 'b;c') -RuntimeParts $runtime
        $first.BaseKey | Should -Not -Be $second.BaseKey
    }
}

Describe 'Content-aware direct media copying' {
    BeforeEach {
        Mock Write-BuildLog { }
        Mock Start-Step { }
        Mock Update-StepDisplay { }
        Mock Write-StepDone { }
        $source = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '-source')
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '-payload')
        New-Item -ItemType Directory -Path $source, $destination | Out-Null
        $image = Join-Path $source 'install.wim'
        [IO.File]::WriteAllText($image, 'image-a')
        $entries = @(New-ManifestEntry -Source $image -Relative 'Images/install.wim')
    }
    It 'copies source assets directly without creating an intermediate payload image' {
        $null = Sync-BuildFiles -Files $entries -Destination $destination -Mirror -PreserveDirectories @('Logs')
        [IO.File]::ReadAllText((Join-Path $destination 'Images/install.wim')) | Should -Be 'image-a'
        @(Get-ChildItem -LiteralPath $source -Recurse -File).Count | Should -Be 1
    }
    It 'performs no file writes on an unchanged refresh' {
        $null = Sync-BuildFiles -Files $entries -Destination $destination -Mirror -PreserveDirectories @('Logs')
        Mock Copy-Item { throw 'An unchanged file should not be copied.' }
        $null = Sync-BuildFiles -Files $entries -Destination $destination -Mirror -PreserveDirectories @('Logs')
        Should -Invoke Copy-Item -Times 0
    }
    It 'does not rewrite byte-identical files just because timestamps differ' {
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        (Get-Item -LiteralPath (Join-Path $destination 'Images/install.wim')).LastWriteTimeUtc = [datetime]'2020-01-01Z'
        Mock Copy-Item { throw 'Timestamp differences alone do not justify a write.' }
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        Should -Invoke Copy-Item -Times 0
    }
    It 'replaces changed bytes with the same length and timestamp' {
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        $stamp = (Get-Item -LiteralPath $image).LastWriteTimeUtc
        [IO.File]::WriteAllText($image, 'image-b')
        (Get-Item -LiteralPath $image).LastWriteTimeUtc = $stamp
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        [IO.File]::ReadAllText((Join-Path $destination 'Images/install.wim')) | Should -Be 'image-b'
    }
    It 'repairs a corrupted destination even when sources did not change' {
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        [IO.File]::WriteAllText((Join-Path $destination 'Images/install.wim'), 'corrupt')
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        [IO.File]::ReadAllText((Join-Path $destination 'Images/install.wim')) | Should -Be 'image-a'
    }
    It 'removes obsolete payload files but preserves logs and source files' {
        New-Item -ItemType Directory -Path (Join-Path $destination 'Drivers/OldModel'), (Join-Path $destination 'Logs/nested') | Out-Null
        [IO.File]::WriteAllText((Join-Path $destination 'Drivers/OldModel/Drivers.7z'), 'obsolete')
        [IO.File]::WriteAllText((Join-Path $destination 'Logs/nested/device.log'), 'keep this')
        $null = Sync-BuildFiles -Files $entries -Destination $destination -Mirror -PreserveDirectories @('Logs')
        Test-Path -LiteralPath (Join-Path $destination 'Drivers/OldModel/Drivers.7z') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $destination 'Logs/nested/device.log')) | Should -Be 'keep this'
        [IO.File]::ReadAllText($image) | Should -Be 'image-a'
    }
    It 'does not purge unrelated boot files when mirroring is disabled' {
        $keep = Join-Path $destination 'other-boot-file'
        [IO.File]::WriteAllText($keep, 'keep')
        $null = Sync-BuildFiles -Files $entries -Destination $destination
        Test-Path -LiteralPath $keep | Should -BeTrue
    }
    It 'rejects unsafe relative path <Relative> before copying' -ForEach @(
        @{ Relative = '../outside.wim' }
        @{ Relative = '..\outside.wim' }
        @{ Relative = 'Images/../../outside.wim' }
        @{ Relative = '/rooted.wim' }
        @{ Relative = '\rooted.wim' }
        @{ Relative = 'C:\rooted.wim' }
        @{ Relative = 'Images/file:stream' }
        @{ Relative = 'Images//install.wim' }
    ) {
        $invalid = New-ManifestEntry -Source $image -Relative $Relative
        Mock Copy-Item { throw 'No copies are allowed for invalid manifests.' }
        { Sync-BuildFiles -Files @($entries[0], $invalid) -Destination $destination -Mirror } | Should -Throw
        Should -Invoke Copy-Item -Times 0
    }
    It 'validates every source before changing any destination file' {
        $missing = [pscustomobject]@{ SourcePath = (Join-Path $source 'missing.zip'); RelativePath = 'Drivers/missing.zip'; Length = 42 }
        Mock Copy-Item { throw 'No writes before the full manifest is validated.' }
        { Sync-BuildFiles -Files @($entries[0], $missing) -Destination $destination -Mirror } | Should -Throw
        Should -Invoke Copy-Item -Times 0
    }
    It 'refuses an asset that grew after the capacity inventory was created' {
        [IO.File]::WriteAllText($image, 'image that now exceeds the inventoried length')
        Mock Copy-Item { throw 'Do not copy files whose capacity reservation is stale.' }
        { Sync-BuildFiles -Files $entries -Destination $destination -Mirror } | Should -Throw
        Should -Invoke Copy-Item -Times 0
    }
    It 'rejects case-insensitive duplicate destinations' {
        $duplicate = New-ManifestEntry -Source $image -Relative 'images/INSTALL.WIM'
        { Sync-BuildFiles -Files @($entries[0], $duplicate) -Destination $destination -Mirror } | Should -Throw
        Test-Path -LiteralPath (Join-Path $destination 'Images/install.wim') | Should -BeFalse
    }
    It 'rejects a file that is also the parent directory of another file' {
        $parentFile = New-ManifestEntry -Source $image -Relative 'Images'
        { Sync-BuildFiles -Files @($entries[0], $parentFile) -Destination $destination -Mirror } | Should -Throw
    }
    It 'detects an existing parent-file conflict before copying earlier entries' {
        [IO.File]::WriteAllText((Join-Path $destination 'Drivers'), 'unexpected file')
        $conflict = New-ManifestEntry -Source $image -Relative 'Drivers/Model/Drivers.zip'
        Mock Copy-Item { throw 'Validate destination types before writes.' }
        { Sync-BuildFiles -Files @($entries[0], $conflict) -Destination $destination -Mirror } | Should -Throw
        Should -Invoke Copy-Item -Times 0
    }
    It 'rejects sources inside the destination to prevent self-copy and purge' {
        $nested = Join-Path $destination 'nested.wim'
        [IO.File]::WriteAllText($nested, 'do not remove')
        $entry = New-ManifestEntry -Source $nested -Relative 'Images/install.wim'
        { Sync-BuildFiles -Files @($entry) -Destination $destination -Mirror } | Should -Throw
        [IO.File]::ReadAllText($nested) | Should -Be 'do not remove'
    }
    It 'rejects attempts to overwrite preserved logs' {
        $entry = New-ManifestEntry -Source $image -Relative 'Logs/device.log'
        { Sync-BuildFiles -Files @($entry) -Destination $destination -Mirror -PreserveDirectories @('Logs') } | Should -Throw
    }
    It 'rejects mirroring a filesystem root before mutations' {
        Mock New-Item { throw 'Root must not be modified.' }
        Mock Copy-Item { throw 'Root must not be modified.' }
        Mock Remove-Item { throw 'Root must not be modified.' }
        { Sync-BuildFiles -Files $entries -Destination ([IO.Path]::GetPathRoot($TestDrive)) -Mirror } | Should -Throw
        Should -Invoke Copy-Item -Times 0
        Should -Invoke Remove-Item -Times 0
        Should -Invoke New-Item -Times 0
    }
    It 'rejects a junction or symlink in a destination tree' {
        $outside = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '-outside')
        New-Item -ItemType Directory -Path $outside | Out-Null
        try { New-Item -ItemType SymbolicLink -Path (Join-Path $destination 'Images') -Target $outside -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'This host cannot create test symbolic links.'; return }
        { Sync-BuildFiles -Files $entries -Destination $destination -Mirror } | Should -Throw
        @(Get-ChildItem -LiteralPath $outside).Count | Should -Be 0
    }
    It 'includes real source paths in media inventories' {
        $inventory = @(Get-MediaFileInventory -Root $source)
        $inventory.Count | Should -Be 1
        $inventory[0].SourcePath | Should -Be $image
        $inventory[0].RelativePath | Should -Be 'install.wim'
        $inventory[0].Length | Should -Be 7
    }
}
