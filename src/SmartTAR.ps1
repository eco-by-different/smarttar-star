# ============================================================================
# SmartTAR STAR 1.0 Beta 1 Fix 5 - Path Safe EXE Build
# Powered by Windows tar.exe / bsdtar only
#
# Fix 5:
#   - full script, no patch required
#   - keeps Fix 4 behavior: temp cleanup, parent-folder extraction target,
#     Yes/No overwrite prompt, safe extraction through _smarttar_tmp
#   - adds path normalization for compiled PS2EXE builds
#   - repairs drive-relative paths like "Z:file.star" to "Z:\file.star"
#   - avoids GUI crash from .NET GetFullPath("path") exceptions
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
# 01. Generic helpers
# ============================================================================
function Is-Blank { param([string]$Text) return [string]::IsNullOrWhiteSpace($Text) }
function New-Point { param([int]$X,[int]$Y) return [System.Drawing.Point]::new($X,$Y) }
function New-Size { param([int]$W,[int]$H) return [System.Drawing.Size]::new($W,$H) }
function New-UiObject { param([string]$Type,[hashtable]$Props) $o=New-Object $Type; foreach($k in $Props.Keys){$o.$k=$Props[$k]}; return $o }
function Format-Bytes { param([int64]$Bytes) if($Bytes -ge 1GB){return "{0:N2} GB" -f ($Bytes/1GB)}; if($Bytes -ge 1MB){return "{0:N2} MB" -f ($Bytes/1MB)}; if($Bytes -ge 1KB){return "{0:N2} KB" -f ($Bytes/1KB)}; return "$Bytes B" }
function Get-FixedUtcText { return "2000-01-01T00:00:00Z" }
function Get-FixedUtcTime { return [datetime]::SpecifyKind([datetime]"2000-01-01T00:00:00",[System.DateTimeKind]::Utc) }

function Get-ErrorDetails {
    param($ErrorRecord)
    $lines=New-Object System.Collections.Generic.List[string]
    $lines.Add("Message:")|Out-Null; $lines.Add([string]$ErrorRecord.Exception.Message)|Out-Null
    $lines.Add("")|Out-Null; $lines.Add("Exception type:")|Out-Null; $lines.Add([string]$ErrorRecord.Exception.GetType().FullName)|Out-Null
    if($ErrorRecord.InvocationInfo){$lines.Add("")|Out-Null; $lines.Add("Position:")|Out-Null; $lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage)|Out-Null}
    if($ErrorRecord.ScriptStackTrace){$lines.Add("")|Out-Null; $lines.Add("Script stack trace:")|Out-Null; $lines.Add([string]$ErrorRecord.ScriptStackTrace)|Out-Null}
    return ($lines -join "`r`n")
}

# ============================================================================
# 02. Script path, tar.exe and path normalization
# ============================================================================
$scriptDir = if($PSScriptRoot){$PSScriptRoot}elseif($MyInvocation.MyCommand.Path){Split-Path -Parent $MyInvocation.MyCommand.Path}else{(Get-Location).Path}
if(Is-Blank $scriptDir){$scriptDir=(Get-Location).Path}

function Repair-WindowsPath {
    param([string]$Path)
    if(Is-Blank $Path){return ""}
    $p=([string]$Path).Trim().Trim('"')
    # PS2EXE / WinForms can sometimes provide drive-relative paths like Z:file.star.
    # Convert to absolute drive-root form Z:\file.star before GetFullPath sees it.
    if($p -match '^([a-zA-Z]):([^\\/].*)$'){return ("{0}:\{1}" -f $matches[1],$matches[2])}
    return $p
}
function Resolve-SmartTarFullPath {
    param([string]$Path)
    $p=Repair-WindowsPath $Path
    if(Is-Blank $p){return ""}
    try{return [System.IO.Path]::GetFullPath($p)}catch{return $p}
}
function Get-NormalizedFullPath { param([string]$Path) if(Is-Blank $Path){return ""}; return (Resolve-SmartTarFullPath $Path).TrimEnd('\','/') }

$tarPath = Join-Path $env:SystemRoot "System32\tar.exe"
if(-not(Test-Path -LiteralPath $tarPath)){ $cmd=Get-Command "tar.exe" -ErrorAction SilentlyContinue; if($cmd -and $cmd.Source){$tarPath=$cmd.Source} }

function Get-SmartTarTempRoot { return (Join-Path $scriptDir "_smarttar_tmp") }
function New-SmartTarSafeWorkDir {
    param([string]$Prefix="smarttar")
    $root=Get-SmartTarTempRoot
    if(-not(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Path $root -Force|Out-Null}
    $p=Join-Path $root ("$Prefix`_"+[guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $p -Force|Out-Null
    return $p
}
function Remove-SmartTarWorkDir {
    param([string]$WorkPath)
    if(-not(Is-Blank $WorkPath) -and (Test-Path -LiteralPath $WorkPath)){Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue}
    $root=Get-SmartTarTempRoot
    if(Test-Path -LiteralPath $root){try{$children=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue); if($children.Count -eq 0){Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue}}catch{}}
}
function Get-FileSHA256 { param([string]$Path) if(-not(Test-Path -LiteralPath $Path)){throw "Cannot hash missing file: $Path"}; return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Set-TreeTimestamp { param([string]$Path,[datetime]$Timestamp) if(-not(Test-Path -LiteralPath $Path)){return}; Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue|ForEach-Object{try{$_.CreationTimeUtc=$Timestamp}catch{};try{$_.LastAccessTimeUtc=$Timestamp}catch{};try{$_.LastWriteTimeUtc=$Timestamp}catch{}}; try{$r=Get-Item -LiteralPath $Path -Force; $r.CreationTimeUtc=$Timestamp; $r.LastAccessTimeUtc=$Timestamp; $r.LastWriteTimeUtc=$Timestamp}catch{} }
function Get-ReportPath { param([string]$BasePath,[string]$Kind) $dir=[System.IO.Path]::GetDirectoryName((Repair-WindowsPath $BasePath)); if(Is-Blank $dir){$dir=(Get-Location).Path}; $name=[System.IO.Path]::GetFileName($BasePath); $stamp=Get-Date -Format "yyyyMMdd_HHmmss"; return Join-Path $dir "$name.$Kind.$stamp.txt" }
function Write-ReportFile { param([string]$Path,[string]$Text) try{$Text|Set-Content -LiteralPath $Path -Encoding UTF8; return $true}catch{return $false} }

# ============================================================================
# 03. UI
# ============================================================================
$cBg=[System.Drawing.Color]::White
$cTxt=[System.Drawing.ColorTranslator]::FromHtml("#2F4F4F")
$cGray=[System.Drawing.Color]::LightGray
$fNormal=[System.Drawing.Font]::new("Segoe UI",9)
$fBold=[System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$fItalic=[System.Drawing.Font]::new("Segoe UI",9,[System.Drawing.FontStyle]::Italic)
$script:selectedPath=""
$script:selectedType=""
function New-EcoLabel { param([string]$Text,[int]$X,[int]$Y,[int]$W=470,[int]$H=20,[System.Drawing.Font]$Font=$fNormal,[System.Drawing.Color]$ForeColor=$cTxt) return New-UiObject "System.Windows.Forms.Label" @{Text=$Text;Location=(New-Point $X $Y);Size=(New-Size $W $H);Font=$Font;ForeColor=$ForeColor;BackColor=$cBg} }
function New-EcoButton { param([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[System.Drawing.Font]$Font=$fNormal,[System.Drawing.Color]$BackColor=$cBg,[System.Drawing.Color]$ForeColor=[System.Drawing.Color]::Black) $b=New-UiObject "System.Windows.Forms.Button" @{Text=$Text;Location=(New-Point $X $Y);Size=(New-Size $W $H);Font=$Font;BackColor=$BackColor;ForeColor=$ForeColor;UseVisualStyleBackColor=$false}; try{$b.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat; $b.FlatAppearance.BorderSize=1; $b.FlatAppearance.BorderColor=$cGray}catch{}; return $b }
function New-EcoCheck { param([string]$Text,[int]$X,[int]$Y,[int]$W,[bool]$Checked=$true) return New-UiObject "System.Windows.Forms.CheckBox" @{Text=$Text;Location=(New-Point $X $Y);Size=(New-Size $W 22);Font=$fNormal;BackColor=$cBg;ForeColor=$cTxt;Checked=$Checked} }
function Msg { param([string]$Message,[string]$Title="SmartTAR STAR 1.0 Beta 1 Fix 5",[System.Windows.Forms.MessageBoxIcon]$Icon=[System.Windows.Forms.MessageBoxIcon]::Information,[System.Windows.Forms.MessageBoxButtons]$Buttons=[System.Windows.Forms.MessageBoxButtons]::OK) return [System.Windows.Forms.MessageBox]::Show($Message,$Title,$Buttons,$Icon) }
function Set-AppStatus { param([string]$Text,[System.Drawing.Color]$Color=[System.Drawing.Color]::DimGray) $lblStatus.Text=$Text; $lblStatus.ForeColor=$Color; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() }
function Start-UiWork { $progressBar.Visible=$true; $progressBar.MarqueeAnimationSpeed=25; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() }
function Stop-UiWork { $progressBar.MarqueeAnimationSpeed=0; $progressBar.Visible=$false; $form.Refresh() }

# ============================================================================
# 04. tar helpers
# ============================================================================
function Get-TarMethods { return @(
    @{Name="store";Display="STORE";Extension=".tar";CreateArgs=@("-cf");Level=$null;Algorithm="store"},
    @{Name="gzip";Display="GZIP";Extension=".tar.gz";CreateArgs=@("-czf");Level=$null;Algorithm="gzip"},
    @{Name="bzip2";Display="BZIP2";Extension=".tar.bz2";CreateArgs=@("-cjf");Level=$null;Algorithm="bzip2"},
    @{Name="xz9";Display="XZ9";Extension=".tar.xz";CreateArgs=@("--options","xz:compression-level=9","-cJf");Level=9;Algorithm="xz"},
    @{Name="xz";Display="XZ";Extension=".tar.xz";CreateArgs=@("-cJf");Level=$null;Algorithm="xz"},
    @{Name="zstd19";Display="ZSTD19";Extension=".tar.zst";CreateArgs=@("--zstd","--options","zstd:compression-level=19","-cf");Level=19;Algorithm="zstd"}
) }
function Get-TarMethodByName { param([string]$Name) foreach($m in Get-TarMethods){if([string]$m.Name -eq $Name){return $m}}; return $null }
function Invoke-TarRaw { param([string]$TarPath,$TarArgs) $argList=@(); foreach($a in @($TarArgs)){$argList += [string]$a}; $output=& $TarPath @argList 2>&1; return @{ExitCode=$LASTEXITCODE;Output=(($output|Out-String).Trim());Args=$argList} }
function Invoke-Tar { param([string]$TarPath,$TarArgs,[string]$FailMessage) $r=Invoke-TarRaw $TarPath $TarArgs; if([int]$r.ExitCode -ne 0){$text=[string]$r.Output; if(Is-Blank $text){$text="No tar.exe output captured."}; $argPreview=(($r.Args|Select-Object -First 80)-join " | "); throw "$FailMessage tar.exe exit code: $($r.ExitCode)`r`n$text`r`n`r`nArgs preview:`r`n$argPreview"} }
function Invoke-TarList { param([string]$TarPath,[string]$ArchivePath) $null=& $TarPath @("-tf",$ArchivePath) 2>&1; return ($LASTEXITCODE -eq 0) }
function Test-TarCapabilities { param([string]$TarPath) $root=New-SmartTarSafeWorkDir "cap"; $sample=Join-Path $root "sample"; $extract=Join-Path $root "extract"; New-Item -ItemType Directory -Path $sample,$extract -Force|Out-Null; "SmartTAR capability test"|Set-Content -LiteralPath (Join-Path $sample "sample.txt") -Encoding UTF8; $result=@{}; try{foreach($method in Get-TarMethods){$name=[string]$method.Name; $archivePath=Join-Path $root ("test"+[string]$method.Extension); $extractDir=Join-Path $extract $name; New-Item -ItemType Directory -Path $extractDir -Force|Out-Null; $ok=$false; try{$args=@(); $args+=$method.CreateArgs; $args+=$archivePath; $args+="-C"; $args+=$sample; $args+="sample.txt"; $r=Invoke-TarRaw $TarPath $args; if([int]$r.ExitCode -eq 0 -and (Test-Path -LiteralPath $archivePath)){ $null=& $TarPath @("-xf",$archivePath,"-C",$extractDir) 2>&1; if($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $extractDir "sample.txt"))){$ok=$true}}}catch{$ok=$false}; $result[$name]=$ok}}finally{Remove-SmartTarWorkDir $root}; return $result }
function Select-BestCompressedMethod { param([hashtable]$Capabilities) foreach($n in @("xz9","xz","bzip2","gzip","store")){if($Capabilities.ContainsKey($n) -and $Capabilities[$n]){return Get-TarMethodByName $n}}; throw "No usable tar method was found." }
function Select-XzOrBest { param([hashtable]$Capabilities) if($Capabilities.ContainsKey("xz9") -and $Capabilities["xz9"]){return Get-TarMethodByName "xz9"}; if($Capabilities.ContainsKey("xz") -and $Capabilities["xz"]){return Get-TarMethodByName "xz"}; return Select-BestCompressedMethod $Capabilities }
function Select-ZstdOrBest { param([hashtable]$Capabilities) if($Capabilities.ContainsKey("zstd19") -and $Capabilities["zstd19"]){return Get-TarMethodByName "zstd19"}; return Select-BestCompressedMethod $Capabilities }
function Select-StoreMethod { param([hashtable]$Capabilities) if($Capabilities.ContainsKey("store") -and $Capabilities["store"]){return Get-TarMethodByName "store"}; return Select-BestCompressedMethod $Capabilities }

# ============================================================================
# 05. planning/staging
# ============================================================================
function Get-SmartGroupName { param([string]$FilePath) $ext=[System.IO.Path]::GetExtension($FilePath).ToLowerInvariant(); $textExt=@(".txt",".csv",".json",".xml",".log",".ini",".cfg",".md",".sql",".ps1",".bat",".cmd",".html",".htm",".css",".js",".ts",".yml",".yaml",".toml",".reg",".inf",".srt",".vtt"); $diskImageExt=@(".iso",".img",".vhd",".vhdx"); $binaryExt=@(".bin",".dat",".db",".sqlite",".sqlite3",".pak",".asset",".res",".idx",".map",".cache",".blob"); $executableExt=@(".exe",".dll",".sys",".ocx",".msi",".msp",".scr",".com",".drv",".efi"); $mediaExt=@(".jpg",".jpeg",".png",".gif",".webp",".bmp",".tif",".tiff",".ico",".mp3",".wav",".flac",".aac",".ogg",".wma",".mp4",".mkv",".avi",".mov",".wmv",".webm",".pdf",".heic",".avif"); $archiveExt=@(".zip",".7z",".rar",".gz",".bz2",".xz",".zst",".tar",".tgz",".tbz2",".txz",".cab",".jar",".war",".ear",".sarc",".star",".docx",".xlsx",".pptx",".odt",".ods",".odp",".apk",".epub",".vsix",".nupkg"); if($textExt -contains $ext){return "text"}; if($diskImageExt -contains $ext){return "diskimage"}; if($binaryExt -contains $ext){return "binary"}; if($executableExt -contains $ext){return "executable"}; if($mediaExt -contains $ext){return "media"}; if($archiveExt -contains $ext){return "archives"}; return "unknown" }
function Get-ModeGroupName { param([string]$Mode,[string]$SmartGroup) if($Mode -eq "Solid"){return "solid"}; if($Mode -eq "SmartXZ"){return $SmartGroup}; if($Mode -eq "Hybrid"){if($SmartGroup -eq "diskimage"){return "diskimage"}; if($SmartGroup -eq "media" -or $SmartGroup -eq "archives"){return "stored"}; return "compressible"}; return $SmartGroup }
function Get-RelativePathFromBase { param([string]$BasePath,[string]$FullPath) $baseFull=Resolve-SmartTarFullPath $BasePath; $pathFull=Resolve-SmartTarFullPath $FullPath; if(Is-Blank $baseFull -or Is-Blank $pathFull){return (Split-Path -Leaf $FullPath)}; $baseClean=$baseFull -replace '[\/]+$',''; $prefix=$baseClean+[System.IO.Path]::DirectorySeparatorChar; if($pathFull.ToLowerInvariant().StartsWith($prefix.ToLowerInvariant())){return $pathFull.Substring($prefix.Length)}; return (Split-Path -Leaf $pathFull) }
function Get-SourceSize { param([string]$Path) try{$item=Get-Item -LiteralPath (Repair-WindowsPath $Path) -ErrorAction Stop; if(-not $item.PSIsContainer){return [int64]$item.Length}; $sum=[int64]0; Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue|ForEach-Object{$sum+=[int64]$_.Length}; return $sum}catch{return [int64]0} }
function Get-SortedSourceFiles { param($SourceItem,[string]$Source,[string]$BaseRoot="") if(-not $SourceItem.PSIsContainer){return @($SourceItem)}; return @(Get-ChildItem -LiteralPath (Repair-WindowsPath $Source) -File -Recurse -Force -ErrorAction SilentlyContinue|Sort-Object @{Expression={(Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant()}},@{Expression={Get-RelativePathFromBase $BaseRoot $_.FullName}}) }
function Get-SortedSourceDirs { param($SourceItem,[string]$Source,[string]$BaseRoot) if(-not $SourceItem.PSIsContainer){return @()}; $dirs=@(); $dirs+=Get-Item -LiteralPath (Repair-WindowsPath $Source) -Force; $dirs+=@(Get-ChildItem -LiteralPath (Repair-WindowsPath $Source) -Directory -Recurse -Force -ErrorAction SilentlyContinue); return @($dirs|Sort-Object @{Expression={(Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant()}},@{Expression={Get-RelativePathFromBase $BaseRoot $_.FullName}}) }
function Get-SourceProfile { param($SourceItem,[string]$Source) $p=@{text=[int64]0;binary=[int64]0;executable=[int64]0;diskimage=[int64]0;media=[int64]0;archives=[int64]0;unknown=[int64]0;files=0}; foreach($f in (Get-SortedSourceFiles $SourceItem $Source)){ $g=Get-SmartGroupName $f.FullName; $p[$g]=[int64]$p[$g]+[int64]$f.Length; $p.files++}; return $p }
function Select-AutoSolidMethod { param([hashtable]$Capabilities,[hashtable]$Profile) $zstd=Select-ZstdOrBest $Capabilities; $xz=Select-XzOrBest $Capabilities; if($Capabilities.ContainsKey("zstd19") -and $Capabilities["zstd19"]){$binaryLike=[int64]$Profile.binary+[int64]$Profile.executable+[int64]$Profile.diskimage; if($binaryLike -gt [int64]$Profile.text){return $zstd}}; return $xz }
function New-GroupInfo { param([string]$Name,[hashtable]$Method,[string]$Stage,[string]$Reason) return @{Name=$Name;Method=$Method;Reason=$Reason;FileCount=0;DirCount=0;Bytes=[int64]0;Stage=$Stage} }
function New-ArchiveGroups { param([string]$Mode,[hashtable]$Capabilities,[hashtable]$Profile,[string]$StagingRoot) $store=Select-StoreMethod $Capabilities; $xz=Select-XzOrBest $Capabilities; $zstd=Select-ZstdOrBest $Capabilities; $groups=[ordered]@{}; switch($Mode){"Solid"{$groups["solid"]=New-GroupInfo "solid" (Select-AutoSolidMethod $Capabilities $Profile) (Join-Path $StagingRoot "solid") "Auto solid method selected."}"SmartXZ"{$groups["structure"]=New-GroupInfo "structure" $store (Join-Path $StagingRoot "structure") "Directory structure.";$groups["text"]=New-GroupInfo "text" $xz (Join-Path $StagingRoot "text") "Text XZ.";$groups["binary"]=New-GroupInfo "binary" $xz (Join-Path $StagingRoot "binary") "Binary XZ.";$groups["executable"]=New-GroupInfo "executable" $xz (Join-Path $StagingRoot "executable") "Executable XZ.";$groups["diskimage"]=New-GroupInfo "diskimage" $xz (Join-Path $StagingRoot "diskimage") "Disk image XZ.";$groups["media"]=New-GroupInfo "media" $store (Join-Path $StagingRoot "media") "Media stored.";$groups["archives"]=New-GroupInfo "archives" $store (Join-Path $StagingRoot "archives") "Archives stored.";$groups["unknown"]=New-GroupInfo "unknown" $xz (Join-Path $StagingRoot "unknown") "Unknown XZ."}"Smart"{$groups["structure"]=New-GroupInfo "structure" $store (Join-Path $StagingRoot "structure") "Directory structure.";$groups["text"]=New-GroupInfo "text" $xz (Join-Path $StagingRoot "text") "Text XZ.";$groups["binary"]=New-GroupInfo "binary" $zstd (Join-Path $StagingRoot "binary") "Binary ZSTD.";$groups["executable"]=New-GroupInfo "executable" $zstd (Join-Path $StagingRoot "executable") "Executable ZSTD.";$groups["diskimage"]=New-GroupInfo "diskimage" $zstd (Join-Path $StagingRoot "diskimage") "Disk image ZSTD.";$groups["media"]=New-GroupInfo "media" $store (Join-Path $StagingRoot "media") "Media stored.";$groups["archives"]=New-GroupInfo "archives" $store (Join-Path $StagingRoot "archives") "Archives stored.";$groups["unknown"]=New-GroupInfo "unknown" $xz (Join-Path $StagingRoot "unknown") "Unknown XZ."}default{$groups["structure"]=New-GroupInfo "structure" $store (Join-Path $StagingRoot "structure") "Directory structure.";$groups["compressible"]=New-GroupInfo "compressible" $xz (Join-Path $StagingRoot "compressible") "Compressible XZ.";$groups["diskimage"]=New-GroupInfo "diskimage" $zstd (Join-Path $StagingRoot "diskimage") "Disk image ZSTD.";$groups["stored"]=New-GroupInfo "stored" $store (Join-Path $StagingRoot "stored") "Media and archives stored."}}; return $groups }
function Test-GroupUsesXz { param($Group) try{return ([string]$Group.Method.Algorithm -eq "xz")}catch{return $false} }
function Test-AnyXzGroup { param([hashtable]$Groups) foreach($k in $Groups.Keys){if(Test-GroupUsesXz $Groups[$k]){return $true}}; return $false }
function Copy-FileToGroupStage { param([string]$SourceFile,[string]$RelativePath,[string]$GroupStageRoot) $target=Join-Path $GroupStageRoot $RelativePath; $dir=Split-Path -Parent $target; if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}; Copy-Item -LiteralPath $SourceFile -Destination $target -Force }
function Create-DirInGroupStage { param([string]$RelativePath,[string]$GroupStageRoot) New-Item -ItemType Directory -Path (Join-Path $GroupStageRoot $RelativePath) -Force|Out-Null }
function Stage-Directories { param($SourceItem,[string]$Source,[string]$BaseRoot,[string]$Mode,[hashtable]$Groups) if(-not $SourceItem.PSIsContainer){return}; $targetGroup=if($Mode -eq "Solid"){"solid"}else{"structure"}; foreach($d in (Get-SortedSourceDirs $SourceItem $Source $BaseRoot)){ $rel=Get-RelativePathFromBase $BaseRoot $d.FullName; Create-DirInGroupStage $rel $Groups[$targetGroup].Stage; $Groups[$targetGroup].DirCount=[int]$Groups[$targetGroup].DirCount+1 } }
function Stage-Files { param($SourceItem,[string]$Source,[string]$BaseRoot,[string]$Mode,[hashtable]$Groups) Set-AppStatus "Copying files into reliable local staging..." ([System.Drawing.Color]::DarkOrange); foreach($file in (Get-SortedSourceFiles $SourceItem $Source $BaseRoot)){ $relative=Get-RelativePathFromBase $BaseRoot $file.FullName; $groupName=Get-ModeGroupName $Mode (Get-SmartGroupName $file.FullName); Copy-FileToGroupStage $file.FullName $relative $Groups[$groupName].Stage; $Groups[$groupName].FileCount=[int]$Groups[$groupName].FileCount+1; $Groups[$groupName].Bytes=[int64]$Groups[$groupName].Bytes+[int64]$file.Length } }

# ============================================================================
# 06. blocks manifest extraction
# ============================================================================
function Create-BlockFromStage { param([string]$TarPath,[string]$StagePath,[string]$BlockPath,[hashtable]$Method) if(-not(Test-Path -LiteralPath $StagePath)){throw "Stage path does not exist: $StagePath"}; $args=@(); $args+=$Method.CreateArgs; $args+=$BlockPath; $args+="-C"; $args+=$StagePath; $args+="."; Invoke-Tar $TarPath $args "Block creation failed: $BlockPath." }
function Build-Blocks { param([string]$TarPath,[hashtable]$Groups,[string]$BlocksDir) Set-AppStatus "Creating internal blocks..." ([System.Drawing.Color]::DarkOrange); $list=@(); $index=1; foreach($groupName in $Groups.Keys){$group=$Groups[$groupName]; if(-not(([int]$group.FileCount -gt 0) -or ([int]$group.DirCount -gt 0))){continue}; $blockId="{0:D6}" -f $index; $method=$group.Method; $clean=[string]$group.Name; $ext=[string]$method.Extension; $blockName="$blockId`_$clean$ext"; $blockPath=Join-Path $BlocksDir $blockName; Create-BlockFromStage $TarPath $group.Stage $blockPath $method; $item=Get-Item -LiteralPath $blockPath; $list += [ordered]@{id=$blockId;group=$clean;path="blocks/$blockName";container="tar";compression=[string]$method.Algorithm;method=[string]$method.Name;display=[string]$method.Display;level=$method.Level;extension=$ext;tarArgs=(($method.CreateArgs+@("-C","<stage>","."))-join " ");reason=[string]$group.Reason;fileCount=[int]$group.FileCount;dirCount=[int]$group.DirCount;sourceBytes=[int64]$group.Bytes;sizeBytes=[int64]$item.Length;sha256=Get-FileSHA256 $blockPath}; $index++}; return $list }
function Write-Manifest { param([string]$Path,$Data) $Data|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding UTF8 }
function Build-Manifest { param([string]$Source,$SourceItem,[string]$SourceLeaf,[string]$Mode,[hashtable]$CapabilityMap,[hashtable]$Profile,$BlockList) $name=$SourceLeaf; if($SourceLeaf -eq "."){$name=Split-Path -Leaf ($Source -replace '[\/]+$','')}; $type=if($SourceItem.PSIsContainer){"Folder"}else{"File"}; $xzBlocks=@(@($BlockList)|Where-Object{[string]$_.compression -eq "xz"}); $det=$xzBlocks.Count -gt 0; return [ordered]@{format="STAR";formatVersion=1;tool="SmartTAR";version=21;toolVersion="1.0-beta1-fix5-path-safe-exe";createdUtc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");engine="Windows tar.exe";archiveEngine="reliable-local-staging-safe-extract";model="auto-planner-v1.0-beta1-fix5";compressionMode=$Mode;sourceName=$name;sourceType=$type;sourceBytes=Get-SourceSize $Source;grouping="auto-planned";planning=[ordered]@{strategy="auto";rulesVersion="smart-plan-v1";xzMaxLevel=9;zstdMaxLevel=19;defaultMode="Hybrid";experimentalModes=@("SmartXZ");defaultExtension=".star";legacyExtensions=@(".sarc.tar");design="Transparent TAR outer container with SmartTAR block manifest. Creation uses reliable staging. Extraction target is parent folder."};deterministicMetadata=[ordered]@{enabled=$det;timestampUtc=if($det){Get-FixedUtcText}else{"not-normalized"};scope=if($det){"XZ/XZ9-blocks"}else{"none"};note="Timestamps are normalized only for XZ/XZ9 stages."};sourceProfile=$Profile;capabilities=[ordered]@{store=[bool]$CapabilityMap.store;gzip=[bool]$CapabilityMap.gzip;bzip2=[bool]$CapabilityMap.bzip2;xz9=[bool]$CapabilityMap.xz9;xz=[bool]$CapabilityMap.xz;zstd19=[bool]$CapabilityMap.zstd19};blocks=@($BlockList);manualRecovery=@("tar -xf archive.star -C outer","tar -xf outer\blocks\000001_solid.tar.xz -C restore")} }
function Read-OuterManifest { param([string]$OuterRoot) $p=Join-Path $OuterRoot "manifest.json"; if(-not(Test-Path -LiteralPath $p)){throw "manifest.json was not found."}; $m=Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json; if($m.format -ne "STAR" -and $m.format -ne "SARC" -and $m.format -ne "SmartTarArc"){throw "Invalid archive format."}; return $m }
function Test-RelativePathSafe { param([string]$PathText) if(Is-Blank $PathText){return $false}; $p=([string]$PathText).Replace('\','/'); if($p -eq "." -or $p -eq "./"){return $true}; if($p -match '^[a-zA-Z]:'){return $false}; if($p.StartsWith("/") -or $p.StartsWith("//")){return $false}; foreach($part in @($p.Split('/')|Where-Object{-not [string]::IsNullOrWhiteSpace($_) -and $_ -ne "."})){if($part -eq ".."){return $false}}; return $true }
function Resolve-SafeBlockPath { param([string]$OuterRoot,[string]$RelativeBlockPath) if(-not(Test-RelativePathSafe $RelativeBlockPath)){throw "Unsafe block path detected in manifest: $RelativeBlockPath"}; return Join-Path $OuterRoot ($RelativeBlockPath -replace '/', [System.IO.Path]::DirectorySeparatorChar) }
function Test-ArchiveEntriesSafe { param([string]$TarPath,[string]$ArchivePath) $entries=& $TarPath @("-tf",$ArchivePath) 2>&1; if($LASTEXITCODE -ne 0){throw "Cannot list TAR block before extraction: $ArchivePath`r`n$(($entries|Out-String).Trim())"}; foreach($e in $entries){if(-not(Test-RelativePathSafe ([string]$e))){throw "Unsafe path inside TAR block detected: $e"}} }
function Copy-ExtractedTreeToDestination { param([string]$SourceRoot,[string]$DestinationRoot) if(-not(Test-Path -LiteralPath $SourceRoot)){return}; if(-not(Test-Path -LiteralPath $DestinationRoot)){New-Item -ItemType Directory -Path $DestinationRoot -Force|Out-Null}; Get-ChildItem -LiteralPath $SourceRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue|ForEach-Object{$rel=$_.FullName.Substring($SourceRoot.Length).TrimStart('\','/'); if(-not(Is-Blank $rel)){ $targetDir=Join-Path $DestinationRoot $rel; if(-not(Test-Path -LiteralPath $targetDir)){New-Item -ItemType Directory -Path $targetDir -Force|Out-Null}}}; Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force -ErrorAction SilentlyContinue|ForEach-Object{$rel=$_.FullName.Substring($SourceRoot.Length).TrimStart('\','/'); $targetFile=Join-Path $DestinationRoot $rel; $targetDir=Split-Path -Parent $targetFile; if(-not(Test-Path -LiteralPath $targetDir)){New-Item -ItemType Directory -Path $targetDir -Force|Out-Null}; Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force} }
function Extract-Blocks { param([string]$TarPath,[string]$OuterRoot,$Blocks,[string]$DestinationFolder,[bool]$SkipFailedBlocks=$false) Set-AppStatus "Extracting internal blocks through safe staging..." ([System.Drawing.Color]::DarkOrange); $blockWorkRoot=New-SmartTarSafeWorkDir "extract_blocks"; try{foreach($block in $Blocks){$relativePath=[string]$block.path; $blockPath=Resolve-SafeBlockPath $OuterRoot $relativePath; if(-not(Test-Path -LiteralPath $blockPath)){if($SkipFailedBlocks){continue}; throw "Block file was not found: $relativePath"}; if($block.sha256){$actualHash=Get-FileSHA256 $blockPath; if($actualHash -ne ([string]$block.sha256).ToLowerInvariant()){if($SkipFailedBlocks){continue}; throw "Block SHA256 mismatch: $relativePath"}}; Test-ArchiveEntriesSafe $TarPath $blockPath; $blockExtractDir=Join-Path $blockWorkRoot ([string]$block.id); New-Item -ItemType Directory -Path $blockExtractDir -Force|Out-Null; Invoke-Tar $TarPath @("-xf",$blockPath,"-C",$blockExtractDir) "Block extraction failed in safe staging: $relativePath."; Copy-ExtractedTreeToDestination $blockExtractDir $DestinationFolder}}finally{Remove-SmartTarWorkDir $blockWorkRoot} }
function Get-SmartArchiveManifestPreview { param([string]$TarPath,[string]$ArchivePath) $work=New-SmartTarSafeWorkDir "preview"; $outer=Join-Path $work "outer"; New-Item -ItemType Directory -Path $outer -Force|Out-Null; try{$safeArchive=Join-Path $work "input.star"; Copy-Item -LiteralPath (Repair-WindowsPath $ArchivePath) -Destination $safeArchive -Force; Invoke-Tar $TarPath @("-xf",$safeArchive,"-C",$outer) "Outer .star preview extraction failed."; return (Read-OuterManifest $outer)}finally{Remove-SmartTarWorkDir $work} }
function Get-ExpectedExtractionRootPath { param($Manifest,[string]$DestinationParent) $sourceName=[string]$Manifest.sourceName; if(Is-Blank $sourceName -or $sourceName -eq "."){return ""}; if(-not(Test-RelativePathSafe $sourceName)){return ""}; return (Join-Path $DestinationParent $sourceName) }
function Get-UsedMethodReport { param($Blocks,$Manifest) $methodMap=@{}; foreach($block in @($Blocks)){$display=[string]$block.display; $compression=[string]$block.compression; if(Is-Blank $display){$display=[string]$block.method}; if(Is-Blank $compression){$compression="n/a"}; $key="{0}/{1}" -f $display,$compression; if(-not $methodMap.ContainsKey($key)){$methodMap[$key]=0}; $methodMap[$key]=[int]$methodMap[$key]+1}; $used=if($methodMap.Count -gt 0){(($methodMap.Keys|Sort-Object|ForEach-Object{"{0} x{1}" -f $_,$methodMap[$_]}) -join ", ")}else{"n/a"}; return @{Used=$used;Zstd="n/a"} }
function Verify-SmartArchive { param([string]$TarPath,[string]$ArchivePath) $work=New-SmartTarSafeWorkDir "verify"; $outer=Join-Path $work "outer"; New-Item -ItemType Directory -Path $outer -Force|Out-Null; try{Set-AppStatus "Verifying outer container through safe staging..." ([System.Drawing.Color]::DarkOrange); $safeArchive=Join-Path $work "input.star"; Copy-Item -LiteralPath (Repair-WindowsPath $ArchivePath) -Destination $safeArchive -Force; Invoke-Tar $TarPath @("-xf",$safeArchive,"-C",$outer) "Outer .star verification failed."; $m=Read-OuterManifest $outer; $blocks=@($m.blocks); if($blocks.Count -lt 1){throw "Manifest does not contain any blocks."}; $methodReport=Get-UsedMethodReport $blocks $m; $ok=0; $fail=0; $total=[int64]0; $lines=@(); foreach($b in $blocks){$bp=Resolve-SafeBlockPath $outer ([string]$b.path); if(-not(Test-Path -LiteralPath $bp)){$fail++; $lines += "  $($b.id) | $($b.group) | MISSING | $($b.path)"; continue}; $listed=Invoke-TarList $TarPath $bp; $hashOk=$true; if($b.sha256){$hashOk=((Get-FileSHA256 $bp) -eq ([string]$b.sha256).ToLowerInvariant())}; $actualSize=[int64](Get-Item -LiteralPath $bp).Length; $total+=$actualSize; if($listed -and $hashOk){$ok++}else{$fail++}; $status=if($listed -and $hashOk){"OK"}elseif($listed){"HASH FAIL"}else{"FAIL"}; $lines += ("  {0} | {1} | {2} | {3} | {4}" -f $b.id,$b.group,$b.display,$status,(Format-Bytes $actualSize))}; $verificationStatus=if($fail -gt 0){"Archive verification PARTIAL / FAILED"}else{"Archive verification OK (Integrity verified)"}; $archiveBytes=[int64](Get-Item -LiteralPath (Repair-WindowsPath $ArchivePath)).Length; return @"
$verificationStatus

Format: $($m.format)
Tool: $($m.tool)
Version: $($m.toolVersion)
Model: $($m.model)
Archive engine: $($m.archiveEngine)
Mode: $($m.compressionMode)
Used methods: $($methodReport.Used)
Blocks: $($blocks.Count)
Blocks OK: $ok
Blocks failed: $fail
Files declared: $(($blocks | Measure-Object -Property fileCount -Sum).Sum)
Dirs declared: $(($blocks | Measure-Object -Property dirCount -Sum).Sum)
Source size declared: $(Format-Bytes ([int64]$m.sourceBytes))
Archive size: $(Format-Bytes $archiveBytes)
Internal block bytes: $(Format-Bytes $total)

Blocks:
$($lines -join "`r`n")
"@}finally{Remove-SmartTarWorkDir $work} }
function Get-ArchiveSummary { param([string]$TarPath,[string]$ArchivePath,[string]$SourcePath) $sourceBytes=Get-SourceSize $SourcePath; $archiveBytes=[int64](Get-Item -LiteralPath (Repair-WindowsPath $ArchivePath)).Length; $ratio="n/a"; $saved="n/a"; if($sourceBytes -gt 0 -and $archiveBytes -gt 0){$ratio="{0:N2} %" -f (($archiveBytes/$sourceBytes)*100); $saved="{0:N2} %" -f ((1-($archiveBytes/$sourceBytes))*100)}; $verify=Verify-SmartArchive $TarPath $ArchivePath; return @"
Archive created successfully.

Source size: $(Format-Bytes $sourceBytes)
Archive size: $(Format-Bytes $archiveBytes)
Ratio: $ratio
Saved: $saved

$verify
"@ }

# ============================================================================
# 07. operations
# ============================================================================
function Compress-SmartArchive { param([string]$TarPath,[string]$Source,[string]$Destination,[string]$Mode) $Source=Repair-WindowsPath $Source; $Destination=Repair-WindowsPath $Destination; if(-not(Test-Path -LiteralPath $TarPath)){throw "tar.exe was not found."}; if(-not(Test-Path -LiteralPath $Source)){throw "Source path does not exist."}; if((Get-NormalizedFullPath $Source).ToLowerInvariant() -eq (Get-NormalizedFullPath $Destination).ToLowerInvariant()){throw "Destination cannot be the same as source."}; if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force}; if(Is-Blank $Mode){$Mode="Hybrid"}; if($Mode -ne "Solid" -and $Mode -ne "Hybrid" -and $Mode -ne "Smart" -and $Mode -ne "SmartXZ"){$Mode="Hybrid"}; Set-AppStatus "Checking TAR capabilities..." ([System.Drawing.Color]::DarkOrange); $cap=Test-TarCapabilities $TarPath; if(-not $cap.store){throw "No usable tar store method was found."}; $work=New-SmartTarSafeWorkDir "create"; $blocksDir=Join-Path $work "blocks"; $stageRoot=Join-Path $work "staging"; New-Item -ItemType Directory -Path $work,$blocksDir,$stageRoot -Force|Out-Null; try{Set-AppStatus "Analyzing source and creating compression plan..." ([System.Drawing.Color]::DarkOrange); $sourceItem=Get-Item -LiteralPath $Source -Force; $sourceParent=Split-Path -Parent $Source; $sourceLeaf=Split-Path -Leaf $Source; if(Is-Blank $sourceParent){$sourceParent=(Get-Location).Path}; if(Is-Blank $sourceLeaf){$sourceParent=$Source; $sourceLeaf="."}; $profile=Get-SourceProfile $sourceItem $Source; $groups=New-ArchiveGroups $Mode $cap $profile $stageRoot; foreach($key in $groups.Keys){New-Item -ItemType Directory -Path $groups[$key].Stage -Force|Out-Null}; Stage-Directories $sourceItem $Source $sourceParent $Mode $groups; Stage-Files $sourceItem $Source $sourceParent $Mode $groups; $hasXz=Test-AnyXzGroup $groups; if($hasXz){foreach($key in $groups.Keys){if(Test-GroupUsesXz $groups[$key]){Set-TreeTimestamp $groups[$key].Stage (Get-FixedUtcTime)}}}; $blockList=Build-Blocks $TarPath $groups $blocksDir; if($blockList.Count -lt 1){throw "No blocks were created. Source may be empty or inaccessible."}; $manifest=Build-Manifest $Source $sourceItem $sourceLeaf $Mode $cap $profile $blockList; Write-Manifest (Join-Path $work "manifest.json") $manifest; if($hasXz){Set-TreeTimestamp $work (Get-FixedUtcTime)}; Set-AppStatus "Creating outer .star container..." ([System.Drawing.Color]::DarkOrange); $safeOut=Join-Path $work "output.star"; Invoke-Tar $TarPath @("-cf",$safeOut,"-C",$work,"manifest.json","blocks") "Outer .star archive creation failed."; Move-Item -LiteralPath $safeOut -Destination $Destination -Force; if(-not(Test-Path -LiteralPath $Destination)){throw "Output archive was not created."}}finally{Remove-SmartTarWorkDir $work} }
function Extract-SmartArchive { param([string]$TarPath,[string]$ArchivePath,[string]$DestinationFolder) $ArchivePath=Repair-WindowsPath $ArchivePath; $DestinationFolder=Repair-WindowsPath $DestinationFolder; if(-not(Test-Path -LiteralPath $TarPath)){throw "tar.exe was not found."}; if(-not(Test-Path -LiteralPath $ArchivePath)){throw "Archive path does not exist."}; if(Is-Blank $DestinationFolder){throw "Destination folder is empty."}; if(-not(Test-Path -LiteralPath $DestinationFolder)){New-Item -ItemType Directory -Path $DestinationFolder -Force|Out-Null}; $work=New-SmartTarSafeWorkDir "extract_outer"; $outer=Join-Path $work "outer"; New-Item -ItemType Directory -Path $outer -Force|Out-Null; try{Set-AppStatus "Extracting outer container through safe staging..." ([System.Drawing.Color]::DarkOrange); $safeArchive=Join-Path $work "input.star"; Copy-Item -LiteralPath $ArchivePath -Destination $safeArchive -Force; Invoke-Tar $TarPath @("-xf",$safeArchive,"-C",$outer) "Outer .star extraction failed."; $m=Read-OuterManifest $outer; Extract-Blocks $TarPath $outer @($m.blocks) $DestinationFolder}finally{Remove-SmartTarWorkDir $work} }

# ============================================================================
# 08. path helpers and GUI events
# ============================================================================
function Is-SmartArchivePath { param([string]$Path) if(Is-Blank $Path){return $false}; return ([System.IO.Path]::GetFileName($Path) -match '(?i)(\.star|\.sarc\.tar)$') }
function Ensure-StarExtension { param([string]$Path) $p=Repair-WindowsPath $Path; if(Is-Blank $p){return $p}; if($p -match '(?i)(\.star|\.sarc\.tar)$'){return $p}; return ($p+".star") }
function Get-DefaultArchiveBaseName { param([string]$Path,[string]$Type) $leaf=Split-Path -Leaf (Repair-WindowsPath $Path); if(Is-Blank $leaf){return "archive_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")}; if($Type -eq "Folder"){return $leaf}; return [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
function Get-DefaultExtractBaseName { param([string]$Path) $name=[System.IO.Path]::GetFileName($Path); if(Is-Blank $name){return "extracted_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")}; if($name -match '^(.*)\.star$'){return $matches[1]}; if($name -match '^(.*)\.sarc\.tar$'){return $matches[1]}; return [System.IO.Path]::GetFileNameWithoutExtension($name) }
function Get-SelectedCompressionMode { $text=[string]$cmbMode.SelectedItem; if($text -like "Smart XZ*"){return "SmartXZ"}; if($text -like "Smart*"){return "Smart"}; if($text -like "Solid*"){return "Solid"}; return "Hybrid" }
function Set-DefaultTarget { if(Is-Blank $script:selectedPath){return}; $parent=Split-Path -Parent (Repair-WindowsPath $script:selectedPath); if(Is-Blank $parent){$parent=$scriptDir}; if($script:selectedType -eq "File" -and (Is-SmartArchivePath $script:selectedPath)){$txtTarget.Text=$parent; return}; $txtTarget.Text=Join-Path $parent ((Get-DefaultArchiveBaseName $script:selectedPath $script:selectedType)+".star") }
function Set-SelectedPath { param([string]$Path,[ValidateSet("File","Folder")][string]$Type) $script:selectedPath=Repair-WindowsPath $Path; $script:selectedType=$Type; $lblSelected.Text="Selected: $script:selectedPath"; if($Type -eq "File"){if(Is-SmartArchivePath $Path){$btnFile.BackColor=$cBg; $btnArchive.BackColor=[System.Drawing.Color]::LightBlue}else{$btnFile.BackColor=[System.Drawing.Color]::LightBlue; $btnArchive.BackColor=$cBg}; $btnFolder.BackColor=$cBg}else{$btnFile.BackColor=$cBg; $btnArchive.BackColor=$cBg; $btnFolder.BackColor=[System.Drawing.Color]::LightBlue}; Set-DefaultTarget }

$form=New-UiObject "System.Windows.Forms.Form" @{Text="SmartTAR STAR 1.0 Beta 1 Fix 5 - Path Safe EXE";ClientSize=(New-Size 505 455);StartPosition="CenterScreen";BackColor=$cBg;FormBorderStyle="FixedSingle";MaximizeBox=$false;TopMost=$false}
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
[void]$cmbMode.Items.Add("Hybrid - recommended, balanced planner")
[void]$cmbMode.Items.Add("Smart - detailed grouped blocks")
[void]$cmbMode.Items.Add("Solid - one auto-selected block")
[void]$cmbMode.Items.Add("Smart XZ - grouped XZ9 blocks")
$cmbMode.SelectedIndex=0
$lblInfo=New-EcoLabel "Path-safe EXE build; safe temp staging with cleanup" 20 252 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$btnCompress=New-EcoButton "COMPRESS" 20 287 150 42 $fBold ([System.Drawing.Color]::SeaGreen) ([System.Drawing.Color]::White)
$btnExtract=New-EcoButton "EXTRACT" 177 287 150 42 $fBold ([System.Drawing.Color]::SteelBlue) ([System.Drawing.Color]::White)
$btnVerify=New-EcoButton "VERIFY" 334 287 151 42 $fBold ([System.Drawing.Color]::DarkSlateGray) ([System.Drawing.Color]::White)
$chkOpenFolder=New-EcoCheck "Open output folder after success" 20 342 300 $true
$lblStatus=New-EcoLabel "Ready." 20 382 465 20 $fItalic ([System.Drawing.Color]::DimGray)
$progressBar=New-UiObject "System.Windows.Forms.ProgressBar" @{Location=(New-Point 20 425);Size=(New-Size 465 8);Style=[System.Windows.Forms.ProgressBarStyle]::Marquee;MarqueeAnimationSpeed=25;Visible=$false}
$form.Controls.AddRange([System.Windows.Forms.Control[]]@($lblInput,$btnFile,$btnFolder,$btnArchive,$lblSelected,$lblTarget,$txtTarget,$btnTarget,$lblMode,$cmbMode,$lblInfo,$btnCompress,$btnExtract,$btnVerify,$chkOpenFolder,$lblStatus,$progressBar))
$cmbMode.Add_SelectedIndexChanged({$mode=Get-SelectedCompressionMode; if($mode -eq "Solid"){$lblInfo.Text="Solid = one block; safe staging used for create/extract"}elseif($mode -eq "SmartXZ"){$lblInfo.Text="Smart XZ = grouped XZ9 blocks; safe staging used"}elseif($mode -eq "Smart"){$lblInfo.Text="Smart = grouped blocks; safe staging used"}else{$lblInfo.Text="Hybrid = recommended; path-safe EXE mode"}})
$btnFile.Add_Click({$d=New-Object System.Windows.Forms.OpenFileDialog; $d.Title="Select file"; $d.Filter="All files (*.*)|*.*"; try{if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Set-SelectedPath $d.FileName "File"}}finally{$d.Dispose()}})
$btnFolder.Add_Click({$d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description="Select folder to archive"; try{if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Set-SelectedPath $d.SelectedPath "Folder"}}finally{$d.Dispose()}})
$btnArchive.Add_Click({$d=New-Object System.Windows.Forms.OpenFileDialog; $d.Title="Select SmartTAR archive"; $d.Filter="SmartTAR Archive (*.star)|*.star|Legacy SmartTAR Archive (*.sarc.tar)|*.sarc.tar|All files (*.*)|*.*"; try{if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Set-SelectedPath $d.FileName "File"}}finally{$d.Dispose()}})
$btnTarget.Add_Click({if($script:selectedType -eq "File" -and (Is-SmartArchivePath $script:selectedPath)){ $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description="Select extraction parent folder"; try{if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$txtTarget.Text=Repair-WindowsPath $d.SelectedPath}}finally{$d.Dispose()}; return}; $d=New-Object System.Windows.Forms.SaveFileDialog; $d.Title="Select destination archive"; $d.Filter="SmartTAR Archive (*.star)|*.star|Legacy SmartTAR Archive (*.sarc.tar)|*.sarc.tar|All files (*.*)|*.*"; $d.DefaultExt="star"; $d.AddExtension=$true; $d.OverwritePrompt=$true; try{if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$txtTarget.Text=Ensure-StarExtension $d.FileName}}finally{$d.Dispose()}})

function Execute-Compress { if(-not(Test-Path -LiteralPath $tarPath)){Msg "tar.exe was not found." "Missing TAR Engine" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}; if(Is-Blank $script:selectedPath){Msg "Please select a file or folder first." "Missing Input" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}; if(Is-Blank $txtTarget.Text){Msg "Please select destination archive path." "Missing Destination" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}; if(-not(Test-Path -LiteralPath $script:selectedPath)){Msg "Selected input path does not exist." "Input Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}; $targetPath=Ensure-StarExtension (Repair-WindowsPath ($txtTarget.Text.Trim('"'))); $txtTarget.Text=$targetPath; $targetDir=[System.IO.Path]::GetDirectoryName($targetPath); if(Is-Blank $targetDir){$targetDir=$scriptDir; $targetPath=Join-Path $targetDir ([System.IO.Path]::GetFileName($targetPath)); $txtTarget.Text=$targetPath}; if(-not(Test-Path -LiteralPath $targetDir)){Msg "Destination directory does not exist:`n$targetDir" "Destination Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}; if(Test-Path -LiteralPath $targetPath){$confirm=Msg "Target archive already exists. Overwrite it?" "Overwrite Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo); if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){return}}; $mode=Get-SelectedCompressionMode; Start-UiWork; $success=$false; $errorMessage=$null; try{Compress-SmartArchive $tarPath $script:selectedPath $targetPath $mode; $success=$true}catch{$errorMessage=Get-ErrorDetails $_}finally{Stop-UiWork}; if($success){Set-AppStatus "Archive created successfully. Mode: $mode." ([System.Drawing.Color]::Green); $reportPath=Get-ReportPath $targetPath "create_report"; try{$summary=Get-ArchiveSummary $tarPath $targetPath $script:selectedPath; [void](Write-ReportFile $reportPath $summary); Msg "$summary`r`nReport saved:`r`n$reportPath" "Archive Summary" ([System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null}catch{$verifyError=Get-ErrorDetails $_; $fallback="Archive created successfully, but automatic summary/verify failed.`r`n`r`nArchive: $targetPath`r`nMode: $mode`r`nSource: $($script:selectedPath)`r`nArchive size: $(Format-Bytes ([int64](Get-Item -LiteralPath $targetPath).Length))`r`n`r`nVerify/report error:`r`n$verifyError"; [void](Write-ReportFile $reportPath $fallback); Msg "$fallback`r`nReport saved:`r`n$reportPath" "Archive Created - Verify Report Failed" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}; if($chkOpenFolder.Checked){explorer.exe "/select,`"$targetPath`""}; return}; Set-AppStatus "Compression failed." ([System.Drawing.Color]::Red); Msg "Compression failed.`n`n$errorMessage" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null }
function Execute-Extract { if(Is-Blank $script:selectedPath){Msg "Please select a SmartTAR archive first." "Missing Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}; if($script:selectedType -ne "File"){Msg "Extraction input must be a .star file." "Invalid Input" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}; $destination=Repair-WindowsPath ($txtTarget.Text.Trim('"')); if(Is-Blank $destination){Msg "Please select extraction parent folder." "Missing Destination" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}; if(-not(Test-Path -LiteralPath $destination)){New-Item -ItemType Directory -Path $destination -Force|Out-Null}; $previewManifest=$null; Start-UiWork; try{$previewManifest=Get-SmartArchiveManifestPreview $tarPath $script:selectedPath}catch{$previewError=Get-ErrorDetails $_}finally{Stop-UiWork}; if($previewManifest -eq $null){Msg "Cannot read archive manifest.`n`n$previewError" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null; return}; $expectedRoot=Get-ExpectedExtractionRootPath $previewManifest $destination; if(-not(Is-Blank $expectedRoot) -and (Test-Path -LiteralPath $expectedRoot)){$confirm=Msg "Target already exists:`r`n$expectedRoot`r`n`r`nOverwrite / merge existing files?" "Overwrite Existing Target" ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo); if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){Set-AppStatus "Extraction cancelled by user." ([System.Drawing.Color]::DimGray); return}}; Start-UiWork; $success=$false; $errorMessage=$null; try{Extract-SmartArchive $tarPath $script:selectedPath $destination; $success=$true}catch{$errorMessage=Get-ErrorDetails $_}finally{Stop-UiWork}; $reportPath=Get-ReportPath $script:selectedPath "extract_report"; if($success){Set-AppStatus "Archive extracted successfully." ([System.Drawing.Color]::Green); $text="Archive extracted successfully.`r`nArchive: $($script:selectedPath)`r`nExtraction parent folder: $destination"; if(-not(Is-Blank $expectedRoot)){$text += "`r`nExpected extracted root: $expectedRoot"}; [void](Write-ReportFile $reportPath $text); Msg "$text`r`nReport saved:`r`n$reportPath" "Extract Archive" ([System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null; if($chkOpenFolder.Checked){explorer.exe "`"$destination`""}; return}; [void](Write-ReportFile $reportPath "Extraction failed.`r`n`r`n$errorMessage"); Set-AppStatus "Extraction failed." ([System.Drawing.Color]::Red); Msg "Extraction failed.`n`n$errorMessage`n`nReport saved:`n$reportPath" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null }
function Execute-Verify { if(Is-Blank $script:selectedPath -or $script:selectedType -ne "File" -or -not(Test-Path -LiteralPath $script:selectedPath)){Msg "Please select an existing .star archive." "Invalid Archive" ([System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return}; Start-UiWork; $success=$false; $errorMessage=$null; $summary=$null; try{$summary=Verify-SmartArchive $tarPath $script:selectedPath; $success=$true}catch{$errorMessage=Get-ErrorDetails $_}finally{Stop-UiWork}; $reportPath=Get-ReportPath $script:selectedPath "verify_report"; if($success){[void](Write-ReportFile $reportPath $summary); Set-AppStatus "Archive verification finished." ([System.Drawing.Color]::Green); Msg "$summary`r`nReport saved:`r`n$reportPath" "Verify Archive" ([System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null; return}; [void](Write-ReportFile $reportPath "Verification failed.`r`n`r`n$errorMessage"); Set-AppStatus "Verification failed." ([System.Drawing.Color]::Red); Msg "Verification failed.`n`n$errorMessage`n`nReport saved:`n$reportPath" "SmartTAR Error" ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null }

$btnCompress.Add_Click({Execute-Compress})
$btnExtract.Add_Click({Execute-Extract})
$btnVerify.Add_Click({Execute-Verify})
$form.Add_FormClosing({$fNormal.Dispose();$fBold.Dispose();$fItalic.Dispose()})
[System.Windows.Forms.Application]::Run($form)