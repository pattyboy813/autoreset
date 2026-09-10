BeforeAll {
    $script:BuilderPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1'
    $tokens = $null
    $parseErrors = $null
    $script:BuilderAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:BuilderPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
    $functions = $script:BuilderAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Parent.Parent -eq $script:BuilderAst
    }, $true)
    . ([scriptblock]::Create(($functions.Extent.Text -join "`n")))

    $script:RefreshPolicy = @($script:BuilderAst.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$FastRefresh'
    })
    # Bind only the real parameter block and isolated policy assignment, never the entrypoint.
    $script:BindBuilderParameters = [scriptblock]::Create(
        $script:BuilderAst.ParamBlock.Extent.Text + "`n" +
        ($script:RefreshPolicy.Extent.Text -join "`n") + @'

[pscustomobject]@{
    Mode = $PSCmdlet.ParameterSetName
    Strict = [bool]$StrictVerify
    Fast = $FastRefresh
    Bound = $PSBoundParameters
}
'@)

    # Storage/DISM commands are absent on Linux; never call actual disk operations.
    function Get-Disk { [CmdletBinding()] param($Number) throw 'Unmocked Get-Disk' }
    function Get-Volume { [CmdletBinding()] param($FileSystemLabel) throw 'Unmocked Get-Volume' }
    function Get-Partition { [CmdletBinding()] param($DriveLetter, $FilePath, $DiskNumber, $PartitionNumber) throw 'Unmocked Get-Partition' }
    function Get-WindowsImage { [CmdletBinding()] param([switch]$Mounted) throw 'Unmocked Get-WindowsImage' }
    function Clear-Disk { [CmdletBinding(SupportsShouldProcess)] param($Number, [switch]$RemoveData, [switch]$RemoveOEM) throw 'Unmocked Clear-Disk' }
    function Initialize-Disk { [CmdletBinding()] param($Number, $PartitionStyle) throw 'Unmocked Initialize-Disk' }
    function Set-Disk { [CmdletBinding()] param($Number, $PartitionStyle) throw 'Unmocked Set-Disk' }
    function New-Partition { [CmdletBinding()] param($DiskNumber, $Size, [switch]$IsActive, [switch]$AssignDriveLetter, [switch]$UseMaximumSize) throw 'Unmocked New-Partition' }
    function Format-Volume { [CmdletBinding(SupportsShouldProcess)] param($Partition, $FileSystem, $NewFileSystemLabel) throw 'Unmocked Format-Volume' }
}

Describe 'Builder disk and volume safeguards' {
    BeforeEach {
        $script:Disk = [pscustomobject]@{ Number = [uint32]7; UniqueId = 'usb-7'; SerialNumber = 'serial-7'
            BusType = 'USB'; Size = 32GB; Path = 'disk-path-7'; Location = 'port-7'
            IsBoot = $false; IsSystem = $false; IsReadOnly = $false; IsOffline = $false; PartitionStyle = 'GPT' }
        $script:Boot = [pscustomobject]@{ DriveLetter = 'P'; FileSystemLabel = 'PE'; FileSystem = 'FAT32'; SizeRemaining = 4GB }
        $script:Payload = [pscustomobject]@{ DriveLetter = 'Q'; FileSystemLabel = 'PAYLOAD'; FileSystem = 'NTFS'; SizeRemaining = 20GB }
        Mock Get-Disk { $script:Disk }
        Mock Get-Volume { if ($FileSystemLabel -eq 'PE') { $script:Boot } else { $script:Payload } }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = [uint32]7; PartitionNumber = [uint32]$(if ($DriveLetter -eq 'P') { 1 } else { 2 })
                IsReadOnly = $false; IsBoot = $false; IsSystem = $false }
        }
    }

    It 'accepts one eligible USB disk and its two partitions' {
        (Get-ValidatedUsbVolumes).Disk.Number | Should -Be 7
        $script:Disk.Number | Should -BeOfType ([uint32])
    }
    It 'rejects duplicate <Label> labels' -TestCases @(@{ Label = 'PE' }, @{ Label = 'PAYLOAD' }) {
        param($Label)
        Mock Get-Volume { $script:Boot; $script:Payload } -ParameterFilter { $FileSystemLabel -eq $Label }
        { Get-ValidatedUsbVolumes } | Should -Throw '*exactly one*'
    }
    It 'rejects missing volumes even for boot-only validation' {
        Mock Get-Volume { }
        { Get-ValidatedUsbVolumes } | Should -Throw '*exactly one*'
    }
    It 'rejects labels on different physical disks' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [uint32]8; PartitionNumber = [uint32]2 } } -ParameterFilter { $DriveLetter -eq 'Q' }
        { Get-ValidatedUsbVolumes } | Should -Throw '*same physical*'
    }
    It 'rejects wrong filesystem or missing drive letter' {
        $script:Boot.FileSystem = 'NTFS'
        { Get-ValidatedUsbVolumes } | Should -Throw '*FAT32/NTFS*'
        $script:Boot.FileSystem = 'FAT32'
        $script:Boot.DriveLetter = $null
        { Get-ValidatedUsbVolumes } | Should -Throw '*distinct drive letters*'
    }
    It 'rejects a read-only partition on an otherwise writable disk' {
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = [uint32]7; PartitionNumber = [uint32]2; IsReadOnly = $true; IsBoot = $false; IsSystem = $false }
        } -ParameterFilter { $DriveLetter -eq 'Q' }
        { Get-ValidatedUsbVolumes } | Should -Throw '*writable*'
    }
    It 'accepts partitions when boot/system flags are unavailable but not true' {
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = [uint32]7; PartitionNumber = [uint32]1; IsReadOnly = $false; IsBoot = $null; IsSystem = $null }
        } -ParameterFilter { $DriveLetter -eq 'P' }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = [uint32]7; PartitionNumber = [uint32]2; IsReadOnly = $false; IsBoot = $null; IsSystem = $null }
        } -ParameterFilter { $DriveLetter -eq 'Q' }
        (Get-ValidatedUsbVolumes).Disk.Number | Should -Be 7
    }
    It 'rejects a <Property> disk' -TestCases @(
        @{ Property = 'IsBoot' }, @{ Property = 'IsSystem' }, @{ Property = 'IsReadOnly' }, @{ Property = 'IsOffline' }) {
        param($Property)
        $script:Disk.$Property = $true
        { Get-ValidatedUsbVolumes } | Should -Throw '*boot/system*'
    }
    It 'fails closed when disk safety properties are unknown' {
        $script:Disk.IsReadOnly = $null
        { Assert-BuildDiskSafe -DiskNumber 7 } | Should -Throw '*unknown*'
    }
    It 'protects source, output and workspace disks' {
        { Get-ValidatedUsbVolumes -ProtectedDiskNumbers @(2, 7) } | Should -Throw '*protected*'
        { Assert-BuildDiskSafe -DiskNumber 7 -ProtectedDiskNumbers @(7) -AllowNonUsb } | Should -Throw '*protected*'
    }
    It 'rejects non-USB updates but allows an explicitly eligible fresh non-USB disk' {
        $script:Disk.BusType = 'SATA'
        { Get-ValidatedUsbVolumes } | Should -Throw '*not USB*'
        (Assert-BuildDiskSafe -DiskNumber 7 -AllowNonUsb).Number | Should -Be 7
        $script:Disk.IsSystem = $true
        { Assert-BuildDiskSafe -DiskNumber 7 -AllowNonUsb } | Should -Throw '*boot/system*'
    }
    It 'rejects changed identity before writes' {
        $identity = Get-BuildDiskIdentity -Disk $script:Disk
        $script:Disk.SerialNumber = 'replacement'
        { Assert-BuildDiskSafe -DiskNumber 7 -ExpectedIdentity $identity } | Should -Throw '*identity changed*'
    }
    It 'requires a stable hardware identifier' {
        $script:Disk.UniqueId = ''
        $script:Disk.SerialNumber = ''
        { Assert-BuildDiskSafe -DiskNumber 7 } | Should -Throw '*stable hardware identity*'
    }
    It 'propagates Clear-Disk failure and never partitions afterward' {
        Mock Clear-Disk { throw 'clear failed' }
        Mock New-Partition { }
        $identity = Get-BuildDiskIdentity $script:Disk
        { New-UsbLayout -DiskNumber 7 -ExpectedIdentity $identity -BootPartitionSize 2GB } | Should -Throw '*clear failed*'
        Should -Invoke Clear-Disk -Times 1 -ParameterFilter { $ErrorAction -eq 'Stop' }
        Should -Invoke New-Partition -Times 0
    }
    It 'revalidates identity before Clear-Disk' {
        Mock Clear-Disk { }
        { New-UsbLayout -DiskNumber 7 -ExpectedIdentity 'old-device' -BootPartitionSize 2GB } | Should -Throw '*identity changed*'
        Should -Invoke Clear-Disk -Times 0
    }
    It 'partitions a validated disk using the computed size and rechecks before formatting' {
        $script:PartitionCount = 0
        Mock Clear-Disk { $script:Disk.PartitionStyle = 'RAW' }
        Mock Initialize-Disk { $script:Disk.PartitionStyle = 'MBR' }
        Mock New-Partition {
            $script:PartitionCount++
            [pscustomobject]@{ DiskNumber = [uint32]7; PartitionNumber = [uint32]$script:PartitionCount }
        }
        Mock Format-Volume { }
        $identity = Get-BuildDiskIdentity $script:Disk
        $layout = New-UsbLayout -DiskNumber 7 -ExpectedIdentity $identity -BootPartitionSize 1900MB
        $layout.Boot.PartitionNumber | Should -Be 1
        $layout.Payload.PartitionNumber | Should -Be 2
        Should -Invoke New-Partition -Times 1 -ParameterFilter { $Size -eq 1900MB -and $IsActive }
        Should -Invoke Format-Volume -Times 2
        Should -Invoke Get-Disk -Times 6
    }
    It 'does not erase an already RAW disk but still verifies identity' {
        $script:Disk.PartitionStyle = 'RAW'
        Mock Clear-Disk { throw 'Must not clear a RAW disk' }
        Mock Initialize-Disk { $script:Disk.PartitionStyle = 'MBR' }
        Mock New-Partition { [pscustomobject]@{ DiskNumber = [uint32]7; PartitionNumber = [uint32]1 } }
        Mock Format-Volume { }
        $null = New-UsbLayout -DiskNumber 7 -ExpectedIdentity (Get-BuildDiskIdentity $script:Disk) -BootPartitionSize 1GB
        Should -Invoke Clear-Disk -Times 0
        Should -Invoke Initialize-Disk -Times 1
    }
    It 'refuses copying when a drive letter was reassigned' {
        { Assert-BuildPartitionMapping -DiskNumber 7 -PartitionNumber 1 -DriveLetter P } | Should -Not -Throw
        { Assert-BuildPartitionMapping -DiskNumber 8 -PartitionNumber 1 -DriveLetter P } | Should -Throw '*no longer belongs*'
    }
    It 'maps existing ancestors to protected physical disks' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [uint32]4 } } -ParameterFilter { $null -ne $FilePath }
        @(Get-BuildProtectedDiskNumbers -Paths @((Join-Path $TestDrive 'new/output'), $TestDrive)) | Should -Be @(4)
    }
    It 'fails closed when a source path maps to multiple disks' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [uint32]4 }; [pscustomobject]@{ DiskNumber = [uint32]5 } } -ParameterFilter { $null -ne $FilePath }
        { Get-BuildProtectedDiskNumbers -Paths @($TestDrive) } | Should -Throw '*unambiguously*'
    }
    It 'falls back to drive-letter mapping when Get-Partition lacks FilePath support' {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{ DriveLetter = $true } } } -ParameterFilter { $Name -eq 'Get-Partition' }
        Mock Test-Path { $true }
        Mock Split-Path { 'C:' } -ParameterFilter { $Qualifier }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [uint32]4 } } -ParameterFilter { $DriveLetter -eq 'C' }
        @(Get-BuildProtectedDiskNumbers -Paths @($TestDrive)) | Should -Be @(4)
        Should -Invoke Get-Partition -Times 1 -ParameterFilter { $DriveLetter -eq 'C' }
    }
}

Describe 'USB validation reports failure in its own scope' {
    BeforeEach {
        Mock Write-Host { }
        Mock Get-ValidatedUsbVolumes {
            [pscustomobject]@{
                Boot = [pscustomobject]@{ DriveLetter = 'P'; SizeRemaining = 1GB }
                Payload = [pscustomobject]@{ DriveLetter = 'Q'; SizeRemaining = 10GB }
            }
        }
        Mock Test-Path { $false }
        Mock Join-Path { "$Path/$ChildPath" }
        $LogFile = $null
        $SkipPayload = $true
    }
    It 'throws when nested Report records missing boot files' {
        { Invoke-UsbValidation } | Should -Throw 'USB validation failed.'
    }
    It 'throws when duplicate or unsafe media is discovered' {
        Mock Get-ValidatedUsbVolumes { throw 'duplicate labels' }
        { Invoke-UsbValidation } | Should -Throw 'USB validation failed.'
    }
}

Describe 'Destructive USB mirror ownership' {
    BeforeEach {
        Mock Assert-NoReparsePath { }
        Mock Join-Path { "$TestDrive/marker.tag" }
        $script:Volume = [pscustomobject]@{ DriveLetter = 'Q' }
    }
    It 'refuses a label-only disk without the builder marker' {
        Mock Test-Path { $false }
        { Assert-UsbPayloadOwnership -Volume $script:Volume } | Should -Throw '*not a recognized AutoReset payload*'
    }
    It 'refuses an unrelated payload marker' {
        Mock Test-Path { $true }
        Mock Get-Content { 'Other application data' }
        { Assert-UsbPayloadOwnership -Volume $script:Volume } | Should -Throw '*destructive mirror*'
    }
    It 'accepts the builder-owned payload marker' {
        Mock Test-Path { $true }
        Mock Get-Content { 'AutoReset deployment media' }
        { Assert-UsbPayloadOwnership -Volume $script:Volume } | Should -Not -Throw
    }
}

Describe 'Boot and update capacity' {
    BeforeEach {
        Mock Join-Path { "$Path/$ChildPath" }
    }
    It 'sizes a larger boot partition dynamically' {
        $size = Get-BootPartitionSize -Files @([pscustomobject]@{ Length = 1400MB })
        $size | Should -BeGreaterThan 1400MB
        ($size % 1MB) | Should -Be 0
    }
    It 'rejects a file that cannot fit FAT32' {
        { Get-BootPartitionSize -Files @([pscustomobject]@{ Length = 4GB }) } | Should -Throw '*FAT32 single-file*'
    }
    It 'rejects FAT32 volumes beyond the formatter limit' {
        $files = 1..12 | ForEach-Object { [pscustomobject]@{ Length = 3GB } }
        { Get-BootPartitionSize -Files $files } | Should -Throw '*32 GiB*'
    }
    It 'rejects an update that cannot fit before starting a mirror' {
        Mock Test-Path { $false }
        $boot = [pscustomobject]@{ DriveLetter = 'P'; FileSystemLabel = 'PE'; SizeRemaining = 500MB }
        $payload = [pscustomobject]@{ DriveLetter = 'Q'; FileSystemLabel = 'PAYLOAD'; SizeRemaining = 10GB }
        $files = @([pscustomobject]@{ RelativePath = 'sources/boot.wim'; Length = 900MB })
        { Assert-UpdateCapacity -BootFiles $files -PayloadFiles @() -BootVolume $boot -PayloadVolume $payload } |
            Should -Throw '*Insufficient space on PE*'
    }
    It 'checks payload capacity during updates too' {
        Mock Test-Path { $false }
        $boot = [pscustomobject]@{ DriveLetter = 'P'; FileSystemLabel = 'PE'; SizeRemaining = 2GB }
        $payload = [pscustomobject]@{ DriveLetter = 'Q'; FileSystemLabel = 'PAYLOAD'; SizeRemaining = 1GB }
        $files = @([pscustomobject]@{ RelativePath = 'Images/install.wim'; Length = 5GB })
        { Assert-UpdateCapacity -BootFiles @() -PayloadFiles $files -BootVolume $boot -PayloadVolume $payload } |
            Should -Throw '*Insufficient space on PAYLOAD*'
    }
}

Describe 'Canonical sources and safe payload defaults' {
    BeforeEach {
        $script:Sources = Join-Path $TestDrive 'sources'
        $script:PayloadSource = Join-Path $TestDrive 'kit'
        New-Item -ItemType Directory -Path $script:Sources, $script:PayloadSource, (Join-Path $script:PayloadSource 'tools') -Force | Out-Null
        foreach ($name in @('autoreset.ps1', 'killdisk.ps1', 'autoreset.common.ps1', 'autoreset.ui.ps1')) {
            Set-Content -LiteralPath (Join-Path $script:Sources $name) -Value "# $name"
        }
        Set-Content -LiteralPath (Join-Path $script:PayloadSource 'reset.json') -Value '{"ConfirmBeforeWipe":true}'
    }
    It 'requires the four explicit usb-scripts runtime files' {
        @(Get-RuntimeSourceFiles -Root $script:Sources).Count | Should -Be 4
        Remove-Item -LiteralPath (Join-Path $script:Sources 'autoreset.common.ps1')
        { Get-RuntimeSourceFiles -Root $script:Sources } | Should -Throw '*Required runtime source missing*'
    }
    It 'rejects a missing installation image unless SkipPayload is explicit' {
        $missing = Join-Path $TestDrive 'missing.wim'
        { Assert-BuildPayload -PayloadSource $script:PayloadSource -InstallImage $missing } | Should -Throw '*Installation image missing*'
        { Assert-BuildPayload -PayloadSource $script:PayloadSource -InstallImage $missing -BootOnly } | Should -Not -Throw
    }
    It 'rejects invalid configuration even for boot-only builds' {
        Set-Content -LiteralPath (Join-Path $script:PayloadSource 'reset.json') -Value '{broken'
        { Assert-BuildPayload -PayloadSource $script:PayloadSource -BootOnly } | Should -Throw
    }
    It 'keeps payload-source reparse checks non-recursive during startup preflight' {
        Mock Assert-NoReparsePath { }
        Assert-BuildPayload -PayloadSource $script:PayloadSource -BootOnly
        Should -Invoke Assert-NoReparsePath -Times 1 -ParameterFilter {
            $Path -eq $script:PayloadSource -and -not $Recurse
        }
    }
    It 'mirrors exactly the runtime files and removes obsolete overrides' {
        Mock Invoke-Robocopy { }
        $dest = Join-Path $TestDrive 'destination'
        New-Item -ItemType Directory -Path (Join-Path $dest 'Scripts/obsolete') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'Scripts/stale.ps1') -Value 'old'
        $files = @(Get-RuntimeSourceFiles -Root $script:Sources)
        Sync-RuntimePayload -Destination $dest -RuntimeFiles $files -PayloadSource $script:PayloadSource
        @(Get-ChildItem -LiteralPath (Join-Path $dest 'Scripts')).Count | Should -Be 4
        Test-Path -LiteralPath (Join-Path $dest 'Scripts/stale.ps1') | Should -BeFalse
        Should -Invoke Invoke-Robocopy -Times 1 -ParameterFilter { $Extra -contains '/MIR' }
    }
    It 'bundles Unicode runtime sources with a UTF-8 BOM for Windows PowerShell 5.1' {
        Mock Invoke-Robocopy { }
        $source = Join-Path $script:Sources 'autoreset.ui.ps1'
        $text = '$label = "' + [char]0x2192 + '"'
        [IO.File]::WriteAllText($source, $text, [Text.UTF8Encoding]::new($false))
        $dest = Join-Path $TestDrive 'unicode-bundle'
        Sync-RuntimePayload -Destination $dest -RuntimeFiles @(Get-RuntimeSourceFiles -Root $script:Sources) -PayloadSource $script:PayloadSource
        foreach ($scriptFile in Get-ChildItem -LiteralPath (Join-Path $dest 'Scripts') -File) {
            [byte[]]$bytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
            @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        }
        [IO.File]::ReadAllText((Join-Path $dest 'Scripts/autoreset.ui.ps1')) | Should -Be $text
        [IO.File]::ReadAllBytes($source)[0] | Should -Not -Be 0xEF
    }
    It 'does not duplicate an existing runtime BOM' {
        $source = Join-Path $script:Sources 'autoreset.ui.ps1'
        $dest = Join-Path $TestDrive 'bom-script.ps1'
        [IO.File]::WriteAllText($source, "'hello'", [Text.UTF8Encoding]::new($true))
        Copy-RuntimeScript -Source $source -Destination $dest
        (Get-FileHash -LiteralPath $dest).Hash | Should -Be (Get-FileHash -LiteralPath $source).Hash
    }
    It 'bundles the ADK BIOS deployment tool even without optional payload tools' {
        Mock Invoke-Robocopy { }
        $bootsect = Join-Path $TestDrive 'adk-bootsect.exe'
        [IO.File]::WriteAllText($bootsect, 'ADK tool fixture')
        foreach ($name in @('wim-runtime', 'media-runtime')) {
            $dest = Join-Path $TestDrive $name
            $system32 = $null
            if ($name -eq 'wim-runtime') {
                $system32 = Join-Path $TestDrive 'mounted-image/Windows/System32'
                New-Item -ItemType Directory -Path $system32 -Force | Out-Null
            }
            Sync-RuntimePayload -Destination $dest -RuntimeFiles @(Get-RuntimeSourceFiles -Root $script:Sources) `
                -PayloadSource $script:PayloadSource -BootsectSource $bootsect -System32Path $system32
            (Get-FileHash -LiteralPath (Join-Path $dest 'Tools/bootsect.exe')).Hash | Should -Be (Get-FileHash -LiteralPath $bootsect).Hash
            if ($system32) {
                (Get-FileHash -LiteralPath (Join-Path $system32 'bootsect.exe')).Hash | Should -Be (Get-FileHash -LiteralPath $bootsect).Hash
            }
        }
    }
    It 'ships confirmation-first defaults without a preselected target' {
        $config = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'reset.json') -Raw | ConvertFrom-Json
        $config.ConfirmBeforeWipe | Should -BeTrue
        $config.TargetDiskNumber | Should -BeNullOrEmpty
        $config.ContinueOnDriverError | Should -BeFalse
        $config.DriversRequired | Should -BeFalse
        $editionParameter = $script:BuilderAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Edition' }
        $config.ImageEdition | Should -Be $editionParameter.DefaultValue.SafeGetValue()
        $config.ImageIndex | Should -BeNullOrEmpty
    }
}

Describe 'Content-based cache and archive refresh' {
    BeforeEach {
        Mock Start-Step { }
        Mock Write-StepDone { }
        Mock Write-StepSkipped { }
        Mock Write-Aside { }
        Mock Write-BuildLog { }
        $script:RuntimeExtractor = $null
        $WorkDir = Join-Path $TestDrive 'work'
        $script:DriverSource = Join-Path $TestDrive ('driver-source-' + [guid]::NewGuid().ToString('N'))
        $script:ArchiveDir = Join-Path $TestDrive ('archives-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DriverSource, $script:ArchiveDir -Force | Out-Null
        $script:DriverFile = Join-Path $script:DriverSource 'driver.inf'
        [IO.File]::WriteAllText($script:DriverFile, 'AAAA')
    }
    It 'detects changed bytes even when length and timestamps match' {
        $stamp = (Get-Item -LiteralPath $script:DriverFile).LastWriteTimeUtc
        $first = Get-DriverSourceHash -SourcePath $script:DriverSource
        [IO.File]::WriteAllText($script:DriverFile, 'BBBB')
        (Get-Item -LiteralPath $script:DriverFile).LastWriteTimeUtc = $stamp
        Get-DriverSourceHash -SourcePath $script:DriverSource | Should -Not -Be $first
    }
    It 'hashes relative names as well as content' {
        $first = Get-ContentTreeHash -Path $script:DriverSource
        Rename-Item -LiteralPath $script:DriverFile -NewName 'renamed.inf'
        Get-ContentTreeHash -Path $script:DriverSource | Should -Not -Be $first
    }
    It 'copies same-size replacements using hashes' {
        $dest = Join-Path $TestDrive 'copied.inf'
        [IO.File]::WriteAllText($dest, 'BBBB')
        Copy-ChangedFile -Source $script:DriverFile -Destination $dest
        [IO.File]::ReadAllText($dest) | Should -Be 'AAAA'
    }
    It 'can ignore access-denied copy failures when explicitly requested' {
        $dest = Join-Path $TestDrive 'protected.inf'
        [IO.File]::WriteAllText($dest, 'BBBB')
        Mock Copy-Item { throw ([UnauthorizedAccessException]::new('Access denied')) } -ParameterFilter {
            $LiteralPath -eq $script:DriverFile -and $Destination -eq $dest
        }
        { Copy-ChangedFile -Source $script:DriverFile -Destination $dest -IgnoreAccessDenied } | Should -Not -Throw
        { Copy-ChangedFile -Source $script:DriverFile -Destination $dest } | Should -Throw '*Access denied*'
        Should -Invoke Write-BuildLog -Times 1 -ParameterFilter { $Text -like '*Skipping protected file update*' }
    }
    It 'uses zip without a runtime extractor and excludes old archive formats' {
        [IO.File]::WriteAllText((Join-Path $script:DriverSource 'Drivers.7z'), 'old-source-archive')
        $result = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $result | Should -BeLike '*.zip'
        $zip = [IO.Compression.ZipFile]::OpenRead($result)
        try { @($zip.Entries.FullName) | Should -Be @('driver.inf') }
        finally { $zip.Dispose() }
    }
    It 'removes obsolete formats even when the selected cache is current' {
        $first = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $stale = Join-Path $script:ArchiveDir 'Drivers.7z'
        [IO.File]::WriteAllText($stale, 'stale')
        [IO.File]::WriteAllText("$stale.hash", 'stale')
        Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir | Should -Be $first
        Test-Path -LiteralPath $stale | Should -BeFalse
        Test-Path -LiteralPath "$stale.hash" | Should -BeFalse
    }
    It 'rebuilds corrupted cached archives rather than trusting only a source hash' {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        [IO.File]::WriteAllText($archive, 'broken')
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try { $zip.Entries.Count | Should -Be 1 }
        finally { $zip.Dispose() }
    }
    It 'reuses driver source hash receipts for unchanged files' {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        Test-Path -LiteralPath "$archive.source.json" | Should -BeTrue
        Mock Get-FileHash { throw 'Source hash should be reused from receipt.' } -ParameterFilter {
            $LiteralPath -eq $script:DriverFile
        }
        { Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh } | Should -Not -Throw
        Should -Invoke Get-FileHash -Times 0 -ParameterFilter { $LiteralPath -eq $script:DriverFile }
    }
    It 'creates the archive directory before writing the first source receipt' {
        Remove-Item -LiteralPath $script:ArchiveDir -Recurse -Force
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh -ErrorAction Stop
        Test-Path -LiteralPath "$archive.source.json" | Should -BeTrue
        Test-Path -LiteralPath "$archive.hash" | Should -BeTrue
    }
    It 'skips both source and archive reads on an unchanged fast refresh' {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        Mock Get-FileHash { throw 'Unchanged source and archive bytes must not be read.' }
        Mock Move-Item { throw 'An unchanged archive must not be rebuilt.' }
        Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh | Should -Be $archive
        Should -Invoke Get-FileHash -Times 0
        Should -Invoke Move-Item -Times 0
    }
    It 'strict refresh detects source changes hidden by matching metadata receipts' {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        $stamp = (Get-Item -LiteralPath $script:DriverFile).LastWriteTimeUtc
        [IO.File]::WriteAllText($script:DriverFile, 'BBBB')
        (Get-Item -LiteralPath $script:DriverFile).LastWriteTimeUtc = $stamp
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh:$false
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        $reader = [IO.StreamReader]::new($zip.GetEntry('driver.inf').Open())
        try { $reader.ReadToEnd() | Should -Be 'BBBB' }
        finally { $reader.Dispose(); $zip.Dispose() }
        Mock Get-FileHash { throw 'Strict verification must refresh receipts for subsequent fast builds.' }
        Mock Move-Item { throw 'A fast build following strict verification must reuse the archive.' }
        Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh | Should -Be $archive
        Should -Invoke Get-FileHash -Times 0
        Should -Invoke Move-Item -Times 0
    }
    It 'rehashes driver sources even for timestamp changes smaller than two seconds' {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        $stamp = (Get-Item -LiteralPath $script:DriverFile).LastWriteTimeUtc
        [IO.File]::WriteAllText($script:DriverFile, 'BBBB')
        (Get-Item -LiteralPath $script:DriverFile).LastWriteTimeUtc = $stamp.AddSeconds(1)
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        $reader = [IO.StreamReader]::new($zip.GetEntry('driver.inf').Open())
        try { $reader.ReadToEnd() | Should -Be 'BBBB' }
        finally { $reader.Dispose(); $zip.Dispose() }
    }
    It 'strict refresh detects archive corruption hidden by matching metadata receipts' {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        $stamp = (Get-Item -LiteralPath $archive).LastWriteTimeUtc
        $bytes = [IO.File]::ReadAllBytes($archive)
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($archive, $bytes)
        (Get-Item -LiteralPath $archive).LastWriteTimeUtc = $stamp
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh:$false
        [IO.File]::ReadAllBytes($archive)[0] | Should -Be 0x50
    }
    It 'rejects non-Windows and non-AMD64 extractors before executing them' {
        Mock Invoke-Tool { }
        $extractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($extractor, 'not an executable')
        { Assert-RuntimeExtractor -Path $extractor } | Should -Throw '*Invalid runtime extractor*'
        $bytes = [byte[]]::new(512)
        $bytes[0] = 0x4D; $bytes[1] = 0x5A; $bytes[60] = 0x80
        $bytes[128] = 0x50; $bytes[129] = 0x45
        [IO.File]::WriteAllBytes($extractor, $bytes)
        { Assert-RuntimeExtractor -Path $extractor } | Should -Throw '*AMD64*'
        Should -Invoke Invoke-Tool -Times 0
    }
    It 'accepts a standalone AMD64 image but rejects non-inbox imports' {
        Mock Invoke-Tool { }
        $extractor = Join-Path $TestDrive 'standalone-7za.exe'
        $bytes = [byte[]]::new(1024)
        $bytes[0] = 0x4D; $bytes[1] = 0x5A; $bytes[60] = 0x80
        $bytes[128] = 0x50; $bytes[129] = 0x45
        $bytes[132] = 0x64; $bytes[133] = 0x86 # AMD64
        $bytes[134] = 1 # one section
        $bytes[148] = 0xF0 # PE32+ optional header length
        $bytes[152] = 0x0B; $bytes[153] = 2
        [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, 272) # import RVA
        [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, 404) # section RVA
        [BitConverter]::GetBytes([uint32]512).CopyTo($bytes, 408) # raw section size
        [BitConverter]::GetBytes([uint32]512).CopyTo($bytes, 412) # raw section offset
        [BitConverter]::GetBytes([uint32]0x1060).CopyTo($bytes, 524) # import name RVA
        [Text.Encoding]::ASCII.GetBytes("KERNEL32.dll`0").CopyTo($bytes, 608)
        [IO.File]::WriteAllBytes($extractor, $bytes)
        Assert-RuntimeExtractor -Path $extractor | Should -Be $extractor
        [Text.Encoding]::ASCII.GetBytes("VCRUNTIME140.dll`0").CopyTo($bytes, 608)
        [IO.File]::WriteAllBytes($extractor, $bytes)
        { Assert-RuntimeExtractor -Path $extractor } | Should -Throw '*not guaranteed in WinPE*'
        Should -Invoke Invoke-Tool -Times 1
    }
    It 'tests a fresh 7z once and trusts only a content-verified successful receipt on reuse' {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor fixture')
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') {
                [IO.File]::WriteAllText($ArgumentList[-2], 'archive')
            }
        }
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $archive | Should -BeLike '*.7z'
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 't' -and $FilePath -eq $script:RuntimeExtractor }
        Should -Invoke Invoke-Tool -Times 1 -ParameterFilter { $ArgumentList[0] -eq 'a' }
    }
    It 'fails before publishing an archive the runtime cannot extract' {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor fixture')
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') { [IO.File]::WriteAllText($ArgumentList[-2], 'archive') }
            else { throw 'runtime cannot extract archive' }
        }
        { Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir } |
            Should -Throw '*runtime cannot extract*'
        Test-Path -LiteralPath (Join-Path $script:ArchiveDir 'Drivers.7z') | Should -BeFalse
    }
    It 'always uses Maximum 7z settings with FastRefresh=<Fast>' -ForEach @(
        @{ Fast = $true }
        @{ Fast = $false }
    ) {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor')
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') { [IO.File]::WriteAllText($ArgumentList[-2], 'archive') }
        }
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh:$Fast
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'a' -and $FilePath -eq $script:RuntimeExtractor -and
            ($ArgumentList[1..6] -join ' ') -eq '-t7z -m0=lzma2 -mx=9 -mfb=273 -md=128m -ms=on'
        }
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 't' }
    }
    It 'rebuilds and retests when extractor bytes change despite identical timestamps and lengths' {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor-a')
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') { [IO.File]::WriteAllText($ArgumentList[-2], 'archive') }
        }
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $stamp = (Get-Item -LiteralPath $script:RuntimeExtractor).LastWriteTimeUtc
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor-b')
        (Get-Item -LiteralPath $script:RuntimeExtractor).LastWriteTimeUtc = $stamp
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'a' }
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 't' }
        Test-Path -LiteralPath "$archive.hash" | Should -BeTrue
    }
    It 'handles previous <Profile> 7z receipts and retests damaged receipts' -ForEach @(
        @{ Profile = 'Fast'; Options = '-m0=lzma2 -mx=1 -ms=on'; ZipLevel = 'Fastest'; Builds = 2 }
        @{ Profile = 'Balanced'; Options = '-m0=lzma2 -mx=5 -ms=on'; ZipLevel = 'Optimal'; Builds = 2 }
        @{ Profile = 'Maximum'; Options = '-m0=lzma2 -mx=9 -mfb=273 -md=128m -ms=on'; ZipLevel = 'Optimal'; Builds = 1 }
    ) {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor')
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') { [IO.File]::WriteAllText($ArgumentList[-2], 'archive') }
        }
        $archive = Join-Path $script:ArchiveDir 'Drivers.7z'
        [IO.File]::WriteAllText($archive, 'archive')
        $oldKey = Get-BuildPartsHash -Parts @('driver-archive-v2',
            (Get-DriverSourceHash -SourcePath $script:DriverSource), $Profile, $Options, $ZipLevel,
            (Get-FileHash -LiteralPath $script:RuntimeExtractor).Hash)
        $oldReceipt = "$oldKey|$((Get-FileHash -LiteralPath $archive).Hash)"
        Set-Content -LiteralPath "$archive.hash" -Value $oldReceipt
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        $receipt = (Get-Content -LiteralPath "$archive.hash" -Raw).Trim()
        ($receipt -eq $oldReceipt) | Should -Be ($Profile -eq 'Maximum')
        Should -Invoke Invoke-Tool -Times ($Builds - 1) -Exactly -ParameterFilter { $ArgumentList[0] -eq 'a' }
        Should -Invoke Invoke-Tool -Times ($Builds - 1) -Exactly -ParameterFilter { $ArgumentList[0] -eq 't' }
        Set-Content -LiteralPath "$archive.hash" -Value 'malformed'
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        Should -Invoke Invoke-Tool -Times $Builds -Exactly -ParameterFilter { $ArgumentList[0] -eq 'a' }
        Should -Invoke Invoke-Tool -Times $Builds -Exactly -ParameterFilter { $ArgumentList[0] -eq 't' }
    }
    It 'retains content corruption detection after a successful 7z test' {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        [IO.File]::WriteAllText($script:RuntimeExtractor, 'extractor')
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') { [IO.File]::WriteAllText($ArgumentList[-2], 'archive') }
        }
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $stamp = (Get-Item -LiteralPath $archive).LastWriteTimeUtc
        [IO.File]::WriteAllText($archive, 'corrupt')
        (Get-Item -LiteralPath $archive).LastWriteTimeUtc = $stamp
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'a' }
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 't' }
        [IO.File]::ReadAllText($archive) | Should -Be 'archive'
    }
    It 'handles previous <Profile> ZIP receipts with the permanent Maximum identity' -ForEach @(
        @{ Profile = 'Fast'; Options = '-m0=lzma2 -mx=1 -ms=on'; ZipLevel = 'Fastest'; Builds = 1 }
        @{ Profile = 'Balanced'; Options = '-m0=lzma2 -mx=5 -ms=on'; ZipLevel = 'Optimal'; Builds = 1 }
        @{ Profile = 'Maximum'; Options = '-m0=lzma2 -mx=9 -mfb=273 -md=128m -ms=on'; ZipLevel = 'Optimal'; Builds = 0 }
    ) {
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $maximumReceipt = (Get-Content -LiteralPath "$archive.hash" -Raw).Trim()
        $oldKey = Get-BuildPartsHash -Parts @('driver-archive-v2',
            (Get-DriverSourceHash -SourcePath $script:DriverSource), $Profile, $Options, $ZipLevel, 'dotnet-zip')
        Set-Content -LiteralPath "$archive.hash" -Value "$oldKey|$((Get-FileHash -LiteralPath $archive).Hash)"
        Mock Copy-Item {
            [IO.File]::Copy($LiteralPath, $Destination)
        }
        Mock Invoke-Tool { throw 'ZIP fallback must not execute any extractor.' }
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir -FastRefresh
        (Get-Content -LiteralPath "$archive.hash" -Raw).Trim() | Should -Be $maximumReceipt
        Should -Invoke Copy-Item -Times $Builds -Exactly -ParameterFilter { $LiteralPath -like '*Drivers-*.zip' }
        Should -Invoke Invoke-Tool -Times 0
    }
    It 'uses ZIP Optimal when no validated runtime extractor is supplied' {
        [IO.File]::WriteAllText($script:DriverFile, ('repeated driver content ' * 10000))
        Mock Invoke-Tool { throw 'ZIP fallback must not execute any extractor.' }
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $referencePath = Join-Path $TestDrive 'optimal-reference.zip'
        $reference = [IO.Compression.ZipFile]::Open($referencePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $reference, $script:DriverFile, 'driver.inf', [IO.Compression.CompressionLevel]::Optimal)
        }
        finally { $reference.Dispose() }
        (Get-FileHash -LiteralPath $archive).Hash | Should -Be (Get-FileHash -LiteralPath $referencePath).Hash
        Should -Invoke Invoke-Tool -Times 0
    }
}

Describe 'Two-level WIM servicing integration with mocked DISM' {
    BeforeEach {
        Mock Start-Step { }
        Mock Write-StepDone { }
        Mock Write-StepSkipped { }
        Mock Write-BuildLog { }
        $script:BuildPhases = @{}
        $script:OwnedWorkspace = Join-Path $TestDrive ('AutoReset-Build-' + [guid]::NewGuid().ToString('N'))
        $script:DismPath = 'dism.exe'
        $cache = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N'))
        $script:SourceWim = Join-Path $TestDrive 'adk.wim'
        $script:WorkingWim = Join-Path $script:OwnedWorkspace 'boot.wim'
        $script:ImageMount = Join-Path $script:OwnedWorkspace 'mount'
        $script:BootDrivers = Join-Path $TestDrive 'boot-drivers'
        New-Item -ItemType Directory -Path $script:OwnedWorkspace, $script:ImageMount, $script:BootDrivers -Force | Out-Null
        [IO.File]::WriteAllText($script:SourceWim, 'ADK')
        [IO.File]::WriteAllText((Join-Path $script:BootDrivers 'boot.inf'), 'driver-a')
        $script:Plan = Get-WinPECachePlan -CacheDirectory $cache -BaseParts @('adk', (Get-ContentTreeHash $script:BootDrivers)) -RuntimeParts @('runtime-a')
        $script:BuildArgs = @{
            CachePlan = $script:Plan; SourceWim = $script:SourceWim; BootWim = $script:WorkingWim
            MountPath = $script:ImageMount; DriverPath = $script:BootDrivers
            PackagePaths = @('WinPE-WMI.cab', 'WinPE-WMI_en-us.cab', 'WinPE-NetFx.cab')
            RuntimeFiles = @(); PayloadSource = $TestDrive; BootsectSource = 'bootsect.exe'
        }
        $script:ImageMounted = $false
        $script:PackageOrder = [Collections.Generic.List[string]]::new()
        Mock Get-WindowsImage {
            if ($script:ImageMounted) {
                [pscustomobject]@{ Path = $script:ImageMount; ImagePath = $script:WorkingWim }
            }
        }
        Mock Invoke-Tool {
            if ($ArgumentList -contains '/Mount-Image') {
                $ArgumentList | Should -Contain "/ImageFile:$script:WorkingWim"
                $script:ImageMounted = $true
            }
            elseif ($ArgumentList -contains '/Unmount-Image') { $script:ImageMounted = $false }
            elseif ($ArgumentList -contains '/Add-Package') {
                $package = ($ArgumentList | Where-Object { $_ -like '/PackagePath:*' }).Substring(13)
                $script:PackageOrder.Add($package)
                [IO.File]::AppendAllText($script:WorkingWim, "|$package")
            }
            elseif ($ArgumentList -contains '/Add-Driver') { [IO.File]::AppendAllText($script:WorkingWim, '|drivers') }
        }
        Mock Sync-RuntimePayload { [IO.File]::AppendAllText($script:WorkingWim, '|runtime') }
        Mock Set-WinPEStartup { }
    }
    It 'publishes a dismounted base before runtime customization, preserving package order and boot drivers' {
        Invoke-WinPEImageBuild @script:BuildArgs | Should -Be $script:WorkingWim
        Test-WinPECacheImage $script:Plan.BasePath | Should -BeTrue
        Test-WinPECacheImage $script:Plan.FinalPath | Should -BeTrue
        [IO.File]::ReadAllText($script:Plan.BasePath) | Should -Not -Match 'runtime'
        [IO.File]::ReadAllText($script:Plan.FinalPath) | Should -Match 'runtime'
        @($script:PackageOrder) | Should -Be $script:BuildArgs.PackagePaths
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList -contains '/Commit' }
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Driver' }
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/Set-ScratchSpace:512' }
    }
    It 'restores an identical final build without another mount or package installation' {
        Invoke-WinPEImageBuild @script:BuildArgs
        Invoke-WinPEImageBuild @script:BuildArgs
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 3 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Package' }
        Should -Invoke Sync-RuntimePayload -Times 1 -Exactly
        Should -Invoke Write-BuildLog -Times 1 -Exactly -ParameterFilter { $Text -like 'WIM final cache HIT*' }
    }
    It 'returns the final cache as a read-only media source without staging or servicing' {
        Publish-WinPECacheImage -Source $script:SourceWim -Destination $script:Plan.FinalPath
        Test-WinPECacheImage -Path $script:Plan.FinalPath -FastRefresh | Should -BeTrue
        Mock Copy-Item { throw 'A final cache hit must not stage a WIM.' }
        Mock Set-ItemProperty { throw 'A final cache hit must not change WIM attributes.' }
        Mock Invoke-Tool { throw 'A final cache hit must not mount or service a WIM.' }
        Mock Get-FileHash { throw 'An unchanged fast cache hit must not hash WIM bytes.' }
        Invoke-WinPEImageBuild @script:BuildArgs -FastRefresh | Should -Be $script:Plan.FinalPath
        Test-Path -LiteralPath $script:WorkingWim | Should -BeFalse
        Should -Invoke Copy-Item -Times 0
        Should -Invoke Set-ItemProperty -Times 0
        Should -Invoke Invoke-Tool -Times 0
        Should -Invoke Get-FileHash -Times 0
    }
    It 'syncs exactly one boot WIM for <State> builds with <Separator> inventory paths' -ForEach @(
        @{ State = 'cold'; Separator = '\' }
        @{ State = 'cold'; Separator = '/' }
        @{ State = 'base-hit'; Separator = '\' }
        @{ State = 'base-hit'; Separator = '/' }
        @{ State = 'final-hit'; Separator = '\' }
        @{ State = 'final-hit'; Separator = '/' }
        @{ State = 'no-cache'; Separator = '\' }
        @{ State = 'no-cache'; Separator = '/' }
    ) {
        if ($State -in @('base-hit', 'final-hit')) {
            $null = Invoke-WinPEImageBuild @script:BuildArgs
            Remove-Item -LiteralPath $script:WorkingWim
            if ($State -eq 'base-hit') {
                Remove-Item -LiteralPath $script:Plan.FinalPath
            }
        }
        $bootWimSource = Invoke-WinPEImageBuild @script:BuildArgs -NoCache:($State -eq 'no-cache')
        $bootWimSource | Should -Be $(if ($State -eq 'final-hit') { $script:Plan.FinalPath } else { $script:WorkingWim })
        $bootWimFile = [pscustomobject]@{
            RelativePath = 'sources/boot.wim'
            Length = (Get-Item -LiteralPath $bootWimSource).Length
            SourcePath = $bootWimSource
        }
        $script:BootInventory = @([pscustomobject]@{
            RelativePath = "Boot${Separator}boot.sdi"
            Length = (Get-Item -LiteralPath $script:SourceWim).Length
            SourcePath = $script:SourceWim
        })
        if (Test-Path -LiteralPath $script:WorkingWim) {
            $script:BootInventory += [pscustomobject]@{
                RelativePath = "sources${Separator}boot.wim"
                Length = (Get-Item -LiteralPath $script:WorkingWim).Length
                SourcePath = $script:WorkingWim
            }
        }
        Mock Get-MediaFileInventory { $script:BootInventory }
        Mock Update-StepDisplay { }
        Mock Clear-Disk { throw 'Inventory tests must never touch a disk.' }
        $mediaDir = $script:OwnedWorkspace
        $assignment = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$bootFiles'
        }, $true)
        $assignment.Count | Should -Be 1
        # Evaluate only the inventory expression, never the builder entrypoint.
        $bootFiles = @(& ([scriptblock]::Create($assignment[0].Right.Extent.Text)))
        $bootFiles.Count | Should -Be 2
        $wims = @($bootFiles | Where-Object { (ConvertTo-BuildRelativePath $_.RelativePath) -eq 'sources/boot.wim' })
        $wims.Count | Should -Be 1
        $wims[0].SourcePath | Should -Be $bootWimSource
        $destination = Join-Path $TestDrive 'boot-output'
        Sync-BuildFiles -Files $bootFiles -Destination $destination
        [IO.File]::ReadAllText((Join-Path $destination 'sources/boot.wim')) |
            Should -Be ([IO.File]::ReadAllText($bootWimSource))
        Should -Invoke Clear-Disk -Times 0
    }
    It 'customizes a runtime-only change from the base without reinstalling packages or drivers' {
        Invoke-WinPEImageBuild @script:BuildArgs
        $baseHash = (Get-FileHash -LiteralPath $script:Plan.BasePath).Hash
        $script:BuildArgs.CachePlan = Get-WinPECachePlan -CacheDirectory $cache -BaseParts @('adk', (Get-ContentTreeHash $script:BootDrivers)) -RuntimeParts @('runtime-b')
        Invoke-WinPEImageBuild @script:BuildArgs
        Should -Invoke Invoke-Tool -Times 3 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 3 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Package' }
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Driver' }
        Should -Invoke Sync-RuntimePayload -Times 2 -Exactly
        (Get-FileHash -LiteralPath $script:Plan.BasePath).Hash | Should -Be $baseHash
    }
    It 'services both layers again after a boot driver content change' {
        Invoke-WinPEImageBuild @script:BuildArgs
        [IO.File]::WriteAllText((Join-Path $script:BootDrivers 'boot.inf'), 'driver-b')
        $script:BuildArgs.CachePlan = Get-WinPECachePlan -CacheDirectory $cache -BaseParts @('adk', (Get-ContentTreeHash $script:BootDrivers)) -RuntimeParts @('runtime-a')
        Invoke-WinPEImageBuild @script:BuildArgs
        Should -Invoke Invoke-Tool -Times 4 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 6 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Package' }
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Driver' }
    }
    It 'bypasses both cache reads and publications with NoCache' {
        Invoke-WinPEImageBuild @script:BuildArgs
        Mock Test-WinPECacheImage { throw 'NoCache must not read either cache.' }
        Mock Publish-WinPECacheImage { throw 'NoCache must not publish either cache.' }
        Invoke-WinPEImageBuild @script:BuildArgs -NoCache
        Should -Invoke Test-WinPECacheImage -Times 0
        Should -Invoke Publish-WinPECacheImage -Times 0
        Should -Invoke Invoke-Tool -Times 3 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 6 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Package' }
    }
    It 'treats a <Damage> final cache as a miss but still uses the verified base' -ForEach @(
        @{ Damage = 'corrupt image' }, @{ Damage = 'malformed receipt' }, @{ Damage = 'missing receipt' }
    ) {
        Invoke-WinPEImageBuild @script:BuildArgs
        switch ($Damage) {
            'corrupt image' {
                $bytes = [IO.File]::ReadAllBytes($script:Plan.FinalPath)
                $stamp = (Get-Item -LiteralPath $script:Plan.FinalPath).LastWriteTimeUtc
                $bytes[0] = $bytes[0] -bxor 1
                [IO.File]::WriteAllBytes($script:Plan.FinalPath, $bytes)
                (Get-Item -LiteralPath $script:Plan.FinalPath).LastWriteTimeUtc = $stamp
            }
            'malformed receipt' { [IO.File]::WriteAllText("$($script:Plan.FinalPath).hash", 'not-a-hash') }
            'missing receipt' { Remove-Item -LiteralPath "$($script:Plan.FinalPath).hash" }
        }
        Invoke-WinPEImageBuild @script:BuildArgs
        Should -Invoke Invoke-Tool -Times 3 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 3 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Package' }
        Test-WinPECacheImage $script:Plan.FinalPath | Should -BeTrue
    }
    It 'rebuilds a corrupt serviced base rather than customizing damaged data' {
        Invoke-WinPEImageBuild @script:BuildArgs
        Remove-Item -LiteralPath $script:Plan.FinalPath
        [IO.File]::WriteAllText($script:Plan.BasePath, 'corrupt base')
        Invoke-WinPEImageBuild @script:BuildArgs
        Should -Invoke Invoke-Tool -Times 4 -Exactly -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        Should -Invoke Invoke-Tool -Times 6 -Exactly -ParameterFilter { $ArgumentList -contains '/Add-Package' }
        Test-WinPECacheImage $script:Plan.BasePath | Should -BeTrue
    }
    It 'does not mutate the base or publish a final image when customization fails' {
        Invoke-WinPEImageBuild @script:BuildArgs
        $baseHash = (Get-FileHash -LiteralPath $script:Plan.BasePath).Hash
        $script:BuildArgs.CachePlan = Get-WinPECachePlan -CacheDirectory $cache -BaseParts @('adk', (Get-ContentTreeHash $script:BootDrivers)) -RuntimeParts @('runtime-b')
        Mock Sync-RuntimePayload {
            [IO.File]::AppendAllText($script:WorkingWim, '|failed')
            throw 'customization failed'
        }
        { Invoke-WinPEImageBuild @script:BuildArgs } | Should -Throw '*customization failed*'
        (Get-FileHash -LiteralPath $script:Plan.BasePath).Hash | Should -Be $baseHash
        Test-Path -LiteralPath $script:BuildArgs.CachePlan.FinalPath | Should -BeFalse
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/Discard' -and $ArgumentList -contains "/MountDir:$script:ImageMount" }
    }
    It 'discards a failed cold service without publishing either layer' {
        Mock Invoke-Tool { throw 'package failed' } -ParameterFilter { $ArgumentList -contains '/Add-Package' }
        { Invoke-WinPEImageBuild @script:BuildArgs } | Should -Throw '*package failed*'
        Test-Path -LiteralPath $script:Plan.BasePath | Should -BeFalse
        Test-Path -LiteralPath $script:Plan.FinalPath | Should -BeFalse
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/Discard' }
    }
    It 'cleans an exact owned registration left behind by a failed mount command' {
        Mock Invoke-Tool {
            $script:ImageMounted = $true
            throw 'mount partially failed'
        } -ParameterFilter { $ArgumentList -contains '/Mount-Image' }
        { Invoke-WinPEImageBuild @script:BuildArgs } | Should -Throw '*mount partially failed*'
        Should -Invoke Invoke-Tool -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains '/Discard' -and $ArgumentList -contains "/MountDir:$script:ImageMount"
        }
        Test-Path -LiteralPath $script:Plan.BasePath | Should -BeFalse
        Test-Path -LiteralPath $script:Plan.FinalPath | Should -BeFalse
    }
    It 'refuses publishing an image still registered as mounted' {
        [IO.File]::WriteAllText($script:WorkingWim, 'mounted')
        $script:ImageMounted = $true
        { Publish-WinPECacheImage -Source $script:WorkingWim -Destination $script:Plan.BasePath } | Should -Throw '*mounted image*'
        Test-Path -LiteralPath $script:Plan.BasePath | Should -BeFalse
    }
    It 'cleans only staged publication files when a cache copy fails' {
        [IO.File]::WriteAllText($script:WorkingWim, 'completed image')
        Mock Copy-Item {
            [IO.File]::WriteAllText($Destination, 'partial')
            throw 'cache copy failed'
        }
        { Publish-WinPECacheImage -Source $script:WorkingWim -Destination $script:Plan.BasePath } | Should -Throw '*cache copy failed*'
        Test-Path -LiteralPath $script:Plan.BasePath | Should -BeFalse
        @(Get-ChildItem -LiteralPath $cache -File).Count | Should -Be 0
    }
}

Describe 'Isolated workspace and mount cleanup' {
    BeforeEach {
        $script:OwnedWorkspace = Join-Path $TestDrive 'AutoReset-Build-0123456789abcdef0123456789abcdef'
        $script:MountPath = Join-Path $script:OwnedWorkspace 'mount/boot-wim'
        $script:ImagePath = Join-Path $script:OwnedWorkspace 'media/sources/boot.wim'
        $script:DismPath = 'dism.exe'
        Mock Invoke-Tool { }
    }
    It 'does not discard unrelated mounts or prefix-sibling workspaces' {
        Mock Get-WindowsImage {
            [pscustomobject]@{ Path = "$script:OwnedWorkspace-other/mount"; ImagePath = "$script:OwnedWorkspace-other/image.wim" }
            [pscustomobject]@{ Path = (Join-Path $TestDrive 'unrelated-mount'); ImagePath = (Join-Path $TestDrive 'other.wim') }
        }
        Clear-StaleMounts -MountPath $script:MountPath -ImagePath $script:ImagePath
        Should -Invoke Invoke-Tool -Times 0
    }
    It 'refuses an unknown image mounted at its own mount path' {
        Mock Get-WindowsImage { [pscustomobject]@{ Path = $script:MountPath; ImagePath = (Join-Path $TestDrive 'foreign.wim') } }
        { Clear-StaleMounts -MountPath $script:MountPath -ImagePath $script:ImagePath } | Should -Throw '*Unknown mount*'
        Should -Invoke Invoke-Tool -Times 0
    }
    It 'refuses its own image mounted at an unexpected path' {
        Mock Get-WindowsImage { [pscustomobject]@{ Path = (Join-Path $TestDrive 'foreign-mount'); ImagePath = $script:ImagePath } }
        { Clear-StaleMounts -MountPath $script:MountPath -ImagePath $script:ImagePath } | Should -Throw '*Unknown mount*'
        Should -Invoke Invoke-Tool -Times 0
    }
    It 'discards only the exact owned mount and image pair' {
        $script:MountQueries = 0
        Mock Get-WindowsImage {
            $script:MountQueries++
            if ($script:MountQueries -eq 1) { [pscustomobject]@{ Path = $script:MountPath; ImagePath = $script:ImagePath } }
        }
        Clear-StaleMounts -MountPath $script:MountPath -ImagePath $script:ImagePath
        Should -Invoke Invoke-Tool -Times 1 -ParameterFilter {
            $ArgumentList -contains '/Discard' -and $ArgumentList -contains "/MountDir:$script:MountPath"
        }
    }
    It 'propagates mount enumeration errors without attempting cleanup' {
        Mock Get-WindowsImage { throw 'DISM enumeration failed' }
        { Clear-StaleMounts -MountPath $script:MountPath -ImagePath $script:ImagePath } | Should -Throw '*enumeration failed*'
        Should -Invoke Invoke-Tool -Times 0
    }
    It 'will not clean arbitrary supplied workspace folders' {
        $WorkDir = Join-Path $TestDrive 'important'
        $KeepWorkDir = $false
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        { Complete-WorkingFolder } | Should -Throw '*unowned workspace*'
        Test-Path -LiteralPath $WorkDir | Should -BeTrue
    }
    It 'rejects root and overlapping mirrors' {
        $source = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path $source | Out-Null
        { Assert-SafeMirror -Source $source -Destination ([IO.Path]::GetPathRoot($TestDrive)) } | Should -Throw '*root or overlapping*'
        { Assert-SafeMirror -Source $source -Destination (Join-Path $source 'nested') } | Should -Throw '*root or overlapping*'
        { Assert-SafeMirror -Source $source -Destination $TestDrive } | Should -Throw '*root or overlapping*'
    }
    It 'refuses to follow links inside an owned destination' {
        $dest = Join-Path $TestDrive 'linked-destination'
        $target = Join-Path $TestDrive 'unrelated-target'
        New-Item -ItemType Directory -Path $dest, $target -Force | Out-Null
        try { New-Item -ItemType SymbolicLink -Path (Join-Path $dest 'link') -Target $target -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'This host cannot create test symbolic links.'; return }
        { Assert-NoReparsePath -Path $dest -Recurse } | Should -Throw '*Reparse points*'
    }
    It 'allows non-link reparse points for cloud-filtered directories' {
        $path = Join-Path $TestDrive 'cloud-filtered'
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $path }
        Mock Get-Item {
            [pscustomobject]@{
                FullName   = $path
                Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
                LinkType   = $null
                Target     = $null
            }
        } -ParameterFilter { $LiteralPath -eq $path }
        { Assert-NoReparsePath -Path $path } | Should -Not -Throw
    }
    It 'does not remove a workspace with a live mounted image' {
        $WorkDir = $script:OwnedWorkspace
        $KeepWorkDir = $false
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        Mock Get-WindowsImage { [pscustomobject]@{ Path = $script:MountPath; ImagePath = $script:ImagePath } }
        { Complete-WorkingFolder } | Should -Throw '*still contains a mounted image*'
        Test-Path -LiteralPath $WorkDir | Should -BeTrue
    }
    It 'removes only its unique workspace and preserves files in the supplied parent' {
        $WorkDir = $script:OwnedWorkspace
        $KeepWorkDir = $false
        $sentinel = Join-Path $TestDrive 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'user content'
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        Mock Get-WindowsImage { }
        Complete-WorkingFolder
        Test-Path -LiteralPath $WorkDir | Should -BeFalse
        Get-Content -LiteralPath $sentinel | Should -Be 'user content'
    }
}

Describe 'Optional WinPE display mode' {
    It 'does not generate Display or unattended arguments by default' {
        Set-WinPEStartup -System32Path $TestDrive
        Test-Path -LiteralPath (Join-Path $TestDrive 'winpe-unattend.xml') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $TestDrive 'winpeshl.ini') -Raw | Should -Not -Match 'unattend'
        Get-Content -LiteralPath (Join-Path $TestDrive 'startnet.cmd') -Raw | Should -Not -Match 'unattend'
        Get-Content -LiteralPath (Join-Path $TestDrive 'AutoReset-Startup.cmd') -Raw | Should -Not -Match 'unattend'
    }
    It 'generates Display only when explicitly requested' {
        Set-WinPEStartup -System32Path $TestDrive -Resolution '1280x720'
        [xml]$xml = Get-Content -LiteralPath (Join-Path $TestDrive 'winpe-unattend.xml') -Raw
        $xml.unattend.settings.component.Display.HorizontalResolution | Should -Be '1280'
        $xml.unattend.settings.component.Display.VerticalResolution | Should -Be '720'
        Get-Content -LiteralPath (Join-Path $TestDrive 'AutoReset-Startup.cmd') -Raw |
            Should -Match 'wpeinit.exe" -unattend:X:\\Windows\\System32\\winpe-unattend.xml'
    }
    It 'removes a stale explicit resolution when returning to defaults' {
        Set-WinPEStartup -System32Path $TestDrive -Resolution '1920x1200'
        Set-WinPEStartup -System32Path $TestDrive
        Test-Path -LiteralPath (Join-Path $TestDrive 'winpe-unattend.xml') | Should -BeFalse
    }
}

Describe 'Visible WinPE startup supervisor' {
    BeforeEach {
        Set-WinPEStartup -System32Path $TestDrive
        $script:Launcher = Get-Content -LiteralPath (Join-Path $TestDrive 'AutoReset-Startup.cmd') -Raw
    }
    It 'routes both entrypoints through the same persistent CMD supervisor' {
        foreach ($name in @('winpeshl.ini', 'startnet.cmd')) {
            $entrypoint = Get-Content -LiteralPath (Join-Path $TestDrive $name) -Raw
            $entrypoint | Should -Match 'cmd.exe"?[,]? /d /k'
            $entrypoint | Should -Match '%SYSTEMROOT%\\System32\\AutoReset-Startup.cmd'
            $entrypoint | Should -Not -Match 'powershell|wpeinit|WindowStyle'
        }
    }
    It 'initializes WinPE once and stops on failure before launching deployment' {
        ([regex]::Matches($script:Launcher, '(?m)^"%SYSTEMROOT%\\System32\\wpeinit.exe"')).Count | Should -Be 1
        $script:Launcher | Should -Match '(?s)wpeinit.exe" >>"%StartupLog%" 2>&1\r\nset "StartupExitCode=%errorlevel%".*?if not "%StartupExitCode%"=="0" goto stopped.*?start "AutoReset runtime"'
        $script:Launcher | Should -Match 'if not exist "%SYSTEMROOT%\\System32\\wpeinit.exe" goto stopped'
    }
    It 'checks for a missing executable and script before launching PowerShell' {
        $script:Launcher | Should -Match 'if not exist "%SYSTEMROOT%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" goto stopped'
        $script:Launcher | Should -Match 'if not exist "%SYSTEMDRIVE%\\Payload\\Scripts\\autoreset.ps1" goto stopped'
    }
    It 'waits for a separate console and captures the actual child exit code' {
        $script:Launcher | Should -Match 'start "AutoReset runtime" /wait "%SYSTEMROOT%\\System32\\cmd.exe" /d /c ""%~f0" child"'
        $script:Launcher | Should -Not -Match '(?im)^start .* /b |WindowStyle Hidden'
        $script:Launcher | Should -Match '(?s)start "AutoReset runtime".*?\r\nset "StartupExitCode=%errorlevel%"'
        $script:Launcher | Should -Match '(?s):child\r\n.*?-NonInteractive -STA .*?-File .*? >>"%SYSTEMROOT%\\Temp\\AutoReset-Startup.log" 2>&1\r\nexit /b %errorlevel%'
        $script:Launcher.IndexOf('if /i "%~1"=="child" goto child') |
            Should -BeLessThan $script:Launcher.IndexOf('wpeinit.exe')
    }
    It 'uses distinct log files for the waiting parent and the runtime child' {
        $script:Launcher | Should -Match 'set "LauncherLog=%SYSTEMROOT%\\Temp\\AutoReset-Launcher.log"'
        $script:Launcher | Should -Match 'set "StartupLog=%SYSTEMROOT%\\Temp\\AutoReset-Startup.log"'
        $parent = [regex]::Match($script:Launcher, '(?m)^start "AutoReset runtime".*').Value
        $parent | Should -Match ' >"%LauncherLog%" 2>&1'
        $parent | Should -Not -Match '%StartupLog%|AutoReset-Startup.log'
        $child = ($script:Launcher -split ':child\r\n', 2)[1] -split ':stopped\r\n', 2 | Select-Object -First 1
        $child | Should -Match ' >>"%SYSTEMROOT%\\Temp\\AutoReset-Startup.log" 2>&1'
        $child | Should -Not -Match '%LauncherLog%|AutoReset-Launcher.log'
    }
    It 'shows errors and log paths using only CMD builtins and never retries or reboots' {
        $diagnostics = ($script:Launcher -split ':stopped\r\n', 2)[1]
        $diagnostics | Should -Match 'type "%StartupLog%"'
        $diagnostics | Should -Match 'type "%LauncherLog%"'
        $diagnostics | Should -Match 'echo Launcher log: "%LauncherLog%"'
        $diagnostics | Should -Match 'type "%SYSTEMROOT%\\Temp\\AutoReset-Bootstrap.log"'
        $diagnostics | Should -Match 'if exist "%SYSTEMROOT%\\Temp\\AutoReset.log" type "%SYSTEMROOT%\\Temp\\AutoReset.log"'
        $diagnostics.LastIndexOf('type "') | Should -BeLessThan $diagnostics.IndexOf('echo ===== AUTORESET STOPPED =====')
        $diagnostics | Should -Match 'echo Exit code: %StartupExitCode%'
        foreach ($log in @('AutoReset.log', 'AutoReset-Detail.log', 'SMSTSLog\smsts.log', 'wpeinit.log')) {
            $diagnostics | Should -Match ([regex]::Escape($log))
        }
        $diagnostics | Should -Not -Match '(?im)^(?:pause|timeout|choice|powershell|start |goto |.*wpeutil.exe)'
        $diagnostics | Should -Match 'command prompt below'
        $script:Launcher | Should -Match 'Exit code 0 can also mean cancellation or an unexpected return'
    }
    It 'generates an ASCII CRLF batch file without a byte-order mark' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $TestDrive 'AutoReset-Startup.cmd'))
        $bytes[0] | Should -Be 64
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $script:Launcher | Should -Not -Match '(?<!\r)\n'
        $script:Launcher | Should -Not -Match '__WPEINIT_ARGS__'
    }
    It 'includes the startup helper in runtime cache invalidation' {
        [IO.File]::ReadAllText($script:BuilderPath) |
            Should -Match "(?s)foreach \(\`$helper in @\([^)]*'Set-WinPEStartup'.*?runtimeParts \+="
    }
}

# These tests execute only generated launchers patched to harmless local fixtures.
# They validate Windows CMD behavior, not WinPE or the destructive runtime.
Describe 'Windows startup launcher fault injection' -Skip:($env:OS -ne 'Windows_NT') {
    It 'retains diagnostics for <Fault>' -ForEach @(
        @{ Fault = 'missing initializer'; InitExit = 0; Child = ''; ExpectedExit = 2; Expected = 'Missing WinPE initializer'; RunsChild = $false }
        @{ Fault = 'initialization failure'; InitExit = 23; Child = 'throw "must not run"'; ExpectedExit = 23; Expected = 'fake init output'; RunsChild = $false }
        @{ Fault = 'missing PowerShell'; InitExit = 0; Child = ''; ExpectedExit = 2; Expected = 'Missing PowerShell'; RunsChild = $false }
        @{ Fault = 'missing runtime'; InitExit = 0; Child = ''; ExpectedExit = 2; Expected = 'Missing AutoReset script'; RunsChild = $false }
        @{ Fault = 'parse failure'; InitExit = 0; Child = 'function Broken {'; ExpectedExit = 1; Expected = 'ParserError'; RunsChild = $true }
        @{ Fault = 'runtime failure'; InitExit = 0; Child = 'Write-Output "fake stdout"; [Console]::Error.WriteLine("fake stderr"); exit 17'; ExpectedExit = 17; Expected = 'fake stderr'; RunsChild = $true }
        @{ Fault = 'unexpected clean return'; InitExit = 0; Child = 'Write-Output "fake clean return"; exit 0'; ExpectedExit = 0; Expected = 'fake clean return'; RunsChild = $true }
    ) {
        $fixture = Join-Path $TestDrive "safe startup $Fault"
        $null = New-Item -ItemType Directory -Path $fixture -Force
        Set-WinPEStartup -System32Path $fixture
        $launcherPath = Join-Path $fixture 'AutoReset-Startup.cmd'
        $initPath = Join-Path $fixture 'fake-init.cmd'
        $childPath = Join-Path $fixture 'fake-runtime.ps1'
        $logPath = Join-Path $fixture 'AutoReset-Startup.log'
        $launcherLogPath = Join-Path $fixture 'AutoReset-Launcher.log'
        $consolePath = Join-Path $fixture 'console.log'
        $markerPath = Join-Path $fixture 'child-launched'
        $psPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Set-Content -LiteralPath $initPath -Encoding Ascii -Value @(
            '@echo off', 'echo fake init output', "exit /b $InitExit")
        Set-Content -LiteralPath $childPath -Encoding Ascii -Value $Child
        Set-Content -LiteralPath (Join-Path $fixture 'AutoReset-Bootstrap.log') -Encoding Ascii -Value 'fake bootstrap diagnostic'
        Set-Content -LiteralPath (Join-Path $fixture 'AutoReset.log') -Encoding Ascii -Value 'fake runtime diagnostic'
        if ($Fault -eq 'missing initializer') { Remove-Item -LiteralPath $initPath }
        if ($Fault -eq 'missing runtime') { Remove-Item -LiteralPath $childPath }
        if ($Fault -eq 'missing PowerShell') { $psPath = Join-Path $fixture 'missing-powershell.exe' }
        $launcher = [IO.File]::ReadAllText($launcherPath)
        $launcher = $launcher.Replace(
            '"%SYSTEMROOT%\System32\wpeinit.exe" >>', 'call "' + $initPath + '" >>')
        $launcher = $launcher.Replace('%SYSTEMROOT%\System32\wpeinit.exe', $initPath)
        $launcher = $launcher.Replace('%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe', $psPath)
        $launcher = $launcher.Replace('%SYSTEMDRIVE%\Payload\Scripts\autoreset.ps1', $childPath)
        $launcher = $launcher.Replace('%SYSTEMROOT%\Temp', $fixture)
        $launcher = $launcher.Replace(":child`r`n", ":child`r`n>""$markerPath"" echo launched`r`n")
        $launcher | Should -Not -Match '%SYSTEMDRIVE%\\Payload|%SYSTEMROOT%\\System32\\wpeinit.exe'
        [IO.File]::WriteAllText($launcherPath, $launcher, [Text.Encoding]::ASCII)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        # /c lets the test collect output; production /k retention is checked above.
        $psi.Arguments = '/d /c ""' + $launcherPath + '" >"' + $consolePath + '" 2>&1"'
        $psi.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($psi)
        try {
            $process.WaitForExit(30000) | Should -BeTrue
            $output = [IO.File]::ReadAllText($consolePath)
            $output | Should -Match "Exit code: $ExpectedExit"
            $output | Should -Match $Expected
            $output | Should -Match 'AUTORESET STOPPED'
            $output | Should -Match 'fake bootstrap diagnostic'
            $output | Should -Match 'fake runtime diagnostic'
            $output.IndexOf('fake runtime diagnostic') | Should -BeLessThan $output.IndexOf('AUTORESET STOPPED')
            $output | Should -Match ([regex]::Escape($launcherLogPath))
            [IO.File]::ReadAllText($logPath) | Should -Match $Expected
            Test-Path -LiteralPath $markerPath | Should -Be $RunsChild
            if ($RunsChild) {
                Test-Path -LiteralPath $launcherLogPath | Should -BeTrue
                [IO.File]::ReadAllText($launcherLogPath) | Should -Not -Match $Expected
            }
            $initCount = if ($Fault -eq 'missing initializer') { 0 } else { 1 }
            ([regex]::Matches([IO.File]::ReadAllText($logPath), 'fake init output')).Count | Should -Be $initCount
            if ($Fault -eq 'runtime failure') { $output | Should -Match 'fake stdout' }
        }
        finally {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
    }
}

Describe 'Builder help header parsing without entrypoint execution' {
    It 'starts directly with the help comment, not a BOM retained by raw-text readers' {
        $bytes = [IO.File]::ReadAllBytes($script:BuilderPath)
        $bytes[0] | Should -Be 0x3C
        $bytes[1] | Should -Be 0x23
    }
    It 'keeps non-ASCII builder text inside comments for legacy Windows decoding' {
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:BuilderPath, [ref]$tokens, [ref]$null)
        @($tokens | Where-Object {
            $_.Kind -ne 'Comment' -and $_.Text -match '[^\x00-\x7F]'
        }).Count | Should -Be 0
    }
    It 'parses raw <Encoding> bytes with <Ending> without exposing the help text as code' -ForEach @(
        @{ Encoding = 'UTF-8'; CodePage = 65001; Ending = 'LF'; NewLine = "`n" }
        @{ Encoding = 'UTF-8'; CodePage = 65001; Ending = 'CRLF'; NewLine = "`r`n" }
        @{ Encoding = 'Windows-1252'; CodePage = 1252; Ending = 'LF'; NewLine = "`n" }
        @{ Encoding = 'Windows-1252'; CodePage = 1252; Ending = 'CRLF'; NewLine = "`r`n" }
    ) {
        # GetString deliberately does not strip a BOM, unlike ReadAllText/ParseFile.
        $source = [Text.Encoding]::GetEncoding($CodePage).GetString([IO.File]::ReadAllBytes($script:BuilderPath))
        $source = $source -replace '\r?\n', $NewLine
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $tokens[0].Kind | Should -Be 'Comment'
        $tokens[0].Text | Should -Match '<LocalAppData>'
        $tokens[0].Text | Should -Match '<OutputRoot>'
        $ast.GetHelpContent().Synopsis | Should -Match 'AutoReset and KillDisk'
        $bindingOnly = [scriptblock]::Create(
            $source.Substring(0, $ast.ParamBlock.Extent.EndOffset) +
            "`n`$PSCmdlet.ParameterSetName")
        (& $bindingOnly -UpdateUsb) | Should -Be 'USBUPDATE'
    }
    It 'preserves comment-based help and its angle-bracket path placeholders' {
        $help = $script:BuilderAst.GetHelpContent()
        $help.Synopsis | Should -Match 'AutoReset and KillDisk'
        $help.Parameters['WORKDIR'] | Should -Match '<LocalAppData>\\AutoReset\\Work'
        $help.Parameters['ISOPATH'] | Should -Match '<OutputRoot>\\AutoReset\.iso'
        $help.Parameters['STRICTVERIFY'] | Should -Match 'full SHA256 verification'
        $help.Examples.Count | Should -Be 6
    }
    It 'parses the complete file with <Name> and binds update mode without executing the builder' -ForEach @(
        @{ Name = 'UTF-8 BOM and LF'; Bom = $true; NewLine = "`n" }
        @{ Name = 'UTF-8 BOM and CRLF'; Bom = $true; NewLine = "`r`n" }
        @{ Name = 'UTF-8 without BOM and LF'; Bom = $false; NewLine = "`n" }
        @{ Name = 'UTF-8 without BOM and CRLF'; Bom = $false; NewLine = "`r`n" }
    ) {
        $source = [IO.File]::ReadAllText($script:BuilderPath)
        $source = ($source -replace '\r?\n', $NewLine)
        $path = Join-Path $TestDrive 'builder-parse-only.ps1'
        [IO.File]::WriteAllText($path, $source, (New-Object Text.UTF8Encoding($Bom)))
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $ast.ParamBlock | Should -Not -BeNullOrEmpty
        $attributeStart = $ast.ParamBlock.Attributes[0].Extent.StartOffset
        $headerTokens = @($tokens | Where-Object { $_.Extent.StartOffset -lt $attributeStart })
        @($headerTokens | Where-Object { $_.Kind -notin @('Comment', 'NewLine') }).Count | Should -Be 0
        $ast.GetHelpContent().Synopsis | Should -Match 'AutoReset and KillDisk'
        # Retain the actual header and attributes, replacing all executable build code.
        $bindingOnly = [scriptblock]::Create(
            $ast.Extent.Text.Substring(0, $ast.ParamBlock.Extent.EndOffset) +
            "`n`$PSCmdlet.ParameterSetName")
        (& $bindingOnly -UpdateUsb) | Should -Be 'USBUPDATE'
    }
}

Describe 'Public build parameter binding without entrypoint execution' {
    It 'preserves the complete supported parameter surface and BootOnly alias' {
        $names = @($script:BuilderAst.ParamBlock.Parameters.Name.VariablePath.UserPath | Sort-Object)
        $names | Should -Be (@(
            'UsbDiskNumber', 'OutputRoot', 'WorkDir', 'KeepWorkDir', 'WinPEResolution',
            'SkipPayload', 'InstallPrerequisites', 'AllowNonUsbDisk', 'UpdateUsb', 'NoCache',
            'StrictVerify', 'BuildIso', 'IsoPath', 'PrepareImage', 'SourceImage', 'Edition',
            'SourceIndex', 'DestinationImage', 'Rebuild', 'ListOnly', 'PrepareDrivers',
            'Device', 'Force', 'ValidateUsb', 'LogFile'
        ) | Sort-Object)
        $bound = & $script:BindBuilderParameters -UsbDiskNumber 7 -BootOnly -NoCache -KeepWorkDir -AllowNonUsbDisk
        $bound.Bound.UsbDiskNumber | Should -Be 7
        foreach ($name in @('SkipPayload', 'NoCache', 'KeepWorkDir', 'AllowNonUsbDisk')) {
            [bool]$bound.Bound[$name] | Should -BeTrue
        }
    }
    It 'rejects removed public parameter <Name>' -ForEach @(
        @{ Name = 'DriverCompression'; Value = 'Maximum' }
        @{ Name = 'NoZip'; Value = $true }
        @{ Name = 'FastRefresh'; Value = $false }
    ) {
        $arguments = @{ PrepareDrivers = $true }
        $arguments[$Name] = $Value
        { & $script:BindBuilderParameters @arguments } | Should -Throw '*parameter cannot be found*'
    }
    It 'binds <Mode> with fast defaults and opt-in strict verification' -ForEach @(
        @{ Mode = 'USB'; ModeArgs = @{ UsbDiskNumber = 7 } }
        @{ Mode = 'USBUPDATE'; ModeArgs = @{ UpdateUsb = $true } }
        @{ Mode = 'ISO'; ModeArgs = @{ BuildIso = $true; IsoPath = 'output.iso' } }
        @{ Mode = 'PrepareImage'; ModeArgs = @{ PrepareImage = $true; SourceImage = 'install.esd' } }
        @{ Mode = 'PrepareDrivers'; ModeArgs = @{ PrepareDrivers = $true; Device = 'Model'; Force = $true } }
        @{ Mode = 'ValidateUsb'; ModeArgs = @{ ValidateUsb = $true; LogFile = 'validation.log' } }
    ) {
        $default = & $script:BindBuilderParameters @ModeArgs
        $explicitFalse = & $script:BindBuilderParameters @ModeArgs -StrictVerify:$false
        $strictSwitch = & $script:BindBuilderParameters @ModeArgs -StrictVerify
        $explicitTrue = & $script:BindBuilderParameters @ModeArgs -StrictVerify:$true
        foreach ($result in @($default, $explicitFalse)) {
            $result.Mode | Should -Be $Mode
            $result.Fast | Should -BeTrue
            $result.Strict | Should -BeFalse
        }
        foreach ($result in @($strictSwitch, $explicitTrue)) {
            $result.Mode | Should -Be $Mode
            $result.Fast | Should -BeFalse
            $result.Strict | Should -BeTrue
        }
    }
    It 'still rejects conflicting output modes and invalid image indexes' {
        { & $script:BindBuilderParameters -BuildIso -UpdateUsb } | Should -Throw
        { & $script:BindBuilderParameters -PrepareImage -SourceImage 'install.esd' -SourceIndex 0 } | Should -Throw
    }
}

Describe 'Build orchestration regression guards' {
    It 'defines opt-in StrictVerify and initializes its inverse before any prep dispatch' {
        $parameter = $script:BuilderAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'StrictVerify'
        }
        $parameter.StaticType | Should -Be ([switch])
        $parameter.DefaultValue | Should -BeNullOrEmpty
        $script:RefreshPolicy.Count | Should -Be 1
        $script:RefreshPolicy[0].Right.Extent.Text | Should -Be '-not $StrictVerify'
        $dispatches = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @('Invoke-ImagePreparation', 'Invoke-DriverPreparation', 'Invoke-UsbValidation')
        }, $true)
        $dispatches.Count | Should -Be 3
        foreach ($dispatch in $dispatches) {
            $script:RefreshPolicy[0].Extent.EndOffset | Should -BeLessThan $dispatch.Extent.StartOffset
        }
        $source = $script:BuilderAst.Extent.Text
        $source | Should -Match 'Get-CachedFileHash -Path \$srcWinpeWim.*-TrustMetadata:\$FastRefresh'
    }
    It 'propagates the policy through hashing, artifact verification and every media sync' {
        $calls = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @('Get-CachedFileHash', 'Get-ContentTreeHash', 'Test-WinPECacheImage', 'Sync-BuildFiles')
        }, $true)
        foreach ($call in $calls) {
            if ($call.GetCommandName() -in @('Test-WinPECacheImage', 'Sync-BuildFiles')) {
                $call.Extent.Text | Should -Match '-FastRefresh:\$FastRefresh'
            }
            elseif ($call.Extent.Text -notmatch '-TrustMetadata') {
                # Only fresh archive/WIM publication hashes intentionally ignore metadata.
                $call.Extent.Text | Should -Match '-Path \$(archivePath|Path) -ReceiptDirectory'
            }
            else {
                $call.Extent.Text | Should -Match '-TrustMetadata:\$(FastRefresh|TrustMetadata)'
            }
        }
        (Get-Command Invoke-DriverArchive).Definition | Should -Match '-UseMetadataReceipt:\$FastRefresh'
    }
    It 'explicitly propagates the refresh policy to every WIM and driver archive build' {
        $calls = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @('Invoke-WinPEImageBuild', 'Invoke-DriverArchive')
        }, $true)
        $calls.Count | Should -Be 6
        foreach ($call in $calls) {
            $call.Extent.Text | Should -Match '-FastRefresh:\$FastRefresh'
        }
    }
    It 'inventories the returned WIM source for USB capacity checks and stages it for ISO only' {
        $source = $script:BuilderAst.Extent.Text
        $source | Should -Match '\$bootWimSource = Invoke-WinPEImageBuild'
        $source | Should -Match 'RelativePath = ''sources/boot.wim''; Length = \(Get-Item -LiteralPath \$bootWimSource\).Length; SourcePath = \$bootWimSource'
        $source | Should -Match '(?s)\$bootFiles = @\(Get-MediaFileInventory.*?Where-Object \{ \(ConvertTo-BuildRelativePath \$_.RelativePath\) -ne ''sources/boot.wim'' \}\) \+ @\(\$bootWimFile\)'
        $source | Should -Match '(?s)if \(\$PSCmdlet.ParameterSetName -eq ''ISO''\) \{\s+if \(\$bootWimSource -ne \$bootWim\) \{\s+Sync-BuildFiles -Files @\(\$bootWimFile\) -Destination \$mediaDir'
    }
    It 'injects boot drivers for ISO and USB, not just USB' {
        $calls = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-WinPEImageBuild'
        }, $true)
        $calls.Count | Should -Be 1
        $calls[0].Extent.Text | Should -Match '-DriverPath \$winpeDrivers'
        $parent = $calls[0].Parent
        while ($parent -and $parent -ne $script:BuilderAst) {
            $parent | Should -Not -BeOfType ([System.Management.Automation.Language.IfStatementAst])
            $parent = $parent.Parent
        }
    }
    It 'does not contain global mount cleanup, registry deletion or service restarts' {
        $source = $script:BuilderAst.Extent.Text
        $source | Should -Not -Match '/Cleanup-Mountpoints|Restart-Service|reg delete|WIMMount\\Mounted Images'
    }
    It 'uses a new workspace for every invocation instead of reusing stale payload' {
        $assignment = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$WorkDir'
        }, $true)
        ($assignment.Right.Extent.Text -join "`n") | Should -Match 'AutoReset-Build-.*NewGuid'
    }
    It 'keeps the required runtime packages and drops only the unused DISM PowerShell package' {
        $packages = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$packages'
        }, $true)
        foreach ($package in @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI')) {
            $packages[0].Right.Extent.Text | Should -Match ([regex]::Escape($package))
        }
        $packages[0].Right.Extent.Text | Should -Not -Match 'WinPE-DismCmdlets'
        (Get-Command Clear-StaleMounts).Definition | Should -Match 'Get-WindowsImage -Mounted'
    }
    It 'keeps the base recipe independent of runtime sources and the whole-builder hash' {
        $parts = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$baseParts'
        }, $true)
        $recipe = $parts.Right.Extent.Text -join "`n"
        $recipe | Should -Match 'Invoke-WinPEBaseServicing'
        $recipe | Should -Match 'Get-ContentTreeHash -Path \$winpeDrivers'
        $recipe | Should -Not -Match 'MyInvocation|runtime|Copy-|Sync-|WinPEResolution'
    }
    It 'does not route USB file refreshes through unconditional robocopy writes' {
        $calls = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-Robocopy'
        }, $true)
        ($calls.Extent.Text -join "`n") | Should -Not -Match '\$bootDrive|\$payloadDrive|\$mediaImages|\$mediaDrivers'
        $syncs = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Sync-BuildFiles'
        }, $true)
        @($syncs | Where-Object { $_.Extent.Text -match '-Files \$bootFiles -Destination \$bootDrive' }).Count | Should -Be 2
        foreach ($sync in ($syncs | Where-Object { $_.Extent.Text -match '\$bootDrive' })) {
            $sync.Extent.Text | Should -Not -Match '-Mirror'
        }
    }
    It 'has no selectable archive compression or raw-driver early return' {
        (Get-Command Invoke-DriverArchive).Parameters.Keys | Should -Not -Contain 'Compression'
        $script:BuilderAst.Extent.Text | Should -Not -Match '\$DriverCompression|\$NoZip|\$Compression\b'
        (Get-Command Invoke-DriverPreparation).Definition | Should -Not -Match 'Using raw drivers'
    }
    It 'stops output timing after every output branch without detaching an else clause' {
        $commands = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)
        @($commands | Where-Object { $_.GetCommandName() -eq 'else' }).Count | Should -Be 0
        $stops = @($commands | Where-Object { $_.Extent.Text -eq "Stop-BuildPhase 'output'" })
        $stops.Count | Should -Be 1
        $parent = $stops[0].Parent
        while ($parent -and $parent -ne $script:BuilderAst) {
            $parent | Should -Not -BeOfType ([System.Management.Automation.Language.IfStatementAst])
            $parent = $parent.Parent
        }
    }
}

Describe 'Build timing output' {
    BeforeEach {
        $script:BuildPhases = @{}
        Mock Write-BuildLog { }
    }
    It 'logs phase elapsed time without contaminating function pipeline results' {
        @(Start-BuildPhase 'copy').Count | Should -Be 0
        @(Stop-BuildPhase 'copy').Count | Should -Be 0
        Should -Invoke Write-BuildLog -Times 1 -Exactly -ParameterFilter { $Text -like 'Timing copy:*s' }
        $script:BuildPhases.Count | Should -Be 0
    }
}
