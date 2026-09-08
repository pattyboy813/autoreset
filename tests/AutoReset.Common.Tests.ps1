BeforeAll {
    . (Join-Path $PSScriptRoot '../AutoReset.Common.ps1')
    # Storage cmdlets do not exist on Linux; these signatures allow safe mocks there.
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        function Get-Disk { [CmdletBinding()]param([int]$Number) }
        function Get-Volume { [CmdletBinding()]param() }
        function Get-Partition { [CmdletBinding()]param($Volume) }
    }
    function New-TestDisk {
        [pscustomobject]@{
            Number = [uint32]0; UniqueId = 'test-disk-0'; SerialNumber = 'test-serial'
            Size = 100GB; BusType = 'NVMe'; IsBoot = $false; IsSystem = $false
            IsReadOnly = $false; IsOffline = $false
        }
    }
}

Describe 'Disk eligibility and stable identity' {
    BeforeEach { $disk = New-TestDisk }

    It 'allows an identified internal writable disk' {
        Test-EligibleTargetDisk -Disk $disk | Should -BeTrue
    }
    It 'allows an identified VM disk' {
        $disk.BusType = 'Virtual'
        Test-EligibleTargetDisk -Disk $disk | Should -BeTrue
    }
    It 'protects the media disk even when reported as internal' {
        Test-EligibleTargetDisk -Disk $disk -ProtectedDiskNumbers @(0) | Should -BeFalse
    }
    It 'rejects <Bus> disks' -ForEach @(
        @{ Bus = 'USB' }, @{ Bus = 'iSCSI' }, @{ Bus = 'File Backed Virtual' }, @{ Bus = 'Unknown' },
        @{ Bus = 'SD' }, @{ Bus = 'MMC' }, @{ Bus = '1394' }, @{ Bus = '' }
    ) {
        $disk.BusType = $Bus
        Test-EligibleTargetDisk -Disk $disk | Should -BeFalse
    }
    It 'rejects disks with <Flag>' -ForEach @(
        @{ Flag = 'IsBoot' }, @{ Flag = 'IsSystem' }, @{ Flag = 'IsReadOnly' }, @{ Flag = 'IsOffline' }
    ) {
        $disk.$Flag = $true
        Test-EligibleTargetDisk -Disk $disk | Should -BeFalse
    }
    It 'rejects missing stable identifiers' {
        $disk.UniqueId = ''
        $disk.SerialNumber = ' '
        { Get-DiskIdentity -Disk $disk } | Should -Throw '*no stable identifier*'
        Test-EligibleTargetDisk -Disk $disk | Should -BeFalse
    }
    It 'detects a different disk reusing the same number' {
        $old = Get-DiskIdentity -Disk $disk
        $disk.UniqueId = 'replacement'
        Get-DiskIdentity -Disk $disk | Should -Not -Be $old
    }
}

Describe 'Deployment media protection' {
    It 'protects all matching disks and deduplicates partitions on the same disk' {
        Mock Get-Volume {
            @(
                [pscustomobject]@{ FileSystemLabel = 'PE'; DriveLetter = 'E'; DriveType = 'Removable' }
                [pscustomobject]@{ FileSystemLabel = 'PAYLOAD'; DriveLetter = 'F'; DriveType = 'Removable' }
                [pscustomobject]@{ FileSystemLabel = 'Other'; DriveLetter = 'G'; DriveType = 'Fixed' }
            )
        }
        Mock Test-Path { $LiteralPath -eq 'G:\Payload\UNE-Payload.tag' }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = $(if ($Volume.DriveLetter -eq 'G') { 3 } else { 2 }) }
        }
        @(Get-DeploymentMediaDiskNumbers) | Should -Be @(2, 3)
    }
    It 'refuses to guess when the media disk cannot be resolved' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'PAYLOAD'; DriveLetter = ''; DriveType = 'Fixed' } }
        Mock Get-Partition { }
        { Get-DeploymentMediaDiskNumbers } | Should -Throw '*Cannot identify*'
    }
    It 'does not try to resolve optical media to a writable disk' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'PAYLOAD'; DriveLetter = ''; DriveType = 'CD-ROM' } }
        Mock Get-Partition { throw 'Optical disks have no writable partition' }
        @(Get-DeploymentMediaDiskNumbers).Count | Should -Be 0
    }
}

Describe 'Last-moment destructive-operation checks' {
    BeforeEach {
        $disk = New-TestDisk
        Mock Assert-WinPEEnvironment { }
        Mock Get-DeploymentMediaDiskNumbers { }
        Mock Get-Disk { $disk }
    }
    It 'returns only the revalidated disk' {
        $identity = Get-DiskIdentity -Disk $disk
        (Assert-TargetDiskSafe -DiskNumber 0 -ExpectedIdentity $identity).Number | Should -Be 0
        Should -Invoke Assert-WinPEEnvironment -Times 1
    }
    It 'refuses a changed identity' {
        $identity = Get-DiskIdentity -Disk $disk
        $disk.SerialNumber = 'different'
        { Assert-TargetDiskSafe -DiskNumber 0 -ExpectedIdentity $identity } | Should -Throw '*changed since selection*'
    }
    It 'rechecks newly attached deployment media' {
        $identity = Get-DiskIdentity -Disk $disk
        Mock Get-DeploymentMediaDiskNumbers { 0 }
        { Assert-TargetDiskSafe -DiskNumber 0 -ExpectedIdentity $identity } | Should -Throw '*protected*'
    }
    It 'preserves the original protected disks after media removal' {
        $identity = Get-DiskIdentity -Disk $disk
        { Assert-TargetDiskSafe -DiskNumber 0 -ExpectedIdentity $identity -ProtectedDiskNumbers @(0) } |
            Should -Throw '*protected*'
    }
}

Describe 'WinPE-only operation' {
    It 'rejects an installed operating system' {
        Mock Test-Path { $false }
        { Assert-WinPEEnvironment } | Should -Throw '*only inside Windows PE*'
    }

    Describe 'KillDisk identity lookup' {
        It 'can retrieve a Windows UInt32 disk identity using a selected Int32 number' {
            $internalDisks = @(New-TestDisk)
            $diskIdentities = @{}
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $PSScriptRoot '../Invoke-KillDisk.ps1'), [ref]$null, [ref]$null)
            # Execute only the identity-map loop, never the destructive entry point.
            $loop = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                $node.Variable.VariablePath.UserPath -eq 'disk' -and
                $node.Condition.Extent.Text -eq '$internalDisks'
            }, $true)
            $loop | Should -Not -BeNullOrEmpty
            & ([scriptblock]::Create($loop.Extent.Text))
            $diskIdentities[[int]0] | Should -Be (Get-DiskIdentity -Disk $internalDisks[0])
        }
    }
    It 'accepts WinPE' {
        Mock Test-Path { $true }
        { Assert-WinPEEnvironment } | Should -Not -Throw
    }
}
