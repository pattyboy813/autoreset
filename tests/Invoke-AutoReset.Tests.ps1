BeforeAll {
    $source = Join-Path $PSScriptRoot '..\Invoke-AutoReset.ps1'
    $script:ParseErrors = $null
    $script:DeploymentAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $source, [ref]$null, [ref]$script:ParseErrors)
    $script:DeploymentSource = Get-Content -LiteralPath $source -Raw
    # Load only function definitions and inert step declarations, never the GUI entry point.
    $names = @(
        'Assert-RelativePayloadPath', 'Assert-Configuration', 'Get-Config', 'Resolve-MediaFile',
        'Get-InitialTargetDisk', 'Assert-DeploymentLettersAvailable', 'Assert-TargetPartitions',
        'Get-DeploymentImage', 'Assert-ArchiveEntryPath', 'Assert-DriverArchiveUnchanged', 'Expand-ValidatedDriverArchive',
        'Get-PreparedDrivers', 'Invoke-DeploymentPreflight', 'Invoke-CheckedTool',
        'Assert-TargetBootConfiguration', 'Install-RecoveryFirstBootHook', 'Copy-LogsToTarget',
        'Invoke-KillDiskProcess', 'Select-DeploymentMediaRoot', 'Find-MediaRoot',
        'Get-DeploymentSourceIdentity', 'Assert-DeploymentSourceUnchanged', 'Title'
    )
    foreach ($definition in $script:DeploymentAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)) {
        if ($definition.Name -in $names) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
    $stepAssignment = $script:DeploymentAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$steps'
    }, $true)
    . ([scriptblock]::Create($stepAssignment.Extent.Text))
    $script:DeploymentSteps = $steps
    function Assert-WinPEEnvironment { }
    function Get-DeploymentMediaDiskNumbers { }
    function Test-EligibleTargetDisk { param($Disk, $ProtectedDiskNumbers) }
    function Get-DiskIdentity { param($Disk) }
    function Assert-TargetDiskSafe { param($DiskNumber, $ExpectedIdentity, $ProtectedDiskNumbers) }
    function Get-Disk { param($Number) }
    function Get-Partition { param($DriveLetter, $Volume) }
    function Get-Volume { param($DriveLetter) }
    function Get-CimInstance { param($ClassName, $Filter) }
    function Invoke-External { param($FilePath, $Arguments, $What, [switch]$ParsePercent) }
    function Write-Log { param($Message, $Level) }
}

Describe 'KillDisk child process result' {
    BeforeEach {
        Mock Write-Log { }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'waits for and verifies the child result' {
        { Invoke-KillDiskProcess -ScriptPath 'Invoke-KillDisk.ps1' -Serial 'TEST' } | Should -Not -Throw
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $Wait -and $PassThru }
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -eq 'KillDisk process exit code: 0' }
    }
    It 'propagates a failed or unavailable child exit code' -TestCases @(
        @{ Code = 1 }, @{ Code = 42 }, @{ Code = $null }
    ) {
        param($Code)
        $script:ChildExitCode = $Code
        Mock Start-Process { [pscustomobject]@{ ExitCode = $script:ChildExitCode } }
        { Invoke-KillDiskProcess -ScriptPath 'Invoke-KillDisk.ps1' -Serial 'TEST' } |
            Should -Throw '*KillDisk did not complete successfully*'
    }
}

Describe 'Deployment structure and shared UI integration' {
    It 'parses without errors' { $script:ParseErrors.Count | Should -Be 0 }
    It 'loads shared helpers relative to its deployed script' {
        $script:DeploymentSource | Should -Match "\. \(Join-Path \`$PSScriptRoot 'AutoReset.Common.ps1'\)"
        $script:DeploymentSource | Should -Match "\. \(Join-Path \`$PSScriptRoot 'AutoReset.UI.ps1'\)"
    }
    It 'uses shared form and disk-list layout rather than duplicate sizing functions' {
        $script:DeploymentSource | Should -Not -Match 'function (Set-FormSize|UiFont)\s'
        $script:DeploymentSource | Should -Match 'New-ResetForm -Title \(Title \$TitleSuffix\)'
        $script:DeploymentSource | Should -Match "'Disk Selection' -Width 800 -MinimumHeight 450"
        $script:DeploymentSource | Should -Match 'Initialize-DiskList -List \$list -RowCount'
    }
    It 'runs preflight before its only destructive deployment step' {
        $script:DeploymentSteps[0].Name | Should -Be 'Preflight'
        $script:DeploymentSteps[1].Name | Should -Be 'Wipe and Partition'
    }
    It 'does not offer a reboot disguised as a retry or block ISO restarts' {
        $script:DeploymentSource | Should -Not -Match 'Try Again|errorRetryTimer|usbTimer|Remove USB first'
        $script:DeploymentSource | Should -Match 'eject/disconnect the ISO'
        $script:DeploymentSource | Should -Match 'Bootability and OOBE still require'
    }
    It 'logs the deployed script path and SHA256' {
        $script:DeploymentSource | Should -Match 'Running script: \$PSCommandPath \| SHA256'
    }
}

Describe 'Respawn display branding' {
    It 'uses the requested main window title' {
        Title | Should -Be "Respawn $([char]0x2014) Windows Deployment"
        Title -Suffix '' | Should -Be "Respawn $([char]0x2014) Windows Deployment"
    }
    It 'keeps stage captions under the Respawn window title' -ForEach @(
        @{ Suffix = 'Preparing...' }, @{ Suffix = 'Disk Selection' },
        @{ Suffix = 'Complete!' }, @{ Suffix = 'Error' }
    ) {
        Title -Suffix $Suffix | Should -Be "Respawn $([char]0x2014) Windows Deployment | $Suffix"
    }
    It 'uses Respawn in prompts, failures and completion messages' {
        foreach ($message in @(
            'Preparing Respawn and gathering info...',
            'Respawn has found the following disk to re-install Windows to:',
            'Respawn media not found.', 'Respawn stopped.', 'Respawn error',
            'Respawn has encountered an error', 'Respawn completed successfully',
            'Respawn FAILED'
        )) {
            $script:DeploymentSource | Should -Match ([regex]::Escape($message))
        }
        $script:DeploymentSource | Should -Not -Match 'AutoReset (v|stopped|error|media not found|has found|has encountered|completed|FAILED)|Preparing AutoReset'
    }
    It 'retains legacy log and recovery paths for support compatibility' {
        foreach ($path in @('AutoReset.log', 'AutoReset-Detail.log', 'AutoReset-EnableWinRE.ps1', 'AutoReset-WinRE.log')) {
            $script:DeploymentSource | Should -Match ([regex]::Escape($path))
        }
    }
    It 'keeps the KillDisk child script name and shortcut' {
        $script:DeploymentSource | Should -Match 'Scripts\\Invoke-KillDisk\.ps1'
        $script:DeploymentSource | Should -Match 'Ctrl\+Shift\+W'
    }
}

Describe 'Unambiguous deployment source selection' {
    BeforeEach {
        $script:SourceOne = Join-Path $TestDrive 'media-one'
        $script:SourceTwo = Join-Path $TestDrive 'media-two'
        Mock Test-Path { $true }
    }
    It 'selects exactly one ready external marker root' {
        $drives = @([pscustomobject]@{ Name = $script:SourceOne; IsReady = $true; DriveType = 'Removable' })
        Select-DeploymentMediaRoot -Drives $drives | Should -Be (Join-Path $script:SourceOne 'Payload')
    }
    It 'rejects multiple deployment sticks or ISO sources instead of picking the first' {
        $drives = @(
            [pscustomobject]@{ Name = $script:SourceOne; IsReady = $true; DriveType = 'Removable' },
            [pscustomobject]@{ Name = $script:SourceTwo; IsReady = $true; DriveType = 'CDRom' }
        )
        { Select-DeploymentMediaRoot -Drives $drives } | Should -Throw '*Multiple deployment media*Detach unused*'
    }
    It 'ignores the X RAM source even if it contains a baked marker' {
        $drives = @(
            [pscustomobject]@{ Name = 'X:\'; IsReady = $true; DriveType = 'Fixed' },
            [pscustomobject]@{ Name = $script:SourceOne; IsReady = $true; DriveType = 'CDRom' }
        )
        Select-DeploymentMediaRoot -Drives $drives | Should -Be (Join-Path $script:SourceOne 'Payload')
        Should -Invoke Test-Path -Times 1
    }
    It 'ignores unreadable drives and RAM disks with other letters' {
        $drives = @(
            [pscustomobject]@{ Name = $script:SourceOne; IsReady = $false; DriveType = 'Removable' },
            [pscustomobject]@{ Name = $script:SourceTwo; IsReady = $true; DriveType = 'Ram' }
        )
        { Select-DeploymentMediaRoot -Drives $drives } | Should -Throw '*No ready external deployment medium*'
        Should -Invoke Test-Path -Times 0
    }
    It 'rejects empty inventory or missing marker roots' {
        { Select-DeploymentMediaRoot -Drives @() } | Should -Throw '*No ready external deployment medium*'
        Mock Test-Path { $false }
        $drives = @([pscustomobject]@{ Name = $script:SourceOne; IsReady = $true; DriveType = 'Removable' })
        { Select-DeploymentMediaRoot -Drives $drives } | Should -Throw '*No ready external deployment medium*'
    }
}

Describe 'Strict configuration validation' {
    It 'accepts typed settings and null optional disk/index values' {
        { Assert-Configuration ('{"ConfirmBeforeWipe":false,"DriversRequired":true,"ImageIndex":null,"TargetDiskNumber":0,"DriverMap":[{"Match":"Latitude","Folder":"Dell/Latitude"}]}' | ConvertFrom-Json) } |
            Should -Not -Throw
    }
    It 'rejects nonobject configurations' -TestCases @(
        @{ Json = 'null' }, @{ Json = '[]' }, @{ Json = '"wrong"' }, @{ Json = 'true' }
    ) {
        param($Json)
        { Assert-Configuration ($Json | ConvertFrom-Json) } | Should -Throw '*JSON object*'
    }
    It 'rejects unsafe setting types' -TestCases @(
        @{ Json = '{"ConfirmBeforeWipe":"false"}' }, @{ Json = '{"DriversRequired":null}' },
        @{ Json = '{"ContinueOnDriverError":1}' }, @{ Json = '{"SetupRecovery":"true"}' },
        @{ Json = '{"TargetDiskNumber":"0"}' }, @{ Json = '{"TargetDiskNumber":-1}' },
        @{ Json = '{"ImageIndex":0}' }, @{ Json = '{"ImageIndex":1.5}' },
        @{ Json = '{"ImageFile":true}' }, @{ Json = '{"ImageEdition":""}' },
        @{ Json = '{"DriverMap":{}}' }, @{ Json = '{"DriverMap":[{"Match":"","Folder":"Dell"}]}' },
        @{ Json = '{"DriverMap":[{"Match":"Dell","Folder":"../escape"}]}' }
    ) {
        param($Json)
        { Assert-Configuration ($Json | ConvertFrom-Json) } | Should -Throw
    }
    It 'rejects traversal, absolute paths, and command-line quoting' -TestCases @(
        @{ Path = '..\escape' }, @{ Path = 'C:\image.wim' }, @{ Path = '\\server\share' },
        @{ Path = 'Images\bad".wim' }, @{ Path = 'Drivers/../escape' }, @{ Path = 'Drivers/*' },
        @{ Path = 'Drivers/.. /escape' }
    ) {
        param($Path)
        { Assert-RelativePayloadPath $Path } | Should -Throw
    }
}

Describe 'Safe initial disk selection' {
    BeforeEach {
        Mock Test-EligibleTargetDisk { $Disk.Number -notin $ProtectedDiskNumbers -and $Disk.BusType -eq 'NVMe' }
        $script:Disks = @(
            [pscustomobject]@{ Number = [uint32]0; BusType = 'NVMe'; Size = 100GB },
            [pscustomobject]@{ Number = [uint32]1; BusType = 'NVMe'; Size = 900GB },
            [pscustomobject]@{ Number = [uint32]2; BusType = 'USB'; Size = 1TB }
        )
    }
    It 'requires explicit selection with multiple eligible disks, not the largest disk' {
        Get-InitialTargetDisk -Disks $script:Disks -ProtectedDiskNumbers @() | Should -BeNullOrEmpty
    }
    It 'selects the sole eligible disk and excludes deployment media' {
        (Get-InitialTargetDisk -Disks $script:Disks -ProtectedDiskNumbers @(1)).Number | Should -Be 0
    }
    It 'applies eligibility to a configured target' -TestCases @(@{ Number = 1 }, @{ Number = 2 }, @{ Number = 9 }) {
        param($Number)
        { Get-InitialTargetDisk -Disks $script:Disks -ProtectedDiskNumbers @(1) -ConfiguredNumber $Number } |
            Should -Throw '*missing or unsafe*'
    }
    It 'accepts an explicit eligible disk zero' {
        (Get-InitialTargetDisk -Disks $script:Disks -ProtectedDiskNumbers @() -ConfiguredNumber 0).Number | Should -Be 0
    }
}

Describe 'Image preflight' {
    BeforeEach {
        $script:ConfigJson = [pscustomobject]@{ ImageEdition = 'Windows 11 Enterprise' }
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Mock Resolve-MediaFile { 'install.wim' }
        Mock Test-Path { $true }
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'readable-image' } }
        Mock Write-Log { }
        Mock Invoke-External {
            if ($Arguments -match '/Index:') {
                [pscustomobject]@{ ExitCode = 0; Output = "Size : 32,212,254,720 bytes`nArchitecture : x64" }
            }
            else { [pscustomobject]@{ ExitCode = 0; Output = "Index : 1`nName : Windows 11 Enterprise" } }
        }
    }
    It 'uses the expanded size and English DISM metadata' {
        $image = Get-DeploymentImage
        $image.ExpandedBytes | Should -Be 30GB
        $image.Index | Should -Be 1
        Should -Invoke Invoke-External -Times 2 -ParameterFilter { $Arguments -match '/English /Get-WimInfo' }
        Should -Invoke Get-FileHash -Times 1
    }
    It 'defaults to the same Windows edition as the image builder' {
        $script:ConfigJson = $null
        Mock Invoke-External {
            if ($Arguments -match '/Index:') {
                [pscustomobject]@{ ExitCode = 0; Output = "Size : 32,212,254,720 bytes`nArchitecture : x64" }
            }
            else { [pscustomobject]@{ ExitCode = 0; Output = "Index : 1`nName : Windows 11 Pro" } }
        }
        (Get-DeploymentImage).Edition | Should -Be 'Windows 11 Pro'
    }
    It 'rejects unreadable image content before DISM or wipe' {
        Mock Get-FileHash { throw 'read error' }
        { Get-DeploymentImage } | Should -Throw '*read error*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'rejects a nonexistent explicit image index' {
        $script:ConfigJson | Add-Member ImageIndex 7
        { Get-DeploymentImage } | Should -Throw '*does not uniquely match*'
    }
    It 'never falls back to a wrong single-image edition' {
        $script:ConfigJson.ImageEdition = 'Windows 11 Pro'
        { Get-DeploymentImage } | Should -Throw '*does not uniquely match*'
    }
    It 'rejects missing expanded metadata instead of using compressed file size' {
        Mock Invoke-External {
            if ($Arguments -match '/Index:') { [pscustomobject]@{ ExitCode = 0; Output = 'Architecture : x64' } }
            else { [pscustomobject]@{ ExitCode = 0; Output = "Index : 1`nName : Windows 11 Enterprise" } }
        }
        { Get-DeploymentImage } | Should -Throw '*expanded image size*'
    }
    It 'rejects an architecture mismatch' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        { Get-DeploymentImage } | Should -Throw '*does not match WinPE*'
    }
}

Describe 'Preflight failure gates' {
    BeforeEach {
        $script:IsUefi = $true
        $script:TargetIdentity = 'stable-disk'
        $script:TargetDisk = [pscustomobject]@{ Number = [uint32]0; Size = 100GB }
        $script:MediaRoot = 'D:\Payload'
        Mock Assert-WinPEEnvironment { }
        Mock Get-Command { [pscustomobject]@{ Name = 'available' } }
        Mock Get-DeploymentMediaDiskNumbers { @(3) }
        Mock Assert-TargetDiskSafe { $script:TargetDisk }
        Mock Assert-DeploymentLettersAvailable { }
        Mock Find-MediaRoot { 'D:\Payload' }
        Mock Get-DeploymentSourceIdentity { 'source-volume-and-disk' }
        Mock Resolve-MediaFile { $null }
        Mock Get-DeploymentImage { [pscustomobject]@{ ExpandedBytes = 30GB } }
        Mock Get-PreparedDrivers { [pscustomobject]@{ Path = 'drivers'; Count = 1 } }
        Mock Invoke-External { throw 'Preflight must not run destructive tools.' }
    }
    It 'requires WinPE before inspecting tools or media' {
        Mock Assert-WinPEEnvironment { throw 'Not WinPE' }
        { Invoke-DeploymentPreflight } | Should -Throw '*Not WinPE*'
        Should -Invoke Get-DeploymentImage -Times 0
    }
    It 'checks all prerequisites without invoking any wipe' {
        $preflight = Invoke-DeploymentPreflight
        $preflight.RequiredBytes | Should -BeGreaterThan 40GB
        $preflight.Source.Root | Should -Be 'D:\Payload'
        $preflight.Source.Identity | Should -Be 'source-volume-and-disk'
        Should -Invoke Assert-TargetDiskSafe -Times 1 -ParameterFilter {
            $DiskNumber -eq 0 -and $ExpectedIdentity -eq 'stable-disk' -and $ProtectedDiskNumbers -contains 3
        }
        Should -Invoke Invoke-External -Times 0
    }
    It 'rejects a missing tool' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'diskpart.exe' }
        { Invoke-DeploymentPreflight } | Should -Throw '*diskpart.exe*unavailable*'
        Should -Invoke Get-DeploymentImage -Times 0
    }
    It 'rejects insufficient expanded-image capacity' {
        $script:TargetDisk.Size = 35GB
        { Invoke-DeploymentPreflight } | Should -Throw '*capacity is insufficient*'
        Should -Invoke Get-PreparedDrivers -Times 0
    }
    It 'includes expanded driver staging in target capacity before wiping' {
        Mock Get-PreparedDrivers { [pscustomobject]@{ ExpandedBytes = 80GB; Archive = 'Drivers.7z' } }
        { Invoke-DeploymentPreflight } | Should -Throw '*driver staging*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'rejects media mapping failure' {
        Mock Get-DeploymentMediaDiskNumbers { throw 'Cannot map deployment media' }
        { Invoke-DeploymentPreflight } | Should -Throw '*Cannot map*'
    }
    It 'requires the legacy boot-sector tool' {
        $script:IsUefi = $false
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'bootsect.exe' }
        { Invoke-DeploymentPreflight } | Should -Throw '*bootsect.exe*required*'
    }
    It 'uses the bundled boot-sector tool when WinPE does not expose it on PATH' {
        $script:IsUefi = $false
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'bootsect.exe' }
        Mock Resolve-MediaFile { 'Payload\Tools\bootsect.exe' } -ParameterFilter { $RelativePath -eq 'Tools\bootsect.exe' }
        Mock Test-Path { $true }
        (Invoke-DeploymentPreflight).Bootsect | Should -Be 'Payload\Tools\bootsect.exe'
    }
    It 'propagates driver archive validation failures without wiping' {
        Mock Get-PreparedDrivers { throw 'corrupt archive' }
        { Invoke-DeploymentPreflight } | Should -Throw '*corrupt archive*'
        Should -Invoke Invoke-External -Times 0
    }
}

Describe 'Driver requirements and archive validation' {
    BeforeEach {
        $script:DriverFolder = 'Model'
        $script:Model = 'Model'
        $script:ConfigJson = [pscustomobject]@{ DriversRequired = $false }
        $script:StepWarnings = @()
        $logRoot = $PSScriptRoot
        Mock Resolve-MediaFile { $null }
        Mock Write-Log { }
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'validated-archive' } }
        Mock Invoke-External { [pscustomobject]@{ ExitCode = 1; Output = 'corrupt' } }
    }
    It 'permits missing model drivers only when not required, with a warning' {
        Get-PreparedDrivers | Should -BeNullOrEmpty
        $script:StepWarnings.Count | Should -Be 1
    }
    It 'fails for missing required drivers' {
        $script:ConfigJson.DriversRequired = $true
        { Get-PreparedDrivers } | Should -Throw '*Required drivers are missing*'
    }
    It 'checks the 7z extraction tool before running an archive' {
        Mock Resolve-MediaFile { 'Drivers.7z' } -ParameterFilter { $RelativePath -like '*.7z' }
        { Get-PreparedDrivers } | Should -Throw '*7za.exe is required*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'rejects corrupt archive listings before extraction' {
        Mock Resolve-MediaFile { if ($RelativePath -like '*.7z') { 'Drivers.7z' } else { '7za.exe' } }
        Mock Test-Path { $true }
        { Get-PreparedDrivers } | Should -Throw '*Cannot list driver archive*'
        Should -Invoke Invoke-External -Times 0 -ParameterFilter { $Arguments -like 'x *' }
    }
    It 'rejects a traversal path from a real-format 7z listing' {
        Mock Resolve-MediaFile { if ($RelativePath -like '*.7z') { 'Drivers.7z' } else { '7za.exe' } }
        Mock Test-Path { $true }
        Mock Invoke-External {
            [pscustomobject]@{ ExitCode = 0; Output = "Path = Drivers.7z`nType = 7z`n`n----------`nPath = ../escape.inf`nSize = 100`n" }
        }
        { Get-PreparedDrivers } | Should -Throw '*Invalid relative payload path*'
        Should -Invoke Invoke-External -Times 0 -ParameterFilter { $Arguments -like 'x *' }
    }
    It 'tests archive integrity before extraction' {
        Mock Resolve-MediaFile { if ($RelativePath -like '*.7z') { 'Drivers.7z' } else { '7za.exe' } }
        Mock Test-Path { $true }
        Mock Invoke-External {
            if ($Arguments -like 'l *') {
                [pscustomobject]@{ ExitCode = 0; Output = "Path = Drivers.7z`n`n----------`nPath = driver.inf`nSize = 100`n" }
            }
            else { [pscustomobject]@{ ExitCode = 2; Output = 'CRC failed' } }
        }
        { Get-PreparedDrivers } | Should -Throw '*integrity validation failed*'
        Should -Invoke Invoke-External -Times 1 -ParameterFilter { $Arguments -like 't *' }
        Should -Invoke Invoke-External -Times 0 -ParameterFilter { $Arguments -like 'x *' }
    }
    It 'validates multi-gigabyte driver packs without extracting or requiring WinPE scratch space' {
        Mock Resolve-MediaFile { if ($RelativePath -like '*.7z') { 'Drivers.7z' } else { '7za.exe' } }
        Mock Test-Path { $true }
        Mock Get-PSDrive { throw 'WinPE scratch is only 512 MB' }
        Mock New-Item { throw 'Preflight must not extract files' }
        Mock Get-ChildItem { throw 'Preflight must not inspect an extracted folder' }
        Mock Invoke-External {
            if ($Arguments -like 'l *') {
                [pscustomobject]@{ ExitCode = 0; Output = "Path = Drivers.7z`n`n----------`nPath = driver.inf`nSize = 100`n`nPath = large.sys`nSize = 6442450944`n" }
            }
            elseif ($Arguments -like 't *') { [pscustomobject]@{ ExitCode = 0; Output = 'Everything is Ok' } }
            else { throw 'Must not extract before partitioning' }
        }
        $drivers = Get-PreparedDrivers
        $drivers.ExpandedBytes | Should -Be (6GB + 100)
        $drivers.Hash | Should -Be 'validated-archive'
        $drivers.Count | Should -Be 1
        $drivers.Path | Should -BeNullOrEmpty
        Should -Invoke Get-PSDrive -Times 0
        Should -Invoke New-Item -Times 0
        Should -Invoke Invoke-External -Times 0 -ParameterFilter { $Arguments -like 'x *' }
    }
    It 'streams ZIP entries for readability and sizes without extracting them' {
        $script:ZipArchivePath = Join-Path $TestDrive 'Drivers.zip'
        $zip = [IO.Compression.ZipFile]::Open($script:ZipArchivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry('driver.inf')
            $stream = $entry.Open()
            try { $stream.WriteByte(65) } finally { $stream.Dispose() }
            $entry = $zip.CreateEntry('large.sys')
            $stream = $entry.Open()
            try {
                $buffer = New-Object byte[] 65536
                for ($i = 0; $i -lt 128; $i++) { $stream.Write($buffer, 0, $buffer.Length) }
            }
            finally { $stream.Dispose() }
        }
        finally { $zip.Dispose() }
        Mock Resolve-MediaFile { if ($RelativePath -like '*.zip') { $script:ZipArchivePath } }
        Mock Get-PSDrive { throw 'No scratch available' }
        Mock Get-ChildItem { throw 'Must not extract a ZIP during preflight' }
        $drivers = Get-PreparedDrivers
        $drivers.Count | Should -Be 1
        $drivers.ExpandedBytes | Should -Be (8MB + 1)
        $drivers.Archive | Should -Be $script:ZipArchivePath
        Should -Invoke Get-ChildItem -Times 0
        Should -Invoke Get-PSDrive -Times 0
    }
    It 'rejects unsafe archive entry paths' -TestCases @(
        @{ Path = '../escape.inf' }, @{ Path = '/absolute.inf' }, @{ Path = 'C:\escape.inf' },
        @{ Path = 'drivers/../../escape.inf' }
    ) {
        param($Path)
        { Assert-ArchiveEntryPath $Path } | Should -Throw
    }
}

Describe 'Fixed drive-letter collision checks' {
    BeforeEach {
        Mock Get-Partition { @() }
        Mock Get-Volume { @() }
        Mock Get-PSDrive { $null }
        Mock Test-Path { $false }
    }
    It 'permits only completely unused letters' {
        { Assert-DeploymentLettersAvailable } | Should -Not -Throw
    }
    It 'rejects existing partitions using any deployment letter' -TestCases @(
        @{ Letter = 'S' }, @{ Letter = 'W' }, @{ Letter = 'R' }
    ) {
        param($Letter)
        $script:CollisionLetter = $Letter
        Mock Get-Partition { [pscustomobject]@{ DriveLetter = $script:CollisionLetter } }
        { Assert-DeploymentLettersAvailable } | Should -Throw "*${Letter}: is already in use*"
    }
    It 'rejects an optical or mounted volume even without a disk partition mapping' {
        Mock Get-Volume { [pscustomobject]@{ DriveLetter = 'S' } }
        { Assert-DeploymentLettersAvailable } | Should -Throw '*S: is already in use*'
    }
    It 'fails closed when volume enumeration fails' {
        Mock Get-Volume { throw 'Storage provider failed' }
        { Assert-DeploymentLettersAvailable } | Should -Throw '*Storage provider failed*'
    }
}

Describe 'Partition ownership and immediate prewipe revalidation' {
    BeforeEach {
        $script:IsUefi = $true
        $script:TargetDisk = [pscustomobject]@{ Number = [uint32]0; Size = 100GB }
        $script:TargetIdentity = 'stable-disk'
        $script:ConfigJson = $null
        $script:Preflight = [pscustomobject]@{ Image = 'validated' }
        $logRoot = $PSScriptRoot
        Mock Write-Log { }
        Mock Set-Content { }
        Mock Get-DeploymentMediaDiskNumbers { @(3) }
        Mock Assert-WinPEEnvironment { }
        Mock Assert-DeploymentLettersAvailable { }
        Mock Assert-DeploymentSourceUnchanged { }
        Mock Assert-TargetDiskSafe { $script:TargetDisk }
        Mock Invoke-External { [pscustomobject]@{ ExitCode = 0 } }
        Mock Assert-TargetPartitions { }
    }
    It 'refuses to partition without completed preflight' {
        $script:Preflight = $null
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*Preflight has not completed*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'stops when target identity changes immediately before diskpart' {
        Mock Assert-TargetDiskSafe { throw 'identity changed' }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*identity changed*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'stops when media mapping changes immediately before diskpart' {
        Mock Get-DeploymentMediaDiskNumbers { throw 'media mapping failed' }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*media mapping failed*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'checks letter collisions again just before partitioning' {
        Mock Assert-DeploymentLettersAvailable { throw 'S: in use' }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*S: in use*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'rechecks the selected archive hash before any erase command' {
        $script:Preflight | Add-Member Drivers ([pscustomobject]@{ Archive = 'Drivers.7z'; Hash = 'original' })
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'changed' } }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*driver archive changed*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'explicitly converts a GPT source disk to MBR for legacy firmware' {
        $script:IsUefi = $false
        & $script:DeploymentSteps[1].Action
        Should -Invoke Set-Content -Times 1 -ParameterFilter { $Value -match '(?s)clean\s+convert mbr' }
        Should -Invoke Assert-TargetPartitions -Times 1
    }
    It 'keeps target revalidation last after source checks and immediately before diskpart' {
        $script:GateOrder = [System.Collections.Generic.List[string]]::new()
        Mock Assert-DeploymentSourceUnchanged { $script:GateOrder.Add('source') }
        Mock Assert-TargetDiskSafe { $script:GateOrder.Add('target'); $script:TargetDisk }
        Mock Invoke-External { $script:GateOrder.Add('diskpart'); [pscustomobject]@{ ExitCode = 0 } }
        & $script:DeploymentSteps[1].Action
        ($script:GateOrder -join ',') | Should -Be 'source,target,diskpart'
    }
}

Describe 'Deployment source medium fingerprint' {
    BeforeEach {
        Mock Get-Volume {
            [pscustomobject]@{ UniqueId = '\\?\Volume{original}'; FileSystemLabel = 'PAYLOAD'; Size = 16GB; FileSystem = 'NTFS' }
        }
        Mock Get-CimInstance { [pscustomobject]@{ VolumeSerialNumber = '1234ABCD'; DriveType = 2 } }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [uint32]3 } }
        Mock Get-Disk { [pscustomobject]@{ Number = [uint32]3 } }
        Mock Get-DiskIdentity { 'physical-media-identity' }
    }
    It 'captures both unique volume and physical disk identities for USB media' {
        $identity = Get-DeploymentSourceIdentity -MediaRoot 'D:\Payload' | ConvertFrom-Json
        $identity.Volume | Should -Be '\\?\Volume{original}'
        $identity.Serial | Should -Be '1234ABCD'
        $identity.Disks | Should -Contain 'physical-media-identity'
        Should -Invoke Get-Partition -Times 1 -ParameterFilter { $null -ne $Volume }
    }
    It 'handles read-only optical media without requiring a physical-disk mapping or writes' {
        Mock Get-CimInstance { [pscustomobject]@{ VolumeSerialNumber = 'ABCD1234'; DriveType = 5 } }
        Mock Get-Partition { throw 'Optical volumes have no MSFT_Disk partition' }
        Mock Set-Content { throw 'Optical media is read-only' }
        $identity = Get-DeploymentSourceIdentity -MediaRoot 'D:\Payload' | ConvertFrom-Json
        $identity.Serial | Should -Be 'ABCD1234'
        $identity.DriveType | Should -Be '5'
        $identity.Disks.Count | Should -Be 0
        Should -Invoke Get-Partition -Times 0
        Should -Invoke Set-Content -Times 0
    }
    It 'rejects a source volume with an unavailable physical mapping' {
        Mock Get-Partition { @() }
        { Get-DeploymentSourceIdentity -MediaRoot 'D:\Payload' } | Should -Throw '*Cannot map*'
    }
    It 'rejects an unidentified source volume' {
        Mock Get-Volume { [pscustomobject]@{ UniqueId = '' } }
        { Get-DeploymentSourceIdentity -MediaRoot 'D:\Payload' } | Should -Throw '*Cannot uniquely identify*'
    }
}

Describe 'Source and full image revalidation before wipe without drivers' {
    BeforeEach {
        $script:IsUefi = $true
        $script:TargetDisk = [pscustomobject]@{ Number = [uint32]0; Size = 100GB }
        $script:TargetIdentity = 'target'
        $script:Preflight = [pscustomobject]@{
            Source = [pscustomobject]@{ Root = 'D:\Payload'; Identity = 'original-medium' }
            Image = [pscustomobject]@{ Path = 'D:\Payload\Images\install.wim'; Hash = 'original-image' }
            Drivers = $null
        }
        $script:CurrentSourceIdentity = 'original-medium'
        $logRoot = $PSScriptRoot
        Mock Write-Log { }
        Mock Set-Content { }
        Mock Assert-WinPEEnvironment { }
        Mock Get-DeploymentMediaDiskNumbers { @(3) }
        Mock Assert-DeploymentLettersAvailable { }
        Mock Find-MediaRoot { 'D:\Payload' }
        Mock Get-DeploymentSourceIdentity { $script:CurrentSourceIdentity }
        Mock Test-Path { $true }
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'original-image' } }
        Mock Assert-TargetDiskSafe { $script:TargetDisk }
        Mock Assert-TargetPartitions { }
        Mock Invoke-External { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'rechecks the full image hash and source identity even when no drivers are supplied' {
        & $script:DeploymentSteps[1].Action
        Should -Invoke Get-FileHash -Times 1 -ParameterFilter {
            $LiteralPath -eq 'D:\Payload\Images\install.wim' -and $Algorithm -eq 'SHA256'
        }
        Should -Invoke Get-DeploymentSourceIdentity -Times 2
        Should -Invoke Invoke-External -Times 1 -ParameterFilter { $FilePath -eq 'diskpart.exe' }
    }
    It 'aborts before erase if the source medium disappears' {
        Mock Find-MediaRoot { throw 'No ready external deployment medium' }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*No ready external deployment medium*'
        Should -Invoke Invoke-External -Times 0
        Should -Invoke Assert-TargetDiskSafe -Times 0
    }
    It 'aborts before erase if another deployment medium creates source ambiguity' {
        Mock Find-MediaRoot { throw 'Multiple deployment media' }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*Multiple deployment media*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'aborts before erase if the source medium is replaced at the same drive letter' {
        $script:CurrentSourceIdentity = 'replacement-medium'
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*medium was replaced or changed*'
        Should -Invoke Get-FileHash -Times 0
        Should -Invoke Invoke-External -Times 0
    }
    It 'aborts before erase if the selected Windows image disappears' {
        Mock Test-Path { $false }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*Windows image disappeared*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'aborts before erase if the selected image contents change' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'modified-image' } }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*Windows image changed*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'aborts before erase if the selected image cannot be read completely' {
        Mock Get-FileHash { throw 'Image media read error' }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*Image media read error*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'rechecks source attachment after the lengthy image hash read' {
        Mock Get-FileHash {
            $script:CurrentSourceIdentity = 'replaced-during-hashing'
            [pscustomobject]@{ Hash = 'original-image' }
        }
        { & $script:DeploymentSteps[1].Action } | Should -Throw '*medium changed while verifying*'
        Should -Invoke Invoke-External -Times 0
    }
}

Describe 'Post-partition driver extraction' {
    BeforeEach {
        $script:Drivers = [pscustomobject]@{
            Archive = 'Drivers.7z'; Hash = 'original'; ExpandedBytes = 6GB
            Tool = '7za.exe'; Count = 1; ModelSubdirectory = $false
        }
        Mock Assert-TargetPartitions { }
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'original' } }
        Mock Get-Volume { [pscustomobject]@{ SizeRemaining = 100GB } }
        Mock Invoke-External { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-ChildItem { [pscustomobject]@{ Attributes = [IO.FileAttributes]::Normal; Extension = '.inf' } }
    }
    It 'extracts only into a unique directory on the verified Windows target' {
        $path = Expand-ValidatedDriverArchive -Drivers $script:Drivers
        $path | Should -Match '^W:\\Windows\\Temp\\AutoReset-Drivers-[a-f0-9]{32}$'
        Should -Invoke Assert-TargetPartitions -Times 1
        Should -Invoke Get-FileHash -Times 1
        Should -Invoke Invoke-External -Times 1 -ParameterFilter {
            $Arguments -like 'x *' -and $Arguments -like '*-o"W:\Windows\Temp\AutoReset-Drivers-*'
        }
    }
    It 'rechecks archive identity before extraction' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'changed' } }
        { Expand-ValidatedDriverArchive -Drivers $script:Drivers } | Should -Throw '*driver archive changed*'
        Should -Invoke Invoke-External -Times 0
    }
    It 'refuses extraction when partition ownership is unverified' {
        Mock Assert-TargetPartitions { throw 'wrong partition' }
        { Expand-ValidatedDriverArchive -Drivers $script:Drivers } | Should -Throw '*wrong partition*'
        Should -Invoke Invoke-External -Times 0
    }
}

Describe 'Actual partition ownership checks' {
    BeforeEach {
        $script:IsUefi = $true
        $script:TargetDisk = [pscustomobject]@{ Number = [uint32]0 }
        $script:TargetIdentity = 'stable-disk'
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 9; DriveLetter = $DriveLetter } }
        Mock Get-Disk { [pscustomobject]@{ Number = [uint32]0 } }
        Mock Get-DiskIdentity { 'stable-disk' }
        Mock Test-Path { $true }
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'FAT32' } }
    }
    It 'rejects another disk even when S, W and R paths exist' {
        { Assert-TargetPartitions } | Should -Throw '*does not belong*'
    }
    It 'rejects reused disk numbers with a different stable identity' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; DriveLetter = $DriveLetter } }
        Mock Get-DiskIdentity { 'replacement-disk' }
        { Assert-TargetPartitions } | Should -Throw '*identity changed*'
    }
    It 'does not copy logs into an unverified preexisting Windows drive' {
        $script:PartitionsVerified = $false
        Mock New-Item { throw 'Must not create target directories' }
        { Copy-LogsToTarget } | Should -Not -Throw
        Should -Invoke New-Item -Times 0
    }
}

Describe 'Target BCD and UEFI verification' {
    BeforeEach {
        $script:IsUefi = $true
        $script:FirmwareEntry = '{12345678-1234-1234-1234-123456789abc}'
        Mock Assert-TargetPartitions { }
        Mock Test-Path { $true }
        Mock Invoke-CheckedTool {
            if ($Arguments -like '/store *{bootmgr}*') { "device partition=S:" }
            elseif ($Arguments -like '/store *{default}*') {
                "device partition=W:`nosdevice partition=W:`nsystemroot \Windows`npath \Windows\system32\winload.efi"
            }
            elseif ($Arguments -eq '/enum firmware /v') {
                "identifier $script:FirmwareEntry`ndevice partition=S:`npath \EFI\Microsoft\Boot\bootmgfw.efi"
            }
            else { "displayorder $script:FirmwareEntry" }
        }
    }
    It 'verifies the target store, actual firmware device and boot order' {
        { Assert-TargetBootConfiguration } | Should -Not -Throw
        Should -Invoke Invoke-CheckedTool -Times 2 -ParameterFilter { $Arguments -like '/store S:*' }
        Should -Invoke Invoke-CheckedTool -Times 1 -ParameterFilter { $Arguments -eq '/enum firmware /v' }
    }
    It 'copies a firmware-class boot manager rather than creating a boot-environment application' {
        Mock Assert-TargetBootConfiguration { }
        Mock Invoke-External { [pscustomobject]@{ ExitCode = 0 } }
        Mock Invoke-CheckedTool {
            if ($Arguments -like '/copy {bootmgr} *') { '{12345678-1234-1234-1234-123456789abc}' }
        }
        $bootStep = $script:DeploymentSteps | Where-Object Name -eq 'Create Boot Data'
        & $bootStep.Action
        Should -Invoke Invoke-CheckedTool -Times 1 -ParameterFilter {
            $FilePath -eq 'bcdedit.exe' -and $Arguments -eq '/copy {bootmgr} /d "Windows Boot Manager - Respawn"'
        }
        Should -Invoke Invoke-CheckedTool -Times 1 -ParameterFilter { $Arguments -match '^/set \{.*\} device partition=S:$' }
        Should -Invoke Invoke-CheckedTool -Times 1 -ParameterFilter { $Arguments -match '^/set \{.*\} path \\EFI\\Microsoft\\Boot\\bootmgfw.efi$' }
        Should -Invoke Assert-TargetBootConfiguration -Times 1
        $script:DeploymentSource | Should -Not -Match '/application BOOTAPP'
    }
    It 'rejects a BCD Windows loader pointing at the deployment environment' {
        Mock Invoke-CheckedTool { "device partition=X:`nosdevice partition=X:" } -ParameterFilter { $Arguments -like '*{default}*' }
        { Assert-TargetBootConfiguration } | Should -Throw '*does not point*'
    }
    It 'rejects a firmware entry on a different ESP' {
        Mock Invoke-CheckedTool { "identifier $script:FirmwareEntry`ndevice partition=T:`npath \EFI\Microsoft\Boot\bootmgfw.efi" } `
            -ParameterFilter { $Arguments -eq '/enum firmware /v' }
        { Assert-TargetBootConfiguration } | Should -Throw '*actual UEFI firmware entry*'
    }
    It 'rejects an entry that is not first in firmware boot order' {
        Mock Invoke-CheckedTool { "displayorder {99999999-9999-9999-9999-999999999999}`n             $script:FirmwareEntry" } `
            -ParameterFilter { $Arguments -eq '/enum {fwbootmgr} /v' }
        { Assert-TargetBootConfiguration } | Should -Throw '*not first*'
    }
    It 'implements an explicit specialize hook instead of promising an unimplemented WinRE retry' {
        $script:DeploymentSource | Should -Match '<settings pass="specialize">'
        $script:DeploymentSource | Should -Match 'AutoReset-EnableWinRE.ps1'
        $script:DeploymentSource | Should -Match 'AutoReset-WinRE.log'
        $script:DeploymentSource | Should -Not -Match 'WinRE registration deferred to first boot'
    }
    It 'includes a syntactically valid first-boot recovery script' {
        $hook = $script:DeploymentAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value -like '*WinRE activation could not be verified*'
        }, $true)
        $hook | Should -Not -BeNullOrEmpty
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($hook.Value, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'does not overwrite an image-provided answer file when staging recovery' {
        Mock Test-Path { $true }
        Mock Set-Content { }
        { Install-RecoveryFirstBootHook } | Should -Throw '*Existing answer file*conflicts*'
        Should -Invoke Set-Content -Times 0
    }
}
