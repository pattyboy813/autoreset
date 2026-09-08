# Shared safety checks. Importing this file never changes a disk.

function Assert-WinPEEnvironment {
    if (-not (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')) {
        throw 'Disk operations are allowed only inside Windows PE, not an installed Windows system.'
    }
}

function Get-DeploymentMediaDiskNumbers {
    # Protect every matching medium, not just the first USB found.
    $numbers = @()
    foreach ($volume in @(Get-Volume -ErrorAction Stop)) {
        $labelled = $volume.FileSystemLabel -in @('PE', 'PAYLOAD')
        $marker = $false
        if ($volume.DriveLetter) {
            $marker = Test-Path -LiteralPath "$($volume.DriveLetter):\Payload\UNE-Payload.tag"
        }
        if (-not ($labelled -or $marker)) { continue }
        # Optical media and the PE RAM disk cannot be DiskPart targets.
        if ("$($volume.DriveType)" -in @('CD-ROM', 'CDROM', 'RAM', 'Ramdisk', 'RAM Disk')) { continue }
        $partitions = @(Get-Partition -Volume $volume -ErrorAction Stop)
        if ($partitions.Count -eq 0) {
            throw "Cannot identify the disk containing deployment volume '$($volume.FileSystemLabel)'."
        }
        $numbers += $partitions.DiskNumber
    }
    $numbers | Sort-Object -Unique
}

function Get-DiskIdentity {
    param([Parameter(Mandatory)]$Disk)
    $unique = ([string]$Disk.UniqueId).Trim()
    $serial = ([string]$Disk.SerialNumber).Trim()
    if (-not $unique -and -not $serial) {
        throw "Disk $($Disk.Number) has no stable identifier; refusing a destructive operation."
    }
    # Disk numbers alone can be reused after a device is disconnected.
    @([string]$Disk.Number, $unique, $serial, [string]$Disk.Size, [string]$Disk.BusType) |
        ConvertTo-Json -Compress
}

function Test-EligibleTargetDisk {
    param([Parameter(Mandatory)]$Disk, [int[]]$ProtectedDiskNumbers = @())
    if ($Disk.Number -in $ProtectedDiskNumbers -or
        $Disk.BusType -notin @('ATA', 'SATA', 'SAS', 'SCSI', 'RAID', 'NVMe', 'SCM', 'Virtual') -or
        $Disk.IsBoot -or $Disk.IsSystem -or $Disk.IsReadOnly -or $Disk.IsOffline -or
        $Disk.Size -le 0) { return $false }
    try { $null = Get-DiskIdentity -Disk $Disk } catch { return $false }
    return $true
}

function Assert-TargetDiskSafe {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][string]$ExpectedIdentity,
        [int[]]$ProtectedDiskNumbers = @()
    )
    Assert-WinPEEnvironment
    $protected = @($ProtectedDiskNumbers) + @(Get-DeploymentMediaDiskNumbers)
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if (-not (Test-EligibleTargetDisk -Disk $disk -ProtectedDiskNumbers $protected)) {
        throw "Disk $DiskNumber is protected, unavailable, or unsuitable for erasure."
    }
    if ((Get-DiskIdentity -Disk $disk) -cne $ExpectedIdentity) {
        throw "Disk $DiskNumber changed since selection. Nothing will be erased."
    }
    return $disk
}
