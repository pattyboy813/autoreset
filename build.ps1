<#
.SYNOPSIS
    Builds a stripped-down, auto-running AutoReset and KillDisk WinPE USB or ISO.

.DESCRIPTION
    Run from an elevated PowerShell prompt. Requires the Windows ADK
    Deployment Tools and WinPE add-on. Use -InstallPrerequisites to install
    missing components.

    The canonical runtime sources are usb-scripts\autoreset.ps1,
    usb-scripts\killdisk.ps1, usb-scripts\autoreset.common.ps1 and
    usb-scripts\autoreset.ui.ps1. These explicit files are bundled into
    boot.wim at Payload\Scripts and mirrored to the deployment media's
    Payload\Scripts; Payload\Scripts is not a source folder. Bundled runtime
    scripts use UTF-8 with a BOM for Windows PowerShell 5.1. Supply
    configuration at reset.json. Optional source assets live in win-images,
    device-drivers, tools and winpe-drivers. OutputRoot\Images\install.wim
    takes precedence over win-images\install.wim. An image is required unless
    -SkipPayload is explicit. winpe-drivers is injected for both USB and ISO builds.
    The default configuration selects Windows 11 Pro by exact edition
    name, matching the default -PrepareImage edition. ImageIndex defaults to
    null so multi-index media is supported. If you pin an ImageIndex, it must
    match ImageEdition; update the configuration for other editions. DriversRequired
    defaults to false. SetupRecovery installs a first-boot WinRE registration
    and verification hook and refuses an existing Panther answer file. For
    custom answer files, integrate equivalent WinRE initialization/verification
    yourself and set SetupRecovery=false to preserve your answer files.

    Driver archives use ZIP unless tools\7za.exe is a compatible,
    standalone AMD64 extractor. A supplied incompatible extractor is an error.
    The trusted ADK AMD64 bootsect.exe is bundled in WinPE Windows\System32
    (on PATH) and tools for legacy BIOS deployment.
    Content-verified caches separate the serviced WinPE base from runtime
    customization. Identical warm builds skip mounting; script/config/tool changes
    customize the cached base without reinstalling packages or boot drivers.
    Cold builds commit and remount the base once, so may take longer than before.
    USB payload images and driver archives copy directly from their original
    locations, not through the workspace. ISO builds still materialize these files.
    Unchanged USB files are SHA256-checked and skipped, not blindly rewritten.
    WorkDir is a parent for a unique, builder-owned workspace; existing folders
    and unrelated DISM mounts are never cleaned up. Failed workspaces are retained.
    USB updates require exactly one PE (FAT32) and PAYLOAD (NTFS) volume on the
    same eligible physical USB disk and the builder's Payload\UNE-Payload.tag
    ownership marker. Logs are preserved during payload refresh.

.PARAMETER OutputRoot
    Folder for build files, caches, logs, and the default ISO.
    Default: W:\AutoReset

.PARAMETER UsbDiskNumber
    USB disk number to erase and build. Check it with Get-Disk first.

.PARAMETER WorkDir
    Parent for a unique scratch workspace. Default: <LocalAppData>\AutoReset\Work.
    Use a local SSD with enough free space; avoid network and synced folders.

.PARAMETER KeepWorkDir
    Keep the scratch workspace after a successful build.

.PARAMETER SkipPayload
    Omit installation images and deployment drivers. Runtime/config/tools are
    still refreshed; a USB update removes old images/drivers, preserving Logs.

.PARAMETER WinPEResolution
    Optional WIDTHxHEIGHT display override. By default WinPE chooses its display
    mode; no Display setting is generated.

.PARAMETER InstallPrerequisites
    Install missing ADK and WinPE components from Microsoft.

.PARAMETER UpdateUsb
    Refresh an existing PE/PAYLOAD USB without repartitioning it.

.PARAMETER BuildIso
    Create a bootable BIOS and UEFI ISO.

.PARAMETER IsoPath
    Output path for -BuildIso. Defaults to <OutputRoot>\AutoReset.iso.

.PARAMETER NoCache
    Bypass both serviced-base and customized-final WIM caches (reads and writes).

.PARAMETER DriverCompression
    Fast (default) favors build time: LZMA2 level 1 or ZIP Fastest.
    Balanced uses LZMA2 level 5; Maximum uses level 9 with a larger dictionary.
    ZIP uses Optimal for Balanced and Maximum. Changing profiles rebuilds archives.

.EXAMPLE
    .\build.ps1 -UpdateUsb

.EXAMPLE
    .\build.ps1 -UsbDiskNumber 2

.EXAMPLE
    .\build.ps1 -PrepareImage -SourceImage D:\sources\install.esd

.EXAMPLE
    .\build.ps1 -PrepareDrivers

.EXAMPLE
    .\build.ps1 -ValidateUsb

.EXAMPLE
    .\build.ps1 -BuildIso
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Preparation and cleanup helpers consume script-scoped parameters; mode switches also select parameter sets.')]
[CmdletBinding(DefaultParameterSetName = 'USB')]
param(
    [Parameter(ParameterSetName = 'USB', Mandatory)]
    [int]$UsbDiskNumber,

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = 'W:\AutoReset',

    [string]$WorkDir,

    [switch]$KeepWorkDir,

    [ValidatePattern('^\d{3,4}x\d{3,4}$')]
    [string]$WinPEResolution,

    [Alias('BootOnly')]
    [switch]$SkipPayload,

    [switch]$InstallPrerequisites,

    [Parameter(ParameterSetName = 'USB')]
    [switch]$AllowNonUsbDisk,

    [Parameter(ParameterSetName = 'USBUPDATE', Mandatory)]
    [switch]$UpdateUsb,

    [switch]$NoCache,

    [ValidateSet('Fast', 'Balanced', 'Maximum')]
    [string]$DriverCompression = 'Fast',

    [Parameter(ParameterSetName = 'ISO', Mandatory)]
    [switch]$BuildIso,

    [Parameter(ParameterSetName = 'ISO')]
    [string]$IsoPath,

    [Parameter(ParameterSetName = 'PrepareImage', Mandatory)]
    [switch]$PrepareImage,

    [Parameter(ParameterSetName = 'PrepareImage', Mandatory)]
    [string]$SourceImage,

    [Parameter(ParameterSetName = 'PrepareImage')]
    [string]$Edition = 'Windows 11 Pro',

    [Parameter(ParameterSetName = 'PrepareImage')]
    [ValidateRange(1, 999)]
    [int]$SourceIndex,

    [Parameter(ParameterSetName = 'PrepareImage')]
    [string]$DestinationImage,

    [Parameter(ParameterSetName = 'PrepareImage')]
    [switch]$Rebuild,

    [Parameter(ParameterSetName = 'PrepareImage')]
    [switch]$ListOnly,

    [Parameter(ParameterSetName = 'PrepareDrivers', Mandatory)]
    [switch]$PrepareDrivers,

    [Parameter(ParameterSetName = 'PrepareDrivers')]
    [string]$Device,

    [Parameter(ParameterSetName = 'PrepareDrivers')]
    [switch]$NoZip,

    [Parameter(ParameterSetName = 'PrepareDrivers')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'ValidateUsb', Mandatory)]
    [switch]$ValidateUsb,

    [Parameter(ParameterSetName = 'ValidateUsb')]
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$script:BuildStopwatch = [Diagnostics.Stopwatch]::StartNew()
$script:BuildPhases = @{}

# ── Constants ────────────────────────────────────────────────────────

$script:Version = '2.0.0'
$script:Arch    = 'amd64'
$script:Lang    = 'en-us'

# ── Path resolution ──────────────────────────────────────────────────

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot -and $MyInvocation.MyCommand.Path) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
if ((Split-Path -Leaf $ScriptRoot) -eq 'Tools') {
    $ScriptRoot = Split-Path -Parent $ScriptRoot
}

$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$script:UseDefaultWorkDir = [string]::IsNullOrWhiteSpace($WorkDir)
if ($script:UseDefaultWorkDir) {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Could not resolve a local scratch folder. Specify -WorkDir <folder>.'
    }
    $WorkDir = [System.IO.Path]::Combine($localAppData, 'AutoReset', 'Work')
}
$workParent = [System.IO.Path]::GetFullPath($WorkDir)
$WorkDir = [System.IO.Path]::Combine($workParent, ('AutoReset-Build-' + [guid]::NewGuid().ToString('N')))
$script:OwnedWorkspace = $WorkDir
$mountRoot = [System.IO.Path]::Combine($WorkDir, 'mount')
$artifactRoot        = $OutputRoot
$cacheDir            = [System.IO.Path]::Combine($artifactRoot, 'Cache')
$preparedImagesRoot  = [System.IO.Path]::Combine($artifactRoot, 'Images')
$preparedDriversRoot = [System.IO.Path]::Combine($artifactRoot, 'Drivers')

# ── Console output engine ───────────────────────────────────────────

$script:SpinnerFrames = @('/', '-', '\', '|')
$script:SpinnerIndex  = 0
$script:ActiveLine    = $null

function Start-Step {
    param([Parameter(Mandatory)][string]$Text)
    $script:ActiveLine   = $Text
    $script:SpinnerIndex = 0
    Update-Spinner
}

function Update-Spinner {
    if (-not $script:ActiveLine) { return }
    $frame  = $script:SpinnerFrames[$script:SpinnerIndex % $script:SpinnerFrames.Count]
    $line   = "  [$frame] $($script:ActiveLine)"
    $padded = $line.PadRight([Console]::BufferWidth - 1)
    [Console]::SetCursorPosition(0, [Console]::CursorTop)
    [Console]::Write($padded)
    $script:SpinnerIndex++
}

function Update-StepDisplay {
    param([int]$Percent = -1)
    if (-not $script:ActiveLine) { return }
    $base = $script:ActiveLine -replace '\s+\d+%$', ''
    if ($Percent -ge 0 -and $Percent -le 100) {
        $script:ActiveLine = "$base  ${Percent}%"
    }
    else {
        $script:ActiveLine = $base
    }
    Update-Spinner
}

function Write-StepDone {
    param([Parameter(Mandatory)][string]$Text)
    $tick   = [char]0x2713
    $line   = "  [$tick] $Text"
    $padded = $line.PadRight([Console]::BufferWidth - 1)
    [Console]::SetCursorPosition(0, [Console]::CursorTop)
    Write-Host $padded -ForegroundColor Green
    $script:ActiveLine = $null
}

function Write-StepSkipped {
    param([Parameter(Mandatory)][string]$Text)
    $line   = "  [-] $Text"
    $padded = $line.PadRight([Console]::BufferWidth - 1)
    [Console]::SetCursorPosition(0, [Console]::CursorTop)
    Write-Host $padded -ForegroundColor DarkGray
    $script:ActiveLine = $null
}

function Write-StepFailed {
    param([Parameter(Mandatory)][string]$Text, [string]$Detail)
    $cross  = [char]0x2717
    $line   = "  [$cross] $Text"
    $padded = $line.PadRight([Console]::BufferWidth - 1)
    [Console]::SetCursorPosition(0, [Console]::CursorTop)
    Write-Host $padded -ForegroundColor Red
    if ($Detail) { Write-Host "      $Detail" -ForegroundColor DarkRed }
    $script:ActiveLine = $null
}

function Write-Aside {
    param([string]$Text, [System.ConsoleColor]$Colour = 'Yellow')
    $wasActive = $script:ActiveLine
    if ($wasActive) {
        $blank = ' ' * ([Console]::BufferWidth - 1)
        [Console]::SetCursorPosition(0, [Console]::CursorTop)
        [Console]::Write($blank)
        [Console]::SetCursorPosition(0, [Console]::CursorTop)
    }
    Write-Host "  [!] $Text" -ForegroundColor $Colour
    if ($wasActive) {
        $script:ActiveLine = $wasActive
        Update-Spinner
    }
}

# ── Build log ────────────────────────────────────────────────────────

$script:BuildLog = $null

function Write-BuildLog {
    param([string]$Text)
    if ($script:BuildLog) {
        Add-Content -Path $script:BuildLog -Value $Text -ErrorAction SilentlyContinue
    }
}

function Start-BuildPhase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only starts an in-memory stopwatch.')]
    [CmdletBinding()]
    param([string]$Name)
    if (-not $script:BuildPhases) { $script:BuildPhases = @{} }
    $script:BuildPhases[$Name] = [Diagnostics.Stopwatch]::StartNew()
}

function Stop-BuildPhase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only stops and logs an in-memory stopwatch.')]
    [CmdletBinding()]
    param([string]$Name)
    if ($script:BuildPhases -and $script:BuildPhases.ContainsKey($Name)) {
        $timer = $script:BuildPhases[$Name]
        $timer.Stop()
        Write-BuildLog ("Timing {0}: {1:N2}s" -f $Name, $timer.Elapsed.TotalSeconds)
        $script:BuildPhases.Remove($Name)
    }
}

function Write-BuildTotal {
    foreach ($phase in @($script:BuildPhases.Keys)) { Stop-BuildPhase $phase }
    $script:BuildStopwatch.Stop()
    Write-BuildLog ("Timing total (including preflight): {0:N2}s" -f $script:BuildStopwatch.Elapsed.TotalSeconds)
}

# ── Tool runner ──────────────────────────────────────────────────────

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$What = $FilePath
    )
    $resolved = Get-Command $FilePath -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw "'$FilePath' was not found on this system."
    }

    $quotedArgs = $ArgumentList | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '"') { "`"$_`"" } else { $_ }
    }

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ($quotedArgs -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $outBuf  = New-Object System.Text.StringBuilder
    $stream  = $proc.StandardOutput.BaseStream
    $bytes   = New-Object byte[] 4096

    $readTask = $stream.ReadAsync($bytes, 0, $bytes.Length)
    while ($true) {
        if ($readTask.IsCompleted) {
            $count = 0
            if (-not $readTask.IsFaulted) { $count = $readTask.Result }
            if ($count -le 0) {
                if ($proc.HasExited) { break }
                Start-Sleep -Milliseconds 50
            }
            else {
                [void]$outBuf.Append([System.Text.Encoding]::UTF8.GetString($bytes, 0, $count))
            }
            $readTask = $stream.ReadAsync($bytes, 0, $bytes.Length)
        }
        else {
            Update-Spinner
            Start-Sleep -Milliseconds 120
        }
    }
    $proc.WaitForExit()
    $exit   = $proc.ExitCode
    $output = $outBuf.ToString()
    $stdErr = ''
    try { $stdErr = $errTask.Result }
    catch { Write-BuildLog "Could not read tool stderr: $($_.Exception.Message)" }

    Write-BuildLog ("### [{0}] {1} (exit {2})" -f
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $What, $exit)
    Write-BuildLog ("    {0}" -f ($ArgumentList -join ' '))
    Write-BuildLog $output
    if ($stdErr.Trim()) { Write-BuildLog "[stderr] $($stdErr.Trim())" }

    if ($null -eq $exit -or $exit -ne 0) {
        $lines = $output -split "[`r`n]+"
        $tail  = ($lines | Where-Object { $_.Trim() } | Select-Object -Last 15) -join "`n"
        throw ("$What failed with exit code $exit." + "`n$tail" + "`nFull log: $($script:BuildLog)")
    }
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Dest, [string[]]$Extra = @('/E'), [string]$What = 'copy')
    Assert-NoReparsePath -Path $Source -Recurse
    Assert-NoReparsePath -Path $Dest -Recurse
    if ($Extra -contains '/MIR' -or $Extra -contains '/PURGE') {
        Assert-SafeMirror -Source $Source -Destination $Dest
    }
    # /IS /IT also replace same-size, same-timestamp files with changed contents.
    $rcArgs = @($Source, $Dest) + $Extra + @('/IS', '/IT', '/XJ', '/R:2', '/W:2', '/BYTES', '/ETA', '/NJH', '/NJS', '/MT:32', '/J')

    $quotedArgs = $rcArgs | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '"') { "`"$_`"" } else { $_ }
    }

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'robocopy.exe'
    $psi.Arguments              = ($quotedArgs -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $outBuf  = New-Object System.Text.StringBuilder
    $stream  = $proc.StandardOutput.BaseStream
    $bytes   = New-Object byte[] 4096
    $pctRx   = [regex]'(\d{1,3})%'

    $readTask = $stream.ReadAsync($bytes, 0, $bytes.Length)
    while ($true) {
        if ($readTask.IsCompleted) {
            $count = 0
            if (-not $readTask.IsFaulted) { $count = $readTask.Result }
            if ($count -le 0) {
                if ($proc.HasExited) { break }
                Start-Sleep -Milliseconds 50
            }
            else {
                $chunk = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $count)
                [void]$outBuf.Append($chunk)
                $hits = $pctRx.Matches($chunk)
                if ($hits.Count -gt 0) {
                    Update-StepDisplay -Percent ([math]::Min(100, [int]$hits[$hits.Count - 1].Groups[1].Value))
                }
            }
            $readTask = $stream.ReadAsync($bytes, 0, $bytes.Length)
        }
        else {
            Update-Spinner
            Start-Sleep -Milliseconds 120
        }
    }
    $proc.WaitForExit()
    $exit   = $proc.ExitCode
    $output = $outBuf.ToString()
    $stdErr = $errTask.Result

    Write-BuildLog ("### [{0}] robocopy {1} -> {2} (exit {3})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Source, $Dest, $exit)
    Write-BuildLog $output
    if ($stdErr.Trim()) { Write-BuildLog "[stderr] $($stdErr.Trim())" }

    if ($exit -ge 8) {
        $lines    = $output -split "[`r`n]+"
        $errLines = ($lines | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 6) -join "`n"
        if (-not $errLines) { $errLines = (($lines | Where-Object { $_.Trim() }) | Select-Object -Last 6) -join "`n" }
        throw ("$What failed (robocopy exit $exit)." + "`n$errLines" + "`nFull log: $($script:BuildLog)")
    }
    $global:LASTEXITCODE = 0
}

# ── Build safety and content helpers ────────────────────────────────

function Test-PathWithin {
    param([string]$Path, [string]$Parent)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-UnsupportedReparsePoint {
    param([Parameter(Mandatory)]$Item)
    if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $linkType = $null
    if ($Item.PSObject.Properties.Name -contains 'LinkType') { $linkType = [string]$Item.LinkType }
    if ($linkType) { return $true }
    $target = $null
    if ($Item.PSObject.Properties.Name -contains 'Target') { $target = $Item.Target }
    if ($null -eq $target) { return $false }
    if ($target -is [System.Array]) { return $target.Count -gt 0 }
    return -not [string]::IsNullOrWhiteSpace([string]$target)
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Recurse)
    if (-not $script:ReparsePathCache) { $script:ReparsePathCache = @{} }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $cacheKey = '{0}|{1}' -f $fullPath, [bool]$Recurse
    if ($script:ReparsePathCache.ContainsKey($cacheKey)) { return }
    $current = $fullPath
    while ($current) {
        $ancestorKey = '{0}|False' -f $current
        if ($script:ReparsePathCache.ContainsKey($ancestorKey)) { break }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (Test-UnsupportedReparsePoint -Item $item) {
                throw "Reparse points are not supported in build paths: $current"
            }
        }
        $script:ReparsePathCache[$ancestorKey] = $true
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $fullPath -PathType Container)) {
        foreach ($child in Get-ChildItem -LiteralPath $fullPath -Force -Recurse -ErrorAction Stop) {
            if (Test-UnsupportedReparsePoint -Item $child) {
                throw "Reparse points are not supported in build paths: $($child.FullName)"
            }
        }
    }
    $script:ReparsePathCache[$cacheKey] = $true
}

function Assert-SafeMirror {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Mirror source missing: $Source" }
    $dest = [IO.Path]::GetFullPath($Destination)
    if ($dest.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($dest).TrimEnd('\', '/') -or
        (Test-PathWithin $dest $Source) -or (Test-PathWithin $Source $dest)) {
        throw "Refusing a root or overlapping mirror: $Source -> $Destination"
    }
}

function Get-BuildDiskIdentity {
    param([Parameter(Mandatory)]$Disk)
    if (-not ([string]$Disk.UniqueId).Trim() -and -not ([string]$Disk.SerialNumber).Trim()) {
        throw "Disk $($Disk.Number) has no stable hardware identity."
    }
    return @($Disk.UniqueId, $Disk.SerialNumber, $Disk.BusType, $Disk.Size, $Disk.Path, $Disk.Location) -join '|'
}

function Assert-BuildDiskSafe {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [string]$ExpectedIdentity,
        [int[]]$ProtectedDiskNumbers = @(),
        [switch]$AllowNonUsb
    )
    $disks = @(Get-Disk -Number $DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1) { throw "Disk $DiskNumber is ambiguous or unavailable." }
    $disk = $disks[0]
    if ($disk.Number -ne $DiskNumber -or $disk.IsBoot -ne $false -or $disk.IsSystem -ne $false -or
        $disk.IsReadOnly -ne $false -or $disk.IsOffline -ne $false -or $DiskNumber -in $ProtectedDiskNumbers) {
        throw "Disk $DiskNumber is boot/system, read-only, offline, protected, or its safety state is unknown."
    }
    if ($disk.BusType -ne 'USB' -and -not $AllowNonUsb) { throw "Disk $DiskNumber is not USB." }
    $identity = Get-BuildDiskIdentity -Disk $disk
    if ($ExpectedIdentity -and $identity -cne $ExpectedIdentity) { throw "Disk $DiskNumber identity changed; refusing writes." }
    return $disk
}

function Get-BuildProtectedDiskNumbers {
    param([Parameter(Mandatory)][string[]]$Paths)
    if (-not $script:ProtectedDiskPathCache) { $script:ProtectedDiskPathCache = @{} }
    $supportsFilePath = (Get-Command -Name Get-Partition -ErrorAction Stop).Parameters.ContainsKey('FilePath')
    $numbers = foreach ($path in $Paths) {
        if (-not $path) { continue }
        $existing = [IO.Path]::GetFullPath($path)
        if ($existing.StartsWith('\\')) { continue } # Network shares cannot be the local USB target.
        while (-not (Test-Path -LiteralPath $existing)) {
            $parent = Split-Path -Parent $existing
            if (-not $parent -or $parent -eq $existing) { throw "Cannot identify source/output disk: $path" }
            $existing = $parent
        }
        $cacheKey = $existing.ToUpperInvariant()
        if ($script:ProtectedDiskPathCache.ContainsKey($cacheKey)) {
            [int]$script:ProtectedDiskPathCache[$cacheKey]
            continue
        }
        if ($supportsFilePath) {
            $partitions = @(Get-Partition -FilePath $existing -ErrorAction Stop)
        }
        else {
            $qualifier = Split-Path -Path $existing -Qualifier
            if ($qualifier -notmatch '^[A-Za-z]:$') { throw "Cannot identify source/output disk: $path" }
            $partitions = @(Get-Partition -DriveLetter $qualifier.TrimEnd(':') -ErrorAction Stop)
        }
        $diskNumbers = @($partitions.DiskNumber | Sort-Object -Unique)
        if ($diskNumbers.Count -ne 1) { throw "Cannot unambiguously identify source/output disk: $path" }
        $script:ProtectedDiskPathCache[$cacheKey] = [int]$diskNumbers[0]
        [int]$diskNumbers[0]
    }
    return @($numbers | Sort-Object -Unique)
}

function Get-ValidatedUsbVolumes {
    param([int[]]$ProtectedDiskNumbers = @(), [string]$ExpectedIdentity)
    $boot = @(Get-Volume -FileSystemLabel 'PE' -ErrorAction SilentlyContinue)
    $payload = @(Get-Volume -FileSystemLabel 'PAYLOAD' -ErrorAction SilentlyContinue)
    if ($boot.Count -ne 1 -or $payload.Count -ne 1) {
        throw 'Need exactly one PE and one PAYLOAD volume; missing or duplicate labels are unsafe.'
    }
    if ("$($boot[0].DriveLetter)" -notmatch '^[A-Za-z]$' -or
        "$($payload[0].DriveLetter)" -notmatch '^[A-Za-z]$' -or
        $boot[0].DriveLetter -eq $payload[0].DriveLetter -or
        $boot[0].FileSystem -ne 'FAT32' -or $payload[0].FileSystem -ne 'NTFS') {
        throw 'PE/PAYLOAD require distinct drive letters and FAT32/NTFS filesystems.'
    }
    $bootPart = @(Get-Partition -DriveLetter $boot[0].DriveLetter -ErrorAction Stop)
    $payloadPart = @(Get-Partition -DriveLetter $payload[0].DriveLetter -ErrorAction Stop)
    if ($bootPart.Count -ne 1 -or $payloadPart.Count -ne 1 -or
        $bootPart[0].DiskNumber -ne $payloadPart[0].DiskNumber -or
        $bootPart[0].PartitionNumber -eq $payloadPart[0].PartitionNumber -or
        $bootPart[0].IsReadOnly -eq $true -or $payloadPart[0].IsReadOnly -eq $true -or
        $bootPart[0].IsBoot -eq $true -or $payloadPart[0].IsBoot -eq $true -or
        $bootPart[0].IsSystem -eq $true -or $payloadPart[0].IsSystem -eq $true) {
        throw 'PE and PAYLOAD must be writable, distinct partitions on the same physical USB disk.'
    }
    $disk = Assert-BuildDiskSafe -DiskNumber $bootPart[0].DiskNumber `
        -ExpectedIdentity $ExpectedIdentity -ProtectedDiskNumbers $ProtectedDiskNumbers
    return [pscustomobject]@{ Boot = $boot[0]; Payload = $payload[0]; Disk = $disk }
}

function Get-ContentTreeHash {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Exclude = @())
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    Assert-NoReparsePath -Path $Path -Recurse
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $parts = foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
            Where-Object Name -NotIn $Exclude | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        "$relative|$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($parts -join "`n"))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-BuildPartsHash {
    param([AllowEmptyCollection()][string[]]$Parts)
    $text = ($Parts | ForEach-Object { "$($_.Length):$_" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-WinPECachePlan {
    param(
        [Parameter(Mandatory)][string]$CacheDirectory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BaseParts,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RuntimeParts
    )
    $baseKey = Get-BuildPartsHash -Parts (@('winpe-base-v1') + $BaseParts)
    $finalKey = Get-BuildPartsHash -Parts (@('winpe-final-v1', $baseKey) + $RuntimeParts)
    [pscustomobject]@{
        BaseKey = $baseKey; FinalKey = $finalKey
        BasePath = Join-Path $CacheDirectory "winpe-base-$baseKey.wim"
        FinalPath = Join-Path $CacheDirectory "winpe-final-$finalKey.wim"
    }
}

function Test-WinPECacheImage {
    param([string]$Path)
    Assert-NoReparsePath -Path $Path
    Assert-NoReparsePath -Path "$Path.hash"
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
            -not (Test-Path -LiteralPath "$Path.hash" -PathType Leaf)) { return $false }
        $stored = (Get-Content -LiteralPath "$Path.hash" -Raw -ErrorAction Stop).Trim()
        return $stored -match '^[0-9A-Fa-f]{64}$' -and
            $stored -eq (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch { Write-BuildLog "WIM cache MISS (unreadable receipt/image): $Path"; return $false }
}

function Publish-WinPECacheImage {
    param([string]$Source, [string]$Destination)
    Assert-NoReparsePath -Path $Source
    Assert-NoReparsePath -Path $Destination
    Assert-NoReparsePath -Path "$Destination.hash"
    if (@(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object {
        [IO.Path]::GetFullPath($_.ImagePath) -eq [IO.Path]::GetFullPath($Source)
    }).Count) { throw 'Refusing to cache a mounted image.' }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('winpe-publish-' + [guid]::NewGuid().ToString('N') + '.wim')
    try {
        Copy-Item -LiteralPath $Source -Destination $stage -ErrorAction Stop
        Set-Content -LiteralPath "$stage.hash" -Value (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash -Encoding Ascii
        # A crash between renames leaves a mismatched receipt: next reuse is a miss.
        Move-Item -LiteralPath $stage -Destination $Destination -Force -ErrorAction Stop
        Move-Item -LiteralPath "$stage.hash" -Destination "$Destination.hash" -Force -ErrorAction Stop
    }
    finally {
        foreach ($path in @($stage, "$stage.hash")) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        }
    }
}

function Invoke-WinPEBaseServicing {
    param([string]$MountPath, [string[]]$PackagePaths, [string]$DriverPath, [int]$ScratchSpace = 512)
    # Keep dependency packages and their language satellites ordered, not a directory-wide batch.
    foreach ($package in $PackagePaths) {
        Start-Step "Adding $(Split-Path -Leaf $package)"
        Invoke-Tool -FilePath $script:DismPath -What "Add $(Split-Path -Leaf $package)" -ArgumentList @(
            "/Image:$MountPath", '/Add-Package', "/PackagePath:$package")
        Write-StepDone "Added $(Split-Path -Leaf $package)"
    }
    $driverInf = if (Test-Path -LiteralPath $DriverPath -PathType Container) {
        Get-ChildItem -LiteralPath $DriverPath -Recurse -Filter *.inf -File -ErrorAction Stop | Select-Object -First 1
    }
    if ($driverInf) {
        Start-Step 'Injecting WinPE boot drivers'
        $driverArgs = @("/Image:$MountPath", '/Add-Driver', "/Driver:$DriverPath", '/Recurse')
        try { Invoke-Tool -FilePath $script:DismPath -What 'Add WinPE drivers' -ArgumentList $driverArgs }
        catch {
            if ($_.Exception.Message -notmatch '(?i)0xc1420117|c1420117') { throw }
            Invoke-Tool -FilePath $script:DismPath -What 'Remount owned boot.wim' -ArgumentList @(
                '/Remount-Image', "/MountDir:$MountPath")
            Invoke-Tool -FilePath $script:DismPath -What 'Add WinPE drivers (retry)' -ArgumentList $driverArgs
        }
        Write-StepDone 'Injected WinPE boot drivers'
    }
    else { Write-StepSkipped 'WinPE boot drivers (none found)' }
    Invoke-Tool -FilePath $script:DismPath -What 'Set scratch space' -ArgumentList @(
        "/Image:$MountPath", "/Set-ScratchSpace:$ScratchSpace")
}

function Invoke-WinPEImageBuild {
    param($CachePlan, [string]$SourceWim, [string]$BootWim, [string]$MountPath,
        [string[]]$PackagePaths, [string]$DriverPath, [object[]]$RuntimeFiles,
        [string]$PayloadSource, [string]$BootsectSource, [string]$Resolution,
        [int]$ScratchSpace = 512, [switch]$NoCache)
    if (-not (Test-PathWithin $BootWim $script:OwnedWorkspace) -or
        -not (Test-PathWithin $MountPath $script:OwnedWorkspace) -or
        (Test-PathWithin $CachePlan.BasePath $script:OwnedWorkspace) -or
        (Test-PathWithin $CachePlan.FinalPath $script:OwnedWorkspace) -or
        [IO.Path]::GetFullPath($SourceWim) -eq [IO.Path]::GetFullPath($BootWim)) {
        throw 'WIM servicing requires an owned working copy, separate from source and caches.'
    }
    Start-BuildPhase 'hash/cache verification'
    $finalHit = -not $NoCache -and (Test-WinPECacheImage -Path $CachePlan.FinalPath)
    $baseHit = -not $NoCache -and -not $finalHit -and (Test-WinPECacheImage -Path $CachePlan.BasePath)
    Write-BuildLog ("WIM final cache {0}: {1}" -f $(if ($finalHit) { 'HIT' } else { 'MISS' }), $CachePlan.FinalKey)
    if (-not $finalHit) {
        Write-BuildLog ("WIM base cache {0}: {1}" -f $(if ($baseHit) { 'HIT' } else { 'MISS' }), $CachePlan.BaseKey)
    }
    if ($NoCache) { Write-BuildLog 'NoCache: bypassing both WIM cache levels (reads and writes)' }
    Stop-BuildPhase 'hash/cache verification'
    Start-BuildPhase 'servicing'
    try {
        $source = if ($finalHit) { $CachePlan.FinalPath } elseif ($baseHit) { $CachePlan.BasePath } else { $SourceWim }
        Copy-Item -LiteralPath $source -Destination $BootWim -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $BootWim -Name IsReadOnly -Value $false
        if ($finalHit) { Write-StepSkipped 'Final WIM cache HIT (no mounting or servicing)'; return }
        $needsCleanup = $true
        try {
            Invoke-Tool -FilePath $script:DismPath -What 'Mount working boot.wim' -ArgumentList @(
                '/Mount-Image', "/ImageFile:$BootWim", '/Index:1', "/MountDir:$MountPath")
            if (-not $baseHit) {
                Invoke-WinPEBaseServicing -MountPath $MountPath -PackagePaths $PackagePaths -DriverPath $DriverPath -ScratchSpace $ScratchSpace
                if (-not $NoCache) {
                    Invoke-Tool -FilePath $script:DismPath -What 'Commit serviced base' -ArgumentList @(
                        '/Unmount-Image', "/MountDir:$MountPath", '/Commit')
                    $needsCleanup = $false
                    Publish-WinPECacheImage -Source $BootWim -Destination $CachePlan.BasePath
                    $needsCleanup = $true
                    Invoke-Tool -FilePath $script:DismPath -What 'Mount base working copy for runtime' -ArgumentList @(
                        '/Mount-Image', "/ImageFile:$BootWim", '/Index:1', "/MountDir:$MountPath")
                }
            }
            $system32 = Join-Path $MountPath 'Windows\System32'
            Sync-RuntimePayload -Destination (Join-Path $MountPath 'Payload') -RuntimeFiles $RuntimeFiles -PayloadSource $PayloadSource `
                -BootsectSource $BootsectSource -System32Path $system32
            Set-WinPEStartup -System32Path $system32 -Resolution $Resolution
            Invoke-Tool -FilePath $script:DismPath -What 'Commit customized WinPE image' -ArgumentList @(
                '/Unmount-Image', "/MountDir:$MountPath", '/Commit')
            $needsCleanup = $false
        }
        finally {
            if ($needsCleanup) { Clear-StaleMounts -MountPath $MountPath -ImagePath $BootWim }
        }
        if (-not $NoCache) { Publish-WinPECacheImage -Source $BootWim -Destination $CachePlan.FinalPath }
        Write-StepDone 'Committed customized WinPE image'
    }
    finally { Stop-BuildPhase 'servicing' }
}

function Assert-UsbPayloadOwnership {
    param([Parameter(Mandatory)]$Volume)
    $root = "$($Volume.DriveLetter):\Payload"
    Assert-NoReparsePath -Path $root -Recurse
    $marker = Join-Path $root 'UNE-Payload.tag'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim() -ne 'AutoReset deployment media') {
        throw 'PAYLOAD is not a recognized AutoReset payload; refusing a destructive mirror. Build fresh media instead.'
    }
}

function Copy-ChangedFile {
    param([string]$Source, [string]$Destination, [switch]$IgnoreAccessDenied)
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        }
        catch {
            $isAccessDenied = $_.Exception -is [UnauthorizedAccessException] -or $_.Exception.Message -match '(?i)access.*denied'
            if (-not $IgnoreAccessDenied -or -not $isAccessDenied) { throw }
            Write-BuildLog "Skipping protected file update (access denied): $Destination"
        }
    }
}

function Copy-RuntimeScript {
    param([string]$Source, [string]$Destination)
    $text = [IO.File]::ReadAllText($Source, [Text.UTF8Encoding]::new($false, $true))
    $encoding = [Text.UTF8Encoding]::new($true, $true)
    [byte[]]$bytes = $encoding.GetPreamble() + $encoding.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $expectedHash) {
        [IO.File]::WriteAllBytes($Destination, $bytes)
    }
}

function Get-RuntimeSourceFiles {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($name in @('autoreset.ps1', 'killdisk.ps1', 'autoreset.common.ps1', 'autoreset.ui.ps1')) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required runtime source missing: $path" }
        Assert-NoReparsePath -Path $path
        Get-Item -LiteralPath $path
    }
}

function Sync-RuntimePayload {
    param([string]$Destination, [object[]]$RuntimeFiles, [string]$PayloadSource,
        [string]$BootsectSource, [string]$System32Path)
    $scripts = Join-Path $Destination 'Scripts'
    Assert-NoReparsePath -Path $Destination -Recurse
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    foreach ($stale in @(Get-ChildItem -LiteralPath $scripts -Force)) {
        if ($stale.PSIsContainer -or $stale.Name -notin $RuntimeFiles.Name) {
            Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop
        }
    }
    foreach ($file in $RuntimeFiles) { Copy-RuntimeScript -Source $file.FullName -Destination (Join-Path $scripts $file.Name) }

    $configSource = Join-Path $PayloadSource 'reset.json'
    $configDestDir = Join-Path $Destination 'Config'
    New-Item -ItemType Directory -Path $configDestDir -Force | Out-Null
    foreach ($stale in @(Get-ChildItem -LiteralPath $configDestDir -Force -ErrorAction SilentlyContinue)) {
        if ($stale.PSIsContainer -or $stale.Name -ne 'reset.json') {
            Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop
        }
    }
    Copy-ChangedFile -Source $configSource -Destination (Join-Path $configDestDir 'reset.json')

    $toolsSource = Join-Path $PayloadSource 'tools'
    $toolsDest = Join-Path $Destination 'Tools'
    if (Test-Path -LiteralPath $toolsSource -PathType Container) {
        Invoke-Robocopy -Source $toolsSource -Dest $toolsDest -Extra @('/MIR') -What 'Tools runtime sync'
    }
    elseif (Test-Path -LiteralPath $toolsDest) { Remove-Item -LiteralPath $toolsDest -Recurse -Force -ErrorAction Stop }

    if ($BootsectSource) {
        $tools = Join-Path $Destination 'Tools'
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Copy-ChangedFile -Source $BootsectSource -Destination (Join-Path $tools 'bootsect.exe')
        if ($System32Path) {
            Assert-NoReparsePath -Path $System32Path
            if (-not (Test-Path -LiteralPath $System32Path -PathType Container)) {
                throw "WinPE System32 directory missing: $System32Path"
            }
            Copy-ChangedFile -Source $BootsectSource -Destination (Join-Path $System32Path 'bootsect.exe') -IgnoreAccessDenied
        }
    }
}

function Assert-BuildPayload {
    param([string]$PayloadSource, [string]$InstallImage, [switch]$BootOnly)
    $config = Join-Path $PayloadSource 'reset.json'
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "Required configuration missing: $config" }
    Assert-NoReparsePath -Path $PayloadSource -Recurse
    $settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $settings -or $settings -is [array] -or $settings -isnot [pscustomobject]) {
        throw 'reset.json must contain a configuration object.'
    }
    if (-not $BootOnly -and -not (Test-Path -LiteralPath $InstallImage -PathType Leaf)) {
        throw "Installation image missing: $InstallImage. Supply install.wim or explicitly use -SkipPayload."
    }
    if (-not $BootOnly) { Assert-NoReparsePath -Path $InstallImage }
}

function Get-BootPartitionSize {
    param([object[]]$Files)
    if (@($Files | Where-Object { $_.Length -ge 4GB }).Count) {
        throw 'A boot file exceeds the FAT32 single-file limit (4 GiB minus one byte).'
    }
    $bytes = ($Files | Measure-Object -Property Length -Sum).Sum
    $size = [long]([math]::Ceiling(([math]::Max([double]512MB, $bytes * 1.15 + 128MB)) / 1MB) * 1MB)
    if ($size -gt 32GB) { throw 'Boot files exceed the supported 32 GiB FAT32 partition limit.' }
    return $size
}

function Assert-UpdateCapacity {
    param([object[]]$BootFiles, [object[]]$PayloadFiles, $BootVolume, $PayloadVolume)
    $null = Get-BootPartitionSize -Files $BootFiles
    foreach ($entry in @(
        @{ Files = $BootFiles; Volume = $BootVolume; Root = "$($BootVolume.DriveLetter):\" },
        @{ Files = $PayloadFiles; Volume = $PayloadVolume; Root = "$($PayloadVolume.DriveLetter):\Payload" })) {
        $bytes = ($entry.Files | Measure-Object Length -Sum).Sum
        # Only count files this build will replace, not arbitrary user files or Logs.
        $reclaimable = 0L
        foreach ($file in $entry.Files) {
            $dest = Join-Path $entry.Root $file.RelativePath
            if (Test-Path -LiteralPath $dest -PathType Leaf) { $reclaimable += (Get-Item -LiteralPath $dest).Length }
        }
        if ($bytes + 64MB -gt $entry.Volume.SizeRemaining + $reclaimable) {
            throw "Insufficient space on $($entry.Volume.FileSystemLabel); repartition on a larger disk or free space."
        }
    }
}

function Assert-BuildPartitionMapping {
    param([int]$DiskNumber, [int]$PartitionNumber, [char]$DriveLetter)
    $partitions = @(Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop)
    if ($partitions.Count -ne 1 -or $partitions[0].DiskNumber -ne $DiskNumber -or
        $partitions[0].PartitionNumber -ne $PartitionNumber) {
        throw "Drive $DriveLetter no longer belongs to the expected USB partition."
    }
}

function Get-MediaFileInventory {
    param([string]$Root, [switch]$ExcludePayload)
    $Root = [IO.Path]::GetFullPath($Root)
    $prefixLength = $Root.TrimEnd('\', '/').Length
    Assert-NoReparsePath -Path $Root
    # Exclude Payload before recursion so boot inventories never walk large payload trees.
    foreach ($entry in Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop) {
        if ($ExcludePayload -and $entry.Name -eq 'Payload') { continue }
        Assert-NoReparsePath -Path $entry.FullName -Recurse
        $files = if ($entry.PSIsContainer) {
            Get-ChildItem -LiteralPath $entry.FullName -Recurse -File -Force -ErrorAction Stop
        } else { $entry }
        foreach ($file in $files) {
            [pscustomobject]@{
                Length = $file.Length
                RelativePath = $file.FullName.Substring($prefixLength).TrimStart('\', '/')
                SourcePath = $file.FullName
            }
        }
    }
}

function ConvertTo-BuildRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^[\\/]|[:*?"<>|\x00-\x1f]') {
        throw "Unsafe relative path in file manifest: $Path"
    }
    $parts = $Path -split '[\\/]'
    foreach ($part in $parts) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[. ]$' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Ambiguous or traversal path in file manifest: $Path"
        }
    }
    return $parts -join '/'
}

function Sync-BuildFiles {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The public manifest contract synchronizes a collection of files.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Mirror,
        [string[]]$PreserveDirectories = @('Logs')
    )
    if ([string]::IsNullOrWhiteSpace($Destination) -or $Destination -match '(^|[\\/])\.\.?([\\/]|$)|^[A-Za-z]:($|[^\\/])') {
        throw 'Refusing an ambiguous sync destination.'
    }
    $destRoot = [IO.Path]::GetFullPath($Destination)
    if ($Mirror -and $destRoot.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($destRoot).TrimEnd('\', '/')) {
        throw 'Refusing to mirror a volume root.'
    }
    Assert-NoReparsePath -Path $destRoot -Recurse
    if ((Test-Path -LiteralPath $destRoot) -and -not (Test-Path -LiteralPath $destRoot -PathType Container)) {
        throw 'Sync destination must be a directory.'
    }
    $preserved = @('Logs') + @($PreserveDirectories) | Select-Object -Unique
    $preserved = @($preserved | ForEach-Object { ConvertTo-BuildRelativePath $_ })
    $names = @{}
    $directories = @{}
    $plan = @(
        foreach ($file in $Files) {
            $relative = ConvertTo-BuildRelativePath ([string]$file.RelativePath)
            foreach ($keep in $preserved) {
                if ($relative -eq $keep -or $relative.StartsWith("$keep/", [StringComparison]::OrdinalIgnoreCase) -or
                    $keep.StartsWith("$relative/", [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Manifest collides with preserved directory: $relative"
                }
            }
            if ($names.ContainsKey($relative)) { throw "Duplicate manifest path: $relative" }
            $names[$relative] = $true
            $parent = $relative
            while ($parent.Contains('/')) {
                $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
                $directories[$parent] = $true
            }
            if ([string]::IsNullOrWhiteSpace([string]$file.SourcePath)) { throw "Manifest source missing: $relative" }
            $source = [IO.Path]::GetFullPath($file.SourcePath)
            if (Test-PathWithin $source $destRoot) { throw "Manifest source is under destination: $source" }
            Assert-NoReparsePath -Path $source
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Manifest source missing: $source" }
            $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if ($null -eq $file.Length -or [long]$file.Length -ne $sourceItem.Length) {
                throw "Manifest source length changed: $source"
            }
            $target = Join-Path $destRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not (Test-PathWithin $target $destRoot)) { throw "Manifest path escapes destination: $relative" }
            [pscustomobject]@{ SourcePath = $source; TargetPath = $target; RelativePath = $relative; Length = $sourceItem.Length }
        }
    )
    # Validate the entire plan before copying or deleting anything.
    foreach ($relative in $names.Keys) {
        if ($directories.ContainsKey($relative)) { throw "Manifest file/directory conflict: $relative" }
    }
    foreach ($entry in $plan) {
        if (Test-Path -LiteralPath $entry.TargetPath -PathType Container) {
            throw "Destination file/directory conflict: $($entry.RelativePath)"
        }
    }
    foreach ($relative in $directories.Keys) {
        if (Test-Path -LiteralPath (Join-Path $destRoot $relative) -PathType Leaf) {
            throw "Destination file/directory conflict: $relative"
        }
    }
    $existing = @()
    if ($Mirror -and (Test-Path -LiteralPath $destRoot -PathType Container)) {
        $existing = @(Get-ChildItem -LiteralPath $destRoot -Recurse -Force -ErrorAction Stop)
    }
    $copied = 0L; $skipped = 0L; $copiedBytes = 0L; $skippedBytes = 0L
    foreach ($entry in $plan) {
        $same = $false
        $sourceItem = Get-Item -LiteralPath $entry.SourcePath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf) {
            $targetItem = Get-Item -LiteralPath $entry.TargetPath -Force -ErrorAction Stop
            $same = $targetItem.Length -eq $entry.Length
            if ($same) {
                # Fast path: unchanged size + timestamp means no expensive hash pass.
                $timeDelta = [math]::Abs(($sourceItem.LastWriteTimeUtc - $targetItem.LastWriteTimeUtc).TotalSeconds)
                if ($timeDelta -le 2) {
                    $same = $true
                }
                else {
                    $same = (Get-FileHash -LiteralPath $entry.SourcePath -Algorithm SHA256 -ErrorAction Stop).Hash -eq
                        (Get-FileHash -LiteralPath $entry.TargetPath -Algorithm SHA256 -ErrorAction Stop).Hash
                }
            }
        }
        if ($same) { $skipped++; $skippedBytes += $entry.Length; continue }
        New-Item -ItemType Directory -Path (Split-Path -Parent $entry.TargetPath) -Force | Out-Null
        Copy-Item -LiteralPath $entry.SourcePath -Destination $entry.TargetPath -Force -ErrorAction Stop
        try { (Get-Item -LiteralPath $entry.TargetPath -Force -ErrorAction Stop).LastWriteTimeUtc = $sourceItem.LastWriteTimeUtc } catch { }
        $copied++; $copiedBytes += $entry.Length
    }
    foreach ($item in ($existing | Sort-Object { $_.FullName.Length } -Descending)) {
        $relative = $item.FullName.Substring($destRoot.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
        $keepItem = $false
        foreach ($keep in $preserved) {
            if ($relative -eq $keep -or $relative.StartsWith("$keep/", [StringComparison]::OrdinalIgnoreCase) -or
                $keep.StartsWith("$relative/", [StringComparison]::OrdinalIgnoreCase)) { $keepItem = $true; break }
        }
        if ($keepItem) { continue }
        if ($item.PSIsContainer) {
            if (@(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            }
        }
        elseif (-not $names.ContainsKey($relative)) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        }
    }
    Write-BuildLog "Copy $Destination : copied $copied files / $copiedBytes bytes; skipped $skipped files / $skippedBytes bytes"
}

function New-UsbLayout {
    param([int]$DiskNumber, [string]$ExpectedIdentity, [int[]]$ProtectedDiskNumbers,
        [long]$BootPartitionSize, [switch]$AllowNonUsb)
    $guard = @{ DiskNumber = $DiskNumber; ExpectedIdentity = $ExpectedIdentity
        ProtectedDiskNumbers = $ProtectedDiskNumbers; AllowNonUsb = $AllowNonUsb }
    $disk = Assert-BuildDiskSafe @guard
    if ($disk.Size -gt 2TB) { throw 'This BIOS/UEFI MBR layout supports disks up to 2 TiB only.' }
    if ($disk.PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }
    $disk = Assert-BuildDiskSafe @guard
    if ($disk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop | Out-Null
    }
    elseif ($disk.PartitionStyle -ne 'MBR') {
        Set-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop
    }
    $null = Assert-BuildDiskSafe @guard
    $boot = New-Partition -DiskNumber $DiskNumber -Size $BootPartitionSize -IsActive -AssignDriveLetter -ErrorAction Stop
    $null = Assert-BuildDiskSafe @guard
    Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'PE' -Confirm:$false -ErrorAction Stop | Out-Null
    $null = Assert-BuildDiskSafe @guard
    $payload = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    $null = Assert-BuildDiskSafe @guard
    Format-Volume -Partition $payload -FileSystem NTFS -NewFileSystemLabel 'PAYLOAD' -Confirm:$false -ErrorAction Stop | Out-Null
    return [pscustomobject]@{ Boot = $boot; Payload = $payload }
}

function Set-WinPEStartup {
    param([string]$System32Path, [string]$Resolution)
    $unattendPath = Join-Path $System32Path 'winpe-unattend.xml'
    $wpeinitArgs = ''
    if ($Resolution) {
        if ($Resolution -notmatch '^\d{3,4}x\d{3,4}$') { throw 'Invalid WinPE resolution.' }
        $resParts = $Resolution -split 'x'
        $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Display>
        <ColorDepth>32</ColorDepth>
        <HorizontalResolution>$($resParts[0])</HorizontalResolution>
        <VerticalResolution>$($resParts[1])</VerticalResolution>
        <RefreshRate>60</RefreshRate>
      </Display>
    </component>
  </settings>
</unattend>
"@
        Set-Content -LiteralPath $unattendPath -Value $unattend -Encoding UTF8
        $wpeinitArgs = ' -unattend:X:\Windows\System32\winpe-unattend.xml'
    }
    elseif (Test-Path -LiteralPath $unattendPath) { Remove-Item -LiteralPath $unattendPath -Force -ErrorAction Stop }
    $shellInit = '%SYSTEMDRIVE%\Windows\System32\wpeinit.exe'
    if ($wpeinitArgs) { $shellInit += ',' + $wpeinitArgs }
    Set-Content -LiteralPath (Join-Path $System32Path 'winpeshl.ini') -Encoding Ascii -Value @(
        '[LaunchApps]', $shellInit,
        '%SYSTEMDRIVE%\Windows\System32\WindowsPowerShell\v1.0\powershell.exe, -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File X:\Payload\Scripts\autoreset.ps1')
    Set-Content -LiteralPath (Join-Path $System32Path 'startnet.cmd') -Encoding Ascii -Value @(
        '@echo off', "wpeinit$wpeinitArgs",
        'X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Payload\Scripts\autoreset.ps1')
}

function Assert-RuntimeExtractor {
    param([Parameter(Mandatory)][string]$Path)
    Assert-NoReparsePath -Path $Path
    $data = [IO.File]::ReadAllBytes($Path)
    if ($data.Length -lt 64 -or [BitConverter]::ToUInt16($data, 0) -ne 0x5A4D) { throw "Invalid runtime extractor: $Path" }
    $pe = [BitConverter]::ToInt32($data, 60)
    if ($pe -lt 64 -or $pe + 264 -gt $data.Length -or [BitConverter]::ToUInt32($data, $pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($data, $pe + 4) -ne 0x8664 -or [BitConverter]::ToUInt16($data, $pe + 24) -ne 0x20B) {
        throw '7za.exe must be a standalone AMD64 Windows executable for this WinPE image.'
    }
    $sectionCount = [BitConverter]::ToUInt16($data, $pe + 6)
    $sectionStart = $pe + 24 + [BitConverter]::ToUInt16($data, $pe + 20)
    function Get-ImageOffset([uint32]$Rva) {
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $offset = $sectionStart + $i * 40
            if ($offset + 40 -gt $data.Length) { throw 'Invalid extractor section table.' }
            $address = [BitConverter]::ToUInt32($data, $offset + 12)
            $size = [BitConverter]::ToUInt32($data, $offset + 16)
            if ($Rva -ge $address -and $Rva - $address -lt $size) {
                $result = [long][BitConverter]::ToUInt32($data, $offset + 20) + $Rva - $address
                if ($result -ge $data.Length) { throw 'Invalid extractor section offset.' }
                return [int]$result
            }
        }
        throw 'Invalid extractor import address.'
    }
    # Reject non-inbox runtimes (for example VC redistributables installed only on the build host).
    $inbox = @('kernel32.dll', 'kernelbase.dll', 'ntdll.dll', 'user32.dll', 'advapi32.dll', 'msvcrt.dll',
        'ole32.dll', 'oleaut32.dll', 'shell32.dll', 'shlwapi.dll', 'gdi32.dll', 'comdlg32.dll',
        'comctl32.dll', 'crypt32.dll', 'bcrypt.dll', 'version.dll', 'secur32.dll', 'rpcrt4.dll')
    $importRva = [BitConverter]::ToUInt32($data, $pe + 24 + 120)
    if (-not $importRva) { throw 'Extractor has no verifiable import table.' }
    if ([BitConverter]::ToUInt32($data, $pe + 24 + 216)) { throw 'Delay-loaded extractor dependencies are not supported.' }
    $import = Get-ImageOffset $importRva
    while ($true) {
        if ($import + 20 -gt $data.Length) { throw 'Invalid extractor import table.' }
        $nameRva = [BitConverter]::ToUInt32($data, $import + 12)
        if (-not $nameRva) { break }
        $nameOffset = Get-ImageOffset $nameRva
        $end = $nameOffset
        while ($end -lt $data.Length -and $data[$end]) { $end++ }
        if ($end -eq $data.Length) { throw 'Invalid extractor import name.' }
        $name = [Text.Encoding]::ASCII.GetString($data, $nameOffset, $end - $nameOffset)
        if ($name -notin $inbox) { throw "Extractor dependency '$name' is not guaranteed in WinPE; use standalone AMD64 7za.exe." }
        $import += 20
    }
    Invoke-Tool -FilePath $Path -ArgumentList @('i') -What 'Validate WinPE runtime extractor'
    return $Path
}

# ── Driver archive change detection ─────────────────────────────────

function Get-DriverSourceHash {
    param([Parameter(Mandatory)][string]$SourcePath, [object[]]$Files)
    if (-not $PSBoundParameters.ContainsKey('Files')) {
        Assert-NoReparsePath -Path $SourcePath -Recurse
        $Files = @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -notin @('Drivers.zip', 'Drivers.7z', 'Drivers.7z.hash', 'Drivers.zip.hash') })
    }
    if ($Files.Count -eq 0) { return $null }
    $root = [IO.Path]::GetFullPath($SourcePath).TrimEnd('\', '/')
    $parts = foreach ($file in ($Files | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        "$relative|$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
    }
    return Get-BuildPartsHash -Parts $parts
}

function Invoke-DriverArchive {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ArchiveDir,
        [string]$Label,
        [switch]$ForceRebuild,
        [ValidateSet('Fast', 'Balanced', 'Maximum')]
        [string]$Compression = $(if ($DriverCompression) { $DriverCompression } else { 'Fast' })
    )
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { return $null }
    Assert-NoReparsePath -Path $SourcePath -Recurse
    Assert-NoReparsePath -Path $ArchiveDir -Recurse
    $files = @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -notin @('Drivers.zip', 'Drivers.7z', 'Drivers.7z.hash', 'Drivers.zip.hash') })
    if ($files.Count -eq 0) { return $null }

    if (-not $Label) { $Label = Split-Path -Leaf $SourcePath }

    $sevenZipPath = $script:RuntimeExtractor
    $use7z        = [bool]$sevenZipPath
    $archiveExt   = if ($use7z) { '7z' } else { 'zip' }
    $archivePath  = Join-Path $ArchiveDir "Drivers.$archiveExt"
    $hashPath     = "$archivePath.hash"
    $staleExt = if ($use7z) { 'zip' } else { '7z' }
    foreach ($stale in @("Drivers.$staleExt", "Drivers.$staleExt.hash")) {
        $stalePath = Join-Path $ArchiveDir $stale
        if (Test-Path -LiteralPath $stalePath) { Remove-Item -LiteralPath $stalePath -Force -ErrorAction Stop }
    }

    $options = switch ($Compression) {
        'Fast' { @('-m0=lzma2', '-mx=1', '-ms=on') }
        'Balanced' { @('-m0=lzma2', '-mx=5', '-ms=on') }
        'Maximum' { @('-m0=lzma2', '-mx=9', '-mfb=273', '-md=128m', '-ms=on') }
    }
    $zipLevel = if ($Compression -eq 'Fast') { 'Fastest' } else { 'Optimal' }
    $extractorHash = if ($use7z) {
        Assert-NoReparsePath -Path $sevenZipPath
        (Get-FileHash -LiteralPath $sevenZipPath -Algorithm SHA256 -ErrorAction Stop).Hash
    } else { 'dotnet-zip' }
    $sourceHash = Get-DriverSourceHash -SourcePath $SourcePath -Files $files
    $currentHash = Get-BuildPartsHash -Parts @('driver-archive-v2', $sourceHash, $Compression, ($options -join ' '), $zipLevel, $extractorHash)
    if (-not $currentHash) { return $null }

    if (-not $ForceRebuild -and (Test-Path -LiteralPath $archivePath) -and (Test-Path -LiteralPath $hashPath)) {
        $storedHash = ''
        try { $storedHash = (Get-Content -LiteralPath $hashPath -Raw -ErrorAction Stop).Trim() }
        catch { Write-BuildLog "Driver cache MISS (unreadable receipt): $archivePath" }
        $expectedHash = "$currentHash|$((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash)"
        if ($storedHash -eq $expectedHash) {
            $sizeMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 0)
            Write-StepSkipped "Drivers ($Label): archive current ($sizeMB MB, no changes)"
            Write-BuildLog "Driver cache HIT: $archivePath (content, extractor and $Compression receipt verified)"
            return $archivePath
        }
    }
    Write-BuildLog "Driver cache MISS: $archivePath ($Compression)"

    New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    $uncompressedMB = [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 0)
    $stagingArchive = Join-Path $WorkDir ('Drivers-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + ".$archiveExt")
    Remove-Item -LiteralPath $stagingArchive -Force -ErrorAction SilentlyContinue

    if ($use7z) {
        Start-Step "Compressing drivers ($Label): $($files.Count) files, $uncompressedMB MB (7z LZMA2)"
        Invoke-Tool -FilePath $sevenZipPath -What "7z archive ($Label)" -ArgumentList (@(
            'a', '-t7z') + $options + @(
            '-xr!Drivers.7z', '-xr!Drivers.zip', '-xr!Drivers.7z.hash', '-xr!Drivers.zip.hash',
            $stagingArchive, (Join-Path $SourcePath '*')))
        Invoke-Tool -FilePath $sevenZipPath -ArgumentList @('t', $stagingArchive) -What 'Test new archive with runtime extractor'
    }
    else {
        Write-Aside 'No compatible runtime extractor supplied. Using .NET ZIP.'
        Start-Step "Compressing drivers ($Label): $($files.Count) files, $uncompressedMB MB (ZIP deflate)"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::Open($stagingArchive, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($SourcePath.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $file.FullName, $relative, [IO.Compression.CompressionLevel]$zipLevel) | Out-Null
            }
        }
        finally { $zip.Dispose() }
    }

    Move-Item -LiteralPath $stagingArchive -Destination $archivePath -Force
    Set-Content -LiteralPath $hashPath -Value "$currentHash|$((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash)" -Encoding UTF8

    $compressedMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 0)
    $ratio = if ($uncompressedMB -gt 0) { [math]::Round((1 - $compressedMB / $uncompressedMB) * 100, 0) } else { 0 }
    Write-StepDone "Compressed drivers ($Label): $uncompressedMB MB -> $compressedMB MB ($ratio% smaller)"
    Write-BuildLog "Driver archive built: $archivePath (hash $currentHash)"
    return $archivePath
}

# ── Cleanup helper ───────────────────────────────────────────────────

function Complete-WorkingFolder {
    if ($KeepWorkDir -or
        -not (Test-Path -LiteralPath $WorkDir)) { return }
    if ($WorkDir -cne $script:OwnedWorkspace -or (Split-Path -Leaf $WorkDir) -notmatch '^AutoReset-Build-[0-9a-f]{32}$') {
        throw 'Refusing cleanup of an unowned workspace.'
    }
    Assert-NoReparsePath -Path $WorkDir -Recurse
    if (@(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object {
        (Test-PathWithin $_.Path $WorkDir) -or (Test-PathWithin $_.ImagePath $WorkDir)
    }).Count) { throw 'Workspace still contains a mounted image; retaining it.' }
    try { Remove-Item -LiteralPath $script:OwnedWorkspace -Recurse -Force -ErrorAction Stop }
    catch { Write-Aside "Couldn't remove temp workspace: $($_.Exception.Message)" }
}

# ── Output root ──────────────────────────────────────────────────────

function Initialize-OutputRoot {
    $driveRoot = [System.IO.Path]::GetPathRoot($OutputRoot)
    if (-not $driveRoot -or -not (Test-Path -LiteralPath $driveRoot)) {
        throw "Build output drive '$driveRoot' isn't available. Connect it or use -OutputRoot <folder>."
    }
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

# ── Header ───────────────────────────────────────────────────────────

function Show-Header {
    param([string]$Mode)
    Clear-Host
    $divider = [string]::new([char]0x2500, 50)
    Write-Host ''
    Write-Host "  AutoReset + KillDisk Build  v$($script:Version)" -ForegroundColor Cyan
    Write-Host "  $divider" -ForegroundColor DarkGray
    if ($Mode) {
        Write-Host "  Mode: $Mode" -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ── Image preparation ───────────────────────────────────────────────

function Invoke-ImagePreparation {
    if (-not (Test-Path -LiteralPath $SourceImage -PathType Leaf)) {
        throw "Source image not found: $SourceImage"
    }

    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    if (-not $DestinationImage) { $DestinationImage = Join-Path $preparedImagesRoot 'install.wim' }
    $DestinationImage = [System.IO.Path]::GetFullPath($DestinationImage)
    Assert-NoReparsePath -Path $SourceImage
    Assert-NoReparsePath -Path $DestinationImage
    if ([IO.Path]::GetFullPath($SourceImage) -eq $DestinationImage) { throw 'Source and destination image paths must differ.' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationImage) -Force | Out-Null

    Start-Step 'Reading image indexes'
    $output = & dism.exe /Get-WimInfo "/WimFile:$SourceImage" 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-StepFailed "Couldn't read $SourceImage"
        throw "DISM couldn't read $SourceImage.`n$($output -join "`n")"
    }

    $images = @(); $curIdx = $null
    foreach ($line in $output) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') { $curIdx = [int]$Matches[1] }
        elseif ($line -match '^\s*Name\s*:\s*(.+)$' -and $null -ne $curIdx) {
            $images += [pscustomobject]@{ Index = $curIdx; Name = $Matches[1].Trim() }
            $curIdx = $null
        }
    }
    if ($images.Count -eq 0) { throw "No image indexes found in $SourceImage." }
    Write-StepDone 'Read image indexes'

    $images | Format-Table Index, Name -AutoSize
    if ($ListOnly) { return }

    if ($SourceIndex) {
        $selected = $images | Where-Object Index -eq $SourceIndex | Select-Object -First 1
        if (-not $selected) { throw "Index $SourceIndex not found in $SourceImage." }
    }
    else {
        $selected = $images | Where-Object Name -eq $Edition | Select-Object -First 1
        if (-not $selected) { throw "Edition '$Edition' not found. Use -ListOnly or -SourceIndex." }
    }

    if (Test-Path -LiteralPath $DestinationImage) {
        if (-not $Rebuild) {
            $answer = Read-Host "Overwrite $DestinationImage? Type YES to continue"
            if ($answer -cne 'YES') { throw 'Aborted.' }
        }
    }

    $workingWim = Join-Path $WorkDir 'install-prepared.wim'
    Remove-Item -LiteralPath $workingWim -Force -ErrorAction SilentlyContinue

    Start-Step "Exporting [$($selected.Index)] $($selected.Name)"
    & dism.exe /Export-Image "/SourceImageFile:$SourceImage" "/SourceIndex:$($selected.Index)" `
        "/DestinationImageFile:$workingWim" /Compress:max /CheckIntegrity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-StepFailed 'Image export failed'; throw "DISM export failed (exit $LASTEXITCODE)." }
    Move-Item -LiteralPath $workingWim -Destination $DestinationImage -Force
    Write-StepDone "Exported [$($selected.Index)] $($selected.Name)"
    Write-Host ''
    Write-Host "  Ready: $DestinationImage" -ForegroundColor Green
}

# ── Driver preparation (standalone) ─────────────────────────────────

function Invoke-DriverPreparation {
    $driversRoot = Join-Path $ScriptRoot 'device-drivers'
    Assert-NoReparsePath -Path $driversRoot -Recurse
    Assert-NoReparsePath -Path $preparedDriversRoot -Recurse
    $extractor = Join-Path $ScriptRoot 'tools\7za.exe'
    $script:RuntimeExtractor = if (Test-Path -LiteralPath $extractor -PathType Leaf) { Assert-RuntimeExtractor -Path $extractor }

    if ($NoZip) {
        Write-Host "  Using raw drivers from: $driversRoot" -ForegroundColor Green
        return
    }

    if ($Device) {
        if ($Device -in @('.', '..') -or $Device -match '[\\/:*?"<>|]') { throw 'Device must be a single model folder name.' }
        $source     = Join-Path $driversRoot $Device
        $archiveDir = Join-Path $preparedDriversRoot $Device
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "Driver folder not found: $source"
        }
        $result = Invoke-DriverArchive -SourcePath $source -ArchiveDir $archiveDir `
            -Label $Device -ForceRebuild:$Force
        if (-not $result) { throw "No driver files found under $source." }
    }
    else {
        $modelFolders = @(Get-ChildItem -LiteralPath $driversRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name)
        if ($modelFolders.Count -eq 0) {
            $result = Invoke-DriverArchive -SourcePath $driversRoot -ArchiveDir $preparedDriversRoot `
                -Label 'all' -ForceRebuild:$Force
            if (-not $result) { throw "No driver files found under $driversRoot." }
        }
        else {
            $built = 0
            foreach ($modelFolder in $modelFolders) {
                $archiveDir = Join-Path $preparedDriversRoot $modelFolder.Name
                $result = Invoke-DriverArchive -SourcePath $modelFolder.FullName -ArchiveDir $archiveDir `
                    -Label $modelFolder.Name -ForceRebuild:$Force
                if ($result) { $built++ }
            }
            if ($built -eq 0) { throw "No driver files found under $driversRoot." }
        }
    }
}

# ── USB validation ──────────────────────────────────────────────────

function Invoke-UsbValidation {
    $lines   = [System.Collections.Generic.List[string]]::new()
    $validation = @{ HasFail = $false }

    function Report([string]$Text) {
        $lines.Add($Text)
        $colour = if ($Text -like 'FAIL:*') { 'Red' }
                  elseif ($Text -like 'WARN:*') { 'Yellow' }
                  else { 'Green' }
        if ($Text -like 'FAIL:*') { $validation.HasFail = $true }
        Write-Host "  $Text" -ForegroundColor $colour
    }

    $boot = $null
    $payload = $null
    try {
        $volumes = Get-ValidatedUsbVolumes
        $boot = $volumes.Boot
        $payload = $volumes.Payload
    }
    catch { Report "FAIL: $($_.Exception.Message)" }

    if (-not $boot) { Report 'FAIL: PE boot volume not found.' }
    else {
        Report ("PASS: PE found ({0}:, {1:N0} MB free)" -f $boot.DriveLetter, ($boot.SizeRemaining / 1MB))
        $bootRoot = "$($boot.DriveLetter):\"
        foreach ($rel in @('sources\boot.wim', 'bootmgr', 'EFI\Boot\bootx64.efi')) {
            if (Test-Path (Join-Path $bootRoot $rel)) { Report "PASS: $rel" }
            else { Report "FAIL: missing $rel" }
        }
    }

    if ($payload) {
        if (-not $payload) { Report 'FAIL: PAYLOAD volume not found.' }
        else {
            Report ("PASS: PAYLOAD found ({0}:, {1:N1} GB free)" -f $payload.DriveLetter, ($payload.SizeRemaining / 1GB))
            $payloadRoot = "$($payload.DriveLetter):\Payload"
            $required = @('UNE-Payload.tag', 'Config\reset.json', 'Scripts\autoreset.ps1',
                'Scripts\killdisk.ps1', 'Scripts\autoreset.common.ps1', 'Scripts\autoreset.ui.ps1')
            if (-not $SkipPayload) { $required += 'Images\install.wim' }
            foreach ($rel in $required) {
                if (Test-Path (Join-Path $payloadRoot $rel)) { Report "PASS: Payload\$rel" }
                else { Report "FAIL: missing Payload\$rel" }
            }

            $hasDrivers = $false
            $archiveNames = if ($SkipPayload) { @() } else { @('Drivers.7z', 'Drivers.zip') }
            foreach ($archiveName in $archiveNames) {
                $allArchive = Join-Path $payloadRoot "Drivers\$archiveName"
                if (Test-Path -LiteralPath $allArchive) {
                    $sizeMB = [math]::Round((Get-Item $allArchive).Length / 1MB, 0)
                    Report "PASS: all-model $archiveName present ($sizeMB MB)."
                    $hasDrivers = $true; break
                }
                $modelArchives = @(Get-ChildItem -Path (Join-Path $payloadRoot 'Drivers') -Recurse -Filter $archiveName -File -ErrorAction SilentlyContinue)
                if ($modelArchives.Count -gt 0) {
                    Report "PASS: $($modelArchives.Count) model-specific $archiveName archive(s) present."
                    $hasDrivers = $true; break
                }
            }
            if (-not $SkipPayload -and -not $hasDrivers) {
                if (Test-Path (Join-Path $payloadRoot 'Drivers')) { Report 'PASS: raw Drivers folder present.' }
                else { Report 'WARN: no driver package found.' }
            }
        }
    }

    if ($LogFile) {
        $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($LogFile))
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -LiteralPath $LogFile -Value $lines -Encoding UTF8
    }
    if ($validation.HasFail) { throw 'USB validation failed.' }
    Write-Host ''
    Write-Host '  USB validation passed.' -ForegroundColor Green
}

# ── ADK discovery ────────────────────────────────────────────────────

function Get-AdkPaths {
    $kitsRoot = $null
    foreach ($regPath in @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots',
            'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots')) {
        if (Test-Path $regPath) {
            $kitsRoot = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).KitsRoot10
            if ($kitsRoot) { break }
        }
    }
    if (-not $kitsRoot) { return $null }

    $adkRoot   = Join-Path $kitsRoot 'Assessment and Deployment Kit'
    $winpeRoot = Join-Path $adkRoot  'Windows Preinstallation Environment\amd64'
    $toolsDir  = Join-Path $adkRoot  'Deployment Tools\amd64'
    $bootsect  = Join-Path $toolsDir 'BCDBoot\bootsect.exe'
    $oscdimg   = Join-Path $toolsDir 'Oscdimg\oscdimg.exe'
    $dism      = Join-Path $toolsDir 'DISM\dism.exe'

    if (-not (Test-Path (Join-Path $winpeRoot 'en-us\winpe.wim'))) { return $null }
    if (-not (Test-Path $bootsect)) { return $null }
    if (-not (Test-Path $dism)) { return $null }

    return [pscustomobject]@{
        AdkRoot   = $adkRoot
        WinpeRoot = $winpeRoot
        Bootsect  = $bootsect
        Oscdimg   = $oscdimg
        Dism      = $dism
    }
}

function Install-AdkPrerequisites {
    Start-Step 'Installing Windows ADK + WinPE add-on from Microsoft'
    $installers = @(
        @{  Name = 'Windows ADK (Deployment Tools)'
            Url  = 'https://go.microsoft.com/fwlink/?linkid=2289980'
            File = 'adksetup.exe'
            Args = @('/quiet', '/norestart', '/ceip', 'off', '/features', 'OptionId.DeploymentTools') },
        @{  Name = 'Windows PE add-on'
            Url  = 'https://go.microsoft.com/fwlink/?linkid=2289981'
            File = 'adkwinpesetup.exe'
            Args = @('/quiet', '/norestart', '/ceip', 'off', '/features', 'OptionId.WindowsPreinstallationEnvironment') }
    )
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        foreach ($inst in $installers) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
            $dest = Join-Path $WorkDir $inst.File
            Write-Aside "Downloading $($inst.Name)..."
            Invoke-WebRequest -Uri $inst.Url -OutFile $dest -UseBasicParsing
            Write-Aside "Installing $($inst.Name) (5-15 min, no progress)..."
            $proc = Start-Process -FilePath $dest -ArgumentList $inst.Args -Wait -PassThru
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                throw "$($inst.Name) installer failed (exit $($proc.ExitCode))."
            }
        }
    }
    finally { $ProgressPreference = $oldPref }
    Write-StepDone 'Installed Windows ADK + WinPE add-on'
}

# ── Stale mount cleanup ─────────────────────────────────────────────

function Clear-StaleMounts {
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)][string]$ImagePath)
    if (-not (Test-PathWithin $MountPath $script:OwnedWorkspace) -or
        -not (Test-PathWithin $ImagePath $script:OwnedWorkspace)) {
        throw 'Refusing mount cleanup outside the current owned workspace.'
    }
    $mounts = @(Get-WindowsImage -Mounted -ErrorAction Stop)
    $own = @()
    foreach ($mount in $mounts) {
        $overlap = (Test-PathWithin $mount.Path $script:OwnedWorkspace) -or
            (Test-PathWithin $script:OwnedWorkspace $mount.Path) -or
            (Test-PathWithin $mount.ImagePath $script:OwnedWorkspace)
        if (-not $overlap) { continue }
        if ([IO.Path]::GetFullPath($mount.Path).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($MountPath).TrimEnd('\', '/') -or
            [IO.Path]::GetFullPath($mount.ImagePath) -ne [IO.Path]::GetFullPath($ImagePath)) {
            throw "Unknown mount overlaps this build: $($mount.Path) -> $($mount.ImagePath). Resolve it with its owner."
        }
        $own += $mount
    }
    if ($own.Count -gt 1) { throw 'Ambiguous mount registrations; refusing cleanup.' }
    if ($own.Count -eq 1) {
        Invoke-Tool -FilePath $script:DismPath -What 'Discard exact owned mount' -ArgumentList @(
            '/Unmount-Image', "/MountDir:$MountPath", '/Discard')
        if (@(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -eq $MountPath }).Count) {
            throw "Owned mount remains registered: $MountPath. Workspace retained; no global cleanup attempted."
        }
    }
}

# ── Dispatch prep/validate modes early ──────────────────────────────

if ($PSCmdlet.ParameterSetName -ne 'ValidateUsb') {
    Assert-NoReparsePath -Path $OutputRoot
    Assert-NoReparsePath -Path $workParent
    Initialize-OutputRoot
    $script:BuildLog = Join-Path $artifactRoot 'build.log'
    Assert-NoReparsePath -Path $script:BuildLog
    Set-Content -LiteralPath $script:BuildLog -Value "AutoReset + KillDisk build - $(Get-Date)" -ErrorAction Stop
    Write-BuildLog "Version: $($script:Version)`nScriptRoot: $ScriptRoot`nWorkDir: $WorkDir`nNoCache: $NoCache`nSkipPayload: $SkipPayload`nDriverCompression: $DriverCompression"
}

switch ($PSCmdlet.ParameterSetName) {
    'PrepareImage' {
        Show-Header 'Prepare Image'
        try { Invoke-ImagePreparation; Complete-WorkingFolder }
        finally { Write-BuildTotal }
        return
    }
    'PrepareDrivers' {
        Show-Header 'Prepare Drivers'
        Start-BuildPhase 'drivers'
        try { Invoke-DriverPreparation; Complete-WorkingFolder }
        finally { Write-BuildTotal }
        return
    }
    'ValidateUsb' {
        Show-Header 'Validate USB'
        Invoke-UsbValidation; return
    }
}

# ── Preflight ────────────────────────────────────────────────────────

try {
Start-BuildPhase 'preflight'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This needs an elevated PowerShell prompt (DISM requires admin).'
}

$modeName = switch ($PSCmdlet.ParameterSetName) {
    'ISO'       { 'Build ISO' }
    'USBUPDATE' { 'Update USB' }
    default     { 'Build USB' }
}
Show-Header $modeName

$payloadSrc = $ScriptRoot
$runtimeSourceRoot = Join-Path $ScriptRoot 'usb-scripts'
$runtimeFiles = @(Get-RuntimeSourceFiles -Root $runtimeSourceRoot)
$externalInstallWim = Join-Path $preparedImagesRoot 'install.wim'
$localInstallWim = Join-Path $payloadSrc 'win-images\install.wim'
$installWim = if (Test-Path -LiteralPath $externalInstallWim -PathType Leaf) { $externalInstallWim } else { $localInstallWim }
Assert-BuildPayload -PayloadSource $payloadSrc -InstallImage $installWim -BootOnly:$SkipPayload
Assert-NoReparsePath -Path $cacheDir -Recurse
Assert-NoReparsePath -Path $preparedDriversRoot -Recurse
Assert-NoReparsePath -Path (Join-Path $ScriptRoot 'winpe-drivers') -Recurse
$runtimeExtractorPath = Join-Path $payloadSrc 'tools\7za.exe'
$script:RuntimeExtractor = if (Test-Path -LiteralPath $runtimeExtractorPath -PathType Leaf) {
    Assert-RuntimeExtractor -Path $runtimeExtractorPath
}
$protectedPaths = @($ScriptRoot, $OutputRoot, $workParent, $installWim)
$protectedDisks = @()
if (-not $BuildIso) {
    $protectedDisks = @(Get-BuildProtectedDiskNumbers -Paths $protectedPaths)
    if ($UpdateUsb) {
        $initialVolumes = Get-ValidatedUsbVolumes -ProtectedDiskNumbers $protectedDisks
        Assert-UsbPayloadOwnership -Volume $initialVolumes.Payload
        $targetIdentity = Get-BuildDiskIdentity -Disk $initialVolumes.Disk
        $targetNumber = $initialVolumes.Disk.Number
    }
    else {
        $initialDisk = Assert-BuildDiskSafe -DiskNumber $UsbDiskNumber -ProtectedDiskNumbers $protectedDisks -AllowNonUsb:$AllowNonUsbDisk
        $targetIdentity = Get-BuildDiskIdentity -Disk $initialDisk
    }
}

New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

# ── Step 1: Locate ADK ──────────────────────────────────────────────

Start-Step 'Locating Windows ADK'
$adk = Get-AdkPaths
if (-not $adk) {
    Write-StepFailed 'Windows ADK not found'
    $doInstall = [bool]$InstallPrerequisites
    if (-not $doInstall -and [Environment]::UserInteractive) {
        $answer = Read-Host '  Download and install from Microsoft now? (Y/N)'
        $doInstall = ($answer -match '^[Yy]')
    }
    if ($doInstall) {
        Install-AdkPrerequisites
        $adk = Get-AdkPaths
    }
    if (-not $adk) {
        throw ('Windows ADK not found. Re-run with -InstallPrerequisites, or install manually: ' +
               'https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install')
    }
}
$winpeRoot = $adk.WinpeRoot
$bootsect  = $adk.Bootsect
$oscdimg   = $adk.Oscdimg
$script:DismPath = $adk.Dism
Write-StepDone 'Located Windows ADK'
if (-not $SkipPayload) {
    Invoke-Tool -FilePath $script:DismPath -What 'Validate installation image' -ArgumentList @(
        '/Get-WimInfo', "/WimFile:$installWim")
}

$protectedPaths += @($winpeRoot, $bootsect)
if (-not $BuildIso) {
    $protectedDisks = @(Get-BuildProtectedDiskNumbers -Paths $protectedPaths)
    if ($UpdateUsb) {
        $null = Get-ValidatedUsbVolumes -ProtectedDiskNumbers $protectedDisks -ExpectedIdentity $targetIdentity
    }
    else {
        $null = Assert-BuildDiskSafe -DiskNumber $UsbDiskNumber -ExpectedIdentity $targetIdentity `
            -ProtectedDiskNumbers $protectedDisks -AllowNonUsb:$AllowNonUsbDisk
    }
}

if ($ScriptRoot -like '*OneDrive*') {
    Write-Aside "This folder is inside OneDrive. Work folder moved to $WorkDir to avoid sync issues."
    Write-Aside 'Consider moving the whole kit to a plain local folder like C:\AutoReset.'
}

# ── Step 2: Prepare work folder ─────────────────────────────────────

Start-Step 'Preparing work folder'
$mountDir = Join-Path $mountRoot 'boot-wim'
$mediaDir = Join-Path $WorkDir 'media'

Clear-StaleMounts -MountPath $mountDir -ImagePath (Join-Path $mediaDir 'sources\boot.wim')
if (Test-Path -LiteralPath $mountDir) { throw "New workspace mount directory already exists: $mountDir" }
New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $mediaDir 'sources') -Force | Out-Null
Write-StepDone 'Prepared work folder'
Stop-BuildPhase 'preflight'

# ── Step 3: Sync WinPE base media ───────────────────────────────────

Start-BuildPhase 'copy base media'
Start-Step 'Syncing WinPE base media'
Invoke-Robocopy -Source (Join-Path $winpeRoot 'Media') -Dest $mediaDir -Extra @('/E', '/XF', 'boot.wim') -What 'WinPE base media'
Write-StepDone 'Synced WinPE base media'

# ── Step 4: Strip non-en-us languages ───────────────────────────────

Start-Step 'Removing non-en-us languages from boot manager'
$localeRx    = '(?i)^[a-z]{2}(-[a-z]{2,4}){0,2}$'
$removedCount = 0
foreach ($localeRoot in @($mediaDir, (Join-Path $mediaDir 'Boot'), (Join-Path $mediaDir 'EFI\Microsoft\Boot'))) {
    if (-not (Test-Path $localeRoot)) { continue }
    Get-ChildItem -Path $localeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $localeRx -and $_.Name -ne $script:Lang } |
        ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            $removedCount++
        }
}
Write-StepDone "Removed $removedCount non-en-us language folders"
Stop-BuildPhase 'copy base media'

# ── Step 5: Build or reuse cached WIM ───────────────────────────────

$bootWim = Join-Path $mediaDir 'sources\boot.wim'
Start-BuildPhase 'hash/cache keys'

$packages = @(
    'WinPE-WMI',
    'WinPE-NetFx',
    'WinPE-Scripting',
    'WinPE-PowerShell',
    'WinPE-StorageWMI'
)

$winpeDrivers       = Join-Path $ScriptRoot 'winpe-drivers'
$srcWinpeWim        = Join-Path $winpeRoot 'en-us\winpe.wim'
$ocDir = Join-Path $winpeRoot 'WinPE_OCs'
$packagePaths = @()
foreach ($pkg in $packages) {
    $cab = Join-Path $ocDir "$pkg.cab"
    if (-not (Test-Path -LiteralPath $cab -PathType Leaf)) { throw "Required WinPE package missing: $cab" }
    $packagePaths += $cab
    $langCab = Join-Path $ocDir "en-us\${pkg}_en-us.cab"
    if (Test-Path -LiteralPath $langCab -PathType Leaf) { $packagePaths += $langCab }
}

$baseParts = @(
    "src:$((Get-FileHash -LiteralPath $srcWinpeWim -Algorithm SHA256).Hash)",
    "arch:$script:Arch", "lang:$script:Lang", 'scratch:512',
    "recipe:$((Get-Command Invoke-WinPEBaseServicing).Definition)",
    "wpd:$(Get-ContentTreeHash -Path $winpeDrivers)"
)
foreach ($cab in $packagePaths) {
    $relativeCab = $cab.Substring($ocDir.Length).TrimStart('\', '/').Replace('\', '/')
    $baseParts += "cab:$relativeCab|$((Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash)"
}
$runtimeParts = @(
    "config:$((Get-FileHash -LiteralPath (Join-Path $payloadSrc 'reset.json') -Algorithm SHA256).Hash)",
    "tools:$(Get-ContentTreeHash -Path (Join-Path $payloadSrc 'tools'))",
    "bootsect:$((Get-FileHash -LiteralPath $bootsect -Algorithm SHA256).Hash)",
    "res:$WinPEResolution"
)
foreach ($rf in ($runtimeFiles | Sort-Object FullName)) {
    $runtimeParts += "$($rf.Name):$((Get-FileHash -LiteralPath $rf.FullName -Algorithm SHA256).Hash)"
}
foreach ($helper in @('Sync-RuntimePayload', 'Copy-RuntimeScript', 'Copy-ChangedFile', 'Set-WinPEStartup', 'Invoke-Robocopy')) {
    $runtimeParts += "helper:${helper}:$((Get-Command $helper).Definition)"
}
$cachePlan = Get-WinPECachePlan -CacheDirectory $cacheDir -BaseParts $baseParts -RuntimeParts $runtimeParts
Stop-BuildPhase 'hash/cache keys'
Invoke-WinPEImageBuild -CachePlan $cachePlan -SourceWim $srcWinpeWim -BootWim $bootWim -MountPath $mountDir `
    -PackagePaths $packagePaths -DriverPath $winpeDrivers -RuntimeFiles $runtimeFiles -PayloadSource $payloadSrc `
    -BootsectSource $bootsect -Resolution $WinPEResolution -ScratchSpace 512 -NoCache:$NoCache

# ── Step 6: Sync payload ────────────────────────────────────────────

Start-BuildPhase 'copy runtime staging'
Start-Step 'Syncing runtime payload'
$mediaPayload = Join-Path $mediaDir 'Payload'
Sync-RuntimePayload -Destination $mediaPayload -RuntimeFiles $runtimeFiles -PayloadSource $payloadSrc -BootsectSource $bootsect
Set-Content -LiteralPath (Join-Path $mediaPayload 'UNE-Payload.tag') -Value 'AutoReset deployment media' -Encoding Ascii
Write-StepDone 'Synced runtime payload'
Stop-BuildPhase 'copy runtime staging'
$externalPayloadFiles = @()

if (-not $SkipPayload) {
    Start-Step 'Planning direct payload copies'
    $localImages = Join-Path $payloadSrc 'win-images'
    if (Test-Path -LiteralPath $localImages -PathType Container) {
        foreach ($file in Get-MediaFileInventory -Root $localImages) {
            if ($file.RelativePath -eq 'install.wim') { continue }
            $externalPayloadFiles += [pscustomobject]@{
                RelativePath = "Images/$($file.RelativePath)"; Length = $file.Length; SourcePath = $file.SourcePath
            }
        }
    }
    $externalPayloadFiles += [pscustomobject]@{
        RelativePath = 'Images/install.wim'; Length = (Get-Item -LiteralPath $installWim).Length; SourcePath = $installWim
    }
    Write-StepDone 'Planned direct payload copies'

    Start-BuildPhase 'drivers'
    $driversSrc = Join-Path $payloadSrc 'device-drivers'
    if (Test-Path -LiteralPath $driversSrc) {
        $modelFolders = @(Get-ChildItem -LiteralPath $driversSrc -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name)

        if ($modelFolders.Count -eq 0) {
            $archive = Invoke-DriverArchive -SourcePath $driversSrc -ArchiveDir $preparedDriversRoot -Label 'all'
            if ($archive) {
                $externalPayloadFiles += [pscustomobject]@{
                    RelativePath = "Drivers/$(Split-Path -Leaf $archive)"
                    Length = (Get-Item -LiteralPath $archive).Length; SourcePath = $archive
                }
            }
            else {
                Write-Aside 'No driver files found. Continuing without drivers.'
            }
        }
        else {
            foreach ($modelFolder in $modelFolders) {
                $modelName   = $modelFolder.Name
                $archiveDir  = Join-Path $preparedDriversRoot $modelName
                $archive = Invoke-DriverArchive -SourcePath $modelFolder.FullName `
                    -ArchiveDir $archiveDir -Label $modelName
                if ($archive) {
                    $externalPayloadFiles += [pscustomobject]@{
                        RelativePath = "Drivers/$modelName/$(Split-Path -Leaf $archive)"
                        Length = (Get-Item -LiteralPath $archive).Length; SourcePath = $archive
                    }
                }
            }
        }
    }
    else {
        Write-StepSkipped 'No device-drivers folder found'
    }
    Stop-BuildPhase 'drivers'
}

# ── Step 7: Output (ISO / USB update / USB fresh) ───────────────────

$bootFiles = @(Get-MediaFileInventory -Root $mediaDir -ExcludePayload)
$payloadFiles = @(Get-MediaFileInventory -Root $mediaPayload) + $externalPayloadFiles
Start-BuildPhase 'output'

if ($PSCmdlet.ParameterSetName -eq 'ISO') {
    Start-BuildPhase 'copy ISO payload'
    Sync-BuildFiles -Files $externalPayloadFiles -Destination $mediaPayload
    Stop-BuildPhase 'copy ISO payload'
    if (-not (Test-Path -LiteralPath $oscdimg)) {
        throw "oscdimg.exe not found at $oscdimg. Install the ADK Deployment Tools and retry."
    }
    $oscdimgDir    = Split-Path -Parent $oscdimg
    $biosBootImage = Join-Path $oscdimgDir 'etfsboot.com'
    $uefiBootImage = Join-Path $oscdimgDir 'efisys.bin'
    foreach ($bi in @($biosBootImage, $uefiBootImage)) {
        if (-not (Test-Path -LiteralPath $bi)) { throw "Required ISO boot image missing: $bi" }
    }

    if (-not $IsoPath) { $IsoPath = Join-Path $artifactRoot 'AutoReset.iso' }
    $IsoPath = [System.IO.Path]::GetFullPath($IsoPath)
    $isoDir  = Split-Path -Parent $IsoPath
    if ($isoDir -and -not (Test-Path -LiteralPath $isoDir -PathType Container)) {
        New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
    }
    Assert-NoReparsePath -Path $IsoPath
    if ([IO.Path]::GetExtension($IsoPath) -ne '.iso' -or
        (Test-PathWithin $IsoPath $WorkDir) -or (Test-PathWithin $IsoPath $payloadSrc)) {
        throw 'ISO output must be an .iso file outside the workspace and payload source.'
    }
    $stagedIso = Join-Path $isoDir ('AutoReset-' + [guid]::NewGuid().ToString('N') + '.iso')

    $bootData = "-bootdata:2#p0,e,b`"$biosBootImage`"#pEF,e,b`"$uefiBootImage`""
    Start-Step 'Creating bootable ISO'
    Invoke-Tool -FilePath $oscdimg -What 'oscdimg' -ArgumentList @(
        '-m', '-o', '-u2', '-udfver102', '-lAUTORESET', $bootData, $mediaDir, $stagedIso)
    if (-not (Test-Path -LiteralPath $stagedIso)) { throw "oscdimg completed but didn't create $stagedIso" }
    Move-Item -LiteralPath $stagedIso -Destination $IsoPath -Force -ErrorAction Stop
    Write-StepDone 'Created bootable ISO'
    Write-Host ''
    Write-Host "  ISO ready: $IsoPath" -ForegroundColor Green
}
elseif ($PSCmdlet.ParameterSetName -eq 'USBUPDATE') {
    Start-Step 'Refreshing existing deployment stick'
    $protectedDisks = @(Get-BuildProtectedDiskNumbers -Paths $protectedPaths)
    $volumes = Get-ValidatedUsbVolumes -ProtectedDiskNumbers $protectedDisks -ExpectedIdentity $targetIdentity
    Assert-UsbPayloadOwnership -Volume $volumes.Payload
    if ($volumes.Disk.Number -ne $targetNumber) { throw 'USB disk number changed during the build.' }
    $bootVol = $volumes.Boot
    $payloadVol = $volumes.Payload
    $bootDrive    = "$($bootVol.DriveLetter):\"
    $payloadDrive = "$($payloadVol.DriveLetter):\"
    Assert-NoReparsePath -Path $bootDrive -Recurse
    Assert-NoReparsePath -Path (Join-Path $payloadDrive 'Payload') -Recurse
    if (Test-Path -LiteralPath (Join-Path $bootDrive 'Payload')) {
        throw 'Unexpected Payload directory on PE; refusing an ambiguous refresh. Build fresh media instead.'
    }
    Assert-UpdateCapacity -BootFiles $bootFiles -PayloadFiles $payloadFiles -BootVolume $bootVol -PayloadVolume $payloadVol
    $currentVolumes = Get-ValidatedUsbVolumes -ProtectedDiskNumbers $protectedDisks -ExpectedIdentity $targetIdentity
    Assert-UsbPayloadOwnership -Volume $currentVolumes.Payload
    if ($currentVolumes.Boot.DriveLetter -ne $bootVol.DriveLetter -or
        $currentVolumes.Payload.DriveLetter -ne $payloadVol.DriveLetter -or
        $currentVolumes.Disk.Number -ne $targetNumber) {
        throw 'USB partition mapping changed before the refresh.'
    }

    Start-BuildPhase 'copy USB refresh'
    Sync-BuildFiles -Files $bootFiles -Destination $bootDrive
    $currentVolumes = Get-ValidatedUsbVolumes -ProtectedDiskNumbers $protectedDisks -ExpectedIdentity $targetIdentity
    Assert-UsbPayloadOwnership -Volume $currentVolumes.Payload
    if ($currentVolumes.Boot.DriveLetter -ne $bootVol.DriveLetter -or
        $currentVolumes.Payload.DriveLetter -ne $payloadVol.DriveLetter -or
        $currentVolumes.Disk.Number -ne $targetNumber) {
        throw 'USB partition mapping changed during the refresh.'
    }
    Sync-BuildFiles -Files $payloadFiles -Destination (Join-Path $payloadDrive 'Payload') -Mirror -PreserveDirectories @('Logs')
    Stop-BuildPhase 'copy USB refresh'
    Write-StepDone 'Refreshed existing deployment stick'
    Write-Host ''
    Write-Host '  Stick refreshed (Logs folder preserved).' -ForegroundColor Green
}
else {
    Start-Step 'Checking USB capacity'
    $protectedDisks = @(Get-BuildProtectedDiskNumbers -Paths $protectedPaths)
    $disk = Assert-BuildDiskSafe -DiskNumber $UsbDiskNumber -ExpectedIdentity $targetIdentity `
        -ProtectedDiskNumbers $protectedDisks -AllowNonUsb:$AllowNonUsbDisk
    if ($disk.Size -gt 2TB) { throw 'This BIOS/UEFI MBR layout supports disks up to 2 TiB only.' }
    $bootPartitionSize = Get-BootPartitionSize -Files $bootFiles
    $payloadBytes = ($payloadFiles | Measure-Object -Property Length -Sum).Sum
    if ($payloadBytes + $bootPartitionSize + 256MB -gt $disk.Size) {
        throw 'USB disk is too small for the dynamically sized boot partition and payload.'
    }
    Write-StepDone "Checked USB capacity: $($disk.FriendlyName) ($([math]::Round($disk.Size / 1GB, 1)) GB)"

    $sizeGB = [math]::Round($disk.Size / 1GB, 1)
    Write-Host ''
    Write-Host "  About to WIPE disk ${UsbDiskNumber}: $($disk.FriendlyName) ($sizeGB GB)" -ForegroundColor Yellow
    $answer = Read-Host '  Type YES to continue'
    if ($answer -cne 'YES') { throw 'Aborted.' }
    Write-Host ''

    Start-Step 'Wiping and partitioning USB'
    $protectedDisks = @(Get-BuildProtectedDiskNumbers -Paths $protectedPaths)
    $layout = New-UsbLayout -DiskNumber $UsbDiskNumber -ExpectedIdentity $targetIdentity `
        -ProtectedDiskNumbers $protectedDisks -BootPartitionSize $bootPartitionSize -AllowNonUsb:$AllowNonUsbDisk
    $bootPart = $layout.Boot
    $payloadPart = $layout.Payload

    $bootLetter    = $null
    $payloadLetter = $null
    for ($wait = 1; $wait -le 5; $wait++) {
        Start-Sleep -Seconds 2
        $bootLetter    = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $bootPart.PartitionNumber).DriveLetter
        $payloadLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $payloadPart.PartitionNumber).DriveLetter
        if ($bootLetter -and $payloadLetter) { break }
    }
    if (-not $bootLetter -or -not $payloadLetter) {
        Write-StepFailed "Windows didn't assign drive letters"
        throw "Partitioned the stick but Windows didn't assign drive letters. Unplug/replug and re-run."
    }
    $bootDrive    = "${bootLetter}:\"
    $payloadDrive = "${payloadLetter}:\"
    Write-StepDone "Wiped and partitioned USB (PE=$bootLetter`:, PAYLOAD=$payloadLetter`:)"

    Start-Step "Copying boot files to $bootLetter`:"
    $null = Assert-BuildDiskSafe -DiskNumber $UsbDiskNumber -ExpectedIdentity $targetIdentity `
        -ProtectedDiskNumbers $protectedDisks -AllowNonUsb:$AllowNonUsbDisk
    Assert-BuildPartitionMapping -DiskNumber $UsbDiskNumber -PartitionNumber $bootPart.PartitionNumber -DriveLetter $bootLetter
    Start-BuildPhase 'copy USB boot'
    Sync-BuildFiles -Files $bootFiles -Destination $bootDrive
    Stop-BuildPhase 'copy USB boot'
    Write-StepDone "Copied boot files to $bootLetter`:"

    Start-Step "Copying payload to $payloadLetter`: (the slow bit)"
    $null = Assert-BuildDiskSafe -DiskNumber $UsbDiskNumber -ExpectedIdentity $targetIdentity `
        -ProtectedDiskNumbers $protectedDisks -AllowNonUsb:$AllowNonUsbDisk
    Assert-BuildPartitionMapping -DiskNumber $UsbDiskNumber -PartitionNumber $payloadPart.PartitionNumber -DriveLetter $payloadLetter
    Start-BuildPhase 'copy USB payload'
    Sync-BuildFiles -Files $payloadFiles -Destination (Join-Path $payloadDrive 'Payload') -Mirror -PreserveDirectories @('Logs')
    Stop-BuildPhase 'copy USB payload'
    Write-StepDone "Copied payload to $payloadLetter`:"

    if (Test-Path $bootsect) {
        Start-Step 'Writing legacy BIOS boot sector'
        $null = Assert-BuildDiskSafe -DiskNumber $UsbDiskNumber -ExpectedIdentity $targetIdentity `
            -ProtectedDiskNumbers $protectedDisks -AllowNonUsb:$AllowNonUsbDisk
        Assert-BuildPartitionMapping -DiskNumber $UsbDiskNumber -PartitionNumber $bootPart.PartitionNumber -DriveLetter $bootLetter
        & $bootsect /nt60 "${bootLetter}:" /mbr 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-StepSkipped "Legacy BIOS boot sector (bootsect failed - UEFI boot still works)"
        }
        else {
            Write-StepDone 'Wrote legacy BIOS boot sector'
        }
    }

    Write-Host ''
    Write-Host '  USB deployment media is ready.' -ForegroundColor Green
    Write-Host '  Boot a target machine from it (F12 one-time boot menu on Dell).' -ForegroundColor DarkGray
}
Stop-BuildPhase 'output'

Write-Host "  Build log: $script:BuildLog" -ForegroundColor DarkGray
Write-Host ''

Complete-WorkingFolder
$global:LASTEXITCODE = 0
}
finally {
    Write-BuildTotal
}
