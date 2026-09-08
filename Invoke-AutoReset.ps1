<#
.SYNOPSIS
    AutoReset - Automated Windows deployment tool for WinPE.

.DESCRIPTION
    Started by winpeshl.ini when WinPE boots. Wipes a disk, applies Windows,
    injects drivers, configures recovery and boot, saves logs, and restarts
    to OOBE ready for Autopilot enrolment.

    USB copy of reset.json overrides the configuration baked into boot.wim.
    Press F3 at any time to open the log in Notepad.
    Press F8 at any time for a command prompt.
    Press Ctrl+Shift+W on the disk confirmation screen for disk overwrite.
#>
param()

$ErrorActionPreference = 'Stop'

trap {
    $failure = $_
    try { Show-Console } catch { }
    try { Write-Log "AutoReset stopped: $($failure.Exception.Message)" 'ERROR' } catch { }
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            "AutoReset stopped. No further deployment actions will run.`r`n`r`n$($failure.Exception.Message)`r`n`r`nLog: $script:LogFile",
            'AutoReset error', 'OK', 'Error')
    }
    catch { Write-Host "AutoReset stopped: $($failure.Exception.Message)" -ForegroundColor Red }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'AutoReset.Common.ps1')
. (Join-Path $PSScriptRoot 'AutoReset.UI.ps1')
Assert-WinPEEnvironment

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Version = '2.0.0'

# ── Console visibility ──────────────────────────────────────────────

try {
    Add-Type -Name ConsoleUtil -Namespace Ar -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    [void][Ar.ConsoleUtil]::ShowWindow([Ar.ConsoleUtil]::GetConsoleWindow(), 0)
}
catch { }

function Show-Console {
    try { [void][Ar.ConsoleUtil]::ShowWindow([Ar.ConsoleUtil]::GetConsoleWindow(), 5) } catch { }
}

# ── Logging ─────────────────────────────────────────────────────────

$logRoot = 'X:\Windows\Temp'
if (-not (Test-Path $logRoot)) { $logRoot = $env:TEMP }
$script:LogFile     = Join-Path $logRoot 'AutoReset.log'
$script:DetailLog   = Join-Path $logRoot 'AutoReset-Detail.log'
$script:SmsTsLogDir = Join-Path $logRoot 'SMSTSLog'
$script:SmsTsLog    = Join-Path $script:SmsTsLogDir 'smsts.log'
New-Item -ItemType Directory -Path $script:SmsTsLogDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:LogComponent = 'AutoReset'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $now = Get-Date
    $prefix = switch ($Level) {
        'WARN'  { '[WARN ]' }
        'ERROR' { '[ERROR]' }
        default { '[INFO ]' }
    }
    Add-Content -Path $script:LogFile -Value (
        '{0}  {1}  {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $prefix, $Message
    ) -ErrorAction SilentlyContinue

    $type = switch ($Level) { 'INFO' { 1 } 'WARN' { 2 } 'ERROR' { 3 } }
    Add-Content -Path $script:SmsTsLog -ErrorAction SilentlyContinue -Value (
        '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f
        $Message, $now.ToString('HH:mm:ss.fff+000'), $now.ToString('MM-dd-yyyy'), $script:LogComponent, $type, $PID)
}

function Write-Detail {
    param([string]$Text)
    Add-Content -Path $script:DetailLog -Value $Text -ErrorAction SilentlyContinue
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    $divider = '=' * 60
    Add-Content -Path $script:LogFile -Value '' -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFile -Value $divider -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFile -Value "  $Text" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFile -Value $divider -ErrorAction SilentlyContinue
    Write-Log $Text
}

function Write-LogBlock {
    param([AllowEmptyString()][Parameter(Mandatory)][string[]]$Lines)
    foreach ($line in $Lines) {
        Add-Content -Path $script:LogFile -Value "  $line" -ErrorAction SilentlyContinue
    }
}

# ── Media and configuration ─────────────────────────────────────────

function Find-MediaRoot {
    Select-DeploymentMediaRoot -Drives @([System.IO.DriveInfo]::GetDrives())
}

function Select-DeploymentMediaRoot {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Drives)
    $roots = @()
    foreach ($drive in $Drives) {
        if (-not $drive.IsReady) { continue }
        if ($drive.Name.TrimEnd('\', '/') -eq 'X:' -or [string]$drive.DriveType -eq 'Ram') { continue }
        if (Test-Path -LiteralPath (Join-Path $drive.Name 'Payload\UNE-Payload.tag')) {
            $roots += (Join-Path $drive.Name 'Payload').TrimEnd('\', '/')
        }
    }
    if ($roots.Count -eq 0) { throw 'No ready external deployment medium contains Payload\UNE-Payload.tag.' }
    if ($roots.Count -ne 1) {
        throw "Multiple deployment media were found: $($roots -join ', '). Detach unused USB media or eject unused ISOs, then restart AutoReset."
    }
    return $roots[0]
}

function Get-DeploymentSourceIdentity {
    param([Parameter(Mandatory)][string]$MediaRoot)
    if ($MediaRoot -notmatch '^([A-Za-z]):[\\/]') { throw 'Deployment media must have a local drive letter.' }
    $letter = $Matches[1]
    $volumes = @(Get-Volume -DriveLetter $letter -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace($volumes[0].UniqueId)) {
        throw 'Cannot uniquely identify the deployment source volume.'
    }
    $volume = $volumes[0]
    $logical = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letter) -ErrorAction Stop)
    if ($logical.Count -ne 1 -or [string]::IsNullOrWhiteSpace($logical[0].VolumeSerialNumber)) {
        throw 'Cannot read the deployment source volume serial number.'
    }
    $diskIdentities = @()
    if ($logical[0].DriveType -ne 5) {
        $partitions = @(Get-Partition -Volume $volume -ErrorAction Stop)
        $numbers = @($partitions | Select-Object -ExpandProperty DiskNumber -Unique | Sort-Object)
        if ($numbers.Count -eq 0) { throw 'Cannot map the deployment source volume to its physical disk.' }
        foreach ($number in $numbers) {
            $diskIdentities += Get-DiskIdentity -Disk (Get-Disk -Number $number -ErrorAction Stop)
        }
    }
    # Optical/ISO media has no MSFT_Disk mapping; identify the mounted volume, not the optical drive.
    [ordered]@{
        Root = $MediaRoot.TrimEnd('\', '/').ToUpperInvariant()
        Volume = [string]$volume.UniqueId
        Serial = [string]$logical[0].VolumeSerialNumber
        Label = [string]$volume.FileSystemLabel
        Size = [string]$volume.Size
        FileSystem = [string]$volume.FileSystem
        DriveType = [string]$logical[0].DriveType
        Disks = $diskIdentities
    } | ConvertTo-Json -Compress
}

function Assert-DeploymentSourceUnchanged {
    param([Parameter(Mandatory)]$Preflight)
    if (-not $Preflight.Source -or [string]::IsNullOrWhiteSpace($Preflight.Source.Identity) -or
        -not $Preflight.Image -or [string]::IsNullOrWhiteSpace($Preflight.Image.Hash)) {
        throw 'The deployment source/image was not completely validated; refusing to erase.'
    }
    $root = Find-MediaRoot
    if ($root -ne $Preflight.Source.Root -or
        (Get-DeploymentSourceIdentity -MediaRoot $root) -ne $Preflight.Source.Identity) {
        throw 'The selected deployment medium was replaced or changed after preflight.'
    }
    if (-not (Test-Path -LiteralPath $Preflight.Image.Path -PathType Leaf)) {
        throw 'The selected Windows image disappeared after preflight.'
    }
    if ((Get-FileHash -LiteralPath $Preflight.Image.Path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Preflight.Image.Hash) {
        throw 'The selected Windows image changed after preflight.'
    }
    # Recheck attachment/identity after the potentially lengthy full image read.
    $root = Find-MediaRoot
    if ($root -ne $Preflight.Source.Root -or
        (Get-DeploymentSourceIdentity -MediaRoot $root) -ne $Preflight.Source.Identity) {
        throw 'The selected deployment medium changed while verifying the image.'
    }
}

$script:MediaRoot        = $null
$script:ImagePayloadRoot = 'X:\Payload'
$script:ConfigJson       = $null

function Initialize-Configuration {
    $script:MediaRoot = Find-MediaRoot
    $configPath = $null
    foreach ($candidate in @(
        $(if ($script:MediaRoot) { Join-Path $script:MediaRoot 'Config\reset.json' }),
        (Join-Path $script:ImagePayloadRoot 'Config\reset.json'),
        (Join-Path $PSScriptRoot '..\Config\reset.json'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $configPath = $candidate; break }
    }
    if ($configPath) {
        try {
            $json = Get-Content -LiteralPath $configPath -Raw
            if (-not $json.TrimStart().StartsWith('{')) { throw 'reset.json must contain a JSON object.' }
            $script:ConfigJson = $json | ConvertFrom-Json -ErrorAction Stop
            Assert-Configuration -Config $script:ConfigJson
        }
        catch { throw "Invalid configuration '$configPath': $($_.Exception.Message)" }
    }
}

function Assert-RelativePayloadPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f":*?<>|]' -or
        $Path -match '^[\\/]' -or ($Path -split '[\\/]' | Where-Object { $_ -in @('..', '.', '') -or $_ -match '[ .]$' })) {
        throw "Invalid relative payload path '$Path'."
    }
}

function Assert-Configuration {
    param($Config)
    if ($null -eq $Config -or $Config.GetType() -ne [System.Management.Automation.PSCustomObject]) {
        throw 'reset.json must contain a JSON object.'
    }
    foreach ($name in @('ConfirmBeforeWipe', 'ContinueOnDriverError', 'SetupRecovery', 'DriversRequired')) {
        if ($Config.PSObject.Properties.Name -contains $name -and $Config.$name -isnot [bool]) {
            throw "$name must be a JSON boolean."
        }
    }
    foreach ($name in @('ImageIndex', 'TargetDiskNumber')) {
        if ($Config.PSObject.Properties.Name -contains $name -and $null -ne $Config.$name) {
            $value = $Config.$name
            $minimum = if ($name -eq 'ImageIndex') { 1 } else { 0 }
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $minimum -or $value -gt [int]::MaxValue) {
                throw "$name must be an integer >= $minimum or null."
            }
        }
    }
    foreach ($name in @('ImageFile', 'ImageEdition')) {
        if ($Config.PSObject.Properties.Name -contains $name) {
            if ($Config.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.$name)) {
                throw "$name must be a nonempty string."
            }
        }
    }
    if ($Config.PSObject.Properties.Name -contains 'ImageFile') { Assert-RelativePayloadPath $Config.ImageFile }
    if ($Config.PSObject.Properties.Name -contains 'DriverMap') {
        if ($Config.DriverMap -isnot [array]) { throw 'DriverMap must be a JSON array.' }
        foreach ($entry in $Config.DriverMap) {
            if ($null -eq $entry -or $entry.GetType() -ne [System.Management.Automation.PSCustomObject] -or $entry.Match -isnot [string] -or
                [string]::IsNullOrWhiteSpace($entry.Match) -or $entry.Folder -isnot [string]) {
                throw 'Each DriverMap entry requires nonempty Match and Folder strings.'
            }
            Assert-RelativePayloadPath $entry.Folder
        }
    }
}

function Get-Config {
    param([Parameter(Mandatory)][string]$Name, $Default)
    if ($script:ConfigJson -and ($script:ConfigJson.PSObject.Properties.Name -contains $Name)) {
        $value = $script:ConfigJson.$Name
        if ($null -ne $value) { return $value }
    }
    return $Default
}

function Resolve-MediaFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    Assert-RelativePayloadPath $RelativePath
    foreach ($root in @($script:MediaRoot, $script:ImagePayloadRoot)) {
        if (-not $root) { continue }
        $full = Join-Path $root $RelativePath
        if (Test-Path -LiteralPath $full) { return $full }
    }
    return $null
}

# ── UI helpers ───────────────────────────────────────────────────────

$script:AccentColor = [System.Drawing.Color]::FromArgb(39, 178, 217)

function Set-PrimaryButtonStyle {
    param([Parameter(Mandatory)][System.Windows.Forms.Button]$Button)
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $script:AccentColor
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
}

function Update-Ui { [System.Windows.Forms.Application]::DoEvents() }

function Title { param([string]$Suffix) "AutoReset v$($script:Version)$(if ($Suffix) { " | $Suffix" })" }

# Pat - Dynamic form factory ----------------------------------------
#   Form is NOT auto-sized. FLP is NOT docked.
#   Caller adds controls to $f.Tag (the FLP), then calls
#   Set-FormSize -Form $f before ShowDialog() or after .Show().
#--------------------------------------------------------------------
function New-BaseForm {
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$TitleSuffix,
        [int]$Width = 720,
        [int]$MinimumHeight = 260
    )
    $f = New-ResetForm -Title (Title $TitleSuffix) -Width $Width -MinimumHeight $MinimumHeight

    $f.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F3) {
            if (Test-Path $script:LogFile) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList $script:LogFile
            }
        }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
            Start-Process -FilePath "$env:windir\System32\cmd.exe"
        }
    })
    return $f
}

# ── State ────────────────────────────────────────────────────────────

$script:StartTime    = Get-Date
$script:Model        = $null
$script:Serial       = $null
$script:Manufacturer = $null
$script:IsUefi       = $true
$script:TargetDisk   = $null
$script:DriverFolder = $null
$script:DriversAdded = 0
$script:StepWarnings = @()
$script:AllDisks     = @()
$script:ProtectedDiskNumbers = @()
$script:TargetIdentity = $null
$script:Preflight = $null
$script:PartitionsVerified = $false

# ── External tool runner ────────────────────────────────────────────

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$What,
        [switch]$ParsePercent
    )
    if (-not $What) { $What = [IO.Path]::GetFileNameWithoutExtension($FilePath) }
    $started = Get-Date
    Write-Detail ''
    Write-Detail ("=== {0:HH:mm:ss}  {1} {2}" -f $started, $FilePath, $Arguments)

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stream  = $proc.StandardOutput.BaseStream
    $buffer  = New-Object byte[] 8192
    $sb      = New-Object System.Text.StringBuilder
    $pctRx   = [regex]'(\d{1,3}(?:\.\d)?)%'

    $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
    while ($true) {
        if ($readTask.IsCompleted) {
            $count = 0
            if (-not $readTask.IsFaulted) { $count = $readTask.Result }
            if ($count -le 0) {
                if ($proc.HasExited) { break }
                Start-Sleep -Milliseconds 100
            }
            else {
                $chunk = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                [void]$sb.Append($chunk)
                if ($ParsePercent) {
                    $hits = $pctRx.Matches($chunk)
                    if ($hits.Count -gt 0) { Set-StepPercent ([double]$hits[$hits.Count - 1].Groups[1].Value) }
                }
            }
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
        }
        else {
            Update-Ui
            Start-Sleep -Milliseconds 60
        }
    }
    $proc.WaitForExit()

    $stdErr = ''
    try { $stdErr = $errTask.Result } catch { }
    $output = $sb.ToString()
    Write-Detail $output
    if ($stdErr.Trim()) { Write-Detail "[stderr] $($stdErr.Trim())" }

    $elapsed = (Get-Date) - $started
    if ($proc.ExitCode -ne 0) {
        $bad = ($output -split "[`r`n]+") |
            Where-Object { $_.Trim() -and $_ -notmatch '^\[' -and $_ -match 'Error|error|failed|cannot|denied' } |
            Select-Object -Last 3
        Write-Log ("{0} failed (exit {1}, {2:mm\:ss})" -f $What, $proc.ExitCode, $elapsed) 'WARN'
        foreach ($b in $bad) { Write-Log ("  {0}" -f $b.Trim()) 'WARN' }
    }
    else {
        Write-Log ('{0} completed (exit 0, {1:mm\:ss})' -f $What, $elapsed)
    }

    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $output; Elapsed = $elapsed }
}

# ── Error helpers ────────────────────────────────────────────────────

function Get-FriendlyError {
    param([Parameter(Mandatory)][string]$StepName)
    switch ($StepName) {
        'Wipe and Partition'     { 'wiping and partitioning the drive. The drive may be faulty, or a BIOS setting like BitLocker or RAID may be preventing access.' }
        'Installing Windows'     { 'installing Windows onto the drive. The install image may be missing from the USB, or the drive may be faulty.' }
        'Installing Drivers'     { 'installing the hardware drivers for this model. The driver package may be missing or incompatible.' }
        'Create WinRE Partition' { 'setting up the Windows recovery environment.' }
        'Create Boot Data'       { 'making the computer bootable after installing Windows.' }
        'Verify Install'         { 'verifying the finished installation. Some critical files may be missing.' }
        'Save Logs'              { 'saving the deployment logs.' }
        default                  { "performing the step: $StepName." }
    }
}

function Save-DeviceLog {
    param([Parameter(Mandatory)][ValidateSet('SUCCESS', 'FAILED')][string]$Result)
    if (-not $script:MediaRoot) { return $null }
    try {
        $logDir = Join-Path ([System.IO.Path]::GetPathRoot($script:MediaRoot)) 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null

        $serial = if ($script:Serial) { $script:Serial } else { 'UNKNOWN' }
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmm'
        $dest   = Join-Path $logDir ('{0}_{1}_{2}.log' -f $serial, $stamp, $Result)

        $duration = (Get-Date) - $script:StartTime
        $header = @(
            '============================================================'
            "  AutoReset v$($script:Version) - $Result"
            '============================================================'
            "  Device       : $($script:Manufacturer) $($script:Model)"
            "  Service tag  : $serial"
            "  Firmware     : $(if ($script:IsUefi) { 'UEFI' } else { 'Legacy BIOS' })"
            "  Started      : $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
            "  Finished     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "  Duration     : $('{0:hh\:mm\:ss}' -f $duration)"
            '============================================================'
            ''
        )
        Set-Content -Path $dest -Value ($header -join [Environment]::NewLine) -Encoding UTF8
        Add-Content -Path $dest -Value (Get-Content -Path $script:LogFile -Raw -ErrorAction SilentlyContinue)
        Copy-Item $script:SmsTsLog  (Join-Path $logDir ('{0}_{1}_smsts.log'  -f $serial, $stamp)) -Force -ErrorAction SilentlyContinue
        Copy-Item $script:DetailLog (Join-Path $logDir ('{0}_{1}_detail.log' -f $serial, $stamp)) -Force -ErrorAction SilentlyContinue
        Write-Log "Logs saved to media: $dest"
        return $dest
    }
    catch {
        Write-Log "Could not write logs to the deployment media: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

# ── Copy logs to installed OS ────────────────────────────────────────

function Copy-LogsToTarget {
    if (-not $script:PartitionsVerified) { return }
    Assert-TargetPartitions
    New-Item -ItemType Directory -Path 'W:\Windows\Temp\SMSTSLog' -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item $script:LogFile   'W:\Windows\Temp\AutoReset.log'        -Force -ErrorAction SilentlyContinue
    Copy-Item $script:DetailLog 'W:\Windows\Temp\AutoReset-Detail.log' -Force -ErrorAction SilentlyContinue
    Copy-Item $script:SmsTsLog  'W:\Windows\Temp\SMSTSLog\smsts.log'   -Force -ErrorAction SilentlyContinue
}

# ── Get drive letter for a disk ─────────────────────────────────────

function Get-PrimaryDriveLetter {
    param([int]$DiskNumber)
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
        Sort-Object Size -Descending)
    if ($parts.Count -gt 0) { return "$($parts[0].DriveLetter):" }
    return '-'
}

function Invoke-KillDiskProcess {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$Serial)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Serial "{1}"' -f $ScriptPath, $Serial
    Write-Log "Launching KillDisk logical zero overwrite: powershell.exe $arguments"
    $process = Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $arguments -Wait -PassThru
    Write-Log "KillDisk process exit code: $($process.ExitCode)"
    if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) {
        throw "KillDisk did not complete successfully (exit code $($process.ExitCode)). Review the KillDisk log before continuing."
    }
}

function Get-InitialTargetDisk {
    param([object[]]$Disks, [int[]]$ProtectedDiskNumbers, $ConfiguredNumber)
    $eligible = @($Disks | Where-Object {
        Test-EligibleTargetDisk -Disk $_ -ProtectedDiskNumbers $ProtectedDiskNumbers
    })
    if ($null -ne $ConfiguredNumber) {
        $selected = @($eligible | Where-Object { $_.Number -eq $ConfiguredNumber })
        if ($selected.Count -ne 1) { throw "Configured disk $ConfiguredNumber is missing or unsafe." }
        return $selected[0]
    }
    if ($eligible.Count -eq 0) { throw 'No eligible internal disk with a stable identity was found.' }
    if ($eligible.Count -eq 1) { return $eligible[0] }
    return $null
}

function Assert-DeploymentLettersAvailable {
    foreach ($letter in @('S', 'W', 'R')) {
        $partitions = @(Get-Partition -ErrorAction Stop | Where-Object { "$($_.DriveLetter)" -eq $letter })
        $volumes = @(Get-Volume -ErrorAction Stop | Where-Object { "$($_.DriveLetter)" -eq $letter })
        if ($partitions.Count -or $volumes.Count -or
            (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) -or (Test-Path "${letter}:\")) {
            throw "Drive letter ${letter}: is already in use. Release it before deployment; AutoReset will not unmount existing volumes."
        }
    }
}

function Assert-TargetPartitions {
    $letters = @('S', 'W', 'R')
    foreach ($letter in $letters) {
        $parts = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
        if ($parts.Count -ne 1 -or $parts[0].DiskNumber -ne $script:TargetDisk.Number) {
            throw "Partition ${letter}: does not belong exclusively to the selected disk."
        }
        $disk = Get-Disk -Number $parts[0].DiskNumber -ErrorAction Stop
        if ((Get-DiskIdentity -Disk $disk) -ne $script:TargetIdentity) {
            throw "Disk identity changed for partition ${letter}:."
        }
        $volume = @($parts[0] | Get-Volume -ErrorAction Stop)
        $expectedFs = if ($letter -eq 'S' -and $script:IsUefi) { 'FAT32' } else { 'NTFS' }
        if ($volume.Count -ne 1 -or $volume[0].FileSystem -ne $expectedFs -or -not (Test-Path "${letter}:\")) {
            throw "Partition ${letter}: is unavailable or not formatted as $expectedFs."
        }
        if ($letter -eq 'S') {
            if ($script:IsUefi -and "$($parts[0].GptType)".Trim('{}') -ne 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b') {
                throw 'S: is not an EFI System Partition.'
            }
            if (-not $script:IsUefi -and -not $parts[0].IsActive) { throw 'BIOS system partition is not active.' }
        }
        if ($letter -eq 'R') {
            if ($script:IsUefi -and "$($parts[0].GptType)".Trim('{}') -ne 'de94bba4-06d1-4d40-a16a-bfd50179d6ac') {
                throw 'R: is not a Windows Recovery partition.'
            }
            if (-not $script:IsUefi -and $parts[0].MbrType -ne 39) { throw 'R: has the wrong MBR recovery partition type.' }
        }
    }
}

function Get-DeploymentImage {
    $relative = Get-Config 'ImageFile' 'Images\install.wim'
    $path = Resolve-MediaFile $relative
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Image '$relative' was not found." }
    # Reading the entire file detects unreadable media before destroying the target.
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    $info = Invoke-External -FilePath 'dism.exe' -What 'Image preflight' -Arguments "/English /Get-WimInfo /WimFile:`"$path`""
    if ($info.ExitCode -ne 0) { throw 'DISM cannot read the installation image.' }
    $images = @()
    $currentIndex = $null
    foreach ($line in ($info.Output -split "[`r`n]+")) {
        if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') { $currentIndex = [int]$Matches[1] }
        elseif ($line -match '^\s*Name\s*:\s*(.+)$' -and $null -ne $currentIndex) {
            $images += [pscustomobject]@{ Index = $currentIndex; Name = $Matches[1].Trim() }
            $currentIndex = $null
        }
    }
    $index = Get-Config 'ImageIndex' $null
    $edition = Get-Config 'ImageEdition' 'Windows 11 Pro'
    $selected = @($images | Where-Object { $_.Name -eq $edition -and ($null -eq $index -or $_.Index -eq $index) })
    if ($selected.Count -ne 1) { throw "Image index/edition '$index / $edition' does not uniquely match an image." }
    $index = $selected[0].Index
    $detail = Invoke-External -FilePath 'dism.exe' -What 'Selected image preflight' `
        -Arguments "/English /Get-WimInfo /WimFile:`"$path`" /Index:$index"
    if ($detail.ExitCode -ne 0) { throw "Cannot inspect image index $index." }
    if ($detail.Output -notmatch '(?m)^\s*Size\s*:\s*([0-9,]+)\s+bytes\s*$') {
        throw 'Cannot determine the expanded image size; refusing to estimate from the compressed file.'
    }
    $expandedBytes = [long]($Matches[1] -replace ',', '')
    if ($expandedBytes -le 0) { throw 'The expanded image size is invalid.' }
    if ($detail.Output -notmatch '(?m)^\s*Architecture\s*:\s*(x64|arm64)\s*$') {
        throw 'Only x64 or ARM64 Windows images are supported.'
    }
    $architecture = $Matches[1]
    $hostArchitecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'x64' } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne $hostArchitecture) { throw "Image architecture $architecture does not match WinPE $hostArchitecture." }
    Write-Log "Image preflight: $path | SHA256 $hash | $edition index $index | expanded $expandedBytes bytes"
    return [pscustomobject]@{
        Path = $path; Index = $index; Edition = $edition; ExpandedBytes = $expandedBytes
        Hash = $hash; Architecture = $architecture
    }
}

function Assert-ArchiveEntryPath {
    param([Parameter(Mandatory)][string]$Path)
    $entryPath = $Path.TrimEnd('\', '/')
    Assert-RelativePayloadPath $entryPath
}

function Get-PreparedDrivers {
    Assert-RelativePayloadPath $script:DriverFolder
    $archive = $null
    foreach ($name in @('Drivers.7z', 'Drivers.zip')) {
        $archive = Resolve-MediaFile "Drivers\$($script:DriverFolder)\$name"
        if ($archive) { break }
        $archive = Resolve-MediaFile "Drivers\$name"
        if ($archive) { break }
    }
    $path = $null
    $required = 0L
    $hash = $null
    $tool = $null
    $modelSubdirectory = $false
    $infs = @()
    if ($archive) {
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256 -ErrorAction Stop).Hash
        $archivePaths = @()
        if ($archive -match '\.7z$') {
            $tool = Resolve-MediaFile 'Tools\7za.exe'
            if (-not $tool -or -not (Test-Path -LiteralPath $tool -PathType Leaf)) {
                throw '7za.exe is required in Payload\Tools for .7z driver archives.'
            }
            $list = Invoke-External -FilePath $tool -What 'Validate driver archive entries' -Arguments "l -slt -pAutoResetNoEncryptedArchives `"$archive`""
            if ($list.ExitCode -ne 0 -or $list.Output -notmatch '(?m)^----------\s*$') { throw 'Cannot list driver archive entries.' }
            $entries = ($list.Output -split '(?m)^----------\s*$', 2)[1]
            $paths = [regex]::Matches($entries, '(?m)^Path = (.+)\r?$')
            if ($paths.Count -eq 0 -or $entries -match '(?im)^(Symbolic Link|Hard Link) = .+|^Attributes = .*l[rwx-]{9}|^Encrypted = \+') {
                throw 'Empty/encrypted driver archives and archive links are not supported.'
            }
            foreach ($entry in $paths) {
                $entryPath = $entry.Groups[1].Value.TrimEnd("`r")
                Assert-ArchiveEntryPath $entryPath
                $archivePaths += $entryPath -replace '\\', '/'
            }
            $sizes = [regex]::Matches($entries, '(?m)^Size = (\d+)\r?$')
            if ($sizes.Count -ne $paths.Count) { throw 'Driver archive entry sizes are incomplete.' }
            foreach ($size in $sizes) { $required += [long]$size.Groups[1].Value }
            $test = Invoke-External -FilePath $tool -What 'Test driver archive' -Arguments "t -pAutoResetNoEncryptedArchives `"$archive`""
            if ($test.ExitCode -ne 0) { throw 'Driver archive integrity validation failed.' }
        }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                $buffer = New-Object byte[] 65536
                foreach ($entry in $zip.Entries) {
                    Assert-ArchiveEntryPath $entry.FullName
                    if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                        throw 'Symbolic links in driver archives are not supported.'
                    }
                    $required += $entry.Length
                    $archivePaths += $entry.FullName -replace '\\', '/'
                    $stream = $entry.Open()
                    try {
                        $readLength = 0L
                        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $readLength += $read
                            if ($readLength -gt $entry.Length) { throw "Archive entry '$($entry.FullName)' exceeds its declared size." }
                        }
                        if ($readLength -ne $entry.Length) { throw "Archive entry '$($entry.FullName)' is truncated." }
                    }
                    finally { $stream.Dispose() }
                }
            }
            finally { $zip.Dispose() }
        }
        $prefix = ($script:DriverFolder -replace '\\', '/') + '/'
        $modelPaths = @($archivePaths | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        $modelSubdirectory = $modelPaths.Count -gt 0
        $selectedPaths = if ($modelSubdirectory) { $modelPaths } else { $archivePaths }
        $infs = @($selectedPaths | Where-Object { $_ -match '\.inf$' })
    }
    else { $path = Resolve-MediaFile "Drivers\$($script:DriverFolder)" }
    if ($path) {
        $files = @(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction Stop)
        if ($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
            throw 'Driver sources must not contain reparse points.'
        }
        $infs = @($files | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.inf' })
        foreach ($file in ($files | Where-Object { -not $_.PSIsContainer })) {
            $null = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop
        }
    }
    if ($infs.Count -eq 0) {
        if (Get-Config 'DriversRequired' $false) { throw "Required drivers are missing for '$script:Model'." }
        Write-Log 'No model drivers available; DriversRequired is false.' 'WARN'
        $script:StepWarnings += "No drivers injected for $script:Model."
        return $null
    }
    return [pscustomobject]@{
        Path = $path; Count = $infs.Count; Archive = $archive; Hash = $hash
        ExpandedBytes = $required; Tool = $tool; ModelSubdirectory = $modelSubdirectory
    }
}

function Assert-DriverArchiveUnchanged {
    param($Drivers)
    if ($Drivers -and $Drivers.Archive) {
        if ([string]::IsNullOrWhiteSpace($Drivers.Hash) -or
            (Get-FileHash -LiteralPath $Drivers.Archive -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Drivers.Hash) {
            throw 'The selected driver archive changed after validation; refusing to continue.'
        }
    }
}

function Expand-ValidatedDriverArchive {
    param([Parameter(Mandatory)]$Drivers)
    Assert-TargetPartitions
    Assert-DriverArchiveUnchanged -Drivers $Drivers
    if (-not $Drivers.Archive) { return $Drivers.Path }
    if ((Get-Volume -DriveLetter W -ErrorAction Stop).SizeRemaining -lt ($Drivers.ExpandedBytes + 1GB)) {
        throw 'The Windows target volume lacks space for validated driver extraction.'
    }
    $destination = 'W:\Windows\Temp\AutoReset-Drivers-' + [guid]::NewGuid().ToString('N')
    $script:DriverScratch = $destination
    if ($Drivers.Archive -match '\.7z$') {
        $extract = Invoke-External -FilePath $Drivers.Tool -What 'Extract validated drivers to target' `
            -Arguments "x -pAutoResetNoEncryptedArchives `"$($Drivers.Archive)`" -o`"$destination`" -y"
        if ($extract.ExitCode -ne 0) { throw 'Validated driver archive extraction failed.' }
    }
    else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Drivers.Archive, $destination)
    }
    $files = @(Get-ChildItem -LiteralPath $destination -Recurse -Force -ErrorAction Stop)
    if ($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
        throw 'Extracted driver sources must not contain reparse points.'
    }
    $path = if ($Drivers.ModelSubdirectory) { Join-Path $destination $script:DriverFolder } else { $destination }
    $infs = @(Get-ChildItem -LiteralPath $path -Recurse -Filter '*.inf' -ErrorAction Stop |
        Where-Object { -not $_.PSIsContainer })
    if ($infs.Count -ne $Drivers.Count) { throw 'Extracted driver package count does not match validated archive contents.' }
    return $path
}

function Invoke-DeploymentPreflight {
    Assert-WinPEEnvironment
    foreach ($tool in @('diskpart.exe', 'dism.exe', 'bcdboot.exe', 'bcdedit.exe', 'wpeutil.exe')) {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "Required tool '$tool' is unavailable."
        }
    }
    $bootsect = $null
    if (-not $script:IsUefi) {
        $command = Get-Command 'bootsect.exe' -CommandType Application -ErrorAction SilentlyContinue
        $bootsect = if ($command) { $command.Source } else { Resolve-MediaFile 'Tools\bootsect.exe' }
        if (-not $bootsect -or -not (Test-Path -LiteralPath $bootsect -PathType Leaf)) {
            throw 'bootsect.exe is required on PATH or in Payload\Tools for Legacy BIOS deployment.'
        }
    }
    $script:ProtectedDiskNumbers = @(Get-DeploymentMediaDiskNumbers)
    $script:TargetDisk = Assert-TargetDiskSafe -DiskNumber $script:TargetDisk.Number `
        -ExpectedIdentity $script:TargetIdentity -ProtectedDiskNumbers $script:ProtectedDiskNumbers
    Assert-DeploymentLettersAvailable
    $sourceRoot = Find-MediaRoot
    if ($sourceRoot -ne $script:MediaRoot) { throw 'The selected deployment source changed before preflight.' }
    $source = [pscustomobject]@{ Root = $sourceRoot; Identity = (Get-DeploymentSourceIdentity -MediaRoot $sourceRoot) }
    $image = Get-DeploymentImage
    $requiredBytes = $image.ExpandedBytes + 10GB + 260MB + 16MB + 2048MB + 4MB
    if ($script:TargetDisk.Size -lt $requiredBytes) {
        throw "Target capacity is insufficient: need at least $([math]::Ceiling($requiredBytes / 1GB)) GB for the expanded image, free space and partitions."
    }
    if (-not $script:IsUefi -and $script:TargetDisk.Size -gt 2TB) { throw 'Legacy MBR deployment to disks over 2 TB is unsupported.' }
    $drivers = Get-PreparedDrivers
    if ($drivers) { $requiredBytes += [long]$drivers.ExpandedBytes }
    if ($script:TargetDisk.Size -lt $requiredBytes) {
        throw "Target capacity is insufficient for the expanded Windows image and $([math]::Ceiling($drivers.ExpandedBytes / 1GB)) GB of driver staging."
    }
    return [pscustomobject]@{ Image = $image; Source = $source; Drivers = $drivers; RequiredBytes = $requiredBytes; Bootsect = $bootsect }
}

function Invoke-CheckedTool {
    param([string]$FilePath, [string]$Arguments, [string]$What)
    $result = Invoke-External -FilePath $FilePath -Arguments $Arguments -What $What
    if ($result.ExitCode -ne 0) { throw "$What failed (exit $($result.ExitCode))." }
    return $result.Output
}

function Assert-TargetBootConfiguration {
    Assert-TargetPartitions
    $store = if ($script:IsUefi) { 'S:\EFI\Microsoft\Boot\BCD' } else { 'S:\Boot\BCD' }
    if (-not (Test-Path -LiteralPath $store -PathType Leaf)) { throw 'Target BCD store is missing.' }
    $manager = Invoke-CheckedTool 'bcdedit.exe' "/store $store /enum {bootmgr} /v" 'Inspect target boot manager'
    $loader = Invoke-CheckedTool 'bcdedit.exe' "/store $store /enum {default} /v" 'Inspect target Windows loader'
    if ($manager -notmatch '(?m)^\s*device\s+partition=S:\s*$' -or
        $loader -notmatch '(?m)^\s*device\s+partition=W:\s*$' -or
        $loader -notmatch '(?m)^\s*osdevice\s+partition=W:\s*$' -or
        $loader -notmatch '(?m)^\s*systemroot\s+\\Windows\s*$') {
        throw 'Target BCD does not point to the selected system and Windows partitions (or cannot be verified in this locale).'
    }
    $loaderFile = if ($script:IsUefi) { 'winload.efi' } else { 'winload.exe' }
    if ($loader -notmatch "(?m)^\s*path\s+\\Windows\\system32\\$([regex]::Escape($loaderFile))\s*$" -or
        -not (Test-Path -LiteralPath "W:\Windows\System32\$loaderFile" -PathType Leaf)) {
        throw 'Target Windows loader is missing or incorrectly configured.'
    }
    if ($script:IsUefi) {
        if (-not (Test-Path -LiteralPath 'S:\EFI\Microsoft\Boot\bootmgfw.efi' -PathType Leaf)) {
            throw 'Target EFI boot manager is missing.'
        }
        if (-not $script:FirmwareEntry) { throw 'No target-specific UEFI entry was created.' }
        $firmware = Invoke-CheckedTool 'bcdedit.exe' '/enum firmware /v' 'Read actual firmware entries'
        $entry = @($firmware -split '(?:\r?\n){2,}' | Where-Object {
            $_ -match "(?m)^\s*identifier\s+$([regex]::Escape($script:FirmwareEntry))\s*$"
        })
        if ($entry.Count -ne 1 -or $entry[0] -notmatch '(?m)^\s*device\s+partition=S:\s*$' -or
            $entry[0] -notmatch '(?m)^\s*path\s+\\EFI\\Microsoft\\Boot\\bootmgfw\.efi\s*$') {
            throw 'The actual UEFI firmware entry does not identify the target EFI boot manager.'
        }
        $order = Invoke-CheckedTool 'bcdedit.exe' '/enum {fwbootmgr} /v' 'Verify firmware boot order'
        if ($order -notmatch "(?m)^\s*displayorder\s+$([regex]::Escape($script:FirmwareEntry))\s*$") {
            throw 'Target UEFI entry is not first in firmware boot order.'
        }
    }
    elseif (-not (Test-Path -LiteralPath 'S:\bootmgr' -PathType Leaf)) { throw 'Legacy boot manager is missing.' }
}

function Install-RecoveryFirstBootHook {
    # Specialize runs as SYSTEM and does not depend on an administrator signing in.
    # Do not silently replace an image's existing unattended setup configuration.
    foreach ($existing in @('W:\Windows\Panther\unattend.xml', 'W:\Windows\Panther\Unattend\unattend.xml',
        'W:\Windows\System32\Sysprep\unattend.xml', 'W:\unattend.xml', 'W:\autounattend.xml')) {
        if (Test-Path -LiteralPath $existing) {
            throw "Existing answer file '$existing' conflicts with automatic WinRE activation. Integrate recovery setup in the image or disable SetupRecovery."
        }
    }
    $scripts = 'W:\Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    $hook = Join-Path $scripts 'AutoReset-EnableWinRE.ps1'
    Set-Content -LiteralPath $hook -Encoding UTF8 -Value @'
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:windir 'Temp\AutoReset-WinRE.log'
try {
    $tool = Join-Path $env:windir 'System32\reagentc.exe'
    & $tool /enable 2>&1 | Out-File -LiteralPath $log -Append
    if ($LASTEXITCODE -ne 0) { throw 'reagentc /enable failed.' }
    & $tool /info 2>&1 | Out-File -LiteralPath $log -Append
    if ($LASTEXITCODE -ne 0) { throw 'reagentc /info failed.' }
    [xml]$state = Get-Content -LiteralPath (Join-Path $env:windir 'System32\Recovery\ReAgent.xml') -Raw
    if ($state.WindowsRE.InstallState.state -ne '1' -or
        [string]::IsNullOrWhiteSpace($state.WindowsRE.WinreBCD.id) -or
        $state.WindowsRE.WinreBCD.id.Trim('{}') -eq '00000000-0000-0000-0000-000000000000') {
        throw 'WinRE activation could not be verified in ReAgent.xml.'
    }
    'WinRE enabled and registration verified after first boot.' | Out-File -LiteralPath $log -Append
    exit 0
}
catch {
    "FAILED: $($_.Exception.Message) Run reagentc /enable and reagentc /info as administrator." |
        Out-File -LiteralPath $log -Append
    exit 1
}
'@
    $architecture = if ($script:Preflight.Image.Architecture -eq 'x64') { 'amd64' } else { 'arm64' }
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    $answerFile = 'W:\Windows\Panther\unattend.xml'
    Set-Content -LiteralPath $answerFile -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add">
          <Order>1</Order>
          <Description>Enable and verify AutoReset Windows Recovery</Description>
          <Path>cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\AutoReset-EnableWinRE.ps1"</Path>
          <WillReboot>Never</WillReboot>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"@
    [xml]$answer = Get-Content -LiteralPath $answerFile -Raw
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf) -or
        $answer.unattend.settings.component.RunSynchronous.RunSynchronousCommand.Path -notlike '*AutoReset-EnableWinRE.ps1*') {
        throw 'First-boot WinRE activation hook could not be verified.'
    }
    $script:RecoveryStaged = $true
    $script:StepWarnings += 'WinRE is staged, not yet enabled. First-boot specialize setup will enable it; verify Windows\Temp\AutoReset-WinRE.log after boot.'
}

# ═════════════════════════════════════════════════════════════════════
# STAGE 1: SPLASH - Preparing AutoReset (5-second minimum)
# ═════════════════════════════════════════════════════════════════════

$splashForm = New-BaseForm -TitleSuffix 'Preparing...' -Width 480

$lblSplash              = New-Object System.Windows.Forms.Label
$lblSplash.Text         = 'Preparing AutoReset and gathering info...'
$lblSplash.Font         = UiFont 10
$lblSplash.AutoSize     = $true
$lblSplash.MaximumSize  = New-Object System.Drawing.Size(444, 0)
$lblSplash.ForeColor    = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblSplash.BackColor    = [System.Drawing.Color]::Transparent
$splashForm.Tag.Controls.Add($lblSplash)

# Pat - Set-FormSize before Show ------------------------------------
Set-FormSize -Form $splashForm
#--------------------------------------------------------------------
$splashForm.Show()
$splashForm.Activate()
Update-Ui

$splashStart = Get-Date

# ── Splash work: logging, hardware, disks, config ───────────────────

Write-Section "AutoReset v$($script:Version)"
Write-Log "Running script: $PSCommandPath | SHA256 $((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash)"
Write-LogBlock @(
    "Started      : $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    "Log file     : $($script:LogFile)"
    "Detail log   : $($script:DetailLog)"
    "SMSTS log    : $($script:SmsTsLog)"
)

Initialize-Configuration

if (-not $script:MediaRoot) {
    $splashForm.Close()
    $splashForm.Dispose()
    Show-Console
    [void][System.Windows.Forms.MessageBox]::Show(
        'AutoReset media not found. Ensure the USB contains Payload\UNE-Payload.tag.',
        (Title 'Error'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

$cs   = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$script:Model        = $cs.Model.Trim()
$script:Manufacturer = $cs.Manufacturer.Trim()
$script:Serial       = ($bios.SerialNumber -replace '[^A-Za-z0-9-]', '')
if (-not $script:Serial) {
    $script:Serial = 'NOSN{0:x6}' -f (Get-Random -Maximum 0xFFFFFF)
}

$peFw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction SilentlyContinue).PEFirmwareType
if ($peFw -notin @(1, 2)) { throw 'WinPE firmware type is unknown; refusing to select a partition layout.' }
$script:IsUefi = ($peFw -eq 2)

& powercfg.exe /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null

$driverMap = Get-Config 'DriverMap' @()
foreach ($entry in $driverMap) {
    if ($script:Model -like "*$($entry.Match)*") { $script:DriverFolder = $entry.Folder; break }
}
if (-not $script:DriverFolder) { $script:DriverFolder = $script:Model }

$script:AllDisks = @(Get-Disk | Sort-Object Number)
$script:ProtectedDiskNumbers = @(Get-DeploymentMediaDiskNumbers)

$configured = Get-Config 'TargetDiskNumber' $null
$script:TargetDisk = Get-InitialTargetDisk -Disks $script:AllDisks `
    -ProtectedDiskNumbers $script:ProtectedDiskNumbers -ConfiguredNumber $configured
if ($script:TargetDisk) {
    $script:TargetIdentity = Get-DiskIdentity -Disk $script:TargetDisk
}

$totalMem = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

Write-Section 'Device Information'
Write-LogBlock @(
    "Manufacturer : $($script:Manufacturer)"
    "Model        : $($script:Model)"
    "Service tag  : $($script:Serial)"
    "Firmware     : $(if ($script:IsUefi) { 'UEFI' } else { 'Legacy BIOS' })"
    "Memory       : ${totalMem} GB"
    "Driver match : $($script:DriverFolder)"
    "Media root   : $($script:MediaRoot)"
    "Config       : $(if ($script:ConfigJson) { 'reset.json loaded' } else { 'defaults (no reset.json)' })"
)

Write-Section 'Disk Inventory'
foreach ($d in $script:AllDisks) {
    $sizeGB = [math]::Round($d.Size / 1GB, 1)
    $letter = Get-PrimaryDriveLetter -DiskNumber $d.Number
    Write-LogBlock @(
        ("Disk {0}: {1} | {2} GB | {3} | {4} | Letter: {5}" -f
            $d.Number, $d.FriendlyName, $sizeGB, $d.BusType, $d.PartitionStyle, $letter)
    )
}

# ── Enforce 5-second minimum splash ─────────────────────────────────

$splashElapsed = (Get-Date) - $splashStart
$remaining = 5 - $splashElapsed.TotalSeconds
if ($remaining -gt 0) {
    $endWait = (Get-Date).AddSeconds($remaining)
    while ((Get-Date) -lt $endWait) {
        Update-Ui
        Start-Sleep -Milliseconds 100
    }
}

$splashForm.Close()
$splashForm.Dispose()

# ═════════════════════════════════════════════════════════════════════
# STAGE 2: CONFIRM DISK SELECTION
# ═════════════════════════════════════════════════════════════════════

function Show-DiskConfirmation {
    $sizeGB = [math]::Round($script:TargetDisk.Size / 1GB, 1)
    $letter = Get-PrimaryDriveLetter -DiskNumber $script:TargetDisk.Number

    $dlg = New-BaseForm -TitleSuffix 'Confirm Disk Selection' -Width 560

    $lblIntro             = New-Object System.Windows.Forms.Label
    $lblIntro.Text        = 'AutoReset has found the following disk to re-install Windows to:'
    $lblIntro.AutoSize    = $true
    $lblIntro.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $dlg.Tag.Controls.Add($lblIntro)

    $lblDisk             = New-Object System.Windows.Forms.Label
    $lblDisk.Text        = "Disk $($script:TargetDisk.Number): $($script:TargetDisk.FriendlyName) | $sizeGB GB | $letter`r`nIdentity: $script:TargetIdentity"
    $lblDisk.Font        = UiFont 10 -Bold
    $lblDisk.AutoSize    = $true
    $lblDisk.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $lblDisk.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
    $dlg.Tag.Controls.Add($lblDisk)

    $lblAsk             = New-Object System.Windows.Forms.Label
    $lblAsk.Text        = 'Is this the right disk?'
    $lblAsk.AutoSize    = $true
    $lblAsk.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $dlg.Tag.Controls.Add($lblAsk)

    $lblWarning           = New-Object System.Windows.Forms.Label
    $lblWarning.Text      = 'NOTE: Any actions performed after clicking Confirm are irreversible.'
    $lblWarning.Font      = UiFont 10 -Bold
    $lblWarning.ForeColor = [System.Drawing.Color]::Red
    $lblWarning.AutoSize  = $true
    $lblWarning.MaximumSize = New-Object System.Drawing.Size(524, 0)
    $lblWarning.Margin    = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $dlg.Tag.Controls.Add($lblWarning)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 524
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    # Pat - AutoSize buttons to prevent text truncation at high DPI -
    #----------------------------------------------------------------
    $btnChoose              = New-Object System.Windows.Forms.Button
    $btnChoose.Text         = 'Choose Disk'
    $btnChoose.AutoSize     = $true
    $btnChoose.MinimumSize  = New-Object System.Drawing.Size(112, 32)
    $btnChoose.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnPanel.Controls.Add($btnChoose)

    $btnConfirm              = New-Object System.Windows.Forms.Button
    $btnConfirm.Text         = 'Confirm'
    $btnConfirm.AutoSize     = $true
    $btnConfirm.MinimumSize  = New-Object System.Drawing.Size(112, 32)
    $btnConfirm.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    Set-PrimaryButtonStyle -Button $btnConfirm
    $btnPanel.Controls.Add($btnConfirm)
    #----------------------------------------------------------------

    $dlg.Tag.Controls.Add($btnPanel)

    $dlg.AcceptButton = $btnConfirm
    $dlg.CancelButton = $btnChoose

    $confirmYesTimer          = New-Object System.Windows.Forms.Timer
    $confirmYesTimer.Interval = 50
    $confirmYesTimer.Add_Tick({
        $confirmYesTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    }.GetNewClosure())

    $confirmNoTimer          = New-Object System.Windows.Forms.Timer
    $confirmNoTimer.Interval = 50
    $confirmNoTimer.Add_Tick({
        $confirmNoTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::No
    }.GetNewClosure())

    $btnConfirm.Add_Click({ $confirmYesTimer.Start() }.GetNewClosure())
    $btnChoose.Add_Click({ $confirmNoTimer.Start() }.GetNewClosure())

    # Pat - Ctrl+Shift+W launches KillDisk -------------------------
    #----------------------------------------------------------------
    $script:WipeRequested = $false

    $wipeTimer          = New-Object System.Windows.Forms.Timer
    $wipeTimer.Interval = 50
    $wipeTimer.Add_Tick({
        $wipeTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Abort
    }.GetNewClosure())

    $dlg.Add_KeyDown({
        if ($_.Control -and $_.Shift -and $_.KeyCode -eq [System.Windows.Forms.Keys]::W) {
            $_.Handled          = $true
            $_.SuppressKeyPress = $true
            $script:WipeRequested = $true
            $wipeTimer.Start()
        }
    }.GetNewClosure())
    #----------------------------------------------------------------

    # Pat - Set-FormSize before ShowDialog --------------------------
    Set-FormSize -Form $dlg
    #----------------------------------------------------------------
    $result = $dlg.ShowDialog()
    $confirmYesTimer.Dispose()
    $confirmNoTimer.Dispose()
    $wipeTimer.Stop()
    $wipeTimer.Dispose()
    $dlg.Dispose()
    return $result
}

function Show-DiskPicker {
    $dlg = New-BaseForm -TitleSuffix 'Disk Selection' -Width 800 -MinimumHeight 450
    $script:AllDisks = @(Get-Disk -ErrorAction Stop | Sort-Object Number)
    $script:ProtectedDiskNumbers = @(Get-DeploymentMediaDiskNumbers)

    $lbl             = New-Object System.Windows.Forms.Label
    $lbl.Text        = 'Please select the drive you would like to install Windows onto!'
    $lbl.AutoSize    = $true
    $lbl.MaximumSize = New-Object System.Drawing.Size(544, 0)
    $dlg.Tag.Controls.Add($lbl)

    $list               = New-Object System.Windows.Forms.ListView
    $list.View          = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect   = $false
    $list.GridLines     = $true
    $list.Margin        = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    [void]$list.Columns.Add('Name', 260)
    [void]$list.Columns.Add('Size (GB)', 100)
    [void]$list.Columns.Add('Drive', 80)

    $list.Font = $dlg.Font
    $list.Width = 760
    Initialize-DiskList -List $list -RowCount $script:AllDisks.Count

    foreach ($d in $script:AllDisks) {
        $sizeGB     = [math]::Round($d.Size / 1GB, 1)
        $letter     = Get-PrimaryDriveLetter -DiskNumber $d.Number
        $item       = New-Object System.Windows.Forms.ListViewItem("Disk $($d.Number): $($d.FriendlyName)")
        [void]$item.SubItems.Add("$sizeGB")
        [void]$item.SubItems.Add($letter)
        $selectable = Test-EligibleTargetDisk -Disk $d -ProtectedDiskNumbers $script:ProtectedDiskNumbers
        $item.Tag   = if ($selectable) { $d } else { $null }
        if (-not $selectable) {
            $item.ForeColor = [System.Drawing.SystemColors]::GrayText
        }
        [void]$list.Items.Add($item)
    }
    $dlg.Tag.Controls.Add($list)

    $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'RightToLeft'
    $btnPanel.AutoSize      = $true
    $btnPanel.Width         = 544
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

    # Pat - AutoSize buttons ----------------------------------------
    #----------------------------------------------------------------
    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.AutoSize     = $true
    $btnCancel.MinimumSize  = New-Object System.Drawing.Size(96, 32)
    $btnCancel.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnPanel.Controls.Add($btnCancel)

    $btnSelect              = New-Object System.Windows.Forms.Button
    $btnSelect.Text         = 'Select'
    $btnSelect.AutoSize     = $true
    $btnSelect.MinimumSize  = New-Object System.Drawing.Size(112, 32)
    $btnSelect.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $btnSelect.Enabled      = $false
    Set-PrimaryButtonStyle -Button $btnSelect
    $btnPanel.Controls.Add($btnSelect)
    #----------------------------------------------------------------

    $dlg.Tag.Controls.Add($btnPanel)

    $list.Add_ItemSelectionChanged({
        if ($null -eq $_.Item.Tag) { $_.Item.Selected = $false }
        $btnSelect.Enabled = ($list.SelectedItems.Count -gt 0 -and $null -ne $list.SelectedItems[0].Tag)
    }.GetNewClosure())

    $pickerOkTimer          = New-Object System.Windows.Forms.Timer
    $pickerOkTimer.Interval = 50
    $pickerOkTimer.Add_Tick({
        $pickerOkTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }.GetNewClosure())

    $pickerCancelTimer          = New-Object System.Windows.Forms.Timer
    $pickerCancelTimer.Interval = 50
    $pickerCancelTimer.Add_Tick({
        $pickerCancelTimer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }.GetNewClosure())

    $btnSelect.Add_Click({
        if ($list.SelectedItems.Count -gt 0 -and $null -ne $list.SelectedItems[0].Tag) {
            $pickerOkTimer.Start()
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({ $pickerCancelTimer.Start() }.GetNewClosure())
    $dlg.AcceptButton = $btnSelect
    $dlg.CancelButton = $btnCancel

    # Pat - Set-FormSize before ShowDialog --------------------------
    Set-FormSize -Form $dlg
    #----------------------------------------------------------------
    $result = $dlg.ShowDialog()
    $chosen = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedItems.Count -gt 0) {
        $chosen = $list.SelectedItems[0].Tag
    }
    $pickerOkTimer.Dispose()
    $pickerCancelTimer.Dispose()
    $dlg.Dispose()
    if ($null -eq $chosen) { return $null }
    $identity = Get-DiskIdentity -Disk $chosen
    $script:ProtectedDiskNumbers = @(Get-DeploymentMediaDiskNumbers)
    return (Assert-TargetDiskSafe -DiskNumber $chosen.Number -ExpectedIdentity $identity `
        -ProtectedDiskNumbers $script:ProtectedDiskNumbers)
}

# ── Disk confirmation loop ──────────────────────────────────────────

if (-not $script:TargetDisk) {
    Write-Log 'Multiple eligible disks detected; explicit selection is required.'
    $script:TargetDisk = Show-DiskPicker
    if (-not $script:TargetDisk) { throw 'Disk selection cancelled; no changes were made.' }
    $script:TargetIdentity = Get-DiskIdentity -Disk $script:TargetDisk
}

if (Get-Config 'ConfirmBeforeWipe' $true) {
    while ($true) {
        $sizeGB = [math]::Round($script:TargetDisk.Size / 1GB, 1)
        $letter = Get-PrimaryDriveLetter -DiskNumber $script:TargetDisk.Number
        Write-Log ("Presenting disk for confirmation: {0} | {1} GB | {2}" -f $script:TargetDisk.FriendlyName, $sizeGB, $letter)

        $confirmResult = Show-DiskConfirmation

        # Pat - Ctrl+Shift+W: launch KillDisk -------------------------
        #---------------------------------------------------------------
        if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Abort) {
            try {
                Write-Log 'User triggered KillDisk launch (Ctrl+Shift+W).'

                $wipeScript = $null
                foreach ($root in @($script:MediaRoot, $script:ImagePayloadRoot)) {
                    if (-not $root) { continue }
                    $candidate = Join-Path $root 'Scripts\Invoke-KillDisk.ps1'
                    Write-Log "Checking for wipe script: $candidate"
                    if (Test-Path $candidate) { $wipeScript = $candidate; break }
                }

                Write-Log "MediaRoot: $($script:MediaRoot)"
                Write-Log "ImagePayloadRoot: $($script:ImagePayloadRoot)"
                Write-Log "Resolved wipe script: $wipeScript"

                if ($wipeScript) {
                    Invoke-KillDiskProcess -ScriptPath $wipeScript -Serial $script:Serial
                    exit 0
                }
                else {
                    Write-Log 'Invoke-KillDisk.ps1 not found on media.' 'ERROR'
                    [void][System.Windows.Forms.MessageBox]::Show(
                        'Invoke-KillDisk.ps1 was not found on the deployment media.',
                        (Title 'Error'),
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error)
                }
            }
            catch {
                Write-Log "KillDisk launch FAILED: $($_.Exception.Message)" 'ERROR'
                Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
                if ($_.ScriptStackTrace) {
                    Write-Log "Stack: $($_.ScriptStackTrace -replace "`n", ' -> ')" 'ERROR'
                }
                Show-Console
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch KillDisk:`r`n`r`n$($_.Exception.Message)`r`n`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`n`r`nCheck log: $($script:LogFile)",
                    (Title 'KillDisk Error'),
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error)
            }
            continue
        }
        #---------------------------------------------------------------

        if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Disk confirmed by user.'
            break
        }

        Write-Log 'User chose to pick a different disk.'
        $picked = Show-DiskPicker
        if (-not $picked) {
            Write-Log 'User cancelled disk selection.' 'ERROR'
            exit 1
        }
        $script:TargetDisk = $picked
        $script:TargetIdentity = Get-DiskIdentity -Disk $picked
    }
}
else {
    Write-Log 'Disk confirmation skipped (ConfirmBeforeWipe = false).'
}

$sizeGB = [math]::Round($script:TargetDisk.Size / 1GB, 1)
Write-Section 'Target Disk'
Write-LogBlock @(
    "Disk         : $($script:TargetDisk.Number)"
    "Name         : $($script:TargetDisk.FriendlyName)"
    "Size         : $sizeGB GB"
    "Bus type     : $($script:TargetDisk.BusType)"
    "Style        : $($script:TargetDisk.PartitionStyle)"
)

# ═════════════════════════════════════════════════════════════════════
# STAGE 3: MAIN DEPLOYMENT
# ═════════════════════════════════════════════════════════════════════

try {

$form = New-BaseForm -TitleSuffix '' -Width 500
$form.Text = Title

$tlpTop = New-Object System.Windows.Forms.TableLayoutPanel
$tlpTop.ColumnCount = 2
$tlpTop.RowCount = 1
$tlpTop.Width = 464
$tlpTop.AutoSize = $true
$tlpTop.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$tlpTop.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$lblTime              = New-Object System.Windows.Forms.Label
$lblTime.Text         = 'Time Remaining: estimating...'
$lblTime.Font         = UiFont 9
$lblTime.AutoSize     = $true
$lblTime.Dock         = 'Fill'
$lblTime.ForeColor    = [System.Drawing.Color]::FromArgb(100, 100, 100)
$lblTime.BackColor    = [System.Drawing.Color]::Transparent
$tlpTop.Controls.Add($lblTime, 0, 0)

$lblPct              = New-Object System.Windows.Forms.Label
$lblPct.Text         = '0%'
$lblPct.Font         = UiFont 10 -Bold
$lblPct.AutoSize     = $true
$lblPct.Dock         = 'Fill'
$lblPct.TextAlign    = 'MiddleRight'
$lblPct.ForeColor    = [System.Drawing.Color]::Black
$lblPct.BackColor    = [System.Drawing.Color]::Transparent
$tlpTop.Controls.Add($lblPct, 1, 0)

$form.Tag.Controls.Add($tlpTop)

$pbMain                       = New-Object System.Windows.Forms.ProgressBar
$pbMain.Minimum               = 0
$pbMain.Maximum               = 100
$pbMain.Style                 = 'Continuous'
$pbMain.MarqueeAnimationSpeed = 0
$pbMain.Value                 = 0
$pbMain.Size                  = New-Object System.Drawing.Size(464, 20)
$pbMain.Margin                = New-Object System.Windows.Forms.Padding(0, 5, 0, 10)
$form.Tag.Controls.Add($pbMain)

$lblStep              = New-Object System.Windows.Forms.Label
$lblStep.Text         = ''
$lblStep.Font         = UiFont 10 -Bold
$lblStep.AutoSize     = $true
$lblStep.MinimumSize  = New-Object System.Drawing.Size(464, 0)
$lblStep.MaximumSize  = New-Object System.Drawing.Size(464, 0)
$lblStep.TextAlign    = 'MiddleCenter'
$lblStep.ForeColor    = [System.Drawing.Color]::Black
$lblStep.BackColor    = [System.Drawing.Color]::Transparent
$lblStep.Visible      = $false
$form.Tag.Controls.Add($lblStep)

$pbStep         = New-Object System.Windows.Forms.ProgressBar
$pbStep.Minimum = 0
$pbStep.Maximum = 100
$pbStep.Size    = New-Object System.Drawing.Size(464, 20)
$pbStep.Visible = $false
$form.Tag.Controls.Add($pbStep)

function Update-TimeRemaining {
    $elapsed = (Get-Date) - $script:DeployStart
    $pct     = 0
    if ($script:WeightTotal -gt 0) {
        $pct = ($script:WeightDone + ($script:CurrentWeight * $pbStep.Value / 100)) / $script:WeightTotal
    }
    if ($pct -le 0.02 -or $elapsed.TotalSeconds -lt 5) {
        $lblTime.Text = 'Time Remaining: estimating...'
        return
    }
    $totalEstimate = [TimeSpan]::FromSeconds($elapsed.TotalSeconds / $pct)
    $remaining     = $totalEstimate - $elapsed
    if ($remaining.TotalSeconds -lt 0) { $remaining = [TimeSpan]::Zero }

    if ($remaining.TotalHours -ge 1) {
        $lblTime.Text = 'Time Remaining: {0}h {1}m' -f [int]$remaining.TotalHours, $remaining.Minutes
    }
    elseif ($remaining.TotalMinutes -ge 1) {
        $lblTime.Text = 'Time Remaining: {0}m {1}s' -f [int]$remaining.TotalMinutes, $remaining.Seconds
    }
    else {
        $lblTime.Text = 'Time Remaining: less than a minute'
    }
}

function Set-Action {
    param([string]$Text, [switch]$Quiet)
    $lblStep.Text    = $Text
    $lblStep.Visible = $true
    if (-not $Quiet) { Write-Log $Text }
    Set-FormSize -Form $form
    Update-Ui
}

function Set-StepPercent {
    param([double]$Percent)
    $wasVisible = $pbStep.Visible
    if ($Percent -ge 0) {
        $stepPercent = [int][math]::Min(100, [math]::Round($Percent))

        if ($stepPercent -gt 0 -and $stepPercent -lt 100) {
            if (-not $pbStep.Visible) {
                $pbStep.Visible               = $true
                $pbStep.Style                 = 'Continuous'
                $pbStep.MarqueeAnimationSpeed = 0
            }
        }
        else {
            if ($pbStep.Visible) {
                $pbStep.Visible = $false
            }
        }

        $pbStep.Value = $stepPercent
        $overall = $script:WeightDone + ($script:CurrentWeight * $stepPercent / 100)
        $overallPct = [int][math]::Min(100, [math]::Round(100 * $overall / $script:WeightTotal))
        $pbMain.Style                 = 'Continuous'
        $pbMain.MarqueeAnimationSpeed = 0
        $pbMain.Value                 = $overallPct
        $lblPct.Text                  = "${overallPct}%"

        Update-TimeRemaining
    }
    if ($wasVisible -ne $pbStep.Visible) { Set-FormSize -Form $form }
    Update-Ui
}

# ── Deployment steps ─────────────────────────────────────────────────

$steps = @(
    @{
        Name = 'Preflight'
        Weight = 7
        Action = { $script:Preflight = Invoke-DeploymentPreflight }
    }
    @{
        Name   = 'Wipe and Partition'
        Weight = 5
        Action = {
            if (-not $script:Preflight) { throw 'Preflight has not completed; refusing to wipe.' }
            $diskNum = $script:TargetDisk.Number
            if ($script:IsUefi) {
                $dp = @"
select disk $diskNum
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label=System
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=2048
format quick fs=ntfs label=Windows
assign letter=W
create partition primary
format quick fs=ntfs label=Recovery
assign letter=R
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac override
gpt attributes=0x8000000000000001
exit
"@
                Write-Log 'Partition layout: GPT (EFI 260 MB, MSR 16 MB, Windows, Recovery 2 GB)'
            }
            else {
                $dp = @"
select disk $diskNum
clean
convert mbr
create partition primary size=260
format quick fs=ntfs label=System
assign letter=S
active
create partition primary
shrink minimum=2048
format quick fs=ntfs label=Windows
assign letter=W
create partition primary
format quick fs=ntfs label=Recovery
assign letter=R
set id=27 override
exit
"@
                Write-Log 'Partition layout: MBR (System 260 MB active, Windows, Recovery 2 GB)'
            }
            $dpFile = Join-Path $logRoot 'autoreset-partition.txt'
            Set-Content -Path $dpFile -Value $dp -Encoding Ascii

            Assert-WinPEEnvironment
            $script:ProtectedDiskNumbers = @(Get-DeploymentMediaDiskNumbers)
            Assert-DeploymentLettersAvailable
            Assert-DriverArchiveUnchanged -Drivers $script:Preflight.Drivers
            Assert-DeploymentSourceUnchanged -Preflight $script:Preflight
            $script:TargetDisk = Assert-TargetDiskSafe -DiskNumber $diskNum `
                -ExpectedIdentity $script:TargetIdentity -ProtectedDiskNumbers $script:ProtectedDiskNumbers
            $result = Invoke-External -FilePath 'diskpart.exe' -Arguments "/s `"$dpFile`"" -What 'diskpart'
            if ($result.ExitCode -ne 0) { throw "diskpart failed (exit code $($result.ExitCode))." }
            Assert-TargetPartitions
            $script:PartitionsVerified = $true
            Write-Log 'Disk wiped and partitions created successfully.'
        }
    }
    @{
        Name   = 'Installing Windows'
        Weight = 50
        Action = {
            Assert-TargetPartitions
            $wim = $script:Preflight.Image.Path
            $index = $script:Preflight.Image.Index
            $result = Invoke-External -FilePath 'dism.exe' -What 'dism /Apply-Image' -ParsePercent -Arguments (
                "/Apply-Image /ImageFile:`"$wim`" /Index:$index /ApplyDir:W:\ /CheckIntegrity /Verify")
            if ($result.ExitCode -ne 0) { throw "Applying the image failed (exit $($result.ExitCode))." }
            if (-not (Test-Path 'W:\Windows\System32')) { throw 'Image applied but W:\Windows\System32 is missing.' }
            Write-Log ('Image applied successfully in {0:mm\:ss}.' -f $result.Elapsed)
        }
    }
    @{
        Name   = 'Installing Drivers'
        Weight = 20
        Action = {
            Assert-TargetPartitions
            if (-not $script:Preflight.Drivers) { return 'SKIPPED' }
            $driverPath = Expand-ValidatedDriverArchive -Drivers $script:Preflight.Drivers
            $count = $script:Preflight.Drivers.Count
            Write-Log ("Driver source: {0}" -f $driverPath)
            Write-Log ("Packages     : {0} .inf file(s)" -f $count)
            $r = Invoke-External -FilePath 'dism.exe' -What 'dism /Add-Driver' -ParsePercent -Arguments (
                "/Image:W:\ /Add-Driver /Driver:`"$driverPath`" /Recurse")

            if ($r.ExitCode -eq 0) {
                $script:DriversAdded = $count
                Write-Log ('{0} driver package(s) injected successfully.' -f $count)
            }
            else {
                if ((Get-Config 'ContinueOnDriverError' $false) -and -not (Get-Config 'DriversRequired' $false)) {
                    Write-Log ("Driver injection returned exit code {0}. Some packages may have failed." -f $r.ExitCode) 'WARN'
                    $script:StepWarnings += 'Some drivers failed to install.'
                }
                else { throw "Driver injection failed (exit $($r.ExitCode))." }
            }
        }
    }
    @{
        Name   = 'Create WinRE Partition'
        Weight = 4
        Action = {
            Assert-TargetPartitions
            if (-not (Get-Config 'SetupRecovery' $true)) {
                Write-Log 'Skipped: SetupRecovery is disabled in reset.json.'
                return 'SKIPPED'
            }
            $winre = 'W:\Windows\System32\Recovery\Winre.wim'
            if (-not (Test-Path -LiteralPath $winre -PathType Leaf)) { throw 'Requested Winre.wim is absent from the applied image.' }
            $reagentc = 'W:\Windows\System32\ReAgentc.exe'
            if (-not (Test-Path -LiteralPath $reagentc -PathType Leaf)) { throw 'The applied image lacks ReAgentc.exe.' }
            if ((Get-Volume -DriveLetter R -ErrorAction Stop).SizeRemaining -lt ((Get-Item -LiteralPath $winre).Length + 250MB)) {
                throw 'The recovery image does not fit with the required recovery servicing reserve.'
            }
            New-Item -ItemType Directory -Path 'R:\Recovery\WindowsRE' -Force | Out-Null
            Copy-Item -Path $winre -Destination 'R:\Recovery\WindowsRE\Winre.wim' -Force
            if ((Get-FileHash -LiteralPath $winre -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath 'R:\Recovery\WindowsRE\Winre.wim' -Algorithm SHA256).Hash) {
                throw 'The staged recovery image failed hash verification.'
            }
            Write-Log 'Winre.wim copied to R:\Recovery\WindowsRE.'
            $result = Invoke-External -FilePath $reagentc -What 'reagentc' -Arguments (
                '/SetREImage /Path R:\Recovery\WindowsRE /Target W:\Windows')
            if ($result.ExitCode -ne 0) { throw 'Offline WinRE path registration failed.' }
            Install-RecoveryFirstBootHook
            Write-Log 'Recovery image and first-boot activation hook staged. WinRE activation is not verified until Windows boots.'
        }
    }
    @{
        Name   = 'Create Boot Data'
        Weight = 5
        Action = {
            Assert-TargetPartitions
            if ($script:IsUefi) {
                $result = Invoke-External -FilePath 'bcdboot.exe' -What 'bcdboot' -Arguments 'W:\Windows /s S: /f UEFI'
                if ($result.ExitCode -ne 0) { throw "bcdboot failed (exit $($result.ExitCode))." }
                # /s populates the target ESP but deliberately does not create an NVRAM entry.
                # Copy the firmware-class boot manager, then bind it explicitly to the selected ESP.
                $created = Invoke-CheckedTool 'bcdedit.exe' '/copy {bootmgr} /d "Windows Boot Manager - AutoReset"' 'Create target firmware entry'
                if ($created -notmatch '\{[0-9a-fA-F-]{36}\}') { throw 'Could not identify the newly created UEFI entry.' }
                $script:FirmwareEntry = $Matches[0]
                $null = Invoke-CheckedTool 'bcdedit.exe' "/set $script:FirmwareEntry device partition=S:" 'Set target firmware device'
                $null = Invoke-CheckedTool 'bcdedit.exe' "/set $script:FirmwareEntry path \EFI\Microsoft\Boot\bootmgfw.efi" 'Set target firmware path'
                $null = Invoke-CheckedTool 'bcdedit.exe' "/set {fwbootmgr} displayorder $script:FirmwareEntry /addfirst" 'Set target firmware boot order'
            }
            else {
                $result = Invoke-External -FilePath 'bcdboot.exe' -What 'bcdboot' -Arguments 'W:\Windows /s S: /f BIOS'
                if ($result.ExitCode -ne 0) { throw "bcdboot failed (exit $($result.ExitCode))." }
                $null = Invoke-CheckedTool $script:Preflight.Bootsect '/nt60 S: /mbr' 'Write target BIOS boot code'
                Write-Log 'Legacy BIOS boot configuration created.'
            }
            Assert-TargetBootConfiguration
        }
    }
    @{
        Name   = 'Verify Install'
        Weight = 3
        Action = {
            Write-Log 'Running post-installation verification...'
            Assert-TargetBootConfiguration
            $problems = @()
            if (-not (Test-Path 'W:\Windows\System32\ntoskrnl.exe')) { $problems += 'ntoskrnl.exe missing.' }
            if (-not (Test-Path 'W:\Windows\System32\config\SYSTEM')) { $problems += 'SYSTEM registry hive missing.' }

            $bootOk = if ($script:IsUefi) { Test-Path 'S:\EFI\Microsoft\Boot\BCD' } else { Test-Path 'S:\Boot\BCD' }
            if (-not $bootOk) { $problems += 'Boot Configuration Data (BCD) not found.' }

            $free = (Get-Volume -DriveLetter W -ErrorAction SilentlyContinue).SizeRemaining
            if ($free) { Write-Log ('Windows volume free space: {0:N1} GB' -f ($free / 1GB)) }
            if ($script:DriversAdded -gt 0) {
                Write-Log ('{0} driver package(s) were injected.' -f $script:DriversAdded)
            }

            if ($problems.Count -gt 0) {
                foreach ($p in $problems) { Write-Log "VERIFICATION FAILED: $p" 'ERROR' }
                throw ('Verification failed: ' + ($problems -join ' | '))
            }
            if ((Get-Config 'SetupRecovery' $true) -and -not $script:RecoveryStaged) {
                throw 'Requested recovery setup has not been staged.'
            }
            Write-Log 'Offline file, partition and boot-configuration checks passed. Bootability, OOBE, networking and WinRE activation still require a real Windows boot.'
        }
    }
    @{
        Name   = 'Save Logs'
        Weight = 6
        Action = {
            Write-Log 'Saving logs to the installed OS and deployment media...'
            try { Copy-LogsToTarget } catch { Write-Log "Copy-LogsToTarget failed: $($_.Exception.Message)" 'WARN' }
            Write-Log 'Logs copied to W:\Windows\Temp.'
            [void](Save-DeviceLog -Result 'SUCCESS')
        }
    }
)

# ── Engine ───────────────────────────────────────────────────────────

$script:WeightTotal   = 0.0
foreach ($s in $steps) { $script:WeightTotal += [double]$s.Weight }
$script:WeightDone    = 0.0
$script:CurrentWeight = 0.0
$script:DeployStart   = Get-Date

# Pat - Set-FormSize before Show ------------------------------------
Set-FormSize -Form $form
#--------------------------------------------------------------------
$form.Show()
$form.Activate()
Update-Ui

}
catch {
    Write-Log "Stage 3 setup crash: $($_.Exception.Message)" 'ERROR'
    Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-Log "Stack: $($_.ScriptStackTrace -replace "`n", ' -> ')" 'ERROR'
    }
    $crashForm = New-BaseForm -TitleSuffix 'CRASH CAUGHT' -Width 600

    $crashLbl             = New-Object System.Windows.Forms.Label
    $crashLbl.Text        = "Crash during form setup!`r`n`r`n$($_.Exception.Message)`r`n`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`n`r`nPress F3 for log, F8 for cmd. Close this to reboot."
    $crashLbl.AutoSize    = $true
    $crashLbl.MaximumSize = New-Object System.Drawing.Size(564, 0)
    $crashForm.Tag.Controls.Add($crashLbl)

    $crashForm.ControlBox = $true
    # Pat - Set-FormSize before ShowDialog --------------------------
    Set-FormSize -Form $crashForm
    #----------------------------------------------------------------
    [void]$crashForm.ShowDialog()
    $crashForm.Dispose()
    exit 1
}

# Pat - Wrap entire deployment engine + Stage 4 in try/catch -------
#-------------------------------------------------------------------
try {

Write-Section 'Deployment Started'

$failed     = $false
$failedStep = $null
$failedReason = $null
$stepNumber = 0
$results    = New-Object System.Collections.Generic.List[object]

foreach ($step in $steps) {
    $stepNumber++
    $script:CurrentWeight = [double]$step.Weight
    $script:LogComponent  = $step.Name
    $stepStart = Get-Date

    Write-Section ("Step {0}/{1}: {2}" -f $stepNumber, $steps.Count, $step.Name)

    $pbStep.Visible  = $false
    $pbStep.Value    = 0
    $lblStep.Visible = $false
    $lblStep.Text    = ''
    Set-Action $step.Name -Quiet
    Update-Ui

    try {
        $outcome = & $step.Action
        $elapsed = (Get-Date) - $stepStart
        $state   = if ("$outcome" -eq 'SKIPPED') { 'SKIPPED' } else { 'OK' }
        Write-Log ("{0} completed: {1} ({2:mm\:ss})" -f $step.Name, $state, $elapsed)
        $results.Add([pscustomobject]@{ Step = $step.Name; State = $state; Elapsed = $elapsed })

        Set-StepPercent 100
        $script:WeightDone += $script:CurrentWeight
        Update-Ui
    }
    catch {
        $failed     = $true
        $failedStep = $step.Name
        $failedReason = $_.Exception.Message
        $elapsed    = (Get-Date) - $stepStart
        $results.Add([pscustomobject]@{ Step = $step.Name; State = 'FAILED'; Elapsed = $elapsed })
        Write-Log ("{0} FAILED after {1:mm\:ss}" -f $step.Name, $elapsed) 'ERROR'
        Write-Log ("Exception: {0}" -f $_.Exception.Message) 'ERROR'
        if ($_.ScriptStackTrace) {
            Write-Log ("Stack: {0}" -f ($_.ScriptStackTrace -replace "`n", ' -> ')) 'ERROR'
        }
        break
    }
}

if ($script:DriverScratch -and (Test-Path -LiteralPath $script:DriverScratch)) {
    try {
        Assert-TargetPartitions
        Remove-Item -LiteralPath $script:DriverScratch -Recurse -Force -ErrorAction Stop
    }
    catch { Write-Log "Driver staging cleanup skipped or failed: $($_.Exception.Message)" 'WARN' }
}

# ── Summary ──────────────────────────────────────────────────────────

$script:LogComponent = 'AutoReset'
$totalDuration = (Get-Date) - $script:StartTime
$outcome = if ($failed) { 'FAILED' } else { 'SUCCESS' }

Write-Section 'Run Summary'
Write-LogBlock @(
    "Result       : $outcome"
    "Device       : $($script:Manufacturer) $($script:Model)"
    "Service tag  : $(if ($script:Serial) { $script:Serial } else { 'UNKNOWN' })"
    "Duration     : $('{0:hh\:mm\:ss}' -f $totalDuration)"
    ''
    ('{0,-28} {1,-10} {2}' -f 'Step', 'Result', 'Duration')
    ('{0,-28} {1,-10} {2}' -f '----', '------', '--------')
)
foreach ($r in $results) {
    Write-LogBlock @(
        ('{0,-28} {1,-10} {2:mm\:ss}' -f $r.Step, $r.State, $r.Elapsed)
    )
}
Write-LogBlock @(
    ''
    ('{0,-28} {1,-10} {2:hh\:mm\:ss}' -f 'TOTAL', $outcome, $totalDuration)
)
if ($script:StepWarnings.Count -gt 0) {
    Write-LogBlock @('', 'Warnings:')
    foreach ($w in $script:StepWarnings) { Write-LogBlock @("  - $w") }
}

try { Copy-LogsToTarget } catch { Write-Log "Final log copy failed: $($_.Exception.Message)" 'WARN' }

# ═════════════════════════════════════════════════════════════════════
# STAGE 4: COMPLETION OR ERROR
# ═════════════════════════════════════════════════════════════════════

$form.Visible = $false

if (-not $failed) {
    try {
        Write-Section 'AutoReset completed successfully'

        $dlg = New-BaseForm -TitleSuffix 'Complete!' -Width 580

        $serial = if ($script:Serial) { $script:Serial } else { 'this device' }

        $lblDone             = New-Object System.Windows.Forms.Label
        $lblDone.Text        = "Windows has been installed and offline checks passed. Bootability and OOBE still require a successful Windows boot.$(if ($script:RecoveryStaged) { ' WinRE activation is scheduled for first-boot setup; check Windows\Temp\AutoReset-WinRE.log afterwards.' }) Please ensure the following:"
        $lblDone.AutoSize    = $true
        $lblDone.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $dlg.Tag.Controls.Add($lblDone)

        $lblChecklist             = New-Object System.Windows.Forms.Label
        $lblChecklist.Text        = "    -  $serial is unblocked in Intune`r`n    -  $serial is removed from Active Directory`r`n    -  $serial is removed from SCCM"
        $lblChecklist.AutoSize    = $true
        $lblChecklist.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $lblChecklist.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
        $dlg.Tag.Controls.Add($lblChecklist)

        $lblRemoveUsb             = New-Object System.Windows.Forms.Label
        $lblRemoveUsb.Text        = 'Remove the deployment USB or eject/disconnect the ISO, then click Restart. If media cannot be detached yet, select the installed Windows disk in the firmware boot menu.'
        $lblRemoveUsb.Font        = UiFont 10 -Bold
        $lblRemoveUsb.ForeColor   = [System.Drawing.Color]::Red
        $lblRemoveUsb.AutoSize    = $true
        $lblRemoveUsb.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $dlg.Tag.Controls.Add($lblRemoveUsb)

        $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
        $btnPanel.FlowDirection = 'RightToLeft'
        $btnPanel.AutoSize      = $true
        $btnPanel.Width         = 544
        $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

        # Pat - AutoSize button -------------------------------------
        #------------------------------------------------------------
        $btnRestart              = New-Object System.Windows.Forms.Button
        $btnRestart.Text         = 'Restart'
        $btnRestart.AutoSize     = $true
        $btnRestart.MinimumSize  = New-Object System.Drawing.Size(132, 32)
        $btnRestart.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
        $btnRestart.Enabled      = $true
        Set-PrimaryButtonStyle -Button $btnRestart
        #------------------------------------------------------------

        $btnPanel.Controls.Add($btnRestart)
        $dlg.Tag.Controls.Add($btnPanel)
        $dlg.AcceptButton = $btnRestart

        $successTimer          = New-Object System.Windows.Forms.Timer
        $successTimer.Interval = 50
        $successTimer.Add_Tick({
            $successTimer.Stop()
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }.GetNewClosure())
        $btnRestart.Add_Click({ $successTimer.Start() }.GetNewClosure())

        # Pat - Set-FormSize before ShowDialog ----------------------
        Set-FormSize -Form $dlg
        #------------------------------------------------------------
        [void]$dlg.ShowDialog()
        $successTimer.Dispose()
        $dlg.Dispose()

        Write-Log 'User clicked Restart. Rebooting device.'
        try { Copy-LogsToTarget } catch { }
        & wpeutil.exe reboot
        exit 0
    }
    catch {
        Show-Console
        try {
            Write-Log "Completion screen failed: $($_.Exception.Message)" 'ERROR'
            Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
            try { Copy-LogsToTarget } catch { }
        } catch { }
        Write-Host ''
        Write-Host '  AutoReset completed successfully but the completion screen failed.' -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Line:  $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Logs: $($script:LogFile)" -ForegroundColor Yellow
        Write-Host '  Press any key to reboot...' -ForegroundColor Gray
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        & wpeutil.exe reboot
        exit 0
    }
}
else {
    try {
        $friendly = Get-FriendlyError -StepName $failedStep
        $dlg = New-BaseForm -TitleSuffix 'Error' -Width 580

        Show-Console

        [void](Save-DeviceLog -Result 'FAILED')

        $lblError             = New-Object System.Windows.Forms.Label
        $lblError.Text        = "AutoReset has encountered an error $friendly`r`n`r`n$failedReason`r`n`r`nRestart does not retry this step. Booting deployment media again starts a new deployment and can wipe the disk again."
        $lblError.AutoSize    = $true
        $lblError.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $dlg.Tag.Controls.Add($lblError)

        $lblLogHint             = New-Object System.Windows.Forms.Label
        $lblLogHint.Text        = "Service tag: $($script:Serial)  |  Logs: $($script:LogFile)"
        $lblLogHint.Font        = UiFont 8
        $lblLogHint.AutoSize    = $true
        $lblLogHint.MaximumSize = New-Object System.Drawing.Size(544, 0)
        $lblLogHint.Margin      = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
        $lblLogHint.ForeColor   = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $dlg.Tag.Controls.Add($lblLogHint)

        $btnPanel               = New-Object System.Windows.Forms.FlowLayoutPanel
        $btnPanel.FlowDirection = 'RightToLeft'
        $btnPanel.AutoSize      = $true
        $btnPanel.Width         = 544
        $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0, 15, 0, 0)

        $errorRestartTimer          = New-Object System.Windows.Forms.Timer
        $errorRestartTimer.Interval = 50
        $errorRestartTimer.Add_Tick({
            $errorRestartTimer.Stop()
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }.GetNewClosure())

        # Pat - AutoSize buttons ------------------------------------
        #------------------------------------------------------------
        $btnRestart              = New-Object System.Windows.Forms.Button
        $btnRestart.Text         = 'Restart'
        $btnRestart.AutoSize     = $true
        $btnRestart.MinimumSize  = New-Object System.Drawing.Size(120, 32)
        $btnRestart.Padding      = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
        $btnRestart.Add_Click({ $errorRestartTimer.Start() }.GetNewClosure())

        Set-PrimaryButtonStyle -Button $btnRestart
        $btnPanel.Controls.Add($btnRestart)
        #------------------------------------------------------------

        $dlg.Tag.Controls.Add($btnPanel)
        $dlg.AcceptButton = $btnRestart

        # Pat - Set-FormSize before ShowDialog ----------------------
        Set-FormSize -Form $dlg
        #------------------------------------------------------------
        [void]$dlg.ShowDialog()
        $errorRestartTimer.Dispose()
        $dlg.Dispose()

        Write-Section 'AutoReset FAILED'
        Write-Log 'User clicked Restart after failure.'
        try { Copy-LogsToTarget } catch { }
        & wpeutil.exe reboot
        exit 1
    }
    catch {
        Show-Console
        try { Write-Log "Error handler itself failed: $($_.Exception.Message)" 'ERROR' } catch { }
        Write-Host ''
        Write-Host '  AutoReset FAILED and the error dialog could not be shown.' -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Logs: $($script:LogFile)" -ForegroundColor Yellow
        Write-Host "  Service tag: $($script:Serial)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Type EXIT to reboot, or press F8 to open another command prompt.' -ForegroundColor Gray
        Write-Host ''
        Start-Process -FilePath (Join-Path $env:windir 'System32\cmd.exe') `
            -ArgumentList '/k echo AutoReset FAILED. Type EXIT to reboot.' -Wait
        exit 1
    }
}

# Pat - Outer catch for entire deployment engine + Stage 4 ---------
#-------------------------------------------------------------------
}
catch {
    Show-Console
    try {
        Write-Log "UNHANDLED deployment crash: $($_.Exception.Message)" 'ERROR'
        Write-Log "Line: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
        if ($_.ScriptStackTrace) {
            Write-Log "Stack: $($_.ScriptStackTrace -replace "`n", ' -> ')" 'ERROR'
        }
        try { Copy-LogsToTarget } catch { }
        try { [void](Save-DeviceLog -Result 'FAILED') } catch { }
    } catch { }

    try {
        $crashForm = New-BaseForm -TitleSuffix 'UNHANDLED ERROR' -Width 600

        $crashLbl             = New-Object System.Windows.Forms.Label
        $crashLbl.Text        = "Unhandled error during deployment!`r`n`r`n$($_.Exception.Message)`r`n`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`n`r`nPress F3 for log, F8 for cmd. Close this to reboot."
        $crashLbl.AutoSize    = $true
        $crashLbl.MaximumSize = New-Object System.Drawing.Size(564, 0)
        $crashForm.Tag.Controls.Add($crashLbl)

        $crashForm.ControlBox = $true
        # Pat - Set-FormSize before ShowDialog ----------------------
        Set-FormSize -Form $crashForm
        #------------------------------------------------------------
        [void]$crashForm.ShowDialog()
        $crashForm.Dispose()
    }
    catch {
        Write-Host ''
        Write-Host '  UNHANDLED ERROR and crash dialog failed.' -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Logs: $($script:LogFile)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press any key to reboot...' -ForegroundColor Gray
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    & wpeutil.exe reboot
    exit 1
}