# ============================================================================
# SmartTAR STAR 1.0 Beta 1 Fix 5c - Readable Build
# Root Preserving Temp-List Planner - XZ9 / ZSTD19 / STORE
# Powered by Windows tar.exe / bsdtar only
#
# This build is based on the successful Fix5c experiment:
#   - Source files are NOT copied into staging folders.
#   - File blocks are created from temporary UTF-8-no-BOM list files.
#   - Temporary list files are NOT stored inside the .star archive.
#   - Directory structure is stored via a tiny folder-only staging tree.
#   - Extraction keeps the stable original root-preserving model:
#       outer TEMP -> payload TEMP -> Copy-PayloadToFinalDestination
#
# Modes:
#   Hybrid   = structure STORE + compressible XZ9 + diskimage ZSTD19 + stored STORE
#   Smart    = structure STORE + text/unknown XZ9 + binary/exe/diskimage ZSTD19 + media/archive STORE
#   Solid    = structure STORE + one solid-files block auto XZ9/ZSTD19
#   Smart XZ = structure STORE + all non-stored file groups XZ9 + media/archive STORE
#   Store    = structure STORE + one store-files block
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================================
# 01. Console handling
# ============================================================================
if (-not ("SmartTarConsoleWindow" -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SmartTarConsoleWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
}

$consolePtr = [SmartTarConsoleWindow]::GetConsoleWindow()
if ($consolePtr -ne [IntPtr]::Zero) {
    [SmartTarConsoleWindow]::ShowWindow($consolePtr, 0) | Out-Null
}
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
# 02. Generic helpers
# ============================================================================
function Is-Blank {
    param([string]$Text)
    return [string]::IsNullOrWhiteSpace($Text)
}

function New-Point {
    param([int]$X,[int]$Y)
    return [System.Drawing.Point]::new($X,$Y)
}

function New-Size {
    param([int]$W,[int]$H)
    return [System.Drawing.Size]::new($W,$H)
}

function New-UiObject {
    param([string]$Type,[hashtable]$Props)
    $obj = New-Object $Type
    foreach($key in $Props.Keys){ $obj.$key = $Props[$key] }
    return $obj
}

function Normalize-ArchiveSourcePath {
    param([string]$Path)

    if(Is-Blank $Path){ return "" }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)

    if($full.TrimEnd('\','/') -ieq $root.TrimEnd('\','/')){ return $root }
    return $full.TrimEnd('\','/')
}

function Get-NormalizedFullPath {
    param([string]$Path)
    if(Is-Blank $Path){ return "" }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Format-Bytes {
    param([int64]$Bytes)

    if($Bytes -ge 1GB){ return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if($Bytes -ge 1MB){ return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if($Bytes -ge 1KB){ return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

function Get-ErrorDetails {
    param($ErrorRecord)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Message:") | Out-Null
    $lines.Add([string]$ErrorRecord.Exception.Message) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Exception type:") | Out-Null
    $lines.Add([string]$ErrorRecord.Exception.GetType().FullName) | Out-Null

    if($ErrorRecord.InvocationInfo){
        $lines.Add("") | Out-Null
        $lines.Add("Position:") | Out-Null
        $lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage) | Out-Null
    }

    if($ErrorRecord.ScriptStackTrace){
        $lines.Add("") | Out-Null
        $lines.Add("Script stack trace:") | Out-Null
        $lines.Add([string]$ErrorRecord.ScriptStackTrace) | Out-Null
    }

    return ($lines -join "`r`n")
}

function Get-FileSHA256 {
    param([string]$Path)

    if(Is-Blank $Path){ throw "Cannot hash an empty path." }
    if(-not(Test-Path -LiteralPath $Path)){ throw "Cannot hash missing file: $Path" }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SourceSize {
    param([string]$Path)

    try {
        if(Is-Blank $Path){ return [int64]0 }

        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if(-not $item.PSIsContainer){ return [int64]$item.Length }

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
    param([string]$BasePath,[string]$Kind)

    $dir = [System.IO.Path]::GetDirectoryName($BasePath)
    if(Is-Blank $dir){ $dir = (Get-Location).Path }

    $name = [System.IO.Path]::GetFileName($BasePath)
    if(Is-Blank $name){ $name = "SmartTAR" }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    return (Join-Path $dir ("$name.$Kind.$stamp.txt"))
}

function Write-ReportFile {
    param([string]$Path,[string]$Text)

    try {
        $Text | Set-Content -LiteralPath $Path -Encoding UTF8
        return $true
    }
    catch {
        return $false
    }
}

function Write-Utf8NoBomLines {
    param([string]$Path,[string[]]$Lines)

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
}

# ============================================================================
# 03. Application state and UI constants
# ============================================================================
$cBg   = [System.Drawing.Color]::White
$cTxt  = [System.Drawing.ColorTranslator]::FromHtml("#2F4F4F")
$cGray = [System.Drawing.Color]::LightGray

$fNormal = [System.Drawing.Font]::new("Segoe UI",9)
$fBold   = [System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$fItalic = [System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Italic)

$scriptDir = if($PSScriptRoot){
    $PSScriptRoot
}elseif($MyInvocation.MyCommand.Path){
    Split-Path -Parent $MyInvocation.MyCommand.Path
}else{
    (Get-Location).Path
}
if(Is-Blank $scriptDir){ $scriptDir = (Get-Location).Path }

$tarPath = Join-Path $env:SystemRoot "System32\tar.exe"
if(-not(Test-Path -LiteralPath $tarPath)){
    $cmdTar = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if($cmdTar -and $cmdTar.Source){ $tarPath = $cmdTar.Source }
}

$script:selectedPath = ""
$script:selectedType = ""

# ============================================================================
# 04. UI helpers
# ============================================================================
function New-EcoLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 470,
        [int]$H = 20,
        [System.Drawing.Font]$Font = $fNormal,
        [System.Drawing.Color]$ForeColor = $cTxt
    )

    return New-UiObject "System.Windows.Forms.Label" @{
        Text      = $Text
        Location  = (New-Point $X $Y)
        Size      = (New-Size $W $H)
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
        [int]$W,
        [int]$H,
        [System.Drawing.Font]$Font = $fNormal,
        [System.Drawing.Color]$BackColor = $cBg,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::Black
    )

    $button = New-UiObject "System.Windows.Forms.Button" @{
        Text                    = $Text
        Location                = (New-Point $X $Y)
        Size                    = (New-Size $W $H)
        Font                    = $Font
        BackColor               = $BackColor
        ForeColor               = $ForeColor
        UseVisualStyleBackColor = $false
    }

    try {
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderSize = 1
        $button.FlatAppearance.BorderColor = $cGray
    } catch {}

    return $button
}

function New-EcoCheck {
    param([string]$Text,[int]$X,[int]$Y,[int]$W,[bool]$Checked=$true)

    return New-UiObject "System.Windows.Forms.CheckBox" @{
        Text      = $Text
        Location  = (New-Point $X $Y)
        Size      = (New-Size $W 22)
        Font      = $fNormal
        BackColor = $cBg
        ForeColor = $cTxt
        Checked   = $Checked
    }
}

function Msg {
    param(
        [string]$Message,
        [string]$Title = "SmartTAR STAR Fix 5c Readable",
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )

    return [System.Windows.Forms.MessageBox]::Show($Message,$Title,$Buttons,$Icon)
}

function Set-AppStatus {
    param([string]$Text,[System.Drawing.Color]$Color=[System.Drawing.Color]::DimGray)

    $lblStatus.Text = $Text
    $lblStatus.ForeColor = $Color
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Start-UiWork {
    $progressBar.Visible = $true
    $progressBar.MarqueeAnimationSpeed = 25
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Stop-UiWork {
    $progressBar.MarqueeAnimationSpeed = 0
    $progressBar.Visible = $false
    $form.Refresh()
}

# ============================================================================
# 05. TAR methods
# ============================================================================
function Get-TarMethods {
    return @(
        @{Name="store";  Display="STORE";  Extension=".tar";     CreateArgs=@("-cf"); Level=$null; Algorithm="store"},
        @{Name="gzip";   Display="GZIP";   Extension=".tar.gz";  CreateArgs=@("-czf"); Level=$null; Algorithm="gzip"},
        @{Name="bzip2";  Display="BZIP2";  Extension=".tar.bz2"; CreateArgs=@("-cjf"); Level=$null; Algorithm="bzip2"},
        @{Name="xz9";    Display="XZ9";    Extension=".tar.xz";  CreateArgs=@("--options","xz:compression-level=9","-cJf"); Level=9; Algorithm="xz"},
        @{Name="xz";     Display="XZ";     Extension=".tar.xz";  CreateArgs=@("-cJf"); Level=$null; Algorithm="xz"},
        @{Name="zstd19"; Display="ZSTD19"; Extension=".tar.zst"; CreateArgs=@("--zstd","--options","zstd:compression-level=19","-cf"); Level=19; Algorithm="zstd"}
    )
}

function Get-TarMethodByName {
    param([string]$Name)

    foreach($method in Get-TarMethods){
        if([string]$method.Name -eq $Name){ return $method }
    }
    return $null
}

function Invoke-Tar {
    param(
        [string]$TarPath,
        $TarArgs,
        [string]$FailMessage,
        [string]$WorkingDirectory = ""
    )

    $argList = @()
    foreach($arg in @($TarArgs)){ $argList += [string]$arg }

    if(Is-Blank $WorkingDirectory){
        $output = & $TarPath @argList 2>&1
    }else{
        Push-Location -LiteralPath $WorkingDirectory
        try { $output = & $TarPath @argList 2>&1 }
        finally { Pop-Location }
    }

    if($LASTEXITCODE -ne 0){
        $text = ($output | Out-String).Trim()
        if(Is-Blank $text){ $text = "No tar.exe output captured." }
        throw "$FailMessage tar.exe exit code: $LASTEXITCODE`r`n$text"
    }
}

function Invoke-TarList {
    param([string]$TarPath,[string]$ArchivePath)

    $null = & $TarPath @("-tf",$ArchivePath) 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ============================================================================
# 06. TAR list mode detection
# ============================================================================
function Get-ListModeCandidateArgs {
    param([string]$Mode,[string]$ListPath,[string]$RelativeListName)

    switch($Mode){
        "AtAbsolute" {
            return @{ Args=@("@$ListPath"); WorkingDirectory="" }
        }
        "AtRelative" {
            return @{
                Args=@("@$RelativeListName")
                WorkingDirectory=([System.IO.Path]::GetDirectoryName($ListPath))
            }
        }
        "DashT" {
            return @{ Args=@("-T",$ListPath); WorkingDirectory="" }
        }
        "FilesFrom" {
            return @{ Args=@("--files-from",$ListPath); WorkingDirectory="" }
        }
    }

    throw "Unknown list mode: $Mode"
}

function Test-OneListMode {
    param([string]$TarPath,[string]$Mode)

    $root = Join-Path $env:TEMP ("smarttar_listmode_" + [guid]::NewGuid().ToString("N"))
    $sample = Join-Path $root "sample"
    $extract = Join-Path $root "extract"

    New-Item -ItemType Directory -Path $sample,$extract -Force | Out-Null
    "list mode test" | Set-Content -LiteralPath (Join-Path $sample "sample.txt") -Encoding UTF8

    $listPath = Join-Path $root "list.txt"
    Write-Utf8NoBomLines $listPath @("sample.txt")

    $archivePath = Join-Path $root "test.tar"

    try {
        $listMode = Get-ListModeCandidateArgs $Mode $listPath "list.txt"
        $args = @("-cf",$archivePath,"-C",$sample) + $listMode.Args

        Invoke-Tar -TarPath $TarPath -TarArgs $args -FailMessage "List mode test failed." -WorkingDirectory $listMode.WorkingDirectory
        Invoke-Tar -TarPath $TarPath -TarArgs @("-xf",$archivePath,"-C",$extract) -FailMessage "List mode extraction test failed."

        return (Test-Path -LiteralPath (Join-Path $extract "sample.txt"))
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Select-TarListMode {
    param([string]$TarPath)

    foreach($mode in @("AtAbsolute","AtRelative","DashT","FilesFrom")){
        if(Test-OneListMode $TarPath $mode){ return $mode }
    }

    return ""
}

function Test-TarCapabilities {
    param([string]$TarPath,[string]$ListMode)

    $root = Join-Path $env:TEMP ("smarttar_cap_list_" + [guid]::NewGuid().ToString("N"))
    $sample = Join-Path $root "sample"
    $extract = Join-Path $root "extract"

    New-Item -ItemType Directory -Path $sample,$extract -Force | Out-Null
    "capability test" | Set-Content -LiteralPath (Join-Path $sample "sample.txt") -Encoding UTF8

    $listPath = Join-Path $root "list.txt"
    Write-Utf8NoBomLines $listPath @("sample.txt")

    $result = @{}

    foreach($method in Get-TarMethods){
        $name = [string]$method.Name
        $archivePath = Join-Path $root ("test" + [string]$method.Extension)
        $extractDir = Join-Path $extract $name
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        $ok = $false
        try {
            $listModeInfo = Get-ListModeCandidateArgs $ListMode $listPath "list.txt"
            $args = @()
            $args += $method.CreateArgs
            $args += $archivePath
            $args += "-C"
            $args += $sample
            $args += $listModeInfo.Args

            Invoke-Tar -TarPath $TarPath -TarArgs $args -FailMessage "Capability test failed." -WorkingDirectory $listModeInfo.WorkingDirectory
            Invoke-Tar -TarPath $TarPath -TarArgs @("-xf",$archivePath,"-C",$extractDir) -FailMessage "Capability extract test failed."

            if(Test-Path -LiteralPath (Join-Path $extractDir "sample.txt")){ $ok = $true }
        }
        catch {
            $ok = $false
        }

        $result[$name] = $ok
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    return $result
}

# ============================================================================
# 07. Method selection
# ============================================================================
function Select-BestCompressedMethod {
    param([hashtable]$Capabilities)

    foreach($name in @("xz9","xz","bzip2","gzip","store")){
        if($Capabilities.ContainsKey($name) -and $Capabilities[$name]){
            return Get-TarMethodByName $name
        }
    }

    throw "No usable tar method was found."
}

function Select-XzOrBest {
    param([hashtable]$Capabilities)

    if($Capabilities.ContainsKey("xz9") -and $Capabilities["xz9"]){ return Get-TarMethodByName "xz9" }
    if($Capabilities.ContainsKey("xz") -and $Capabilities["xz"]){ return Get-TarMethodByName "xz" }
    return Select-BestCompressedMethod $Capabilities
}

function Select-ZstdOrBest {
    param([hashtable]$Capabilities)

    if($Capabilities.ContainsKey("zstd19") -and $Capabilities["zstd19"]){ return Get-TarMethodByName "zstd19" }
    return Select-BestCompressedMethod $Capabilities
}

function Select-StoreMethod {
    param([hashtable]$Capabilities)

    if($Capabilities.ContainsKey("store") -and $Capabilities["store"]){ return Get-TarMethodByName "store" }
    return Select-BestCompressedMethod $Capabilities
}

# ============================================================================
# 08. File classification and grouping
# ============================================================================
function Get-SmartGroupName {
    param([string]$FilePath)

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    $textExt = @(".txt",".csv",".json",".xml",".log",".ini",".cfg",".md",".sql",".ps1",".bat",".cmd",".html",".htm",".css",".js",".ts",".yml",".yaml",".toml",".reg",".inf",".srt",".vtt")
    $binaryExt = @(".bin",".dat",".db",".sqlite",".sqlite3",".pak",".asset",".res",".idx",".map",".cache",".blob")
    $executableExt = @(".exe",".dll",".sys",".ocx",".msi",".msp",".scr",".com",".drv",".efi")
    $diskImageExt = @(".iso",".img",".vhd",".vhdx")
    $mediaExt = @(".jpg",".jpeg",".png",".gif",".webp",".bmp",".tif",".tiff",".ico",".mp3",".wav",".flac",".aac",".ogg",".wma",".mp4",".mkv",".avi",".mov",".wmv",".webm",".pdf",".heic",".avif")
    $archiveExt = @(".zip",".7z",".rar",".gz",".bz2",".xz",".zst",".tar",".tgz",".tbz2",".txz",".cab",".jar",".war",".ear",".sarc",".star",".docx",".xlsx",".pptx",".odt",".ods",".odp",".apk",".epub",".vsix",".nupkg")

    if($textExt -contains $ext){ return "text" }
    if($diskImageExt -contains $ext){ return "diskimage" }
    if($binaryExt -contains $ext){ return "binary" }
    if($executableExt -contains $ext){ return "executable" }
    if($mediaExt -contains $ext){ return "media" }
    if($archiveExt -contains $ext){ return "archives" }
    return "unknown"
}

function Get-ModeGroupName {
    param([string]$Mode,[string]$SmartGroup)

    if($Mode -eq "Solid"){ return "solidfiles" }
    if($Mode -eq "Store"){ return "storefiles" }

    if($Mode -eq "SmartXZ"){ return $SmartGroup }

    if($Mode -eq "Hybrid"){
        if($SmartGroup -eq "diskimage"){ return "diskimage" }
        if($SmartGroup -eq "media" -or $SmartGroup -eq "archives"){ return "stored" }
        return "compressible"
    }

    return $SmartGroup
}

function Get-RelativePathFromBase {
    param([string]$BasePath,[string]$FullPath)

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\','/')
    $pathFull = [System.IO.Path]::GetFullPath($FullPath)
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar

    if($pathFull.ToLowerInvariant().StartsWith($prefix.ToLowerInvariant())){
        return $pathFull.Substring($prefix.Length)
    }

    return (Split-Path -Leaf $pathFull)
}

function Convert-ToTarListPath {
    param([string]$Path)
    return ([string]$Path).Replace('\','/')
}

function Get-SortedSourceFiles {
    param(
        $SourceItem,
        [string]$Source,
        [string]$BaseRoot = ""
    )

    if(-not $SourceItem.PSIsContainer){
        return @($SourceItem)
    }

    if(Is-Blank $BaseRoot){
        return @(
            Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object `
                    @{Expression={$_.FullName.ToLowerInvariant()}},
                    @{Expression={$_.FullName}}
        )
    }

    return @(
        Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object `
                @{Expression={(Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant()}},
                @{Expression={Get-RelativePathFromBase $BaseRoot $_.FullName}}
    )
}

function Get-SourceProfile {
    param($SourceItem,[string]$Source)

    $profile = @{
        text=[int64]0; binary=[int64]0; executable=[int64]0; diskimage=[int64]0
        media=[int64]0; archives=[int64]0; unknown=[int64]0; files=0
    }

    foreach($file in (Get-SortedSourceFiles $SourceItem $Source)){
        $group = Get-SmartGroupName $file.FullName
        $profile[$group] = [int64]$profile[$group] + [int64]$file.Length
        $profile.files++
    }

    return $profile
}

# ============================================================================
# 09. Group model
# ============================================================================
function Select-AutoSolidMethod {
    param([hashtable]$Capabilities,[hashtable]$Profile)

    $zstd = Select-ZstdOrBest $Capabilities
    $xz = Select-XzOrBest $Capabilities

    if($Capabilities.ContainsKey("zstd19") -and $Capabilities["zstd19"]){
        $binaryLike = [int64]$Profile.binary + [int64]$Profile.executable + [int64]$Profile.diskimage
        if($binaryLike -gt [int64]$Profile.text){ return $zstd }
    }

    return $xz
}

function New-GroupInfo {
    param([string]$Name,[hashtable]$Method,[string]$Reason)

    return @{
        Name=$Name
        Method=$Method
        Reason=$Reason
        FileCount=0
        DirCount=0
        Bytes=[int64]0
        Entries=(New-Object System.Collections.Generic.List[string])
    }
}

function New-ArchiveGroups {
    param([string]$Mode,[hashtable]$Capabilities,[hashtable]$Profile)

    $store = Select-StoreMethod $Capabilities
    $xz = Select-XzOrBest $Capabilities
    $zstd = Select-ZstdOrBest $Capabilities

    $groups = [ordered]@{}
    $groups["structure"] = New-GroupInfo "structure" $store "Directory structure from tiny folder-only staging."

    switch($Mode){
        "Store" {
            $groups["storefiles"] = New-GroupInfo "storefiles" $store "Store file block from temporary list."
        }
        "Solid" {
            $groups["solidfiles"] = New-GroupInfo "solidfiles" (Select-AutoSolidMethod $Capabilities $Profile) "Solid file block from temporary list."
        }
        "SmartXZ" {
            $groups["text"]       = New-GroupInfo "text"       $xz    "Smart XZ: text data uses XZ9 when available."
            $groups["binary"]     = New-GroupInfo "binary"     $xz    "Smart XZ: binary data uses XZ9 when available."
            $groups["executable"] = New-GroupInfo "executable" $xz    "Smart XZ: executable data uses XZ9 when available."
            $groups["diskimage"]  = New-GroupInfo "diskimage"  $xz    "Smart XZ: disk image data uses XZ9 when available."
            $groups["media"]      = New-GroupInfo "media"      $store "Media is usually already compressed, stored."
            $groups["archives"]   = New-GroupInfo "archives"   $store "Archive-like data is usually already compressed, stored."
            $groups["unknown"]    = New-GroupInfo "unknown"    $xz    "Smart XZ: unknown data uses XZ9 when available."
        }
        "Smart" {
            $groups["text"]       = New-GroupInfo "text"       $xz    "Text-like data prefers XZ9 when available."
            $groups["binary"]     = New-GroupInfo "binary"     $zstd  "Binary data prefers ZSTD19 when available."
            $groups["executable"] = New-GroupInfo "executable" $zstd  "Executable data prefers ZSTD19 when available."
            $groups["diskimage"]  = New-GroupInfo "diskimage"  $zstd  "Disk image data prefers ZSTD19 when available."
            $groups["media"]      = New-GroupInfo "media"      $store "Media is usually already compressed, stored."
            $groups["archives"]   = New-GroupInfo "archives"   $store "Archive-like data is usually already compressed, stored."
            $groups["unknown"]    = New-GroupInfo "unknown"    $xz    "Unknown data prefers XZ9 when available."
        }
        default {
            $groups["compressible"] = New-GroupInfo "compressible" $xz    "General compressible block prefers XZ9 when available."
            $groups["diskimage"]    = New-GroupInfo "diskimage"    $zstd  "Disk image data prefers ZSTD19 when available."
            $groups["stored"]       = New-GroupInfo "stored"       $store "Media and archive-like data is stored."
        }
    }

    return $groups
}

# ============================================================================
# 10. Planning: folder-only structure + temporary file lists
# ============================================================================
function Add-EntryToGroup {
    param([hashtable]$Group,[string]$RelativePath,[bool]$IsDirectory,[int64]$Bytes=0)

    $tarPath = Convert-ToTarListPath $RelativePath
    $Group.Entries.Add($tarPath) | Out-Null

    if($IsDirectory){
        $Group.DirCount = [int]$Group.DirCount + 1
    }else{
        $Group.FileCount = [int]$Group.FileCount + 1
        $Group.Bytes = [int64]$Group.Bytes + $Bytes
    }
}

function Create-DirInStructureStage {
    param([string]$RelativePath,[string]$StructureStage)

    New-Item -ItemType Directory -Path (Join-Path $StructureStage $RelativePath) -Force | Out-Null
}

function Plan-Directories {
    param($SourceItem,[string]$Source,[string]$BaseRoot,[hashtable]$Groups,[string]$StructureStage)

    if(-not $SourceItem.PSIsContainer){ return }

    $rootRel = Get-RelativePathFromBase $BaseRoot $Source
    Create-DirInStructureStage $rootRel $StructureStage
    $Groups["structure"].DirCount = [int]$Groups["structure"].DirCount + 1

    Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object `
            @{Expression={(Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant()}},
            @{Expression={Get-RelativePathFromBase $BaseRoot $_.FullName}} |
        ForEach-Object {
            $rel = Get-RelativePathFromBase $BaseRoot $_.FullName
            Create-DirInStructureStage $rel $StructureStage
            $Groups["structure"].DirCount = [int]$Groups["structure"].DirCount + 1
        }
}

function Plan-Files {
    param($SourceItem,[string]$Source,[string]$BaseRoot,[string]$Mode,[hashtable]$Groups)

    foreach($file in (Get-SortedSourceFiles $SourceItem $Source $BaseRoot)){
        $relative = Get-RelativePathFromBase $BaseRoot $file.FullName
        $smartGroup = Get-SmartGroupName $file.FullName
        $groupName = Get-ModeGroupName $Mode $smartGroup

        if(-not $Groups.Contains($groupName)){
            throw "Internal grouping error. Group '$groupName' does not exist for mode '$Mode'."
        }

        Add-EntryToGroup $Groups[$groupName] $relative $false ([int64]$file.Length)
    }
}

# ============================================================================
# 11. Block creation
# ============================================================================
function Create-BlockFromStage {
    param([string]$TarPath,[string]$StagePath,[string]$BlockPath,[hashtable]$Method)

    $args = @()
    $args += $Method.CreateArgs
    $args += $BlockPath
    $args += "-C"
    $args += $StagePath
    $args += "."

    Invoke-Tar -TarPath $TarPath -TarArgs $args -FailMessage "Block creation from structure stage failed: $BlockPath."
}

function Create-BlockFromList {
    param(
        [string]$TarPath,
        [string]$SourceParent,
        [string]$BlockPath,
        [string[]]$RelativeEntries,
        [hashtable]$Method,
        [string]$ListFilePath,
        [string]$ListMode
    )

    $cleanEntries = @(
        $RelativeEntries |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    if($cleanEntries.Count -lt 1){ throw "No entries provided for block list." }

    Write-Utf8NoBomLines $ListFilePath $cleanEntries

    $listModeInfo = Get-ListModeCandidateArgs $ListMode $ListFilePath ([System.IO.Path]::GetFileName($ListFilePath))

    $args = @()
    $args += $Method.CreateArgs
    $args += $BlockPath
    $args += "-C"
    $args += $SourceParent
    $args += $listModeInfo.Args

    Invoke-Tar `
        -TarPath $TarPath `
        -TarArgs $args `
        -FailMessage "Block creation from temporary file list failed: $BlockPath." `
        -WorkingDirectory $listModeInfo.WorkingDirectory
}

function Build-Blocks {
    param(
        [string]$TarPath,
        [string]$SourceParent,
        [hashtable]$Groups,
        [string]$BlocksDir,
        [string]$ListsDir,
        [string]$ListMode,
        [string]$StructureStage
    )

    $blocks = @()
    $index = 1

    foreach($groupName in $Groups.Keys){
        $group = $Groups[$groupName]
        $hasContent = (([int]$group.FileCount -gt 0) -or ([int]$group.DirCount -gt 0))
        if(-not $hasContent){ continue }

        $id = "{0:D6}" -f $index
        $method = $group.Method
        $blockName = "$id`_$($group.Name)$($method.Extension)"
        $blockPath = Join-Path $BlocksDir $blockName

        $tempListSize = [int64]0
        $tempListSha = ""
        $listPolicy = ""

        if($group.Name -eq "structure"){
            Create-BlockFromStage `
                -TarPath $TarPath `
                -StagePath $StructureStage `
                -BlockPath $blockPath `
                -Method $method
        }else{
            $listName = "$id`_$($group.Name).txt"
            $listPath = Join-Path $ListsDir $listName

            Create-BlockFromList `
                -TarPath $TarPath `
                -SourceParent $SourceParent `
                -BlockPath $blockPath `
                -RelativeEntries ([string[]]$group.Entries.ToArray()) `
                -Method $method `
                -ListFilePath $listPath `
                -ListMode $ListMode

            $listItem = Get-Item -LiteralPath $listPath
            $tempListSize = [int64]$listItem.Length
            $tempListSha = Get-FileSHA256 $listPath
            $listPolicy = "temp-list-only"
        }

        $blockItem = Get-Item -LiteralPath $blockPath

        $blocks += [ordered]@{
            id                = $id
            group             = [string]$group.Name
            path              = "blocks/$blockName"
            container         = "tar"
            compression       = [string]$method.Algorithm
            method            = [string]$method.Name
            display           = [string]$method.Display
            level             = $method.Level
            extension         = [string]$method.Extension
            reason            = [string]$group.Reason
            fileCount         = [int]$group.FileCount
            dirCount          = [int]$group.DirCount
            entryCount        = ([int]$group.FileCount + [int]$group.DirCount)
            sourceBytes       = [int64]$group.Bytes
            sizeBytes         = [int64]$blockItem.Length
            sha256            = Get-FileSHA256 $blockPath
            listMode          = $ListMode
            listPolicy        = $listPolicy
            tempListSizeBytes = $tempListSize
            tempListSha256    = $tempListSha
        }

        $index++
    }

    return $blocks
}

function Write-Manifest {
    param([string]$Path,$Data)
    $Data | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Build-Manifest {
    param(
        [string]$Source,
        $SourceItem,
        [string]$SourceLeaf,
        [string]$Mode,
        [string]$ListMode,
        [hashtable]$CapabilityMap,
        [hashtable]$Profile,
        $BlockList
    )

    $name = $SourceLeaf
    if($SourceLeaf -eq "."){
        $name = Split-Path -Leaf ($Source -replace '[\/]+$','')
    }

    $type = if($SourceItem.PSIsContainer){ "Folder" }else{ "File" }

    return [ordered]@{
        format          = "STAR"
        formatVersion   = 2
        tool            = "SmartTAR"
        version         = 24
        toolVersion     = "1.0-beta1-fix5c-readable-temp-lists-folder-stage"
        createdUtc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        engine          = "Windows tar.exe"
        model           = "root-preserving-temp-lists-folder-stage-readable-fix5c"
        compressionMode = $Mode
        listMode        = $ListMode
        sourceName      = $name
        sourceType      = $type
        sourceBytes     = Get-SourceSize $Source
        rootRule        = "No deduplication. Every block contains the selected root prefix."
        creationMode    = "temp-lists-for-file-blocks-folder-only-stage-for-structure"
        deterministicMetadata = [ordered]@{
            enabled      = $false
            timestampUtc = "not-normalized"
            scope        = "none"
            note         = "Temp-list mode does not modify source timestamps."
        }
        capabilities = [ordered]@{
            store  = [bool]$CapabilityMap.store
            gzip   = [bool]$CapabilityMap.gzip
            bzip2  = [bool]$CapabilityMap.bzip2
            xz9    = [bool]$CapabilityMap.xz9
            xz     = [bool]$CapabilityMap.xz
            zstd19 = [bool]$CapabilityMap.zstd19
        }
        sourceProfile = $Profile
        blocks        = @($BlockList)
    }
}

# ============================================================================
# 12. Archive safety and extraction helpers
# ============================================================================
function Read-OuterManifest {
    param([string]$OuterRoot)

    $manifestPath = Join-Path $OuterRoot "manifest.json"
    if(-not(Test-Path -LiteralPath $manifestPath)){ throw "manifest.json was not found." }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.format -ne "STAR" -and $manifest.format -ne "SARC" -and $manifest.format -ne "SmartTarArc"){
        throw "Invalid archive format. Expected STAR, SARC or SmartTarArc."
    }

    return $manifest
}

function Test-RelativePathSafe {
    param([string]$PathText)

    if(Is-Blank $PathText){ return $false }

    $path = ([string]$PathText).Replace('\','/')
    if($path -eq "." -or $path -eq "./"){ return $true }
    if($path -match '^[a-zA-Z]:'){ return $false }
    if($path.StartsWith("/") -or $path.StartsWith("//")){ return $false }

    foreach($part in @($path.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne "." })){
        if($part -eq ".."){ return $false }
    }

    return $true
}

function Resolve-SafeBlockPath {
    param([string]$OuterRoot,[string]$RelativeBlockPath)

    if(-not(Test-RelativePathSafe $RelativeBlockPath)){
        throw "Unsafe block path: $RelativeBlockPath"
    }

    return (Join-Path $OuterRoot ($RelativeBlockPath -replace '/', [string][System.IO.Path]::DirectorySeparatorChar))
}

function Test-ArchiveEntriesSafe {
    param([string]$TarPath,[string]$ArchivePath)

    $entries = & $TarPath @("-tf",$ArchivePath) 2>&1
    if($LASTEXITCODE -ne 0){
        $text = ($entries | Out-String).Trim()
        throw "Cannot list TAR block: $ArchivePath`r`n$text"
    }

    foreach($entry in $entries){
        if(-not(Test-RelativePathSafe ([string]$entry))){
            throw "Unsafe path inside TAR block: $entry"
        }
    }

    return @($entries)
}

function Get-ArchiveBaseNameWithoutSmartExtension {
    param([string]$ArchivePath)

    $name = [System.IO.Path]::GetFileName($ArchivePath)
    if($name -match '^(.*)\.sarc\.tar$'){ return $matches[1] }
    if($name -match '^(.*)\.star$'){ return $matches[1] }
    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}

function Get-ArchiveRootName {
    param($Manifest,[string]$ArchivePath)

    $sourceName = [string]$Manifest.sourceName
    if(-not(Is-Blank $sourceName)){ return $sourceName }
    return (Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath)
}

function Copy-DirectoryContents {
    param([string]$SourceRoot,[string]$DestinationRoot)

    if(-not(Test-Path -LiteralPath $SourceRoot)){ return }
    if(-not(Test-Path -LiteralPath $DestinationRoot)){
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $target = Join-Path $DestinationRoot $_.Name

        if($_.PSIsContainer){
            if(-not(Test-Path -LiteralPath $target)){
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            }
            Copy-DirectoryContents -SourceRoot $_.FullName -DestinationRoot $target
        }else{
            $targetDir = Split-Path -Parent $target
            if(-not(Test-Path -LiteralPath $targetDir)){
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Copy-PayloadToFinalDestination {
    param($Manifest,[string]$PayloadRoot,[string]$DestinationParent,[string]$ArchivePath)

    $rootName = Get-ArchiveRootName $Manifest $ArchivePath
    $sourceType = [string]$Manifest.sourceType

    if($sourceType -eq "Folder" -and -not(Is-Blank $rootName)){
        $finalRoot = Join-Path $DestinationParent $rootName
        if(-not(Test-Path -LiteralPath $finalRoot)){
            New-Item -ItemType Directory -Path $finalRoot -Force | Out-Null
        }

        $rootInPayload = Join-Path $PayloadRoot $rootName
        if(Test-Path -LiteralPath $rootInPayload){
            Copy-DirectoryContents -SourceRoot $rootInPayload -DestinationRoot $finalRoot
        }else{
            Copy-DirectoryContents -SourceRoot $PayloadRoot -DestinationRoot $finalRoot
        }
        return
    }

    Copy-DirectoryContents -SourceRoot $PayloadRoot -DestinationRoot $DestinationParent
}

function Extract-Blocks {
    param([string]$TarPath,[string]$OuterRoot,$Blocks,[string]$DestinationFolder)

    foreach($block in @($Blocks)){
        $blockPath = Resolve-SafeBlockPath $OuterRoot ([string]$block.path)
        if(-not(Test-Path -LiteralPath $blockPath)){
            throw "Block missing: $($block.path)"
        }

        if($block.sha256){
            $actualHash = Get-FileSHA256 $blockPath
            if($actualHash -ne ([string]$block.sha256).ToLowerInvariant()){
                throw "Block SHA256 mismatch: $($block.path)"
            }
        }

        [void](Test-ArchiveEntriesSafe $TarPath $blockPath)
        Invoke-Tar $TarPath @("-xf",$blockPath,"-C",$DestinationFolder) "Block extraction failed: $($block.path)."
    }
}

# ============================================================================
# 13. Verify and reporting
# ============================================================================
function Get-UsedMethodReport {
    param($Blocks)

    $methodMap = @{}
    foreach($block in @($Blocks)){
        $key = "{0}/{1}" -f ([string]$block.display),([string]$block.compression)
        if(-not $methodMap.ContainsKey($key)){ $methodMap[$key] = 0 }
        $methodMap[$key]++
    }

    if($methodMap.Count -gt 0){
        return (($methodMap.Keys | Sort-Object | ForEach-Object { "{0} x{1}" -f $_,$methodMap[$_] }) -join ", ")
    }

    return "n/a"
}

function Verify-SmartArchive {
    param([string]$TarPath,[string]$ArchivePath)

    if(-not(Test-Path -LiteralPath $ArchivePath)){ throw "Archive path does not exist." }

    $work = Join-Path $env:TEMP ("smarttar_verify_" + [guid]::NewGuid().ToString("N"))
    $outer = Join-Path $work "outer"
    New-Item -ItemType Directory -Path $outer -Force | Out-Null

    try {
        Invoke-Tar $TarPath @("-xf",$ArchivePath,"-C",$outer) "Outer .star verification failed."
        $manifest = Read-OuterManifest $outer
        $blocks = @($manifest.blocks)

        $ok = 0
        $fail = 0
        $total = [int64]0
        $lines = @()

        foreach($block in $blocks){
            $blockPath = Resolve-SafeBlockPath $outer ([string]$block.path)

            if(-not(Test-Path -LiteralPath $blockPath)){
                $fail++
                $lines += "MISSING: $($block.path)"
                continue
            }

            $listed = $true
            try { [void](Test-ArchiveEntriesSafe $TarPath $blockPath) }
            catch { $listed = $false }

            $hashOk = $true
            if($block.sha256){
                $hashOk = ((Get-FileSHA256 $blockPath) -eq ([string]$block.sha256).ToLowerInvariant())
            }

            $size = [int64](Get-Item -LiteralPath $blockPath).Length
            $total += $size

            if($listed -and $hashOk){
                $ok++
                $status = "OK"
            }else{
                $fail++
                $status = "FAIL"
            }

            $lines += ("  {0} | {1} | {2} | {3} | {4}" -f $block.id,$block.group,$block.display,$status,(Format-Bytes $size))
        }

        $verificationStatus = if($fail){ "Archive verification PARTIAL / FAILED" }else{ "Archive verification OK" }
        $used = Get-UsedMethodReport $blocks
        $archiveBytes = [int64](Get-Item -LiteralPath $ArchivePath).Length

        return @"
$verificationStatus

Format: $($manifest.format)
Tool: $($manifest.tool)
Version: $($manifest.toolVersion)
Model: $($manifest.model)
Mode: $($manifest.compressionMode)
List mode: $($manifest.listMode)
Creation mode: $($manifest.creationMode)
Root rule: $($manifest.rootRule)
Used methods: $used
Deterministic metadata: no - temp-list source-safe mode
Blocks: $($blocks.Count)
Blocks OK: $ok
Blocks failed: $fail
Source size declared: $(Format-Bytes ([int64]$manifest.sourceBytes))
Archive size: $(Format-Bytes $archiveBytes)
Internal block bytes: $(Format-Bytes $total)

Blocks:
$($lines -join "`r`n")
"@
    }
    finally {
        if(Test-Path -LiteralPath $work){
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ArchiveSummary {
    param([string]$TarPath,[string]$ArchivePath,[string]$SourcePath)

    $sourceBytes = Get-SourceSize $SourcePath
    $archiveBytes = [int64](Get-Item -LiteralPath $ArchivePath).Length

    $ratio = "n/a"
    $saved = "n/a"
    if($sourceBytes -gt 0 -and $archiveBytes -gt 0){
        $ratio = "{0:N2} %" -f (($archiveBytes / $sourceBytes) * 100)
        $saved = "{0:N2} %" -f ((1 - ($archiveBytes / $sourceBytes)) * 100)
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
# 14. Core operations
# ============================================================================
function Compress-SmartArchive {
    param([string]$TarPath,[string]$Source,[string]$Destination,[string]$Mode)

    if(-not(Test-Path -LiteralPath $TarPath)){ throw "tar.exe was not found." }
    if(-not(Test-Path -LiteralPath $Source)){ throw "Source path does not exist." }
    if(Test-Path -LiteralPath $Destination){ Remove-Item -LiteralPath $Destination -Force }
    if(Is-Blank $Mode){ $Mode = "Hybrid" }
    if($Mode -notin @("Solid","Hybrid","Smart","SmartXZ","Store")){ $Mode = "Hybrid" }

    Set-AppStatus "Detecting TAR list mode..." ([System.Drawing.Color]::DarkOrange)
    $listMode = Select-TarListMode $TarPath
    if(Is-Blank $listMode){
        throw "No usable tar file-list mode was found. Tested: @absolute, @relative, -T, --files-from."
    }

    Set-AppStatus "Checking TAR capabilities with list mode $listMode..." ([System.Drawing.Color]::DarkOrange)
    $capabilities = Test-TarCapabilities $TarPath $listMode
    if(-not $capabilities.store){
        throw "No usable tar store method with list mode $listMode was found."
    }

    $Source = Normalize-ArchiveSourcePath $Source

    $work = Join-Path $env:TEMP ("smarttar_temp_lists_" + [guid]::NewGuid().ToString("N"))
    $blocksDir = Join-Path $work "blocks"
    $listsDir = Join-Path $work "lists"
    $structureStage = Join-Path $work "structure_stage"

    New-Item -ItemType Directory -Path $work,$blocksDir,$listsDir,$structureStage -Force | Out-Null

    try {
        $sourceItem = Get-Item -LiteralPath $Source -Force
        $sourceParent = Split-Path -Parent $Source
        $sourceLeaf = Split-Path -Leaf $Source

        if(Is-Blank $sourceParent){ $sourceParent = (Get-Location).Path }
        if(Is-Blank $sourceLeaf){ $sourceParent = $Source; $sourceLeaf = "." }

        Set-AppStatus "Analyzing source and planning groups..." ([System.Drawing.Color]::DarkOrange)
        $profile = Get-SourceProfile $sourceItem $Source
        $groups = New-ArchiveGroups $Mode $capabilities $profile

        Set-AppStatus "Planning: folder-only structure + temporary file lists..." ([System.Drawing.Color]::DarkOrange)
        Plan-Directories $sourceItem $Source $sourceParent $groups $structureStage
        Plan-Files $sourceItem $Source $sourceParent $Mode $groups

        Set-AppStatus "Creating internal blocks..." ([System.Drawing.Color]::DarkOrange)
        $blocks = Build-Blocks $TarPath $sourceParent $groups $blocksDir $listsDir $listMode $structureStage
        if($blocks.Count -lt 1){ throw "No blocks were created." }

        $manifest = Build-Manifest $Source $sourceItem $sourceLeaf $Mode $listMode $capabilities $profile $blocks
        Write-Manifest (Join-Path $work "manifest.json") $manifest

        Set-AppStatus "Creating outer .star container..." ([System.Drawing.Color]::DarkOrange)
        Invoke-Tar $TarPath @("-cf",$Destination,"-C",$work,"manifest.json","blocks") "Outer .star archive creation failed."

        if(-not(Test-Path -LiteralPath $Destination)){ throw "Output archive was not created." }
    }
    finally {
        if(Test-Path -LiteralPath $work){
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Extract-SmartArchive {
    param([string]$TarPath,[string]$ArchivePath,[string]$DestinationFolder)

    if(-not(Test-Path -LiteralPath $TarPath)){ throw "tar.exe was not found." }
    if(-not(Test-Path -LiteralPath $ArchivePath)){ throw "Archive path does not exist." }
    if(Is-Blank $DestinationFolder){ throw "Destination folder is empty." }
    if(-not(Test-Path -LiteralPath $DestinationFolder)){
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }

    $work = Join-Path $env:TEMP ("smarttar_extract_" + [guid]::NewGuid().ToString("N"))
    $outer = Join-Path $work "outer"
    $payload = Join-Path $work "payload"

    New-Item -ItemType Directory -Path $outer,$payload -Force | Out-Null

    try {
        Invoke-Tar $TarPath @("-xf",$ArchivePath,"-C",$outer) "Outer .star extraction failed."
        $manifest = Read-OuterManifest $outer

        Extract-Blocks $TarPath $outer @($manifest.blocks) $payload
        Copy-PayloadToFinalDestination $manifest $payload $DestinationFolder $ArchivePath
    }
    finally {
        if(Test-Path -LiteralPath $work){
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# 15. Path helpers
# ============================================================================
function Is-SmartArchivePath {
    param([string]$Path)
    if(Is-Blank $Path){ return $false }
    return ([System.IO.Path]::GetFileName($Path) -match '(?i)(\.star|\.sarc\.tar)$')
}

function Ensure-StarExtension {
    param([string]$Path)
    if(Is-Blank $Path){ return $Path }
    if($Path -match '(?i)(\.star|\.sarc\.tar)$'){ return $Path }
    return ($Path + ".star")
}

function Get-DefaultArchiveBaseName {
    param([string]$Path,[string]$Type)

    $leaf = Split-Path -Leaf (Normalize-ArchiveSourcePath $Path)
    if(Is-Blank $leaf){ return "archive_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss") }
    if($Type -eq "Folder"){ return $leaf }
    return [System.IO.Path]::GetFileNameWithoutExtension($leaf)
}

function Get-SelectedCompressionMode {
    $text = [string]$cmbMode.SelectedItem
    if($text -like "Smart XZ*"){ return "SmartXZ" }
    if($text -like "Smart*"){ return "Smart" }
    if($text -like "Solid*"){ return "Solid" }
    if($text -like "Store*"){ return "Store" }
    return "Hybrid"
}

function Set-DefaultTarget {
    if(Is-Blank $script:selectedPath){ return }

    $parent = Split-Path -Parent $script:selectedPath
    if(Is-Blank $parent){ $parent = $scriptDir }

    if($script:selectedType -eq "File" -and (Is-SmartArchivePath $script:selectedPath)){
        $txtTarget.Text = $parent
        return
    }

    $txtTarget.Text = Join-Path $parent ((Get-DefaultArchiveBaseName $script:selectedPath $script:selectedType) + ".star")
}

function Set-SelectedPath {
    param([string]$Path,[ValidateSet("File","Folder")][string]$Type)

    $script:selectedPath = $Path
    $script:selectedType = $Type
    $lblSelected.Text = "Selected: $script:selectedPath"

    if($Type -eq "File"){
        if(Is-SmartArchivePath $Path){
            $btnFile.BackColor = $cBg
            $btnArchive.BackColor = [System.Drawing.Color]::LightBlue
        }else{
            $btnFile.BackColor = [System.Drawing.Color]::LightBlue
            $btnArchive.BackColor = $cBg
        }
        $btnFolder.BackColor = $cBg
    }else{
        $btnFile.BackColor = $cBg
        $btnArchive.BackColor = $cBg
        $btnFolder.BackColor = [System.Drawing.Color]::LightBlue
    }

    Set-DefaultTarget
}

# ============================================================================
# 16. GUI construction
# ============================================================================
$form = New-UiObject "System.Windows.Forms.Form" @{
    Text            = "SmartTAR STAR Fix 5c - Temp Lists Readable"
    ClientSize      = (New-Size 505 475)
    StartPosition   = "CenterScreen"
    BackColor       = $cBg
    FormBorderStyle = "FixedSingle"
    MaximizeBox     = $false
    TopMost         = $false
}

$lblInput    = New-EcoLabel "1. Select input file or folder:" 20 20 -Font $fBold
$btnFile     = New-EcoButton "Add FILE" 20 48 150 30
$btnFolder   = New-EcoButton "Add FOLDER" 177 48 150 30
$btnArchive  = New-EcoButton "Add ARCHIVE" 334 48 151 30
$lblSelected = New-EcoLabel "Selected: none" 20 88 465 20 $fItalic ([System.Drawing.Color]::DimGray)

$lblTarget = New-EcoLabel "2. Destination archive / extraction parent folder:" 20 125 -Font $fBold
$txtTarget = New-UiObject "System.Windows.Forms.TextBox" @{
    Location  = (New-Point 20 153)
    Size      = (New-Size 395 23)
    Font      = $fNormal
    ReadOnly  = $true
    BackColor = $cBg
}
$btnTarget = New-EcoButton "..." 422 152 63 24

$lblMode = New-EcoLabel "3. Compression mode:" 20 195 -Font $fBold
$cmbMode = New-UiObject "System.Windows.Forms.ComboBox" @{
    Location      = (New-Point 20 223)
    Size          = (New-Size 465 24)
    Font          = $fNormal
    DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
}
[void]$cmbMode.Items.Add("Hybrid - temp lists, XZ9 + ZSTD19 + STORE")
[void]$cmbMode.Items.Add("Smart - temp lists, grouped blocks")
[void]$cmbMode.Items.Add("Solid - temp list solid-files + structure")
[void]$cmbMode.Items.Add("Smart XZ - temp lists, XZ9 blocks")
[void]$cmbMode.Items.Add("Store - temp list store-files + structure")
$cmbMode.SelectedIndex = 0

$lblInfo = New-EcoLabel "File blocks use temp lists; structure uses tiny folder-only staging." 20 252 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$btnCompress = New-EcoButton "COMPRESS" 20 287 150 42 $fBold ([System.Drawing.Color]::SeaGreen) ([System.Drawing.Color]::White)
$btnExtract = New-EcoButton "EXTRACT" 177 287 150 42 $fBold ([System.Drawing.Color]::SteelBlue) ([System.Drawing.Color]::White)
$btnVerify = New-EcoButton "VERIFY" 334 287 151 42 $fBold ([System.Drawing.Color]::DarkSlateGray) ([System.Drawing.Color]::White)
$chkOpenFolder = New-EcoCheck "Open output folder after success" 20 342 300 $true
$lblStatus = New-EcoLabel "Ready." 20 392 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$progressBar = New-UiObject "System.Windows.Forms.ProgressBar" @{
    Location              = (New-Point 20 435)
    Size                  = (New-Size 465 8)
    Style                 = [System.Windows.Forms.ProgressBarStyle]::Marquee
    MarqueeAnimationSpeed = 25
    Visible               = $false
}

$form.Controls.AddRange([System.Windows.Forms.Control[]]@(
    $lblInput,$btnFile,$btnFolder,$btnArchive,$lblSelected,
    $lblTarget,$txtTarget,$btnTarget,
    $lblMode,$cmbMode,$lblInfo,
    $btnCompress,$btnExtract,$btnVerify,
    $chkOpenFolder,$lblStatus,$progressBar
))

# ============================================================================
# 17. GUI events
# ============================================================================
$cmbMode.Add_SelectedIndexChanged({
    $mode = Get-SelectedCompressionMode
    if($mode -eq "Solid"){
        $lblInfo.Text = "Solid = structure STORE + one solid-files block via temp list."
    }elseif($mode -eq "SmartXZ"){
        $lblInfo.Text = "Smart XZ = non-stored file groups use XZ9 via temp lists."
    }elseif($mode -eq "Smart"){
        $lblInfo.Text = "Smart = text XZ9, binary/exe/diskimage ZSTD19, media/archive STORE."
    }elseif($mode -eq "Store"){
        $lblInfo.Text = "Store = structure STORE + one store-files block via temp list."
    }else{
        $lblInfo.Text = "Hybrid = compressible XZ9, diskimage ZSTD19, media/archive STORE."
    }
})

$btnFile.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select file"
    $dialog.Filter = "All files (*.*)|*.*"
    try {
        if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){
            Set-SelectedPath $dialog.FileName "File"
        }
    } finally { $dialog.Dispose() }
})

$btnFolder.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select folder to archive"
    try {
        if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){
            Set-SelectedPath (Normalize-ArchiveSourcePath $dialog.SelectedPath) "Folder"
        }
    } finally { $dialog.Dispose() }
})

$btnArchive.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select SmartTAR archive"
    $dialog.Filter = "SmartTAR Archive (*.star)|*.star|Legacy SmartTAR Archive (*.sarc.tar)|*.sarc.tar|All files (*.*)|*.*"
    try {
        if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){
            Set-SelectedPath $dialog.FileName "File"
        }
    } finally { $dialog.Dispose() }
})

$btnTarget.Add_Click({
    if($script:selectedType -eq "File" -and (Is-SmartArchivePath $script:selectedPath)){
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select extraction parent folder"
        try {
            if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){
                $txtTarget.Text = $dialog.SelectedPath
            }
        } finally { $dialog.Dispose() }
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Select destination archive"
    $dialog.Filter = "SmartTAR Archive (*.star)|*.star|Legacy SmartTAR Archive (*.sarc.tar)|*.sarc.tar|All files (*.*)|*.*"
    $dialog.DefaultExt = "star"
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    try {
        if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){
            $txtTarget.Text = Ensure-StarExtension $dialog.FileName
        }
    } finally { $dialog.Dispose() }
})

# ============================================================================
# 18. Execution handlers
# ============================================================================
function Execute-Compress {
    if(-not(Test-Path -LiteralPath $tarPath)){
        Msg "tar.exe was not found." "Missing TAR Engine" ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if(Is-Blank $script:selectedPath){
        Msg "Please select a file or folder first." "Missing Input" ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if(Is-Blank $txtTarget.Text){
        Msg "Please select destination archive path." "Missing Destination" ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $targetPath = Ensure-StarExtension ($txtTarget.Text.Trim('"'))
    $txtTarget.Text = $targetPath

    $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
    if(Is-Blank $targetDir){
        $targetDir = $scriptDir
        $targetPath = Join-Path $targetDir ([System.IO.Path]::GetFileName($targetPath))
        $txtTarget.Text = $targetPath
    }

    if(Test-Path -LiteralPath $targetPath){
        $confirm = Msg "Target archive already exists. Overwrite it?" "Overwrite Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo)
        if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){ return }
    }

    $mode = Get-SelectedCompressionMode
    Start-UiWork

    $success = $false
    $errorMessage = $null

    try {
        Compress-SmartArchive $tarPath $script:selectedPath $targetPath $mode
        $success = $true
    }
    catch {
        $errorMessage = Get-ErrorDetails $_
    }
    finally {
        Stop-UiWork
    }

    if($success){
        Set-AppStatus "Archive created successfully. Mode: $mode." ([System.Drawing.Color]::Green)
        $reportPath = Get-ReportPath $targetPath "create_report"

        try {
            $summary = Get-ArchiveSummary $tarPath $targetPath $script:selectedPath
            [void](Write-ReportFile $reportPath $summary)
            Msg "$summary`r`nReport saved:`r`n$reportPath" "Archive Summary" ([System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            $verifyError = Get-ErrorDetails $_
            [void](Write-ReportFile $reportPath $verifyError)
            Msg "Archive created, but verify failed:`r`n$verifyError`r`nReport saved:`r`n$reportPath" "Archive Created - Verify Failed" ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }

        if($chkOpenFolder.Checked){ explorer.exe "/select,`"$targetPath`"" }
        return
    }

    Set-AppStatus "Compression failed." ([System.Drawing.Color]::Red)
    Msg "Compression failed.`n`n$errorMessage" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Execute-Extract {
    if(Is-Blank $script:selectedPath){
        Msg "Please select a SmartTAR archive first." "Missing Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $destination = $txtTarget.Text.Trim('"')
    if(Is-Blank $destination){
        Msg "Please select extraction parent folder." "Missing Destination" ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if(-not(Test-Path -LiteralPath $destination)){
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
    }

    Start-UiWork
    $success = $false
    $errorMessage = $null

    try {
        Extract-SmartArchive $tarPath $script:selectedPath $destination
        $success = $true
    }
    catch {
        $errorMessage = Get-ErrorDetails $_
    }
    finally {
        Stop-UiWork
    }

    $reportPath = Get-ReportPath $script:selectedPath "extract_report"

    if($success){
        $text = "Archive extracted successfully.`r`nArchive: $($script:selectedPath)`r`nExtraction parent folder: $destination"
        [void](Write-ReportFile $reportPath $text)
        Msg "$text`r`nReport saved:`r`n$reportPath" "Extract Archive" ([System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if($chkOpenFolder.Checked){ explorer.exe "`"$destination`"" }
        return
    }

    [void](Write-ReportFile $reportPath "Extraction failed.`r`n`r`n$errorMessage")
    Msg "Extraction failed.`n`n$errorMessage`n`nReport saved:`n$reportPath" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Execute-Verify {
    if(Is-Blank $script:selectedPath -or $script:selectedType -ne "File" -or -not(Test-Path -LiteralPath $script:selectedPath)){
        Msg "Please select an existing .star archive." "Invalid Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Start-UiWork
    $success = $false
    $errorMessage = $null
    $summary = $null

    try {
        $summary = Verify-SmartArchive $tarPath $script:selectedPath
        $success = $true
    }
    catch {
        $errorMessage = Get-ErrorDetails $_
    }
    finally {
        Stop-UiWork
    }

    $reportPath = Get-ReportPath $script:selectedPath "verify_report"

    if($success){
        [void](Write-ReportFile $reportPath $summary)
        Msg "$summary`r`nReport saved:`r`n$reportPath" "Verify Archive" ([System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    [void](Write-ReportFile $reportPath "Verification failed.`r`n`r`n$errorMessage")
    Msg "Verification failed.`n`n$errorMessage`n`nReport saved:`n$reportPath" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

$btnCompress.Add_Click({ Execute-Compress })
$btnExtract.Add_Click({ Execute-Extract })
$btnVerify.Add_Click({ Execute-Verify })

$form.Add_FormClosing({
    $fNormal.Dispose()
    $fBold.Dispose()
    $fItalic.Dispose()
})

[System.Windows.Forms.Application]::Run($form)