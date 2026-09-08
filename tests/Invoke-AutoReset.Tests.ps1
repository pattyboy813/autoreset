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
        'Get-DeploymentImage', 'Assert-ArchiveEntryPath', 'Assert-DriverScratchSpace',
        'Get-PreparedDrivers', 'Invoke-DeploymentPreflight', 'Invoke-CheckedTool',
        'Assert-TargetBootConfiguration', 'Install-RecoveryFirstBootHook', 'Copy-LogsToTarget',
        'Invoke-KillDiskProcess'
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
    function Get-Partition { param($DriveLetter) }
    function Get-Volume { param($DriveLetter) }
    function Invoke-External { param($FilePath, $Arguments, $What, [switch]$ParsePercent) }
    function Write-Log { param($Message, $Level) }
}

Describe 'Secure wipe child process result' {
    BeforeEach {
        Mock Write-Log { }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'waits for and verifies the child result' {
        { Invoke-KillDiskProcess -ScriptPath 'Invoke-KillDisk.ps1' -Serial 'TEST' } | Should -Not -Throw
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $Wait -and $PassThru }
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -eq 'Secure wipe process exit code: 0' }
    }
    It 'propagates a failed or unavailable child exit code' -TestCases @(
        @{ Code = 1 }, @{ Code = 42 }, @{ Code = $null }
    ) {
        param($Code)
        $script:ChildExitCode = $Code
        Mock Start-Process { [pscustomobject]@{ ExitCode = $script:ChildExitCode } }
        { Invoke-KillDiskProcess -ScriptPath 'Invoke-KillDisk.ps1' -Serial 'TEST' } |
            Should -Throw '*Secure wipe did not complete successfully*'
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
        Mock Assert-WinPEEnvironment { }
        Mock Get-Command { [pscustomobject]@{ Name = 'available' } }
        Mock Get-DeploymentMediaDiskNumbers { @(3) }
        Mock Assert-TargetDiskSafe { $script:TargetDisk }
        Mock Assert-DeploymentLettersAvailable { }
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
        (Invoke-DeploymentPreflight).RequiredBytes | Should -BeGreaterThan 40GB
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
    It 'rejects media mapping failure' {
        Mock Get-DeploymentMediaDiskNumbers { throw 'Cannot map deployment media' }
        { Invoke-DeploymentPreflight } | Should -Throw '*Cannot map*'
    }
    It 'requires the legacy boot-sector tool' {
        $script:IsUefi = $false
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'bootsect.exe' }
        { Invoke-DeploymentPreflight } | Should -Throw '*bootsect.exe*required*'
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
        Mock Assert-DriverScratchSpace { }
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
    It 'explicitly converts a GPT source disk to MBR for legacy firmware' {
        $script:IsUefi = $false
        & $script:DeploymentSteps[1].Action
        Should -Invoke Set-Content -Times 1 -ParameterFilter { $Value -match '(?s)clean\s+convert mbr' }
        Should -Invoke Assert-TargetPartitions -Times 1
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
