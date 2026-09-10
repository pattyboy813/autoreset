BeforeAll {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1'
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join "`n") }
    # Load definitions only; never execute the builder's disk operations.
    $functions = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Parent.Parent -eq $ast
    }, $true)
    . ([scriptblock]::Create(($functions.Extent.Text -join "`n")))
}

Describe 'Destination-side driver archive publication' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work [local]'
        $cache = Join-Path $root 'cache [output]'
        [IO.Directory]::CreateDirectory($work) | Out-Null
        [IO.Directory]::CreateDirectory($cache) | Out-Null
        $source = Join-Path $work 'Drivers [new].7z'
        $destination = Join-Path $cache 'Drivers [old].7z'
        [IO.File]::WriteAllText($source, 'NEW ARCHIVE')
        [IO.File]::WriteAllText($destination, 'OLD ARCHIVE')
        [IO.File]::WriteAllText("$destination.hash", 'old-success-receipt')
        $receipts = Join-Path $cache 'ArtifactHashes'
        $oldHash = Get-CachedFileHash -Path $destination -ReceiptDirectory $receipts
        $receipt = @(Get-ChildItem -LiteralPath $receipts -File)[0].FullName
        $oldReceipt = [IO.File]::ReadAllText($receipt)
    }
    AfterEach {
        @(Get-ChildItem -LiteralPath $cache -Force -Filter '*.tmp').Count | Should -Be 0
        [IO.File]::ReadAllText($source) | Should -Be 'NEW ARCHIVE'
    }
    It 'publishes an initial archive using literal sibling paths' {
        Remove-Item -LiteralPath $destination
        $hash = Publish-DriverArchive -Source $source -Destination $destination
        $hash | Should -Be (Get-FileHash -LiteralPath $source).Hash
        [IO.File]::ReadAllText($destination) | Should -Be 'NEW ARCHIVE'
    }
    It 'replaces an existing archive without cross-volume Move-Item or deleting the cache' {
        Mock Move-Item { throw 'The file exists (cross-volume Move-Item regression).' }
        Mock Remove-Item { throw 'Never delete the existing cache first.' } -ParameterFilter { $LiteralPath -eq $destination }
        $hash = Publish-DriverArchive -Source $source -Destination $destination
        $hash | Should -Be (Get-FileHash -LiteralPath $source).Hash
        [IO.File]::ReadAllText($destination) | Should -Be 'NEW ARCHIVE'
        Should -Invoke Move-Item -Times 0
        Should -Invoke Remove-Item -Times 0 -ParameterFilter { $LiteralPath -eq $destination }
    }
    It 'invalidates same-length same-timestamp metadata after replacement even before receipt refresh' {
        $stamp = (Get-Item -LiteralPath $destination).LastWriteTimeUtc
        [IO.File]::SetLastWriteTimeUtc($source, $stamp)
        $hash = Publish-DriverArchive -Source $source -Destination $destination
        (Get-Item -LiteralPath $destination).LastWriteTimeUtc | Should -Not -Be $stamp
        Get-CachedFileHash -Path $destination -ReceiptDirectory $receipts -TrustMetadata | Should -Be $hash
        $hash | Should -Not -Be $oldHash
    }
    It 'retains source, old cache and receipts on <Failure> failure' -ForEach @(
        @{ Failure = 'copy' }, @{ Failure = 'verification' }, @{ Failure = 'source hash' },
        @{ Failure = 'hash read' }, @{ Failure = 'replacement' }
    ) {
        switch ($Failure) {
            'copy' {
                Mock Copy-Item {
                    [IO.File]::WriteAllText($Destination, 'partial copy')
                    throw 'copy failure'
                }
            }
            'verification' {
                Mock Copy-Item { [IO.File]::WriteAllText($Destination, 'corrupt copy') }
            }
            'hash read' {
                Mock Get-FileHash { throw 'hash read failure' } -ParameterFilter { $LiteralPath -ne $source }
            }
            'source hash' {
                Mock Get-FileHash { throw 'source hash failure' } -ParameterFilter { $LiteralPath -eq $source }
            }
            'replacement' {
                Mock Move-DriverArchiveStage { throw [PlatformNotSupportedException]::new('Replace unavailable') }
            }
        }
        { Publish-DriverArchive -Source $source -Destination $destination } | Should -Throw '*source retained*'
        [IO.File]::ReadAllText($destination) | Should -Be 'OLD ARCHIVE'
        [IO.File]::ReadAllText("$destination.hash") | Should -Be 'old-success-receipt'
        [IO.File]::ReadAllText($receipt) | Should -Be $oldReceipt
    }
    It 'leaves no initial cache or receipt when publication fails' {
        Remove-Item -LiteralPath $destination, "$destination.hash"
        Mock Move-DriverArchiveStage { throw 'rename failed' }
        { Publish-DriverArchive -Source $source -Destination $destination } | Should -Throw '*rename failed*'
        Test-Path -LiteralPath $destination | Should -BeFalse
        Test-Path -LiteralPath "$destination.hash" | Should -BeFalse
    }
    It 'rejects a directory destination without copying into it' {
        Remove-Item -LiteralPath $destination
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        Mock Copy-Item { throw 'Must validate before copying' }
        { Publish-DriverArchive -Source $source -Destination $destination } | Should -Throw '*safe destination*'
        Should -Invoke Copy-Item -Times 0
        @(Get-ChildItem -LiteralPath $destination).Count | Should -Be 0
    }
    It 'rejects a missing destination directory' {
        Mock Copy-Item { throw 'Must validate before copying' }
        { Publish-DriverArchive -Source $source -Destination (Join-Path $cache 'missing/Drivers.7z') } |
            Should -Throw '*safe destination*'
        Should -Invoke Copy-Item -Times 0
    }
    It 'rejects a file masquerading as the destination directory' {
        Mock Copy-Item { throw 'Must validate before copying' }
        { Publish-DriverArchive -Source $source -Destination (Join-Path $destination 'Drivers.7z') } |
            Should -Throw
        Should -Invoke Copy-Item -Times 0
    }
    It 'rejects source and destination aliases' {
        { Publish-DriverArchive -Source $source -Destination $source } | Should -Throw '*safe destination*'
    }
    It 'rejects a symlink at the <Location>' -ForEach @(
        @{ Location = 'destination' }, @{ Location = 'parent' }, @{ Location = 'source' }
    ) {
        $link = Join-Path $root 'link'
        $target = switch ($Location) { 'destination' { $destination }; 'parent' { $cache }; 'source' { $source } }
        try { New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'Symbolic links unavailable on this host'; return }
        $publishSource = if ($Location -eq 'source') { $link } else { $source }
        $publishDestination = if ($Location -eq 'destination') { $link }
            elseif ($Location -eq 'parent') { Join-Path $link 'new.7z' } else { $destination }
        Mock Copy-Item { throw 'Must validate links before copying' }
        { Publish-DriverArchive -Source $publishSource -Destination $publishDestination } | Should -Throw '*Reparse*'
        Should -Invoke Copy-Item -Times 0
        [IO.File]::ReadAllText($destination) | Should -Be 'OLD ARCHIVE'
    }
    It 'refuses to use the same-volume primitive across directories' {
        { Move-DriverArchiveStage -Stage $source -Destination $destination } | Should -Throw '*sibling*'
    }
    It 'checks the destination again immediately before replacement' {
        $link = Join-Path $cache 'linked.7z'
        try { New-Item -ItemType SymbolicLink -Path $link -Target $destination -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'Symbolic links unavailable on this host'; return }
        $stage = Join-Path $cache 'verified.7z'
        [IO.File]::WriteAllText($stage, 'NEW ARCHIVE')
        { Move-DriverArchiveStage -Stage $stage -Destination $link } | Should -Throw '*Reparse*'
        [IO.File]::ReadAllText($stage) | Should -Be 'NEW ARCHIVE'
        [IO.File]::ReadAllText($destination) | Should -Be 'OLD ARCHIVE'
    }
}

Describe 'Driver publication receipt ordering' {
    BeforeEach {
        Mock Start-Step { }
        Mock Write-StepDone { }
        Mock Write-StepSkipped { }
        Mock Write-Aside { }
        Mock Write-BuildLog { }
        $script:RuntimeExtractor = $null
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $WorkDir = Join-Path $root 'work'
        $driverSource = Join-Path $root 'drivers'
        $cache = Join-Path $root 'cache'
        [IO.Directory]::CreateDirectory($driverSource) | Out-Null
        [IO.File]::WriteAllText((Join-Path $driverSource 'driver.inf'), 'AAAA')
        $archive = Invoke-DriverArchive -SourcePath $driverSource -ArchiveDir $cache
        $oldArchiveHash = (Get-FileHash -LiteralPath $archive).Hash
        $oldSuccess = [IO.File]::ReadAllText("$archive.hash")
        $receipt = @(Get-ChildItem -LiteralPath (Join-Path $cache 'ArtifactHashes') -File)[0].FullName
        $oldMetadata = [IO.File]::ReadAllText($receipt)
        [IO.File]::WriteAllText((Join-Path $driverSource 'driver.inf'), 'BBBB')
    }
    AfterEach {
        @(Get-ChildItem -LiteralPath $cache -Recurse -Force -Filter '*.tmp').Count | Should -Be 0
    }
    It 'does not issue success or change cache receipts when copying fails' {
        Mock Copy-Item { throw 'output copy failed' } -ParameterFilter { $LiteralPath -like '*Drivers-*.zip' }
        { Invoke-DriverArchive -SourcePath $driverSource -ArchiveDir $cache -ForceRebuild } | Should -Throw '*output copy failed*'
        (Get-FileHash -LiteralPath $archive).Hash | Should -Be $oldArchiveHash
        [IO.File]::ReadAllText("$archive.hash") | Should -Be $oldSuccess
        [IO.File]::ReadAllText($receipt) | Should -Be $oldMetadata
        @(Get-ChildItem -LiteralPath $WorkDir -Filter '*.zip').Count | Should -Be 1
        Should -Invoke Write-StepDone -Times 1
    }
    It 'retains compressed source and no success receipt on <Failure> failure after replacement' -ForEach @(
        @{ Failure = 'metadata' }, @{ Failure = 'success write' }, @{ Failure = 'success rename' }
    ) {
        switch ($Failure) {
            'metadata' { Mock Get-CachedFileHash { throw 'metadata failed' } -ParameterFilter { $VerifiedHash } }
            'success write' {
                Mock Set-Content { throw 'receipt write failed' } -ParameterFilter { $LiteralPath -like '*.driver-hash-*.tmp' }
            }
            'success rename' {
                Mock Move-DriverArchiveStage { throw 'receipt rename failed' } -ParameterFilter { $Destination -like '*.hash' }
            }
        }
        { Invoke-DriverArchive -SourcePath $driverSource -ArchiveDir $cache -ForceRebuild } | Should -Throw '*failed*'
        (Get-FileHash -LiteralPath $archive).Hash | Should -Not -Be $oldArchiveHash
        Test-Path -LiteralPath "$archive.hash" | Should -BeFalse
        @(Get-ChildItem -LiteralPath $WorkDir -Filter '*.zip').Count | Should -Be 1
        Should -Invoke Write-StepDone -Times 1
    }
    It 'refreshes metadata from the verified copy without rereading the destination' {
        Mock Get-FileHash { throw 'Do not reread the published archive' } -ParameterFilter { $LiteralPath -eq $archive }
        $null = Invoke-DriverArchive -SourcePath $driverSource -ArchiveDir $cache -ForceRebuild
        $metadata = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        [IO.File]::ReadAllText("$archive.hash").Trim().Split('|')[-1] | Should -Be $metadata.Hash
        $metadata.Hash | Should -Not -Be $oldArchiveHash
        Get-CachedFileHash -Path $archive -ReceiptDirectory (Join-Path $cache 'ArtifactHashes') -TrustMetadata |
            Should -Be $metadata.Hash
        Should -Invoke Get-FileHash -Times 0 -ParameterFilter { $LiteralPath -eq $archive }
        @(Get-ChildItem -LiteralPath $WorkDir -Filter '*.zip').Count | Should -Be 0
    }
}
