# ============================================================================
# SmartTAR - STAR v1.4.0
# Windows PowerShell GUI archiver using Windows tar.exe / bsdtar
# ============================================================================

param(
    [string]$WorkerConfigFile = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


# Browse selective extraction bridge.
# Streams one compressed inner TAR block directly from the outer STAR into a
# second tar.exe process. The compressed block is hashed while passing through
# RAM, so no temporary block file is required.
if (-not ('SmartTarStreamBridge' -as [type])) {
    Add-Type @"
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

public sealed class SmartTarStreamResult
{
    public int ProducerExitCode { get; set; }
    public int ConsumerExitCode { get; set; }
    public string ProducerError { get; set; }
    public string ConsumerError { get; set; }
    public string Sha256 { get; set; }
    public long StreamedBytes { get; set; }
}

public static class SmartTarStreamBridge
{
    private static string Q(string value)
    {
        if (value == null) return "\"\"";
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    public static SmartTarStreamResult Extract(
        string tarPath,
        string outerArchive,
        string blockEntry,
        string destination,
        string selectedPath,
        bool selectedIsFolder)
    {
        ProcessStartInfo producerInfo = new ProcessStartInfo();
        producerInfo.FileName = tarPath;
        producerInfo.Arguments = "-xOf " + Q(outerArchive) + " " + Q(blockEntry);
        producerInfo.UseShellExecute = false;
        producerInfo.CreateNoWindow = true;
        producerInfo.RedirectStandardOutput = true;
        producerInfo.RedirectStandardError = true;

        ProcessStartInfo consumerInfo = new ProcessStartInfo();
        consumerInfo.FileName = tarPath;
        StringBuilder consumerArgs = new StringBuilder();
        consumerArgs.Append("-xf - -C ").Append(Q(destination));
        if (!String.IsNullOrEmpty(selectedPath)) {
            if (selectedIsFolder) {
                consumerArgs.Append(" --include ").Append(Q(selectedPath));
                consumerArgs.Append(" --include ").Append(Q(selectedPath.TrimEnd('/') + "/*"));
            } else {
                consumerArgs.Append(' ').Append(Q(selectedPath));
            }
        }
        consumerInfo.Arguments = consumerArgs.ToString();
        consumerInfo.UseShellExecute = false;
        consumerInfo.CreateNoWindow = true;
        consumerInfo.RedirectStandardInput = true;
        consumerInfo.RedirectStandardOutput = true;
        consumerInfo.RedirectStandardError = true;

        using (Process producer = new Process())
        using (Process consumer = new Process())
        using (SHA256 sha = SHA256.Create())
        {
            producer.StartInfo = producerInfo;
            consumer.StartInfo = consumerInfo;
            StringBuilder producerError = new StringBuilder();
            StringBuilder consumerError = new StringBuilder();

            producer.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) lock (producerError) producerError.AppendLine(e.Data);
            };
            consumer.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) lock (consumerError) consumerError.AppendLine(e.Data);
            };
            consumer.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { };

            if (!consumer.Start()) throw new InvalidOperationException("Cannot start inner TAR extractor.");
            consumer.BeginErrorReadLine();
            consumer.BeginOutputReadLine();
            if (!producer.Start()) throw new InvalidOperationException("Cannot start outer STAR reader.");
            producer.BeginErrorReadLine();

            long total = 0;
            byte[] buffer = new byte[1024 * 1024];
            Stream source = producer.StandardOutput.BaseStream;
            Stream target = consumer.StandardInput.BaseStream;
            try {
                while (true) {
                    int read = source.Read(buffer, 0, buffer.Length);
                    if (read <= 0) break;
                    sha.TransformBlock(buffer, 0, read, buffer, 0);
                    target.Write(buffer, 0, read);
                    total += read;
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
            }
            finally {
                try { target.Flush(); } catch { }
                try { consumer.StandardInput.Close(); } catch { }
            }

            producer.WaitForExit();
            consumer.WaitForExit();
            string hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
            return new SmartTarStreamResult {
                ProducerExitCode = producer.ExitCode,
                ConsumerExitCode = consumer.ExitCode,
                ProducerError = producerError.ToString(),
                ConsumerError = consumerError.ToString(),
                Sha256 = hash,
                StreamedBytes = total
            };
        }
    }
}
"@
}

$script:UseNativeAnalyzer = $false
if (-not ('SmartTarNativeAnalyzer' -as [type])) {
    try {
Add-Type @"
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Threading.Tasks;

public sealed class SmartTarNativeAnalysisResult
{
    public string FullName { get; set; }
    public string Decision { get; set; }
    public bool Error { get; set; }
    public long SampleBytes { get; set; }
    public long ZeroBytes { get; set; }
    public bool EntropyAvailable { get; set; }
    public double Entropy { get; set; }
    public bool UniqueAvailable { get; set; }
    public int UniqueBytes { get; set; }

    public SmartTarNativeAnalysisResult()
    {
        FullName = String.Empty;
        Decision = "unknown";
        Error = false;
        SampleBytes = 0;
        ZeroBytes = 0;
        EntropyAvailable = false;
        Entropy = 0.0;
        UniqueAvailable = false;
        UniqueBytes = 0;
    }
}

public static class SmartTarNativeAnalyzer
{
    private static readonly HashSet<string> StoreExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz", ".zst", ".tar", ".tgz", ".tbz2", ".txz", ".cab",
        ".jar", ".war", ".ear", ".star", ".apk", ".epub", ".vsix", ".nupkg",
        ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".avif",
        ".mp3", ".aac", ".ogg", ".wma", ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".webm",
        ".pdf", ".tib", ".tibx", ".mrimg", ".adi", ".imgz", ".dmg"
    };

    public static SmartTarNativeAnalysisResult AnalyzeFile(string path, long fileSize, int maxBytes)
    {
        SmartTarNativeAnalysisResult result = new SmartTarNativeAnalysisResult();
        result.FullName = path ?? String.Empty;

        try
        {
            if (String.IsNullOrEmpty(path) || fileSize <= 0)
                return result;

            byte[] sample = ReadSample(path, fileSize, maxBytes);
            result.SampleBytes = sample.LongLength;
            long zeroBytes;
            int uniqueBytes;
            double entropy;
            double textScore;
            AnalyzeSample(
                sample,
                out zeroBytes,
                out uniqueBytes,
                out entropy,
                out textScore
            );
            result.ZeroBytes = zeroBytes;
            result.UniqueBytes = uniqueBytes;
            result.Entropy = entropy;
            result.UniqueAvailable = sample.Length > 0;
            result.EntropyAvailable = sample.Length > 0;

            string ext = Path.GetExtension(path);
            if (!String.IsNullOrEmpty(ext) && StoreExtensions.Contains(ext))
            {
                result.Decision = "archives";
                return result;
            }

            if (sample.Length < 1)
                return result;

            string magic = GetMagicGroup(sample);
            if (!String.IsNullOrEmpty(magic))
            {
                result.Decision = magic;
                return result;
            }

            if (textScore >= 0.80 && entropy < 7.90)
                result.Decision = "text";
            else if (entropy >= 7.92)
                result.Decision = "archives";
            else if (entropy >= 7.60 && textScore < 0.65)
                result.Decision = "binary";
            else
                result.Decision = "text";

            return result;
        }
        catch
        {
            result.Error = true;
            result.Decision = "unknown";
            return result;
        }
    }

    public static SmartTarNativeAnalysisResult[] AnalyzeFiles(
        string[] paths,
        long[] fileSizes,
        int maxBytes,
        int maxParallelism)
    {
        if (paths == null)
            throw new ArgumentNullException("paths");
        if (fileSizes == null)
            throw new ArgumentNullException("fileSizes");
        if (paths.Length != fileSizes.Length)
            throw new ArgumentException("Path and size arrays must have the same length.");

        SmartTarNativeAnalysisResult[] results =
            new SmartTarNativeAnalysisResult[paths.Length];
        if (paths.Length == 0)
            return results;

        ParallelOptions options = new ParallelOptions();
        options.MaxDegreeOfParallelism = Math.Max(1, maxParallelism);
        Parallel.For(0, paths.Length, options, delegate(int index)
        {
            results[index] = AnalyzeFile(paths[index], fileSizes[index], maxBytes);
        });
        return results;
    }

    private static byte[] ReadSample(string path, long fileSize, int maxBytes)
    {
        if (fileSize <= 0 || maxBytes <= 0)
            return new byte[0];

        int total = (int)Math.Min((long)maxBytes, fileSize);
        if (total <= 0)
            return new byte[0];

        byte[] buffer = new byte[total];
        using (FileStream stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            if (fileSize <= (long)maxBytes)
            {
                ReadInto(stream, buffer, 0, total);
                return buffer;
            }

            int first = total / 2;
            int last = total - first;

            stream.Seek(0, SeekOrigin.Begin);
            ReadInto(stream, buffer, 0, first);

            stream.Seek(-(long)last, SeekOrigin.End);
            ReadInto(stream, buffer, first, last);
        }
        return buffer;
    }

    private static void ReadInto(FileStream stream, byte[] buffer, int offset, int count)
    {
        int done = 0;
        while (done < count)
        {
            int read = stream.Read(buffer, offset + done, count - done);
            if (read <= 0)
                break;
            done += read;
        }
    }

    private static void AnalyzeSample(
        byte[] bytes,
        out long zeroBytes,
        out int uniqueBytes,
        out double entropy,
        out double textScore)
    {
        zeroBytes = 0;
        uniqueBytes = 0;
        entropy = 0.0;
        textScore = 0.0;
        if (bytes == null || bytes.Length == 0)
            return;

        int[] counts = new int[256];
        int printable = 0;
        int control = 0;

        for (int i = 0; i < bytes.Length; i++)
        {
            byte b = bytes[i];
            if (counts[b] == 0)
                uniqueBytes++;
            counts[b]++;

            if (b == 0)
            {
                zeroBytes++;
                continue;
            }

            if (b == 9 || b == 10 || b == 13 || (b >= 32 && b <= 126) || b >= 128)
                printable++;
            else if (b < 32)
                control++;
        }

        double length = (double)bytes.Length;
        for (int i = 0; i < 256; i++)
        {
            if (counts[i] > 0)
            {
                double p = (double)counts[i] / length;
                entropy -= p * (Math.Log(p) / Math.Log(2.0));
            }
        }
        textScore = ((double)printable / length) - (((double)zeroBytes / length) * 4.0) - (((double)control / length) * 2.0);
    }

    private static bool StartsWith(byte[] bytes, byte[] signature)
    {
        if (bytes == null || signature == null || bytes.Length < signature.Length)
            return false;
        for (int i = 0; i < signature.Length; i++)
            if (bytes[i] != signature[i]) return false;
        return true;
    }

    private static bool AsciiAt(byte[] bytes, int offset, string text)
    {
        if (bytes == null || String.IsNullOrEmpty(text))
            return false;
        byte[] chars = Encoding.ASCII.GetBytes(text);
        if (bytes.Length < offset + chars.Length)
            return false;
        for (int i = 0; i < chars.Length; i++)
            if (bytes[offset + i] != chars[i]) return false;
        return true;
    }

    private static string GetMagicGroup(byte[] bytes)
    {
        if (bytes == null || bytes.Length < 2)
            return String.Empty;

        if (StartsWith(bytes, new byte[] { 0xEF, 0xBB, 0xBF })) return "text";
        if (StartsWith(bytes, new byte[] { 0xFF, 0xFE })) return "text";
        if (StartsWith(bytes, new byte[] { 0xFE, 0xFF })) return "text";

        byte[][] archiveSignatures = new byte[][]
        {
            new byte[] { 0x50, 0x4B, 0x03, 0x04 }, new byte[] { 0x50, 0x4B, 0x05, 0x06 }, new byte[] { 0x50, 0x4B, 0x07, 0x08 },
            new byte[] { 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C },
            new byte[] { 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 }, new byte[] { 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 },
            new byte[] { 0x1F, 0x8B }, new byte[] { 0x42, 0x5A, 0x68 }, new byte[] { 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 },
            new byte[] { 0x28, 0xB5, 0x2F, 0xFD }, new byte[] { 0x4D, 0x53, 0x43, 0x46 }, new byte[] { 0xFF, 0xD8, 0xFF },
            new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, new byte[] { 0x47, 0x49, 0x46, 0x38 },
            new byte[] { 0x25, 0x50, 0x44, 0x46 }, new byte[] { 0x1A, 0x45, 0xDF, 0xA3 }, new byte[] { 0x4F, 0x67, 0x67, 0x53 },
            new byte[] { 0x66, 0x4C, 0x61, 0x43 }
        };

        for (int i = 0; i < archiveSignatures.Length; i++)
            if (StartsWith(bytes, archiveSignatures[i])) return "archives";

        if (AsciiAt(bytes, 8, "WEBP")) return "archives";
        if (AsciiAt(bytes, 4, "ftyp")) return "archives";

        byte[][] binarySignatures = new byte[][]
        {
            new byte[] { 0x4D, 0x5A }, new byte[] { 0x7F, 0x45, 0x4C, 0x46 }, new byte[] { 0xCF, 0xFA, 0xED, 0xFE },
            new byte[] { 0xFE, 0xED, 0xFA, 0xCF }, new byte[] { 0xCA, 0xFE, 0xBA, 0xBE },
            new byte[] { 0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00 }
        };

        for (int i = 0; i < binarySignatures.Length; i++)
            if (StartsWith(bytes, binarySignatures[i])) return "binary";

        return String.Empty;
    }
}
"@
        $script:UseNativeAnalyzer = $true
    }
    catch {
        $script:UseNativeAnalyzer = $false
    }
}
else {
    $script:UseNativeAnalyzer = $true
}

# Validate every prepared stage against its physical build plan before compression.
if(-not('SmartTarStageValidator' -as [type])){Add-Type @"
using System;
using System.Collections.Generic;
using System.IO;
public static class SmartTarStageValidator {
  static string Key(string root,string full){
    string p=root+Path.DirectorySeparatorChar;
    if(!full.StartsWith(p,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Path escaped stage root: "+full);
    return full.Substring(p.Length).Replace(Path.DirectorySeparatorChar,'/');
  }
  public static void Validate(string root,string[] paths,long[] sizes){
    if(String.IsNullOrWhiteSpace(root)||!Directory.Exists(root))throw new DirectoryNotFoundException("Stage root does not exist: "+root);
    if(paths==null||sizes==null||paths.Length!=sizes.Length)throw new InvalidDataException("Stage validation arrays are inconsistent.");
    root=Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
    var expected=new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);long planned=0;
    for(int i=0;i<paths.Length;i++){
      string rel=(paths[i]??"").Replace('/',Path.DirectorySeparatorChar).TrimStart(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
      if(rel.Length==0||Path.IsPathRooted(rel))throw new InvalidDataException("Invalid planned stage path: "+paths[i]);
      string full=Path.GetFullPath(Path.Combine(root,rel)),key=Key(root,full);
      if(expected.ContainsKey(key))throw new InvalidDataException("Duplicate planned stage path: "+key);
      var f=new FileInfo(full);if(!f.Exists)throw new FileNotFoundException("Missing stage file: "+key,full);
      if(f.Length!=sizes[i])throw new InvalidDataException("Stage size mismatch: "+key+". Planned="+sizes[i]+", actual="+f.Length+".");
      expected.Add(key,sizes[i]);checked{planned+=sizes[i];}
    }
    long count=0,bytes=0;
    foreach(string path in Directory.EnumerateFiles(root,"*",SearchOption.AllDirectories)){
      string full=Path.GetFullPath(path),key=Key(root,full);
      if(!expected.ContainsKey(key))throw new InvalidDataException("Unexpected stage file: "+key);
      count++;checked{bytes+=new FileInfo(full).Length;}
    }
    if(count!=paths.Length||bytes!=planned)throw new InvalidDataException("Stage totals differ from plan. Planned files="+paths.Length+", actual files="+count+", planned bytes="+planned+", actual bytes="+bytes+".");
  }
}
"@}

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


function Trim-PathSeparators {
    param([string]$Text)
    if (Test-Blank $Text) { return '' }
    return $Text.TrimEnd([char]92, [char]47)
}

function Convert-ToSafeArchiveFileNamePart {
    param([string]$Name)

    if (Test-Blank $Name) { return '' }

    $safe = [string]$Name
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$ch, '_')
    }

    $safe = $safe.Trim()
    $safe = $safe.TrimEnd([char[]]@([char]46, [char]32))

    if (Test-Blank $safe) { return '' }
    return $safe
}

function Normalize-ArchiveSourcePath {
    param([string]$Path)
    if (Test-Blank $Path) { return '' }
    $candidate = ([string]$Path).Trim()
    if ($candidate -match '^[A-Za-z]:[\/]?$') {
        $candidate = $candidate.Substring(0, 2) + [System.IO.Path]::DirectorySeparatorChar
    }
    $full = [System.IO.Path]::GetFullPath($candidate)
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not (Test-Blank $root) -and ((Trim-PathSeparators $full) -ieq (Trim-PathSeparators $root))) { return $root }
    return (Trim-PathSeparators $full)
}

function Test-IsDriveRootPath {
    param([string]$Path)
    try {
        $full = [System.IO.Path]::GetFullPath((Normalize-ArchiveSourcePath $Path))
        $root = [System.IO.Path]::GetPathRoot($full)
        return (-not (Test-Blank $root) -and ((Trim-PathSeparators $full) -ieq (Trim-PathSeparators $root)))
    } catch { return $false }
}

function Get-DriveArchiveRootName {
    param([string]$DriveRoot)
    $root = Normalize-ArchiveSourcePath $DriveRoot
    $label = ''
    try {
        $di = [System.IO.DriveInfo]::new($root)
        if ($di -and $di.IsReady) { $label = Convert-ToSafeArchiveFileNamePart ([string]$di.VolumeLabel) }
    } catch { $label = '' }
    if (-not (Test-Blank $label)) { return $label }
    $letter = Convert-ToSafeArchiveFileNamePart ((Trim-PathSeparators $root).Replace(':',''))
    if (Test-Blank $letter) { $letter = 'Root' }
    return ('Disk_' + $letter)
}

function Get-ArchiveSourceContext {
    param([string]$Source)
    $normalized = Normalize-ArchiveSourcePath $Source
    if (Test-IsDriveRootPath $normalized) {
        $name = Get-DriveArchiveRootName $normalized
        return [pscustomobject]@{ BaseRoot=$normalized; SourceLeaf=$name; ArchiveRootPrefix=$name; IsDriveRoot=$true }
    }
    $parent = Split-Path -Parent $normalized
    $leaf = Split-Path -Leaf $normalized
    if (Test-Blank $parent -or Test-Blank $leaf) { throw "Cannot determine source context: $normalized" }
    return [pscustomobject]@{ BaseRoot=$parent; SourceLeaf=$leaf; ArchiveRootPrefix=''; IsDriveRoot=$false }
}

function Get-RelativePathFromBase {
    param([string]$BasePath, [string]$FullPath)
    if (Test-Blank $BasePath -or Test-Blank $FullPath) { throw 'Cannot create a relative path from an empty path.' }
    $baseFull = Trim-PathSeparators ([System.IO.Path]::GetFullPath($BasePath))
    $pathFull = [System.IO.Path]::GetFullPath($FullPath)
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    $archivePrefix = [string]$script:sourceArchiveRootPrefix
    if ((Trim-PathSeparators $pathFull) -ieq (Trim-PathSeparators $baseFull)) {
        if (-not (Test-Blank $archivePrefix)) { return $archivePrefix }
        return '.'
    }
    if ($pathFull.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $pathFull.Substring($prefix.Length)
        if (-not (Test-Blank $archivePrefix)) { return (Join-Path $archivePrefix $relative) }
        return $relative
    }
    throw "Source item is outside the selected base path. Base='$baseFull', Path='$pathFull'."
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

function Test-DirectoryWritable {
    param([string]$Path)
    try {
        if (Test-Blank $Path) { return $false }
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
        $testFile = Join-Path $Path ('smarttar_write_test_' + [guid]::NewGuid().ToString('N') + '.tmp')
        'test' | Set-Content -LiteralPath $testFile -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Get-SmartTarStandardTempCandidates {
    $list = New-Object System.Collections.Generic.List[string]

    # User-scoped temp locations only. SmartTAR intentionally does not use
    # system-wide common application data for new work roots.
    try {
        $systemTemp = [System.IO.Path]::GetTempPath()
        if (-not (Test-Blank $systemTemp)) { [void]$list.Add((Join-Path $systemTemp 'SmartTAR')) }
    }
    catch {
    }

    if (-not (Test-Blank $env:TEMP)) { [void]$list.Add((Join-Path $env:TEMP 'SmartTAR')) }
    if (-not (Test-Blank $env:TMP))  { [void]$list.Add((Join-Path $env:TMP  'SmartTAR')) }

    return @($list | Select-Object -Unique)
}

function Get-SmartTarWritableStandardTempRoot {
    param([string]$SubFolder = '')
    foreach ($candidate in Get-SmartTarStandardTempCandidates) {
        try {
            if (Test-Blank $candidate) { continue }
            $root = if (Test-Blank $SubFolder) { $candidate } else { Join-Path $candidate $SubFolder }
            if (Test-DirectoryWritable $root) { return $root }
        } catch { continue }
    }
    throw 'Unable to find a writable SmartTAR temp folder.'
}

function New-WorkRootAtBase {
    param([string]$Purpose, [string]$BasePath)
    if (Test-Blank $BasePath) { throw 'Work root base path is empty.' }
    if (-not (Test-DirectoryWritable $BasePath)) { throw "Work root base is not writable: $BasePath" }
    $safePurpose = if (Test-Blank $Purpose) { 'w' } else { ([string]$Purpose).Substring(0,1).ToLowerInvariant() }
    $work = Join-Path $BasePath ('{0}_{1}' -f $safePurpose, [guid]::NewGuid().ToString('N').Substring(0,12))
    [System.IO.Directory]::CreateDirectory($work) | Out-Null
    return $work
}

function New-CompressionWorkRoot {
    param([string]$Source, [string]$Destination)

    # Destination-local workflow:
    # Create the build workroot next to the target archive. The base work folder
    # is hidden so normal users do not see SmartTAR internals next to archives.
    try {
        $destDir = [System.IO.Path]::GetDirectoryName($Destination)
        if (Test-Blank $destDir) { $destDir = (Get-Location).Path }
        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
        if (-not (Test-DirectoryWritable $destDir)) { throw "Destination folder is not writable: $destDir" }

        $workBase = Join-Path $destDir '.stw'
        [System.IO.Directory]::CreateDirectory($workBase) | Out-Null

        try {
            $workBaseItem = Get-Item -LiteralPath $workBase -Force -ErrorAction Stop
            $workBaseItem.Attributes = $workBaseItem.Attributes -bor [System.IO.FileAttributes]::Hidden
        }
        catch {
        }

        if (-not (Test-DirectoryWritable $workBase)) { throw "Destination work folder is not writable: $workBase" }

        return [pscustomobject]@{
            WorkRoot = (New-WorkRootAtBase 'create' $workBase)
            AllowGroupCopyFallback = $true
            Mode = 'destination-local-workroot-copy-fallback-full-sequential-compact-manifest-hidden-work'
        }
    }
    catch {
        throw "Unable to create destination-local SmartTAR workroot near destination '$Destination'. $($_.Exception.Message)"
    }
}

function Get-SafeReportPath {
    param([string]$BasePath, [string]$Kind)
    try {
        $preferred = Get-ReportPath $BasePath $Kind
        $preferredDir = Split-Path -Parent $preferred
        if (Test-DirectoryWritable $preferredDir) { return $preferred }
    } catch {}
    $reportRoot = Get-SmartTarWritableStandardTempRoot 'Reports'
    $name = [System.IO.Path]::GetFileName($BasePath)
    if (Test-Blank $name) { $name = 'SmartTAR' }
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$ch, '_') }
    return (Join-Path $reportRoot ("$name.$Kind.$(Get-Date -Format yyyyMMdd_HHmmss).txt"))
}

function Write-ReportFile {
    param([string]$Path, [string]$Text)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Blank $dir) -and -not (Test-Path -LiteralPath $dir)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $Text | Set-Content -LiteralPath $Path -Encoding UTF8
}

# Report slots: 0 action, 1 title, 2 source size, 3 archive size, 4 ratio, 5 saved,
# 10 format, 11 version, 12 profile, 13 mode, 14 blocks, 15 blocks OK,
# 16 blocks failed, 17 verification, 20 archive path, 21 destination,
# 22 salvage, 25 groups, 26 method summary, 27 analysis, 28 details/warnings.

function Format-OperationReport {
    param($R)

    $lines = @()
    if ($R[1]) { $lines += [string]$R[1] }

    foreach ($section in @(
        @{ Header = '';         Map = @('2|Source size','3|Archive size','4|Ratio','5|Saved') },
        @{ Header = '';         Map = @('20|Archive path','21|Extraction parent folder','22|Salvage mode') },
        @{ Header = 'Archive:'; Map = @('10|Format','11|Version','12|Profile','13|Mode','14|Blocks','15|Blocks OK','16|Blocks failed','17|Verification') }
    )) {
        $rows = @()
        foreach ($m in $section.Map) {
            $p = $m.Split('|', 2)
            $v = $R[[int]$p[0]]
            if ($v) { $rows += ('{0}: {1}' -f $p[1], $v) }
        }
        if ($rows.Count -gt 0) {
            $lines += ''
            if ($section.Header) { $lines += [string]$section.Header }
            $lines += $rows
        }
    }

    foreach ($i in 25..28) {
        if ($R[$i]) { $lines += [string]$R[$i] }
    }

    return (($lines -join [Environment]::NewLine).Trim())
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
    $workRoot = Get-SmartTarWritableStandardTempRoot 'Work'
    $work = Join-Path $workRoot ('smarttar_{0}_{1}' -f $safePurpose, $guid)
    [System.IO.Directory]::CreateDirectory($work) | Out-Null
    return $work
}

# ============================================================================
# 04. UI state and status bridge
# ============================================================================
# Royal Black Noir single-theme palette
$cBg           = [System.Drawing.ColorTranslator]::FromHtml('#191B20')
$cSurface      = [System.Drawing.ColorTranslator]::FromHtml('#242832')
$cSurfaceAlt   = [System.Drawing.ColorTranslator]::FromHtml('#2D3340')
$cInput        = [System.Drawing.ColorTranslator]::FromHtml('#15171C')
$cText         = [System.Drawing.ColorTranslator]::FromHtml('#E3E6EB')
$cTextMuted    = [System.Drawing.ColorTranslator]::FromHtml('#A9B1BF')
$cGray         = [System.Drawing.ColorTranslator]::FromHtml('#505968')
$cRoyal        = [System.Drawing.ColorTranslator]::FromHtml('#4B6698')
$cRoyalHover   = [System.Drawing.ColorTranslator]::FromHtml('#607DB0')
$cRoyalActive  = [System.Drawing.ColorTranslator]::FromHtml('#38527E')
$cSuccess      = [System.Drawing.ColorTranslator]::FromHtml('#477B5E')
$cSuccessHover = [System.Drawing.ColorTranslator]::FromHtml('#56896B')
$cSuccessDown  = [System.Drawing.ColorTranslator]::FromHtml('#37664B')
$cVerify       = [System.Drawing.ColorTranslator]::FromHtml('#46505C')
$cVerifyHover  = [System.Drawing.ColorTranslator]::FromHtml('#596574')
$cWarning      = [System.Drawing.ColorTranslator]::FromHtml('#D0A354')
$cDanger       = [System.Drawing.ColorTranslator]::FromHtml('#C65E62')
$cStatusOk     = [System.Drawing.ColorTranslator]::FromHtml('#72B88A')
$cButtonText   = [System.Drawing.ColorTranslator]::FromHtml('#F2F4F7')

$fNormal = [System.Drawing.Font]::new('Segoe UI', 9)
$fBold = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fItalic = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)

function Get-SafeWorkerCount {
    $cpuThreads = [Environment]::ProcessorCount

    if ($cpuThreads -le 2) { return 1 }
    if ($cpuThreads -le 4) { return 2 }
    return 4
}

function Reset-SmartTarRuntimeState {
    $script:ToolVersion = '1.4.0-streamed-add-uppercase'
    $script:FormatName = 'STAR'
    $script:FormatVersion = 1
    $script:ArchiveExtension = '.star'
    $script:AdaptiveSampleBytes = 1MB
    $script:MaxParallelAnalysis = Get-SafeWorkerCount
    $script:analysisScope = 'None'
    $script:compressionPreference = 'Balanced'
    $script:adaptiveDeepAnalyze = $false
    $script:adaptiveStats = $null
    $script:EnableFileDedup = $true
    $script:DedupMinFileBytes = 1
    $script:sourceArchiveRootPrefix = ''
    $script:dedupStats = $null
}

function Set-BusyStatus {
    param([string]$Text)
    Set-AppStatus $Text $cWarning
}

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
$script:pendingTargetPath = ''
$script:pendingTargetAction = ''
$script:openFolderAfter = $true
$script:currentStdOut = ''
$script:currentStdErr = ''
Reset-SmartTarRuntimeState
$script:IncludeDebugDiagnosticsInManifest = $false
$script:ExportDebugBundle = $false
$script:KeepDebugArtifacts = $false

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
    if (Test-Blank $Path) { return }
    $dir=Split-Path -Parent $Path;if(-not(Test-Blank $dir)){[System.IO.Directory]::CreateDirectory($dir)|Out-Null}
    $tmp=$Path+'.writing.'+[guid]::NewGuid().ToString('N')
    try{$Text|Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop;for($n=0;$n-lt 5;$n++){try{Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop;return}catch{Start-Sleep -Milliseconds 40}}}catch{}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}

function Set-AppStatus {
    param([string]$Text, [System.Drawing.Color]$Color = $cTextMuted)

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
        @{ Name='xz9';    Display='XZ9';    Extension='.tar.xz';  CreateArgs=@('--options','xz:compression-level=9','-cJf'); Level=9; Algorithm='xz' },
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

function Select-BestCompressedMethod { param([hashtable]$Capabilities) foreach ($name in @('xz9','zstd19','store')) { if ($Capabilities.ContainsKey($name) -and $Capabilities[$name]) { return Get-TarMethodByName $name } } throw 'No usable tar method found.' }

function Select-XzOrBest { param([hashtable]$Capabilities) if ($Capabilities.ContainsKey('xz9') -and $Capabilities['xz9']) { return Get-TarMethodByName 'xz9' }; return Select-BestCompressedMethod $Capabilities }

function Select-ZstdOrBest { param([hashtable]$Capabilities) if ($Capabilities.ContainsKey('zstd19') -and $Capabilities['zstd19']) { return Get-TarMethodByName 'zstd19' }; return Select-BestCompressedMethod $Capabilities }

function Select-StoreMethod { param([hashtable]$Capabilities) if ($Capabilities.ContainsKey('store') -and $Capabilities['store']) { return Get-TarMethodByName 'store' }; return Select-BestCompressedMethod $Capabilities }

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
    $archiveExt = @('.zip','.7z','.rar','.gz','.bz2','.xz','.zst','.tar','.tgz','.tbz2','.txz','.cab','.jar','.war','.ear','.star','.docx','.xlsx','.pptx','.odt','.ods','.odp','.apk','.epub','.vsix','.nupkg')

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
    if ($Mode -eq 'Balanced' -or $Mode -eq 'Store') {
        if ($SmartGroup -eq 'diskimage') { return 'diskimage' }
        if ($SmartGroup -eq 'media' -or $SmartGroup -eq 'archives') { return 'stored' }
        return 'compressible'
    }
    return $SmartGroup
}

function Get-AnalysisScopeForMode {
    param([string]$Mode)

    if ($Mode -eq 'Smart' -or $Mode -eq 'Solid') { 'FullAnalyze' } else { 'UnknownOnly' }
}

function Get-CompressionPreferenceForMode {
    param([string]$Mode)
    switch ([string]$Mode) {
        'Smart' { return 'MaxCompression' }
        default { return 'Balanced' }
    }
}

function Get-CompressionProfileDisplayName {
    param([string]$Mode, [string]$Preference)
    switch ([string]$Mode) {
        'Balanced' { return 'Balanced - mixed blocks' }
        'Smart' { return 'Smart - max compression' }
        'Solid' { return 'Solid - single block' }
        'Store' { return 'Store - no compression' }
        default { return [string]$Mode }
    }
}

function Test-ContentAnalysisEnabled { param([string]$Scope) return (([string]$Scope) -ne 'None') }

function Test-ShouldAnalyzeFileContent {
    param([string]$Scope, [string]$SmartGroup)
    switch ([string]$Scope) {
        'FullAnalyze' { return $true }
        'UnknownOnly' { return (([string]$SmartGroup) -eq 'unknown') }
        default { return $false }
    }
}

function Invoke-NativeAdaptiveAnalysis {
    param($File)

    try {
        if ($script:UseNativeAnalyzer -and ('SmartTarNativeAnalyzer' -as [type])) {
            return [SmartTarNativeAnalyzer]::AnalyzeFile(
                [string]$File.FullName,
                [int64]$File.Length,
                [int]$script:AdaptiveSampleBytes
            )
        }
    }
    catch {
        $script:UseNativeAnalyzer = $false
    }

    return [pscustomobject]@{
        FullName = [string]$File.FullName
        Decision = 'unknown'
        Error = $true
        SampleBytes = [int64]0
        ZeroBytes = [int64]0
        EntropyAvailable = $false
        Entropy = [double]0.0
        UniqueAvailable = $false
        UniqueBytes = [int]0
    }
}

function New-AdaptiveStats {
    $scope=[string]$script:analysisScope; if(Test-Blank $scope){$scope='None'}
    $enabled=Test-ContentAnalysisEnabled $scope
    return [ordered]@{
        enabled=[bool]$enabled; analysisScope=$scope
        scope=if($scope -eq 'FullAnalyze'){'all-files'}elseif($scope -eq 'UnknownOnly'){'unknown-files-only'}else{'none'}
        method='native-csharp-magic-bytes-plus-conservative-byte-entropy-start-end-sample'; sampleBytes=[int]$script:AdaptiveSampleBytes
        unknownSeen=0; unknownBytes=[int64]0
        movedToText=0; movedToTextBytes=[int64]0; movedToBinary=0; movedToBinaryBytes=[int64]0; movedToArchives=0; movedToArchivesBytes=[int64]0
        stayedUnknown=0; stayedUnknownBytes=[int64]0; errors=0
        zeroSampleBytes=[int64]0; zeroBytes=[int64]0
        entropyCount=0; entropySum=[double]0.0; entropyMin=[double]9.0; entropyMax=[double]0.0
        uniqueCount=0; uniqueSum=[int64]0; uniqueMin=257; uniqueMax=0
    }
}

function Add-AdaptiveDecisionStat {
    param([string]$Decision,[int64]$Bytes,[bool]$Error=$false,[int64]$SampleBytes=0,[int64]$ZeroBytes=0,[bool]$EntropyAvailable=$false,[double]$Entropy=0.0,[bool]$UniqueAvailable=$false,[int]$UniqueBytes=0)
    if($null -eq $script:adaptiveStats){$script:adaptiveStats=New-AdaptiveStats}
    $script:adaptiveStats.unknownSeen=[int]$script:adaptiveStats.unknownSeen+1
    $script:adaptiveStats.unknownBytes=[int64]$script:adaptiveStats.unknownBytes+$Bytes
    if($SampleBytes -gt 0){$script:adaptiveStats.zeroSampleBytes=[int64]$script:adaptiveStats.zeroSampleBytes+$SampleBytes; $script:adaptiveStats.zeroBytes=[int64]$script:adaptiveStats.zeroBytes+$ZeroBytes}
    if($EntropyAvailable){
        $script:adaptiveStats.entropyCount=[int]$script:adaptiveStats.entropyCount+1
        $script:adaptiveStats.entropySum=[double]$script:adaptiveStats.entropySum+[double]$Entropy
        if([double]$Entropy -lt [double]$script:adaptiveStats.entropyMin){$script:adaptiveStats.entropyMin=[double]$Entropy}
        if([double]$Entropy -gt [double]$script:adaptiveStats.entropyMax){$script:adaptiveStats.entropyMax=[double]$Entropy}
    }
    if($UniqueAvailable){
        $script:adaptiveStats.uniqueCount=[int]$script:adaptiveStats.uniqueCount+1
        $script:adaptiveStats.uniqueSum=[int64]$script:adaptiveStats.uniqueSum+[int64]$UniqueBytes
        if([int]$UniqueBytes -lt [int]$script:adaptiveStats.uniqueMin){$script:adaptiveStats.uniqueMin=[int]$UniqueBytes}
        if([int]$UniqueBytes -gt [int]$script:adaptiveStats.uniqueMax){$script:adaptiveStats.uniqueMax=[int]$UniqueBytes}
    }
    if($Error){$script:adaptiveStats.errors=[int]$script:adaptiveStats.errors+1}
    switch([string]$Decision){
        'text' {$script:adaptiveStats.movedToText=[int]$script:adaptiveStats.movedToText+1; $script:adaptiveStats.movedToTextBytes=[int64]$script:adaptiveStats.movedToTextBytes+$Bytes}
        'binary' {$script:adaptiveStats.movedToBinary=[int]$script:adaptiveStats.movedToBinary+1; $script:adaptiveStats.movedToBinaryBytes=[int64]$script:adaptiveStats.movedToBinaryBytes+$Bytes}
        'archives' {$script:adaptiveStats.movedToArchives=[int]$script:adaptiveStats.movedToArchives+1; $script:adaptiveStats.movedToArchivesBytes=[int64]$script:adaptiveStats.movedToArchivesBytes+$Bytes}
        default {$script:adaptiveStats.stayedUnknown=[int]$script:adaptiveStats.stayedUnknown+1; $script:adaptiveStats.stayedUnknownBytes=[int64]$script:adaptiveStats.stayedUnknownBytes+$Bytes}
    }
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
    param([hashtable]$Capabilities, [hashtable]$Profile, $AdaptiveStats = $null)

    $xz = Select-XzOrBest $Capabilities
    $zstd = Select-ZstdOrBest $Capabilities

    $zstdAvailable = ($Capabilities.ContainsKey('zstd19') -and $Capabilities['zstd19'])
    if (-not $zstdAvailable) { return $xz }

    $textBytes = [int64]0
    $binaryBytes = [int64]0
    $diskImageBytes = [int64]0
    $archiveLikeBytes = [int64]0
    $unknownBytes = [int64]0
    $totalBytes = [int64]0

    if ($null -ne $Profile) {
        foreach ($key in @('text','binary','executable','diskimage','media','archives','unknown')) {
            if ($Profile.ContainsKey($key)) { $totalBytes += [int64]$Profile[$key] }
        }
        if ($Profile.ContainsKey('text')) { $textBytes = [int64]$Profile.text }
        if ($Profile.ContainsKey('binary')) { $binaryBytes += [int64]$Profile.binary }
        if ($Profile.ContainsKey('executable')) { $binaryBytes += [int64]$Profile.executable }
        if ($Profile.ContainsKey('diskimage')) { $diskImageBytes = [int64]$Profile.diskimage; $binaryBytes += [int64]$Profile.diskimage }
        if ($Profile.ContainsKey('media')) { $archiveLikeBytes += [int64]$Profile.media }
        if ($Profile.ContainsKey('archives')) { $archiveLikeBytes += [int64]$Profile.archives }
        if ($Profile.ContainsKey('unknown')) { $unknownBytes = [int64]$Profile.unknown }
    }

    $entropyAverage = [double]0.0
    $uniqueAverage = [double]0.0
    $hasEntropySignal = $false

    if ($null -ne $AdaptiveStats -and [bool]$AdaptiveStats.enabled -and [int64]$AdaptiveStats.unknownBytes -gt 0) {
        $adaptiveTotal = [int64]$AdaptiveStats.unknownBytes
        $adaptiveText = [int64]$AdaptiveStats.movedToTextBytes
        $adaptiveBinary = [int64]$AdaptiveStats.movedToBinaryBytes
        $adaptiveArchive = [int64]$AdaptiveStats.movedToArchivesBytes
        $adaptiveUnknown = [int64]$AdaptiveStats.stayedUnknownBytes

        if ($adaptiveTotal -gt 0) {
            $totalBytes = $adaptiveTotal
            $textBytes = $adaptiveText
            $binaryBytes = $adaptiveBinary
            $archiveLikeBytes = $adaptiveArchive
            $unknownBytes = $adaptiveUnknown

            if ($null -ne $Profile -and $Profile.ContainsKey('diskimage')) {
                $diskImageBytes = [int64]$Profile.diskimage
                if ($diskImageBytes -gt $binaryBytes) { $binaryBytes = $diskImageBytes }
            }
        }

        if ([int]$AdaptiveStats.entropyCount -gt 0) {
            $entropyAverage = [double]$AdaptiveStats.entropySum / [double]$AdaptiveStats.entropyCount
            $hasEntropySignal = $true
        }
        if ([int]$AdaptiveStats.uniqueCount -gt 0) {
            $uniqueAverage = [double]$AdaptiveStats.uniqueSum / [double]$AdaptiveStats.uniqueCount
        }
    }

    if ($totalBytes -le 0) { return $xz }

    $compressibleBytes = $textBytes + $unknownBytes
    $archiveRatio = [double]$archiveLikeBytes / [double]$totalBytes
    $diskRatio = [double]$diskImageBytes / [double]$totalBytes
    $binaryRatio = [double]$binaryBytes / [double]$totalBytes
    $compressibleRatio = [double]$compressibleBytes / [double]$totalBytes

    if ($archiveRatio -ge 0.60) { return $zstd }
    if ($diskRatio -ge 0.50 -and $compressibleRatio -lt 0.25 -and $totalBytes -ge 256MB) { return $zstd }
    if ($binaryRatio -ge 0.90 -and $compressibleRatio -lt 0.10 -and $totalBytes -ge 512MB) { return $zstd }
    if ($hasEntropySignal -and $entropyAverage -ge 7.65 -and $uniqueAverage -ge 220 -and $binaryRatio -ge 0.60 -and $compressibleRatio -lt 0.20 -and $totalBytes -ge 128MB) { return $zstd }

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
    $preference = Get-CompressionPreferenceForMode $Mode
    $groups = [ordered]@{}
    switch ($Mode) {
        'Solid' { $groups.solid = New-GroupInfo solid (Select-AutoSolidMethod $Capabilities $Profile) 'Auto solid method.' }
        'Smart' {
            $binaryMethod = if ($preference -eq 'MaxCompression') { $xz } else { $zstd }
            $binaryReason = if ($preference -eq 'MaxCompression') { 'Binary data uses XZ9 by Smart max compression preference.' } else { 'Binary data prefers ZSTD19.' }
            $groups.text       = New-GroupInfo text       $xz           'Text-like data prefers XZ9.'
            $groups.binary     = New-GroupInfo binary     $binaryMethod $binaryReason
            $groups.executable = New-GroupInfo executable $binaryMethod $binaryReason
            $groups.diskimage  = New-GroupInfo diskimage  $binaryMethod $binaryReason
            $groups.media      = New-GroupInfo media      $store        'Media is stored.'
            $groups.archives   = New-GroupInfo archives   $store        'Archives are stored.'
            $groups.unknown    = New-GroupInfo unknown    $xz           'Unknown data prefers XZ9.'
        }
        default {
            $compressibleMethod = if ($Mode -eq 'Store') { $store } else { $xz }
            $diskimageMethod    = if ($Mode -eq 'Store') { $store } else { $zstd }
            $generalReason      = if ($Mode -eq 'Store') { 'General data stored without compression.' } else { 'General compressible data prefers XZ9.' }
            $diskReason         = if ($Mode -eq 'Store') { 'Disk images stored without compression.' } else { 'Disk images prefer ZSTD19.' }
            $storedReason       = if ($Mode -eq 'Store') { 'Media and archive-like data stored without compression.' } else { 'Media and archive-like data is stored.' }
            $groups.compressible = New-GroupInfo compressible $compressibleMethod $generalReason
            $groups.diskimage    = New-GroupInfo diskimage    $diskimageMethod    $diskReason
            $groups.stored       = New-GroupInfo stored       $store              $storedReason
        }
    }
    return $groups
}

# ============================================================================
# 07. Staging and block creation
# ============================================================================

function Get-SafeStageRelativePath {
    param([string]$RelativePath, [string]$FallbackName)
    $candidate=[string]$RelativePath
    if(Test-Blank $candidate){$candidate=[string]$FallbackName}
    $candidate=(Convert-ToLocalPath $candidate).TrimStart([char]92,[char]47)
    if((Test-Blank $candidate) -or [System.IO.Path]::IsPathRooted($candidate) -or ($candidate -match '^[A-Za-z]:') -or ($candidate -match '(^|[\\/])\.\.([\\/]|$)') -or ($candidate -match ':')){
        $candidate = Convert-ToSafeArchiveFileNamePart ([string]$FallbackName)
    }
    if(Test-Blank $candidate){$candidate='root'}
    return $candidate
}

function Add-FileToGroup {
    param([hashtable]$Group, [string]$SourcePath, [string]$RelativePath, [int64]$Bytes, [string]$LinkTarget = '')

    $fileInfo = [pscustomobject]@{
        Path       = $SourcePath
        Rel        = (Convert-ToTarPath $RelativePath)
        Bytes      = [int64]$Bytes
        LinkTarget = [string]$LinkTarget
    }

    [void]$Group.Files.Add($fileInfo)
    $Group.FileCount = [int]$Group.FileCount + 1
    $Group.Bytes = [int64]$Group.Bytes + [int64]$Bytes
}

function New-FileDedupStats {
    return [ordered]@{
        enabled = [bool]$script:EnableFileDedup
        mode = 'unique-only-manifest-alias-dedup'
        minFileBytes = [int64]$script:DedupMinFileBytes
        candidates = 0
        candidateBytes = [int64]0
        hashedFiles = 0
        duplicateFiles = 0
        duplicateBytes = [int64]0
        uniqueFingerprints = 0
        skippedSmallFiles = 0
        skippedSmallBytes = [int64]0
        errors = 0
    }
}

function Register-FileDedupCandidate {
    param($File, [string]$RelativePath, [hashtable]$State)

    if ($null -eq $script:dedupStats) { $script:dedupStats = New-FileDedupStats }
    if (-not [bool]$script:EnableFileDedup) { return '' }
    if ($null -eq $File) { return '' }

    $bytes = [int64]$File.Length
    if ($bytes -le 0 -or $bytes -lt [int64]$script:DedupMinFileBytes) {
        $script:dedupStats.skippedSmallFiles = [int]$script:dedupStats.skippedSmallFiles + 1
        $script:dedupStats.skippedSmallBytes = [int64]$script:dedupStats.skippedSmallBytes + $bytes
        return ''
    }

    $script:dedupStats.candidates = [int]$script:dedupStats.candidates + 1
    $script:dedupStats.candidateBytes = [int64]$script:dedupStats.candidateBytes + $bytes

    $lengthKey = [string]$bytes
    if (-not $State.ContainsKey($lengthKey)) {
        $list = New-Object System.Collections.ArrayList
        [void]$list.Add([pscustomobject]@{ Path=[string]$File.FullName; Rel=(Convert-ToTarPath $RelativePath); Bytes=[int64]$bytes; Hash='' })
        $State[$lengthKey] = $list
        $script:dedupStats.uniqueFingerprints = [int]$script:dedupStats.uniqueFingerprints + 1
        return ''
    }

    try {
        $entries = $State[$lengthKey]
        $currentHash = Get-FileSHA256 ([string]$File.FullName)
        $script:dedupStats.hashedFiles = [int]$script:dedupStats.hashedFiles + 1

        foreach ($entry in @($entries)) {
            if (Test-Blank ([string]$entry.Hash)) {
                $entry.Hash = Get-FileSHA256 ([string]$entry.Path)
                $script:dedupStats.hashedFiles = [int]$script:dedupStats.hashedFiles + 1
            }

            if ([string]$entry.Hash -eq $currentHash) {
                $script:dedupStats.duplicateFiles = [int]$script:dedupStats.duplicateFiles + 1
                $script:dedupStats.duplicateBytes = [int64]$script:dedupStats.duplicateBytes + $bytes
                return [pscustomobject]@{
                    Path=[string]$entry.Path
                    Rel=(Convert-ToTarPath ([string]$entry.Rel))
                    Bytes=[int64]$entry.Bytes
                    Hash=[string]$entry.Hash
                }
            }
        }

        [void]$entries.Add([pscustomobject]@{ Path=[string]$File.FullName; Rel=(Convert-ToTarPath $RelativePath); Bytes=[int64]$bytes; Hash=$currentHash })
        $script:dedupStats.uniqueFingerprints = [int]$script:dedupStats.uniqueFingerprints + 1
        return ''
    }
    catch {
        $script:dedupStats.errors = [int]$script:dedupStats.errors + 1
        return ''
    }
}

function Initialize-SmartTarPlanningArtifacts {
    param([string]$WorkRoot)

    $script:planCatalogPath = ''
    $script:planDedupMapPath = ''
    $script:planBuildPlanPath = ''
    $script:planItemId = [int64]0
    $script:planPathToRel = @{}
    $script:planRelToPath = @{}
    $script:planFamilyKeys = @{}
    $script:planDedupAliases = @()
    $script:planDiagnostics = [ordered]@{
        enabled = $true
        mode = 'unique-only-alias-dedup'
        buildWorkMode = [string]$script:buildWorkMode
        catalogPath = ''
        dedupMapPath = ''
        buildPlanPath = ''
        catalogFiles = 0
        catalogBytes = [int64]0
        uniqueFiles = 0
        uniqueBytes = [int64]0
        aliasFiles = 0
        aliasBytes = [int64]0
        dedupFamilies = 0
        buildFiles = 0
        buildBytes = [int64]0
        aliasBuildSkippedFiles = 0
        aliasBuildSkippedBytes = [int64]0
        manifestAliasCount = 0
        manifestAliasBytes = [int64]0
        uniqueOnlyBuildEnabled = $true
        writeErrors = 0
    }

    if (Test-Blank $WorkRoot) { return }

    try {
        [System.IO.Directory]::CreateDirectory($WorkRoot) | Out-Null
        $script:planCatalogPath = Join-Path $WorkRoot 'smarttar_catalog.jsonl'
        $script:planDedupMapPath = Join-Path $WorkRoot 'smarttar_dedup_map.jsonl'
        $script:planBuildPlanPath = Join-Path $WorkRoot 'smarttar_build_plan.jsonl'

        foreach ($p in @($script:planCatalogPath, $script:planDedupMapPath, $script:planBuildPlanPath)) {
            if (-not (Test-Blank $p) -and (Test-Path -LiteralPath $p)) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }

        $script:planDiagnostics.catalogPath = [string]$script:planCatalogPath
        $script:planDiagnostics.dedupMapPath = [string]$script:planDedupMapPath
        $script:planDiagnostics.buildPlanPath = [string]$script:planBuildPlanPath
        $script:planDiagnostics.buildWorkMode = [string]$script:buildWorkMode
    }
    catch {
        $script:planDiagnostics.enabled = $false
        $script:planDiagnostics.writeErrors = [int]$script:planDiagnostics.writeErrors + 1
    }
}

function Write-SmartTarJsonLine {
    param([string]$Path, $Object)

    if (Test-Blank $Path -or $null -eq $Object) { return }
    try {
        $json = ($Object | ConvertTo-Json -Compress -Depth 12)
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
    }
    catch {
        if ($null -ne $script:planDiagnostics -and $script:planDiagnostics.Contains('writeErrors')) {
            $script:planDiagnostics.writeErrors = [int]$script:planDiagnostics.writeErrors + 1
        }
    }
}

function Add-SmartTarPlanCatalogItem {
    param([int64]$Id, $File, [string]$RelativePath, [string]$GroupName, [string]$SmartGroup)
    if ($null -eq $File -or $null -eq $script:planDiagnostics) { return }
    $rel=(Convert-ToTarPath $RelativePath).Trim('/').Trim();$path=[string]$File.FullName;$bytes=[int64]$File.Length
    if(Test-Blank $rel -or -not(Test-RelativePathSafe $rel)){throw "Unsafe planned archive path: $rel"}
    $relKey=$rel.ToLowerInvariant()
    if($script:planRelToPath.ContainsKey($relKey)){
        $existing=[string]$script:planRelToPath[$relKey]
        if(-not $existing.Equals($path,[System.StringComparison]::OrdinalIgnoreCase)){throw "Archive path collision: '$rel' maps both '$existing' and '$path'."}
    }else{$script:planRelToPath[$relKey]=$path}
    $script:planPathToRel[$path.ToLowerInvariant()]=$rel
    $script:planDiagnostics.catalogFiles=[int]$script:planDiagnostics.catalogFiles+1;$script:planDiagnostics.catalogBytes=[int64]$script:planDiagnostics.catalogBytes+$bytes
    Write-SmartTarJsonLine $script:planCatalogPath ([ordered]@{id=$Id;rel=$rel;path=$path;bytes=$bytes;group=[string]$GroupName;smartGroup=[string]$SmartGroup;lastWriteUtc=$File.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')})
}

function Add-SmartTarPlanItems {
    param([int64]$Id,$File,[string]$RelativePath,[string]$GroupName,$LinkTarget)
    if($null-eq$File-or$null-eq$script:planDiagnostics){return}
    $rel=(Convert-ToTarPath $RelativePath).Trim('/').Trim();$path=[string]$File.FullName;$bytes=[int64]$File.Length;$role='unique';$targetPath='';$targetRel='';$family=''
    $hasTarget=($null-ne$LinkTarget-and-not(Test-Blank([string]$LinkTarget.Path)))
    if($hasTarget){
        $role='alias';$targetPath=[string]$LinkTarget.Path;$targetRel=(Convert-ToTarPath([string]$LinkTarget.Rel)).Trim('/').Trim();$targetBytes=[int64]$LinkTarget.Bytes
        if(Test-Blank $targetRel-or-not(Test-RelativePathSafe $targetRel)){throw "Unsafe dedup target path: $targetRel"}
        if($targetBytes-ne$bytes){throw "Dedup target size changed: $rel -> $targetRel. Alias=$bytes, target=$targetBytes."}
        $key=$targetPath.ToLowerInvariant();if(-not$script:planPathToRel.ContainsKey($key)){throw "Dedup target is absent from unique plan: $targetPath"}
        $planned=(Convert-ToTarPath([string]$script:planPathToRel[$key])).Trim('/').Trim();if(-not$planned.Equals($targetRel,[System.StringComparison]::OrdinalIgnoreCase)){throw "Dedup identity mismatch: '$planned' vs '$targetRel'."}
        $family='target:'+$targetRel.ToLowerInvariant();$script:planDiagnostics.aliasFiles++;$script:planDiagnostics.aliasBytes=[int64]$script:planDiagnostics.aliasBytes+$bytes;$script:planDiagnostics.aliasBuildSkippedFiles++;$script:planDiagnostics.aliasBuildSkippedBytes=[int64]$script:planDiagnostics.aliasBuildSkippedBytes+$bytes;$script:planDiagnostics.manifestAliasCount++;$script:planDiagnostics.manifestAliasBytes=[int64]$script:planDiagnostics.manifestAliasBytes+$bytes
        if(-not$script:planFamilyKeys.ContainsKey($family)){$script:planFamilyKeys[$family]=$true;$script:planDiagnostics.dedupFamilies++}
        $script:planDedupAliases += [ordered]@{path=$rel;target=$targetRel;bytes=$bytes}
    }else{$script:planDiagnostics.uniqueFiles++;$script:planDiagnostics.uniqueBytes=[int64]$script:planDiagnostics.uniqueBytes+$bytes;$script:planDiagnostics.buildFiles++;$script:planDiagnostics.buildBytes=[int64]$script:planDiagnostics.buildBytes+$bytes}
    Write-SmartTarJsonLine $script:planDedupMapPath ([ordered]@{id=$Id;rel=$rel;path=$path;bytes=$bytes;group=[string]$GroupName;role=$role;family=$family;targetRel=$targetRel;targetPath=$targetPath})
    if($role-eq'alias'){Write-SmartTarJsonLine $script:planBuildPlanPath ([ordered]@{id=$Id;role='alias';rel=$rel;targetRel=$targetRel;bytes=$bytes})}else{Write-SmartTarJsonLine $script:planBuildPlanPath ([ordered]@{id=$Id;role='file';blockGroup=[string]$GroupName;rel=$rel;path=$path;bytes=$bytes})}
}

function Invoke-ParallelAdaptiveAnalysis {
    param($Targets, [int]$MaxParallel = 4, [int]$SampleBytes = 1048576)
    $items = @($Targets)
    if ($items.Count -lt 1) { return @{} }
    if ($MaxParallel -lt 1) { $MaxParallel = 1 }
    if ($MaxParallel -gt $items.Count) { $MaxParallel = $items.Count }

    $map = @{}
    if (-not ($script:UseNativeAnalyzer -and ('SmartTarNativeAnalyzer' -as [type]))) {
        foreach ($item in $items) {
            $map[[string]$item.FullName] = Invoke-NativeAdaptiveAnalysis $item
        }
        return $map
    }

    $paths = New-Object 'System.String[]' $items.Count
    $sizes = New-Object 'System.Int64[]' $items.Count
    for ($i = 0; $i -lt $items.Count; $i++) {
        $paths[$i] = [string]$items[$i].FullName
        $sizes[$i] = [int64]$items[$i].Length
    }

    try {
        $results = [SmartTarNativeAnalyzer]::AnalyzeFiles(
            $paths, $sizes, [int]$SampleBytes, [int]$MaxParallel
        )
        for ($i = 0; $i -lt $items.Count; $i++) {
            $map[$paths[$i]] = $results[$i]
        }
        return $map
    }
    catch {
        $script:UseNativeAnalyzer = $false
        foreach ($item in $items) {
            $map[[string]$item.FullName] = Invoke-NativeAdaptiveAnalysis $item
        }
        return $map
    }
}

function Stage-FilesPlan {
    param($SourceItem,[string]$Source,[string]$BaseRoot,[string]$Mode,[hashtable]$Groups)
    $script:analysisScope = Get-AnalysisScopeForMode $Mode
    $script:compressionPreference = Get-CompressionPreferenceForMode $Mode
    $profileName = Get-CompressionProfileDisplayName $Mode $script:compressionPreference
    $script:adaptiveDeepAnalyze = Test-ContentAnalysisEnabled $script:analysisScope
    $script:adaptiveStats = New-AdaptiveStats
    $script:dedupStats = New-FileDedupStats
    Set-BusyStatus "Planning blocks: $profileName..."
    $files = @(Get-SortedSourceFiles $SourceItem $Source $BaseRoot)
    $plans = New-Object System.Collections.ArrayList
    $analysisTargets = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        $smartGroup = Get-SmartGroupName $file.FullName
        $shouldAnalyze = Test-ShouldAnalyzeFileContent $script:analysisScope $smartGroup
        [void]$plans.Add([pscustomobject]@{ File=$file; SmartGroup=$smartGroup; ShouldAnalyze=[bool]$shouldAnalyze })
        if ($shouldAnalyze) { [void]$analysisTargets.Add($file) }
    }
    $analysisResults = @{}
    if ($analysisTargets.Count -gt 0) {
        $maxParallel = [int]$script:MaxParallelAnalysis
        if ($maxParallel -lt 1) { $maxParallel = 1 }

        if ($analysisTargets.Count -eq 1 -or $maxParallel -eq 1) {
            foreach ($file in $analysisTargets) {
                $analysisResults[[string]$file.FullName] = Invoke-NativeAdaptiveAnalysis $file
            }
        }
        else {
            Set-BusyStatus "Analyzing content..."
            $analysisResults = Invoke-ParallelAdaptiveAnalysis -Targets @($analysisTargets) -MaxParallel $maxParallel -SampleBytes ([int]$script:AdaptiveSampleBytes)
        }
    }
    $dedupState = @{}
    foreach ($plan in $plans) {
        $file = $plan.File
        $smartGroup = [string]$plan.SmartGroup
        if ([bool]$plan.ShouldAnalyze) {
            $result = $analysisResults[[string]$file.FullName]
            if ($null -eq $result) { $result = [pscustomobject]@{ Decision='unknown'; Error=$true; SampleBytes=0; ZeroBytes=0; EntropyAvailable=$false; Entropy=0.0; UniqueAvailable=$false; UniqueBytes=0 } }
            $adaptiveGroup = [string]$result.Decision
            if (Test-Blank $adaptiveGroup) { $adaptiveGroup = 'unknown' }
            Add-AdaptiveDecisionStat $adaptiveGroup ([int64]$file.Length) ([bool]$result.Error) ([int64]$result.SampleBytes) ([int64]$result.ZeroBytes) ([bool]$result.EntropyAvailable) ([double]$result.Entropy) ([bool]$result.UniqueAvailable) ([int]$result.UniqueBytes)
            $smartGroup = $adaptiveGroup
        }
        $groupName = Get-ModeGroupName $Mode $smartGroup
        if (-not $Groups.Contains($groupName)) { throw "Internal grouping error. Group '$groupName' does not exist for mode '$Mode'." }
        $relativePath = Get-RelativePathFromBase $BaseRoot $file.FullName
        $relativePath = Get-SafeStageRelativePath $relativePath ([System.IO.Path]::GetFileName($file.FullName))

        $script:planItemId = [int64]$script:planItemId + 1
        $planId = [int64]$script:planItemId
        Add-SmartTarPlanCatalogItem $planId $file $relativePath $groupName $smartGroup

        $linkTarget = Register-FileDedupCandidate $file $relativePath $dedupState
        Add-SmartTarPlanItems $planId $file $relativePath $groupName $linkTarget

        if ($null -eq $linkTarget -or (Test-Blank ([string]$linkTarget.Path))) {
            Add-FileToGroup $Groups[$groupName] $file.FullName $relativePath ([int64]$file.Length) ''
        }
    }
}

function Create-StructureStage {
    param($SourceItem, [string]$Source, [string]$BaseRoot, [string]$StageRoot)
    $count = 0
    if (-not $SourceItem.PSIsContainer) { return $count }
    $sourceFallback = [System.IO.Path]::GetFileName((Trim-PathSeparators $Source))
    $rootRelative = Get-RelativePathFromBase $BaseRoot $Source
    $rootRelative = Get-SafeStageRelativePath $rootRelative $sourceFallback
    [System.IO.Directory]::CreateDirectory((Join-Path $StageRoot $rootRelative)) | Out-Null
    $count++
    $directories = @(Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object @{ Expression = { (Get-RelativePathFromBase $BaseRoot $_.FullName).ToLowerInvariant() } })
    foreach ($directory in $directories) {
        $relativePath = Get-RelativePathFromBase $BaseRoot $directory.FullName
        $relativePath = Get-SafeStageRelativePath $relativePath ([System.IO.Path]::GetFileName($directory.FullName))
        [System.IO.Directory]::CreateDirectory((Join-Path $StageRoot $relativePath)) | Out-Null
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

    $shortPrefix = if (([string]$Prefix).StartsWith('group')) { 'g' } else { 'a' }
    $stageRoot = Join-Path $WorkRoot ('{0}_{1}' -f $shortPrefix, [guid]::NewGuid().ToString('N').Substring(0,8))
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
        if (-not (Test-Blank ([string]$file.LinkTarget))) {
            $targetPath = [string]$file.LinkTarget
        }

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
    param([string]$WorkRoot, $GroupFiles, [bool]$AllowCopyFallback = $false)
    return New-HardlinkStageInternal $WorkRoot $GroupFiles $AllowCopyFallback 'groupstage'
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

function Test-SmartTarPreparedStage {
    param([string]$StageRoot,[hashtable]$Group)
    $f=@($Group.Files);$p=New-Object string[] $f.Count;$z=New-Object long[] $f.Count
    for($i=0;$i-lt$f.Count;$i++){$p[$i]=[string]$f[$i].Rel;$z[$i]=[int64]$f[$i].Bytes}
    [SmartTarStageValidator]::Validate($StageRoot,$p,$z)
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

function Get-SmartTarMethodProbeSampleFiles {
    param($Files, [int64]$MaxBytes = 256MB, [int]$MaxFiles = 128, [int64]$MaxSingleFileBytes = 64MB)

    $sample = New-Object System.Collections.ArrayList
    $sampleBytes = [int64]0
    $eligible = @($Files | Where-Object { $null -ne $_ -and [int64]$_.Bytes -gt 0 } | Sort-Object @{ Expression = { [int64]$_.Bytes } }, @{ Expression = { [string]$_.Rel } })

    foreach ($file in $eligible) {
        if ($sample.Count -ge $MaxFiles) { break }
        $bytes = [int64]$file.Bytes
        if ($bytes -gt $MaxSingleFileBytes) { continue }
        if ($sample.Count -gt 0 -and (($sampleBytes + $bytes) -gt $MaxBytes)) { break }
        [void]$sample.Add($file)
        $sampleBytes += $bytes
    }

    if ($sample.Count -lt 1 -and $eligible.Count -gt 0) {
        [void]$sample.Add($eligible[0])
        $sampleBytes = [int64]$eligible[0].Bytes
    }

    return [pscustomobject]@{
        Files = [object[]]$sample.ToArray()
        Bytes = [int64]$sampleBytes
        Count = [int]$sample.Count
    }
}

function Invoke-SmartTarArchiveGroupMethodProbe {
    param([string]$TarPath, [string]$WorkRoot, [hashtable]$Group, [hashtable]$Capabilities)

    if ($null -eq $Group) { return }
    if ([int]$Group.FileCount -lt 1 -or [int64]$Group.Bytes -lt 128MB) { return }

    $methods = New-Object System.Collections.ArrayList
    if ($Capabilities.ContainsKey('store') -and [bool]$Capabilities['store']) { [void]$methods.Add((Get-TarMethodByName 'store')) }
    if ($Capabilities.ContainsKey('zstd19') -and [bool]$Capabilities['zstd19']) { [void]$methods.Add((Get-TarMethodByName 'zstd19')) }
    if ($Capabilities.ContainsKey('xz9') -and [bool]$Capabilities['xz9']) { [void]$methods.Add((Get-TarMethodByName 'xz9')) }
    if ($methods.Count -lt 2) { return }

    $sample = Get-SmartTarMethodProbeSampleFiles @($Group.Files)
    if ($null -eq $sample -or [int]$sample.Count -lt 1) { return }

    $probeRoot = Join-Path $WorkRoot ('methodprobe_' + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($probeRoot) | Out-Null
    $stageRoot = $null

    try {
        Set-BusyStatus ("Probing archive-like group methods ({0} files, {1})..." -f [int]$sample.Count, (Format-Bytes ([int64]$sample.Bytes)))
        $stageRoot = New-ChunkHardlinkStage $WorkRoot @($sample.Files)
        $relativePaths = @($sample.Files | ForEach-Object { [string]$_.Rel })
        $results = New-Object System.Collections.ArrayList

        foreach ($method in @($methods)) {
            if ($null -eq $method) { continue }
            $methodName = [string]$method.Name
            $probePath = Join-Path $probeRoot ('probe_' + $methodName + $method.Extension)
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Create-BlockFromStageList $TarPath $stageRoot $probePath $method $relativePaths
                $sw.Stop()
                if (Test-Path -LiteralPath $probePath) {
                    $probeSize = [int64](Get-Item -LiteralPath $probePath).Length
                    [void]$results.Add([pscustomobject]@{ Method=$method; Name=$methodName; Display=[string]$method.Display; Size=$probeSize; Milliseconds=[int64]$sw.ElapsedMilliseconds })
                }
            }
            catch {
                Add-GroupDiagnostic ([string]$Group.Name) 'method-probe-failed' ("{0} probe failed: {1}" -f [string]$method.Display, [string]$_.Exception.Message) ([int]$sample.Count) ([int64]$sample.Bytes)
            }
            finally {
                Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
            }
        }

        $resultList = @($results)
        if ($resultList.Count -lt 2) { return }
        $storeResult = @($resultList | Where-Object { [string]$_.Name -eq 'store' } | Select-Object -First 1)
        if ($null -eq $storeResult) { return }

        $best = @($resultList | Sort-Object @{ Expression = { [int64]$_.Size } }, @{ Expression = { [int64]$_.Milliseconds } } | Select-Object -First 1)
        if ($null -eq $best) { return }

        $storeSize = [int64]$storeResult.Size
        if ($storeSize -le 0) { return }
        $improvement = ([double]($storeSize - [int64]$best.Size) / [double]$storeSize)

        $parts = @()
        foreach ($r in @($resultList | Sort-Object Name)) {
            $ratio = if ([int64]$sample.Bytes -gt 0) { ('{0:N2} %' -f (([double]$r.Size / [double]$sample.Bytes) * 100.0)) } else { 'n/a' }
            $parts += ('{0}={1} ({2}, {3} ms)' -f [string]$r.Display, (Format-Bytes ([int64]$r.Size)), $ratio, [int64]$r.Milliseconds)
        }

        if ([string]$best.Name -ne 'store' -and $improvement -ge 0.02) {
            $Group.Method = $best.Method
            $Group.Reason = ("Archive-like data method probe selected {0}. Sample: {1}. STORE improvement: {2:N2} %." -f [string]$best.Display, ($parts -join '; '), ($improvement * 100.0))
            Add-GroupDiagnostic ([string]$Group.Name) 'method-probe-selected' $Group.Reason ([int]$sample.Count) ([int64]$sample.Bytes)
        }
        else {
            $Group.Reason = ("Archive-like data kept STORE after method probe. Sample: {0}. Best improvement was {1:N2} %." -f ($parts -join '; '), ([Math]::Max(0.0, $improvement) * 100.0))
            Add-GroupDiagnostic ([string]$Group.Name) 'method-probe-store' $Group.Reason ([int]$sample.Count) ([int64]$sample.Bytes)
        }
    }
    finally {
        Remove-SmartTarTempFolder $stageRoot
        Remove-SmartTarTempFolder $probeRoot
    }
}

function Invoke-SmartArchiveMethodProbes {
    param([string]$TarPath, [string]$WorkRoot, [string]$Mode, [hashtable]$Groups, [hashtable]$Capabilities)

    if ([string]$Mode -ne 'Smart') { return }
    if ($null -eq $Groups -or -not $Groups.Contains('archives')) { return }
    Invoke-SmartTarArchiveGroupMethodProbe $TarPath $WorkRoot $Groups['archives'] $Capabilities
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
        method      = [string]$Method.Name
        display     = [string]$Method.Display
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

function Get-StarOuterTarLayout {
    param([string]$ArchivePath)
    if(Test-Blank $ArchivePath -or -not(Test-Path -LiteralPath $ArchivePath -PathType Leaf)){throw 'STAR outer archive is missing for layout inspection.'}
    $stream=[System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    try{
        $header=New-Object byte[] 512
        $pendingStart=[int64]-1;$entries=New-Object System.Collections.ArrayList;$manifestCount=0;$manifestStart=[int64]-1;$lastPath='';$endOffset=[int64]-1
        while($stream.Position -lt $stream.Length){
            $headerOffset=[int64]$stream.Position;$read=$stream.Read($header,0,512)
            if($read -ne 512){throw "Truncated outer TAR header at offset $headerOffset."}
            $allZero=$true;foreach($b in $header){if($b -ne 0){$allZero=$false;break}}
            if($allZero){$endOffset=$headerOffset;break}
            $name=([System.Text.Encoding]::ASCII.GetString($header,0,100)).Trim([char]0).Trim()
            $prefix=([System.Text.Encoding]::ASCII.GetString($header,345,155)).Trim([char]0).Trim()
            if(-not(Test-Blank $prefix)){$name=$prefix+'/'+$name}
            $sizeText=([System.Text.Encoding]::ASCII.GetString($header,124,12)).Trim([char]0,[char]32)
            $size=[int64]0
            if(-not(Test-Blank $sizeText)){try{$size=[Convert]::ToInt64($sizeText,8)}catch{throw "Invalid outer TAR size at offset $headerOffset."}}
            $type=[char]$header[156]
            $dataBlocks=[int64][Math]::Ceiling(([double]$size)/512.0)
            $next=[int64]($headerOffset+512+($dataBlocks*512))
            if($next -gt $stream.Length){throw "Outer TAR entry exceeds file size: $name"}
            if($type -eq 'x' -or $type -eq 'g' -or $type -eq 'L' -or $type -eq 'K'){
                if($pendingStart -lt 0){$pendingStart=$headerOffset}
            }else{
                $recordStart=if($pendingStart -ge 0){$pendingStart}else{$headerOffset}
                [void]$entries.Add([pscustomobject]@{Path=(Convert-ToTarPath $name);RecordStart=[int64]$recordStart;HeaderOffset=$headerOffset;Size=$size;Type=[string]$type})
                $lastPath=Convert-ToTarPath $name
                if($lastPath -eq 'manifest.json'){$manifestCount++;$manifestStart=[int64]$recordStart}
                $pendingStart=[int64]-1
            }
            $stream.Position=$next
        }
        if($endOffset -lt 0){$endOffset=[int64]$stream.Length}
        return [pscustomobject]@{EndOfEntriesOffset=$endOffset;ManifestCount=$manifestCount;ManifestRecordStart=$manifestStart;LastEntryPath=$lastPath;Entries=@($entries);FileLength=[int64]$stream.Length}
    }finally{$stream.Dispose()}
}

function Set-ManifestCanonicalOuterLayout {
    param($Manifest,[int64]$TruncateOffset)
    if($null -eq $Manifest){throw 'Manifest object is missing.'}
    if($TruncateOffset -le 0 -or ($TruncateOffset % 512) -ne 0){throw "Invalid canonical STAR truncate offset: $TruncateOffset"}
    $layout=[ordered]@{schema=1;mode='replaceable-tail-manifest';manifestEntry='manifest.json';manifestPosition='last';truncateOffset=$TruncateOffset;alignmentBytes=512}
    if($Manifest -is [System.Collections.IDictionary]){$Manifest['outerLayout']=$layout}
    else{$Manifest|Add-Member -NotePropertyName outerLayout -NotePropertyValue ([pscustomobject]$layout) -Force}
}

function Test-StarCanonicalTailLayout {
    param([string]$ArchivePath,$Manifest)
    if($null -eq $Manifest -or $null -eq $Manifest.outerLayout){throw 'STAR archive does not contain canonical tail metadata required for ADD.'}
    $layout=$Manifest.outerLayout
    if([int]$layout.schema -ne 1 -or [string]$layout.mode -ne 'replaceable-tail-manifest'){throw 'Unsupported STAR canonical tail layout.'}
    $offset=[int64]$layout.truncateOffset
    if($offset -le 0 -or ($offset % 512) -ne 0){throw "Unsafe STAR truncate offset: $offset"}
    $scan=Get-StarOuterTarLayout $ArchivePath
    if([int]$scan.ManifestCount -ne 1){throw "Canonical STAR must contain exactly one manifest.json entry; found $($scan.ManifestCount)."}
    if([string]$scan.LastEntryPath -ne 'manifest.json'){throw "Canonical STAR manifest is not the last logical entry: $($scan.LastEntryPath)"}
    if([int64]$scan.ManifestRecordStart -ne $offset){throw "Canonical STAR truncate offset mismatch. Manifest=$offset, actual=$($scan.ManifestRecordStart)."}
    foreach($block in @($Manifest.blocks)){
        $path=(Convert-ToTarPath ([string]$block.path)).Trim('/').Trim()
        $entry=@($scan.Entries|Where-Object{([string]$_.Path).Trim('/').Equals($path,[System.StringComparison]::OrdinalIgnoreCase)})|Select-Object -First 1
        if($null -eq $entry){throw "Canonical STAR active block is missing from outer TAR: $path"}
        if([int64]$entry.RecordStart -ge $offset){throw "Canonical STAR active block lies after truncate offset: $path"}
    }
    return $scan
}

function Reset-StarTempToCanonicalDataEnd {
    param([string]$ArchivePath,[int64]$TruncateOffset)
    if($TruncateOffset -le 0 -or ($TruncateOffset % 512) -ne 0){throw "Refusing unsafe STAR truncate offset: $TruncateOffset"}
    $stream=[System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    try{
        if($TruncateOffset -ge $stream.Length){throw 'STAR truncate offset is outside the temporary archive.'}
        $stream.SetLength($TruncateOffset)
        $stream.Position=$TruncateOffset
        $zeros=New-Object byte[] 1024
        $stream.Write($zeros,0,$zeros.Length)
        $stream.Flush($true)
    }finally{$stream.Dispose()}
}

function Write-Manifest {
    param([string]$Path, $Data)
    $Data | ConvertTo-Json -Depth 40 -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-StarOuterTempArchive {
    param([string]$Destination)
    if (Test-Blank $Destination) { throw 'Destination archive path is empty.' }
    $destDir = [System.IO.Path]::GetDirectoryName($Destination)
    if (Test-Blank $destDir) { $destDir = (Get-Location).Path }
    [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
    if (-not (Test-DirectoryWritable $destDir)) { throw "Destination folder is not writable: $destDir" }
    $tempArchive = Join-Path $destDir (([System.IO.Path]::GetFileName($Destination)) + '.tmp')
    if (Test-Path -LiteralPath $tempArchive) { Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue }
    return $tempArchive
}

function Add-StarOuterEntry {
    param([string]$TarPath, [string]$ArchivePath, [string]$WorkRoot, [string]$RelativeEntry, [string]$FailMessage)
    if (Test-Blank $ArchivePath) { throw 'Outer STAR temp archive path is empty.' }
    if (Test-Blank $WorkRoot -or -not (Test-Path -LiteralPath $WorkRoot)) { throw 'Work root does not exist.' }
    $entry = Convert-ToTarPath $RelativeEntry
    if (Test-Blank $entry -or -not (Test-RelativePathSafe $entry)) { throw "Unsafe STAR outer entry path: $entry" }
    if (Test-Path -LiteralPath $ArchivePath) { Invoke-Tar $TarPath @('--format=pax', '-rf', $ArchivePath, '-C', $WorkRoot, $entry) $FailMessage }
    else { Invoke-Tar $TarPath @('--format=pax', '-cf', $ArchivePath, '-C', $WorkRoot, $entry) $FailMessage }
}

function Test-StarOuterEntryExists {
    param([string]$TarPath, [string]$ArchivePath, [string]$RelativeEntry)

    if (Test-Blank $ArchivePath -or -not (Test-Path -LiteralPath $ArchivePath)) { return $false }
    if (Test-Blank $RelativeEntry) { return $false }

    $wanted = (Convert-ToTarPath $RelativeEntry).TrimStart('./')
    $result = Invoke-TarRaw $TarPath @('-tf', $ArchivePath)
    if ([int]$result.ExitCode -ne 0) {
        $text = [string]$result.Output
        if (Test-Blank $text) { $text = 'No tar.exe output captured.' }
        throw "Cannot verify outer STAR entries. tar.exe exit code: $($result.ExitCode)`r`n$text"
    }

    foreach ($entry in @(([string]$result.Output) -split "`r?`n")) {
        if (Test-Blank $entry) { continue }
        $normalized = (Convert-ToTarPath $entry).TrimStart('./')
        if ($normalized -eq $wanted) { return $true }
    }

    return $false
}

function Add-BlockToStarOuterAndCleanup {
    param([string]$TarPath,[string]$OuterArchivePath,[string]$WorkRoot,[ref]$Blocks,[string]$BlockId,[string]$GroupName,[string]$BlockPath,[hashtable]$Method,[string]$Reason,[int]$FileCount,[int]$DirCount,[int64]$SourceBytes)
    if (Test-Blank $BlockPath -or -not (Test-Path -LiteralPath $BlockPath)) { throw "Block file does not exist before publish: $BlockPath" }
    $relativeBlock = 'blocks/' + [System.IO.Path]::GetFileName($BlockPath)
    Set-BusyStatus "Publishing block $BlockId $GroupName into STAR..."
    Add-StarOuterEntry $TarPath $OuterArchivePath $WorkRoot $relativeBlock 'Outer .star block append failed.'
    Set-BusyStatus "Confirming published block $BlockId $GroupName..."
    if (-not (Test-StarOuterEntryExists $TarPath $OuterArchivePath $relativeBlock)) {
        throw "Published block was not found in outer STAR archive: $relativeBlock"
    }
    Add-BlockManifestItem $Blocks $BlockId $GroupName $BlockPath $Method $Reason $FileCount $DirCount $SourceBytes
    Remove-Item -LiteralPath $BlockPath -Force -ErrorAction SilentlyContinue
}

function Complete-StarOuterArchive {
    param([string]$TempArchive, [string]$Destination)
    if (Test-Blank $TempArchive -or -not (Test-Path -LiteralPath $TempArchive)) { throw 'STAR temp archive does not exist.' }
    if (Test-Blank $Destination) { throw 'Destination archive path is empty.' }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Move-Item -LiteralPath $TempArchive -Destination $Destination -Force
}

function Get-CompressionWorkerLimit {
    param([int]$Count)

    # SmartTAR intentionally uses two compression streams. All group stages are
    # prepared before scheduling, so text/XZ and binary/XZ can start back-to-back.
    return [Math]::Max(1, [Math]::Min(2, [Math]::Max(1, $Count)))
}

function Get-CompressionQueuePriority {
    param($Group)

    $name = ([string]$Group.Name).ToLowerInvariant()
    $algorithm = ([string]$Group.Method.Algorithm).ToLowerInvariant()
    $bytes = [int64]$Group.Bytes

    # Empirical order from the large ISO test. text/XZ was the slowest workload
    # per source byte; binary/XZ was the second long-running workload.
    if ($name -eq 'text' -and $algorithm -eq 'xz') { return 0 }
    if ($name -eq 'binary' -and $algorithm -eq 'xz') { return 10 }
    if ($algorithm -eq 'zstd') { return 20 }
    if ($algorithm -eq 'xz' -and $bytes -ge 1MB) { return 30 }
    if ($algorithm -eq 'store') { return 40 }
    if ($algorithm -eq 'xz') { return 50 }
    return 60
}
function Convert-ToWindowsProcessArgument {
    param([string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]92) { $slashes++; continue }
        if ($ch -eq [char]34) {
            [void]$builder.Append(([string][char]92) * ($slashes * 2 + 1))
            [void]$builder.Append([char]34)
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(([string][char]92) * $slashes); $slashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($slashes -gt 0) { [void]$builder.Append(([string][char]92) * ($slashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Convert-ToProcessArgumentString {
    param($Arguments)
    $quoted = @()
    foreach ($argument in @($Arguments)) {
        $quoted += (Convert-ToWindowsProcessArgument ([string]$argument))
    }
    return ($quoted -join ' ')
}
function Start-TarAsync {
    param([string]$TarPath, $TarArguments)

    $argumentString = Convert-ToProcessArgumentString $TarArguments
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $TarPath
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    # tar create writes no useful standard output. Redirecting and asynchronously
    # reading both streams caused disposed-stream errors in Windows PowerShell 5.1.
    # Keep stdout attached and capture only stderr, which contains diagnostics.
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "Unable to start TAR process. Arguments: $argumentString"
    }

    try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

    $errorTask = $process.StandardError.ReadToEndAsync()
    return [pscustomobject]@{
        P = $process
        E = $errorTask
        Arguments = $argumentString
    }
}
function Build-AndPublishBlocksParallel {
    param(
        [string]$TarPath,
        [hashtable]$Groups,
        [string]$BlocksDir,
        [string]$WorkRoot,
        [string]$StructureStage,
        [int]$StructureDirCount,
        [hashtable]$StoreMethod,
        [bool]$AllowGroupCopyFallback,
        [string]$OuterArchivePath,
        [int]$StartIndex = 1,
        [string]$BlockSuffix = ''
    )

    $blocks = @()
    $index = [Math]::Max(1, $StartIndex)
    $script:lastGroupDiagnostics = @()

    if ($StructureDirCount -gt 0) {
        $id = '{0:D6}' -f $index
        $method = Get-TarMethodByName 'xz9'
        if ($null -eq $method) { $method = $StoreMethod }
        $blockPath = Join-Path $BlocksDir ("$id`_structure$BlockSuffix$($method.Extension)")

        Set-BusyStatus "Creating structure block $id..."
        Create-BlockFromStageDirect $TarPath $StructureStage $blockPath $method
        Add-BlockToStarOuterAndCleanup $TarPath $OuterArchivePath $WorkRoot ([ref]$blocks) $id 'structure' $blockPath $method 'Directory structure block.' 0 $StructureDirCount 0
        Remove-SmartTarTempFolder $StructureStage
        $index++
    }

    # Assign stable IDs independently from runtime scheduling priority.
    $jobs = New-Object System.Collections.ArrayList
    foreach ($groupName in $Groups.Keys) {
        $group = $Groups[$groupName]
        if ([int]$group.FileCount -le 0) { continue }

        [void]$jobs.Add([pscustomobject]@{
            Id       = ('{0:D6}' -f $index)
            Group    = $group
            Priority = (Get-CompressionQueuePriority $group)
            Bytes    = [int64]$group.Bytes
            Name     = [string]$group.Name
        })
        $index++
    }

    $prepared = New-Object System.Collections.ArrayList
    $active = New-Object System.Collections.ArrayList
    $done = New-Object System.Collections.ArrayList

    try {
        # Phase 1: prepare every data stage before any data compression begins.
        $prepareNumber = 0
        foreach ($job in @($jobs | Sort-Object Id)) {
            $prepareNumber++
            $group = $job.Group
            Set-BusyStatus ("Preparing block stage {0}/{1}: {2} ({3})..." -f $prepareNumber, $jobs.Count, ([string]$group.Name), ([string]$group.Method.Display))

            $stagePath = New-GroupHardlinkStage $WorkRoot @($group.Files) $AllowGroupCopyFallback
            [void](Normalize-XzStageIfNeeded $stagePath $group.Method)
            Set-BusyStatus ("Validating prepared stage {0}/{1}: {2}..." -f $prepareNumber,$jobs.Count,([string]$group.Name))
            Test-SmartTarPreparedStage $stagePath $group
            $blockPath = Join-Path $BlocksDir ("$($job.Id)`_$($group.Name)$BlockSuffix$($group.Method.Extension)")

            [void]$prepared.Add([pscustomobject]@{
                Id       = [string]$job.Id
                Group    = $group
                Priority = [int]$job.Priority
                Bytes    = [int64]$job.Bytes
                Name     = [string]$job.Name
                Stage    = [string]$stagePath
                Block    = [string]$blockPath
            })
        }

        # Phase 2: start only after all stages are ready.
        $pending = New-Object System.Collections.ArrayList
        $orderedPrepared = @(
            $prepared |
                Sort-Object `
                    @{ Expression = { [int]$_.Priority }; Ascending = $true }, `
                    @{ Expression = { [int64]$_.Bytes }; Descending = $true }, `
                    @{ Expression = { [string]$_.Name }; Ascending = $true }
        )
        foreach ($job in $orderedPrepared) { [void]$pending.Add($job) }

        $limit = Get-CompressionWorkerLimit $pending.Count
        Set-BusyStatus ("All {0} data stages are ready. Starting {1} compression stream(s)..." -f $pending.Count, $limit)

        while ($pending.Count -gt 0 -or $active.Count -gt 0) {
            while ($pending.Count -gt 0 -and $active.Count -lt $limit) {
                $job = $pending[0]
                [void]$pending.RemoveAt(0)
                $group = $job.Group

                Set-BusyStatus ("Starting compression: {0} ({1}). Active={2}, pending={3}..." -f ([string]$group.Name), ([string]$group.Method.Display), ($active.Count + 1), $pending.Count)
                $processData = Start-TarAsync $TarPath (@($group.Method.CreateArgs) + @($job.Block, '-C', $job.Stage, '.'))

                [void]$active.Add([pscustomobject]@{
                    Id       = [string]$job.Id
                    Group    = $group
                    Stage    = [string]$job.Stage
                    Block    = [string]$job.Block
                    P        = $processData.P
                    E        = $processData.E
                    Args     = $processData.Arguments
                })
            }

            if ($active.Count -gt 0) {
                $activeNames = @($active | ForEach-Object { [string]$_.Group.Name }) -join ', '
                Set-BusyStatus ("Parallel compression: {0} active, {1} pending. Active: {2}" -f $active.Count, $pending.Count, $activeNames)
            }

            $finished = @($active | Where-Object { $_.P.HasExited })
            if ($finished.Count -eq 0 -and $active.Count -gt 0) {
                Start-Sleep -Milliseconds 100
                continue
            }

            foreach ($job in $finished) {
                [void]$active.Remove($job)
                $job.P.WaitForExit()
                $exitCode = $job.P.ExitCode

                # Fully complete the asynchronous stderr read before disposing the
                # process. GetAwaiter().GetResult() also exposes the real exception.
                $errorText = ''
                try {
                    $errorText = [string]$job.E.GetAwaiter().GetResult()
                }
                catch {
                    $errorText = "Unable to read TAR diagnostics: $($_.Exception.Message)"
                }
                try { $job.P.Dispose() } catch {}

                Remove-SmartTarTempFolder $job.Stage

                if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $job.Block)) {
                    throw "Parallel block failed: $($job.Group.Name). Arguments: $($job.Args) Error: $errorText"
                }

                [void]$done.Add($job)
            }
        }

        # Publish by stable ID, independent from runtime completion order.
        foreach ($job in @($done | Sort-Object Id)) {
            Add-BlockToStarOuterAndCleanup $TarPath $OuterArchivePath $WorkRoot ([ref]$blocks) $job.Id ([string]$job.Group.Name) $job.Block $job.Group.Method ([string]$job.Group.Reason + ' parallel block; all stages prepared before scheduling.') ([int]$job.Group.FileCount) 0 ([int64]$job.Group.Bytes)
        }

        return $blocks
    }
    finally {
        foreach ($job in @($active)) {
            try {
                if (-not $job.P.HasExited) { $job.P.Kill() }
            }
            catch {}
            try { $job.P.Dispose() } catch {}
        }

        foreach ($job in @($prepared)) {
            Remove-SmartTarTempFolder ([string]$job.Stage)
        }
    }
}

function Build-AndPublishBlocksSequential {
    param([string]$TarPath,[hashtable]$Groups,[string]$BlocksDir,[string]$WorkRoot,[string]$StructureStage,[int]$StructureDirCount,[hashtable]$StoreMethod,[bool]$AllowGroupCopyFallback,[string]$OuterArchivePath,[int]$StartIndex = 1,[string]$BlockSuffix = '')
    $script:lastGroupDiagnostics = @(); $blocks = @(); $index = [Math]::Max(1, $StartIndex)
    if ($StructureDirCount -gt 0) {
        $id = '{0:D6}' -f $index
        $structureMethod = Get-TarMethodByName 'xz9'; if ($null -eq $structureMethod) { $structureMethod = $StoreMethod }
        $blockPath = Join-Path $BlocksDir ("$id`_structure$BlockSuffix$($structureMethod.Extension)"); $structureReason = 'Directory structure only. Metadata-friendly XZ9 structure block.'
        try { Set-BusyStatus "Creating block $id structure..."; Create-BlockFromStageDirect $TarPath $StructureStage $blockPath $structureMethod }
        catch { if ([string]$structureMethod.Name -ne [string]$StoreMethod.Name) { Remove-Item -LiteralPath $blockPath -Force -ErrorAction SilentlyContinue; $structureMethod = $StoreMethod; $blockPath = Join-Path $BlocksDir ("$id`_structure$BlockSuffix$($structureMethod.Extension)"); $structureReason = 'Directory structure only. XZ9 structure block failed; STORE fallback used.'; Set-BusyStatus "Creating block $id structure..."; Create-BlockFromStageDirect $TarPath $StructureStage $blockPath $structureMethod } else { throw } }
        Add-BlockToStarOuterAndCleanup $TarPath $OuterArchivePath $WorkRoot ([ref]$blocks) $id 'structure' $blockPath $structureMethod $structureReason 0 $StructureDirCount 0
        Remove-SmartTarTempFolder $StructureStage; $index++
    }
    foreach ($groupName in $Groups.Keys) {
        $group = $Groups[$groupName]; if ([int]$group.FileCount -le 0) { continue }
        $id = '{0:D6}' -f $index; $safeGroup = [string]$group.Name; $blockPath = Join-Path $BlocksDir ("$id`_$safeGroup$BlockSuffix$($group.Method.Extension)"); $stageRoot = $null; $ok = $false; $err = $null; $usedCopyFallback = $false
        try { $stageModeText = if ($AllowGroupCopyFallback) { 'hardlink/copy' } else { 'hardlink' }; Set-BusyStatus "Creating group $stageModeText stage for block $id $safeGroup..."; $stageRoot = New-GroupHardlinkStage $WorkRoot @($group.Files) $AllowGroupCopyFallback; if ([string]$group.Method.Algorithm -eq 'xz') { Set-BusyStatus "Normalizing XZ stage directory timestamps for block $id $safeGroup..." }; Set-BusyStatus "Creating group block $id $safeGroup..."; Create-BlockFromStageDirect $TarPath $stageRoot $blockPath $group.Method; $ok = $true; $usedCopyFallback = [bool]$AllowGroupCopyFallback } catch { $err = [string]$_.Exception.Message; $ok = $false } finally { Remove-SmartTarTempFolder $stageRoot }
        if ($ok -and (Test-Path -LiteralPath $blockPath)) { $diagMessage = if ($usedCopyFallback) { 'Created as one group-stage block. Copy fallback was allowed if hardlinks were unavailable.' } else { 'Created as one group-stage block.' }; if ([string]$group.Method.Algorithm -eq 'xz') { $diagMessage += ' XZ directory timestamps normalized.' }; Add-GroupDiagnostic $safeGroup 'group-stage-ok' $diagMessage ([int]$group.FileCount) ([int64]$group.Bytes); Add-BlockToStarOuterAndCleanup $TarPath $OuterArchivePath $WorkRoot ([ref]$blocks) $id $safeGroup $blockPath $group.Method ([string]$group.Reason + ' group-stage block.') ([int]$group.FileCount) 0 ([int64]$group.Bytes); $index++; continue }
        Add-GroupDiagnostic $safeGroup 'fallback-chunked' ('Group-stage failed. ' + $err) ([int]$group.FileCount) ([int64]$group.Bytes); Set-BusyStatus "Group stage failed for $safeGroup. Falling back to chunked blocks..."
        $chunks = Split-FileChunks -Files $group.Files; $part = 1
        foreach ($chunkInfo in $chunks) { $chunkFiles = @($chunkInfo.Files); if ($chunkFiles.Count -lt 1) { continue }; $id = '{0:D6}' -f $index; $suffix = if ($chunks.Count -gt 1) { '_p{0:D3}' -f $part } else { '' }; $fallbackGroup = ([string]$group.Name) + $suffix; $blockPath = Join-Path $BlocksDir ("$id`_$fallbackGroup$BlockSuffix$($group.Method.Extension)"); $chunkStage = $null; try { Set-BusyStatus "Creating fallback chunk stage for block $id..."; $chunkStage = New-ChunkHardlinkStage $WorkRoot $chunkFiles; $relativePaths = @($chunkFiles | ForEach-Object { [string]$_.Rel }); if ([string]$group.Method.Algorithm -eq 'xz') { Set-BusyStatus "Normalizing XZ fallback stage timestamps for block $id..." }; Set-BusyStatus "Creating fallback block $id $fallbackGroup..."; Create-BlockFromStageList $TarPath $chunkStage $blockPath $group.Method $relativePaths } finally { Remove-SmartTarTempFolder $chunkStage }; $sourceBytes = [int64]0; foreach ($file in $chunkFiles) { $sourceBytes += [int64]$file.Bytes }; $reason = ([string]$group.Reason) + " Group-stage failed, chunk fallback used. Error: $err"; Add-BlockToStarOuterAndCleanup $TarPath $OuterArchivePath $WorkRoot ([ref]$blocks) $id $fallbackGroup $blockPath $group.Method $reason ([int]$chunkFiles.Count) 0 $sourceBytes; $index++; $part++ }
    }
    return $blocks
}

function Test-PlannedDedupAliases {
    param([hashtable]$Groups)
    $physical=@{}
    foreach($n in $Groups.Keys){foreach($f in @($Groups[$n].Files)){$rel=(Convert-ToTarPath([string]$f.Rel)).Trim('/').Trim();$key=$rel.ToLowerInvariant();if($physical.ContainsKey($key)){throw "Duplicate physical archive path in block plan: $rel"};$physical[$key]=[int64]$f.Bytes}}
    foreach($a in @($script:planDedupAliases)){$p=(Convert-ToTarPath([string]$a.path)).Trim('/').Trim();$t=(Convert-ToTarPath([string]$a.target)).Trim('/').Trim();if(Test-Blank $t-or-not(Test-RelativePathSafe $t)){throw "Unsafe planned dedup target: $t"};$k=$t.ToLowerInvariant();if(-not$physical.ContainsKey($k)){throw "Planned dedup target is not a physical block member: $t"};if([int64]$physical[$k]-ne[int64]$a.bytes){throw "Planned dedup target size mismatch: $p -> $t. Alias=$($a.bytes), target=$($physical[$k])."}}
}

function Build-Manifest {
    param([string]$Source,$SourceItem,[string]$SourceLeaf,[string]$Mode,[hashtable]$Capabilities,[hashtable]$Profile,$Blocks)
    $profileName = Get-CompressionProfileDisplayName $Mode ([string]$script:compressionPreference)
    $storedUniqueBytes = [int64]0
    foreach ($block in @($Blocks)) { if ([string]$block.group -ne 'structure') { $storedUniqueBytes += [int64]$block.sourceBytes } }
    $aliasBytes = [int64]0
    foreach ($alias in @($script:planDedupAliases)) { $aliasBytes += [int64]$alias.bytes }
    $summary = [ordered]@{ storedUniqueBytes = $storedUniqueBytes; catalogFiles = if ($null -ne $script:planDiagnostics) { [int]$script:planDiagnostics.catalogFiles } else { 0 }; uniqueFiles = if ($null -ne $script:planDiagnostics) { [int]$script:planDiagnostics.uniqueFiles } else { 0 }; aliasFiles = @($script:planDedupAliases).Count; dedupAliasCount = @($script:planDedupAliases).Count; dedupAliasBytes = $aliasBytes }
    $manifest = [ordered]@{ format = $script:FormatName; formatVersion = $script:FormatVersion; tool = 'SmartTAR'; toolVersion = $script:ToolVersion; createdUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); sourceName = $SourceLeaf; sourceType = if ($SourceItem.PSIsContainer) { 'Folder' } else { 'File' }; sourceBytes = Get-SourceSize $Source; compressionMode = $Mode; compressionProfile = $profileName; build = [ordered]@{ workrootMode = [string]$script:buildWorkMode; pipeline = 'parallel-block-build-sequential-publish'; blockCleanup = 'after-append'; manifestPosition = 'last-outer-entry'; outerTarFormat = 'pax' }; summary = $summary; dedupAliasMode = 'unique-only-restored-on-extract'; dedupAliases = @($script:planDedupAliases); blocks = @($Blocks) }
    if ([bool]$script:IncludeDebugDiagnosticsInManifest) { $manifest.diagnostics = [ordered]@{ source = $Profile; adaptive = $script:adaptiveStats; fileDedup = $script:dedupStats; plan = $script:planDiagnostics } }
    return $manifest
}

# ============================================================================
# 08. Extraction, verification and summary
# ============================================================================

function Read-OuterManifest {
    param([string]$OuterRoot)

    $manifestPath = Join-Path $OuterRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'manifest.json was not found.' }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.format -ne 'STAR') {
        throw 'Invalid archive format.'
    }
    $formatVersion=[int]$manifest.formatVersion
    if($formatVersion -notin @(1,2)){throw "Unsupported STAR format version: $formatVersion"}
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
    $blocks = @($Manifest.blocks | Where-Object { [string]$_.group -ne 'structure' })
    if ($blocks.Count -lt 1) { return '' }
    $lines = @('', 'Compression groups:')
    foreach ($block in $blocks) { $lines += ('{0}: {1} files, source={2}, method={3}' -f ([string]$block.group), ([int]$block.fileCount), (Format-Bytes ([int64]$block.sourceBytes)), ([string]$block.display)) }
    return ($lines -join "`r`n")
}

function Format-CompressionMethodSummary {
    param($Manifest)
    try{
        $blocks=@($Manifest.blocks|Where-Object{[string]$_.group -ne 'structure'}); if($blocks.Count -lt 1){return ''}
        $summary=@{}
        foreach($block in $blocks){
            $display=[string]$block.display; if(Test-Blank $display){$display=[string]$block.method}; if(Test-Blank $display){$display='UNKNOWN'}
            if(-not $summary.ContainsKey($display)){$summary[$display]=[pscustomobject]@{Blocks=0;Files=0;SourceBytes=[int64]0;ArchiveBytes=[int64]0}}
            $summary[$display].Blocks=[int]$summary[$display].Blocks+1; $summary[$display].Files=[int]$summary[$display].Files+[int]$block.fileCount
            $summary[$display].SourceBytes=[int64]$summary[$display].SourceBytes+[int64]$block.sourceBytes; $summary[$display].ArchiveBytes=[int64]$summary[$display].ArchiveBytes+[int64]$block.sizeBytes
        }
        $totalSource=[int64]0; $totalArchive=[int64]0; foreach($key in $summary.Keys){$totalSource+=[int64]$summary[$key].SourceBytes; $totalArchive+=[int64]$summary[$key].ArchiveBytes}
        $lines=@('', 'Compression method summary:')
        foreach($key in @($summary.Keys|Sort-Object)){
            $item=$summary[$key]
            $sourcePct=if($totalSource -gt 0){'{0:N1} %' -f (([double]$item.SourceBytes/[double]$totalSource)*100.0)}else{'0,0 %'}
            $archivePct=if($totalArchive -gt 0){'{0:N1} %' -f (([double]$item.ArchiveBytes/[double]$totalArchive)*100.0)}else{'0,0 %'}
            $methodRatio=if([int64]$item.SourceBytes -gt 0){'{0:N2} %' -f (([double]$item.ArchiveBytes/[double]$item.SourceBytes)*100.0)}else{'n/a'}
            $methodSaved=if([int64]$item.SourceBytes -gt 0){'{0:N2} %' -f ((1.0-([double]$item.ArchiveBytes/[double]$item.SourceBytes))*100.0)}else{'n/a'}
            $lines+=('{0}: {1} blocks, {2} files, source={3} ({4}), archive={5} ({6}), ratio={7}, saved={8}' -f $key,([int]$item.Blocks),([int]$item.Files),(Format-Bytes ([int64]$item.SourceBytes)),$sourcePct,(Format-Bytes ([int64]$item.ArchiveBytes)),$archivePct,$methodRatio,$methodSaved)
        }
        return ($lines -join "`r`n")
    }catch{return ''}
}

function Format-FileDedupDiagnostics {
    param($Manifest)
    try { $aliases=@($Manifest.dedupAliases); if($aliases.Count -lt 1 -and $null -ne $Manifest.dedup){$aliases=@($Manifest.dedup.aliases)}; $summary=$Manifest.summary; $dedup=$Manifest.fileDedupDiagnostics; if($null -eq $dedup -and $null -ne $Manifest.diagnostics){$dedup=$Manifest.diagnostics.fileDedup}; $enabled=$true; if($null -ne $dedup -and $null -ne $dedup.enabled){$enabled=[bool]$dedup.enabled}; $lines=@('', 'File dedup summary:'); if(-not $enabled){$lines+='File dedup: OFF'; return ($lines -join "`r`n")}; $mode=[string]$Manifest.dedupAliasMode; if(Test-Blank $mode -and $null -ne $Manifest.dedup){$mode=[string]$Manifest.dedup.mode}; if(Test-Blank $mode -and $null -ne $dedup){$mode=[string]$dedup.mode}; if(Test-Blank $mode){$mode='unique-only-restored-on-extract'}; $aliasCount=if($null -ne $summary -and $null -ne $summary.dedupAliasCount){[int]$summary.dedupAliasCount}else{[int]$aliases.Count}; $aliasBytes=[int64]0; if($null -ne $summary -and $null -ne $summary.dedupAliasBytes){$aliasBytes=[int64]$summary.dedupAliasBytes}else{foreach($alias in $aliases){$aliasBytes+=[int64]$alias.bytes}}; $lines+='File dedup: ON - duplicate files are omitted from data blocks and restored from STAR manifest aliases.'; $lines+=('Dedup mode: {0}' -f $mode); $lines+=('STAR manifest aliases: {0}, alias bytes={1}' -f $aliasCount,(Format-Bytes $aliasBytes)); if($null -ne $summary -and $null -ne $summary.storedUniqueBytes){$lines+=('Stored unique source: {0}' -f (Format-Bytes ([int64]$summary.storedUniqueBytes)))} elseif($null -ne $Manifest.storedUniqueBytes){$lines+=('Stored unique source: {0}' -f (Format-Bytes ([int64]$Manifest.storedUniqueBytes)))}; if($null -ne $dedup -and [int]$dedup.errors -gt 0){$lines+=('Dedup errors: {0}' -f ([int]$dedup.errors))}; return ($lines -join "`r`n") } catch { return '' }
}

function Format-PlanDiagnostics {
    param($Manifest)
    try { $summary=$Manifest.summary; $plan=$Manifest.planDiagnostics; if($null -eq $plan -and $null -ne $Manifest.diagnostics){$plan=$Manifest.diagnostics.plan}; $build=$Manifest.build; $lines=@('', 'Build summary:'); $workMode=[string]$build.workrootMode; if(Test-Blank $workMode -and $null -ne $plan){$workMode=[string]$plan.buildWorkMode}; if(Test-Blank $workMode){$workMode=[string]$Manifest.buildWorkMode}; if(-not(Test-Blank $workMode)){$lines+=('Build workroot mode: {0}' -f $workMode)}; $pipeline=[string]$build.pipeline; if(Test-Blank $pipeline -and $null -ne $plan){$pipeline=[string]$plan.buildPipeline}; if(Test-Blank $pipeline){$pipeline=[string]$Manifest.buildPipeline}; if(-not(Test-Blank $pipeline)){$lines+=('Build pipeline: {0}' -f $pipeline)}; $cleanup=[string]$build.blockCleanup; if(Test-Blank $cleanup -and $null -ne $plan){$cleanup=[string]$plan.blockCleanup}; if(Test-Blank $cleanup){$cleanup=[string]$Manifest.blockCleanup}; if(-not(Test-Blank $cleanup)){$lines+=('Block cleanup: {0}' -f $cleanup)}; $manifestPos=[string]$build.manifestPosition; if(Test-Blank $manifestPos -and $null -ne $plan){$manifestPos=[string]$plan.manifestPosition}; if(Test-Blank $manifestPos){$manifestPos=[string]$Manifest.manifestPosition}; if(-not(Test-Blank $manifestPos)){$lines+=('Manifest position: {0}' -f $manifestPos)}; $catalogFiles=if($null -ne $summary -and $null -ne $summary.catalogFiles){[int]$summary.catalogFiles}elseif($null -ne $plan){[int]$plan.catalogFiles}else{0}; $uniqueFiles=if($null -ne $summary -and $null -ne $summary.uniqueFiles){[int]$summary.uniqueFiles}elseif($null -ne $plan){[int]$plan.uniqueFiles}else{0}; $aliasFiles=if($null -ne $summary -and $null -ne $summary.aliasFiles){[int]$summary.aliasFiles}elseif($null -ne $summary -and $null -ne $summary.dedupAliasCount){[int]$summary.dedupAliasCount}elseif($null -ne $plan){[int]$plan.aliasFiles}else{@($Manifest.dedupAliases).Count}; $aliasBytes=if($null -ne $summary -and $null -ne $summary.dedupAliasBytes){[int64]$summary.dedupAliasBytes}elseif($null -ne $plan){[int64]$plan.aliasBytes}else{[int64]0}; $storedUnique=if($null -ne $summary -and $null -ne $summary.storedUniqueBytes){[int64]$summary.storedUniqueBytes}elseif($null -ne $Manifest.storedUniqueBytes){[int64]$Manifest.storedUniqueBytes}else{[int64]0}; if($catalogFiles -gt 0){$lines+=('Catalog files: {0}' -f $catalogFiles)}; if($uniqueFiles -gt 0 -or $storedUnique -gt 0){$lines+=('Unique files stored: {0}, source={1}' -f $uniqueFiles,(Format-Bytes $storedUnique))}; if($aliasFiles -gt 0 -or $aliasBytes -gt 0){$lines+=('Alias files restored from manifest: {0}, alias bytes={1}' -f $aliasFiles,(Format-Bytes $aliasBytes))}; return ($lines -join "`r`n") } catch { return '' }
}

function Format-AdaptiveDiagnostics {
    param($Manifest)
    try { $pref=[string]$Manifest.compressionPreference; if(Test-Blank $pref){$pref='Balanced'}; $profile=[string]$Manifest.compressionProfile; if(Test-Blank $profile){$profile=Get-CompressionProfileDisplayName ([string]$Manifest.compressionMode) $pref}; $diag=$Manifest.adaptiveDiagnostics; if($null -eq $diag -and $null -ne $Manifest.diagnostics){$diag=$Manifest.diagnostics.adaptive}; $lines=@('', 'Archive summary:'); if(-not(Test-Blank $profile)){$lines+=('Compression profile: {0}' -f $profile)}; if($null -ne $diag -and [bool]$diag.enabled){$scope=[string]$diag.analysisScope; if(Test-Blank $scope){$scope=[string]$Manifest.analysisScope}; if(-not(Test-Blank $scope)){$lines+=('Content analysis: ON - {0}' -f $scope)}; if([int]$diag.unknownSeen -gt 0){$lines+=('Files analyzed: {0}, source={1}' -f ([int]$diag.unknownSeen),(Format-Bytes ([int64]$diag.unknownBytes)))}; if([int]$diag.movedToText -gt 0){$lines+=('Detected text-like: {0} files, source={1}' -f ([int]$diag.movedToText),(Format-Bytes ([int64]$diag.movedToTextBytes)))}; if([int]$diag.movedToBinary -gt 0){$lines+=('Detected binary-like: {0} files, source={1}' -f ([int]$diag.movedToBinary),(Format-Bytes ([int64]$diag.movedToBinaryBytes)))}; if([int]$diag.movedToArchives -gt 0){$lines+=('Detected store-like: {0} files, source={1}' -f ([int]$diag.movedToArchives),(Format-Bytes ([int64]$diag.movedToArchivesBytes)))}}; $dedupText=Format-FileDedupDiagnostics $Manifest; if(-not(Test-Blank $dedupText)){$lines+=$dedupText}; $planText=Format-PlanDiagnostics $Manifest; if(-not(Test-Blank $planText)){$lines+=$planText}; return ($lines -join "`r`n") } catch { return '' }
}

function Get-SmartArchivePlannedExtractionTarget {
    param([string]$TarPath,[string]$ArchivePath,[string]$DestinationParent)
    $work=New-SafeWorkRoot 'precheck' $ArchivePath
    $outer=Join-Path $work 'outer';[System.IO.Directory]::CreateDirectory($outer)|Out-Null
    try{
        $safeArchive=Prepare-SafeArchiveInput $ArchivePath $work
        # Only the manifest is required for target planning.
        Invoke-Tar $TarPath @('-xf',$safeArchive,'-C',$outer,'manifest.json') 'Outer pre-check manifest extraction failed.'
        $manifest=Read-OuterManifest $outer
        $rootName=Get-ArchiveRootName $manifest $ArchivePath
        if(Test-Blank $rootName){$rootName=Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath}
        $sourceType=[string]$manifest.sourceType
        $targets=New-Object System.Collections.ArrayList
        $isAdditive=([int]$manifest.formatVersion -ge 2 -and [string]$manifest.layout -eq 'multi-root-additive')
        if($isAdditive){
            $primary=Join-Path $DestinationParent $rootName
            [void]$targets.Add([pscustomobject]@{Kind='Primary';Path=$primary})
            $hasAdd=(@($manifest.addHistory).Count -gt 0)
            if(-not $hasAdd){foreach($root in @(Get-StarContentRoots $manifest)){if(([string]$root.name) -ieq 'ADD'){$hasAdd=$true;break}}}
            if($hasAdd){[void]$targets.Add([pscustomobject]@{Kind='ADD';Path=(Join-Path $DestinationParent ($rootName+'_ADD'))})}
            # Early preview roots were extracted beside the primary folder.
            foreach($root in @(Get-StarContentRoots $manifest)){
                $name=(Convert-ToTarPath ([string]$root.name)).Trim('/').Trim()
                if(Test-Blank $name -or $name -ieq $rootName -or $name -ieq 'ADD'){continue}
                [void]$targets.Add([pscustomobject]@{Kind='Legacy ADD root';Path=(Join-Path $DestinationParent (Split-Path -Leaf (Convert-ToLocalPath $name)))})
            }
        }
        elseif(($sourceType -eq 'Folder' -or $sourceType -eq 'File') -and -not(Test-Blank $rootName) -and $rootName -ne '.'){
            [void]$targets.Add([pscustomobject]@{Kind=$sourceType;Path=(Join-Path $DestinationParent $rootName)})
        }
        else{
            [void]$targets.Add([pscustomobject]@{Kind=$sourceType;Path=$DestinationParent})
        }
        return [pscustomobject]@{Manifest=$manifest;SourceType=$sourceType;SourceName=$rootName;DestinationParent=$DestinationParent;Targets=@($targets)}
    }finally{Remove-SmartTarWorkAndRoot $work}
}

function Confirm-ExtractionOverwriteIfNeeded {
    param([string]$TarPath,[string]$ArchivePath,[string]$DestinationParent)
    $planned=Get-SmartArchivePlannedExtractionTarget $TarPath $ArchivePath $DestinationParent
    $existing=New-Object System.Collections.ArrayList
    foreach($target in @($planned.Targets)){
        $path=[string]$target.Path
        # The selected parent directory itself and the internal raw ADD name are
        # not output targets. Only mapped output items can be merged/overwritten.
        if(-not(Test-Blank $path) -and (Test-Path -LiteralPath $path)){[void]$existing.Add($target)}
    }
    if($existing.Count -lt 1){return $true}
    $archiveFile=[System.IO.Path]::GetFileName($ArchivePath)
    $targetLines=@($existing|ForEach-Object{'- '+[string]$_.Path}) -join "`r`n"
    $message=@"
One or more extraction targets already exist:
$targetLines

Only these target folders/files may be merged or overwritten.
The selected parent folder itself will not be deleted.

Archive file name:
$archiveFile

Stored source name:
$($planned.SourceName)

Continue?
"@
    $confirm=Show-Message $message 'Merge / overwrite existing extraction target?' ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo)
    return ($confirm -eq [System.Windows.Forms.DialogResult]::Yes)
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
    param($Manifest,[string]$PayloadRoot,[string]$DestinationParent,[string]$ArchivePath)
    $rootName=Get-ArchiveRootName $Manifest $ArchivePath
    $sourceType=[string]$Manifest.sourceType
    $isAdditive=([int]$Manifest.formatVersion -ge 2 -and [string]$Manifest.layout -eq 'multi-root-additive')
    if($isAdditive){
        if(Test-Blank $rootName){$rootName=Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath}
        # ADD is an internal payload root. It must be mapped to <primary>_add,
        # never published as a raw sibling. Preserve any user-owned ADD folder
        # that already existed before extraction.
        $rawAddTarget=Join-Path $DestinationParent 'ADD'
        $rawAddExistedBefore=Test-Path -LiteralPath $rawAddTarget
        $primarySource=Join-Path $PayloadRoot (Convert-ToLocalPath $rootName)
        $primaryTarget=Join-Path $DestinationParent $rootName
        if(Test-Path -LiteralPath $primarySource){[System.IO.Directory]::CreateDirectory($primaryTarget)|Out-Null;Copy-DirectoryContents $primarySource $primaryTarget}
        $addSource=Join-Path $PayloadRoot 'ADD'
        if(Test-Path -LiteralPath $addSource){
            $addTarget=Join-Path $DestinationParent ($rootName+'_ADD')
            [System.IO.Directory]::CreateDirectory($addTarget)|Out-Null
            Copy-DirectoryContents $addSource $addTarget
        }
        # Compatibility for early 1.4 previews that used separate Added roots.
        foreach($root in @(Get-StarContentRoots $Manifest)){
            $name=(Convert-ToTarPath ([string]$root.name)).Trim('/').Trim()
            if(Test-Blank $name -or $name -ieq $rootName -or $name -ieq 'ADD'){continue}
            $legacySource=Join-Path $PayloadRoot (Convert-ToLocalPath $name)
            if(Test-Path -LiteralPath $legacySource){
                $legacyTarget=Join-Path $DestinationParent $name
                [System.IO.Directory]::CreateDirectory($legacyTarget)|Out-Null
                Copy-DirectoryContents $legacySource $legacyTarget
            }
        }
        if(-not $rawAddExistedBefore -and (Test-Path -LiteralPath $rawAddTarget -PathType Container)){
            # Defensive cleanup for any lower-level extraction path that leaked
            # the internal ADD root into the selected parent directory.
            Remove-Item -LiteralPath $rawAddTarget -Recurse -Force -ErrorAction Stop
        }
        if(-not(Test-Path -LiteralPath $primaryTarget) -and -not(Test-Path -LiteralPath (Join-Path $DestinationParent ($rootName+'_ADD')))){
            throw 'Multi-root extraction did not create either the primary or ADD destination.'
        }
        return
    }
    if($sourceType -eq 'Folder' -and -not(Test-Blank $rootName)){
        $finalRoot=Join-Path $DestinationParent $rootName
        [System.IO.Directory]::CreateDirectory($finalRoot)|Out-Null
        $rootInPayload=Join-Path $PayloadRoot $rootName
        if(Test-Path -LiteralPath $rootInPayload){Copy-DirectoryContents $rootInPayload $finalRoot}else{Copy-DirectoryContents $PayloadRoot $finalRoot}
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

function Invoke-SmartTarStreamWholeBlock {
 param([string]$TarPath,[string]$ArchivePath,$Block,[string]$DestinationFolder)
 if($null-eq$Block){throw 'STAR block metadata is missing.'};$rb=(Convert-ToTarPath ([string]$Block.path)).Trim('/').Trim()
 if(Test-Blank $rb-or-not(Test-RelativePathSafe $rb)){throw "Unsafe or empty STAR block path: $rb"};[System.IO.Directory]::CreateDirectory($DestinationFolder)|Out-Null
 $x=[SmartTarStreamBridge]::Extract($TarPath,$ArchivePath,$rb,$DestinationFolder,'',$false)
 if([int]$x.ProducerExitCode-ne 0){throw "Outer STAR streamed block read failed: $rb`r`n$($x.ProducerError)"};if([int]$x.ConsumerExitCode-ne 0){throw "Streamed block extraction failed: $rb`r`n$($x.ConsumerError)"}
 if(-not(Test-Blank ([string]$Block.sha256))-and[string]$x.Sha256-ne([string]$Block.sha256).ToLowerInvariant()){throw "Block SHA256 mismatch during streamed extraction: $rb"}
 if($null-ne$Block.sizeBytes-and[int64]$Block.sizeBytes-gt 0-and[int64]$x.StreamedBytes-ne[int64]$Block.sizeBytes){throw "Streamed block size mismatch: $rb. Expected $($Block.sizeBytes), actual $($x.StreamedBytes)."};return $x
}
function Extract-BlocksStreamed {
 param([string]$TarPath,[string]$ArchivePath,$Blocks,[string]$DestinationFolder,[bool]$SalvageMode=$false);$script:lastSalvageSkippedBlocks=@()
 foreach($b in @($Blocks)){$label="$($b.id) $($b.group) $($b.path)";try{Set-BusyStatus "Streaming block $($b.id) $($b.group)...";[void](Invoke-SmartTarStreamWholeBlock $TarPath $ArchivePath $b $DestinationFolder)}catch{if($SalvageMode){$script:lastSalvageSkippedBlocks+="SKIPPED: $label`r`nReason: $([string]$_.Exception.Message)";continue};throw}}
 return @($script:lastSalvageSkippedBlocks)
}

function Get-SafePayloadPath {
    param([string]$PayloadRoot, [string]$RelativePath)

    $rel = Convert-ToTarPath $RelativePath
    if (-not (Test-RelativePathSafe $rel)) { throw "Unsafe payload path: $rel" }
    return (Join-Path $PayloadRoot (Convert-ToLocalPath $rel))
}

function Restore-DedupAliases {
    param($Manifest, [string]$PayloadRoot, [bool]$SalvageMode = $false)

    $aliases = @($Manifest.dedupAliases)
    $result = [ordered]@{
        mode = [string]$Manifest.dedupAliasMode
        total = $aliases.Count
        restored = 0
        alreadyPresent = 0
        skipped = 0
        errors = 0
    }

    if ($aliases.Count -lt 1) { return [pscustomobject]$result }

    foreach ($alias in $aliases) {
        $aliasPath = Convert-ToTarPath ([string]$alias.path)
        $targetPath = Convert-ToTarPath ([string]$alias.target)
        $label = "DEDUP ALIAS: $aliasPath -> $targetPath"

        try {
            if (Test-Blank $aliasPath -or Test-Blank $targetPath) { throw 'Empty alias path or target.' }
            $sourceFile = Get-SafePayloadPath $PayloadRoot $targetPath
            $destinationFile = Get-SafePayloadPath $PayloadRoot $aliasPath

            if (-not (Test-Path -LiteralPath $sourceFile)) { throw "Dedup alias target is missing: $targetPath" }

            if (Test-Path -LiteralPath $destinationFile) {
                $result.alreadyPresent = [int]$result.alreadyPresent + 1
                continue
            }

            $destinationDir = Split-Path -Parent $destinationFile
            if (-not (Test-Blank $destinationDir)) { [System.IO.Directory]::CreateDirectory($destinationDir) | Out-Null }
            Copy-Item -LiteralPath $sourceFile -Destination $destinationFile -Force -ErrorAction Stop
            $result.restored = [int]$result.restored + 1
        }
        catch {
            $result.errors = [int]$result.errors + 1
            if ($SalvageMode) {
                $result.skipped = [int]$result.skipped + 1
                $script:lastSalvageSkippedBlocks += "SKIPPED: $label`r`nReason: $([string]$_.Exception.Message)"
                continue
            }
            throw
        }
    }

    return [pscustomobject]$result
}

function Test-DedupAliasesForManifest {
    param($Manifest, [string]$PayloadRoot = '')

    $aliases = @($Manifest.dedupAliases)
    $result = [ordered]@{
        total = $aliases.Count
        ok = 0
        failed = 0
        details = @()
    }

    if ($aliases.Count -lt 1) { return [pscustomobject]$result }

    foreach ($alias in $aliases) {
        $aliasPath = Convert-ToTarPath ([string]$alias.path)
        $targetPath = Convert-ToTarPath ([string]$alias.target)

        try {
            if (Test-Blank $aliasPath -or -not (Test-RelativePathSafe $aliasPath)) { throw "Unsafe dedup alias path: $aliasPath" }
            if (Test-Blank $targetPath -or -not (Test-RelativePathSafe $targetPath)) { throw "Unsafe dedup alias target: $targetPath" }

            if (-not (Test-Blank $PayloadRoot)) {
                $targetFile = Get-SafePayloadPath $PayloadRoot $targetPath
                if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) { throw "Dedup alias target not stored in blocks: $targetPath" }
                if ($null -ne $alias.bytes -and -not (Test-Blank ([string]$alias.bytes))) {
                    $expectedBytes = [int64]$alias.bytes
                    $actualBytes = [int64](Get-Item -LiteralPath $targetFile -Force).Length
                    if ($actualBytes -ne $expectedBytes) {
                        throw "Dedup alias target size mismatch: $aliasPath -> $targetPath. Expected $expectedBytes bytes, actual $actualBytes bytes."
                    }
                }
            }

            $result.ok = [int]$result.ok + 1
        }
        catch {
            $result.failed = [int]$result.failed + 1
            $result.details += ([string]$_.Exception.Message)
        }
    }

    return [pscustomobject]$result
}

function Extract-SmartArchive {
    param([string]$TarPath, [string]$ArchivePath, [string]$DestinationFolder, [bool]$SalvageMode = $false)

    if (-not (Test-Path -LiteralPath $TarPath)) { throw 'tar.exe was not found.' }
    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw 'Archive path does not exist.' }
    if (Test-Blank $DestinationFolder) { throw 'Destination folder is empty.' }

    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        [System.IO.Directory]::CreateDirectory($DestinationFolder) | Out-Null
    }

    $r=@('')*32; $r[0]='Extract'; $r[1]='Archive extracted successfully.'; $r[20]=[string]$ArchivePath; $r[21]=[string]$DestinationFolder; $r[22]=if($SalvageMode){'ON'}else{'OFF'}
    $work = New-SafeWorkRoot 'extract' $ArchivePath
    $outer = Join-Path $work 'outer'
    $payload = Join-Path $work 'payload'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null
    [System.IO.Directory]::CreateDirectory($payload) | Out-Null

    try {
        Invoke-Tar $TarPath @('-xf',$ArchivePath,'-C',$outer,'manifest.json') 'Outer manifest extraction failed.'
        $manifest = Read-OuterManifest $outer
        $r[10]=[string]$manifest.format; $r[11]=[string]$manifest.toolVersion; $r[12]=[string]$manifest.compressionProfile; $r[13]=[string]$manifest.compressionMode; $r[14]=[string]@($manifest.blocks).Count
        $r[25]=Format-GroupDiagnostics $manifest; $r[26]=Format-CompressionMethodSummary $manifest; $r[27]=Format-AdaptiveDiagnostics $manifest
        [void](Extract-BlocksStreamed $TarPath $ArchivePath @($manifest.blocks) $payload $SalvageMode)
        $aliasRestore = Restore-DedupAliases $manifest $payload $SalvageMode
        Copy-PayloadToFinalDestination $manifest $payload $DestinationFolder $ArchivePath
        $skipped = @($script:lastSalvageSkippedBlocks)
        if (@($manifest.dedupAliases).Count -gt 0) {
            $r[28] += "`r`n`r`nDedup alias restore:`r`nAliases: $($aliasRestore.total), already present: $($aliasRestore.alreadyPresent), restored: $($aliasRestore.restored), errors: $($aliasRestore.errors)"
        }
        if ($SalvageMode -and $skipped.Count -gt 0) { $r[28]+="`r`n`r`nWARNING: Some blocks or dedup aliases were skipped.`r`nSkipped items: $($skipped.Count)`r`n`r`n$($skipped -join "`r`n`r`n")" }
        elseif ($SalvageMode) { $r[28]+="`r`n`r`nNo broken blocks or dedup aliases were detected. Nothing was skipped." }
        return $r
    }
    finally {
        Remove-SmartTarWorkAndRoot $work
    }
}

function Verify-SmartArchive {
 param([string]$TarPath,[string]$ArchivePath);if(-not(Test-Path -LiteralPath $ArchivePath)){throw 'Archive path does not exist.'};$r=@('')*32;$r[0]='Verify';$r[1]='Archive verification completed.';$r[20]=[string]$ArchivePath
 $w=New-SafeWorkRoot 'verify' $ArchivePath;$o=Join-Path $w 'outer';$p=Join-Path $w 'payload';[System.IO.Directory]::CreateDirectory($o)|Out-Null;[System.IO.Directory]::CreateDirectory($p)|Out-Null
 try{Invoke-Tar $TarPath @('-xf',$ArchivePath,'-C',$o,'manifest.json') 'Outer verification manifest extraction failed.';$m=Read-OuterManifest $o;$bs=@($m.blocks);$ok=0;$fail=0;$lines=@()
 foreach($b in $bs){Set-BusyStatus "Verifying streamed block $($b.id) $($b.group)...";try{[void](Invoke-SmartTarStreamWholeBlock $TarPath $ArchivePath $b $p);$ok++}catch{$fail++;$lines+="FAIL: $($b.id) $($b.group) $($b.path)`r`n$([string]$_.Exception.Message)"}}
 $ac=Test-DedupAliasesForManifest $m $p;if([int]$ac.failed-gt 0){$fail+=[int]$ac.failed;foreach($d in @($ac.details)){$lines+="DEDUP ALIAS FAIL: $d"}};$ver=if($fail-eq 0){'OK'}else{'FAILED'}
 $r[10]=[string]$m.format;$r[11]=[string]$m.toolVersion;$r[12]=[string]$m.compressionProfile;$r[13]=[string]$m.compressionMode;$r[14]=[string]$bs.Count;$r[15]=[string]$ok;$r[16]=[string]$fail;$r[17]=$ver;$r[25]=Format-GroupDiagnostics $m;$r[26]=Format-CompressionMethodSummary $m;$r[27]=Format-AdaptiveDiagnostics $m
 if(@($m.dedupAliases).Count-gt 0){$r[28]+="`r`n`r`nDedup alias verification:`r`nAliases: $($ac.total), OK: $($ac.ok), failed: $($ac.failed)"};if($fail-gt 0-and$lines.Count-gt 0){$r[28]+="`r`n`r`nFailed verification details:`r`n"+($lines-join"`r`n")};return $r}finally{Remove-SmartTarWorkAndRoot $w}
}


function Add-SmartArchiveBrowseEntry {
    param(
        [hashtable]$Entries,
        [string]$RelativePath,
        [bool]$IsFolder,
        [string]$BlockPath = '',
        [string]$AliasTarget = ''
    )

    $rel = (Convert-ToTarPath ([string]$RelativePath)).Trim()
    if (Test-Blank $rel) { return }
    $rel = $rel.TrimStart([char]46, [char]47)
    $rel = $rel.TrimEnd([char]47)
    if (Test-Blank $rel) { return }
    if (-not (Test-RelativePathSafe $rel)) { return }

    $parts = @($rel.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $current = ''
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $current = if (Test-Blank $current) { [string]$parts[$i] } else { $current + '/' + [string]$parts[$i] }
        $isCurrentFolder = if ($i -lt ($parts.Count - 1)) { $true } else { [bool]$IsFolder }
        $key = $current.ToLowerInvariant()
        if (-not $Entries.ContainsKey($key)) {
            $Entries[$key] = [pscustomobject]@{
                Rel         = $current
                IsFolder    = [bool]$isCurrentFolder
                Blocks      = New-Object System.Collections.ArrayList
                AliasTarget = ''
            }
        }
        elseif ($isCurrentFolder) {
            $Entries[$key].IsFolder = $true
        }

        if (-not (Test-Blank $BlockPath) -and -not $Entries[$key].Blocks.Contains($BlockPath)) {
            [void]$Entries[$key].Blocks.Add($BlockPath)
        }
        if ($i -eq ($parts.Count - 1) -and -not (Test-Blank $AliasTarget)) {
            $Entries[$key].AliasTarget = Convert-ToTarPath $AliasTarget
        }
    }
}

function Get-SmartArchiveBrowseEntries {
    param([string]$TarPath, [string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $TarPath)) { throw 'tar.exe was not found.' }
    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw 'Archive path does not exist.' }

    $work = New-SafeWorkRoot 'browse' $ArchivePath
    $outer = Join-Path $work 'outer'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null

    try {
        $safeArchive = Prepare-SafeArchiveInput $ArchivePath $work
        Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer, 'manifest.json') 'Outer manifest extraction failed.'
        $manifest = Read-OuterManifest $outer
        $entries = @{}

        foreach ($block in @($manifest.blocks)) {
            $relativeBlock = [string]$block.path
            if (Test-Blank $relativeBlock) { continue }
            Set-BusyStatus "Browsing block $($block.id) $($block.group)..."
            Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer, $relativeBlock) "Outer block extraction for browse failed: $relativeBlock."
            $blockPath = Resolve-SafeBlockPath $outer $relativeBlock
            if (-not (Test-Path -LiteralPath $blockPath)) { throw "Block missing during browse: $relativeBlock" }

            if ($block.sha256) {
                $actualHash = Get-FileSHA256 $blockPath
                if ($actualHash -ne ([string]$block.sha256).ToLowerInvariant()) { throw "Block SHA256 mismatch during browse: $relativeBlock" }
            }

            Test-ArchiveEntriesSafe $TarPath $blockPath
            $listResult = Invoke-TarRaw $TarPath @('-tf', $blockPath)
            if ([int]$listResult.ExitCode -ne 0) { throw "Cannot list block during browse: $relativeBlock`r`n$($listResult.Output)" }

            foreach ($entry in @(([string]$listResult.Output) -split "`r?`n")) {
                if (Test-Blank $entry) { continue }
                $raw = Convert-ToTarPath ([string]$entry)
                $clean = $raw.Trim().TrimStart([char]46, [char]47)
                if (Test-Blank $clean) { continue }
                $isFolder = $raw.EndsWith('/')
                Add-SmartArchiveBrowseEntry $entries $clean $isFolder $relativeBlock
            }

            Remove-Item -LiteralPath $blockPath -Force -ErrorAction SilentlyContinue
            $blockDir = Split-Path -Parent $blockPath
            try {
                if (-not (Test-Blank $blockDir)) {
                    $remaining = @(Get-ChildItem -LiteralPath $blockDir -Force -ErrorAction SilentlyContinue)
                    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $blockDir -Force -ErrorAction SilentlyContinue }
                }
            }
            catch {}
        }

        foreach ($alias in @($manifest.dedupAliases)) {
            $targetKey = (Convert-ToTarPath ([string]$alias.target)).Trim('/').ToLowerInvariant()
            $targetBlocks = @()
            if ($entries.ContainsKey($targetKey)) { $targetBlocks = @($entries[$targetKey].Blocks) }
            if ($targetBlocks.Count -gt 0) {
                foreach ($targetBlock in $targetBlocks) {
                    Add-SmartArchiveBrowseEntry $entries ([string]$alias.path) $false ([string]$targetBlock) ([string]$alias.target)
                }
            }
            else {
                Add-SmartArchiveBrowseEntry $entries ([string]$alias.path) $false '' ([string]$alias.target)
            }
        }

        $items = @($entries.Values | Sort-Object @{ Expression = { if ($_.IsFolder) { 0 } else { 1 } } }, @{ Expression = { [string]$_.Rel } })
        return [pscustomobject]@{ Work = $work; Manifest = $manifest; Entries = $items; EntryMap = $entries }
    }
    catch {
        Remove-SmartTarWorkAndRoot $work
        throw
    }
}

function Add-SmartArchiveTreeNode {
    param([System.Windows.Forms.TreeView]$Tree,[hashtable]$NodeMap,[string]$RelativePath,[bool]$IsFolder,[string]$ArchiveRoot='')
    $rel=(Convert-ToTarPath $RelativePath).Trim('/').Trim();if(Test-Blank $rel){return}
    $root=(Convert-ToTarPath $ArchiveRoot).Trim('/').Trim();$parts=@($rel.Split('/')|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    $current='';$parents=$Tree.Nodes
    if(-not(Test-Blank $root)){
        $rk=$root.ToLowerInvariant();if(-not $NodeMap.ContainsKey($rk)){return};$parents=$NodeMap[$rk].Nodes
    }
    for($i=0;$i -lt $parts.Count;$i++){
        $part=[string]$parts[$i];$current=if(Test-Blank $current){$part}else{$current+'/'+$part}
        $archivePath=if(Test-Blank $root){$current}else{$root+'/'+$current};$key=$archivePath.ToLowerInvariant()
        $folder=if($i -lt $parts.Count-1){$true}else{[bool]$IsFolder}
        if(-not $NodeMap.ContainsKey($key)){$node=[System.Windows.Forms.TreeNode]::new($part);$node.Tag=[pscustomobject]@{Rel=$archivePath;IsFolder=$folder};$node.ImageIndex=if($folder){0}else{1};$node.SelectedImageIndex=$node.ImageIndex;[void]$parents.Add($node);$NodeMap[$key]=$node}else{$node=$NodeMap[$key];if($folder){$node.Tag.IsFolder=$true}}
        $parents=$node.Nodes
    }
}

function Extract-SmartArchiveSelectionLegacy {
    param([string]$TarPath, [string]$ArchivePath, [string]$RelativePath, [bool]$IsFolder, [string]$DestinationParent)

    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw 'Archive path does not exist.' }
    if (Test-Blank $DestinationParent) { throw 'Destination folder is empty.' }
    [System.IO.Directory]::CreateDirectory($DestinationParent) | Out-Null

    $work = New-SafeWorkRoot 'browse_extract' $ArchivePath
    $outer = Join-Path $work 'outer'
    $payload = Join-Path $work 'payload'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null
    [System.IO.Directory]::CreateDirectory($payload) | Out-Null

    try {
        $safeArchive = Prepare-SafeArchiveInput $ArchivePath $work
        Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer, 'manifest.json') 'Outer manifest extraction failed.'
        $manifest = Read-OuterManifest $outer

        foreach ($block in @($manifest.blocks)) {
            $relativeBlock = [string]$block.path
            if (Test-Blank $relativeBlock) { continue }
            Set-BusyStatus "Preparing browse extraction block $($block.id) $($block.group)..."
            Invoke-Tar $TarPath @('-xf', $safeArchive, '-C', $outer, $relativeBlock) "Outer block extraction failed: $relativeBlock."
            $blockPath = Resolve-SafeBlockPath $outer $relativeBlock
            if (-not (Test-Path -LiteralPath $blockPath)) { throw "Block missing: $relativeBlock" }
            if ($block.sha256) {
                $actualHash = Get-FileSHA256 $blockPath
                if ($actualHash -ne ([string]$block.sha256).ToLowerInvariant()) { throw "Block SHA256 mismatch: $relativeBlock" }
            }
            Test-ArchiveEntriesSafe $TarPath $blockPath
            Invoke-Tar $TarPath @('-xf', $blockPath, '-C', $payload) "Block extraction failed: $relativeBlock."
            Remove-Item -LiteralPath $blockPath -Force -ErrorAction SilentlyContinue
        }

        [void](Restore-DedupAliases $manifest $payload $false)

        $rel = (Convert-ToTarPath ([string]$RelativePath)).Trim('/').Trim()
        if (Test-Blank $rel) {
            Copy-DirectoryContents $payload $DestinationParent
            return $DestinationParent
        }

        $sourceItem = Get-SafePayloadPath $payload $rel
        if (-not (Test-Path -LiteralPath $sourceItem)) { throw "Selected item was not restored from archive: $rel" }

        $leaf = Split-Path -Leaf (Convert-ToLocalPath $rel)
        if (Test-Blank $leaf) { $leaf = 'selection' }
        $targetPath = Join-Path $DestinationParent $leaf

        if ($IsFolder) {
            [System.IO.Directory]::CreateDirectory($targetPath) | Out-Null
            Copy-DirectoryContents $sourceItem $targetPath
        }
        else {
            [System.IO.Directory]::CreateDirectory($DestinationParent) | Out-Null
            Copy-Item -LiteralPath $sourceItem -Destination $targetPath -Force -ErrorAction Stop
        }

        return $targetPath
    }
    finally {
        Remove-SmartTarWorkAndRoot $work
    }
}


function Invoke-SmartTarStreamSelection {
    param(
        [string]$TarPath,
        [string]$ArchivePath,
        [string]$RelativeBlock,
        [string]$ExpectedSha256,
        [string]$Destination,
        [string]$SelectedPath,
        [bool]$SelectedIsFolder
    )

    if (Test-Blank $RelativeBlock -or -not (Test-RelativePathSafe $RelativeBlock)) {
        throw "Unsafe or empty STAR block path: $RelativeBlock"
    }
    $result = [SmartTarStreamBridge]::Extract(
        $TarPath,
        $ArchivePath,
        (Convert-ToTarPath $RelativeBlock),
        $Destination,
        (Convert-ToTarPath $SelectedPath),
        $SelectedIsFolder
    )
    if ([int]$result.ProducerExitCode -ne 0) {
        throw "Outer STAR streamed block read failed: $RelativeBlock`r`n$($result.ProducerError)"
    }
    if ([int]$result.ConsumerExitCode -ne 0) {
        throw "Selective streamed extraction failed: $RelativeBlock`r`n$($result.ConsumerError)"
    }
    if (-not (Test-Blank $ExpectedSha256)) {
        if ([string]$result.Sha256 -ne ([string]$ExpectedSha256).ToLowerInvariant()) {
            throw "Block SHA256 mismatch during streamed extraction: $RelativeBlock"
        }
    }
    return $result
}

function Restore-SelectedDedupAliases {
    param($Manifest, [string]$PayloadRoot, [string]$RelativePath, [bool]$IsFolder)

    $selection = (Convert-ToTarPath $RelativePath).Trim('/').Trim()
    foreach ($alias in @($Manifest.dedupAliases)) {
        $aliasPath = (Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim()
        $wanted = if ($IsFolder) {
            $aliasPath -eq $selection -or $aliasPath.StartsWith($selection + '/', [System.StringComparison]::OrdinalIgnoreCase)
        }
        else {
            $aliasPath -eq $selection
        }
        if (-not $wanted) { continue }

        $targetPath = (Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim()
        $source = Get-SafePayloadPath $PayloadRoot $targetPath
        $destination = Get-SafePayloadPath $PayloadRoot $aliasPath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Dedup source was not restored for selected alias: $targetPath"
        }
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
    }
}

function Extract-SmartArchiveSelection {
    param([string]$TarPath,[string]$ArchivePath,[string]$RelativePath,[bool]$IsFolder,[string]$DestinationParent,$BrowseData=$null)
    $rel=(Convert-ToTarPath ([string]$RelativePath)).Trim('/').Trim()
    $sourceRoot='';if($null -ne $BrowseData -and $null -ne $BrowseData.Manifest){$sourceRoot=(Convert-ToTarPath ([string]$BrowseData.Manifest.sourceName)).Trim('/').Trim()}
    $multiRoot=($null -ne $BrowseData -and $null -ne $BrowseData.Manifest -and @($BrowseData.Manifest.contentRoots).Count -gt 1)
    if((Test-Blank $rel) -or (-not $multiRoot -and -not(Test-Blank $sourceRoot) -and $rel.Equals($sourceRoot,[System.StringComparison]::OrdinalIgnoreCase))){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent)}
    if($null -eq $BrowseData -or $null -eq $BrowseData.EntryMap){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent)}
    $entryKey=$rel.ToLowerInvariant();if(-not $BrowseData.EntryMap.ContainsKey($entryKey)){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent)}
    if(-not(Test-Path -LiteralPath $ArchivePath)){throw 'Archive path does not exist.'};if(Test-Blank $DestinationParent){throw 'Destination folder is empty.'};[System.IO.Directory]::CreateDirectory($DestinationParent)|Out-Null
    $work=New-SafeWorkRoot 'browse_stream' $ArchivePath;$payload=Join-Path $work 'payload';[System.IO.Directory]::CreateDirectory($payload)|Out-Null
    try{
        $manifest=$BrowseData.Manifest;$blockMap=@{};foreach($block in @($manifest.blocks)){$blockMap[(Convert-ToTarPath ([string]$block.path)).ToLowerInvariant()]=$block}
        $aliasMap=@{};foreach($alias in @($manifest.dedupAliases)){$p=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim();if(-not(Test-Blank $p)){$aliasMap[$p.ToLowerInvariant()]=$alias}}
        if(-not $IsFolder -and $aliasMap.ContainsKey($entryKey)){
            $alias=$aliasMap[$entryKey];$target=(Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim();$targetKey=$target.ToLowerInvariant()
            if(-not $BrowseData.EntryMap.ContainsKey($targetKey)){throw "Dedup target is missing from browse index: $target"}
            foreach($rb in @($BrowseData.EntryMap[$targetKey].Blocks)){$bk=(Convert-ToTarPath ([string]$rb)).ToLowerInvariant();$block=$blockMap[$bk];[void](Invoke-SmartTarStreamSelection $TarPath $ArchivePath ([string]$block.path) ([string]$block.sha256) $payload $target $false)}
            $physical=Get-SafePayloadPath $payload $target;if(-not(Test-Path -LiteralPath $physical -PathType Leaf)){throw "Dedup target was not extracted: $target"}
            $aliasPayload=Get-SafePayloadPath $payload $rel;[System.IO.Directory]::CreateDirectory((Split-Path -Parent $aliasPayload))|Out-Null;Copy-Item -LiteralPath $physical -Destination $aliasPayload -Force -ErrorAction Stop
        }else{
            $needed=@($BrowseData.EntryMap[$entryKey].Blocks);if($needed.Count -lt 1){throw "Selected item has no physical block mapping: $rel"}
            foreach($rb in $needed){$bk=(Convert-ToTarPath ([string]$rb)).ToLowerInvariant();$block=$blockMap[$bk];[void](Invoke-SmartTarStreamSelection $TarPath $ArchivePath ([string]$block.path) ([string]$block.sha256) $payload $rel $IsFolder)}
            if($IsFolder){
                $extra=@{};foreach($alias in @($manifest.dedupAliases)){$ap=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim();if(-not($ap -eq $rel -or $ap.StartsWith($rel+'/',[System.StringComparison]::OrdinalIgnoreCase))){continue};$t=(Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim();$tk=$t.ToLowerInvariant();foreach($tb in @($BrowseData.EntryMap[$tk].Blocks)){$extra[[string]$tb+'|'+$t]=[pscustomobject]@{Block=[string]$tb;Target=$t}}}
                foreach($x in $extra.Values){$bk=(Convert-ToTarPath ([string]$x.Block)).ToLowerInvariant();$block=$blockMap[$bk];[void](Invoke-SmartTarStreamSelection $TarPath $ArchivePath ([string]$block.path) ([string]$block.sha256) $payload ([string]$x.Target) $false)}
                Restore-SelectedDedupAliases $manifest $payload $rel $true
            }
        }
        $sourceItem=Get-SafePayloadPath $payload $rel;if(-not(Test-Path -LiteralPath $sourceItem)){throw "Selected item was not restored from archive: $rel"}
        $leaf=Split-Path -Leaf (Convert-ToLocalPath $rel)
        if($rel -ieq 'ADD'){$leaf=$sourceRoot+'_ADD'}
        if(Test-Blank $leaf){$leaf='selection'}
        $targetPath=Join-Path $DestinationParent $leaf
        if($IsFolder){[System.IO.Directory]::CreateDirectory($targetPath)|Out-Null;Copy-DirectoryContents $sourceItem $targetPath}else{Copy-Item -LiteralPath $sourceItem -Destination $targetPath -Force -ErrorAction Stop}
        if(-not(Test-Path -LiteralPath $targetPath)){throw "Browse extraction did not create output: $targetPath"};return $targetPath
    }catch{
        Set-BusyStatus 'Streamed Browse extraction unavailable. Using compatibility fallback...'
        $fallback=Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent
        if(Test-Blank ([string]$fallback) -or -not(Test-Path -LiteralPath ([string]$fallback))){throw "Browse fallback did not create the selected item: $rel"};return $fallback
    }finally{Remove-SmartTarWorkAndRoot $work}
}

function Show-SmartArchiveBrowseDialog {
    param([string]$TarPath, [string]$ArchivePath)

    if (-not (Test-SmartArchivePath $ArchivePath)) {
        Show-Message "Selected file is not a SmartTAR archive:`r`n$ArchivePath" 'Invalid archive selection' ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $oldCursor = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    $browseData = $null
    try {
        Set-BusyStatus 'Opening archive browser...'
        $browseData = Get-SmartArchiveBrowseEntries $TarPath $ArchivePath
    }
    catch {
        Show-Message (Get-ErrorDetails $_) 'Archive browse failed' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = $oldCursor
        Set-AppStatus 'Ready.' $cTextMuted
    }

    $browseForm = New-Object System.Windows.Forms.Form
    $browseForm.Text = 'Browse STAR archive - ' + [System.IO.Path]::GetFileName($ArchivePath)
    $browseForm.Size = New-Size 780 580
    $browseForm.StartPosition = 'CenterParent'
    $browseForm.MinimizeBox = $false
    $browseForm.MaximizeBox = $true
    $browseForm.BackColor = $cBg

    $lbl = New-EcoLabel ('Archive: ' + $ArchivePath) 12 10 740 20 $fItalic $cTextMuted
    try { $lbl.UseMnemonic = $false; $lbl.AutoEllipsis = $true } catch {}

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Location = New-Point 12 38
    $tree.Size = New-Size 740 440
    $tree.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $tree.HideSelection = $false
    $tree.BackColor = $cInput
    $tree.ForeColor = $cText
    $tree.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tree.LineColor = $cGray

    $declaredRoots=@(Get-StarContentRoots $browseData.Manifest)
    if($declaredRoots.Count -lt 1){$declaredRoots=@([pscustomobject]@{name=(Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath);generation=0})}
    $nodeMap=@{}
    $rootNames=New-Object System.Collections.ArrayList
    $entryPaths=@($browseData.Entries|ForEach-Object{(Convert-ToTarPath ([string]$_.Rel)).Trim('/').Trim()})
    foreach($rootInfo in $declaredRoots){
        $declared=(Convert-ToTarPath ([string]$rootInfo.name)).Trim('/').Trim()
        if(Test-Blank $declared){continue}
        $effective=$declared
        # Some legacy/preview blocks can contain root/root/... . If there are no
        # direct children of root but there are children of root/root, show only
        # the actual inner root and avoid producing two identical top nodes.
        $directPrefix=$declared+'/'
        $doublePrefix=$declared+'/'+$declared+'/'
        $hasDirectNonDouble=$false;$hasDouble=$false
        foreach($p in $entryPaths){
            if($p.StartsWith($doublePrefix,[System.StringComparison]::OrdinalIgnoreCase)){$hasDouble=$true;continue}
            if($p.StartsWith($directPrefix,[System.StringComparison]::OrdinalIgnoreCase)){$hasDirectNonDouble=$true}
        }
        if($hasDouble -and -not $hasDirectNonDouble){$effective=$declared+'/'+$declared}
        if(-not $rootNames.Contains($effective)){[void]$rootNames.Add($effective)}
    }
    # Also admit actual top-level roots not declared by early preview manifests.
    foreach($p in $entryPaths){
        if(Test-Blank $p){continue};$top=($p -split '/')[0]
        $covered=$false
        foreach($root in @($rootNames)){if($p -eq $root -or $p.StartsWith($root+'/',[System.StringComparison]::OrdinalIgnoreCase)){$covered=$true;break}}
        if(-not $covered -and -not $rootNames.Contains($top)){[void]$rootNames.Add($top)}
    }
    foreach($rootPath in @($rootNames)){
        $display=Split-Path -Leaf (Convert-ToLocalPath $rootPath)
        if(Test-Blank $display){$display=$rootPath}
        $rootNode=[System.Windows.Forms.TreeNode]::new($display)
        $rootNode.Tag=[pscustomobject]@{Rel=$rootPath;IsFolder=$true}
        [void]$tree.Nodes.Add($rootNode);$nodeMap[$rootPath.ToLowerInvariant()]=$rootNode
    }
    $tree.BeginUpdate()
    try{
        foreach($entry in @($browseData.Entries)){
            $entryRel=(Convert-ToTarPath ([string]$entry.Rel)).Trim('/').Trim();if(Test-Blank $entryRel){continue}
            $matched=$false
            foreach($rootPath in @($rootNames)){
                if($entryRel.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase)){$matched=$true;break}
                if($entryRel.StartsWith($rootPath+'/',[System.StringComparison]::OrdinalIgnoreCase)){
                    $displayRel=$entryRel.Substring($rootPath.Length+1)
                    Add-SmartArchiveTreeNode $tree $nodeMap $displayRel ([bool]$entry.IsFolder) $rootPath
                    $matched=$true;break
                }
            }
            if(-not $matched){Add-SmartArchiveTreeNode $tree $nodeMap $entryRel ([bool]$entry.IsFolder) ''}
        }
        foreach($node in @($tree.Nodes)){$node.Expand()}
    }finally{$tree.EndUpdate()}

    $btnExtractSelected = New-EcoButton 'Extract selected...' 12 495 160 32 $fBold $cRoyal $cButtonText
    $btnClose = New-EcoButton 'Close' 592 495 160 32 $fBold $cVerify $cButtonText
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnExtractSelected.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $btnClose.Add_Click({ $browseForm.Close() })
    $btnExtractSelected.Add_Click({
        if ($null -eq $tree.SelectedNode -or $null -eq $tree.SelectedNode.Tag) {
            Show-Message 'Select a file or folder first.' 'Browse archive' ([System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $tag = $tree.SelectedNode.Tag
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description = 'Select destination folder for extracted item.'
            if ($dialog.ShowDialog($browseForm) -eq [System.Windows.Forms.DialogResult]::OK) {
                $old = [System.Windows.Forms.Cursor]::Current
                [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
                try {
                    $target = Extract-SmartArchiveSelection $TarPath $ArchivePath ([string]$tag.Rel) ([bool]$tag.IsFolder) $dialog.SelectedPath $browseData
                    if(Test-Blank ([string]$target) -or -not(Test-Path -LiteralPath ([string]$target))){throw 'Browse extraction returned without creating an output item.'}
                    Show-Message "Selected item extracted successfully:`r`n$target" 'Browse archive' | Out-Null
                    if ([bool]$chkOpenFolder.Checked -and -not (Test-Blank $target)) {
                        if (Test-Path -LiteralPath $target -PathType Leaf) { explorer.exe "/select,`"$target`"" }
                        else { explorer.exe "`"$target`"" }
                    }
                }
                catch {
                    Show-Message (Get-ErrorDetails $_) 'Extract selected failed' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
                finally {
                    [System.Windows.Forms.Cursor]::Current = $old
                }
            }
        }
        finally { $dialog.Dispose() }
    })

    $browseForm.Controls.AddRange([System.Windows.Forms.Control[]]@($lbl, $tree, $btnExtractSelected, $btnClose))
    try { [void]$browseForm.ShowDialog($form) }
    finally {
        Remove-SmartTarWorkAndRoot ([string]$browseData.Work)
        $browseForm.Dispose()
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

    $r = Verify-SmartArchive $TarPath $ArchivePath
    $r[0]='Compress'; $r[1]='Archive created successfully.'; $r[2]=Format-Bytes $sourceBytes; $r[3]=Format-Bytes $archiveBytes; $r[4]=$ratio; $r[5]=$saved; $r[20]=''
    return $r
}


# ============================================================================
# 08A. Additive multi-root archive support (STAR formatVersion 2)
# ============================================================================

function Get-StarOuterData {
 param([string]$TarPath,[string]$ArchivePath,[string]$WorkRoot,[bool]$ExtractBlocks=$true);$outer=Join-Path $WorkRoot 'outer';[System.IO.Directory]::CreateDirectory($outer)|Out-Null
 if($ExtractBlocks){$safe=Prepare-SafeArchiveInput $ArchivePath $WorkRoot;Invoke-Tar $TarPath @('-xf',$safe,'-C',$outer) 'Existing STAR extraction failed.'}else{$safe=$ArchivePath;Invoke-Tar $TarPath @('-xf',$ArchivePath,'-C',$outer,'manifest.json') 'Existing STAR manifest extraction failed.'};$manifest=Read-OuterManifest $outer;return [pscustomobject]@{Outer=$outer;SafeArchive=$safe;Manifest=$manifest}
}

function Get-StarContentRoots {
    param($Manifest)
    $roots=New-Object System.Collections.ArrayList;$seen=@{}
    foreach($root in @($Manifest.contentRoots)){
        $name=(Convert-ToTarPath ([string]$root.name)).Trim('/').Trim();if(Test-Blank $name){continue}
        $key=$name.ToLowerInvariant();if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        [void]$roots.Add([pscustomobject]@{name=$name;generation=[int]$root.generation;type=[string]$root.type})
    }
    if($roots.Count -lt 1){
        $name=(Convert-ToTarPath ([string]$Manifest.sourceName)).Trim('/').Trim()
        if(-not(Test-Blank $name)){[void]$roots.Add([pscustomobject]@{name=$name;generation=0;type='primary'})}
    }
    return @($roots)
}

function Get-NextAddRoot {
    param($Manifest,[string]$SourceLeaf)
    $sourceName=Convert-ToSafeArchiveFileNamePart $SourceLeaf
    if(Test-Blank $sourceName){$sourceName='Added content'}
    $max=0;foreach($root in @(Get-StarContentRoots $Manifest)){if([int]$root.generation -gt $max){$max=[int]$root.generation}}
    foreach($item in @($Manifest.addHistory)){if([int]$item.generation -gt $max){$max=[int]$item.generation}}
    $generation=$max+1
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
    $used=@{}
    foreach($item in @($Manifest.addHistory)){
        $batch=(Convert-ToTarPath ([string]$item.batch)).Trim('/').Trim()
        $root=(Convert-ToTarPath ([string]$item.root)).Trim('/').Trim()
        if(-not(Test-Blank $batch)){$used[$batch.ToLowerInvariant()]=$true}
        if(-not(Test-Blank $root)){$used[$root.ToLowerInvariant()]=$true}
    }
    $batch='ADD/ADD_'+$stamp;$suffix=1
    while($used.ContainsKey($batch.ToLowerInvariant())){$batch='ADD/ADD_'+$stamp+'_{0:D3}' -f $suffix;$suffix++}
    $name=$batch+'/'+$sourceName
    return [pscustomobject]@{Name=$name;Batch=$batch;SourceName=$sourceName;Generation=$generation;AddedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')}
}

function Get-MaxStarBlockId {
    param($Manifest)
    $max=0
    foreach($block in @($Manifest.blocks)){
        $n=0
        if([int]::TryParse([string]$block.id,[ref]$n) -and $n -gt $max){$max=$n}
    }
    return $max
}

function New-AddSourceStage {
    param([string]$Source,[string]$StageParent,[string]$RootName)
    $root=Join-Path $StageParent $RootName
    [System.IO.Directory]::CreateDirectory($root)|Out-Null
    $item=Get-Item -LiteralPath $Source -Force
    if($item.PSIsContainer){
        foreach($dir in @(Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue)){
            $rel=Get-RelativePathFromBase $Source $dir.FullName
            [System.IO.Directory]::CreateDirectory((Join-Path $root (Convert-ToLocalPath $rel)))|Out-Null
        }
        foreach($file in @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue)){
            $rel=Get-RelativePathFromBase $Source $file.FullName
            $target=Join-Path $root (Convert-ToLocalPath $rel)
            try{New-HardLinkLiteral $target $file.FullName}catch{[System.IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $target -Force}
        }
    }else{
        $target=Join-Path $root ([System.IO.Path]::GetFileName($Source))
        try{New-HardLinkLiteral $target $Source}catch{Copy-Item -LiteralPath $Source -Destination $target -Force}
    }
    return $root
}

function New-ExistingContentDedupIndex {
    param([string]$PayloadRoot,$Manifest)
    $index=@{}
    $aliasPaths=@{}
    foreach($alias in @($Manifest.dedupAliases)){
        $aliasRel=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim()
        if(-not(Test-Blank $aliasRel)){$aliasPaths[$aliasRel.ToLowerInvariant()]=$true}
    }
    foreach($file in @(Get-ChildItem -LiteralPath $PayloadRoot -File -Recurse -Force -ErrorAction SilentlyContinue)){
        $rel=(Convert-ToTarPath (Get-RelativePathFromBase $PayloadRoot $file.FullName)).Trim('/').Trim()
        # Restored aliases are logical files, not physical block members. Using
        # one as a future dedup target would create alias-to-alias chains, which
        # Verify intentionally rejects because every target must exist in blocks.
        if($aliasPaths.ContainsKey($rel.ToLowerInvariant())){continue}
        if([int64]$file.Length -lt [int64]$script:DedupMinFileBytes -or [int64]$file.Length -le 0){continue}
        $key=[string][int64]$file.Length
        if(-not $index.ContainsKey($key)){$index[$key]=New-Object System.Collections.ArrayList}
        [void]$index[$key].Add([pscustomobject]@{Path=$file.FullName;Rel=$rel;Hash=''})
    }
    return $index
}

function Remove-AddDuplicatesAgainstArchive {
    param([string]$AddStageParent,[string]$AddRoot,[hashtable]$ExistingIndex)
    $aliases=New-Object System.Collections.ArrayList
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $AddStageParent $AddRoot) -File -Recurse -Force -ErrorAction SilentlyContinue)){
        $bytes=[int64]$file.Length
        if($bytes -lt [int64]$script:DedupMinFileBytes -or $bytes -le 0){continue}
        $key=[string]$bytes
        if(-not $ExistingIndex.ContainsKey($key)){continue}
        $hash=Get-FileSHA256 $file.FullName
        foreach($old in @($ExistingIndex[$key])){
            if(Test-Blank ([string]$old.Hash)){$old.Hash=Get-FileSHA256 ([string]$old.Path)}
            if([string]$old.Hash -eq $hash){
                $aliasRel=(Convert-ToTarPath (Get-RelativePathFromBase $AddStageParent $file.FullName)).Trim('/').Trim();$targetRel=(Convert-ToTarPath ([string]$old.Rel)).Trim('/').Trim()
                if(Test-Blank $aliasRel-or$aliasRel-eq'.'-or-not(Test-RelativePathSafe $aliasRel)){throw "ADD dedup produced an unsafe alias path: '$aliasRel'."};if(Test-Blank $targetRel-or$targetRel-eq'.'-or-not(Test-RelativePathSafe $targetRel)){throw "ADD dedup produced an unsafe target path: '$targetRel'."}
                [void]$aliases.Add([pscustomobject]@{path=$aliasRel;target=$targetRel;bytes=$bytes});Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                break
            }
        }
    }
    return @($aliases)
}

function Merge-StarAddManifest {
    param($OldManifest,$AddManifest,$CrossAliases,$AddInfo,$NewBlocks)
    $allBlocks=@($OldManifest.blocks)+@($NewBlocks)
    $rawAliases=@($OldManifest.dedupAliases)+@($AddManifest.dedupAliases)+@($CrossAliases);$normalizedAliases=New-Object System.Collections.ArrayList
    foreach($a in $rawAliases){if($null-eq$a){continue};$ap=(Convert-ToTarPath ([string]$a.path)).Trim('/').Trim();$tp=(Convert-ToTarPath ([string]$a.target)).Trim('/').Trim();if(Test-Blank $ap-or$ap-eq'.'-or-not(Test-RelativePathSafe $ap)){throw "Invalid ADD alias path before manifest merge: '$ap'."};if(Test-Blank $tp-or$tp-eq'.'-or-not(Test-RelativePathSafe $tp)){throw "Invalid ADD alias target before manifest merge: '$ap' -> '$tp'."};$ab=if($null-ne$a.bytes-and-not(Test-Blank ([string]$a.bytes))){[int64]$a.bytes}else{[int64]0};[void]$normalizedAliases.Add([pscustomobject]@{path=$ap;target=$tp;bytes=$ab})};$allAliases=@($normalizedAliases)
    $primary=(Convert-ToTarPath ([string]$OldManifest.sourceName)).Trim('/').Trim()
    if(Test-Blank $primary){$oldRoots=@(Get-StarContentRoots $OldManifest);if($oldRoots.Count -gt 0){$primary=[string]$oldRoots[0].name}}
    $roots=New-Object System.Collections.ArrayList
    if(-not(Test-Blank $primary)){[void]$roots.Add([pscustomobject]@{name=$primary;type='primary';generation=0})}
    # Preserve uncommon roots from early previews, then expose one canonical ADD root.
    foreach($root in @(Get-StarContentRoots $OldManifest)){
        $name=(Convert-ToTarPath ([string]$root.name)).Trim('/').Trim()
        if(Test-Blank $name -or $name -ieq $primary -or $name -ieq 'ADD'){continue}
        [void]$roots.Add([pscustomobject]@{name=$name;type='legacy-add-root';generation=[int]$root.generation})
    }
    [void]$roots.Add([pscustomobject]@{name='ADD';type='add-container';generation=[int]$AddInfo.Generation})
    $history=@($OldManifest.addHistory)+@([pscustomobject]@{generation=[int]$AddInfo.Generation;batch=[string]$AddInfo.Batch;sourceName=[string]$AddInfo.SourceName;root=[string]$AddInfo.Name;addedUtc=[string]$AddInfo.AddedUtc;blockIds=@($NewBlocks|ForEach-Object{$_.id})})
    $aliasPathSet=@{}
    foreach($alias in $allAliases){
        $path=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim()
        if(-not(Test-Blank $path)){$aliasPathSet[$path.ToLowerInvariant()]=$true}
    }
    foreach($alias in $allAliases){
        $target=(Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim()
        if(-not(Test-Blank $target) -and $aliasPathSet.ContainsKey($target.ToLowerInvariant())){
            throw "Invalid dedup alias chain detected: $([string]$alias.path) -> $target"
        }
    }
    $stored=[int64]0;foreach($b in $allBlocks){if([string]$b.group -ne 'structure'){$stored+=[int64]$b.sourceBytes}}
    $aliasBytes=[int64]0;foreach($a in $allAliases){$aliasBytes+=[int64]$a.bytes}
    $unique=0;foreach($b in $allBlocks){$unique+=[int]$b.fileCount}
    return [ordered]@{
        format='STAR';formatVersion=2;layout='multi-root-additive';tool='SmartTAR';toolVersion='1.4.0';createdUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sourceName=$primary;sourceType='MultiRoot';sourceBytes=([int64]$stored+[int64]$aliasBytes)
        compressionMode='Additive';compressionProfile='Multi-root additive archive'
        build=[ordered]@{workrootMode='transactional-add';pipeline='append-new-blocks-preserve-existing';blockCleanup='after-append';manifestPosition='last-outer-entry';outerTarFormat='pax'}
        contentRoots=@($roots);addHistory=@($history)
        summary=[ordered]@{storedUniqueBytes=$stored;catalogFiles=($unique+$allAliases.Count);uniqueFiles=$unique;aliasFiles=$allAliases.Count;dedupAliasCount=$allAliases.Count;dedupAliasBytes=$aliasBytes}
        dedupAliasMode='unique-only-restored-on-extract';dedupAliases=@($allAliases);blocks=@($allBlocks)
    }
}

function Add-SmartArchive {
    param([string]$TarPath,[string]$Source,[string]$Destination,[string]$Mode)
    if(-not(Test-Path -LiteralPath $Destination -PathType Leaf)){throw 'ADD destination archive does not exist.'}
    $Source=Normalize-ArchiveSourcePath $Source
    if(-not(Test-Path -LiteralPath $Source)){throw 'ADD source path does not exist.'}
    $work=New-SafeWorkRoot 'add' $Destination
    $published=$false;$tempArchive=Join-Path ([System.IO.Path]::GetDirectoryName($Destination)) (([System.IO.Path]::GetFileName($Destination))+'.adding.tmp')
    try{
        Set-BusyStatus 'Reading existing STAR archive...'
        $old=Get-StarOuterData $TarPath $Destination $work $false
        $manifest=$old.Manifest
        if([int]$manifest.formatVersion -gt 2){throw "Unsupported STAR formatVersion: $($manifest.formatVersion)"}
        $payload=Join-Path $work 'existing_payload';[System.IO.Directory]::CreateDirectory($payload)|Out-Null
        Set-BusyStatus 'Building existing dedup index...'
        Extract-BlocksStreamed $TarPath $Destination @($manifest.blocks) $payload $false|Out-Null
        # ADD dedup needs only physically stored block members. Existing aliases
        # remain in the manifest and are deliberately not materialized here.
        $existingIndex=New-ExistingContentDedupIndex $payload $manifest
        $sourceLeaf=Split-Path -Leaf $Source;if(Test-Blank $sourceLeaf){$sourceLeaf='Added content'}
        $addInfo=Get-NextAddRoot $manifest $sourceLeaf
        $addParent=Join-Path $work 'add_source';[System.IO.Directory]::CreateDirectory($addParent)|Out-Null
        Set-BusyStatus "Preparing ADD batch $($addInfo.Batch)..."
        [void](New-AddSourceStage $Source $addParent $addInfo.Name)
        $crossAliases=Remove-AddDuplicatesAgainstArchive $addParent $addInfo.Name $existingIndex
        $mini=Join-Path $work 'add_generation.star'
        Set-BusyStatus 'Compressing new ADD generation...'
        # Compress from the common ADD root so both structure and data blocks
        # store the same complete path: ADD/ADD_timestamp/source/...
        Compress-SmartArchive $TarPath (Join-Path $addParent 'ADD') $mini $Mode
        $miniWork=Join-Path $work 'mini';[System.IO.Directory]::CreateDirectory($miniWork)|Out-Null
        $miniData=Get-StarOuterData $TarPath $mini $miniWork
        $start=(Get-MaxStarBlockId $manifest)+1;$newBlocks=@();$i=$start
        $appendRoot=Join-Path $work 'append';$appendBlocks=Join-Path $appendRoot 'blocks';[System.IO.Directory]::CreateDirectory($appendBlocks)|Out-Null
        foreach($block in @($miniData.Manifest.blocks)){
            $oldPath=Resolve-SafeBlockPath $miniData.Outer ([string]$block.path)
            $name=[System.IO.Path]::GetFileName([string]$block.path)
            $tail=$name -replace '^\d+_',''
            $generationSuffix='_add{0:D3}' -f [int]$addInfo.Generation
            $renamedTail=$tail -replace '(?=\.tar)', $generationSuffix
            $newId='{0:D6}' -f $i
            $newName=$newId+'_'+$renamedTail
            $dest=Join-Path $appendBlocks $newName;Copy-Item -LiteralPath $oldPath -Destination $dest -Force
            $block.id=$newId;$block.path='blocks/'+$newName;$block|Add-Member -NotePropertyName generation -NotePropertyValue ([int]$addInfo.Generation) -Force
            $newBlocks+=,$block;$i++
        }
        $newManifest=Merge-StarAddManifest $manifest $miniData.Manifest $crossAliases $addInfo $newBlocks
        $canonical=Test-StarCanonicalTailLayout $Destination $manifest
        if(Test-Path -LiteralPath $tempArchive){Remove-Item -LiteralPath $tempArchive -Force}
        Copy-Item -LiteralPath $Destination -Destination $tempArchive -Force
        Reset-StarTempToCanonicalDataEnd $tempArchive ([int64]$canonical.ManifestRecordStart)
        foreach($block in $newBlocks){Add-StarOuterEntry $TarPath $tempArchive $appendRoot ([string]$block.path) 'ADD block append failed.'}
        $newDataLayout=Get-StarOuterTarLayout $tempArchive
        Set-ManifestCanonicalOuterLayout $newManifest ([int64]$newDataLayout.EndOfEntriesOffset)
        Write-Manifest (Join-Path $appendRoot 'manifest.json') $newManifest
        Add-StarOuterEntry $TarPath $tempArchive $appendRoot 'manifest.json' 'ADD manifest append failed.'
        $publishedLayout=Get-StarOuterTarLayout $tempArchive
        if([int]$publishedLayout.ManifestCount -ne 1 -or [string]$publishedLayout.LastEntryPath -ne 'manifest.json'){throw 'Updated STAR canonical manifest layout validation failed.'}
        Set-BusyStatus 'Verifying updated STAR archive...'
        $verify=Verify-SmartArchive $TarPath $tempArchive
        if([string]$verify[17] -ne 'OK'){
            $detail=[string]$verify[28]
            if(Test-Blank $detail){$detail='No verification details were returned.'}
            throw "Updated STAR verification failed.`r`n$detail"
        }
        Complete-StarOuterArchive $tempArchive $Destination;$published=$true
        return [pscustomobject]@{ Root=$addInfo.Name;Batch=$addInfo.Batch;SourceName=$addInfo.SourceName;Generation=$addInfo.Generation;NewBlocks=$newBlocks.Count;CrossAliases=@($crossAliases).Count }
    }finally{
        if(-not $published -and (Test-Path -LiteralPath $tempArchive)){Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue}
        Remove-SmartTarWorkAndRoot $work
    }
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
    if ($Mode -notin @('Balanced','Smart','Solid','Store')) { $Mode = 'Balanced' }
    $compressionWork = New-CompressionWorkRoot $Source $Destination
    $work = [string]$compressionWork.WorkRoot
    $allowGroupCopyFallback = [bool]$compressionWork.AllowGroupCopyFallback
    $script:buildWorkMode = [string]$compressionWork.Mode
    $blocksDir = Join-Path $work 'blocks'; $structureStage = Join-Path $work 'structure_stage'
    [System.IO.Directory]::CreateDirectory($blocksDir) | Out-Null; [System.IO.Directory]::CreateDirectory($structureStage) | Out-Null
    $outerTemp = ''; $published = $false
    try { Set-BusyStatus 'Checking TAR capabilities...'; $capabilities = Test-TarCapabilities $TarPath $work; if (-not $capabilities.store) { throw 'No usable tar store method.' }; $sourceItem = Get-Item -LiteralPath $Source -Force; $sourceContext = Get-ArchiveSourceContext $Source; $sourceParent = [string]$sourceContext.BaseRoot; $sourceLeaf = [string]$sourceContext.SourceLeaf; $script:sourceArchiveRootPrefix = [string]$sourceContext.ArchiveRootPrefix; Set-BusyStatus 'Analyzing source...'; $profile = Get-SourceProfile $sourceItem $Source $sourceParent; $profileName = Get-CompressionProfileDisplayName $Mode (Get-CompressionPreferenceForMode $Mode); Set-BusyStatus "Selected profile: $profileName"; $groups = New-ArchiveGroups $Mode $capabilities $profile; Initialize-SmartTarPlanningArtifacts $work; Stage-FilesPlan $sourceItem $Source $sourceParent $Mode $groups; Test-PlannedDedupAliases $groups; Invoke-SmartArchiveMethodProbes $TarPath $work $Mode $groups $capabilities; if ($Mode -eq 'Solid' -and $groups.Contains('solid')) { $groups.solid.Method = Select-AutoSolidMethod $capabilities $profile $script:adaptiveStats; $groups.solid.Reason = 'Solid single-block method selected from content profile.' }; $dirCount = Create-StructureStage $sourceItem $Source $sourceParent $structureStage; $storeMethod = Select-StoreMethod $capabilities; Set-BusyStatus "Creating parallel STAR archive: $profileName..."; $outerTemp = New-StarOuterTempArchive $Destination; $blocks = Build-AndPublishBlocksParallel $TarPath $groups $blocksDir $work $structureStage $dirCount $storeMethod $allowGroupCopyFallback $outerTemp; if ($blocks.Count -lt 1) { throw 'No blocks were created.' }; $manifest = Build-Manifest $Source $sourceItem $sourceLeaf $Mode $capabilities $profile $blocks; $dataLayout=Get-StarOuterTarLayout $outerTemp; Set-ManifestCanonicalOuterLayout $manifest ([int64]$dataLayout.EndOfEntriesOffset); Write-Manifest (Join-Path $work 'manifest.json') $manifest; Set-BusyStatus "Finalizing STAR archive: $profileName..."; Add-StarOuterEntry $TarPath $outerTemp $work 'manifest.json' 'Outer .star manifest append failed.'; $finalLayout=Get-StarOuterTarLayout $outerTemp; if([int]$finalLayout.ManifestCount -ne 1 -or [string]$finalLayout.LastEntryPath -ne 'manifest.json'){throw 'New STAR canonical manifest layout validation failed.'}; Complete-StarOuterArchive $outerTemp $Destination; $published = $true }
    finally { if (-not $published -and -not (Test-Blank $outerTemp) -and (Test-Path -LiteralPath $outerTemp)) { Remove-Item -LiteralPath $outerTemp -Force -ErrorAction SilentlyContinue }; Remove-SmartTarWorkAndRoot $work }
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
        $script:analysisScope = Get-AnalysisScopeForMode $mode
        $script:compressionPreference = Get-CompressionPreferenceForMode $mode
        $script:adaptiveDeepAnalyze = Test-ContentAnalysisEnabled $script:analysisScope

        if (Test-Blank $source -or -not (Test-Path -LiteralPath $source)) { throw "Worker source path does not exist: $source" }
        if (Test-Blank $internalReport) { throw 'Internal report path is empty.' }
        if (Test-Blank $resultFile) { throw 'Result path is empty.' }

        $targetPath=''; $destinationResult=''
        if ($action -eq 'Compress') {
            if (Test-Blank $destination) { throw 'Worker destination path is empty.' }
            Set-BusyStatus 'Starting compression...'
            Compress-SmartArchive $tarPath $source $destination $mode
            $targetPath=$destination
            try { $r = Get-ArchiveSummary $tarPath $destination $source }
            catch { $e=Get-ErrorDetails $_; $r=@('')*32; $r[0]='Compress'; $r[1]='Archive created successfully.'; $r[20]=''; if(Test-Path -LiteralPath $source){$r[2]=Format-Bytes (Get-SourceSize $source)}; if(Test-Path -LiteralPath $destination){$r[3]=Format-Bytes ([int64](Get-Item -LiteralPath $destination).Length)}; $r[28]="`r`n`r`nArchive created, but verify failed:`r`n$e" }
        }
        elseif ($action -eq 'Add') {
            if (Test-Blank $destination) { throw 'Worker ADD destination path is empty.' }
            Set-BusyStatus 'Starting ADD...'
            $previousArchiveBytes=[int64](Get-Item -LiteralPath $destination).Length
            $addedSourceBytes=[int64](Get-SourceSize $source)
            $addResult=Add-SmartArchive $tarPath $source $destination $mode
            $targetPath=$destination
            $r=Verify-SmartArchive $tarPath $destination
            $updatedArchiveBytes=[int64](Get-Item -LiteralPath $destination).Length;$increase=[int64]($updatedArchiveBytes-$previousArchiveBytes)
            $r[0]='Add';$r[1]="Content added successfully as $($addResult.Batch).";$r[2]=Format-Bytes $addedSourceBytes;$r[3]=Format-Bytes $updatedArchiveBytes;$r[4]='n/a (ADD)';$r[5]='n/a (ADD)'
            $r[28]+="`r`n`r`nADD statistics:`r`nPrevious archive size: $(Format-Bytes $previousArchiveBytes)`r`nUpdated archive size: $(Format-Bytes $updatedArchiveBytes)`r`nArchive size increase: $(Format-Bytes $increase)`r`nAdded source size: $(Format-Bytes $addedSourceBytes)`r`nCross-archive dedup aliases: $($addResult.CrossAliases)"
        }
        elseif ($action -eq 'Extract') {
            if (Test-Blank $destination) { throw 'Worker destination path is empty.' }
            Set-BusyStatus 'Starting extraction...'
            $destinationResult=$destination
            $r = Extract-SmartArchive $tarPath $source $destination $salvage
        }
        elseif ($action -eq 'Verify') {
            Set-BusyStatus 'Starting verification...'
            $targetPath=$source
            $r = Verify-SmartArchive $tarPath $source
        }
        else { throw "Unknown worker action: $action" }

        $summary = Format-OperationReport $r
        Write-ReportFile $internalReport $summary
        if (-not (Test-Blank $finalReport)) { Copy-Item -LiteralPath $internalReport -Destination $finalReport -Force }

        @{ Success=$true; Action=$action; InternalReportFile=$internalReport; FinalReportFile=$finalReport; TargetPath=$targetPath; Destination=$destinationResult; Mode=$mode } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultFile -Encoding UTF8

        Set-AppStatus 'Done.' $cStatusOk
        exit 0
    }
    catch {
        $err = Get-ErrorDetails $_
        try {
            if ($script:workerConfig) {
                $failedInternal = [string]$script:workerConfig.InternalReportFile
                $failedFinal = [string]$script:workerConfig.FinalReportFile
                if (-not (Test-Blank $failedInternal)) {
                    Write-ReportFile $failedInternal "Operation failed.`r`n`r`n$err"
                    if (-not (Test-Blank $failedFinal)) { Copy-Item -LiteralPath $failedInternal -Destination $failedFinal -Force -ErrorAction Stop }
                }
                if (-not (Test-Blank ([string]$script:workerConfig.ResultFile))) {
                    @{ Success = $false; Action = ([string]$script:workerConfig.Action); Error = $err; InternalReportFile = $failedInternal; FinalReportFile = $failedFinal } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath ([string]$script:workerConfig.ResultFile) -Encoding UTF8
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
    return ([System.IO.Path]::GetFileName($Path) -match '(?i)\.star$')
}

function Ensure-StarExtension {
    param([string]$Path)
    if (Test-Blank $Path) { return $Path }
    if ($Path -match '(?i)\.star$') { return $Path }
    return ($Path + $script:ArchiveExtension)
}

function Get-DefaultArchiveBaseName {
    param([string]$Path, [string]$Type)

    if (Test-Blank $Path) { return "archive_$(Get-Date -Format yyyyMMdd_HHmmss)" }

    $normalized = Normalize-ArchiveSourcePath $Path
    if (Test-Blank $normalized) { return "archive_$(Get-Date -Format yyyyMMdd_HHmmss)" }

    try {
        $full = [System.IO.Path]::GetFullPath($normalized)
        $root = [System.IO.Path]::GetPathRoot($full)

        if (-not (Test-Blank $root) -and ((Trim-PathSeparators $full) -ieq (Trim-PathSeparators $root))) {
            return (Get-DriveArchiveRootName $root)
        }
    }
    catch {
        # Fall through to normal leaf handling.
    }

    $leaf = Split-Path -Leaf $normalized
    if ($Type -ne 'Folder') { $leaf = [System.IO.Path]::GetFileNameWithoutExtension($leaf) }

    $leaf = Convert-ToSafeArchiveFileNamePart $leaf
    if (Test-Blank $leaf) { return "archive_$(Get-Date -Format yyyyMMdd_HHmmss)" }
    return $leaf
}

function Get-SelectedCompressionMode {
    $text=[string]$cmbMode.SelectedItem
    if($text -like 'Smart*'){return 'Smart'}
    if($text -like 'Solid*'){return 'Solid'}
    if($text -like 'Store*'){return 'Store'}
    return 'Balanced'
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
    $script:pendingTargetPath = ''
    $script:pendingTargetAction = ''
    $lblSelected.Text = "Selected: $Path"
    $btnFile.BackColor = if ($Type -eq 'File' -and -not (Test-SmartArchivePath $Path)) { $cRoyal } else { $cSurface }
    $btnFolder.BackColor = if ($Type -eq 'Folder') { $cRoyal } else { $cSurface }
    $btnArchive.BackColor = if ($Type -eq 'File' -and (Test-SmartArchivePath $Path)) { $cRoyal } else { $cSurface }
    foreach ($button in @($btnFile, $btnFolder, $btnArchive)) { $button.ForeColor = $cButtonText }
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
        [string]$Mode = 'Balanced',
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
        'Add'      { 'add_report' }
        'Extract'  { 'extract_report' }
        'Verify'   { 'verify_report' }
        default    { 'worker_report' }
    }

    if (($Action -eq 'Compress' -or $Action -eq 'Add') -and -not (Test-Blank $DestinationPath)) {
        $reportBase = $DestinationPath
    }
    elseif ($Action -eq 'Extract' -and -not (Test-Blank $DestinationPath)) {
        $archiveName = Get-ArchiveBaseNameWithoutSmartExtension $SourcePath
        if (Test-Blank $archiveName) { $archiveName = 'SmartTAR_extract' }
        $reportBase = Join-Path $DestinationPath $archiveName
    }
    else {
        $reportBase = $SourcePath
    }
    $script:currentFinalReportFile = Get-SafeReportPath $reportBase $reportKind

    $script:currentAction = $Action
    $script:openFolderAfter = [bool]$chkOpenFolder.Checked
    $script:currentStdOut = ''
    $script:currentStdErr = ''
Reset-SmartTarRuntimeState

    'Starting...' | Set-Content -LiteralPath $script:currentStatusFile -Encoding UTF8

    $config = [ordered]@{
        Action             = $Action
        Source             = $SourcePath
        Destination        = $DestinationPath
        Mode               = $Mode
        Salvage            = $Salvage
        AdaptiveDeepAnalyze = [bool]$script:adaptiveDeepAnalyze
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
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false

    $script:currentProcess = [System.Diagnostics.Process]::Start($psi)

    Set-UiBusy $true
    Set-BusyStatus "$Action started..."
    $timer.Start()
    Clear-UiFocus
}

function Get-SmartTarChildProcesses {
    param([int]$ParentProcessId)

    if ($ParentProcessId -le 0) { return @() }

    try {
        return @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction Stop)
    }
    catch {
        try {
            return @(Get-WmiObject Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction SilentlyContinue)
        }
        catch {
            return @()
        }
    }
}

function Stop-SmartTarProcessTree {
    param(
        [int]$ProcessId,
        [bool]$IncludeRoot = $true
    )

    if ($ProcessId -le 0) { return }

    foreach ($child in @(Get-SmartTarChildProcesses $ProcessId)) {
        try {
            Stop-SmartTarProcessTree -ProcessId ([int]$child.ProcessId) -IncludeRoot $true
        }
        catch {}
    }

    if ($IncludeRoot) {
        try {
            $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($p) {
                Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
}

function Clear-CurrentWorkerState {
    try { if ($script:currentProcess) { $script:currentProcess.Dispose() } } catch {}
    $script:currentProcess = $null
    $script:currentWorkerRoot = ''
    $script:currentConfigFile = ''
    $script:currentStatusFile = ''
    $script:currentResultFile = ''
    $script:currentInternalReportFile = ''
    $script:currentFinalReportFile = ''
}

function Remove-CurrentOperationCompressionWorkRoot {
    try {
        if (Test-Blank $script:currentConfigFile) { return }
        if (-not (Test-Path -LiteralPath $script:currentConfigFile)) { return }

        $cfg = Get-Content -LiteralPath $script:currentConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$cfg.Action -ne 'Compress') { return }

        $destination = [string]$cfg.Destination
        if (Test-Blank $destination) { return }

        $destDir = [System.IO.Path]::GetDirectoryName($destination)
        if (Test-Blank $destDir) { $destDir = (Get-Location).Path }

        $workBase = Join-Path $destDir '.stw'
        if (-not (Test-Path -LiteralPath $workBase)) { return }

        foreach ($dir in @(Get-ChildItem -LiteralPath $workBase -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'c_*' })) {
            try { Remove-SmartTarTempFolder $dir.FullName } catch {}
        }

        try {
            $remaining = @(Get-ChildItem -LiteralPath $workBase -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $workBase -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
    catch {}
}

function Stop-CurrentWorkerOperation {
    param([string]$Reason = 'Cancelled by user.')

    try { $timer.Stop() } catch {}
    Set-BusyStatus 'Stopping operation...'

    $workerPid = 0
    try {
        if ($script:currentProcess) { $workerPid = [int]$script:currentProcess.Id }
    }
    catch { $workerPid = 0 }

    if ($workerPid -gt 0) {
        try { Stop-SmartTarProcessTree -ProcessId $workerPid -IncludeRoot $true } catch {}
        try { $script:currentProcess.WaitForExit(5000) | Out-Null } catch {}
    }

    try { Remove-CurrentOperationCompressionWorkRoot } catch {}

    if (-not (Test-Blank $script:currentWorkerRoot)) {
        try { Remove-SmartTarWorkAndRoot $script:currentWorkerRoot } catch {}
    }

    Clear-CurrentWorkerState
    Set-UiBusy $false
    Clear-UiFocus
    Set-AppStatus 'Operation cancelled.' $cTextMuted
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
        return [pscustomobject]@{ Success=$false; Action=[string]$Result.Action; Error=[string]$Result.Error; InternalReportFile=[string]$Result.InternalReportFile; FinalReportFile=[string]$Result.FinalReportFile }
    }
    return [pscustomobject]@{ Success=$false; Action=$script:currentAction; Error='Worker ended without temp result/report. See stdout/stderr details.'; InternalReportFile=$script:currentInternalReportFile; FinalReportFile=$script:currentFinalReportFile }
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

    return [System.Windows.Forms.Label]@{
        Text      = $Text
        Location  = (New-Point $X $Y)
        Size      = (New-Size $Width $Height)
        Font      = $Font
        ForeColor = $ForeColor
        BackColor = [System.Drawing.Color]::Transparent
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
        [System.Drawing.Color]$BackColor = $cSurface,
        [System.Drawing.Color]$ForeColor = $cText
    )

    $button = [System.Windows.Forms.Button]@{
        Text                    = $Text
        Location                = (New-Point $X $Y)
        Size                    = (New-Size $Width $Height)
        Font                    = $Font
        BackColor               = $BackColor
        ForeColor               = $ForeColor
        UseVisualStyleBackColor = $false
        FlatStyle               = [System.Windows.Forms.FlatStyle]::Flat
        Cursor                  = [System.Windows.Forms.Cursors]::Hand
    }

    try {
        $button.FlatAppearance.BorderSize = 1
        $button.FlatAppearance.BorderColor = $cGray
        $button.FlatAppearance.MouseOverBackColor = $cRoyalHover
        $button.FlatAppearance.MouseDownBackColor = $cRoyalActive
    }
    catch {}

    return $button
}

function New-EcoCheck {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Checked = $true)

    return [System.Windows.Forms.CheckBox]@{
        Text                     = $Text
        Location                 = (New-Point $X $Y)
        Size                     = (New-Size $Width 22)
        Font                     = $fNormal
        BackColor                = $cBg
        ForeColor                = $cText
        Checked                  = $Checked
        FlatStyle                = [System.Windows.Forms.FlatStyle]::Standard
        UseVisualStyleBackColor  = $false
        CheckAlign               = [System.Drawing.ContentAlignment]::MiddleLeft
        TextAlign                = [System.Drawing.ContentAlignment]::MiddleLeft
        Cursor                   = [System.Windows.Forms.Cursors]::Hand
    }
}

function Show-Message {
    param(
        [string]$Message,
        [string]$Title = 'SmartTAR STAR v1.4.0',
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )
    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Show-ExistingStarAction {
    param([string]$ArchivePath)
    $f=[System.Windows.Forms.Form]@{Text='Existing STAR archive';ClientSize=(New-Size 520 230);StartPosition='CenterParent';BackColor=$cBg;FormBorderStyle='FixedDialog';MaximizeBox=$false;MinimizeBox=$false;ShowInTaskbar=$false}
    $label=New-EcoLabel "The destination STAR already exists.`r`n`r`nOVERWRITE replaces it completely.`r`nADD preserves existing blocks and adds a new independent root.`r`nCANCEL makes no changes.`r`n`r`nArchive: $ArchivePath" 18 16 484 130 $fNormal $cText
    $label.AutoEllipsis=$true
    $result='Cancel'
    $over=New-EcoButton 'OVERWRITE' 18 168 145 38 $fBold $cDanger $cButtonText
    $add=New-EcoButton 'ADD' 187 168 145 38 $fBold $cSuccess $cButtonText
    $cancel=New-EcoButton 'CANCEL' 356 168 145 38 $fBold $cVerify $cButtonText
    $over.Add_Click({$script:existingStarChoice='Overwrite';$f.Close()})
    $add.Add_Click({$script:existingStarChoice='Add';$f.Close()})
    $cancel.Add_Click({$script:existingStarChoice='Cancel';$f.Close()})
    $f.Add_FormClosing({if(Test-Blank $script:existingStarChoice){$script:existingStarChoice='Cancel'}})
    $f.Controls.AddRange([System.Windows.Forms.Control[]]@($label,$over,$add,$cancel))
    $script:existingStarChoice='';try{[void]$f.ShowDialog($form);$result=[string]$script:existingStarChoice}finally{$f.Dispose();$script:existingStarChoice=''}
    return $result
}

function Show-ArchiveAddBrowseChoice {
    param([string]$ArchivePath)

    $choiceForm = New-Object System.Windows.Forms.Form
    $choiceForm.Text = 'Add or Browse archive?'
    $choiceForm.ClientSize = New-Size 470 170
    $choiceForm.StartPosition = 'CenterParent'
    $choiceForm.FormBorderStyle = 'FixedDialog'
    $choiceForm.MaximizeBox = $false
    $choiceForm.MinimizeBox = $false
    $choiceForm.BackColor = $cBg

    $label = New-EcoLabel "Archive selected:" 16 16 430 20 $fBold $cText
    $pathLabel = New-EcoLabel $ArchivePath 16 40 430 45 $fItalic $cTextMuted
    try { $pathLabel.UseMnemonic = $false; $pathLabel.AutoEllipsis = $true } catch {}
    $hint = New-EcoLabel 'Choose what to do with this archive:' 16 88 430 20 $fNormal $cText

    $btnAddChoice = New-EcoButton 'Add' 94 122 120 32 $fBold $cSuccess $cButtonText
    $btnBrowseChoice = New-EcoButton 'Browse' 256 122 120 32 $fBold $cRoyal $cButtonText

    $script:archiveAddBrowseChoice = ''
    $btnAddChoice.Add_Click({ $script:archiveAddBrowseChoice = 'Add'; $choiceForm.Close() })
    $btnBrowseChoice.Add_Click({ $script:archiveAddBrowseChoice = 'Browse'; $choiceForm.Close() })

    $choiceForm.Controls.AddRange([System.Windows.Forms.Control[]]@($label, $pathLabel, $hint, $btnAddChoice, $btnBrowseChoice))

    try { [void]$choiceForm.ShowDialog($form) }
    finally { $choiceForm.Dispose() }

    return [string]$script:archiveAddBrowseChoice
}

$form = [System.Windows.Forms.Form]@{
    Text            = 'SmartTAR - STAR 1.4.0 STREAMED ADD UPPERCASE  .:: Copyright © 2026 eco-by-different ::.'
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
$btnArchive  = New-EcoButton 'Add / Browse ARCHIVE' 334 48 151 30
$lblSelected = New-EcoLabel 'Selected: none' 20 88 465 20 $fItalic $cTextMuted
try { $lblSelected.UseMnemonic = $false; $lblSelected.AutoEllipsis = $true } catch {}

$lblTarget = New-EcoLabel '2. Destination archive / extraction parent folder:' 20 125 -Font $fBold
$txtTarget = [System.Windows.Forms.TextBox]@{
    Location      = (New-Point 20 153)
    Size          = (New-Size 395 23)
    Font          = $fNormal
    ReadOnly      = $true
    BackColor     = $cInput
    ForeColor     = $cText
    BorderStyle   = [System.Windows.Forms.BorderStyle]::FixedSingle
    TabStop       = $false
    HideSelection = $true
}
$btnTarget = New-EcoButton '...' 422 152 63 24

$lblMode = New-EcoLabel '3. Compression profile:' 20 195 -Font $fBold
$cmbMode = [System.Windows.Forms.ComboBox]@{
    Location      = (New-Point 20 223)
    Size          = (New-Size 465 24)
    Font          = $fNormal
    DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    BackColor     = $cSurface
    ForeColor     = $cText
    FlatStyle     = [System.Windows.Forms.FlatStyle]::Flat
}
[void]$cmbMode.Items.Add('Balanced - mixed blocks')
[void]$cmbMode.Items.Add('Smart - max compression')
[void]$cmbMode.Items.Add('Solid - single block')
[void]$cmbMode.Items.Add('Store - no compression')
$cmbMode.SelectedIndex = 0

$lblInfo = New-EcoLabel '-=>> SmartTAR is an MTB project - Make TAR Better <<=-' 20 252 465 20 $fBold $cTextMuted
$lblInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$btnCompress = New-EcoButton 'COMPRESS' 20 287 150 42 $fBold $cSuccess $cButtonText
$btnExtract  = New-EcoButton 'EXTRACT' 177 287 150 42 $fBold $cRoyal $cButtonText
$btnVerify   = New-EcoButton 'VERIFY' 334 287 151 42 $fBold $cVerify $cButtonText
try {
    $btnCompress.FlatAppearance.MouseOverBackColor = $cSuccessHover
    $btnCompress.FlatAppearance.MouseDownBackColor = $cSuccessDown
    $btnExtract.FlatAppearance.MouseOverBackColor = $cRoyalHover
    $btnExtract.FlatAppearance.MouseDownBackColor = $cRoyalActive
    $btnVerify.FlatAppearance.MouseOverBackColor = $cVerifyHover
    $btnVerify.FlatAppearance.MouseDownBackColor = $cSurfaceAlt
} catch {}

$chkOpenFolder  = New-EcoCheck 'Open output folder after success' 20 342 260 $true
$chkAdaptive    = New-EcoCheck 'Content analysis is automatic' 290 342 200 $false
$chkAdaptive.Visible = $false
$chkAdaptive.Enabled = $false
$chkSalvageMode = New-EcoCheck 'Salvage mode (Ignore broken blocks)' 20 366 330 $false

$lblStatus = New-EcoLabel 'Ready.' 20 404 465 20 $fItalic $cTextMuted
$progressBar = [System.Windows.Forms.ProgressBar]@{
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
            $statusText='';try{$statusText=Get-Content -LiteralPath $script:currentStatusFile -Raw -Encoding UTF8 -ErrorAction Stop}catch{}
            if(-not(Test-Blank $statusText)){Set-BusyStatus ($statusText.Trim())}
        }

        if ($script:currentProcess -and $script:currentProcess.HasExited) {
            $timer.Stop()

            $script:currentStdOut = ''
            $script:currentStdErr = ''

            $result = Read-WorkerResultFromTemp
            $completion = Resolve-WorkerCompletionFromTemp $result

            Set-UiBusy $false
            Clear-UiFocus

            $shownReport = if (-not (Test-Blank ([string]$completion.FinalReportFile)) -and (Test-Path -LiteralPath ([string]$completion.FinalReportFile) -PathType Leaf)) { [string]$completion.FinalReportFile } elseif (-not (Test-Blank ([string]$completion.InternalReportFile))) { [string]$completion.InternalReportFile } else { '' }
            if ($completion.Success) {
                Set-AppStatus 'Done.' $cStatusOk
                $reportInfo = if (Test-Blank $shownReport) { 'Operation completed successfully, but the report path is unavailable.' } else { "Operation completed successfully.`r`n`r`nReport saved to:`r`n$shownReport" }
                Show-Message $reportInfo "SmartTAR $($completion.Action)" ([System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                if ($script:openFolderAfter) {
                    if ($completion.Action -eq 'Compress' -and -not (Test-Blank $completion.TargetPath)) { explorer.exe "/select,`"$($completion.TargetPath)`"" }
                    elseif ($completion.Action -eq 'Extract' -and -not (Test-Blank $completion.Destination)) { explorer.exe "`"$($completion.Destination)`"" }
                }
            } else {
                Set-AppStatus 'Failed.' $cDanger
                $reportInfo = if (Test-Blank $shownReport) { 'Operation failed and the report could not be saved.' } else { "Operation failed.`r`n`r`nReport saved to:`r`n$shownReport" }
                Show-Message $reportInfo 'SmartTAR Error' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }

            Remove-SmartTarWorkAndRoot $script:currentWorkerRoot
            Clear-CurrentWorkerState
        }
    }
    catch {
        $timer.Stop()
        Set-UiBusy $false
        Clear-UiFocus
        Set-AppStatus 'GUI worker monitor failed.' $cDanger
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
    $dialog.Filter = 'SmartTAR Archive (*.star)|*.star|All files (*.*)|*.*'
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            # STAR v1 and v2 use the same Add / Browse choice. Selecting Add
            # places the archive in the main window for direct Extract, Verify
            # and Salvage; Browse opens the selective tree.
            $choice = Show-ArchiveAddBrowseChoice $dialog.FileName
            if ($choice -eq 'Add') {
                Set-SelectedPath $dialog.FileName 'File'
            }
            elseif ($choice -eq 'Browse') {
                Show-SmartArchiveBrowseDialog $tarPath $dialog.FileName
            }
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
    # Existing destinations are handled only by SmartTAR's
    # OVERWRITE / ADD / CANCEL dialog after the target is selected.
    $dialog.OverwritePrompt = $false

    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selectedTarget = Ensure-StarExtension $dialog.FileName
            $selectedAction = 'Compress'
            if (Test-Path -LiteralPath $selectedTarget -PathType Leaf) {
                if (-not (Test-SmartArchivePath $selectedTarget)) {
                    Show-Message "Existing destination is not a STAR archive:`r`n$selectedTarget" 'Invalid destination' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
                $choice = Show-ExistingStarAction $selectedTarget
                if ($choice -eq 'Cancel') { return }
                if ($choice -eq 'Add') { $selectedAction = 'Add' }
            }
            $txtTarget.Text = $selectedTarget
            $script:pendingTargetPath = [System.IO.Path]::GetFullPath($selectedTarget)
            $script:pendingTargetAction = $selectedAction
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

    $targetText = $txtTarget.Text.Trim('"')
    if (Test-Blank $targetText) {
        Show-Message 'Select destination.' | Out-Null
        return
    }

    $targetPath = ''

    if (Test-Path -LiteralPath $targetText -PathType Container) {
        if ($script:selectedType -eq 'Folder') {
            $baseName = Get-DefaultArchiveBaseName $script:selectedPath $script:selectedType

            if (Test-Blank $baseName) {
                $baseName = "archive_$(Get-Date -Format yyyyMMdd_HHmmss)"
            }

            $targetPath = Join-Path $targetText ($baseName + '.star')
        }
        else {
            $sourceLeaf = Split-Path -Leaf $script:selectedPath

            if (Test-Blank $sourceLeaf) {
                $sourceLeaf = "archive_$(Get-Date -Format yyyyMMdd_HHmmss)"
            }

            $targetPath = Join-Path $targetText ($sourceLeaf + '.star')
        }
    }
    else {
        $targetPath = Ensure-StarExtension $targetText
    }

    if (Test-Blank $targetPath) {
        Show-Message 'Select destination.' | Out-Null
        return
    }

    $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)

    if (Test-Blank $targetDir) {
        $targetDir = $scriptDir
        $targetPath = Join-Path $targetDir ([System.IO.Path]::GetFileName($targetPath))
    }

    try {
        $inputFull = [System.IO.Path]::GetFullPath($script:selectedPath)
        $targetFull = [System.IO.Path]::GetFullPath($targetPath)

        if ($inputFull -ieq $targetFull) {
            $targetPath = $targetPath + '.star'
        }
    }
    catch {}

    $action='Compress'
    if (Test-Path -LiteralPath $targetPath) {
        if (-not (Test-SmartArchivePath $targetPath)) {
            Show-Message "Existing destination is not a STAR archive:`r`n$targetPath" 'Invalid destination' ([System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
            return
        }
        $targetFull=[System.IO.Path]::GetFullPath($targetPath)
        if (-not (Test-Blank $script:pendingTargetPath) -and $targetFull -ieq $script:pendingTargetPath -and $script:pendingTargetAction -in @('Compress','Add')) {
            $action=[string]$script:pendingTargetAction
        }
        else {
            $choice=Show-ExistingStarAction $targetPath
            if($choice -eq 'Cancel'){return}
            if($choice -eq 'Add'){$action='Add'}
        }
    }
    $script:pendingTargetPath=''
    $script:pendingTargetAction=''
    Start-WorkerOperation $action $script:selectedPath $targetPath (Get-SelectedCompressionMode) $false
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
            Set-AppStatus 'Extraction cancelled by user.' $cTextMuted
            return
        }
    }
    catch {
        $precheckError = Get-ErrorDetails $_
        Show-Message "Extraction pre-check failed.`n`n$precheckError" 'SmartTAR Error' ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    Start-WorkerOperation 'Extract' $script:selectedPath $destination 'Balanced' ([bool]$chkSalvageMode.Checked) $false
}

function Execute-Verify {
    if ($script:isBusy) { return }
    if (-not (Test-SelectedInputReady 'verification')) { return }

    if (-not (Test-SmartArchivePath $script:selectedPath)) {
        Show-Message "Selected input is not a SmartTAR archive:`r`n$($script:selectedPath)" 'Invalid archive selection' ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Start-WorkerOperation 'Verify' $script:selectedPath $txtTarget.Text 'Balanced' $false $false
}

$btnCompress.Add_Click({ Execute-Compress })

$btnExtract.Add_Click({ Execute-Extract })

$btnVerify.Add_Click({ Execute-Verify })

$form.Add_FormClosing({
    $disposeUiResources = $true
    try {
        if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
            $confirm = Show-Message 'An operation is still running. Stop it and close?' 'Operation running' ([System.Windows.Forms.MessageBoxIcon]::Warning) ([System.Windows.Forms.MessageBoxButtons]::YesNo)
            if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
                $_.Cancel = $true
                $disposeUiResources = $false
                return
            }

            Stop-CurrentWorkerOperation 'Cancelled by user during application close.'
        }
    }
    finally {
        if ($disposeUiResources -and -not $_.Cancel) {
            try { $timer.Stop() } catch {}
            try { $fNormal.Dispose() } catch {}
            try { $fBold.Dispose() } catch {}
            try { $fItalic.Dispose() } catch {}
        }
    }
})

[System.Windows.Forms.Application]::Run($form)