# ============================================================================
# SmartTAR STAR 1.0 Beta 1
# Root Preserving Smart Hybrid Archive Tool
# Powered by Windows tar.exe / bsdtar only
#
# Build:
#   SmartTAR STAR 1.0 Beta 1 - Root Preserving Smart Hybrid v8.2
#
# Change in v8.2:
#   - GUI mode names cleaned up to exactly four user-facing modes:
#       Mode - Hybrid - recommended
#       Mode - Smart - grouped blocks
#       Mode - SmartXZ - grouped XZ blocks
#       Mode - Solid - one compressed block
#   - Removed Store as a user-facing mode.
#   - STORE remains an internal compression method for already-compressed data.
#   - Kept v8.1 VERIFY empty-selection fix.
#
# Core rules:
#   - NO folder-name deduplication.
#   - The selected root folder is preserved exactly.
#   - Every internal block contains the selected root prefix.
#   - Same-name child folders are valid content and must be restored.
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
if ($consolePtr -ne [IntPtr]::Zero) { [SmartTarConsoleWindow]::ShowWindow($consolePtr, 0) | Out-Null }
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
# 02. Generic helpers
# ============================================================================
function Is-Blank { param([string]$Text) return [string]::IsNullOrWhiteSpace($Text) }
function New-Point { param([int]$X,[int]$Y) return [System.Drawing.Point]::new($X,$Y) }
function New-Size { param([int]$W,[int]$H) return [System.Drawing.Size]::new($W,$H) }
function New-UiObject { param([string]$Type,[hashtable]$Props) $obj = New-Object $Type; foreach($k in $Props.Keys){$obj.$k=$Props[$k]}; return $obj }

function Normalize-ArchiveSourcePath {
    param([string]$Path)
    if (Is-Blank $Path) { return "" }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\','/') -ieq $root.TrimEnd('\','/')) { return $root }
    return $full.TrimEnd('\','/')
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
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
    if ($ErrorRecord.InvocationInfo) { $lines.Add("") | Out-Null; $lines.Add("Position:") | Out-Null; $lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage) | Out-Null }
    if ($ErrorRecord.ScriptStackTrace) { $lines.Add("") | Out-Null; $lines.Add("Script stack trace:") | Out-Null; $lines.Add([string]$ErrorRecord.ScriptStackTrace) | Out-Null }
    return ($lines -join "`r`n")
}

function Get-FileSHA256 {
    param([string]$Path)
    if (Is-Blank $Path) { throw "Cannot hash an empty path." }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Cannot hash missing file: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DirectorySize {
    param([string]$Path)
    try {
        if (Is-Blank $Path) { return [int64]0 }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [int64]$item.Length }
        $sum = [int64]0
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $sum += [int64]$_.Length }
        return $sum
    } catch { return [int64]0 }
}

function Get-FixedUtcTime { return [datetime]::SpecifyKind([datetime]"2000-01-01T00:00:00", [System.DateTimeKind]::Utc) }
function Get-FixedUtcText { return "2000-01-01T00:00:00Z" }

function Set-TreeTimestamp {
    param([string]$Path,[datetime]$Timestamp)
    if (Is-Blank $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.CreationTimeUtc = $Timestamp } catch {}
        try { $_.LastAccessTimeUtc = $Timestamp } catch {}
        try { $_.LastWriteTimeUtc = $Timestamp } catch {}
    }
    try {
        $root = Get-Item -LiteralPath $Path -Force
        $root.CreationTimeUtc = $Timestamp
        $root.LastAccessTimeUtc = $Timestamp
        $root.LastWriteTimeUtc = $Timestamp
    } catch {}
}

function Get-ReportPath {
    param([string]$BasePath,[string]$Kind)
    $dir = [System.IO.Path]::GetDirectoryName($BasePath)
    if (Is-Blank $dir) { $dir = (Get-Location).Path }
    $name = [System.IO.Path]::GetFileName($BasePath)
    if (Is-Blank $name) { $name = "SmartTAR" }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    return (Join-Path $dir ("$name.$Kind.$stamp.txt"))
}
function Write-ReportFile { param([string]$Path,[string]$Text) try { $Text | Set-Content -LiteralPath $Path -Encoding UTF8; return $true } catch { return $false } }

# ============================================================================
# 03. Application state and UI constants
# ============================================================================
$cBg = [System.Drawing.Color]::White
$cTxt = [System.Drawing.ColorTranslator]::FromHtml("#2F4F4F")
$cGray = [System.Drawing.Color]::LightGray
$fNormal = [System.Drawing.Font]::new("Segoe UI",9)
$fBold = [System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$fItalic = [System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Italic)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (Is-Blank $scriptDir) { $scriptDir = (Get-Location).Path }
$tarPath = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path -LiteralPath $tarPath)) { $cmdTar = Get-Command "tar.exe" -ErrorAction SilentlyContinue; if ($cmdTar -and $cmdTar.Source) { $tarPath = $cmdTar.Source } }
$script:selectedPath = ""
$script:selectedType = ""

# ============================================================================
# 04. UI helpers
# ============================================================================
function New-EcoLabel { param([string]$Text,[int]$X,[int]$Y,[int]$W=470,[int]$H=20,[System.Drawing.Font]$Font=$fNormal,[System.Drawing.Color]$ForeColor=$cTxt) return New-UiObject "System.Windows.Forms.Label" @{Text=$Text; Location=(New-Point $X $Y); Size=(New-Size $W $H); Font=$Font; ForeColor=$ForeColor; BackColor=$cBg} }
function New-EcoButton { param([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[System.Drawing.Font]$Font=$fNormal,[System.Drawing.Color]$BackColor=$cBg,[System.Drawing.Color]$ForeColor=[System.Drawing.Color]::Black) $button = New-UiObject "System.Windows.Forms.Button" @{Text=$Text; Location=(New-Point $X $Y); Size=(New-Size $W $H); Font=$Font; BackColor=$BackColor; ForeColor=$ForeColor; UseVisualStyleBackColor=$false}; try { $button.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat; $button.FlatAppearance.BorderSize=1; $button.FlatAppearance.BorderColor=$cGray } catch {}; return $button }
function New-EcoCheck { param([string]$Text,[int]$X,[int]$Y,[int]$W,[bool]$Checked=$true) return New-UiObject "System.Windows.Forms.CheckBox" @{Text=$Text; Location=(New-Point $X $Y); Size=(New-Size $W 22); Font=$fNormal; BackColor=$cBg; ForeColor=$cTxt; Checked=$Checked} }
function Msg { param([string]$Message,[string]$Title="SmartTAR STAR 1.0 Beta 1",[System.Windows.Forms.MessageBoxIcon]$Icon=[System.Windows.Forms.MessageBoxIcon]::Information,[System.Windows.Forms.MessageBoxButtons]$Buttons=[System.Windows.Forms.MessageBoxButtons]::OK) return [System.Windows.Forms.MessageBox]::Show($Message,$Title,$Buttons,$Icon) }
function Set-AppStatus { param([string]$Text,[System.Drawing.Color]$Color=[System.Drawing.Color]::DimGray) $lblStatus.Text=$Text; $lblStatus.ForeColor=$Color; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() }
function Start-UiWork { $progressBar.Visible=$true; $progressBar.MarqueeAnimationSpeed=25; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() }
function Stop-UiWork { $progressBar.MarqueeAnimationSpeed=0; $progressBar.Visible=$false; $form.Refresh() }

# ============================================================================
# 05. TAR helpers and methods
# ============================================================================
function Invoke-Tar {
    param([string]$TarPath,$TarArgs,[string]$FailMessage)
    if (Is-Blank $TarPath) { throw "tar.exe path is empty." }
    $argList = @()
    foreach ($arg in @($TarArgs)) { $argList += [string]$arg }
    $output = & $TarPath @argList 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($output | Out-String).Trim()
        if (Is-Blank $text) { $text = "No tar.exe output captured." }
        throw "$FailMessage tar.exe exit code: $LASTEXITCODE`r`n$text"
    }
}
function Test-TarListOk { param([string]$TarPath,[string]$ArchivePath) if(Is-Blank $ArchivePath){return $false}; $null = & $TarPath @("-tf",$ArchivePath) 2>&1; return ($LASTEXITCODE -eq 0) }

function Get-BlockMethod {
    param([string]$Name)
    switch ($Name) {
        "store" { return @{Name="store"; Display="STORE"; Extension=".tar"; Args=@("-cf"); Algorithm="store"; NormalizeTime=$false} }
        "xz9"   { return @{Name="xz9"; Display="XZ9"; Extension=".tar.xz"; Args=@("--options","xz:compression-level=9","-cJf"); Algorithm="xz"; NormalizeTime=$true} }
        default { return @{Name="xz9"; Display="XZ9"; Extension=".tar.xz"; Args=@("--options","xz:compression-level=9","-cJf"); Algorithm="xz"; NormalizeTime=$true} }
    }
}

# ============================================================================
# 06. Classification and grouping
# ============================================================================
function Get-SmartGroupName {
    param([string]$FilePath)
    $ext=[System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $textExt=@(".txt",".csv",".json",".xml",".log",".ini",".cfg",".md",".sql",".ps1",".bat",".cmd",".html",".htm",".css",".js",".ts",".yml",".yaml",".toml",".reg",".inf",".srt",".vtt")
    $exeExt=@(".exe",".dll",".sys",".ocx",".msi",".msp",".scr",".com",".drv",".efi")
    $diskExt=@(".iso",".img",".vhd",".vhdx")
    $mediaExt=@(".jpg",".jpeg",".png",".gif",".webp",".bmp",".tif",".tiff",".ico",".mp3",".wav",".flac",".aac",".ogg",".wma",".mp4",".mkv",".avi",".mov",".wmv",".webm",".pdf",".heic",".avif")
    $archiveExt=@(".zip",".7z",".rar",".gz",".bz2",".xz",".zst",".tar",".tgz",".tbz2",".txz",".cab",".jar",".war",".ear",".sarc",".star",".docx",".xlsx",".pptx",".odt",".ods",".odp",".apk",".epub",".vsix",".nupkg")
    if($textExt -contains $ext){return "text"}
    if($exeExt -contains $ext){return "executable"}
    if($diskExt -contains $ext){return "diskimage"}
    if($mediaExt -contains $ext){return "media"}
    if($archiveExt -contains $ext){return "archives"}
    return "binary"
}

function Get-ModeGroupName {
    param([string]$Mode,[string]$SmartGroup)
    if($Mode -eq "Solid"){ return "solid" }
    if($Mode -eq "SmartXZ"){ return $SmartGroup }
    if($Mode -eq "Smart") { return $SmartGroup }
    # Hybrid
    if($SmartGroup -eq "media" -or $SmartGroup -eq "archives"){ return "stored" }
    if($SmartGroup -eq "diskimage"){ return "stored" }
    return "compressible"
}

function Get-GroupMethodName {
    param([string]$Mode,[string]$GroupName)
    if($GroupName -eq "stored" -or $GroupName -eq "media" -or $GroupName -eq "archives"){ return "store" }
    return "xz9"
}

function New-GroupMap {
    param([string]$StageRoot,[string]$Mode)
    $names = if($Mode -eq "Solid") { @("solid") } elseif($Mode -eq "Hybrid") { @("compressible","stored") } else { @("text","binary","executable","diskimage","media","archives") }
    $map=[ordered]@{}
    foreach($n in $names){
        $methodName=Get-GroupMethodName $Mode $n
        $map[$n]=@{Name=$n; Stage=(Join-Path $StageRoot $n); Method=(Get-BlockMethod $methodName); FileCount=0; DirCount=0; SourceBytes=[int64]0}
    }
    return $map
}

# ============================================================================
# 07. Root-preserving staging
# ============================================================================
function Get-RelativePathFromBase {
    param([string]$BasePath,[string]$FullPath)
    $baseFull=[System.IO.Path]::GetFullPath($BasePath).TrimEnd('\','/')
    $pathFull=[System.IO.Path]::GetFullPath($FullPath)
    $prefix=$baseFull+[System.IO.Path]::DirectorySeparatorChar
    if($pathFull.ToLowerInvariant().StartsWith($prefix.ToLowerInvariant())){ return $pathFull.Substring($prefix.Length) }
    return (Split-Path -Leaf $pathFull)
}

function Copy-FileToStage {
    param([string]$SourceFile,[string]$RelativePath,[string]$StageRoot)
    $target=Join-Path $StageRoot $RelativePath
    $dir=Split-Path -Parent $target
    if(-not(Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $SourceFile -Destination $target -Force
}

function Create-DirInStage {
    param([string]$RelativePath,[string]$StageRoot)
    New-Item -ItemType Directory -Path (Join-Path $StageRoot $RelativePath) -Force | Out-Null
}

function Stage-RootPreservingGroups {
    param([string]$Source,[string]$Mode,[hashtable]$Groups)
    $sourceItem=Get-Item -LiteralPath $Source -Force
    $sourceParent=Split-Path -Parent $Source
    if(Is-Blank $sourceParent){$sourceParent=(Get-Location).Path}

    # Important: relative paths are ALWAYS from parent of selected root.
    # Therefore each stage contains the selected root prefix.
    if($sourceItem.PSIsContainer){
        $rootRel=Get-RelativePathFromBase $sourceParent $Source
        foreach($key in $Groups.Keys){ Create-DirInStage $rootRel $Groups[$key].Stage; $Groups[$key].DirCount++ }
        Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rel=Get-RelativePathFromBase $sourceParent $_.FullName
            foreach($key in $Groups.Keys){ Create-DirInStage $rel $Groups[$key].Stage; $Groups[$key].DirCount++ }
        }
        Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object @{Expression={(Get-RelativePathFromBase $sourceParent $_.FullName).ToLowerInvariant()}} | ForEach-Object {
            $rel=Get-RelativePathFromBase $sourceParent $_.FullName
            $smart=Get-SmartGroupName $_.FullName
            $groupName=Get-ModeGroupName $Mode $smart
            if(-not $Groups.Contains($groupName)){ $groupName = if($Groups.Contains("compressible")){"compressible"}else{"solid"} }
            Copy-FileToStage $_.FullName $rel $Groups[$groupName].Stage
            $Groups[$groupName].FileCount++
            $Groups[$groupName].SourceBytes += [int64]$_.Length
        }
    } else {
        $rel=Get-RelativePathFromBase $sourceParent $Source
        $groupName=if($Groups.Contains("solid")){"solid"}elseif($Groups.Contains("compressible")){"compressible"}else{Get-ModeGroupName $Mode (Get-SmartGroupName $Source)}
        Copy-FileToStage $Source $rel $Groups[$groupName].Stage
        $Groups[$groupName].FileCount++
        $Groups[$groupName].SourceBytes += [int64]$sourceItem.Length
    }
}

# ============================================================================
# 08. Block creation and manifest
# ============================================================================
function Create-BlockFromStage {
    param([string]$TarPath,[string]$StagePath,[string]$BlockPath,[hashtable]$Method)
    if($Method.NormalizeTime){ Set-TreeTimestamp $StagePath (Get-FixedUtcTime) }
    $args=@()
    $args += $Method.Args
    $args += $BlockPath
    $args += "-C"
    $args += $StagePath
    $args += "."
    try {
        Invoke-Tar $TarPath $args "Block creation failed."
    } catch {
        if($Method.Name -ne "store"){
            $fallback=Get-BlockMethod "store"
            $fallbackPath=$BlockPath.Replace($Method.Extension,".tar")
            $args=@(); $args += $fallback.Args; $args += $fallbackPath; $args += "-C"; $args += $StagePath; $args += "."
            Invoke-Tar $TarPath $args "Block creation fallback failed."
            return $fallbackPath
        }
        throw
    }
    return $BlockPath
}

function Build-Blocks {
    param([string]$TarPath,[hashtable]$Groups,[string]$BlocksDir)
    $blocks=@(); $index=1
    foreach($key in $Groups.Keys){
        $g=$Groups[$key]
        if(([int]$g.FileCount -le 0) -and ([int]$g.DirCount -le 0)){ continue }
        $id="{0:D6}" -f $index
        $method=$g.Method
        $blockName="$id`_$($g.Name)$($method.Extension)"
        $blockPath=Join-Path $BlocksDir $blockName
        Set-AppStatus "Creating block $id $($g.Name)..." ([System.Drawing.Color]::DarkOrange)
        $actualBlockPath=Create-BlockFromStage $TarPath $g.Stage $blockPath $method
        $actualName=[System.IO.Path]::GetFileName($actualBlockPath)
        $item=Get-Item -LiteralPath $actualBlockPath
        $actualMethod = if($actualName.EndsWith(".tar.xz")){"xz9"}else{"store"}
        $actualCompression = if($actualMethod -eq "xz9"){"xz"}else{"store"}
        $blocks += [ordered]@{id=$id; group=$g.Name; path="blocks/$actualName"; method=$actualMethod; compression=$actualCompression; fileCount=[int]$g.FileCount; dirCount=[int]$g.DirCount; sourceBytes=[int64]$g.SourceBytes; sizeBytes=[int64]$item.Length; sha256=Get-FileSHA256 $actualBlockPath}
        $index++
    }
    return $blocks
}

function Write-Manifest { param([string]$Path,$Data) $Data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Read-Manifest { param([string]$OuterRoot) $p=Join-Path $OuterRoot "manifest.json"; if(-not(Test-Path -LiteralPath $p)){throw "manifest.json was not found."}; $m=Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json; if($m.format -ne "STAR"){throw "Invalid archive format. Expected STAR."}; return $m }

function Build-Manifest {
    param([string]$Source,$SourceItem,[string]$Mode,$Blocks)
    $sourceName=Split-Path -Leaf $Source
    if(Is-Blank $sourceName){$sourceName=[System.IO.Path]::GetFileName($Source.TrimEnd('\','/'))}
    $sourceType=if($SourceItem.PSIsContainer){"Folder"}else{"File"}
    return [ordered]@{
        format="STAR"
        formatVersion=1
        tool="SmartTAR"
        toolVersion="SmartTAR STAR 1.0 Beta 1 - Root Preserving Smart Hybrid v8.2"
        createdUtc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        engine="Windows tar.exe"
        mode=$Mode
        sourceName=$sourceName
        sourceType=$sourceType
        sourceBytes=Get-DirectorySize $Source
        rootRule="No deduplication. Every block contains the selected root prefix."
        deterministicMetadata=[ordered]@{enabled=$true; timestampUtc=Get-FixedUtcText; scope="XZ9 blocks only"}
        blocks=@($Blocks)
    }
}

# ============================================================================
# 09. Extraction helpers - NO DEDUPLICATION
# ============================================================================
function Get-ArchiveBaseNameWithoutSmartExtension { param([string]$ArchivePath) $name=[System.IO.Path]::GetFileName($ArchivePath); if(Is-Blank $name){return "extracted_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")}; if($name -match '^(.*)\.sarc\.tar$'){return $matches[1]}; if($name -match '^(.*)\.star$'){return $matches[1]}; return [System.IO.Path]::GetFileNameWithoutExtension($name) }
function Get-ArchiveRootName { param($Manifest,[string]$ArchivePath) $sourceName=[string]$Manifest.sourceName; if(-not(Is-Blank $sourceName)){return $sourceName}; return (Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath) }
function Test-RelativePathSafe { param([string]$PathText) if(Is-Blank $PathText){return $false}; $path=([string]$PathText).Replace('\','/'); if($path -eq "." -or $path -eq "./"){return $true}; if($path -match '^[a-zA-Z]:'){return $false}; if($path.StartsWith("/") -or $path.StartsWith("//")){return $false}; foreach($part in @($path.Split('/')|Where-Object{-not [string]::IsNullOrWhiteSpace($_) -and $_ -ne "."})){if($part -eq ".."){return $false}}; return $true }
function Resolve-SafeBlockPath { param([string]$OuterRoot,[string]$RelativeBlockPath) if(-not(Test-RelativePathSafe $RelativeBlockPath)){throw "Unsafe block path in manifest: $RelativeBlockPath"}; return (Join-Path $OuterRoot ($RelativeBlockPath -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)) }
function Test-ArchiveEntriesSafe { param([string]$TarPath,[string]$ArchivePath) $entries = & $TarPath @("-tf",$ArchivePath) 2>&1; if($LASTEXITCODE -ne 0){$text=($entries|Out-String).Trim(); throw "Cannot list TAR block before extraction: $ArchivePath`r`n$text"}; foreach($entry in $entries){if(-not(Test-RelativePathSafe ([string]$entry))){throw "Unsafe path inside TAR block detected: $entry"}} }

function Copy-DirectoryContents {
    param([string]$SourceRoot,[string]$DestinationRoot)
    if(-not(Test-Path -LiteralPath $SourceRoot)){return}
    if(-not(Test-Path -LiteralPath $DestinationRoot)){New-Item -ItemType Directory -Path $DestinationRoot -Force|Out-Null}
    Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $target=Join-Path $DestinationRoot $_.Name
        if($_.PSIsContainer){
            if(-not(Test-Path -LiteralPath $target)){New-Item -ItemType Directory -Path $target -Force|Out-Null}
            Copy-DirectoryContents -SourceRoot $_.FullName -DestinationRoot $target
        } else {
            $targetDir=Split-Path -Parent $target
            if(-not(Test-Path -LiteralPath $targetDir)){New-Item -ItemType Directory -Path $targetDir -Force|Out-Null}
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Copy-PayloadToFinalDestination {
    param($Manifest,[string]$PayloadRoot,[string]$DestinationParent,[string]$ArchivePath)
    $rootName=Get-ArchiveRootName $Manifest $ArchivePath
    $sourceType=[string]$Manifest.sourceType
    if($sourceType -eq "Folder" -and -not(Is-Blank $rootName)){
        $finalRoot=Join-Path $DestinationParent $rootName
        if(-not(Test-Path -LiteralPath $finalRoot)){New-Item -ItemType Directory -Path $finalRoot -Force|Out-Null}
        $rootInPayload=Join-Path $PayloadRoot $rootName
        if(Test-Path -LiteralPath $rootInPayload){
            # Exact restore of root content. Same-name child folder is normal content.
            Copy-DirectoryContents -SourceRoot $rootInPayload -DestinationRoot $finalRoot
        } else {
            # Fallback for older/malformed archives.
            Copy-DirectoryContents -SourceRoot $PayloadRoot -DestinationRoot $finalRoot
        }
        return
    }
    Copy-DirectoryContents -SourceRoot $PayloadRoot -DestinationRoot $DestinationParent
}

# ============================================================================
# 10. Core archive operations
# ============================================================================
function Compress-SmartArchive {
    param([string]$TarPath,[string]$Source,[string]$Destination,[string]$Mode)
    if(-not(Test-Path -LiteralPath $TarPath)){throw "tar.exe was not found."}
    $Source=Normalize-ArchiveSourcePath $Source
    if(-not(Test-Path -LiteralPath $Source)){throw "Source path does not exist."}
    if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force}
    if(Is-Blank $Mode){$Mode="Hybrid"}

    $sourceItem=Get-Item -LiteralPath $Source -Force
    $work=Join-Path $env:TEMP ("smarttar_create_"+[guid]::NewGuid().ToString("N"))
    $stageRoot=Join-Path $work "staging"
    $blocksDir=Join-Path $work "blocks"
    New-Item -ItemType Directory -Path $stageRoot,$blocksDir -Force|Out-Null

    try{
        Set-AppStatus "Preparing root-preserving stages..." ([System.Drawing.Color]::DarkOrange)
        $groups=New-GroupMap $stageRoot $Mode
        foreach($k in $groups.Keys){New-Item -ItemType Directory -Path $groups[$k].Stage -Force|Out-Null}
        Stage-RootPreservingGroups $Source $Mode $groups

        $blocks=Build-Blocks $TarPath $groups $blocksDir
        if($blocks.Count -lt 1){throw "No blocks were created."}
        $manifest=Build-Manifest $Source $sourceItem $Mode $blocks
        Write-Manifest (Join-Path $work "manifest.json") $manifest

        Set-AppStatus "Creating outer STAR container..." ([System.Drawing.Color]::DarkOrange)
        Invoke-Tar $TarPath @("-cf",$Destination,"-C",$work,"manifest.json","blocks") "Outer .star archive creation failed."
    } finally {
        if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

function Extract-SmartArchive {
    param([string]$TarPath,[string]$ArchivePath,[string]$DestinationFolder)
    if(Is-Blank $ArchivePath){throw "Archive path is empty. Please select an existing .star archive first."}
    if(-not(Test-Path -LiteralPath $TarPath)){throw "tar.exe was not found."}
    if(-not(Test-Path -LiteralPath $ArchivePath)){throw "Archive path does not exist."}
    if(-not(Test-Path -LiteralPath $DestinationFolder)){New-Item -ItemType Directory -Path $DestinationFolder -Force|Out-Null}

    $work=Join-Path $env:TEMP ("smarttar_extract_"+[guid]::NewGuid().ToString("N"))
    $outer=Join-Path $work "outer"
    $payload=Join-Path $work "payload"
    New-Item -ItemType Directory -Path $outer,$payload -Force|Out-Null
    try{
        Set-AppStatus "Extracting outer STAR container..." ([System.Drawing.Color]::DarkOrange)
        Invoke-Tar $TarPath @("-xf",$ArchivePath,"-C",$outer) "Outer .star extraction failed."
        $manifest=Read-Manifest $outer
        foreach($block in @($manifest.blocks)){
            $blockPath=Resolve-SafeBlockPath $outer ([string]$block.path)
            if(-not(Test-Path -LiteralPath $blockPath)){throw "Block file was not found: $($block.path)"}
            if($block.sha256){$actualHash=Get-FileSHA256 $blockPath; if($actualHash -ne ([string]$block.sha256).ToLowerInvariant()){throw "Block SHA256 mismatch: $($block.path)"}}
            Test-ArchiveEntriesSafe $TarPath $blockPath
            Set-AppStatus "Extracting block $($block.id) $($block.group)..." ([System.Drawing.Color]::DarkOrange)
            Invoke-Tar $TarPath @("-xf",$blockPath,"-C",$payload) "Payload block extraction failed."
        }
        Set-AppStatus "Copying payload to final destination..." ([System.Drawing.Color]::DarkOrange)
        Copy-PayloadToFinalDestination -Manifest $manifest -PayloadRoot $payload -DestinationParent $DestinationFolder -ArchivePath $ArchivePath
    } finally {
        if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

function Verify-SmartArchive {
    param([string]$TarPath,[string]$ArchivePath)

    if(Is-Blank $ArchivePath){
        throw "Archive path is empty. Please select an existing .star archive first."
    }
    if(Is-Blank $TarPath){
        throw "tar.exe path is empty."
    }
    if(-not(Test-Path -LiteralPath $TarPath)){
        throw "tar.exe was not found."
    }
    if(-not(Test-Path -LiteralPath $ArchivePath)){
        throw "Archive path does not exist."
    }

    $work=Join-Path $env:TEMP ("smarttar_verify_"+[guid]::NewGuid().ToString("N"))
    $outer=Join-Path $work "outer"
    New-Item -ItemType Directory -Path $outer -Force|Out-Null
    try{
        Invoke-Tar $TarPath @("-xf",$ArchivePath,"-C",$outer) "Outer .star verification failed."
        $manifest=Read-Manifest $outer
        $lines=@(); $ok=0; $fail=0
        foreach($block in @($manifest.blocks)){
            $blockPath=Resolve-SafeBlockPath $outer ([string]$block.path)
            if(-not(Test-Path -LiteralPath $blockPath)){$fail++; $lines += "MISSING: $($block.path)"; continue}
            $listed=Test-TarListOk $TarPath $blockPath
            $hashOk=$true
            if($block.sha256){$hashOk=((Get-FileSHA256 $blockPath) -eq ([string]$block.sha256).ToLowerInvariant())}
            if($listed -and $hashOk){$ok++; $lines += "OK: $($block.id) $($block.group) $($block.path)"}else{$fail++; $lines += "FAIL: $($block.id) $($block.group) $($block.path)"}
        }
        return @"
Archive verification finished.

Format: $($manifest.format)
Tool: $($manifest.tool)
Version: $($manifest.toolVersion)
Mode: $($manifest.mode)
Source name: $($manifest.sourceName)
Source type: $($manifest.sourceType)
Source size: $(Format-Bytes ([int64]$manifest.sourceBytes))
Root rule: $($manifest.rootRule)
Blocks OK: $ok
Blocks failed: $fail
Archive size: $(Format-Bytes ([int64](Get-Item -LiteralPath $ArchivePath).Length))

$($lines -join "`r`n")
"@
    } finally {
        if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

# ============================================================================
# 11. Path helpers
# ============================================================================
function Is-SmartArchivePath { param([string]$Path) if(Is-Blank $Path){return $false}; return ([System.IO.Path]::GetFileName($Path) -match '(?i)(\.star|\.sarc\.tar)$') }
function Ensure-StarExtension { param([string]$Path) if(Is-Blank $Path){return $Path}; if($Path -match '(?i)(\.star|\.sarc\.tar)$'){return $Path}; return ($Path+".star") }
function Get-DefaultArchiveBaseName { param([string]$Path,[string]$Type) $clean=Normalize-ArchiveSourcePath $Path; $leaf=Split-Path -Leaf $clean; if(Is-Blank $leaf){return "archive_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")}; if($Type -eq "Folder"){return $leaf}; return [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
function Get-SelectedCompressionMode { $text=[string]$cmbMode.SelectedItem; if($text -like "Mode - Solid*"){return "Solid"}; if($text -like "Mode - SmartXZ*"){return "SmartXZ"}; if($text -like "Mode - Smart *"){return "Smart"}; return "Hybrid" }
function Set-DefaultTarget { if(Is-Blank $script:selectedPath){return}; $parent=Split-Path -Parent $script:selectedPath; if(Is-Blank $parent){$parent=$scriptDir}; if($script:selectedType -eq "File" -and (Is-SmartArchivePath $script:selectedPath)){$txtTarget.Text=$parent; return}; $txtTarget.Text=Join-Path $parent ((Get-DefaultArchiveBaseName $script:selectedPath $script:selectedType)+".star") }
function Set-SelectedPath { param([string]$Path,[ValidateSet("File","Folder")][string]$Type) $script:selectedPath=$Path; $script:selectedType=$Type; $lblSelected.Text="Selected: $script:selectedPath"; if($Type -eq "File"){if(Is-SmartArchivePath $Path){$btnFile.BackColor=$cBg; $btnArchive.BackColor=[System.Drawing.Color]::LightBlue}else{$btnFile.BackColor=[System.Drawing.Color]::LightBlue; $btnArchive.BackColor=$cBg}; $btnFolder.BackColor=$cBg}else{$btnFile.BackColor=$cBg; $btnArchive.BackColor=$cBg; $btnFolder.BackColor=[System.Drawing.Color]::LightBlue}; Set-DefaultTarget }

# ============================================================================
# 12. GUI construction
# ============================================================================
$form=New-UiObject "System.Windows.Forms.Form" @{Text="SmartTAR STAR 1.0 Beta 1 - Root Preserving Smart Hybrid v8.2";ClientSize=(New-Size 505 475);StartPosition="CenterScreen";BackColor=$cBg;FormBorderStyle="FixedSingle";MaximizeBox=$false;TopMost=$false}
$lblInput=New-EcoLabel "1. Select input file or folder:" 20 20 -Font $fBold
$btnFile=New-EcoButton "Add FILE" 20 48 150 30
$btnFolder=New-EcoButton "Add FOLDER" 177 48 150 30
$btnArchive=New-EcoButton "Add ARCHIVE" 334 48 151 30
$lblSelected=New-EcoLabel "Selected: none" 20 88 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$lblTarget=New-EcoLabel "2. Destination archive / extraction parent folder:" 20 125 -Font $fBold
$txtTarget=New-UiObject "System.Windows.Forms.TextBox" @{Location=(New-Point 20 153);Size=(New-Size 395 23);Font=$fNormal;ReadOnly=$true;BackColor=$cBg}
$btnTarget=New-EcoButton "..." 422 152 63 24
$lblMode=New-EcoLabel "3. Compression mode:" 20 195 -Font $fBold
$cmbMode=New-UiObject "System.Windows.Forms.ComboBox" @{Location=(New-Point 20 223);Size=(New-Size 465 24);Font=$fNormal;DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList}
[void]$cmbMode.Items.Add("Mode - Hybrid - recommended")
[void]$cmbMode.Items.Add("Mode - Smart - grouped blocks")
[void]$cmbMode.Items.Add("Mode - SmartXZ - grouped XZ blocks")
[void]$cmbMode.Items.Add("Mode - Solid - one compressed block")
$cmbMode.SelectedIndex=0
$lblInfo=New-EcoLabel "Every block contains the selected root prefix. No folder-name deduplication." 20 252 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$btnCompress=New-EcoButton "COMPRESS" 20 287 150 42 $fBold ([System.Drawing.Color]::SeaGreen) ([System.Drawing.Color]::White)
$btnExtract=New-EcoButton "EXTRACT" 177 287 150 42 $fBold ([System.Drawing.Color]::SteelBlue) ([System.Drawing.Color]::White)
$btnVerify=New-EcoButton "VERIFY" 334 287 151 42 $fBold ([System.Drawing.Color]::DarkSlateGray) ([System.Drawing.Color]::White)
$chkOpenFolder=New-EcoCheck "Open output folder after success" 20 342 300 $true
$lblStatus=New-EcoLabel "Ready." 20 392 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$progressBar=New-UiObject "System.Windows.Forms.ProgressBar" @{Location=(New-Point 20 435);Size=(New-Size 465 8);Style=[System.Windows.Forms.ProgressBarStyle]::Marquee;MarqueeAnimationSpeed=25;Visible=$false}
$form.Controls.AddRange([System.Windows.Forms.Control[]]@($lblInput,$btnFile,$btnFolder,$btnArchive,$lblSelected,$lblTarget,$txtTarget,$btnTarget,$lblMode,$cmbMode,$lblInfo,$btnCompress,$btnExtract,$btnVerify,$chkOpenFolder,$lblStatus,$progressBar))

# ============================================================================
# 13. GUI events
# ============================================================================
$cmbMode.Add_SelectedIndexChanged({
    $mode = Get-SelectedCompressionMode
    if($mode -eq "Solid"){
        $lblInfo.Text = "Solid creates one compressed root-preserving block."
    } elseif($mode -eq "SmartXZ"){
        $lblInfo.Text = "SmartXZ creates grouped XZ blocks and STORE blocks for already-compressed data."
    } elseif($mode -eq "Smart"){
        $lblInfo.Text = "Smart creates detailed grouped root-preserving blocks."
    } else {
        $lblInfo.Text = "Hybrid is recommended. Every block contains the selected root prefix."
    }
})
$btnFile.Add_Click({$dialog=New-Object System.Windows.Forms.OpenFileDialog; $dialog.Title="Select file"; $dialog.Filter="All files (*.*)|*.*"; try{if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Set-SelectedPath $dialog.FileName "File"}}finally{$dialog.Dispose()}})
$btnFolder.Add_Click({$dialog=New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.Description="Select folder to archive"; try{if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Set-SelectedPath (Normalize-ArchiveSourcePath $dialog.SelectedPath) "Folder"}}finally{$dialog.Dispose()}})
$btnArchive.Add_Click({$dialog=New-Object System.Windows.Forms.OpenFileDialog; $dialog.Title="Select SmartTAR archive"; $dialog.Filter="SmartTAR Archive (*.star)|*.star|Legacy SmartTAR Archive (*.sarc.tar)|*.sarc.tar|All files (*.*)|*.*"; try{if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Set-SelectedPath $dialog.FileName "File"}}finally{$dialog.Dispose()}})
$btnTarget.Add_Click({if($script:selectedType -eq "File" -and (Is-SmartArchivePath $script:selectedPath)){$dialog=New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.Description="Select extraction parent folder"; try{if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$txtTarget.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}; return}; $dialog=New-Object System.Windows.Forms.SaveFileDialog; $dialog.Title="Select destination archive"; $dialog.Filter="SmartTAR Archive (*.star)|*.star|All files (*.*)|*.*"; $dialog.DefaultExt="star"; $dialog.AddExtension=$true; $dialog.OverwritePrompt=$true; try{if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$txtTarget.Text=Ensure-StarExtension $dialog.FileName}}finally{$dialog.Dispose()}})

# ============================================================================
# 14. Execution handlers
# ============================================================================
function Execute-Compress {
    if(-not(Test-Path -LiteralPath $tarPath)){Msg "tar.exe was not found." "Missing TAR Engine" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}
    if(Is-Blank $script:selectedPath){Msg "Please select a file or folder first." "Missing Input" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}
    if(Is-Blank $txtTarget.Text){Msg "Please select destination archive path." "Missing Destination" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}
    if(-not(Test-Path -LiteralPath $script:selectedPath)){Msg "Selected input path does not exist." "Input Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}
    $targetPath=Ensure-StarExtension ($txtTarget.Text.Trim('"')); $txtTarget.Text=$targetPath
    $targetDir=[System.IO.Path]::GetDirectoryName($targetPath)
    if(Is-Blank $targetDir){$targetDir=$scriptDir; $targetPath=Join-Path $targetDir ([System.IO.Path]::GetFileName($targetPath)); $txtTarget.Text=$targetPath}
    if(-not(Test-Path -LiteralPath $targetDir)){Msg "Destination directory does not exist:`n$targetDir" "Destination Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}
    if(Test-Path -LiteralPath $targetPath){$confirm=Msg "Target archive already exists. Overwrite it?" "Overwrite Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo); if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){return}}
    $mode=Get-SelectedCompressionMode
    Start-UiWork; $success=$false; $errorMessage=$null
    try{Compress-SmartArchive $tarPath $script:selectedPath $targetPath $mode; $success=$true}catch{$errorMessage=Get-ErrorDetails $_}finally{Stop-UiWork}
    if($success){Set-AppStatus "Archive created successfully. Mode: $mode." ([System.Drawing.Color]::Green); $reportPath=Get-ReportPath $targetPath "create_report"; try{$summary=Verify-SmartArchive $tarPath $targetPath; [void](Write-ReportFile $reportPath $summary); Msg "$summary`r`nReport saved:`r`n$reportPath" "Archive Summary" ([System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null}catch{}; if($chkOpenFolder.Checked){explorer.exe "/select,`"$targetPath`""}; return}
    Set-AppStatus "Compression failed." ([System.Drawing.Color]::Red); Msg "Compression failed.`n`n$errorMessage" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
}

function Execute-Extract {
    if(Is-Blank $script:selectedPath){Msg "Please select a SmartTAR archive first." "Missing Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}
    if($script:selectedType -ne "File"){Msg "Extraction input must be a .star file." "Invalid Input" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}
    $destination=$txtTarget.Text.Trim('"')
    if(Is-Blank $destination){Msg "Please select extraction parent folder." "Missing Destination" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}
    if(-not(Test-Path -LiteralPath $destination)){New-Item -ItemType Directory -Path $destination -Force|Out-Null}
    Start-UiWork; $success=$false; $errorMessage=$null
    try{Extract-SmartArchive $tarPath $script:selectedPath $destination; $success=$true}catch{$errorMessage=Get-ErrorDetails $_}finally{Stop-UiWork}
    $reportPath=Get-ReportPath $script:selectedPath "extract_report"
    if($success){Set-AppStatus "Archive extracted successfully." ([System.Drawing.Color]::Green); $text="Archive extracted successfully.`r`nArchive: $($script:selectedPath)`r`nExtraction parent folder: $destination"; [void](Write-ReportFile $reportPath $text); Msg "$text`r`nReport saved:`r`n$reportPath" "Extract Archive" ([System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null; if($chkOpenFolder.Checked){explorer.exe "`"$destination`""}; return}
    [void](Write-ReportFile $reportPath "Extraction failed.`r`n`r`n$errorMessage"); Set-AppStatus "Extraction failed." ([System.Drawing.Color]::Red); Msg "Extraction failed.`n`n$errorMessage`n`nReport saved:`n$reportPath" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
}

function Execute-Verify {
    if(Is-Blank $script:selectedPath){
        Msg "Please select an existing .star archive first." "Invalid Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        Set-AppStatus "Verification cancelled. No archive selected." ([System.Drawing.Color]::DimGray)
        return
    }
    if($script:selectedType -ne "File"){
        Msg "Verification input must be a .star archive file." "Invalid Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        Set-AppStatus "Verification cancelled. Invalid input type." ([System.Drawing.Color]::DimGray)
        return
    }
    if(-not(Test-Path -LiteralPath $script:selectedPath)){
        Msg "Selected archive does not exist." "Invalid Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        Set-AppStatus "Verification cancelled. Archive does not exist." ([System.Drawing.Color]::DimGray)
        return
    }
    if(-not(Is-SmartArchivePath $script:selectedPath)){
        Msg "Please select a .star archive." "Invalid Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        Set-AppStatus "Verification cancelled. Not a .star archive." ([System.Drawing.Color]::DimGray)
        return
    }

    Start-UiWork; $success=$false; $summary=$null; $errorMessage=$null
    try{$summary=Verify-SmartArchive $tarPath $script:selectedPath; $success=$true}catch{$errorMessage=Get-ErrorDetails $_}finally{Stop-UiWork}
    $reportPath=Get-ReportPath $script:selectedPath "verify_report"
    if($success){[void](Write-ReportFile $reportPath $summary); Set-AppStatus "Archive verification finished." ([System.Drawing.Color]::Green); Msg "$summary`r`nReport saved:`r`n$reportPath" "Verify Archive" ([System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null; return}
    [void](Write-ReportFile $reportPath "Verification failed.`r`n`r`n$errorMessage"); Set-AppStatus "Verification failed." ([System.Drawing.Color]::Red); Msg "Verification failed.`n`n$errorMessage`n`nReport saved:`n$reportPath" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
}

$btnCompress.Add_Click({Execute-Compress})
$btnExtract.Add_Click({Execute-Extract})
$btnVerify.Add_Click({Execute-Verify})
$form.Add_FormClosing({$fNormal.Dispose();$fBold.Dispose();$fItalic.Dispose()})
[System.Windows.Forms.Application]::Run($form)