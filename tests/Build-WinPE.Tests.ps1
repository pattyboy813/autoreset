BeforeAll {
    $script:BuilderPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Build-WinPE.ps1'
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
        $script:PayloadSource = Join-Path $TestDrive 'Payload'
        New-Item -ItemType Directory -Path $script:Sources, (Join-Path $script:PayloadSource 'Config') -Force | Out-Null
        foreach ($name in @('Invoke-AutoReset.ps1', 'Invoke-KillDisk.ps1', 'AutoReset.Common.ps1', 'AutoReset.UI.ps1')) {
            Set-Content -LiteralPath (Join-Path $script:Sources $name) -Value "# $name"
        }
        Set-Content -LiteralPath (Join-Path $script:PayloadSource 'Config/reset.json') -Value '{"ConfirmBeforeWipe":true}'
    }
    It 'requires the four explicit repository-root runtime files' {
        @(Get-RuntimeSourceFiles -Root $script:Sources).Count | Should -Be 4
        Remove-Item -LiteralPath (Join-Path $script:Sources 'AutoReset.Common.ps1')
        { Get-RuntimeSourceFiles -Root $script:Sources } | Should -Throw '*Required runtime source missing*'
    }
    It 'rejects a missing installation image unless SkipPayload is explicit' {
        $missing = Join-Path $TestDrive 'missing.wim'
        { Assert-BuildPayload -PayloadSource $script:PayloadSource -InstallImage $missing } | Should -Throw '*Installation image missing*'
        { Assert-BuildPayload -PayloadSource $script:PayloadSource -InstallImage $missing -BootOnly } | Should -Not -Throw
    }
    It 'rejects invalid configuration even for boot-only builds' {
        Set-Content -LiteralPath (Join-Path $script:PayloadSource 'Config/reset.json') -Value '{broken'
        { Assert-BuildPayload -PayloadSource $script:PayloadSource -BootOnly } | Should -Throw
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
        $source = Join-Path $script:Sources 'AutoReset.UI.ps1'
        $text = '$label = "' + [char]0x2192 + '"'
        [IO.File]::WriteAllText($source, $text, [Text.UTF8Encoding]::new($false))
        $dest = Join-Path $TestDrive 'unicode-bundle'
        Sync-RuntimePayload -Destination $dest -RuntimeFiles @(Get-RuntimeSourceFiles -Root $script:Sources) -PayloadSource $script:PayloadSource
        foreach ($scriptFile in Get-ChildItem -LiteralPath (Join-Path $dest 'Scripts') -File) {
            [byte[]]$bytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
            @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        }
        [IO.File]::ReadAllText((Join-Path $dest 'Scripts/AutoReset.UI.ps1')) | Should -Be $text
        [IO.File]::ReadAllBytes($source)[0] | Should -Not -Be 0xEF
    }
    It 'does not duplicate an existing runtime BOM' {
        $source = Join-Path $script:Sources 'AutoReset.UI.ps1'
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
        $config = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'Payload/Config/reset.json') -Raw | ConvertFrom-Json
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
    It 'tests both fresh and cached 7z archives using the bundled extractor' {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') {
                [IO.File]::WriteAllText($ArgumentList[-2], 'archive')
            }
        }
        $archive = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        $archive | Should -BeLike '*.7z'
        $null = Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir
        Should -Invoke Invoke-Tool -Times 2 -ParameterFilter { $ArgumentList[0] -eq 't' -and $FilePath -eq $script:RuntimeExtractor }
        Should -Invoke Invoke-Tool -Times 1 -ParameterFilter { $ArgumentList[0] -eq 'a' }
    }
    It 'fails before publishing an archive the runtime cannot extract' {
        $script:RuntimeExtractor = Join-Path $TestDrive '7za.exe'
        Mock Invoke-Tool {
            if ($ArgumentList[0] -eq 'a') { [IO.File]::WriteAllText($ArgumentList[-2], 'archive') }
            else { throw 'runtime cannot extract archive' }
        }
        { Invoke-DriverArchive -SourcePath $script:DriverSource -ArchiveDir $script:ArchiveDir } |
            Should -Throw '*runtime cannot extract*'
        Test-Path -LiteralPath (Join-Path $script:ArchiveDir 'Drivers.7z') | Should -BeFalse
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
    }
    It 'generates Display only when explicitly requested' {
        Set-WinPEStartup -System32Path $TestDrive -Resolution '1280x720'
        [xml]$xml = Get-Content -LiteralPath (Join-Path $TestDrive 'winpe-unattend.xml') -Raw
        $xml.unattend.settings.component.Display.HorizontalResolution | Should -Be '1280'
        $xml.unattend.settings.component.Display.VerticalResolution | Should -Be '720'
        Get-Content -LiteralPath (Join-Path $TestDrive 'winpeshl.ini') -Raw | Should -Match 'unattend'
    }
    It 'removes a stale explicit resolution when returning to defaults' {
        Set-WinPEStartup -System32Path $TestDrive -Resolution '1920x1200'
        Set-WinPEStartup -System32Path $TestDrive
        Test-Path -LiteralPath (Join-Path $TestDrive 'winpe-unattend.xml') | Should -BeFalse
    }
}

Describe 'Build orchestration regression guards' {
    It 'injects boot drivers for ISO and USB, not just USB' {
        $assignment = $script:BuilderAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$injectWinpeDrivers'
        }, $true)
        $assignment.Count | Should -Be 1
        $assignment[0].Right.Extent.Text | Should -Be '$true'
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
}
