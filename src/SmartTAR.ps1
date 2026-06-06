# ============================================================================
# SmartTAR STAR v1.0
# Windows PowerShell GUI archiver using Windows tar.exe / bsdtar
#
# Stable 1.0 features:
#   - STAR outer TAR container.
#   - manifest.json with SHA-256 block metadata.
#   - Smart grouped block planning.
#   - RC5 group hardlink stage.
#   - RC6 chunk fallback when group-stage fails.
#   - XZ directory timestamp normalization.
#   - Responsive GUI using hidden worker process.
#   - Worker temp root with worker_config.json, status.txt, result.json, report.txt.
#   - VERIFY writes internal temp report first, then final report next to archive.
# ============================================================================

param(
    [string]$WorkerConfigFile = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================================
# 01. Console handling
# ============================================================================
if (-not ('SmartTarConsoleWindow' -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SmartTarConsoleWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
}

if ([string]::IsNullOrWhiteSpace($WorkerConfigFile)) {
    $consolePtr = [SmartTarConsoleWindow]::GetConsoleWindow()
    if ($consolePtr -ne [IntPtr]::Zero) {
        [SmartTarConsoleWindow]::ShowWindow($consolePtr, 0) | Out-Null
    }
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# ============================================================================
# 02. Generic helpers
# ============================================================================
function Test-Blank {
    param([string]$Text)
    return [string]::IsNullOrWhiteSpace($Text)
}

function New-Point {
    param([int]$X, [int]$Y)
    return [System.Drawing.Point]::new($X, $Y)
}

function New-Size {
    param([int]$Width, [int]$Height)
    return [System.Drawing.Size]::new($Width, $Height)
}

function Convert-ToTarPath {
    param([string]$Path)
    return ([string]$Path).Replace([char]92, [char]47)
}

function Convert-ToLocalPath {
    param([string]$Path)
    return ([string]$Path).Replace([char]47, [System.IO.Path]::DirectorySeparatorChar)
}

function New-UiObject {
    param([string]$Type, [hashtable]$Properties)
    $object = New-Object $Type
    foreach ($key in $Properties.Keys) {
        $object.$key = $Properties[$key]
    }
    return $object
}

function Trim-PathSeparators {
    param([string]$Text)
    if (Test-Blank $Text) { return '' }
    return $Text.TrimEnd([char]92, [char]47)
}

function Normalize-ArchiveSourcePath {
    param([string]$Path)
    if (Test-Blank $Path) { return '' }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)

    if ((Trim-PathSeparators $full) -ieq (Trim-PathSeparators $root)) {
        return $root
    }
    return (Trim-PathSeparators $full)
}

function Get-RelativePathFromBase {
    param([string]$BasePath, [string]$FullPath)

    $baseFull = Trim-PathSeparators ([System.IO.Path]::GetFullPath($BasePath))
    $pathFull = [System.IO.Path]::GetFullPath($FullPath)
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar

    if ($pathFull.ToLowerInvariant().StartsWith($prefix.ToLowerInvariant())) {
        return $pathFull.Substring($prefix.Length)
    }
    return (Split-Path -Leaf $pathFull)
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ("$Bytes B")
}

function Get-ErrorDetails {
    param($ErrorRecord)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Message:') | Out-Null
    $lines.Add([string]$ErrorRecord.Exception.Message) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('Exception type:') | Out-Null
    $lines.Add([string]$ErrorRecord.Exception.GetType().FullName) | Out-Null

    if ($ErrorRecord.InvocationInfo) {
        $lines.Add('') | Out-Null
        $lines.Add('Position:') | Out-Null
        $lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage) | Out-Null
    }

    if ($ErrorRecord.ScriptStackTrace) {
        $lines.Add('') | Out-Null
        $lines.Add('Script stack trace:') | Out-Null
        $lines.Add([string]$ErrorRecord.ScriptStackTrace) | Out-Null
    }

    return ($lines -join "`r`n")
}

function Get-FileSHA256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot hash missing file: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SourceSize {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [int64]$item.Length }

        $sum = [int64]0
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            $sum += [int64]$_.Length
        }
        return $sum
    }
    catch {
        return [int64]0
    }
}

function Get-ReportPath {
    param([string]$BasePath, [string]$Kind)

    $dir = [System.IO.Path]::GetDirectoryName($BasePath)
    if (Test-Blank $dir) { $dir = (Get-Location).Path }

    $name = [System.IO.Path]::GetFileName($BasePath)
    if (Test-Blank $name) { $name = 'SmartTAR' }

    return (Join-Path $dir ("$name.$Kind.$(Get-Date -Format yyyyMMdd_HHmmss).txt"))
}

function Write-ReportFile {
    param([string]$Path, [string]$Text)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Blank $dir) -and -not (Test-Path -LiteralPath $dir)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $Text | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-TextFileSafe {
    param([string]$Path)
    if (Test-Blank $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Wait-FileReady {
    param(
        [string]$Path,
        [int]$TimeoutMs = 15000,
        [int]$IntervalMs = 100
    )

    if (Test-Blank $Path) { return $false }

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $stream = $null
            try {
                $stream = [System.IO.File]::Open(
                    $Path,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::None
                )
                return $true
            }
            catch {
                Start-Sleep -Milliseconds $IntervalMs
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
        else {
            Start-Sleep -Milliseconds $IntervalMs
        }
    }
    return $false
}

# ============================================================================
# 03. Temp cleanup and safe work folder
# ============================================================================
function Remove-SmartTarTempFolder {
    param([string]$Path)

    if (Test-Blank $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
    catch {}

    for ($i = 1; $i -le 5; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            Start-Sleep -Milliseconds (200 * $i)
        }
    }

    try {
        cmd.exe /c "rmdir /s /q `"$Path`"" | Out-Null
    }
    catch {}
}

function Remove-EmptySmartTarTempRoot {
    param([string]$WorkPath)

    if (Test-Blank $WorkPath) { return }

    try {
        $root = Split-Path -Parent $WorkPath
        if (Test-Blank $root) { return }
        if (-not (Test-Path -LiteralPath $root)) { return }

        $children = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function Remove-SmartTarWorkAndRoot {
    param([string]$WorkPath)
    Remove-SmartTarTempFolder $WorkPath
    Remove-EmptySmartTarTempRoot $WorkPath
}

function New-SafeWorkRoot {
    param([string]$Purpose, [string]$PreferredPath)

    $guid = [guid]::NewGuid().ToString('N')
    $safePurpose = if (Test-Blank $Purpose) { 'work' } else { $Purpose }
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $preferredFull = [System.IO.Path]::GetFullPath($PreferredPath)
        $preferredDrive = [System.IO.Path]::GetPathRoot($preferredFull)

        if (-not (Test-Blank $preferredDrive)) {
            if ($preferredDrive -ieq 'C:\' -and -not (Test-Blank $env:PUBLIC)) {
                [void]$candidates.Add((Join-Path $env:PUBLIC 'SmartTAR_Temp'))
            }
            [void]$candidates.Add((Join-Path $preferredDrive 'SmartTAR_Temp'))
        }
    }
    catch {}

    if (-not (Test-Blank $env:PUBLIC)) { [void]$candidates.Add((Join-Path $env:PUBLIC 'SmartTAR_Temp')) }
    if (-not (Test-Blank $env:TEMP)) { [void]$candidates.Add((Join-Path $env:TEMP 'SmartTAR_Temp')) }

    foreach ($base in ($candidates | Select-Object -Unique)) {
        try {
            if (Test-Blank $base) { continue }

            [System.IO.Directory]::CreateDirectory($base) | Out-Null

            $testFile = Join-Path $base ('write_test_' + [guid]::NewGuid().ToString('N') + '.tmp')
            'test' | Set-Content -LiteralPath $testFile -Encoding ASCII -ErrorAction Stop
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue

            $work = Join-Path $base ('smarttar_{0}_{1}' -f $safePurpose, $guid)
            [System.IO.Directory]::CreateDirectory($work) | Out-Null
            return $work
        }
        catch {
            continue
        }
    }

    throw 'Unable to create a writable SmartTAR work folder.'
}

# ============================================================================
# 04. UI state and status bridge
# ============================================================================
$cBg = [System.Drawing.Color]::White
$cText = [System.Drawing.ColorTranslator]::FromHtml('#2F4F4F')
$cGray = [System.Drawing.Color]::LightGray
$cButtonText = [System.Drawing.Color]::White

$fNormal = [System.Drawing.Font]::new('Segoe UI', 9)
$fBold = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fItalic = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)

$script:StableXzStageTime = [datetime]'2000-01-01T00:00:00'
$script:selectedPath = ''
$script:selectedType = ''
$script:lastSalvageSkippedBlocks = @()
$script:lastGroupDiagnostics = @()
$script:isBusy = $false
$script:workerConfig = $null
$script:currentProcess = $null
$script:currentWorkerRoot = ''
$script:currentConfigFile = ''
$script:currentStatusFile = ''
$script:currentResultFile = ''
$script:currentInternalReportFile = ''
$script:currentFinalReportFile = ''
$script:currentAction = ''
$script:openFolderAfter = $true
$script:currentStdOut = ''
$script:currentStdErr = ''

$scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}

$tarPath = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tarPath)) {
    $tarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tarCommand -and $tarCommand.Source) { $tarPath = $tarCommand.Source }
}

function Write-WorkerStatusFile {
    param([string]$Path, [string]$Text)
    if (-not (Test-Blank $Path)) {
        try { $Text | Set-Content -LiteralPath $Path -Encoding UTF8 } catch {}
    }
}

function Set-AppStatus {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::DimGray)

    if ($script:workerConfig -and -not (Test-Blank ([string]$script:workerConfig.StatusFile))) {
        Write-WorkerStatusFile ([string]$script:workerConfig.StatusFile) $Text
        return
    }

    if ($null -ne $lblStatus) {
        $lblStatus.Text = $Text
        $lblStatus.ForeColor = $Color
        try { $lblStatus.Refresh() } catch {}
    }
}

function Clear-UiFocus {
    try {
        if ($null -ne $txtTarget) {
            $txtTarget.SelectionStart = 0
            $txtTarget.SelectionLength = 0
        }
        if ($null -ne $form) {
            $form.ActiveControl = $null
        }
    }
    catch {}
}

function Start-UiWork {
    $progressBar.Visible = $true
    $progressBar.MarqueeAnimationSpeed = 25
}

function Stop-UiWork {
    $progressBar.MarqueeAnimationSpeed = 0
    $progressBar.Visible = $false
}

function Enable-ControlDoubleBuffering {
    param([System.Windows.Forms.Control]$Control)

    try {
        $prop = [System.Windows.Forms.Control].GetProperty(
            'DoubleBuffered',
            [System.Reflection.BindingFlags]'NonPublic,Instance'
        )
        if ($prop) { $prop.SetValue($Control, $true, $null) }
    }
    catch {}
}

function Set-OperationButtonsVisualState {
    foreach ($button in @($btnCompress, $btnExtract, $btnVerify)) {
        if ($button) {
            $button.Enabled = $true
            $button.ForeColor = $cButtonText
            $button.UseVisualStyleBackColor = $false
            try { $button.Refresh() } catch {}
        }
    }
}

function Set-UiBusy {
    param([bool]$Busy)

    $script:isBusy = $Busy
    $enabled = -not $Busy

    foreach ($control in @($btnFile, $btnFolder, $btnArchive, $btnTarget, $cmbMode, $chkOpenFolder, $chkSalvageMode)) {
        if ($control) { $control.Enabled = $enabled }
    }

    Set-OperationButtonsVisualState
    if ($Busy) { Start-UiWork } else { Stop-UiWork }
    Clear-UiFocus
}

# ============================================================================
# 05. TAR engine and methods
# ============================================================================
function Get-TarMethods {
    return @(
        @{ Name='store';  Display='STORE';  Extension='.tar';     CreateArgs=@('-cf'); Level=$null; Algorithm='store' },
        @{ Name='gzip';   Display='GZIP';   Extension='.tar.gz';  CreateArgs=@('-czf'); Level=$null; Algorithm='gzip' },
        @{ Name='bzip2';  Display='BZIP2';  Extension='.tar.bz2'; CreateArgs=@('-cjf'); Level=$null; Algorithm='bzip2' },
        @{ Name='xz9';    Display='XZ9';    Extension='.tar.xz';  CreateArgs=@('--options','xz:compression-level=9','-cJf'); Level=9; Algorithm='xz' },
        @{ Name='xz';     Display='XZ';     Extension='.tar.xz';  CreateArgs=@('-cJf'); Level=$null; Algorithm='xz' },
        @{ Name='zstd19'; Display='ZSTD19'; Extension='.tar.zst'; CreateArgs=@('--zstd','--options','zstd:compression-level=19','-cf'); Level=19; Algorithm='zstd' }
    )
}

function Get-TarMethodByName {
    param([string]$Name)
    foreach ($method in Get-TarMethods) {
        if ([string]$method.Name -eq $Name) { return $method }
    }
    return $null
}

function Invoke-TarRaw {
    param([string]$TarPath, $TarArgs)

    $arguments = @()
    foreach ($arg in @($TarArgs)) { $arguments += [string]$arg }

    $output = & $TarPath @arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
}

function Invoke-Tar {
    param([string]$TarPath, $TarArgs, [string]$FailMessage)

    $result = Invoke-TarRaw $TarPath $TarArgs
    if ([int]$result.ExitCode -ne 0) {
        $text = [string]$result.Output
        if (Test-Blank $text) { $text = 'No tar.exe output captured.' }
        throw "$FailMessage tar.exe exit code: $($result.ExitCode)`r`n$text"
    }
}

function Invoke-TarList {
    param([string]$TarPath, [string]$ArchivePath)
    $result = Invoke-TarRaw $TarPath @('-tf', $ArchivePath)
    return ([int]$result.ExitCode -eq 0)
}

function Test-TarCapabilities {
    param([string]$TarPath, [string]$SafeWork)

    $root = Join-Path $SafeWork ('cap_' + [guid]::NewGuid().ToString('N'))
    $sample = Join-Path $root 'sample'
    $extract = Join-Path $root 'extract'

    [System.IO.Directory]::CreateDirectory($sample) | Out-Null
    [System.IO.Directory]::CreateDirectory($extract) | Out-Null
    'test' | Set-Content -LiteralPath (Join-Path $sample 'sample.txt') -Encoding UTF8

    $capabilities = @{}

    foreach ($method in Get-TarMethods) {
        $name = [string]$method.Name
        $archive = Join-Path $root ('test' + $method.Extension)
        $extractDir = Join-Path $extract $name
        [System.IO.Directory]::CreateDirectory($extractDir) | Out-Null

        $args = @()
        $args += $method.CreateArgs
        $args += $archive
        $args += '-C'
        $args += $sample
        $args += 'sample.txt'

        $create = Invoke-TarRaw $TarPath $args
        $ok = $false

        if ([int]$create.ExitCode -eq 0 -and (Test-Path -LiteralPath $archive)) {
            $extractResult = Invoke-TarRaw $TarPath @('-xf', $archive, '-C', $extractDir)
            if ([int]$extractResult.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $extractDir 'sample.txt'))) {
                $ok = $true
            }
        }

        $capabilities[$name] = $ok
    }

    Remove-SmartTarTempFolder $root
    return $capabilities
}

function Select-BestCompressedMethod {
    param([hashtable]$Capabilities)
    foreach ($name in @('xz9','xz','bzip2','gzip','store')) {
        if ($Capabilities.ContainsKey($name) -and $Capabilities[$name]) {
            return Get-TarMethodByName $name
        }
    }
    throw 'No usable tar method found.'
}

function Select-XzOrBest {
    param([hashtable]$Capabilities)
    if ($Capabilities.ContainsKey('xz9') -and $Capabilities['xz9']) { return Get-TarMethodByName 'xz9' }
    if ($Capabilities.ContainsKey('xz') -and $Capabilities['xz']) { return Get-TarMethodByName 'xz' }
    return Select-BestCompressedMethod $Capabilities
}

function Select-ZstdOrBest {
    param([hashtable]$Capabilities)
    if ($Capabilities.ContainsKey('zstd19') -and $Capabilities['zstd19']) { return Get-TarMethodByName 'zstd19' }
    return Select-BestCompressedMethod $Capabilities
}

function Select-StoreMethod {
    param([hashtable]$Capabilities)
    if ($Capabilities.ContainsKey('store') -and $Capabilities['store']) { return Get-TarMethodByName 'store' }
    return Select-BestCompressedMethod $Capabilities
}

# ============================================================================
# 06. Classification and grouping
# ============================================================================
function Get-SmartGroupName {
    param([string]$FilePath)

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    $textExt = @('.txt','.csv','.json','.xml','.log','.ini','.cfg','.md','.sql','.ps1','.bat','.cmd','.html','.htm','.css','.js','.ts','.yml','.yaml','.toml','.reg','.inf','.srt','.vtt','.py')
    $binaryExt = @('.bin','.dat','.db','.sqlite','.sqlite3','.pak','.asset','.res','.idx','.map','.cache','.blob')
    $exeExt = @('.exe','.dll','.sys','.ocx','.msi','.msp','.scr','.com','.drv','.efi')
    $diskExt = @('.iso','.img','.vhd','.vhdx')
    $mediaExt = @('.jpg','.jpeg','.png','.gif','.webp','.bmp','.tif','.tiff','.ico','.mp3','.wav','.flac','.aac','.ogg','.wma','.mp4','.mkv','.avi','.mov','.wmv','.webm','.pdf','.heic','.avif')
    $archiveExt = @('.zip','.7z','.rar','.gz','.bz2','.xz','.zst','.tar','.tgz','.tbz2','.txz','.cab','.jar','.war','.ear','.sarc','.star','.docx','.xlsx','.pptx','.odt','.ods','.odp','.apk','.epub','.vsix','.nupkg')

    if ($textExt -contains $extension) { return 'text' }
    if ($diskExt -contains $extension) { return 'diskimage' }
    if ($binaryExt -contains $extension) { return 'binary' }
    if ($exeExt -contains $extension) { return 'executable' }
    if ($mediaExt -contains $extension) { return 'media' }
    if ($archiveExt -contains $extension) { return 'archives' }
    return 'unknown'
}

function Get-ModeGroupName {
    param([string]$Mode, [string]$SmartGroup)

    if ($Mode -eq 'Solid') { return 'solid' }
    if ($Mode -eq 'Store') { return 'store' }
    if ($Mode -eq 'SmartXZ') { return $SmartGroup }

    if ($Mode -eq 'Hybrid') {
        if ($SmartGroup -eq 'diskimage') { return 'diskimage' }
        if ($SmartGroup -eq 'media' -or $SmartGroup -eq 'archives') { return 'stored' }
        return 'compressible'
    }

    return $SmartGroup
}

function Get-SortedSourceFiles {
    param($SourceItem, [string]$Source, [string]$BaseRoot)

    if (-not $SourceItem.PSIsContainer) { return @($SourceItem) }

    return @(
        Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object `
                @{ Expression = { (Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant() } },
                @{ Expression = { Get-RelativePathFromBase $BaseRoot $_.FullName } }
    )
}

function Get-SourceProfile {
    param($SourceItem, [string]$Source, [string]$BaseRoot)

    $profile = @{
        text       = [int64]0
        binary     = [int64]0
        executable = [int64]0
        diskimage  = [int64]0
        media      = [int64]0
        archives   = [int64]0
        unknown    = [int64]0
        files      = 0
    }

    foreach ($file in (Get-SortedSourceFiles $SourceItem $Source $BaseRoot)) {
        $group = Get-SmartGroupName $file.FullName
        $profile[$group] = [int64]$profile[$group] + [int64]$file.Length
        $profile.files++
    }

    return $profile
}

function Select-AutoSolidMethod {
    param([hashtable]$Capabilities, [hashtable]$Profile)

    $zstd = Select-ZstdOrBest $Capabilities
    $xz = Select-XzOrBest $Capabilities

    if ($Capabilities.ContainsKey('zstd19') -and $Capabilities['zstd19']) {
        $binaryLike = [int64]$Profile.binary + [int64]$Profile.executable + [int64]$Profile.diskimage
        if ($binaryLike -gt [int64]$Profile.text) { return $zstd }
    }

    return $xz
}

function New-GroupInfo {
    param([string]$Name, [hashtable]$Method, [string]$Reason)

    return @{
        Name      = $Name
        Method    = $Method
        Reason    = $Reason
        FileCount = 0
        DirCount  = 0
        Bytes     = [int64]0
        Files     = New-Object System.Collections.ArrayList
    }
}

function New-ArchiveGroups {
    param([string]$Mode, [hashtable]$Capabilities, [hashtable]$Profile)

    $store = Select-StoreMethod $Capabilities
    $xz = Select-XzOrBest $Capabilities
    $zstd = Select-ZstdOrBest $Capabilities
    $groups = [ordered]@{}

    switch ($Mode) {
        'Store' {
            $groups.store = New-GroupInfo store $store 'Store mode.'
        }
        'Solid' {
            $groups.solid = New-GroupInfo solid (Select-AutoSolidMethod $Capabilities $Profile) 'Auto solid method.'
        }
        'SmartXZ' {
            foreach ($name in @('text','binary','executable','diskimage','media','archives','unknown')) {
                $method = if ($name -eq 'media' -or $name -eq 'archives') { $store } else { $xz }
                $groups[$name] = New-GroupInfo $name $method 'Smart XZ plan.'
            }
        }
        'Smart' {
            $groups.text       = New-GroupInfo text       $xz    'Text-like data prefers XZ9.'
            $groups.binary     = New-GroupInfo binary     $zstd  'Binary data prefers ZSTD19.'
            $groups.executable = New-GroupInfo executable $zstd  'Executable data prefers ZSTD19.'
            $groups.diskimage  = New-GroupInfo diskimage  $zstd  'Disk images prefer ZSTD19.'
            $groups.media      = New-GroupInfo media      $store 'Media is stored.'
            $groups.archives   = New-GroupInfo archives   $store 'Archives are stored.'
            $groups.unknown    = New-GroupInfo unknown    $xz    'Unknown data prefers XZ9.'
        }
        default {
            $groups.compressible = New-GroupInfo compressible $xz    'General compressible data prefers XZ9.'
            $groups.diskimage    = New-GroupInfo diskimage    $zstd  'Disk images prefer ZSTD19.'
            $groups.stored       = New-GroupInfo stored       $store 'Media and archive-like data is stored.'
        }
    }

    return $groups
}

# ============================================================================
# 07. Staging and block creation
# ============================================================================
function Add-FileToGroup {
    param([hashtable]$Group, [string]$SourcePath, [string]$RelativePath, [int64]$Bytes)

    $fileInfo = [pscustomobject]@{
        Path  = $SourcePath
        Rel   = (Convert-ToTarPath $RelativePath)
        Bytes = [int64]$Bytes
    }

    [void]$Group.Files.Add($fileInfo)
    $Group.FileCount = [int]$Group.FileCount + 1
    $Group.Bytes = [int64]$Group.Bytes + [int64]$Bytes
}

function Stage-FilesPlan {
    param($SourceItem, [string]$Source, [string]$BaseRoot, [string]$Mode, [hashtable]$Groups)

    Set-AppStatus "Planning grouped file blocks for $Mode mode..." ([System.Drawing.Color]::DarkOrange)

    foreach ($file in (Get-SortedSourceFiles $SourceItem $Source $BaseRoot)) {
        $smartGroup = Get-SmartGroupName $file.FullName
        $groupName = Get-ModeGroupName $Mode $smartGroup

        if (-not $Groups.Contains($groupName)) {
            throw "Internal grouping error. Group '$groupName' does not exist for mode '$Mode'."
        }

        $relativePath = Get-RelativePathFromBase $BaseRoot $file.FullName
        Add-FileToGroup $Groups[$groupName] $file.FullName $relativePath ([int64]$file.Length)
    }
}

function Create-StructureStage {
    param($SourceItem, [string]$Source, [string]$BaseRoot, [string]$StageRoot)

    $count = 0
    if (-not $SourceItem.PSIsContainer) { return $count }

    $rootRelative = Get-RelativePathFromBase $BaseRoot $Source
    [System.IO.Directory]::CreateDirectory((Join-Path $StageRoot (Convert-ToLocalPath $rootRelative))) | Out-Null
    $count++

    $directories = @(
        Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object @{ Expression = { (Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant() } }
    )

    foreach ($directory in $directories) {
        $relativePath = Get-RelativePathFromBase $BaseRoot $directory.FullName
        [System.IO.Directory]::CreateDirectory((Join-Path $StageRoot (Convert-ToLocalPath $relativePath))) | Out-Null
        $count++
    }

    return $count
}

function Split-FileChunks {
    param($Files, [int]$MaxEntries = 96, [int]$MaxChars = 22000)

    $chunks = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.ArrayList
    $chars = 0

    foreach ($file in @($Files)) {
        if ($null -eq $file) { continue }

        $relativePath = [string]$file.Rel
        $additionalChars = $relativePath.Length + 3

        if ($current.Count -gt 0 -and (($current.Count -ge $MaxEntries) -or (($chars + $additionalChars) -gt $MaxChars))) {
            [void]$chunks.Add([pscustomobject]@{
                Files = [object[]]$current.ToArray()
                Count = [int]$current.Count
            })
            $current.Clear()
            $chars = 0
        }

        [void]$current.Add($file)
        $chars += $additionalChars
    }

    if ($current.Count -gt 0) {
        [void]$chunks.Add([pscustomobject]@{
            Files = [object[]]$current.ToArray()
            Count = [int]$current.Count
        })
    }

    return ,$chunks
}

function New-HardLinkLiteral {
    param([string]$LinkPath, [string]$TargetPath)

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        throw "Hardlink target does not exist: $TargetPath"
    }

    $linkDir = Split-Path -Parent $LinkPath
    if (-not (Test-Blank $linkDir)) {
        [System.IO.Directory]::CreateDirectory($linkDir) | Out-Null
    }

    if (Test-Path -LiteralPath $LinkPath) {
        Remove-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    }

    $newItemError = $null

    try {
        # New-Item has no -LiteralPath for hardlinks, so wildcard characters are escaped.
        $escapedLink = [System.Management.Automation.WildcardPattern]::Escape($LinkPath)
        $escapedTarget = [System.Management.Automation.WildcardPattern]::Escape($TargetPath)
        New-Item -ItemType HardLink -Path $escapedLink -Target $escapedTarget -ErrorAction Stop | Out-Null
        return
    }
    catch {
        $newItemError = [string]$_.Exception.Message
    }

    # cmd.exe mklink fallback does not treat [ ] as PowerShell wildcard characters.
    $cmdOutput = & cmd.exe /c "mklink /H `"$LinkPath`" `"$TargetPath`"" 2>&1
    $cmdText = ($cmdOutput | Out-String).Trim()

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $LinkPath)) {
        throw "Hardlink creation failed. Target: '$TargetPath'. Link: '$LinkPath'. New-Item error: $newItemError. mklink output: $cmdText"
    }
}

function New-HardlinkStageInternal {
    param([string]$WorkRoot, $Files, [bool]$AllowCopyFallback, [string]$Prefix)

    $stageRoot = Join-Path $WorkRoot ('{0}_{1}' -f $Prefix, [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($stageRoot) | Out-Null

    foreach ($file in @($Files)) {
        if ($null -eq $file) { continue }

        $relTar = Convert-ToTarPath ([string]$file.Rel)
        if (Test-Blank $relTar) { throw 'Empty relative path in stage.' }
        if ($relTar.StartsWith('/') -or $relTar -match '^[a-zA-Z]:') {
            throw "Relative path expected, got: $relTar"
        }

        $linkPath = Join-Path $stageRoot (Convert-ToLocalPath $relTar)
        $targetPath = [string]$file.Path

        try {
            New-HardLinkLiteral $linkPath $targetPath
        }
        catch {
            if ($AllowCopyFallback) {
                $linkDir = Split-Path -Parent $linkPath
                if (-not (Test-Blank $linkDir)) { [System.IO.Directory]::CreateDirectory($linkDir) | Out-Null }
                Copy-Item -LiteralPath $targetPath -Destination $linkPath -Force -ErrorAction Stop
            }
            else {
                throw "Hardlink stage failed for '$targetPath'. Original error: $($_.Exception.Message)"
            }
        }
    }

    return $stageRoot
}

function New-GroupHardlinkStage {
    param([string]$WorkRoot, $GroupFiles)
    return New-HardlinkStageInternal $WorkRoot $GroupFiles $false 'groupstage'
}

function New-ChunkHardlinkStage {
    param([string]$WorkRoot, $ChunkFiles)
    return New-HardlinkStageInternal $WorkRoot $ChunkFiles $true 'argstage'
}

function Set-XzStageDirectoryTimes {
    param([string]$StageRoot, [datetime]$Time = $script:StableXzStageTime)

    if (Test-Blank $StageRoot) { return }
    if (-not (Test-Path -LiteralPath $StageRoot)) { return }

    $directories = @(
        Get-ChildItem -LiteralPath $StageRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object @{ Expression = { $_.FullName.Length }; Descending = $true }
    )

    foreach ($directory in $directories) {
        try {
            $directory.CreationTime = $Time
            $directory.LastWriteTime = $Time
            $directory.LastAccessTime = $Time
        }
        catch {}
    }

    try {
        $root = Get-Item -LiteralPath $StageRoot -Force
        $root.CreationTime = $Time
        $root.LastWriteTime = $Time
        $root.LastAccessTime = $Time
    }
    catch {}
}

function Normalize-XzStageIfNeeded {
    param([string]$StageRoot, [hashtable]$Method)

    if ($Method -and ([string]$Method.Algorithm -eq 'xz')) {
        Set-XzStageDirectoryTimes $StageRoot
        return $true
    }
    return $false
}

function Create-BlockFromStageDirect {
    param([string]$TarPath, [string]$StagePath, [string]$BlockPath, [hashtable]$Method)

    [void](Normalize-XzStageIfNeeded $StagePath $Method)

    $args = @()
    $args += $Method.CreateArgs
    $args += $BlockPath
    $args += '-C'
    $args += $StagePath
    $args += '.'

    Invoke-Tar $TarPath $args "Block creation failed: $BlockPath."
}

function Create-BlockFromStageList {
    param([string]$TarPath, [string]$StagePath, [string]$BlockPath, [hashtable]$Method, $RelativePaths)

    [void](Normalize-XzStageIfNeeded $StagePath $Method)

    $args = @()
    $args += $Method.CreateArgs
    $args += $BlockPath
    $args += '-C'
    $args += $StagePath

    foreach ($rel in @($RelativePaths)) {
        $safeRel = Convert-ToTarPath ([string]$rel)
        if ($safeRel.StartsWith('-')) { $safeRel = "./$safeRel" }
        $args += $safeRel
    }

    Invoke-Tar $TarPath $args "Block creation failed: $BlockPath."
}

function Add-BlockManifestItem {
    param(
        [ref]$List,
        [string]$BlockId,
        [string]$GroupName,
        [string]$BlockPath,
        [hashtable]$Method,
        [string]$Reason,
        [int]$FileCount,
        [int]$DirCount,
        [int64]$SourceBytes
    )

    $item = Get-Item -LiteralPath $BlockPath
    $name = [System.IO.Path]::GetFileName($BlockPath)

    $List.Value += [ordered]@{
        id          = $BlockId
        group       = $GroupName
        path        = "blocks/$name"
        container   = 'tar'
        compression = [string]$Method.Algorithm
        method      = [string]$Method.Name
        display     = [string]$Method.Display
        level       = $Method.Level
        extension   = [string]$Method.Extension
        tarArgs     = ($Method.CreateArgs -join ' ')
        reason      = $Reason
        fileCount   = $FileCount
        dirCount    = $DirCount
        sourceBytes = $SourceBytes
        sizeBytes   = [int64]$item.Length
        sha256      = Get-FileSHA256 $BlockPath
    }
}

function Add-GroupDiagnostic {
    param([string]$Group, [string]$Status, [string]$Message, [int]$FileCount, [int64]$Bytes)

    $script:lastGroupDiagnostics += [ordered]@{
        group       = $Group
        status      = $Status
        fileCount   = $FileCount
        sourceBytes = $Bytes
        message     = $Message
    }
}

function Build-Blocks {
    param(
        [string]$TarPath,
        [hashtable]$Groups,
        [string]$BlocksDir,
        [string]$WorkRoot,
        [string]$StructureStage,
        [int]$StructureDirCount,
        [hashtable]$StoreMethod
    )

    $script:lastGroupDiagnostics = @()
    $blocks = @()
    $index = 1

    if ($StructureDirCount -gt 0) {
        $id = '{0:D6}' -f $index
        $blockPath = Join-Path $BlocksDir ("$id`_structure.tar")

        Set-AppStatus "Creating block $id structure..." ([System.Drawing.Color]::DarkOrange)
        Create-BlockFromStageDirect $TarPath $StructureStage $blockPath $StoreMethod
        Add-BlockManifestItem ([ref]$blocks) $id 'structure' $blockPath $StoreMethod 'Directory structure only.' 0 $StructureDirCount 0
        $index++
    }

    foreach ($groupName in $Groups.Keys) {
        $group = $Groups[$groupName]
        if ([int]$group.FileCount -le 0) { continue }

        $id = '{0:D6}' -f $index
        $safeGroup = [string]$group.Name
        $blockPath = Join-Path $BlocksDir ("$id`_$safeGroup$($group.Method.Extension)")
        $stageRoot = $null
        $ok = $false
        $err = $null

        try {
            Set-AppStatus "Creating group hardlink stage for block $id $safeGroup..." ([System.Drawing.Color]::DarkOrange)
            $stageRoot = New-GroupHardlinkStage $WorkRoot @($group.Files)

            if ([string]$group.Method.Algorithm -eq 'xz') {
                Set-AppStatus "Normalizing XZ stage directory timestamps for block $id $safeGroup..." ([System.Drawing.Color]::DarkOrange)
            }

            Set-AppStatus "Creating group block $id $safeGroup..." ([System.Drawing.Color]::DarkOrange)
            Create-BlockFromStageDirect $TarPath $stageRoot $blockPath $group.Method
            $ok = $true
        }
        catch {
            $err = [string]$_.Exception.Message
            $ok = $false
        }
        finally {
            Remove-SmartTarTempFolder $stageRoot
        }

        if ($ok -and (Test-Path -LiteralPath $blockPath)) {
            $diagMessage = 'Created as one RC5 group-stage block.'
            if ([string]$group.Method.Algorithm -eq 'xz') {
                $diagMessage += ' XZ directory timestamps normalized.'
            }

            Add-GroupDiagnostic $safeGroup 'group-stage-ok' $diagMessage ([int]$group.FileCount) ([int64]$group.Bytes)
            Add-BlockManifestItem ([ref]$blocks) $id $safeGroup $blockPath $group.Method ([string]$group.Reason + ' RC5 group-stage block.') ([int]$group.FileCount) 0 ([int64]$group.Bytes)
            $index++
            continue
        }

        Add-GroupDiagnostic $safeGroup 'fallback-rc6-chunked' ('Group-stage failed. ' + $err) ([int]$group.FileCount) ([int64]$group.Bytes)
        Set-AppStatus "Group stage failed for $safeGroup. Falling back to RC6 chunked blocks..." ([System.Drawing.Color]::DarkOrange)

        $chunks = Split-FileChunks -Files $group.Files
        $part = 1

        foreach ($chunkInfo in $chunks) {
            $chunkFiles = @($chunkInfo.Files)
            if ($chunkFiles.Count -lt 1) { continue }

            $id = '{0:D6}' -f $index
            $suffix = if ($chunks.Count -gt 1) { '_p{0:D3}' -f $part } else { '' }
            $fallbackGroup = ([string]$group.Name) + $suffix
            $blockPath = Join-Path $BlocksDir ("$id`_$fallbackGroup$($group.Method.Extension)")
            $chunkStage = $null

            try {
                Set-AppStatus "Creating fallback chunk stage for block $id..." ([System.Drawing.Color]::DarkOrange)
                $chunkStage = New-ChunkHardlinkStage $WorkRoot $chunkFiles
                $relativePaths = @($chunkFiles | ForEach-Object { [string]$_.Rel })

                if ([string]$group.Method.Algorithm -eq 'xz') {
                    Set-AppStatus "Normalizing XZ fallback stage timestamps for block $id..." ([System.Drawing.Color]::DarkOrange)
                }

                Set-AppStatus "Creating fallback block $id $fallbackGroup..." ([System.Drawing.Color]::DarkOrange)
                Create-BlockFromStageList $TarPath $chunkStage $blockPath $group.Method $relativePaths
            }
            finally {
                Remove-SmartTarTempFolder $chunkStage
            }

            $sourceBytes = [int64]0
            foreach ($file in $chunkFiles) { $sourceBytes += [int64]$file.Bytes }

            $reason = ([string]$group.Reason) + " RC5 group-stage failed, RC6 chunk fallback used. Group-stage error: $err"
            Add-BlockManifestItem ([ref]$blocks) $id $fallbackGroup $blockPath $group.Method $reason ([int]$chunkFiles.Count) 0 $sourceBytes
            $index++
            $part++
        }
    }

    return $blocks
}

function Write-Manifest {
    param([string]$Path, $Data)
    $Data | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Build-Manifest {
    param(
        [string]$Source,
        $SourceItem,
        [string]$SourceLeaf,
        [string]$Mode,
        [hashtable]$Capabilities,
        [hashtable]$Profile,
        $Blocks
    )

    return [ordered]@{
        format          = 'STAR'
        formatVersion   = 1
        tool            = 'SmartTAR'
        toolVersion     = '1.0-beta1-fix13-rc5-responsive-readable-worker-temp-verify'
        createdUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        engine          = 'Windows tar.exe'
        model           = 'safe-workroot-group-hardlink-stage-fix13-rc5-responsive-worker'
        compressionMode = $Mode
        sourceName      = $SourceLeaf
        sourceType      = if ($SourceItem.PSIsContainer) { 'Folder' } else { 'File' }
        sourceBytes     = Get-SourceSize $Source
        rootRule        = 'Root-preserving. File blocks are preferably created as one group-stage block per data type. Extraction root is based on manifest sourceName.'
        creationMode    = 'safe-workroot-group-stage-dot-literal-hardlink-xz-dirtime-normalized-with-rc6-fallback'
        planning        = [ordered]@{
            strategy                 = 'direct-tar-C-stage-dot'
            hardlinkPathMode         = 'literal-escaped-newitem-with-mklink-fallback'
            xzStageDirectoryTimeMode = 'directories-only-normalized-to-2000-01-01'
            xzFileTimeMode           = 'preserve-original-hardlink-file-times'
            avoidsFileList           = $true
            avoidsLongCommandLine    = $true
            preferredBlockModel      = 'one-block-per-data-type'
            fallbackStrategy         = 'rc6-chunked-arguments'
            chunkMaxEntries          = 96
            chunkMaxChars            = 22000
            xzMaxLevel               = 9
            zstdMaxLevel             = 19
            uiExecution              = 'hidden-worker-process-with-config-json'
            verifyResult             = 'internal-temp-report-result-json'
        }
        capabilities    = [ordered]@{
            store  = [bool]$Capabilities.store
            gzip   = [bool]$Capabilities.gzip
            bzip2  = [bool]$Capabilities.bzip2
            xz9    = [bool]$Capabilities.xz9
            xz     = [bool]$Capabilities.xz
            zstd19 = [bool]$Capabilities.zstd19
        }
        sourceProfile         = $Profile
        groupStageDiagnostics = @($script:lastGroupDiagnostics)
        blocks                = @($Blocks)
    }
}

# ============================================================================
# 08. Extraction, verification and summary
# ============================================================================
function Read-OuterManifest {
    param([string]$OuterRoot)

    $manifestPath = Join-Path $OuterRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'manifest.json was not found.' }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.format -ne 'STAR' -and $manifest.format -ne 'SARC' -and $manifest.format -ne 'SmartTarArc') {
        throw 'Invalid archive format.'
    }
    return $manifest
}

function Test-RelativePathSafe {
    param([string]$PathText)

    if (Test-Blank $PathText) { return $false }

    $path = Convert-ToTarPath $PathText
    if ($path -eq '.' -or $path -eq './') { return $true }
    if ($path -match '^[a-zA-Z]:') { return $false }
    if ($path.StartsWith('/') -or $path.StartsWith('//')) { return $false }

    foreach ($part in @($path.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne '.' })) {
        if ($part -eq '..') { return $false }
    }
    return $true
}

function Resolve-SafeBlockPath {
    param([string]$OuterRoot, [string]$RelativeBlockPath)
    if (-not (Test-RelativePathSafe $RelativeBlockPath)) { throw "Unsafe block path: $RelativeBlockPath" }
    return (Join-Path $OuterRoot (Convert-ToLocalPath $RelativeBlockPath))
}

function Test-ArchiveEntriesSafe {
    param([string]$TarPath, [string]$ArchivePath)

    $result = Invoke-TarRaw $TarPath @('-tf', $ArchivePath)
    if ([int]$result.ExitCode -ne 0) { throw "Cannot list TAR block: $ArchivePath`r`n$($result.Output)" }

    foreach ($entry in @(([string]$result.Output) -split "`r?`n")) {
        if (-not (Test-Blank $entry)) {
            if (-not (Test-RelativePathSafe $entry)) { throw "Unsafe path inside TAR block: $entry" }
        }
    }
}

function Get-ArchiveBaseNameWithoutSmartExtension {
    param([string]$ArchivePath)
    $name = [System.IO.Path]::GetFileName($ArchivePath)
    if ($name -match '^(.*)\.sarc\.tar$') { return $matches[1] }
    if ($name -match '^(.*)\.star$') { return $matches[1] }
    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}

function Get-ArchiveRootName {
    param($Manifest, [string]$ArchivePath)
    $sourceName = [string]$Manifest.sourceName
    if (-not (Test-Blank $sourceName)) { return $sourceName }
    return (Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath)
}

function Prepare-SafeArchiveInput {
    param([string]$ArchivePath, [string]$WorkRoot)

    $safeArchive = Join-Path $WorkRoot 'input.star'
    if (Test-Path -LiteralPath $safeArchive) {
        Remove-Item -LiteralPath $safeArchive -Force -ErrorAction SilentlyContinue
    }

    try {
        New-HardLinkLiteral $safeArchive $ArchivePath
    }
    catch {
        Copy-Item -LiteralPath $ArchivePath -Destination $safeArchive -Force -ErrorAction Stop
    }
    return $safeArchive
}

function Format-GroupDiagnostics {
    param($Manifest)

    $diagnostics = @($Manifest.groupStageDiagnostics)
    if ($diagnostics.Count -lt 1) { return '' }

    $lines = @('', 'Group-stage diagnostics:')
    foreach ($diag in $diagnostics) {
        $lines += ('{0}: {1}, files={2}, source={3}, message={4}' -f `
            $diag.group,
            $diag.status,
            $diag.fileCount,
            (Format-Bytes ([int64]$diag.sourceBytes)),
            ([string]$diag.message)
        )
    }
    return ($lines -join "`r`n")
}

function Get-SmartArchivePlannedExtractionTarget {
    param([string]$TarPath, [string]$ArchivePath, [string]$DestinationParent)

    $work = New-SafeWorkRoot 'precheck' $ArchivePath
    $outer = Join-Path $work 'outer'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null

    try {
        $safeArchive = Prepare-SafeArchiveInput $ArchivePath $work
        Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer) 'Outer pre-check extraction failed.'

        $manifest = Read-OuterManifest $outer
        $rootName = Get-ArchiveRootName $manifest $ArchivePath

        if ([string]$manifest.sourceType -eq 'Folder' -and -not (Test-Blank $rootName)) {
            return [pscustomobject]@{
                SourceType = [string]$manifest.sourceType
                SourceName = [string]$rootName
                TargetPath = (Join-Path $DestinationParent $rootName)
            }
        }

        return [pscustomobject]@{
            SourceType = [string]$manifest.sourceType
            SourceName = [string]$rootName
            TargetPath = $DestinationParent
        }
    }
    finally {
        Remove-SmartTarWorkAndRoot $work
    }
}

function Confirm-ExtractionOverwriteIfNeeded {
    param([string]$TarPath, [string]$ArchivePath, [string]$DestinationParent)

    $planned = Get-SmartArchivePlannedExtractionTarget $TarPath $ArchivePath $DestinationParent

    if ($planned -and (Test-Path -LiteralPath ([string]$planned.TargetPath))) {
        $archiveFile = [System.IO.Path]::GetFileName($ArchivePath)
        $message = @"
Target already exists:
$($planned.TargetPath)

Existing files/folders may be merged or overwritten.

Archive file name:
$archiveFile

Stored source name used for extraction:
$($planned.SourceName)

Continue?
"@
        $confirm = Show-Message $message 'Merge / overwrite existing target?' ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo)
        return ($confirm -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    return $true
}

function Copy-DirectoryContents {
    param([string]$SourceRoot, [string]$DestinationRoot)

    if (-not (Test-Path -LiteralPath $SourceRoot)) { return }
    if (-not (Test-Path -LiteralPath $DestinationRoot)) { [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null }

    Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $target = Join-Path $DestinationRoot $_.Name
        if ($_.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $target)) { [System.IO.Directory]::CreateDirectory($target) | Out-Null }
            Copy-DirectoryContents $_.FullName $target
        }
        else {
            $targetDir = Split-Path -Parent $target
            if (-not (Test-Blank $targetDir)) { [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Copy-PayloadToFinalDestination {
    param($Manifest, [string]$PayloadRoot, [string]$DestinationParent, [string]$ArchivePath)

    $rootName = Get-ArchiveRootName $Manifest $ArchivePath
    $sourceType = [string]$Manifest.sourceType

    if ($sourceType -eq 'Folder' -and -not (Test-Blank $rootName)) {
        $finalRoot = Join-Path $DestinationParent $rootName
        if (-not (Test-Path -LiteralPath $finalRoot)) { [System.IO.Directory]::CreateDirectory($finalRoot) | Out-Null }

        $rootInPayload = Join-Path $PayloadRoot $rootName
        if (Test-Path -LiteralPath $rootInPayload) {
            Copy-DirectoryContents $rootInPayload $finalRoot
        }
        else {
            Copy-DirectoryContents $PayloadRoot $finalRoot
        }
        return
    }

    Copy-DirectoryContents $PayloadRoot $DestinationParent
}

function Extract-Blocks {
    param([string]$TarPath, [string]$OuterRoot, $Blocks, [string]$DestinationFolder, [bool]$SalvageMode = $false)

    $script:lastSalvageSkippedBlocks = @()

    foreach ($block in @($Blocks)) {
        $blockLabel = "$($block.id) $($block.group) $($block.path)"
        try {
            $blockPath = Resolve-SafeBlockPath $OuterRoot ([string]$block.path)
            if (-not (Test-Path -LiteralPath $blockPath)) { throw "Block missing: $($block.path)" }

            if ($block.sha256) {
                $actualHash = Get-FileSHA256 $blockPath
                if ($actualHash -ne ([string]$block.sha256).ToLowerInvariant()) {
                    throw "Block SHA256 mismatch: $($block.path)"
                }
            }

            Test-ArchiveEntriesSafe $TarPath $blockPath
            Invoke-Tar $TarPath @('-xf', $blockPath, '-C', $DestinationFolder) "Block extraction failed: $($block.path)."
        }
        catch {
            if ($SalvageMode) {
                $script:lastSalvageSkippedBlocks += "SKIPPED: $blockLabel`r`nReason: $([string]$_.Exception.Message)"
                continue
            }
            throw
        }
    }

    return @($script:lastSalvageSkippedBlocks)
}

function Extract-SmartArchive {
    param([string]$TarPath, [string]$ArchivePath, [string]$DestinationFolder, [bool]$SalvageMode = $false)

    if (-not (Test-Path -LiteralPath $TarPath)) { throw 'tar.exe was not found.' }
    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw 'Archive path does not exist.' }
    if (Test-Blank $DestinationFolder) { throw 'Destination folder is empty.' }

    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        [System.IO.Directory]::CreateDirectory($DestinationFolder) | Out-Null
    }

    $work = New-SafeWorkRoot 'extract' $ArchivePath
    $outer = Join-Path $work 'outer'
    $payload = Join-Path $work 'payload'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null
    [System.IO.Directory]::CreateDirectory($payload) | Out-Null

    try {
        $safeArchive = Prepare-SafeArchiveInput $ArchivePath $work
        Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer) 'Outer extraction failed.'
        $manifest = Read-OuterManifest $outer
        [void](Extract-Blocks $TarPath $outer @($manifest.blocks) $payload $SalvageMode)
        Copy-PayloadToFinalDestination $manifest $payload $DestinationFolder $ArchivePath
    }
    finally {
        Remove-SmartTarWorkAndRoot $work
    }
}

function Verify-SmartArchive {
    param([string]$TarPath, [string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw 'Archive path does not exist.' }

    $work = New-SafeWorkRoot 'verify' $ArchivePath
    $outer = Join-Path $work 'outer'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null

    try {
        $safeArchive = Prepare-SafeArchiveInput $ArchivePath $work
        Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer) 'Outer verification failed.'

        $manifest = Read-OuterManifest $outer
        $blocks = @($manifest.blocks)
        $ok = 0
        $fail = 0
        $lines = @()

        foreach ($block in $blocks) {
            Set-AppStatus "Verifying block $($block.id) $($block.group)..." ([System.Drawing.Color]::DarkOrange)

            $blockPath = Resolve-SafeBlockPath $outer ([string]$block.path)
            if (-not (Test-Path -LiteralPath $blockPath)) {
                $fail++
                $lines += "MISSING: $($block.path)"
                continue
            }

            $listed = Invoke-TarList $TarPath $blockPath
            $hashOk = $true
            if ($block.sha256) {
                $hashOk = ((Get-FileSHA256 $blockPath) -eq ([string]$block.sha256).ToLowerInvariant())
            }

            if ($listed -and $hashOk) {
                $ok++
                $lines += "OK: $($block.id) $($block.group) $($block.display) $($block.path)"
            }
            else {
                $fail++
                $lines += "FAIL: $($block.id) $($block.group) $($block.path)"
            }
        }

        $status = if ($fail -eq 0) { 'Archive verification OK' } else { 'Archive verification FAILED' }
        $archiveSize = [int64](Get-Item -LiteralPath $ArchivePath).Length
        $diag = Format-GroupDiagnostics $manifest

        return @"
$status

Format: $($manifest.format)
Tool: $($manifest.tool)
Version: $($manifest.toolVersion)
Mode: $($manifest.compressionMode)
Root rule: $($manifest.rootRule)
Creation mode: $($manifest.creationMode)
Blocks: $($blocks.Count)
Blocks OK: $ok
Blocks failed: $fail
Archive size: $(Format-Bytes $archiveSize)$diag

$($lines -join "`r`n")
"@
    }
    finally {
        Remove-SmartTarWorkAndRoot $work
    }
}

function Get-ArchiveSummary {
    param([string]$TarPath, [string]$ArchivePath, [string]$SourcePath)

    $sourceBytes = Get-SourceSize $SourcePath
    $archiveBytes = [int64](Get-Item -LiteralPath $ArchivePath).Length
    $ratio = 'n/a'
    $saved = 'n/a'

    if ($sourceBytes -gt 0) {
        $ratio = '{0:N2} %' -f (($archiveBytes / $sourceBytes) * 100)
        $saved = '{0:N2} %' -f ((1 - ($archiveBytes / $sourceBytes)) * 100)
    }

    $verify = Verify-SmartArchive $TarPath $ArchivePath

    return @"
Archive created successfully.

Source size: $(Format-Bytes $sourceBytes)
Archive size: $(Format-Bytes $archiveBytes)
Ratio: $ratio
Saved: $saved

$verify
"@
}

# ============================================================================
# 09. Core compression
# ============================================================================
function Compress-SmartArchive {
    param([string]$TarPath, [string]$Source, [string]$Destination, [string]$Mode)

    if (-not (Test-Path -LiteralPath $TarPath)) { throw 'tar.exe was not found.' }

    $Source = Normalize-ArchiveSourcePath $Source
    if (-not (Test-Path -LiteralPath $Source)) { throw 'Source path does not exist.' }

    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    if ($Mode -notin @('Hybrid','Smart','Solid','SmartXZ','Store')) { $Mode = 'Hybrid' }

    $work = New-SafeWorkRoot 'create' $Source
    $blocksDir = Join-Path $work 'blocks'
    $structureStage = Join-Path $work 'structure_stage'
    [System.IO.Directory]::CreateDirectory($blocksDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($structureStage) | Out-Null

    try {
        Set-AppStatus 'Checking TAR capabilities...' ([System.Drawing.Color]::DarkOrange)
        $capabilities = Test-TarCapabilities $TarPath $work
        if (-not $capabilities.store) { throw 'No usable tar store method.' }

        $sourceItem = Get-Item -LiteralPath $Source -Force
        $sourceParent = Split-Path -Parent $Source
        $sourceLeaf = Split-Path -Leaf $Source
        if (Test-Blank $sourceParent) { $sourceParent = (Get-Location).Path }
        if (Test-Blank $sourceLeaf) { $sourceParent = $Source; $sourceLeaf = '.' }

        Set-AppStatus 'Analyzing source...' ([System.Drawing.Color]::DarkOrange)
        $profile = Get-SourceProfile $sourceItem $Source $sourceParent
        $groups = New-ArchiveGroups $Mode $capabilities $profile

        Stage-FilesPlan $sourceItem $Source $sourceParent $Mode $groups
        $dirCount = Create-StructureStage $sourceItem $Source $sourceParent $structureStage
        $storeMethod = Select-StoreMethod $capabilities

        Set-AppStatus 'Creating internal group blocks...' ([System.Drawing.Color]::DarkOrange)
        $blocks = Build-Blocks $TarPath $groups $blocksDir $work $structureStage $dirCount $storeMethod
        if ($blocks.Count -lt 1) { throw 'No blocks were created.' }

        $manifest = Build-Manifest $Source $sourceItem $sourceLeaf $Mode $capabilities $profile $blocks
        Write-Manifest (Join-Path $work 'manifest.json') $manifest

        Set-AppStatus 'Creating outer .star container...' ([System.Drawing.Color]::DarkOrange)
        $safeOuter = Join-Path $work 'archive.star'
        Invoke-Tar $TarPath @('-cf', $safeOuter, '-C', $work, 'manifest.json', 'blocks') 'Outer .star archive creation failed.'

        $destDir = [System.IO.Path]::GetDirectoryName($Destination)
        if (-not (Test-Path -LiteralPath $destDir)) { [System.IO.Directory]::CreateDirectory($destDir) | Out-Null }
        Move-Item -LiteralPath $safeOuter -Destination $Destination -Force
    }
    finally {
        Remove-SmartTarWorkAndRoot $work
    }
}

# ============================================================================
# 10. Worker mode - one config file, temp report/result
# ============================================================================
if (-not (Test-Blank $WorkerConfigFile)) {
    try {
        $script:workerConfig = Get-Content -LiteralPath $WorkerConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg = $script:workerConfig

        $action = [string]$cfg.Action
        $source = [string]$cfg.Source
        $destination = [string]$cfg.Destination
        $mode = [string]$cfg.Mode
        $internalReport = [string]$cfg.InternalReportFile
        $finalReport = [string]$cfg.FinalReportFile
        $resultFile = [string]$cfg.ResultFile
        $salvage = [bool]$cfg.Salvage

        if (Test-Blank $source -or -not (Test-Path -LiteralPath $source)) { throw "Worker source path does not exist: $source" }
        if (Test-Blank $internalReport) { throw 'Internal report path is empty.' }
        if (Test-Blank $resultFile) { throw 'Result path is empty.' }

        if ($action -eq 'Compress') {
            if (Test-Blank $destination) { throw 'Worker destination path is empty.' }

            Set-AppStatus 'Starting compression...' ([System.Drawing.Color]::DarkOrange)
            Compress-SmartArchive $tarPath $source $destination $mode

            try {
                $summary = Get-ArchiveSummary $tarPath $destination $source
                Write-ReportFile $internalReport $summary
                if (-not (Test-Blank $finalReport)) { Copy-Item -LiteralPath $internalReport -Destination $finalReport -Force }

                @{
                    Success = $true
                    Action = 'Compress'
                    InternalReportFile = $internalReport
                    FinalReportFile = $finalReport
                    TargetPath = $destination
                    Mode = $mode
                } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultFile -Encoding UTF8
            }
            catch {
                $verifyError = Get-ErrorDetails $_
                Write-ReportFile $internalReport "Archive created, but verify failed:`r`n$verifyError"
                if (-not (Test-Blank $finalReport)) { Copy-Item -LiteralPath $internalReport -Destination $finalReport -Force }

                @{
                    Success = $true
                    Action = 'Compress'
                    InternalReportFile = $internalReport
                    FinalReportFile = $finalReport
                    TargetPath = $destination
                    Mode = $mode
                    VerifyFailed = $true
                } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultFile -Encoding UTF8
            }
        }
        elseif ($action -eq 'Extract') {
            if (Test-Blank $destination) { throw 'Worker destination path is empty.' }

            Set-AppStatus 'Starting extraction...' ([System.Drawing.Color]::DarkOrange)
            Extract-SmartArchive $tarPath $source $destination $salvage

            $skipped = @($script:lastSalvageSkippedBlocks)
            $modeText = if ($salvage) { 'Salvage mode: ON' } else { 'Salvage mode: OFF' }
            $text = "Archive extracted successfully.`r`nArchive: $source`r`nExtraction parent folder: $destination`r`n$modeText"

            if ($salvage -and $skipped.Count -gt 0) {
                $text += "`r`n`r`nWARNING: Some blocks were skipped.`r`nSkipped blocks: $($skipped.Count)`r`n`r`n$($skipped -join "`r`n`r`n")"
            }
            elseif ($salvage) {
                $text += "`r`n`r`nNo broken blocks were detected. Nothing was skipped."
            }

            Write-ReportFile $internalReport $text
            if (-not (Test-Blank $finalReport)) { Copy-Item -LiteralPath $internalReport -Destination $finalReport -Force }

            @{
                Success = $true
                Action = 'Extract'
                InternalReportFile = $internalReport
                FinalReportFile = $finalReport
                Destination = $destination
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultFile -Encoding UTF8
        }
        elseif ($action -eq 'Verify') {
            Set-AppStatus 'Starting verification...' ([System.Drawing.Color]::DarkOrange)
            $summary = Verify-SmartArchive $tarPath $source

            Write-ReportFile $internalReport $summary
            if (-not (Test-Blank $finalReport)) { Copy-Item -LiteralPath $internalReport -Destination $finalReport -Force }

            @{
                Success = $true
                Action = 'Verify'
                InternalReportFile = $internalReport
                FinalReportFile = $finalReport
                TargetPath = $source
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultFile -Encoding UTF8
        }
        else {
            throw "Unknown worker action: $action"
        }

        Set-AppStatus 'Done.' ([System.Drawing.Color]::Green)
        exit 0
    }
    catch {
        $err = Get-ErrorDetails $_
        try {
            if ($script:workerConfig) {
                if (-not (Test-Blank ([string]$script:workerConfig.InternalReportFile))) {
                    Write-ReportFile ([string]$script:workerConfig.InternalReportFile) "Operation failed.`r`n`r`n$err"
                }
                if (-not (Test-Blank ([string]$script:workerConfig.ResultFile))) {
                    @{
                        Success = $false
                        Action  = ([string]$script:workerConfig.Action)
                        Error   = $err
                    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath ([string]$script:workerConfig.ResultFile) -Encoding UTF8
                }
            }
        }
        catch {}
        exit 1
    }
}

# ============================================================================
# 11. Path and GUI helpers
# ============================================================================
function Test-SmartArchivePath {
    param([string]$Path)
    if (Test-Blank $Path) { return $false }
    return ([System.IO.Path]::GetFileName($Path) -match '(?i)(\.star|\.sarc\.tar)$')
}

function Ensure-StarExtension {
    param([string]$Path)
    if (Test-Blank $Path) { return $Path }
    if ($Path -match '(?i)(\.star|\.sarc\.tar)$') { return $Path }
    return ($Path + '.star')
}

function Get-DefaultArchiveBaseName {
    param([string]$Path, [string]$Type)

    $leaf = Split-Path -Leaf (Normalize-ArchiveSourcePath $Path)
    if (Test-Blank $leaf) { return "archive_$(Get-Date -Format yyyyMMdd_HHmmss)" }
    if ($Type -eq 'Folder') { return $leaf }
    return [System.IO.Path]::GetFileNameWithoutExtension($leaf)
}

function Get-SelectedCompressionMode {
    $text = [string]$cmbMode.SelectedItem
    if ($text -like 'Smart XZ*') { return 'SmartXZ' }
    if ($text -like 'Smart*') { return 'Smart' }
    if ($text -like 'Solid*') { return 'Solid' }
    if ($text -like 'Store*') { return 'Store' }
    return 'Hybrid'
}

function Set-DefaultTarget {
    if (Test-Blank $script:selectedPath) { return }

    $parent = Split-Path -Parent $script:selectedPath
    if (Test-Blank $parent) { $parent = $scriptDir }

    if ($script:selectedType -eq 'File' -and (Test-SmartArchivePath $script:selectedPath)) {
        $txtTarget.Text = $parent
        return
    }

    $txtTarget.Text = Join-Path $parent ((Get-DefaultArchiveBaseName $script:selectedPath $script:selectedType) + '.star')
}

function Set-SelectedPath {
    param([string]$Path, [ValidateSet('File','Folder')][string]$Type)

    $script:selectedPath = $Path
    $script:selectedType = $Type
    $lblSelected.Text = "Selected: $Path"
    Set-DefaultTarget
    Clear-UiFocus
}

function Test-SelectedInputReady {
    param([string]$Purpose)

    if (Test-Blank $script:selectedPath) {
        Show-Message "Select input first for $Purpose." | Out-Null
        return $false
    }

    if (-not (Test-Path -LiteralPath $script:selectedPath)) {
        Show-Message "Selected input does not exist:`r`n$($script:selectedPath)" 'Missing selected input' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return $false
    }

    return $true
}

# ============================================================================
# 12. Responsive worker launcher
# ============================================================================
function Quote-ProcessArg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"','\"') + '"'
}

function Start-WorkerOperation {
    param(
        [string]$Action,
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Mode = 'Hybrid',
        [bool]$Salvage = $false
    )

    if (Test-Blank $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) {
        Show-Message "Selected input does not exist:`r`n$SourcePath" 'Missing input' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $script:currentWorkerRoot = New-SafeWorkRoot 'uiworker' $scriptDir
    $script:currentConfigFile = Join-Path $script:currentWorkerRoot 'worker_config.json'
    $script:currentStatusFile = Join-Path $script:currentWorkerRoot 'status.txt'
    $script:currentResultFile = Join-Path $script:currentWorkerRoot 'result.json'
    $script:currentInternalReportFile = Join-Path $script:currentWorkerRoot 'report.txt'

    $reportKind = switch ($Action) {
        'Compress' { 'create_report' }
        'Extract'  { 'extract_report' }
        'Verify'   { 'verify_report' }
        default    { 'worker_report' }
    }

    $reportBase = if ($Action -eq 'Compress' -and -not (Test-Blank $DestinationPath)) { $DestinationPath } else { $SourcePath }
    $script:currentFinalReportFile = Get-ReportPath $reportBase $reportKind

    $script:currentAction = $Action
    $script:openFolderAfter = [bool]$chkOpenFolder.Checked
    $script:currentStdOut = ''
    $script:currentStdErr = ''

    'Starting...' | Set-Content -LiteralPath $script:currentStatusFile -Encoding UTF8

    $config = [ordered]@{
        Action             = $Action
        Source             = $SourcePath
        Destination        = $DestinationPath
        Mode               = $Mode
        Salvage            = $Salvage
        WorkerRoot         = $script:currentWorkerRoot
        StatusFile         = $script:currentStatusFile
        ResultFile         = $script:currentResultFile
        InternalReportFile = $script:currentInternalReportFile
        FinalReportFile    = $script:currentFinalReportFile
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:currentConfigFile -Encoding UTF8

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

    try { $powershellExe = (Get-Process -Id $PID).Path } catch { $powershellExe = '' }
    if (Test-Blank $powershellExe) { $powershellExe = Join-Path $PSHOME 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $powershellExe)) { $powershellExe = 'powershell.exe' }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-WorkerConfigFile', $script:currentConfigFile
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershellExe
    $psi.Arguments = (($argList | ForEach-Object { Quote-ProcessArg ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $script:currentProcess = [System.Diagnostics.Process]::Start($psi)

    Set-UiBusy $true
    Set-AppStatus "$Action started..." ([System.Drawing.Color]::DarkOrange)
    $timer.Start()
    Clear-UiFocus
}

function Read-WorkerResultFromTemp {
    for ($i = 1; $i -le 30; $i++) {
        if (Test-Path -LiteralPath $script:currentResultFile) {
            try {
                return (Get-Content -LiteralPath $script:currentResultFile -Raw -Encoding UTF8 | ConvertFrom-Json)
            }
            catch {
                Start-Sleep -Milliseconds 100
            }
        }
        else {
            Start-Sleep -Milliseconds 100
        }
    }
    return $null
}

function Resolve-WorkerCompletionFromTemp {
    param($Result)

    if ($Result -and [bool]$Result.Success) {
        $internalReport = [string]$Result.InternalReportFile
        if (Test-Blank $internalReport) { $internalReport = $script:currentInternalReportFile }

        if (Wait-FileReady $internalReport 15000 100) {
            return [pscustomobject]@{
                Success            = $true
                Action             = [string]$Result.Action
                Summary            = (Read-TextFileSafe $internalReport)
                InternalReportFile = $internalReport
                FinalReportFile    = [string]$Result.FinalReportFile
                TargetPath         = [string]$Result.TargetPath
                Destination        = [string]$Result.Destination
            }
        }
    }

    if (Wait-FileReady $script:currentInternalReportFile 15000 100) {
        return [pscustomobject]@{
            Success            = $true
            Action             = $script:currentAction
            Summary            = (Read-TextFileSafe $script:currentInternalReportFile)
            InternalReportFile = $script:currentInternalReportFile
            FinalReportFile    = $script:currentFinalReportFile
            TargetPath         = ''
            Destination        = ''
        }
    }

    if ($Result -and $Result.Error) {
        return [pscustomobject]@{ Success = $false; Error = [string]$Result.Error }
    }

    return [pscustomobject]@{
        Success = $false
        Error   = 'Worker ended without temp result/report. See stdout/stderr details.'
    }
}

# ============================================================================
# 13. GUI construction
# ============================================================================
function New-EcoLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 470,
        [int]$Height = 20,
        [System.Drawing.Font]$Font = $fNormal,
        [System.Drawing.Color]$ForeColor = $cText
    )

    return New-UiObject 'System.Windows.Forms.Label' @{
        Text      = $Text
        Location  = (New-Point $X $Y)
        Size      = (New-Size $Width $Height)
        Font      = $Font
        ForeColor = $ForeColor
        BackColor = $cBg
    }
}

function New-EcoButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [System.Drawing.Font]$Font = $fNormal,
        [System.Drawing.Color]$BackColor = $cBg,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::Black
    )

    $button = New-UiObject 'System.Windows.Forms.Button' @{
        Text                    = $Text
        Location                = (New-Point $X $Y)
        Size                    = (New-Size $Width $Height)
        Font                    = $Font
        BackColor               = $BackColor
        ForeColor               = $ForeColor
        UseVisualStyleBackColor = $false
    }

    try {
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderSize = 1
        $button.FlatAppearance.BorderColor = $cGray
    }
    catch {}

    return $button
}

function New-EcoCheck {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Checked = $true)

    return New-UiObject 'System.Windows.Forms.CheckBox' @{
        Text      = $Text
        Location  = (New-Point $X $Y)
        Size      = (New-Size $Width 22)
        Font      = $fNormal
        BackColor = $cBg
        ForeColor = $cText
        Checked   = $Checked
    }
}

function Show-Message {
    param(
        [string]$Message,
        [string]$Title = 'SmartTAR STAR v1.0',
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )
    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

$form = New-UiObject 'System.Windows.Forms.Form' @{
    Text            = 'SmartTAR STAR v1.0    ..:: Copyright (c) 2026 eco-by-different ::..'
    ClientSize      = (New-Size 505 490)
    StartPosition   = 'CenterScreen'
    BackColor       = $cBg
    FormBorderStyle = 'FixedSingle'
    MaximizeBox     = $false
}
Enable-ControlDoubleBuffering $form

$lblInput    = New-EcoLabel '1. Select input file or folder:' 20 20 -Font $fBold
$btnFile     = New-EcoButton 'Add FILE' 20 48 150 30
$btnFolder   = New-EcoButton 'Add FOLDER' 177 48 150 30
$btnArchive  = New-EcoButton 'Add ARCHIVE' 334 48 151 30
$lblSelected = New-EcoLabel 'Selected: none' 20 88 465 20 $fItalic ([System.Drawing.Color]::DimGray)
try { $lblSelected.UseMnemonic = $false; $lblSelected.AutoEllipsis = $true } catch {}

$lblTarget = New-EcoLabel '2. Destination archive / extraction parent folder:' 20 125 -Font $fBold
$txtTarget = New-UiObject 'System.Windows.Forms.TextBox' @{
    Location      = (New-Point 20 153)
    Size          = (New-Size 395 23)
    Font          = $fNormal
    ReadOnly      = $true
    BackColor     = $cBg
    TabStop       = $false
    HideSelection = $true
}
$btnTarget = New-EcoButton '...' 422 152 63 24

$lblMode = New-EcoLabel '3. Compression mode:' 20 195 -Font $fBold
$cmbMode = New-UiObject 'System.Windows.Forms.ComboBox' @{
    Location      = (New-Point 20 223)
    Size          = (New-Size 465 24)
    Font          = $fNormal
    DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
}
[void]$cmbMode.Items.Add('Hybrid - group blocks XZ9 + ZSTD19 + STORE')
[void]$cmbMode.Items.Add('Smart - one block per detected data type')
[void]$cmbMode.Items.Add('Solid - one auto-selected compressed block')
[void]$cmbMode.Items.Add('Smart XZ - grouped XZ9 blocks')
[void]$cmbMode.Items.Add('Store - grouped TAR blocks without compression')
$cmbMode.SelectedIndex = 0

$lblInfo = New-EcoLabel 'Fix 13 RC5: responsive worker + temp verify result/report enabled.' 20 252 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$btnCompress = New-EcoButton 'COMPRESS' 20 287 150 42 $fBold ([System.Drawing.Color]::SeaGreen) $cButtonText
$btnExtract  = New-EcoButton 'EXTRACT' 177 287 150 42 $fBold ([System.Drawing.Color]::SteelBlue) $cButtonText
$btnVerify   = New-EcoButton 'VERIFY' 334 287 151 42 $fBold ([System.Drawing.Color]::DarkSlateGray) $cButtonText

$chkOpenFolder  = New-EcoCheck 'Open output folder after success' 20 342 300 $true
$chkSalvageMode = New-EcoCheck 'Salvage mode (Ignore broken blocks)' 20 366 330 $false

$lblStatus = New-EcoLabel 'Ready.' 20 404 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$progressBar = New-UiObject 'System.Windows.Forms.ProgressBar' @{
    Location = (New-Point 20 447)
    Size     = (New-Size 465 8)
    Style    = [System.Windows.Forms.ProgressBarStyle]::Marquee
    Visible  = $false
    MarqueeAnimationSpeed = 0
}

$form.Controls.AddRange([System.Windows.Forms.Control[]]@(
    $lblInput, $btnFile, $btnFolder, $btnArchive, $lblSelected,
    $lblTarget, $txtTarget, $btnTarget,
    $lblMode, $cmbMode, $lblInfo,
    $btnCompress, $btnExtract, $btnVerify,
    $chkOpenFolder, $chkSalvageMode,
    $lblStatus, $progressBar
))
Set-OperationButtonsVisualState

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        if (-not (Test-Blank $script:currentStatusFile) -and (Test-Path -LiteralPath $script:currentStatusFile)) {
            $statusText = Get-Content -LiteralPath $script:currentStatusFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not (Test-Blank $statusText)) {
                Set-AppStatus $statusText.Trim() ([System.Drawing.Color]::DarkOrange)
            }
        }

        if ($script:currentProcess -and $script:currentProcess.HasExited) {
            $timer.Stop()

            try { $script:currentStdOut = $script:currentProcess.StandardOutput.ReadToEnd() } catch { $script:currentStdOut = '' }
            try { $script:currentStdErr = $script:currentProcess.StandardError.ReadToEnd() } catch { $script:currentStdErr = '' }

            $result = Read-WorkerResultFromTemp
            $completion = Resolve-WorkerCompletionFromTemp $result

            Set-UiBusy $false
            Clear-UiFocus

            if ($completion.Success) {
                Set-AppStatus "$($completion.Action) completed successfully." ([System.Drawing.Color]::Green)

                $shownReport = if (-not (Test-Blank $completion.FinalReportFile)) {
                    $completion.FinalReportFile
                }
                else {
                    $completion.InternalReportFile
                }

                Show-Message "$($completion.Summary)`r`n`r`nReport saved:`r`n$shownReport" "SmartTAR $($completion.Action)" | Out-Null

                if ($script:openFolderAfter) {
                    if ($completion.Action -eq 'Compress' -and -not (Test-Blank $completion.TargetPath)) {
                        explorer.exe "/select,`"$($completion.TargetPath)`""
                    }
                    elseif ($completion.Action -eq 'Extract' -and -not (Test-Blank $completion.Destination)) {
                        explorer.exe "`"$($completion.Destination)`""
                    }
                }
            }
            else {
                $errorText = [string]$completion.Error
                if (-not (Test-Blank $script:currentStdErr)) { $errorText += "`r`n`r`nWorker stderr:`r`n$($script:currentStdErr)" }
                if (-not (Test-Blank $script:currentStdOut)) { $errorText += "`r`n`r`nWorker stdout:`r`n$($script:currentStdOut)" }

                Set-AppStatus "$($script:currentAction) failed." ([System.Drawing.Color]::Red)
                Show-Message "$($script:currentAction) failed.`r`n`r`n$errorText" 'SmartTAR Error' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }

            try { $script:currentProcess.Dispose() } catch {}
            $script:currentProcess = $null

            Remove-SmartTarWorkAndRoot $script:currentWorkerRoot
            $script:currentWorkerRoot = ''
            $script:currentConfigFile = ''
            $script:currentStatusFile = ''
            $script:currentResultFile = ''
            $script:currentInternalReportFile = ''
            $script:currentFinalReportFile = ''
        }
    }
    catch {
        $timer.Stop()
        Set-UiBusy $false
        Clear-UiFocus
        Set-AppStatus 'GUI worker monitor failed.' ([System.Drawing.Color]::Red)
        Show-Message (Get-ErrorDetails $_) 'SmartTAR GUI Error' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

# ============================================================================
# 14. GUI events and execution handlers
# ============================================================================
$btnFile.Add_Click({
    if ($script:isBusy) { return }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'All files (*.*)|*.*'
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-SelectedPath $dialog.FileName 'File'
        }
    }
    finally { $dialog.Dispose() }
})

$btnFolder.Add_Click({
    if ($script:isBusy) { return }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-SelectedPath (Normalize-ArchiveSourcePath $dialog.SelectedPath) 'Folder'
        }
    }
    finally { $dialog.Dispose() }
})

$btnArchive.Add_Click({
    if ($script:isBusy) { return }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'SmartTAR Archive (*.star)|*.star|Legacy (*.sarc.tar)|*.sarc.tar|All files (*.*)|*.*'
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-SelectedPath $dialog.FileName 'File'
        }
    }
    finally { $dialog.Dispose() }
})

$btnTarget.Add_Click({
    if ($script:isBusy) { return }

    if ($script:selectedType -eq 'File' -and (Test-SmartArchivePath $script:selectedPath)) {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtTarget.Text = $dialog.SelectedPath
                Clear-UiFocus
            }
        }
        finally { $dialog.Dispose() }
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'SmartTAR Archive (*.star)|*.star|All files (*.*)|*.*'
    $dialog.DefaultExt = 'star'
    $dialog.AddExtension = $true

    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtTarget.Text = Ensure-StarExtension $dialog.FileName
            Clear-UiFocus
        }
    }
    finally { $dialog.Dispose() }
})

function Execute-Compress {
    if ($script:isBusy) { return }

    if (-not (Test-Path -LiteralPath $tarPath)) {
        Show-Message 'tar.exe was not found.' 'Missing TAR' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    if (-not (Test-SelectedInputReady 'compression')) { return }

    $targetPath = Ensure-StarExtension ($txtTarget.Text.Trim('"'))
    if (Test-Blank $targetPath) {
        Show-Message 'Select destination.' | Out-Null
        return
    }

    $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
    if (Test-Blank $targetDir) {
        $targetDir = $scriptDir
        $targetPath = Join-Path $targetDir ([System.IO.Path]::GetFileName($targetPath))
    }

    if (Test-Path -LiteralPath $targetPath) {
        $confirm = Show-Message "Target archive already exists:`r`n$targetPath`r`n`r`nOverwrite?" 'Overwrite archive?' ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Start-WorkerOperation 'Compress' $script:selectedPath $targetPath (Get-SelectedCompressionMode) $false
}

function Execute-Extract {
    if ($script:isBusy) { return }
    if (-not (Test-SelectedInputReady 'extraction')) { return }

    $destination = $txtTarget.Text.Trim('"')
    if (Test-Blank $destination) {
        Show-Message 'Select extraction parent folder.' | Out-Null
        return
    }

    if (-not (Test-Path -LiteralPath $destination)) {
        [System.IO.Directory]::CreateDirectory($destination) | Out-Null
    }

    try {
        $canContinue = Confirm-ExtractionOverwriteIfNeeded $tarPath $script:selectedPath $destination
        if (-not $canContinue) {
            Set-AppStatus 'Extraction cancelled by user.' ([System.Drawing.Color]::DimGray)
            return
        }
    }
    catch {
        $precheckError = Get-ErrorDetails $_
        Show-Message "Extraction pre-check failed.`n`n$precheckError" 'SmartTAR Error' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    Start-WorkerOperation 'Extract' $script:selectedPath $destination 'Hybrid' ([bool]$chkSalvageMode.Checked)
}

function Execute-Verify {
    if ($script:isBusy) { return }
    if (-not (Test-SelectedInputReady 'verification')) { return }

    if (-not (Test-SmartArchivePath $script:selectedPath)) {
        Show-Message "Selected input is not a SmartTAR archive:`r`n$($script:selectedPath)" 'Invalid archive selection' ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Start-WorkerOperation 'Verify' $script:selectedPath $txtTarget.Text 'Hybrid' $false
}

$btnCompress.Add_Click({ Execute-Compress })
$btnExtract.Add_Click({ Execute-Extract })
$btnVerify.Add_Click({ Execute-Verify })

$form.Add_FormClosing({
    try {
        if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
            $confirm = Show-Message 'An operation is still running. Stop it and close?' 'Operation running' ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo)
            if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
                $_.Cancel = $true
                return
            }
            try { $script:currentProcess.Kill() } catch {}
        }
    }
    finally {
        $fNormal.Dispose()
        $fBold.Dispose()
        $fItalic.Dispose()
    }
})

[System.Windows.Forms.Application]::Run($form)