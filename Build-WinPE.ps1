<#
.SYNOPSIS
    Builds a stripped-down, auto-running WinPE reset USB or ISO.

.DESCRIPTION
    Run from an elevated PowerShell prompt. Requires the Windows ADK
    Deployment Tools and WinPE add-on. Use -InstallPrerequisites to install
    missing components.

.PARAMETER OutputRoot
    Folder for build files, caches, logs, and the default ISO.
    Default: W:\AutoReset

.PARAMETER UsbDiskNumber
    USB disk number to erase and build. Check it with Get-Disk first.

.PARAMETER WorkDir
    Scratch workspace. Default: <LocalAppData>\AutoReset\Work.

.PARAMETER KeepWorkDir
    Keep the scratch workspace after a successful build.

.PARAMETER SkipPayload
    Build boot media only, without install.wim or drivers.

.PARAMETER InstallPrerequisites
    Install missing ADK and WinPE components from Microsoft.

.PARAMETER UpdateUsb
    Refresh an existing PE/PAYLOAD USB without repartitioning it.

.PARAMETER BuildIso
    Create a bootable BIOS and UEFI ISO.

.PARAMETER IsoPath
    Output path for -BuildIso. Defaults to <OutputRoot>\AutoReset.iso.

.PARAMETER NoCache
    Rebuild the cached WIM from scratch.

.EXAMPLE
    .\Build-WinPE.ps1 -UpdateUsb

.EXAMPLE
    .\Build-WinPE.ps1 -UsbDiskNumber 2

.EXAMPLE
    .\Build-WinPE.ps1 -PrepareImage -SourceImage D:\sources\install.esd

.EXAMPLE
    .\Build-WinPE.ps1 -PrepareDrivers

.EXAMPLE
    .\Build-WinPE.ps1 -ValidateUsb

.EXAMPLE
    .\Build-WinPE.ps1 -BuildIso
#>
[CmdletBinding(DefaultParameterSetName = 'USB')]
param(
    [Parameter(ParameterSetName = 'USB', Mandatory)]
    [int]$UsbDiskNumber,

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = 'W:\AutoReset',

    [string]$WorkDir,

    [switch]$KeepWorkDir,

    [ValidatePattern('^\d{3,4}x\d{3,4}$')]
    [string]$WinPEResolution = '1920x1200',

    [Alias('BootOnly')]
    [switch]$SkipPayload,

    [switch]$InstallPrerequisites,

    [Parameter(ParameterSetName = 'USB')]
    [switch]$AllowNonUsbDisk,

    [Parameter(ParameterSetName = 'USBUPDATE', Mandatory)]
    [switch]$UpdateUsb,

    [switch]$NoCache,

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
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
$mountRoot = [System.IO.Path]::Combine(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData), 'AutoReset', 'Mount')
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
    try { $stdErr = $errTask.Result } catch { }

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
    $rcArgs = @($Source, $Dest) + $Extra + @('/BYTES', '/ETA', '/NJH', '/NJS', '/MT:32', '/J')

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

    Write-BuildLog ("### [{0}] robocopy {1} -> {2} (exit {3})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Source, $Dest, $exit)
    Write-BuildLog $output

    if ($exit -ge 8) {
        $lines    = $output -split "[`r`n]+"
        $errLines = ($lines | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 6) -join "`n"
        if (-not $errLines) { $errLines = (($lines | Where-Object { $_.Trim() }) | Select-Object -Last 6) -join "`n" }
        throw ("$What failed (robocopy exit $exit)." + "`n$errLines" + "`nFull log: $($script:BuildLog)")
    }
    $global:LASTEXITCODE = 0
}

# ── 7-Zip discovery ─────────────────────────────────────────────────

function Find-SevenZip {
    $cmd = Get-Command '7z' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ── Driver archive change detection ─────────────────────────────────

function Get-DriverSourceHash {
    param([Parameter(Mandatory)][string]$SourcePath)
    $files = @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Name -notin @('Drivers.zip', 'Drivers.7z', 'Drivers.7z.hash', 'Drivers.zip.hash') } |
        Sort-Object FullName)
    if ($files.Count -eq 0) { return $null }

    $parts = [System.Text.StringBuilder]::new()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($SourcePath.Length).TrimStart('\')
        [void]$parts.AppendLine("$rel|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)")
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($parts.ToString())
    ) | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    return $hash
}

function Invoke-DriverArchive {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ArchiveDir,
        [string]$Label,
        [switch]$ForceRebuild
    )
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { return $null }

    $files = @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Drivers.zip', 'Drivers.7z', 'Drivers.7z.hash', 'Drivers.zip.hash') })
    if ($files.Count -eq 0) { return $null }

    if (-not $Label) { $Label = Split-Path -Leaf $SourcePath }

    $sevenZipPath = Find-SevenZip
    $use7z        = [bool]$sevenZipPath
    $archiveExt   = if ($use7z) { '7z' } else { 'zip' }
    $archivePath  = Join-Path $ArchiveDir "Drivers.$archiveExt"
    $hashPath     = "$archivePath.hash"

    $currentHash = Get-DriverSourceHash -SourcePath $SourcePath
    if (-not $currentHash) { return $null }

    if (-not $ForceRebuild -and (Test-Path -LiteralPath $archivePath) -and (Test-Path -LiteralPath $hashPath)) {
        $storedHash = (Get-Content -LiteralPath $hashPath -Raw -ErrorAction SilentlyContinue).Trim()
        if ($storedHash -eq $currentHash) {
            $sizeMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 0)
            Write-StepSkipped "Drivers ($Label): archive current ($sizeMB MB, no changes)"
            Write-BuildLog "Driver archive up to date: $archivePath (hash $currentHash)"
            return $archivePath
        }
    }

    $staleExt = if ($use7z) { 'zip' } else { '7z' }
    Remove-Item -LiteralPath (Join-Path $ArchiveDir "Drivers.$staleExt") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ArchiveDir "Drivers.$staleExt.hash") -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    $uncompressedMB = [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 0)
    $stagingArchive = Join-Path $WorkDir ('Drivers-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + ".$archiveExt")
    Remove-Item -LiteralPath $stagingArchive -Force -ErrorAction SilentlyContinue

    if ($use7z) {
        Start-Step "Compressing drivers ($Label): $($files.Count) files, $uncompressedMB MB (7z LZMA2)"
        Invoke-Tool -FilePath $sevenZipPath -What "7z archive ($Label)" -ArgumentList @(
            'a', '-t7z', '-m0=lzma2', '-mx=9', '-mfb=273', '-md=128m', '-ms=on',
            $stagingArchive, (Join-Path $SourcePath '*'))
    }
    else {
        Write-Aside '7-Zip not found. Using .NET ZIP (larger output). Install 7-Zip for better compression.'
        Start-Step "Compressing drivers ($Label): $($files.Count) files, $uncompressedMB MB (ZIP deflate)"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $SourcePath, $stagingArchive, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    }

    Move-Item -LiteralPath $stagingArchive -Destination $archivePath -Force
    Set-Content -LiteralPath $hashPath -Value $currentHash -Encoding UTF8

    $compressedMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 0)
    $ratio = if ($uncompressedMB -gt 0) { [math]::Round((1 - $compressedMB / $uncompressedMB) * 100, 0) } else { 0 }
    Write-StepDone "Compressed drivers ($Label): $uncompressedMB MB -> $compressedMB MB ($ratio% smaller)"
    Write-BuildLog "Driver archive built: $archivePath (hash $currentHash)"
    return $archivePath
}

# ── Cleanup helper ───────────────────────────────────────────────────

function Complete-WorkingFolder {
    if (-not $script:UseDefaultWorkDir -or $KeepWorkDir -or
        -not (Test-Path -LiteralPath $WorkDir)) { return }
    try { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop }
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
    Write-Host "  AutoReset Build  v$($script:Version)" -ForegroundColor Cyan
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
        Remove-Item -LiteralPath $DestinationImage -Force
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
    $driversRoot = Join-Path $ScriptRoot 'Payload\Drivers'

    if ($NoZip) {
        Write-Host "  Using raw drivers from: $driversRoot" -ForegroundColor Green
        return
    }

    if ($Device) {
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
    $hasFail = $false

    function Report([string]$Text) {
        $lines.Add($Text)
        $colour = if ($Text -like 'FAIL:*') { 'Red' }
                  elseif ($Text -like 'WARN:*') { 'Yellow' }
                  else { 'Green' }
        if ($Text -like 'FAIL:*') { $script:hasFail = $true }
        Write-Host "  $Text" -ForegroundColor $colour
    }

    $boot    = Get-Volume -FileSystemLabel 'PE'      -ErrorAction SilentlyContinue
    $payload = Get-Volume -FileSystemLabel 'PAYLOAD'  -ErrorAction SilentlyContinue

    if (-not $boot) { Report 'FAIL: PE boot volume not found.' }
    else {
        Report ("PASS: PE found ({0}:, {1:N0} MB free)" -f $boot.DriveLetter, ($boot.SizeRemaining / 1MB))
        $bootRoot = "$($boot.DriveLetter):\"
        foreach ($rel in @('sources\boot.wim', 'bootmgr', 'EFI\Boot\bootx64.efi')) {
            if (Test-Path (Join-Path $bootRoot $rel)) { Report "PASS: $rel" }
            else { Report "FAIL: missing $rel" }
        }
    }

    if (-not $SkipPayload) {
        if (-not $payload) { Report 'FAIL: PAYLOAD volume not found.' }
        else {
            Report ("PASS: PAYLOAD found ({0}:, {1:N1} GB free)" -f $payload.DriveLetter, ($payload.SizeRemaining / 1GB))
            $payloadRoot = "$($payload.DriveLetter):\Payload"
            foreach ($rel in @('UNE-Payload.tag', 'Config\reset.json', 'Images\install.wim')) {
                if (Test-Path (Join-Path $payloadRoot $rel)) { Report "PASS: Payload\$rel" }
                else { Report "FAIL: missing Payload\$rel" }
            }

            $hasDrivers = $false
            foreach ($archiveName in @('Drivers.7z', 'Drivers.zip')) {
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
            if (-not $hasDrivers) {
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
    if ($hasFail) { throw 'USB validation failed.' }
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

    if (-not (Test-Path (Join-Path $winpeRoot 'en-us\winpe.wim'))) { return $null }
    if (-not (Test-Path $bootsect)) { return $null }

    return [pscustomobject]@{
        AdkRoot   = $adkRoot
        WinpeRoot = $winpeRoot
        Bootsect  = $bootsect
        Oscdimg   = $oscdimg
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
            $dest = Join-Path $env:TEMP $inst.File
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
    $recycleBinPattern = '*$Recycle.Bin*'
    $staleMounts = @()
    try { $staleMounts = @(Get-WindowsImage -Mounted -ErrorAction Stop) } catch { }
    foreach ($m in $staleMounts) {
        $isOurs = ($m.Path -like "$WorkDir*") -or ($m.ImagePath -like "$WorkDir*") -or
                  ($m.Path -like "$mountRoot*") -or ($m.ImagePath -like "$mountRoot*") -or
                  ($m.ImagePath -like "$ScriptRoot*") -or
                  ($m.Path -like $recycleBinPattern) -or ($m.ImagePath -like $recycleBinPattern)
        if (-not $isOurs) { continue }

        Write-Aside "Discarding stale mount: $($m.Path)"
        & dism.exe /Unmount-Image "/MountDir:$($m.Path)" /Discard 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & dism.exe /Remount-Image "/MountDir:$($m.Path)" 2>&1 | Out-Null
            & dism.exe /Unmount-Image "/MountDir:$($m.Path)" /Discard 2>&1 | Out-Null
        }
    }
    & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null

    $remaining = @()
    try { $remaining = @(Get-WindowsImage -Mounted -ErrorAction Stop) } catch { }
    $blocking = @($remaining | Where-Object {
        ($_.Path -like "$WorkDir*") -or ($_.ImagePath -like "$WorkDir*") -or
        ($_.Path -like "$mountRoot*") -or ($_.ImagePath -like "$mountRoot*") -or
        ($_.ImagePath -like "$ScriptRoot*") -or
        ($_.Path -like $recycleBinPattern) -or ($_.ImagePath -like $recycleBinPattern)
    })

    if ($blocking.Count -eq 0) { return }

    Write-Aside 'Stale mount survived - removing WIMMount registration...'
    $regKey = 'HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images'
    if (Test-Path $regKey) {
        foreach ($sub in @(Get-ChildItem -Path $regKey -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            $mp    = [string]$props.'Mount Path'
            $wp    = [string]$props.'WIM Path'
            $stale = ($mp -like $recycleBinPattern) -or ($wp -like $recycleBinPattern) -or
                     ($mp -like "$WorkDir*") -or ($wp -like "$WorkDir*") -or
                     ($mp -like "$mountRoot*") -or ($wp -like "$mountRoot*") -or
                     ($wp -like "$ScriptRoot*") -or
                     (-not (Test-Path -LiteralPath $mp -ErrorAction SilentlyContinue)) -or
                     (-not (Test-Path -LiteralPath $wp -ErrorAction SilentlyContinue))
            if ($stale) {
                Write-Aside "Removing registration: $mp -> $wp"
                Remove-Item -Path $sub.PSPath -Recurse -Force
            }
        }
    }
    & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null

    $remaining2 = @()
    try { $remaining2 = @(Get-WindowsImage -Mounted -ErrorAction Stop) } catch { }
    $stillBlocking = @($remaining2 | Where-Object {
        ($_.Path -like "$WorkDir*") -or ($_.ImagePath -like "$WorkDir*") -or
        ($_.Path -like "$mountRoot*") -or ($_.ImagePath -like "$mountRoot*") -or
        ($_.ImagePath -like "$ScriptRoot*") -or
        ($_.Path -like $recycleBinPattern) -or ($_.ImagePath -like $recycleBinPattern)
    })
    if ($stillBlocking.Count -gt 0) {
        $detail = ($stillBlocking | ForEach-Object { "    Mount: $($_.Path)`n    Image: $($_.ImagePath)" }) -join "`n"
        throw ("DISM still has a stale WIM mount blocking this build:`n$detail`n" +
               "Try: empty the Recycle Bin, delete the old build folder, run " +
               "'reg delete `"HKLM\SOFTWARE\Microsoft\WIMMount\Mounted Images`" /f', " +
               "reboot, then 'dism /Cleanup-Mountpoints' and re-run.")
    }
    Write-Aside 'Stale mount registration cleared.'
}

# ── Dispatch prep/validate modes early ──────────────────────────────

if ($PSCmdlet.ParameterSetName -ne 'ValidateUsb') { Initialize-OutputRoot }

switch ($PSCmdlet.ParameterSetName) {
    'PrepareImage' {
        Show-Header 'Prepare Image'
        Invoke-ImagePreparation; Complete-WorkingFolder; return
    }
    'PrepareDrivers' {
        Show-Header 'Prepare Drivers'
        Invoke-DriverPreparation; Complete-WorkingFolder; return
    }
    'ValidateUsb' {
        Show-Header 'Validate USB'
        Invoke-UsbValidation; return
    }
}

# ── Preflight ────────────────────────────────────────────────────────

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
Write-StepDone 'Located Windows ADK'

if ($ScriptRoot -like '*OneDrive*') {
    Write-Aside "This folder is inside OneDrive. Work folder moved to $WorkDir to avoid sync issues."
    Write-Aside 'Consider moving the whole kit to a plain local folder like C:\AutoReset.'
}

$payloadSrc = Join-Path $ScriptRoot 'Payload'
if (-not (Test-Path (Join-Path $payloadSrc 'Scripts\Invoke-AutoReset.ps1'))) {
    throw "Payload\Scripts\Invoke-AutoReset.ps1 not found next to this script. Run from the repo root."
}

$externalInstallWim = Join-Path $preparedImagesRoot 'install.wim'
$localInstallWim    = Join-Path $payloadSrc 'Images\install.wim'
$installWim = if (Test-Path -LiteralPath $externalInstallWim) { $externalInstallWim } else { $localInstallWim }
if (-not $SkipPayload -and -not (Test-Path $installWim)) {
    Write-Aside "No install.wim found at $externalInstallWim"
    Write-Aside 'Media will boot but deployment will fail until you add one.'
}

# ── Step 2: Prepare work folder ─────────────────────────────────────

Start-Step 'Preparing work folder'
$mountDir = Join-Path $mountRoot 'boot-wim'
$mediaDir = Join-Path $WorkDir 'media'

Clear-StaleMounts

if (Test-Path $mountDir) {
    $deleted = $false
    for ($attempt = 1; $attempt -le 4 -and -not $deleted; $attempt++) {
        try { Remove-Item $mountDir -Recurse -Force; $deleted = $true }
        catch {
            if ($attempt -eq 2) {
                Write-Aside 'File handle blocking cleanup - restarting Windows Search...'
                try { Restart-Service WSearch -Force -ErrorAction Stop } catch { }
            }
            Start-Sleep -Seconds ($attempt * 3)
        }
    }
    if (-not $deleted) {
        throw ("Couldn't delete $mountDir - something has a file handle open inside it.`n" +
               "Try: Restart-Service WSearch -Force, or exclude $WorkDir from indexing/AV.")
    }
}
New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $mediaDir 'sources') -Force | Out-Null
$script:BuildLog = Join-Path $artifactRoot 'build.log'
Set-Content -Path $script:BuildLog -Value "AutoReset build - $(Get-Date)" -ErrorAction SilentlyContinue
Write-BuildLog "Version: $($script:Version)`nScriptRoot: $ScriptRoot`nWorkDir: $WorkDir`nNoCache: $NoCache`nSkipPayload: $SkipPayload"
Write-StepDone 'Prepared work folder'

# ── Step 3: Sync WinPE base media ───────────────────────────────────

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

# ── Step 5: Build or reuse cached WIM ───────────────────────────────

$bootWim = Join-Path $mediaDir 'sources\boot.wim'

$packages = @(
    'WinPE-WMI',
    'WinPE-NetFx',
    'WinPE-Scripting',
    'WinPE-PowerShell',
    'WinPE-StorageWMI',
    'WinPE-DismCmdlets'
)

$winpeDrivers       = Join-Path $ScriptRoot 'WinPEDrivers'
$injectWinpeDrivers = $PSCmdlet.ParameterSetName -ne 'ISO'
$srcWinpeWim        = Join-Path $winpeRoot 'en-us\winpe.wim'
$srcWimInfo         = Get-Item -LiteralPath $srcWinpeWim

$runtimeFiles = @(
    foreach ($runtimeSource in @((Join-Path $payloadSrc 'Scripts'), (Join-Path $payloadSrc 'Config'))) {
        if (Test-Path -LiteralPath $runtimeSource) {
            Get-ChildItem -LiteralPath $runtimeSource -Recurse -File -ErrorAction Stop
        }
    }
)

$cacheKeyParts = @(
    "src:$($srcWimInfo.Length)|$($srcWimInfo.LastWriteTimeUtc.Ticks)",
    "pkgs:$($packages -join ',')",
    "res:$WinPEResolution",
    "drv:$injectWinpeDrivers",
    "builder:$((Get-FileHash -LiteralPath $MyInvocation.MyCommand.Path -Algorithm SHA256).Hash)"
)
foreach ($rf in ($runtimeFiles | Sort-Object FullName)) {
    $rel = $rf.FullName.Substring($payloadSrc.Length).TrimStart('\')
    $cacheKeyParts += "$rel`:$($rf.Length)|$($rf.LastWriteTimeUtc.Ticks)"
}
if ($injectWinpeDrivers -and (Test-Path $winpeDrivers)) {
    Get-ChildItem -Path $winpeDrivers -Recurse -File | Sort-Object FullName | ForEach-Object {
        $cacheKeyParts += "wpd:$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
    }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$cacheHash = -join ($sha.ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($cacheKeyParts -join ';')
) | ForEach-Object { $_.ToString('x2') })
$sha.Dispose()
$cachedWim = Join-Path $cacheDir "winpe-$cacheHash.wim"

if (-not $NoCache -and (Test-Path -LiteralPath $cachedWim)) {
    Start-Step 'Restoring cached WIM'
    Copy-Item -LiteralPath $cachedWim -Destination $bootWim -Force
    Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false
    Write-StepDone 'Restored cached WIM (no servicing needed)'
}
else {
    Start-Step 'Building WinPE image'
    Copy-Item -Path $srcWinpeWim -Destination $bootWim -Force
    Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false

    Invoke-Tool -FilePath dism.exe -What 'Mount boot.wim' -ArgumentList @(
        '/Mount-Image', "/ImageFile:$bootWim", '/Index:1', "/MountDir:$mountDir")
    $mounted = $true
    try {
        $ocDir = Join-Path $winpeRoot 'WinPE_OCs'
        $packagePaths = @()
        foreach ($pkg in $packages) {
            $cab     = Join-Path $ocDir "$pkg.cab"
            $langCab = Join-Path $ocDir "en-us\${pkg}_en-us.cab"
            $packagePaths += $cab
            if (Test-Path $langCab) { $packagePaths += $langCab }
        }
        Write-StepDone 'Mounted WinPE image'

        for ($i = 0; $i -lt $packagePaths.Count; $i++) {
            $pkgPath = $packagePaths[$i]
            $pkgName = Split-Path -Path $pkgPath -Leaf
            Start-Step "Adding package $($i + 1)/$($packagePaths.Count): $pkgName"
            Invoke-Tool -FilePath dism.exe -What "Add $pkgName" -ArgumentList @(
                "/Image:$mountDir", '/Add-Package', "/PackagePath:$pkgPath")
            Write-StepDone "Added package $($i + 1)/$($packagePaths.Count): $pkgName"
        }

        $driverInf = if ($injectWinpeDrivers -and (Test-Path $winpeDrivers)) {
            Get-ChildItem $winpeDrivers -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($driverInf) {
            Start-Step 'Injecting WinPE boot drivers'
            $driverArgs = @("/Image:$mountDir", '/Add-Driver', "/Driver:$winpeDrivers", '/Recurse')
            try {
                Invoke-Tool -FilePath dism.exe -What 'Add WinPE drivers' -ArgumentList $driverArgs
            }
            catch {
                if ($_.Exception.Message -notmatch '(?i)0xc1420117|c1420117') { throw }
                Write-Aside 'DISM lost the mount handle - remounting and retrying...'
                & dism.exe /Remount-Image "/MountDir:$mountDir" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Couldn't remount boot.wim after driver failure."
                }
                Invoke-Tool -FilePath dism.exe -What 'Add WinPE drivers (retry)' -ArgumentList $driverArgs
            }
            Write-StepDone 'Injected WinPE boot drivers'
        }
        else {
            Write-StepSkipped 'WinPE boot drivers (none found)'
        }

        Start-Step 'Setting scratch space to 512 MB'
        Invoke-Tool -FilePath dism.exe -What 'Set scratch space' -ArgumentList @(
            "/Image:$mountDir", '/Set-ScratchSpace:512')
        Write-StepDone 'Set scratch space to 512 MB'

        $sevenZaSource = Join-Path $ScriptRoot 'Payload\Tools\7za.exe'
        if (Test-Path -LiteralPath $sevenZaSource) {
            Start-Step 'Bundling 7za.exe into WinPE'
            $wimTools = Join-Path $mountDir 'Payload\Tools'
            New-Item -ItemType Directory -Path $wimTools -Force | Out-Null
            Copy-Item -LiteralPath $sevenZaSource -Destination (Join-Path $wimTools '7za.exe') -Force
            Write-StepDone 'Bundled 7za.exe into WinPE'
        }
        else {
            Write-StepSkipped '7za.exe not in Payload\Tools (WinPE will only extract .zip drivers)'
        }

        $imgPayload = Join-Path $mountDir 'Payload'
        if (-not (Test-Path $imgPayload)) { New-Item -ItemType Directory -Path $imgPayload -Force | Out-Null }
        Copy-Item -Path (Join-Path $payloadSrc 'Scripts') -Destination $imgPayload -Recurse -Force
        Copy-Item -Path (Join-Path $payloadSrc 'Config')  -Destination $imgPayload -Recurse -Force

        $resParts = $WinPEResolution -split 'x'
        $peUnattend = @"
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
        Set-Content -Path (Join-Path $mountDir 'Windows\System32\winpe-unattend.xml') -Value $peUnattend -Encoding UTF8

        $winpeshl = @'
[LaunchApps]
%SYSTEMDRIVE%\Windows\System32\wpeinit.exe, -unattend:%SYSTEMDRIVE%\Windows\System32\winpe-unattend.xml
%SYSTEMDRIVE%\Windows\System32\WindowsPowerShell\v1.0\powershell.exe, -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File X:\Payload\Scripts\Invoke-AutoReset.ps1
'@
        Set-Content -Path (Join-Path $mountDir 'Windows\System32\winpeshl.ini') -Value $winpeshl -Encoding Ascii

        $startnet = @'
@echo off
wpeinit -unattend:X:\Windows\System32\winpe-unattend.xml
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Payload\Scripts\Invoke-AutoReset.ps1
'@
        Set-Content -Path (Join-Path $mountDir 'Windows\System32\startnet.cmd') -Value $startnet -Encoding Ascii

        Start-Step 'Committing WinPE image'
        Invoke-Tool -FilePath dism.exe -What 'Unmount + commit' -ArgumentList @(
            '/Unmount-Image', "/MountDir:$mountDir", '/Commit')
        $mounted = $false
        Write-StepDone 'Committed WinPE image'
    }
    finally {
        if ($mounted) {
            Write-StepFailed 'Build failed - discarding mount'
            & dism.exe /Unmount-Image "/MountDir:$mountDir" /Discard 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & dism.exe /Remount-Image "/MountDir:$mountDir" 2>&1 | Out-Null
                & dism.exe /Unmount-Image "/MountDir:$mountDir" /Discard 2>&1 | Out-Null
            }
        }
    }

    Copy-Item -LiteralPath $bootWim -Destination $cachedWim -Force
    Get-ChildItem -Path $cacheDir -Filter 'winpe-*.wim' |
        Where-Object { $_.Name -ne "winpe-$cacheHash.wim" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-BuildLog "Cached WIM: $cachedWim"
}

# ── Step 6: Sync payload ────────────────────────────────────────────

if (-not $SkipPayload) {
    Start-Step 'Syncing reset payload'
    $mediaPayload = Join-Path $mediaDir 'Payload'
    New-Item -ItemType Directory -Path $mediaPayload -Force | Out-Null
    Set-Content -Path (Join-Path $mediaPayload 'UNE-Payload.tag') -Value 'AutoReset deployment media' -Encoding Ascii

    Invoke-Robocopy -Source (Join-Path $payloadSrc 'Config') -Dest (Join-Path $mediaPayload 'Config') `
        -Extra @('/MIR') -What 'config sync'

    if (Test-Path $installWim) {
        $mediaImages = Join-Path $mediaPayload 'Images'
        New-Item -ItemType Directory -Path $mediaImages -Force | Out-Null
        $destWim = Join-Path $mediaImages 'install.wim'
        if (-not (Test-Path $destWim) -or
            (Get-Item $installWim).Length -ne (Get-Item $destWim -ErrorAction SilentlyContinue).Length) {
            Copy-Item -LiteralPath $installWim -Destination $destWim -Force
        }
    }

    Write-StepDone 'Synced reset payload'

    # Pat - Dynamic driver preparation during build --------------------
    #-----------------------------------------------------------------------
    $driversSrc = Join-Path $payloadSrc 'Drivers'
    if (Test-Path -LiteralPath $driversSrc) {
        $mediaDrivers = Join-Path $mediaPayload 'Drivers'

        $modelFolders = @(Get-ChildItem -LiteralPath $driversSrc -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name)

        if ($modelFolders.Count -eq 0) {
            $archive = Invoke-DriverArchive -SourcePath $driversSrc -ArchiveDir $preparedDriversRoot -Label 'all'
            if ($archive) {
                New-Item -ItemType Directory -Path $mediaDrivers -Force | Out-Null
                $destArchive = Join-Path $mediaDrivers (Split-Path -Leaf $archive)
                if (-not (Test-Path $destArchive) -or
                    (Get-Item $archive).Length -ne (Get-Item $destArchive -ErrorAction SilentlyContinue).Length) {
                    Copy-Item -LiteralPath $archive -Destination $destArchive -Force
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
                    $modelDest = Join-Path $mediaDrivers $modelName
                    New-Item -ItemType Directory -Path $modelDest -Force | Out-Null
                    $destArchive = Join-Path $modelDest (Split-Path -Leaf $archive)
                    if (-not (Test-Path $destArchive) -or
                        (Get-Item $archive).Length -ne (Get-Item $destArchive -ErrorAction SilentlyContinue).Length) {
                        Copy-Item -LiteralPath $archive -Destination $destArchive -Force
                    }
                }
            }
        }
    }
    else {
        Write-StepSkipped 'No Payload\Drivers folder found'
    }

    $sevenZaSrc = Join-Path $payloadSrc 'Tools\7za.exe'
    if (Test-Path -LiteralPath $sevenZaSrc) {
        $mediaTools = Join-Path $mediaPayload 'Tools'
        New-Item -ItemType Directory -Path $mediaTools -Force | Out-Null
        Copy-Item -LiteralPath $sevenZaSrc -Destination (Join-Path $mediaTools '7za.exe') -Force
    }
    # Pat - End dynamic driver preparation -----------------------------
    #-----------------------------------------------------------------------
}

# ── Step 7: Output (ISO / USB update / USB fresh) ───────────────────

if ($PSCmdlet.ParameterSetName -eq 'ISO') {
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
    Remove-Item -LiteralPath $IsoPath -Force -ErrorAction SilentlyContinue

    $bootData = "-bootdata:2#p0,e,b`"$biosBootImage`"#pEF,e,b`"$uefiBootImage`""
    Start-Step 'Creating bootable ISO'
    Invoke-Tool -FilePath $oscdimg -What 'oscdimg' -ArgumentList @(
        '-m', '-o', '-u2', '-udfver102', '-lAUTORESET', $bootData, $mediaDir, $IsoPath)
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "oscdimg completed but didn't create $IsoPath" }
    Write-StepDone 'Created bootable ISO'
    Write-Host ''
    Write-Host "  ISO ready: $IsoPath" -ForegroundColor Green
}
elseif ($PSCmdlet.ParameterSetName -eq 'USBUPDATE') {
    Start-Step 'Refreshing existing deployment stick'
    $bootVol    = Get-Volume -FileSystemLabel 'PE'      -ErrorAction SilentlyContinue
    $payloadVol = Get-Volume -FileSystemLabel 'PAYLOAD' -ErrorAction SilentlyContinue
    if (-not $bootVol -or -not $payloadVol) {
        Write-StepFailed "Couldn't find an AutoReset USB"
        throw "No AutoReset USB found (need volumes labelled PE and PAYLOAD). Build one first with -UsbDiskNumber."
    }
    $bootDrive    = "$($bootVol.DriveLetter):"
    $payloadDrive = "$($payloadVol.DriveLetter):"

    Invoke-Robocopy -Source $mediaDir -Dest $bootDrive -Extra @('/E', '/XD', 'Payload') -What 'boot file refresh'
    if (-not $SkipPayload) {
        Invoke-Robocopy -Source (Join-Path $mediaDir 'Payload') -Dest (Join-Path $payloadDrive 'Payload') `
            -Extra @('/MIR', '/XD', 'Logs') -What 'payload refresh'
    }
    Write-StepDone 'Refreshed existing deployment stick'
    Write-Host ''
    Write-Host '  Stick refreshed (Logs folder preserved).' -ForegroundColor Green
}
else {
    Start-Step 'Checking USB capacity'
    $disk = Get-Disk -Number $UsbDiskNumber
    if ($disk.BusType -ne 'USB' -and -not $AllowNonUsbDisk) {
        Write-StepFailed "Disk $UsbDiskNumber isn't USB"
        throw ("Disk $UsbDiskNumber is '$($disk.BusType)', not USB. " +
               "Re-run with -AllowNonUsbDisk if it's a USB stick passed through to Hyper-V.")
    }

    $bootPartitionSize = 700MB
    $bootFiles = @(Get-ChildItem -LiteralPath $mediaDir -Recurse -File |
        Where-Object { $_.FullName -notlike "$(Join-Path $mediaDir 'Payload')\*" })
    $bootBytes = ($bootFiles | Measure-Object -Property Length -Sum).Sum
    $bootRoom  = $bootPartitionSize - 64MB
    if ($bootBytes -gt $bootRoom) {
        Write-StepFailed 'Boot media too large for 700 MB PE partition'
        throw ("Boot media is {0:N1} MB but only {1:N1} MB fits." -f ($bootBytes / 1MB), ($bootRoom / 1MB))
    }

    $mediaSrcPayload = Join-Path $mediaDir 'Payload'
    if (-not $SkipPayload -and (Test-Path $mediaSrcPayload)) {
        $payloadBytes  = (Get-ChildItem -Path $mediaSrcPayload -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $payloadRoom   = $disk.Size - $bootPartitionSize - 128MB
        if ($payloadBytes -gt $payloadRoom) {
            Write-StepFailed 'USB stick too small for the payload'
            throw ("Payload is {0:N2} GB but only ~{1:N2} GB fits." -f ($payloadBytes / 1GB), ($payloadRoom / 1GB))
        }
    }
    Write-StepDone "Checked USB capacity: $($disk.FriendlyName) ($([math]::Round($disk.Size / 1GB, 1)) GB)"

    $sizeGB = [math]::Round($disk.Size / 1GB, 1)
    Write-Host ''
    Write-Host "  About to WIPE disk ${UsbDiskNumber}: $($disk.FriendlyName) ($sizeGB GB)" -ForegroundColor Yellow
    $answer = Read-Host '  Type YES to continue'
    if ($answer -cne 'YES') { throw 'Aborted.' }
    Write-Host ''

    Start-Step 'Wiping and partitioning USB'
    Clear-Disk -Number $UsbDiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    if ((Get-Disk -Number $UsbDiskNumber).PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $UsbDiskNumber -PartitionStyle MBR | Out-Null
    }
    elseif ((Get-Disk -Number $UsbDiskNumber).PartitionStyle -ne 'MBR') {
        Set-Disk -Number $UsbDiskNumber -PartitionStyle MBR
    }

    $bootPart    = New-Partition -DiskNumber $UsbDiskNumber -Size 700MB -IsActive -AssignDriveLetter
    Format-Volume -Partition $bootPart -FileSystem FAT32 -NewFileSystemLabel 'PE' -Confirm:$false | Out-Null
    $payloadPart = New-Partition -DiskNumber $UsbDiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $payloadPart -FileSystem NTFS -NewFileSystemLabel 'PAYLOAD' -Confirm:$false | Out-Null

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
    $bootDrive    = "${bootLetter}:"
    $payloadDrive = "${payloadLetter}:"
    Write-StepDone "Wiped and partitioned USB (PE=$bootLetter`:, PAYLOAD=$payloadLetter`:)"

    Start-Step "Copying boot files to $bootLetter`:"
    Invoke-Robocopy -Source $mediaDir -Dest $bootDrive -Extra @('/E', '/XD', 'Payload', '/R:2', '/W:2') -What 'boot file copy'
    Write-StepDone "Copied boot files to $bootLetter`:"

    if (-not $SkipPayload) {
        Start-Step "Copying payload to $payloadLetter`: (the slow bit)"
        Invoke-Robocopy -Source (Join-Path $mediaDir 'Payload') -Dest (Join-Path $payloadDrive 'Payload') `
            -Extra @('/E', '/R:2', '/W:2') -What 'payload copy'
        Write-StepDone "Copied payload to $payloadLetter`:"
    }

    if (Test-Path $bootsect) {
        Start-Step 'Writing legacy BIOS boot sector'
        & $bootsect /nt60 $bootDrive /mbr 2>&1 | Out-Null
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

Write-Host "  Build log: $script:BuildLog" -ForegroundColor DarkGray
Write-Host ''

Complete-WorkingFolder
$global:LASTEXITCODE = 0
