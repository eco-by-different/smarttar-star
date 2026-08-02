# ============================================================================
# SmartTAR - STAR v1.5.1 ZSTD Scanner Multi Root Browse Fix 6 Preview
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

# Streams tar.exe ZSTD output to the final block file and removes the
# 512-byte stdout padding by parsing the ZSTD frame structure. The scanner is
# bounded-memory and validates that every removed trailing byte is zero.
if (-not ('SmartTarZstdBlockWriter' -as [type])) {
Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

public sealed class SmartTarZstdWriteResult
{
    public int ExitCode { get; set; }
    public string Error { get; set; }
    public long PaddedBytes { get; set; }
    public long FrameBytes { get; set; }
    public long RemovedPaddingBytes { get; set; }
    public int ZstdBlocks { get; set; }
    public bool Checksum { get; set; }
}

public static class SmartTarZstdBlockWriter
{
    private static string Q(string value)
    {
        if (value == null) return "\"\"";
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string JoinArgs(string[] args)
    {
        var b = new StringBuilder();
        foreach (string a in args) {
            if (b.Length > 0) b.Append(' ');
            b.Append(Q(a));
        }
        return b.ToString();
    }

    private static int ReadByteChecked(FileStream s, string message)
    {
        int value = s.ReadByte();
        if (value < 0) throw new InvalidDataException(message);
        return value;
    }

    private static ulong ReadLE(FileStream s, int count, string message)
    {
        ulong value = 0;
        for (int i = 0; i < count; i++) value |= ((ulong)ReadByteChecked(s, message)) << (8 * i);
        return value;
    }

    private static void Skip(FileStream s, long count, string message)
    {
        if (count < 0 || s.Position + count > s.Length) throw new InvalidDataException(message);
        s.Position += count;
    }

    private static SmartTarZstdWriteResult TrimFrame(string path)
    {
        using (var s = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {
            long padded = s.Length;
            if (padded < 6) throw new InvalidDataException("ZSTD frame is too short.");
            if (ReadByteChecked(s, "Missing ZSTD magic.") != 0x28 ||
                ReadByteChecked(s, "Missing ZSTD magic.") != 0xB5 ||
                ReadByteChecked(s, "Missing ZSTD magic.") != 0x2F ||
                ReadByteChecked(s, "Missing ZSTD magic.") != 0xFD)
                throw new InvalidDataException("ZSTD magic mismatch.");

            int fd = ReadByteChecked(s, "Missing ZSTD frame descriptor.");
            int dictFlag = fd & 3;
            bool checksum = (fd & 4) != 0;
            bool reserved = (fd & 8) != 0;
            bool single = (fd & 32) != 0;
            int fcsFlag = (fd >> 6) & 3;
            if (reserved) throw new InvalidDataException("Reserved ZSTD frame-header bit is set.");
            if (!single) ReadByteChecked(s, "Missing ZSTD window descriptor.");

            int[] dictSizes = new int[] { 0, 1, 2, 4 };
            int dictSize = dictSizes[dictFlag];
            int fcsSize = fcsFlag == 0 ? (single ? 1 : 0) : (fcsFlag == 1 ? 2 : (fcsFlag == 2 ? 4 : 8));
            Skip(s, dictSize + fcsSize, "Truncated ZSTD frame header.");

            int blocks = 0;
            while (true) {
                uint h = (uint)ReadLE(s, 3, "Missing ZSTD block header.");
                bool last = (h & 1) != 0;
                int type = (int)((h >> 1) & 3);
                int size = (int)((h >> 3) & 0x1FFFFF);
                if (type == 3) throw new InvalidDataException("Reserved ZSTD block type.");
                long payload = type == 1 ? 1 : size;
                Skip(s, payload, "Truncated ZSTD block payload.");
                blocks++;
                if (last) break;
            }
            if (checksum) Skip(s, 4, "Missing ZSTD content checksum.");

            long end = s.Position;
            long padding = padded - end;
            if (padding < 0 || padding >= 512) throw new InvalidDataException("Unexpected ZSTD stdout padding length: " + padding + ".");
            for (long i = 0; i < padding; i++) {
                if (ReadByteChecked(s, "Truncated ZSTD stdout padding.") != 0)
                    throw new InvalidDataException("Non-zero data found after the ZSTD frame.");
            }
            s.SetLength(end);
            s.Flush(true);
            return new SmartTarZstdWriteResult {
                ExitCode = 0, Error = "", PaddedBytes = padded, FrameBytes = end,
                RemovedPaddingBytes = padding, ZstdBlocks = blocks, Checksum = checksum
            };
        }
    }

    public static SmartTarZstdWriteResult Create(string tarPath, string[] args, string outputPath)
    {
        if (String.IsNullOrWhiteSpace(tarPath) || !File.Exists(tarPath))
            throw new FileNotFoundException("tar.exe was not found.", tarPath);
        string directory = Path.GetDirectoryName(outputPath);
        if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
        if (File.Exists(outputPath)) File.Delete(outputPath);

        var errors = new StringBuilder();
        var psi = new ProcessStartInfo {
            FileName = tarPath, Arguments = JoinArgs(args), UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        using (var p = new Process()) {
            p.StartInfo = psi;
            p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) { lock (errors) errors.AppendLine(e.Data); }
            };
            if (!p.Start()) throw new InvalidOperationException("Cannot start tar.exe.");
            p.BeginErrorReadLine();
            using (var output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024)) {
                p.StandardOutput.BaseStream.CopyTo(output, 1024 * 1024);
                output.Flush(true);
            }
            p.WaitForExit();
            p.WaitForExit();
            if (p.ExitCode != 0) {
                try { File.Delete(outputPath); } catch { }
                return new SmartTarZstdWriteResult { ExitCode = p.ExitCode, Error = errors.ToString().Trim() };
            }
        }
        SmartTarZstdWriteResult result = TrimFrame(outputPath);
        result.Error = errors.ToString().Trim();
        return result;
    }
}
"@
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
        return [pscustomobject]@{ BaseRoot=$normalized; SourceLeaf=$name; ArchiveRootPrefix=''; IsDriveRoot=$true }
    }
    $parent = Split-Path -Parent $normalized
    $leaf = Split-Path -Leaf $normalized
    if (Test-Blank $parent -or Test-Blank $leaf) { throw "Cannot determine source context: $normalized" }
    return [pscustomobject]@{ BaseRoot=$parent; SourceLeaf=$leaf; ArchiveRootPrefix=''; IsDriveRoot=$false }
}

function Get-SourceLayoutPolicy {
    param([string]$Source)
    $context=Get-ArchiveSourceContext $Source
    if([bool]$context.IsDriveRoot){return [pscustomobject]@{SourceType='DriveRoot';BaseRoot=[string]$context.BaseRoot;SourceName=[string]$context.SourceLeaf;StoredRootPrefix='';DisplayRoot=[string]$context.SourceLeaf;DisplayRootVirtual=$true;ExtractionMode='Contents';IsDriveRoot=$true}}
    $item=Get-Item -LiteralPath $Source -Force
    $type=if($item.PSIsContainer){'Folder'}else{'File'}
    return [pscustomobject]@{SourceType=$type;BaseRoot=[string]$context.BaseRoot;SourceName=[string]$context.SourceLeaf;StoredRootPrefix=[string]$context.ArchiveRootPrefix;DisplayRoot=[string]$context.SourceLeaf;DisplayRootVirtual=$false;ExtractionMode='Container';IsDriveRoot=$false}
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
            Mode = 'destination-local-sealed-catalog'
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

function Get-ReportVersionNumber {
    param([string]$Version)
    if (-not (Test-Blank $Version) -and $Version -match '^(\d+\.\d+\.\d+)') { return [string]$matches[1] }
    return [string]$Version
}
function Format-OperationDuration {
    param([TimeSpan]$Elapsed)
    return ('{0:D2}:{1:D2}:{2:D2}' -f [int][Math]::Floor($Elapsed.TotalHours),$Elapsed.Minutes,$Elapsed.Seconds)
}

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

    foreach ($i in 25..29) {
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

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { & cmd.exe /d /c "rmdir /s /q `"$Path`"" 1>$null 2>$null } catch {}
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
    $script:ToolVersion = '1.5.1-zstdscan-multirootfix6'
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
    $script:tarCapabilities = @{}
    $script:CompressionThreads = 1
    $script:MultithreadCompatibilityRetries = 0
    $script:SourceEnumerationExcludedRoots = @()
    $script:BrowseIndexDirectories = @()
    $script:BrowseIndexBlocks = @()
    $script:CurrentSourceIsDriveRoot = $false
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
Reset-SmartTarRuntimeState

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
        @{Name='store';Display='STORE';Extension='.tar';Level=$null;Algorithm='store'},
        @{Name='xz9';Display='XZ9';Extension='.tar.xz';Level=9;Algorithm='xz'},
        @{Name='zstd22';Display='ZSTD22';Extension='.tar.zst';Level=22;Algorithm='zstd'}
    )
}

function Get-CompressionThreadCount { return [Math]::Max(1,[Math]::Min(8,[Environment]::ProcessorCount)) }
function Test-TarThreadingSupported {
    param([hashtable]$Capabilities,[string]$Algorithm)
    if($null-eq$Capabilities){return $false}
    if($Algorithm-eq'xz'){return ($Capabilities.ContainsKey('xzThreads')-and[bool]$Capabilities.xzThreads)}
    if($Algorithm-eq'zstd'){return ($Capabilities.ContainsKey('zstdThreads')-and[bool]$Capabilities.zstdThreads)}
    return $false
}
function Get-TarCreateArguments {
    param([hashtable]$Method,[hashtable]$Capabilities,[int]$Threads=1,[bool]$ForceSingleThread=$false,[ValidateSet('pax','gnutar')][string]$TarFormat='pax')
    $a=[string]$Method.Algorithm;$mt=(-not$ForceSingleThread-and$Threads-gt1-and(Test-TarThreadingSupported $Capabilities $a))
    if($TarFormat-eq'gnutar'){
        if($a-ne'zstd'){throw 'GNU structure TAR requires ZSTD.'}
        $o='zstd:compression-level='+[string]$Method.Level;if($mt){$o+=',zstd:threads='+$Threads}
        return @('--format=gnutar','--zstd','--options',$o,'-cf')
    }
    if($a-eq'xz'){$o='xz:compression-level='+[string]$Method.Level;if($mt){$o+=',xz:threads='+$Threads};return @('--format=pax','--options',$o,'-cJf')}
    if($a-eq'zstd'){$o='zstd:compression-level='+[string]$Method.Level;if($mt){$o+=',zstd:threads='+$Threads};return @('--format=pax','--zstd','--options',$o,'-cf')}
    return @('--format=pax','-cf')
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

function Test-TarCapabilities {
    param([string]$TarPath,[string]$SafeWork)
    $root=Join-Path $SafeWork ('cap_'+[guid]::NewGuid().ToString('N'));$sample=Join-Path $root 'sample';$extract=Join-Path $root 'extract'
    [System.IO.Directory]::CreateDirectory($sample)|Out-Null;[System.IO.Directory]::CreateDirectory($extract)|Out-Null
    ('SmartTAR probe.'+('0123456789ABCDEF'*4096))|Set-Content -LiteralPath (Join-Path $sample 'sample.txt') -Encoding UTF8
    $c=@{store=$false;xz9=$false;zstd22=$false;xzThreads=$false;zstdThreads=$false}
    try{
        foreach($m in Get-TarMethods){$n=[string]$m.Name;$arc=Join-Path $root ('test_'+$n+$m.Extension);$out=Join-Path $extract $n;[System.IO.Directory]::CreateDirectory($out)|Out-Null
            $r=Invoke-TarRaw $TarPath (@(Get-TarCreateArguments $m @{} 1 $true)+@($arc,'-C',$sample,'sample.txt'))
            if([int]$r.ExitCode-eq0-and(Test-Path -LiteralPath $arc)){$u=Invoke-TarRaw $TarPath @('-xf',$arc,'-C',$out);$c[$n]=([int]$u.ExitCode-eq0-and(Test-Path -LiteralPath (Join-Path $out 'sample.txt')))}
        }
        foreach($a in @('xz','zstd')){$m=if($a-eq'xz'){Get-TarMethodByName 'xz9'}else{Get-TarMethodByName 'zstd22'};$base=if($a-eq'xz'){'xz9'}else{'zstd22'};$key=$a+'Threads';if(-not[bool]$c[$base]){continue}
            $arc=Join-Path $root ('mt_'+$a+$m.Extension);$out=Join-Path $extract ('mt_'+$a);[System.IO.Directory]::CreateDirectory($out)|Out-Null;$pc=@{xzThreads=($a-eq'xz');zstdThreads=($a-eq'zstd')}
            $r=Invoke-TarRaw $TarPath (@(Get-TarCreateArguments $m $pc 2 $false)+@($arc,'-C',$sample,'sample.txt'))
            if([int]$r.ExitCode-eq0-and(Test-Path -LiteralPath $arc)){$u=Invoke-TarRaw $TarPath @('-xf',$arc,'-C',$out);$c[$key]=([int]$u.ExitCode-eq0-and(Test-Path -LiteralPath (Join-Path $out 'sample.txt')))}
        };return $c
    }finally{Remove-SmartTarTempFolder $root}
}

function Select-TarMethod {
    param([hashtable]$Capabilities,[ValidateSet('xz9','zstd22','store')][string]$Preferred,[bool]$AllowFallback=$true)
    $order=switch($Preferred){'xz9'{@('xz9','zstd22','store')};'zstd22'{@('zstd22','xz9','store')};default{@('store')}}
    foreach($name in $order){if($Capabilities.ContainsKey($name)-and[bool]$Capabilities[$name]){return Get-TarMethodByName $name};if(-not$AllowFallback){break}}
    throw "Required PAX TAR method is unavailable: $Preferred"
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

function Test-SmartTarSourcePathExcluded {
    param([string]$Path)
    if (Test-Blank $Path) { return $false }
    $candidate=[System.IO.Path]::GetFullPath($Path).TrimEnd([char]92,[char]47)
    foreach($rootText in @($script:SourceEnumerationExcludedRoots)){
        if(Test-Blank ([string]$rootText)){continue}
        $root=[System.IO.Path]::GetFullPath([string]$rootText).TrimEnd([char]92,[char]47)
        if($candidate.Equals($root,[System.StringComparison]::OrdinalIgnoreCase)){return $true}
        if($candidate.StartsWith($root+[System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase)){return $true}
    }
    return $false
}
function New-SmartTarSourceCatalog {
    param($SourceItem,[string]$Source,[string]$BaseRoot)

    $files=New-Object System.Collections.ArrayList
    $directories=New-Object System.Collections.ArrayList
    $profile=@{
        text=[int64]0;binary=[int64]0;executable=[int64]0;diskimage=[int64]0
        media=[int64]0;archives=[int64]0;unknown=[int64]0;files=0
    }

    if(-not $SourceItem.PSIsContainer){
        $relative=Get-SafeStageRelativePath (Get-RelativePathFromBase $BaseRoot $SourceItem.FullName) ([System.IO.Path]::GetFileName($SourceItem.FullName))
        $group=Get-SmartGroupName $SourceItem.FullName
        [void]$files.Add([pscustomobject]@{File=$SourceItem;RelativePath=(Convert-ToTarPath $relative);InitialGroup=$group})
        $profile[$group]=[int64]$SourceItem.Length;$profile.files=1
        return [pscustomobject]@{Files=@($files);Directories=@();Profile=$profile}
    }

    $pending=New-Object System.Collections.Generic.Stack[string]
    $pending.Push([System.IO.Path]::GetFullPath($Source))
    while($pending.Count -gt 0){
        $current=$pending.Pop()
        foreach($directoryPath in [System.IO.Directory]::EnumerateDirectories($current)){
            if(Test-SmartTarSourcePathExcluded $directoryPath){continue}
            $directory=Get-Item -LiteralPath $directoryPath -Force -ErrorAction Stop
            $relative=Get-SafeStageRelativePath (Get-RelativePathFromBase $BaseRoot $directory.FullName) ([System.IO.Path]::GetFileName($directory.FullName))
            [void]$directories.Add([pscustomobject]@{FullPath=[string]$directory.FullName;RelativePath=(Convert-ToTarPath $relative)})
            $pending.Push($directoryPath)
        }
        foreach($filePath in [System.IO.Directory]::EnumerateFiles($current)){
            if(Test-SmartTarSourcePathExcluded $filePath){continue}
            $file=Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
            $relative=Get-SafeStageRelativePath (Get-RelativePathFromBase $BaseRoot $file.FullName) ([System.IO.Path]::GetFileName($file.FullName))
            $group=Get-SmartGroupName $file.FullName
            [void]$files.Add([pscustomobject]@{File=$file;RelativePath=(Convert-ToTarPath $relative);InitialGroup=$group})
            $profile[$group]=[int64]$profile[$group]+[int64]$file.Length;$profile.files=[int]$profile.files+1
        }
    }

    $sortedFiles=@($files|Sort-Object @{Expression={$_.RelativePath.ToLowerInvariant()}},@{Expression={$_.RelativePath}})
    $sortedDirectories=@($directories|Sort-Object @{Expression={$_.RelativePath.ToLowerInvariant()}},@{Expression={$_.RelativePath}})
    return [pscustomobject]@{Files=$sortedFiles;Directories=$sortedDirectories;Profile=$profile}
}

function Select-AutoSolidMethod {
    param([hashtable]$Capabilities, [hashtable]$Profile, $AdaptiveStats = $null)

    $xz = Select-TarMethod $Capabilities 'xz9'
    $zstd = Select-TarMethod $Capabilities 'zstd22'

    $zstdAvailable = ($Capabilities.ContainsKey('zstd22') -and $Capabilities['zstd22'])
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
    $store = Select-TarMethod $Capabilities 'store' $false
    $xz = Select-TarMethod $Capabilities 'xz9'
    $zstd = Select-TarMethod $Capabilities 'zstd22'
    $groups = [ordered]@{}
    switch ($Mode) {
        'Solid' { $groups.solid = New-GroupInfo solid (Select-AutoSolidMethod $Capabilities $Profile) 'Auto solid method.' }
        'Smart' {
            $groups.text       = New-GroupInfo text       $zstd 'Text-like data uses ZSTD22 by measured Smart max compression results.'
            $groups.binary     = New-GroupInfo binary     $zstd 'Binary data uses ZSTD22 by measured Smart max compression results.'
            $groups.executable = New-GroupInfo executable $zstd 'Executable data uses ZSTD22 by measured Smart max compression results.'
            $groups.diskimage  = New-GroupInfo diskimage  $zstd 'Disk images use ZSTD22 by Smart max compression preference.'
            $groups.media      = New-GroupInfo media      $store 'Media is stored.'
            $groups.archives   = New-GroupInfo archives   $zstd 'Archive-like data uses ZSTD22 by measured Smart max compression results.'
            $groups.unknown    = New-GroupInfo unknown    $zstd 'Unknown data uses ZSTD22 by unified Smart compression policy.'
        }
        default {
            $compressibleMethod = if ($Mode -eq 'Store') { $store } else { $xz }
            $diskimageMethod    = if ($Mode -eq 'Store') { $store } else { $zstd }
            $generalReason      = if ($Mode -eq 'Store') { 'General data stored without compression.' } else { 'General compressible data prefers XZ9.' }
            $diskReason         = if ($Mode -eq 'Store') { 'Disk images stored without compression.' } else { 'Disk images prefer ZSTD22.' }
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
# Source catalog and empty-directory structure are sealed in user TEMP before
# destination-local .stw is created. One stage, one block and one bsdtar run.

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
    $script:planItemId=[int64]0;$script:planPathToRel=@{};$script:planRelToPath=@{};$script:planFamilyKeys=@{};$script:planDedupAliases=@()
    $script:planDiagnostics=[ordered]@{enabled=$true;mode='unique-only-alias-dedup';buildWorkMode=[string]$script:buildWorkMode;catalogFiles=0;catalogBytes=[int64]0;uniqueFiles=0;uniqueBytes=[int64]0;aliasFiles=0;aliasBytes=[int64]0;dedupFamilies=0;buildFiles=0;buildBytes=[int64]0;aliasBuildSkippedFiles=0;aliasBuildSkippedBytes=[int64]0;manifestAliasCount=0;manifestAliasBytes=[int64]0;uniqueOnlyBuildEnabled=$true}
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
    param($SourceCatalog,[string]$Mode,[hashtable]$Groups)
    $script:analysisScope=Get-AnalysisScopeForMode $Mode
    $script:compressionPreference=Get-CompressionPreferenceForMode $Mode
    $profileName=Get-CompressionProfileDisplayName $Mode $script:compressionPreference
    $script:adaptiveDeepAnalyze=Test-ContentAnalysisEnabled $script:analysisScope
    $script:adaptiveStats=New-AdaptiveStats
    $script:dedupStats=New-FileDedupStats
    Set-BusyStatus "Planning blocks: $profileName..."

    $plans=@($SourceCatalog.Files)
    $analysisTargets=New-Object System.Collections.ArrayList
    foreach($plan in $plans){
        $plan|Add-Member -NotePropertyName ShouldAnalyze -NotePropertyValue ([bool](Test-ShouldAnalyzeFileContent $script:analysisScope ([string]$plan.InitialGroup))) -Force
        if([bool]$plan.ShouldAnalyze){[void]$analysisTargets.Add($plan.File)}
    }

    $analysisResults=@{}
    if($analysisTargets.Count -gt 0){
        $maxParallel=[Math]::Max(1,[int]$script:MaxParallelAnalysis)
        if($analysisTargets.Count -eq 1 -or $maxParallel -eq 1){foreach($file in $analysisTargets){$analysisResults[[string]$file.FullName]=Invoke-NativeAdaptiveAnalysis $file}}
        else{Set-BusyStatus 'Analyzing content...';$analysisResults=Invoke-ParallelAdaptiveAnalysis -Targets @($analysisTargets) -MaxParallel $maxParallel -SampleBytes ([int]$script:AdaptiveSampleBytes)}
    }

    $dedupState=@{}
    foreach($plan in $plans){
        $file=$plan.File;$smartGroup=[string]$plan.InitialGroup
        if([bool]$plan.ShouldAnalyze){
            $result=$analysisResults[[string]$file.FullName]
            if($null -eq $result){$result=[pscustomobject]@{Decision='unknown';Error=$true;SampleBytes=0;ZeroBytes=0;EntropyAvailable=$false;Entropy=0.0;UniqueAvailable=$false;UniqueBytes=0}}
            $adaptiveGroup=[string]$result.Decision;if(Test-Blank $adaptiveGroup){$adaptiveGroup='unknown'}
            Add-AdaptiveDecisionStat $adaptiveGroup ([int64]$file.Length) ([bool]$result.Error) ([int64]$result.SampleBytes) ([int64]$result.ZeroBytes) ([bool]$result.EntropyAvailable) ([double]$result.Entropy) ([bool]$result.UniqueAvailable) ([int]$result.UniqueBytes)
            $smartGroup=$adaptiveGroup
        }
        $plan|Add-Member -NotePropertyName FinalGroup -NotePropertyValue $smartGroup -Force
        $groupName=Get-ModeGroupName $Mode $smartGroup
        if(-not $Groups.Contains($groupName)){throw "Internal grouping error. Group '$groupName' does not exist for mode '$Mode'."}
        $relativePath=[string]$plan.RelativePath

        $script:planItemId=[int64]$script:planItemId+1;$planId=[int64]$script:planItemId
        Add-SmartTarPlanCatalogItem $planId $file $relativePath $groupName $smartGroup
        $linkTarget=Register-FileDedupCandidate $file $relativePath $dedupState
        Add-SmartTarPlanItems $planId $file $relativePath $groupName $linkTarget
        if($null -eq $linkTarget -or (Test-Blank ([string]$linkTarget.Path))){Add-FileToGroup $Groups[$groupName] $file.FullName $relativePath ([int64]$file.Length) ''}
    }
}

function Create-StructureStage {
    param($SourceItem,[string]$Source,[string]$BaseRoot,[string]$StageRoot,$SourceCatalog)
    $count=0;$script:BrowseIndexDirectories=@();if(-not $SourceItem.PSIsContainer){return $count}
    $sourceFallback=[System.IO.Path]::GetFileName((Trim-PathSeparators $Source))
    $rawRootRelative=Get-RelativePathFromBase $BaseRoot $Source
    if($rawRootRelative-eq'.'){$count=1}else{$rootRelative=Get-SafeStageRelativePath $rawRootRelative $sourceFallback;$script:BrowseIndexDirectories+=,(Convert-ToTarPath $rootRelative);[System.IO.Directory]::CreateDirectory((Join-Path $StageRoot (Convert-ToLocalPath $rootRelative)))|Out-Null;$count++}
    foreach($directory in @($SourceCatalog.Directories)){
        $relativePath=[string]$directory.RelativePath
        if(Test-Blank $relativePath -or -not(Test-RelativePathSafe $relativePath)){throw "Unsafe structure directory path: $relativePath"}
        $script:BrowseIndexDirectories+=,(Convert-ToTarPath $relativePath)
        [System.IO.Directory]::CreateDirectory((Join-Path $StageRoot (Convert-ToLocalPath $relativePath)))|Out-Null;$count++
    }
    return $count
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
    param([string]$TarPath,[string]$StagePath,[string]$BlockPath,[hashtable]$Method,[bool]$ForceSingleThread=$false,[ValidateSet('pax','gnutar')][string]$TarFormat='pax')
    [void](Normalize-XzStageIfNeeded $StagePath $Method)

    if ([string]$Method.Algorithm -eq 'zstd') {
        # Windows bsdtar pads binary stdout to its TAR blocking factor. Build C
        # proved that -b 1 limits this to <512 bytes and that the ZSTD frame can
        # be parsed and trimmed without changing archive contents.
        $createArgs = @(Get-TarCreateArguments $Method $script:tarCapabilities $script:CompressionThreads $ForceSingleThread $TarFormat)
        $args = @($createArgs[0..($createArgs.Count-2)]) + @('-b', '1', $createArgs[-1], '-', '-C', $StagePath, '.')
        $result = [SmartTarZstdBlockWriter]::Create($TarPath, [string[]]$args, $BlockPath)
        if ([int]$result.ExitCode -ne 0) {
            $detail = [string]$result.Error
            if (Test-Blank $detail) { $detail = 'No tar.exe error output captured.' }
            throw "Block creation failed: $BlockPath. tar.exe exit code: $($result.ExitCode)`r`n$detail"
        }
        if (-not (Test-Path -LiteralPath $BlockPath -PathType Leaf) -or [int64](Get-Item -LiteralPath $BlockPath).Length -ne [int64]$result.FrameBytes) {
            throw "ZSTD frame publication validation failed: $BlockPath"
        }
        return
    }

    Invoke-Tar $TarPath (@(Get-TarCreateArguments $Method $script:tarCapabilities $script:CompressionThreads $ForceSingleThread $TarFormat)+@($BlockPath,'-C',$StagePath,'.')) "Block creation failed: $BlockPath."
}

function New-StarBlockFromStage {
    param([string]$TarPath,[string]$StagePath,[string]$BlockPath,[hashtable]$Method,[ValidateSet('pax','gnutar')][string]$TarFormat='pax')
    $mt=($script:CompressionThreads-gt1-and(Test-TarThreadingSupported $script:tarCapabilities ([string]$Method.Algorithm)))
    try{Create-BlockFromStageDirect $TarPath $StagePath $BlockPath $Method $false $TarFormat}catch{if(-not$mt){throw};$first=Get-ErrorDetails $_;$script:MultithreadCompatibilityRetries++;Remove-Item -LiteralPath $BlockPath -Force -ErrorAction SilentlyContinue
        try{Create-BlockFromStageDirect $TarPath $StagePath $BlockPath $Method $true $TarFormat}catch{throw "Multithread failed:`r`n$first`r`nSingle-thread retry failed:`r`n$(Get-ErrorDetails $_)"}}
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
        [int64]$SourceBytes,
        [ValidateSet('pax','gnutar')][string]$TarFormat='pax'
    )

    $item = Get-Item -LiteralPath $BlockPath
    $name = [System.IO.Path]::GetFileName($BlockPath)

    $List.Value += [ordered]@{
        id          = $BlockId
        group       = $GroupName
        path        = "blocks/$name"
        method      = [string]$Method.Name
        display     = [string]$Method.Display
        tarFormat   = $TarFormat
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
    param($Manifest,[int64]$TruncateOffset,[string]$CatalogPath='')
    if($null -eq $Manifest){throw 'Manifest object is missing.'}
    if($TruncateOffset -le 0 -or ($TruncateOffset % 512) -ne 0){throw "Invalid canonical STAR truncate offset: $TruncateOffset"}
    $layout=if(Test-Blank $CatalogPath){
        [ordered]@{schema=1;mode='replaceable-tail-manifest';manifestEntry='manifest.json';manifestPosition='last';truncateOffset=$TruncateOffset;alignmentBytes=512}
    }else{
        [ordered]@{schema=2;mode='replaceable-catalog-manifest-tail';catalogEntry=(Convert-ToTarPath $CatalogPath);manifestEntry='manifest.json';catalogPosition='before-manifest';manifestPosition='last';truncateOffset=$TruncateOffset;alignmentBytes=512}
    }
    if($Manifest -is [System.Collections.IDictionary]){$Manifest['outerLayout']=$layout}
    else{$Manifest|Add-Member -NotePropertyName outerLayout -NotePropertyValue ([pscustomobject]$layout) -Force}
}

function Test-StarCanonicalTailLayout {
    param([string]$ArchivePath,$Manifest)
    if($null -eq $Manifest -or $null -eq $Manifest.outerLayout){throw 'STAR archive does not contain canonical tail metadata required for ADD.'}
    $layout=$Manifest.outerLayout;$schema=[int]$layout.schema;$mode=[string]$layout.mode
    $offset=[int64]$layout.truncateOffset
    if($offset -le 0 -or ($offset % 512) -ne 0){throw "Unsafe STAR truncate offset: $offset"}
    $scan=Get-StarOuterTarLayout $ArchivePath
    if([int]$scan.ManifestCount -ne 1){throw "Canonical STAR must contain exactly one manifest.json entry; found $($scan.ManifestCount)."}
    if([string]$scan.LastEntryPath -ne 'manifest.json'){throw "Canonical STAR manifest is not the last logical entry: $($scan.LastEntryPath)"}
    if($schema -eq 1 -and $mode -eq 'replaceable-tail-manifest'){
        if([int64]$scan.ManifestRecordStart -ne $offset){throw "Canonical STAR truncate offset mismatch. Manifest=$offset, actual=$($scan.ManifestRecordStart)."}
    }elseif($schema -eq 2 -and $mode -eq 'replaceable-catalog-manifest-tail'){
        $catalogPath=(Convert-ToTarPath ([string]$layout.catalogEntry)).Trim('/').Trim()
        if(Test-Blank $catalogPath){throw 'Canonical STAR catalog entry is missing.'}
        $catalogEntries=@($scan.Entries|Where-Object{([string]$_.Path).Trim('/').Equals($catalogPath,[System.StringComparison]::OrdinalIgnoreCase)})
        if($catalogEntries.Count-ne1){throw "Canonical STAR must contain exactly one active catalog entry; found $($catalogEntries.Count)."}
        $catalogEntry=$catalogEntries[0]
        if([int64]$catalogEntry.RecordStart-ne$offset){throw "Canonical STAR truncate offset does not point to catalog. Expected=$offset, actual=$($catalogEntry.RecordStart)."}
        if([int64]$scan.ManifestRecordStart-le[int64]$catalogEntry.RecordStart){throw 'Canonical STAR manifest does not follow the catalog.'}
    }else{throw 'Unsupported STAR canonical tail layout.'}
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

function Set-StarObjectProperty {
    param($Object,[string]$Name,$Value)
    if($Object -is [System.Collections.IDictionary]){$Object[$Name]=$Value}
    else{$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force}
}

function Remove-StarObjectProperty {
    param($Object,[string]$Name)
    if($null-eq$Object){return}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){$Object.Remove($Name)}}
    elseif($null-ne$Object.PSObject.Properties[$Name]){$Object.PSObject.Properties.Remove($Name)}
}

function New-StarCatalogPayload {
    param($Manifest)
    $aliasRows=New-Object System.Collections.ArrayList
    foreach($a in @($Manifest.dedupAliases)){[void]$aliasRows.Add(@([string]$a.path,[string]$a.target,[int64]$a.bytes))}
    return [ordered]@{
        schema=1
        browseIndex=$Manifest.browseIndex
        aliases=@($aliasRows)
        aliasMode=if(Test-Blank ([string]$Manifest.dedupAliasMode)){'unique-only-restored-on-extract'}else{[string]$Manifest.dedupAliasMode}
        contentRoots=@($Manifest.contentRoots)
        addHistory=@($Manifest.addHistory)
    }
}

function Add-StarCatalogToManifest {
    param($Manifest,$Catalog)
    Set-StarObjectProperty $Manifest 'browseIndex' $Catalog.browseIndex
    $aliases=New-Object System.Collections.ArrayList
    foreach($rowValue in @($Catalog.aliases)){$row=@($rowValue);if($row.Count-lt2){throw 'Invalid compact catalog alias row.'};$bytes=if($row.Count-gt2){[int64]$row[2]}else{[int64]0};[void]$aliases.Add([pscustomobject]@{path=[string]$row[0];target=[string]$row[1];bytes=$bytes})}
    Set-StarObjectProperty $Manifest 'dedupAliases' @($aliases)
    $catalogAliasMode=if(Test-Blank ([string]$Catalog.aliasMode)){'unique-only-restored-on-extract'}else{[string]$Catalog.aliasMode}
    Set-StarObjectProperty $Manifest 'dedupAliasMode' $catalogAliasMode
    Set-StarObjectProperty $Manifest 'contentRoots' @($Catalog.contentRoots)
    Set-StarObjectProperty $Manifest 'addHistory' @($Catalog.addHistory)
    return $Manifest
}

function Remove-StarCatalogPayloadFromManifest {
    param($Manifest)
    foreach($name in @('browseIndex','dedupAliases','dedupAliasMode','contentRoots','addHistory')){Remove-StarObjectProperty $Manifest $name}
}

function Test-StarCatalogConsistency {
    param($Manifest)
    if($null-eq$Manifest.browseIndex){throw 'STAR catalog browse index is missing.'}
    if([int]$Manifest.browseIndex.schema-ne2){throw 'Unsupported STAR browse index schema.'}
    $roots=@($Manifest.browseIndex.roots);$virtual=@($Manifest.browseIndex.virtualRoots)
    if($roots.Count-lt1){throw 'STAR catalog has no browse roots.'}
    $blockIds=@{};foreach($b in @($Manifest.blocks)){if(Test-Blank ([string]$b.id)){throw 'STAR block ID is empty.'};$blockIds[([string]$b.id).ToLowerInvariant()]=$b}
    $physical=@{};$physicalCount=0
    foreach($ib in @($Manifest.browseIndex.blocks)){
        $id=[string]$ib.id;$key=$id.ToLowerInvariant();if(-not$blockIds.ContainsKey($key)){throw "Catalog references missing block ID: $id"}
        $rootId=[int]$ib.root;if($rootId-lt0-or$rootId-ge$roots.Count){throw "Catalog block $id has an invalid root index."}
        $root=(Convert-ToTarPath ([string]$roots[$rootId])).Trim('/').Trim();$isVirtual=($rootId-lt$virtual.Count-and[bool]$virtual[$rootId])
        $files=@($ib.files);if($files.Count-ne[int]$blockIds[$key].fileCount){throw "Catalog file count differs from block $id."}
        foreach($pathValue in $files){$rel=(Convert-ToTarPath ([string]$pathValue)).Trim('/').Trim();if(Test-Blank $rel-or-not(Test-RelativePathSafe $rel)){throw "Unsafe catalog file path: $rel"};$stored=if($isVirtual){$rel}else{$root+'/'+$rel};$pk=$stored.ToLowerInvariant();if($physical.ContainsKey($pk)){throw "Duplicate physical path in STAR catalog: $stored"};$physical[$pk]=$true;$physicalCount++}
    }
    if($null-ne$Manifest.summary-and$null-ne$Manifest.summary.uniqueFiles-and$physicalCount-ne[int]$Manifest.summary.uniqueFiles){throw "Catalog unique file total mismatch. Expected=$($Manifest.summary.uniqueFiles), actual=$physicalCount."}
    $aliasPaths=@{};foreach($a in @($Manifest.dedupAliases)){$p=(Convert-ToTarPath ([string]$a.path)).Trim('/').Trim();if(Test-Blank $p-or-not(Test-RelativePathSafe $p)){throw "Unsafe catalog alias path: $p"};$aliasPaths[$p.ToLowerInvariant()]=$true}
    foreach($a in @($Manifest.dedupAliases)){$p=(Convert-ToTarPath ([string]$a.path)).Trim('/').Trim();$t=(Convert-ToTarPath ([string]$a.target)).Trim('/').Trim();if(Test-Blank $t-or-not(Test-RelativePathSafe $t)){throw "Unsafe catalog alias target: $t"};if($aliasPaths.ContainsKey($t.ToLowerInvariant())){throw "Catalog alias chain is not allowed: $p -> $t"};if(-not$physical.ContainsKey($t.ToLowerInvariant())){throw "Catalog alias target is absent from physical files: $t"}}
    return $true
}
function Publish-StarCatalogAndManifest {
    param([string]$TarPath,[string]$OuterArchivePath,[string]$WorkRoot,$Manifest,[int64]$TruncateOffset)
    $payload=New-StarCatalogPayload $Manifest
    [void](Test-StarCatalogConsistency $Manifest)
    $catalogStage=Join-Path $WorkRoot ('catalog_stage_'+[guid]::NewGuid().ToString('N').Substring(0,8));[System.IO.Directory]::CreateDirectory($catalogStage)|Out-Null
    $catalogJson=Join-Path $catalogStage 'index.json'
    $payload|ConvertTo-Json -Depth 40 -Compress|Set-Content -LiteralPath $catalogJson -Encoding UTF8
    $contentBytes=[int64](Get-Item -LiteralPath $catalogJson).Length;$contentSha=Get-FileSHA256 $catalogJson
    $method=Select-TarMethod $script:tarCapabilities 'zstd22'
    $catalogName='star-index'+[string]$method.Extension;$catalogFile=Join-Path $WorkRoot $catalogName
    Create-BlockFromStageDirect $TarPath $catalogStage $catalogFile $method
    $relative=$catalogName;$catalogInfo=[ordered]@{schema=1;path=$relative;entry='index.json';container='pax-tar';method=[string]$method.Name;display=[string]$method.Display;sizeBytes=[int64](Get-Item -LiteralPath $catalogFile).Length;sha256=Get-FileSHA256 $catalogFile;contentBytes=$contentBytes;contentSha256=$contentSha}
    Remove-StarCatalogPayloadFromManifest $Manifest
    Set-StarObjectProperty $Manifest 'catalog' $catalogInfo
    Set-ManifestCanonicalOuterLayout $Manifest $TruncateOffset $relative
    Add-StarOuterEntry $TarPath $OuterArchivePath $WorkRoot $relative 'Outer STAR catalog append failed.'
    Write-Manifest (Join-Path $WorkRoot 'manifest.json') $Manifest
    Add-StarOuterEntry $TarPath $OuterArchivePath $WorkRoot 'manifest.json' 'Outer STAR manifest append failed.'
    [void](Test-StarCanonicalTailLayout $OuterArchivePath $Manifest)
    Remove-SmartTarTempFolder $catalogStage
    return $Manifest
}

function Read-StarArchiveManifest {
    param([string]$TarPath,[string]$ArchivePath,[string]$OuterRoot)
    [System.IO.Directory]::CreateDirectory($OuterRoot)|Out-Null
    $manifestPath=Join-Path $OuterRoot 'manifest.json'
    if(-not(Test-Path -LiteralPath $manifestPath)){Invoke-Tar $TarPath @('-xf',$ArchivePath,'-C',$OuterRoot,'manifest.json') 'Outer manifest extraction failed.'}
    $manifest=Read-OuterManifest $OuterRoot
    if($null-eq$manifest.catalog){return $manifest}
    $relative=(Convert-ToTarPath ([string]$manifest.catalog.path)).Trim('/').Trim();if(Test-Blank $relative-or-not(Test-RelativePathSafe $relative)){throw "Unsafe STAR catalog path: $relative"}
    $catalogFile=Join-Path $OuterRoot (Convert-ToLocalPath $relative)
    if(-not(Test-Path -LiteralPath $catalogFile)){Invoke-Tar $TarPath @('-xf',$ArchivePath,'-C',$OuterRoot,$relative) 'Outer catalog extraction failed.'}
    if(-not(Test-Path -LiteralPath $catalogFile -PathType Leaf)){throw 'STAR catalog file is missing.'}
    if([int64]$manifest.catalog.sizeBytes-ne[int64](Get-Item -LiteralPath $catalogFile).Length){throw 'STAR catalog compressed size mismatch.'}
    if((Get-FileSHA256 $catalogFile)-ne([string]$manifest.catalog.sha256).ToLowerInvariant()){throw 'STAR catalog SHA256 mismatch.'}
    $catalogOut=Join-Path $OuterRoot ('catalog_read_'+[guid]::NewGuid().ToString('N').Substring(0,8));[System.IO.Directory]::CreateDirectory($catalogOut)|Out-Null
    $entry=if(Test-Blank ([string]$manifest.catalog.entry)){'index.json'}else{[string]$manifest.catalog.entry}
    Invoke-Tar $TarPath @('-xf',$catalogFile,'-C',$catalogOut) 'STAR catalog decompression failed.'
    $indexPath=Join-Path $catalogOut (Convert-ToLocalPath $entry);if(-not(Test-Path -LiteralPath $indexPath -PathType Leaf)){throw 'STAR catalog index entry is missing.'}
    if([int64]$manifest.catalog.contentBytes-ne[int64](Get-Item -LiteralPath $indexPath).Length){throw 'STAR catalog content size mismatch.'}
    if((Get-FileSHA256 $indexPath)-ne([string]$manifest.catalog.contentSha256).ToLowerInvariant()){throw 'STAR catalog content SHA256 mismatch.'}
    $catalog=Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$catalog.schema-ne1){throw "Unsupported STAR catalog schema: $($catalog.schema)"}
    [void](Add-StarCatalogToManifest $manifest $catalog);[void](Test-StarCatalogConsistency $manifest)
    return $manifest
}

function Test-StarOuterBlockHashes {
    param([string]$TarPath,[string]$ArchivePath,$Blocks,[string]$WorkRoot)
    $check=Join-Path $WorkRoot ('block_hash_check_'+[guid]::NewGuid().ToString('N').Substring(0,8));[System.IO.Directory]::CreateDirectory($check)|Out-Null
    try{
        foreach($block in @($Blocks)){
            $relative=(Convert-ToTarPath ([string]$block.path)).Trim('/').Trim();if(Test-Blank $relative-or-not(Test-RelativePathSafe $relative)){throw "Unsafe incremental block path: $relative"}
            Invoke-Tar $TarPath @('-xf',$ArchivePath,'-C',$check,$relative) "Incremental block read failed: $relative."
            $file=Join-Path $check (Convert-ToLocalPath $relative);if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Incremental block is missing after outer read: $relative"}
            if([int64](Get-Item -LiteralPath $file).Length-ne[int64]$block.sizeBytes){throw "Incremental block size mismatch: $relative"}
            if((Get-FileSHA256 $file)-ne([string]$block.sha256).ToLowerInvariant()){throw "Incremental block SHA256 mismatch: $relative"}
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        return $true
    }finally{Remove-SmartTarTempFolder $check}
}

function Get-StarFastSummary {
    param([string]$TarPath,[string]$ArchivePath,[string]$Action='Add')
    $work=New-SafeWorkRoot 'fast_summary' $ArchivePath;$outer=Join-Path $work 'outer'
    try{$m=Read-StarArchiveManifest $TarPath $ArchivePath $outer;[void](Test-StarCanonicalTailLayout $ArchivePath $m);$r=@('')*32;$r[0]=$Action;$r[1]='Archive updated successfully.';$r[3]=Format-Bytes ([int64](Get-Item -LiteralPath $ArchivePath).Length);$r[10]=[string]$m.format;$r[11]=Get-ReportVersionNumber ([string]$m.toolVersion);$r[12]=[string]$m.compressionProfile;$r[13]=[string]$m.compressionMode;$r[14]=[string]@($m.blocks).Count;$r[15]='n/a (incremental)';$r[16]='0';$r[17]='INCREMENTAL OK';$r[20]=[string]$ArchivePath;$r[25]=Format-GroupDiagnostics $m;$r[26]=Format-CompressionMethodSummary $m;$r[27]=Format-AdaptiveDiagnostics $m;$r[28]="`r`n`r`nCatalog integrity: OK`r`nCatalog path: $($m.catalog.path)`r`nCatalog SHA256: $($m.catalog.sha256)";return $r}finally{Remove-SmartTarWorkAndRoot $work}
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
    param([string]$TarPath,[string]$OuterArchivePath,[string]$WorkRoot,[ref]$Blocks,[string]$BlockId,[string]$GroupName,[string]$BlockPath,[hashtable]$Method,[string]$Reason,[int]$FileCount,[int]$DirCount,[int64]$SourceBytes,[ValidateSet('pax','gnutar')][string]$TarFormat='pax')
    if (Test-Blank $BlockPath -or -not (Test-Path -LiteralPath $BlockPath)) { throw "Block file does not exist before publish: $BlockPath" }
    $relativeBlock = 'blocks/' + [System.IO.Path]::GetFileName($BlockPath)
    Set-BusyStatus "Publishing block $BlockId $GroupName into STAR..."
    Add-StarOuterEntry $TarPath $OuterArchivePath $WorkRoot $relativeBlock 'Outer .star block append failed.'
    Set-BusyStatus "Confirming published block $BlockId $GroupName..."
    if (-not (Test-StarOuterEntryExists $TarPath $OuterArchivePath $relativeBlock)) {
        throw "Published block was not found in outer STAR archive: $relativeBlock"
    }
    Add-BlockManifestItem $Blocks $BlockId $GroupName $BlockPath $Method $Reason $FileCount $DirCount $SourceBytes $TarFormat
    Remove-Item -LiteralPath $BlockPath -Force -ErrorAction SilentlyContinue
}

function Complete-StarOuterArchive {
    param([string]$TempArchive, [string]$Destination)
    if (Test-Blank $TempArchive -or -not (Test-Path -LiteralPath $TempArchive)) { throw 'STAR temp archive does not exist.' }
    if (Test-Blank $Destination) { throw 'Destination archive path is empty.' }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Move-Item -LiteralPath $TempArchive -Destination $Destination -Force
}

function Publish-StarStageBlock {
    param([string]$TarPath,[string]$StagePath,[string]$BlockPath,[hashtable]$Method,[string]$OuterArchivePath,[string]$WorkRoot,[ref]$Blocks,[string]$BlockId,[string]$GroupName,[string]$Reason,[int]$FileCount,[int]$DirCount,[int64]$SourceBytes,[ValidateSet('pax','gnutar')][string]$TarFormat='pax')
    New-StarBlockFromStage $TarPath $StagePath $BlockPath $Method $TarFormat
    Add-BlockToStarOuterAndCleanup $TarPath $OuterArchivePath $WorkRoot $Blocks $BlockId $GroupName $BlockPath $Method $Reason $FileCount $DirCount $SourceBytes $TarFormat
}

function Build-AndPublishBlocksSequential {
    param([string]$TarPath,[hashtable]$Groups,[string]$BlocksDir,[string]$WorkRoot,[string]$StructureStage,[int]$StructureDirCount,[hashtable]$StoreMethod,[bool]$AllowGroupCopyFallback,[string]$OuterArchivePath,[int]$StartIndex=1,[string]$BlockSuffix='')
    $blocks=@();$index=[Math]::Max(1,$StartIndex);$script:lastGroupDiagnostics=@();$script:BrowseIndexBlocks=@()
    if($StructureDirCount-gt0){$id='{0:D6}'-f$index;$method=Select-TarMethod $script:tarCapabilities 'zstd22';$blockPath=Join-Path $BlocksDir ("$id`_structure$BlockSuffix$($method.Extension)")
        try{Publish-StarStageBlock $TarPath $StructureStage $blockPath $method $OuterArchivePath $WorkRoot ([ref]$blocks) $id 'structure' 'Directory structure block uses GNU TAR with ZSTD22; sequential scheduler.' 0 $StructureDirCount 0 'gnutar';$index++}finally{Remove-SmartTarTempFolder $StructureStage}}
    foreach($name in $Groups.Keys){$g=$Groups[$name];if([int]$g.FileCount-le0){continue};$id='{0:D6}'-f$index;$stage=$null;$blockPath=Join-Path $BlocksDir ("$id`_$($g.Name)$BlockSuffix$($g.Method.Extension)")
        try{$stage=New-GroupHardlinkStage $WorkRoot @($g.Files) $AllowGroupCopyFallback;Test-SmartTarPreparedStage $stage $g;Publish-StarStageBlock $TarPath $stage $blockPath $g.Method $OuterArchivePath $WorkRoot ([ref]$blocks) $id ([string]$g.Name) ([string]$g.Reason+' one-stage sequential block.') ([int]$g.FileCount) 0 ([int64]$g.Bytes);$script:BrowseIndexBlocks+=,[ordered]@{id=$id;files=@($g.Files|ForEach-Object{(Convert-ToTarPath ([string]$_.Rel)).Trim('/').Trim()})};$index++}finally{Remove-SmartTarTempFolder $stage}}
    return $blocks
}

function Test-PlannedDedupAliases {
    param([hashtable]$Groups)
    $physical=@{}
    foreach($n in $Groups.Keys){foreach($f in @($Groups[$n].Files)){$rel=(Convert-ToTarPath([string]$f.Rel)).Trim('/').Trim();$key=$rel.ToLowerInvariant();if($physical.ContainsKey($key)){throw "Duplicate physical archive path in block plan: $rel"};$physical[$key]=[int64]$f.Bytes}}
    foreach($a in @($script:planDedupAliases)){$p=(Convert-ToTarPath([string]$a.path)).Trim('/').Trim();$t=(Convert-ToTarPath([string]$a.target)).Trim('/').Trim();if(Test-Blank $t-or-not(Test-RelativePathSafe $t)){throw "Unsafe planned dedup target: $t"};$k=$t.ToLowerInvariant();if(-not$physical.ContainsKey($k)){throw "Planned dedup target is not a physical block member: $t"};if([int64]$physical[$k]-ne[int64]$a.bytes){throw "Planned dedup target size mismatch: $p -> $t. Alias=$($a.bytes), target=$($physical[$k])."}}
}

function Convert-ToSmartTarRootRelative {
    param([string]$Root,[string]$Path,[bool]$StoredPathsAreRootRelative=$false)
    $r=(Convert-ToTarPath $Root).Trim('/').Trim();$p=(Convert-ToTarPath $Path).Trim('/').Trim()
    if($StoredPathsAreRootRelative){return $p}
    if($p.Equals($r,[System.StringComparison]::OrdinalIgnoreCase)){return ''}
    $prefix=$r+'/'
    if($p.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)){return $p.Substring($prefix.Length)}
    throw "Browse index path '$p' is outside root '$r'."
}
function New-SmartTarBrowseIndex {
    param([string]$Root,$Directories,$BlockEntries,$Aliases,[bool]$StoredPathsAreRootRelative=$false)
    $rootPath=(Convert-ToTarPath $Root).Trim('/').Trim();if(Test-Blank $rootPath-or-not(Test-RelativePathSafe $rootPath)){throw "Invalid Browse root: $rootPath"}
    $ancestorSet=@{};$blocks=New-Object System.Collections.ArrayList
    foreach($entry in @($BlockEntries)){
        $files=New-Object System.Collections.ArrayList
        foreach($full in @($entry.files)){$rel=Convert-ToSmartTarRootRelative $rootPath ([string]$full) $StoredPathsAreRootRelative;if(Test-Blank $rel-or-not(Test-RelativePathSafe $rel)){throw "Invalid Browse file path: $rel"};[void]$files.Add($rel);$parent=$rel;while($parent.Contains('/')){$parent=$parent.Substring(0,$parent.LastIndexOf('/'));$ancestorSet[$parent.ToLowerInvariant()]=$true}}
        [void]$blocks.Add([ordered]@{id=[string]$entry.id;root=0;files=@($files)})
    }
    foreach($alias in @($Aliases)){$rel=Convert-ToSmartTarRootRelative $rootPath ([string]$alias.path) $StoredPathsAreRootRelative;$parent=$rel;while($parent.Contains('/')){$parent=$parent.Substring(0,$parent.LastIndexOf('/'));$ancestorSet[$parent.ToLowerInvariant()]=$true}}
    $empty=New-Object System.Collections.ArrayList;$seen=@{}
    foreach($fullDir in @($Directories)){$rel=Convert-ToSmartTarRootRelative $rootPath ([string]$fullDir) $StoredPathsAreRootRelative;if(Test-Blank $rel){continue};$key=$rel.ToLowerInvariant();if(-not$seen.ContainsKey($key)-and-not$ancestorSet.ContainsKey($key)){[void]$empty.Add(@(0,$rel));$seen[$key]=$true}}
    return [ordered]@{schema=2;roots=@($rootPath);virtualRoots=@([bool]$StoredPathsAreRootRelative);blocks=@($blocks);emptyDirectories=@($empty)}
}

function Build-Manifest {
    param([string]$Source,$SourceItem,[string]$SourceLeaf,[string]$Mode,[hashtable]$Capabilities,[hashtable]$Profile,$Blocks)
    $profileName = Get-CompressionProfileDisplayName $Mode ([string]$script:compressionPreference)
    $storedUniqueBytes = [int64]0
    foreach ($block in @($Blocks)) { if ([string]$block.group -ne 'structure') { $storedUniqueBytes += [int64]$block.sourceBytes } }
    $aliasBytes = [int64]0
    foreach ($alias in @($script:planDedupAliases)) { $aliasBytes += [int64]$alias.bytes }
    $summary = [ordered]@{ storedUniqueBytes = $storedUniqueBytes; catalogFiles = if ($null -ne $script:planDiagnostics) { [int]$script:planDiagnostics.catalogFiles } else { 0 }; uniqueFiles = if ($null -ne $script:planDiagnostics) { [int]$script:planDiagnostics.uniqueFiles } else { 0 }; aliasFiles = @($script:planDedupAliases).Count; dedupAliasCount = @($script:planDedupAliases).Count; dedupAliasBytes = $aliasBytes }
    $isDriveRoot=[bool]$script:CurrentSourceIsDriveRoot
    $browseIndex=New-SmartTarBrowseIndex $SourceLeaf $script:BrowseIndexDirectories $script:BrowseIndexBlocks $script:planDedupAliases $isDriveRoot
    $manifest = [ordered]@{ format = $script:FormatName; formatVersion = $script:FormatVersion; tool = 'SmartTAR'; toolVersion = $script:ToolVersion; createdUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); sourceName = $SourceLeaf; sourceType = if ($isDriveRoot) { 'DriveRoot' } elseif ($SourceItem.PSIsContainer) { 'Folder' } else { 'File' }; sourceBytes = Get-SourceSize $Source; compressionMode = $Mode; compressionProfile = $profileName; build = [ordered]@{ workrootMode = [string]$script:buildWorkMode; pipeline = 'sequential-one-stage-one-bsdtar'; blockCleanup = 'after-append'; catalogPosition = 'before-manifest'; manifestPosition = 'last-outer-entry'; outerTarFormat = 'pax'; innerTarFormat = 'mixed:structure=gnutar,data=pax' }; summary = $summary; browseIndex=$browseIndex; dedupAliasMode = 'unique-only-restored-on-extract'; dedupAliases = @($script:planDedupAliases); blocks = @($Blocks) }
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
        $manifest=Read-StarArchiveManifest $TarPath $safeArchive $outer
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
        elseif($sourceType-eq'DriveRoot'){
        if(Test-Blank $rootName){$rootName=Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath}
        [void]$targets.Add([pscustomobject]@{Kind='DriveRoot container';Path=(Join-Path $DestinationParent $rootName)})
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
        $rawAddGuardCreated=$false
        if(-not$rawAddExistedBefore){
            [System.IO.Directory]::CreateDirectory($rawAddTarget)|Out-Null
            try{(Get-Item -LiteralPath $rawAddTarget -Force).Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::Hidden}catch{}
            $rawAddGuardCreated=$true
        }
        $primarySource=Join-Path $PayloadRoot (Convert-ToLocalPath $rootName)
        $primaryTarget=Join-Path $DestinationParent $rootName
        if(Test-Path -LiteralPath $primarySource){
            [System.IO.Directory]::CreateDirectory($primaryTarget)|Out-Null;Copy-DirectoryContents $primarySource $primaryTarget
        }else{
            $primaryIsVirtual=($null-ne$Manifest.browseIndex-and$null-ne$Manifest.browseIndex.virtualRoots-and@($Manifest.browseIndex.virtualRoots).Count-gt0-and[bool]@($Manifest.browseIndex.virtualRoots)[0])
            if($primaryIsVirtual){
                [System.IO.Directory]::CreateDirectory($primaryTarget)|Out-Null
                foreach($item in @(Get-ChildItem -LiteralPath $PayloadRoot -Force -ErrorAction Stop)){
                    if([string]$item.Name -ieq 'ADD'){continue};$target=Join-Path $primaryTarget ([string]$item.Name)
                    if($item.PSIsContainer){[System.IO.Directory]::CreateDirectory($target)|Out-Null;Copy-DirectoryContents $item.FullName $target}else{Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop}
                }
            }
        }
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
        if($rawAddGuardCreated -and (Test-Path -LiteralPath $rawAddTarget -PathType Container)){Remove-Item -LiteralPath $rawAddTarget -Recurse -Force -ErrorAction Stop}
        if(-not(Test-Path -LiteralPath $primaryTarget)){throw 'Multi-root extraction did not create the primary destination.'}
        if(Test-Path -LiteralPath $addSource){$expectedAddTarget=Join-Path $DestinationParent ($rootName+'_ADD');if(-not(Test-Path -LiteralPath $expectedAddTarget)){throw 'Multi-root extraction did not create the ADD destination.'}}
        return
    }
    if(($sourceType -eq 'DriveRoot' -or $sourceType -eq 'Folder') -and -not(Test-Blank $rootName)){
        $safeRootLeaf=Split-Path -Leaf (Convert-ToLocalPath $rootName)
        if(Test-Blank $safeRootLeaf){$safeRootLeaf=Get-ArchiveBaseNameWithoutSmartExtension $ArchivePath}
        if(Test-Blank $safeRootLeaf){$safeRootLeaf='SmartTAR_Root'}
        $finalRoot=Join-Path $DestinationParent $safeRootLeaf
        [System.IO.Directory]::CreateDirectory($finalRoot)|Out-Null
        $rootInPayload=Join-Path $PayloadRoot (Convert-ToLocalPath $rootName)
        if(Test-Path -LiteralPath $rootInPayload -PathType Container){Copy-DirectoryContents $rootInPayload $finalRoot}else{Copy-DirectoryContents $PayloadRoot $finalRoot}
        if(-not(Test-Path -LiteralPath $finalRoot -PathType Container)){throw "Extraction did not create named source root: $safeRootLeaf"}
        return
    }
    Copy-DirectoryContents $PayloadRoot $DestinationParent
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
        $manifest = Read-StarArchiveManifest $TarPath $ArchivePath $outer
        $r[10]=[string]$manifest.format; $r[11]=Get-ReportVersionNumber ([string]$manifest.toolVersion); $r[12]=[string]$manifest.compressionProfile; $r[13]=[string]$manifest.compressionMode; $r[14]=[string]@($manifest.blocks).Count
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
 try{$m=Read-StarArchiveManifest $TarPath $ArchivePath $o;$bs=@($m.blocks);$ok=0;$fail=0;$lines=@()
 foreach($b in $bs){Set-BusyStatus "Verifying streamed block $($b.id) $($b.group)...";try{[void](Invoke-SmartTarStreamWholeBlock $TarPath $ArchivePath $b $p);$ok++}catch{$fail++;$lines+="FAIL: $($b.id) $($b.group) $($b.path)`r`n$([string]$_.Exception.Message)"}}
 $ac=Test-DedupAliasesForManifest $m $p;if([int]$ac.failed-gt 0){$fail+=[int]$ac.failed;foreach($d in @($ac.details)){$lines+="DEDUP ALIAS FAIL: $d"}};$ver=if($fail-eq 0){'OK'}else{'FAILED'}
 $r[10]=[string]$m.format;$r[11]=Get-ReportVersionNumber ([string]$m.toolVersion);$r[12]=[string]$m.compressionProfile;$r[13]=[string]$m.compressionMode;$r[14]=[string]$bs.Count;$r[15]=[string]$ok;$r[16]=[string]$fail;$r[17]=$ver;$r[25]=Format-GroupDiagnostics $m;$r[26]=Format-CompressionMethodSummary $m;$r[27]=Format-AdaptiveDiagnostics $m
 if(@($m.dedupAliases).Count-gt 0){$r[28]+="`r`n`r`nDedup alias verification:`r`nAliases: $($ac.total), OK: $($ac.ok), failed: $($ac.failed)"};if($fail-gt 0-and$lines.Count-gt 0){$r[28]+="`r`n`r`nFailed verification details:`r`n"+($lines-join"`r`n")};return $r}finally{Remove-SmartTarWorkAndRoot $w}
}


function Add-SmartArchiveBrowseEntry {
    param(
        [hashtable]$Entries,
        [string]$RelativePath,
        [bool]$IsFolder,
        [string]$BlockPath = '',
        [string]$AliasTarget = '',
        [string]$StoredPath = ''
    )

    $rel = (Convert-ToTarPath ([string]$RelativePath)).Trim()
    if (Test-Blank $rel) { return }
    $rel = $rel.TrimStart([char]46, [char]47)
    $rel = $rel.TrimEnd([char]47)
    if (Test-Blank $rel) { return }
    if (-not (Test-RelativePathSafe $rel)) { return }

    $parts = @($rel.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $storedFinal=(Convert-ToTarPath ([string]$StoredPath)).Trim('/').Trim()
    $displayPrefixCount=0
    if(-not(Test-Blank $storedFinal)){$storedParts=@($storedFinal.Split('/')|Where-Object{-not[string]::IsNullOrWhiteSpace($_)});$displayPrefixCount=[Math]::Max(0,$parts.Count-$storedParts.Count)}
    $current = ''
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $current = if (Test-Blank $current) { [string]$parts[$i] } else { $current + '/' + [string]$parts[$i] }
        $currentStored=if(Test-Blank $storedFinal){$current}elseif($i-lt$displayPrefixCount){''}else{(@($parts[$displayPrefixCount..$i])-join '/')}
        $isCurrentFolder = if ($i -lt ($parts.Count - 1)) { $true } else { [bool]$IsFolder }
        $key = $current.ToLowerInvariant()
        if (-not $Entries.ContainsKey($key)) {
            $Entries[$key] = [pscustomobject]@{
                Rel         = $current
                IsFolder    = [bool]$isCurrentFolder
                Blocks      = New-Object System.Collections.ArrayList
                AliasTarget = ''
                StoredRel    = $currentStored
            }
        }
        elseif ($isCurrentFolder) {
            $Entries[$key].IsFolder = $true
        }
        if(-not(Test-Blank $currentStored)){$Entries[$key].StoredRel=$currentStored}

        if (-not (Test-Blank $BlockPath) -and -not $Entries[$key].Blocks.Contains($BlockPath)) {
            [void]$Entries[$key].Blocks.Add($BlockPath)
        }
        if($i-eq($parts.Count-1)){
            if(-not(Test-Blank $StoredPath)){$Entries[$key].StoredRel=(Convert-ToTarPath $StoredPath).Trim('/').Trim()}
            if(-not(Test-Blank $AliasTarget)){$Entries[$key].AliasTarget=(Convert-ToTarPath $AliasTarget).Trim('/').Trim()}
        }
    }
}

function Get-SmartArchiveBrowseIndexEntries {
    param($Manifest)
    if($null-eq$Manifest.browseIndex-or[int]$Manifest.browseIndex.schema-ne2){return $null}
    try{
        $entries=@{};$roots=@($Manifest.browseIndex.roots);$blockById=@{};$physical=@{};$physicalCount=0
        if($roots.Count-lt1){throw 'Browse index has no roots.'}
        foreach($rootValue in $roots){$root=(Convert-ToTarPath ([string]$rootValue)).Trim('/').Trim();if(Test-Blank $root-or-not(Test-RelativePathSafe $root)){throw "Unsafe Browse root: $root"};Add-SmartArchiveBrowseEntry $entries $root $true}
        foreach($block in @($Manifest.blocks)){$id=[string]$block.id;if(-not(Test-Blank $id)){$blockById[$id.ToLowerInvariant()]=$block}}
        foreach($indexed in @($Manifest.browseIndex.blocks)){
            $id=[string]$indexed.id;$key=$id.ToLowerInvariant();if(Test-Blank $id-or-not$blockById.ContainsKey($key)){throw "Browse index references missing block: $id"}
            $rootId=[int]$indexed.root;if($rootId-lt0-or$rootId-ge$roots.Count){throw "Invalid Browse root for block $id"};$root=(Convert-ToTarPath ([string]$roots[$rootId])).Trim('/').Trim();$isVirtual=($null-ne$Manifest.browseIndex.virtualRoots-and$rootId-lt@($Manifest.browseIndex.virtualRoots).Count-and[bool]@($Manifest.browseIndex.virtualRoots)[$rootId]);$files=@($indexed.files);$block=$blockById[$key]
            if($files.Count-ne[int]$block.fileCount){throw "Browse index file count mismatch for block $id."}
            foreach($relative in $files){$rel=(Convert-ToTarPath ([string]$relative)).Trim('/').Trim();if(Test-Blank $rel-or-not(Test-RelativePathSafe $rel)){throw "Unsafe Browse file: $rel"};$stored=if($isVirtual){$rel}else{$root+'/'+$rel};$display=$root+'/'+$rel;$storedKey=$stored.ToLowerInvariant();if($physical.ContainsKey($storedKey)){throw "Duplicate physical Browse path: $stored"};$physical[$storedKey]=[string]$block.path;$physicalCount++;Add-SmartArchiveBrowseEntry $entries $display $false ([string]$block.path) '' $stored}
        }
        foreach($empty in @($Manifest.browseIndex.emptyDirectories)){$row=@($empty);if($row.Count-ne2){throw 'Invalid empty-directory Browse row.'};$rootId=[int]$row[0];if($rootId-lt0-or$rootId-ge$roots.Count){throw 'Invalid empty-directory root.'};$rel=(Convert-ToTarPath ([string]$row[1])).Trim('/').Trim();if(Test-Blank $rel-or-not(Test-RelativePathSafe $rel)){throw "Unsafe empty Browse directory: $rel"};$root=(Convert-ToTarPath ([string]$roots[$rootId])).Trim('/').Trim();$isVirtual=($null-ne$Manifest.browseIndex.virtualRoots-and$rootId-lt@($Manifest.browseIndex.virtualRoots).Count-and[bool]@($Manifest.browseIndex.virtualRoots)[$rootId]);$stored=if($isVirtual){$rel}else{$root+'/'+$rel};Add-SmartArchiveBrowseEntry $entries ($root+'/'+$rel) $true '' '' $stored}
        if($null-ne$Manifest.summary-and$null-ne$Manifest.summary.uniqueFiles-and$physicalCount-ne[int]$Manifest.summary.uniqueFiles){throw 'Browse index unique-file total mismatch.'}
        $aliasPaths=@{};foreach($alias in @($Manifest.dedupAliases)){$ap=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim();if(-not(Test-Blank $ap)){$aliasPaths[$ap.ToLowerInvariant()]=$true}}
        foreach($alias in @($Manifest.dedupAliases)){
            $path=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim();$target=(Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim()
            if(Test-Blank $path-or-not(Test-RelativePathSafe $path)-or Test-Blank $target-or-not(Test-RelativePathSafe $target)){throw 'Unsafe Browse alias.'}
            $targetKey=$target.ToLowerInvariant();if($aliasPaths.ContainsKey($targetKey)){throw "Browse alias chain: $path -> $target"};if(-not$physical.ContainsKey($targetKey)){throw "Browse alias target is absent: $target"}
            $displayPath=$path;$hasDeclaredRoot=$false
            foreach($rootValue in $roots){$declaredRoot=(Convert-ToTarPath ([string]$rootValue)).Trim('/').Trim();if($path.Equals($declaredRoot,[System.StringComparison]::OrdinalIgnoreCase)-or$path.StartsWith($declaredRoot+'/',[System.StringComparison]::OrdinalIgnoreCase)){$hasDeclaredRoot=$true;break}}
            if(-not$hasDeclaredRoot){$isPrimaryVirtual=($null-ne$Manifest.browseIndex.virtualRoots-and@($Manifest.browseIndex.virtualRoots).Count-gt0-and[bool]@($Manifest.browseIndex.virtualRoots)[0]);if($isPrimaryVirtual){$displayPath=((Convert-ToTarPath ([string]$roots[0])).Trim('/').Trim())+'/'+$path}}
            Add-SmartArchiveBrowseEntry $entries $displayPath $false ([string]$physical[$targetKey]) $target $path
        }
        $items=@($entries.Values|Sort-Object @{Expression={if($_.IsFolder){0}else{1}}},@{Expression={[string]$_.Rel}})
        return [pscustomobject]@{Entries=$items;EntryMap=$entries}
    }catch{return $null}
}

function Get-SmartArchiveBrowseEntriesLegacy {
    param([string]$TarPath, [string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $TarPath)) { throw 'tar.exe was not found.' }
    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw 'Archive path does not exist.' }

    $work = New-SafeWorkRoot 'browse' $ArchivePath
    $outer = Join-Path $work 'outer'
    [System.IO.Directory]::CreateDirectory($outer) | Out-Null

    try {
        $safeArchive = Prepare-SafeArchiveInput $ArchivePath $work
        $manifest = Read-StarArchiveManifest $TarPath $safeArchive $outer
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

function Get-SmartArchiveBrowseEntries {
    param([string]$TarPath,[string]$ArchivePath)
    $work=New-SafeWorkRoot 'browse_index' $ArchivePath;$outer=Join-Path $work 'outer';[System.IO.Directory]::CreateDirectory($outer)|Out-Null
    try{$manifest=Read-StarArchiveManifest $TarPath $ArchivePath $outer;$fast=Get-SmartArchiveBrowseIndexEntries $manifest
        if($null-ne$fast){return [pscustomobject]@{Work=$work;Manifest=$manifest;Entries=$fast.Entries;EntryMap=$fast.EntryMap}}
    }catch{Remove-SmartTarWorkAndRoot $work;throw}
    Remove-SmartTarWorkAndRoot $work
    return Get-SmartArchiveBrowseEntriesLegacy $TarPath $ArchivePath
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

function Get-SmartArchiveStoredSelectionPath {
    param([string]$DisplayPath,$BrowseData)
    $display=(Convert-ToTarPath ([string]$DisplayPath)).Trim('/').Trim()
    if($null-ne$BrowseData-and$null-ne$BrowseData.EntryMap){$key=$display.ToLowerInvariant();if($BrowseData.EntryMap.ContainsKey($key)){return (Convert-ToTarPath ([string]$BrowseData.EntryMap[$key].StoredRel)).Trim('/').Trim()}}
    return $display
}

function Extract-SmartArchiveSelectionLegacy {
    param([string]$TarPath, [string]$ArchivePath, [string]$RelativePath, [bool]$IsFolder, [string]$DestinationParent, [string]$StoredPath='')

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
        $manifest = Read-StarArchiveManifest $TarPath $safeArchive $outer

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

        $displayRel=(Convert-ToTarPath ([string]$RelativePath)).Trim('/').Trim()
        $primaryRootMarker='__SMARTTAR_PRIMARY_VIRTUAL_ROOT__'
        $genericRootMarker='__SMARTTAR_VIRTUAL_ROOT__'
        $isPrimaryVirtual=(([string]$StoredPath) -eq $primaryRootMarker)
        $rel=if($isPrimaryVirtual -or ([string]$StoredPath) -eq $genericRootMarker){''}elseif(Test-Blank $StoredPath){$displayRel}else{(Convert-ToTarPath $StoredPath).Trim('/').Trim()}
        if (Test-Blank $rel) {
            if(-not(Test-Blank $displayRel) -and $IsFolder){
                $leaf=Split-Path -Leaf (Convert-ToLocalPath $displayRel)
                if(Test-Blank $leaf){$leaf=Get-ArchiveRootName $manifest $ArchivePath}
                if(Test-Blank $leaf){$leaf='selection'}
                $targetPath=Join-Path $DestinationParent $leaf
                [System.IO.Directory]::CreateDirectory($targetPath)|Out-Null
                foreach($item in @(Get-ChildItem -LiteralPath $payload -Force -ErrorAction Stop)){
                    if($isPrimaryVirtual -and ([string]$item.Name -ieq 'ADD')){continue}
                    $target=Join-Path $targetPath ([string]$item.Name)
                    if($item.PSIsContainer){[System.IO.Directory]::CreateDirectory($target)|Out-Null;Copy-DirectoryContents $item.FullName $target}else{Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop}
                }
                if(-not(Test-Path -LiteralPath $targetPath -PathType Container)){throw "Virtual root extraction did not create output: $targetPath"}
                return $targetPath
            }
            Copy-DirectoryContents $payload $DestinationParent
            return $DestinationParent
        }

        $sourceItem = Get-SafePayloadPath $payload $rel
        if (-not (Test-Path -LiteralPath $sourceItem)) { throw "Selected item was not restored from archive: $rel" }

        $leaf = Split-Path -Leaf (Convert-ToLocalPath $displayRel)
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
    $storedRel=Get-SmartArchiveStoredSelectionPath $rel $BrowseData
    $sourceRoot='';if($null -ne $BrowseData -and $null -ne $BrowseData.Manifest){$sourceRoot=(Convert-ToTarPath ([string]$BrowseData.Manifest.sourceName)).Trim('/').Trim()}
    $multiRoot=($null -ne $BrowseData -and $null -ne $BrowseData.Manifest -and @($BrowseData.Manifest.contentRoots).Count -gt 1)
    $isPrimaryRoot=(-not(Test-Blank $sourceRoot) -and $rel.Equals($sourceRoot,[System.StringComparison]::OrdinalIgnoreCase))
    if($isPrimaryRoot){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent '__SMARTTAR_PRIMARY_VIRTUAL_ROOT__')}
    if(Test-Blank $rel){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent '__SMARTTAR_VIRTUAL_ROOT__')}
    if($null -eq $BrowseData -or $null -eq $BrowseData.EntryMap){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent $storedRel)}
    $entryKey=$rel.ToLowerInvariant();if(-not $BrowseData.EntryMap.ContainsKey($entryKey)){return (Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent $storedRel)}
    if(-not(Test-Path -LiteralPath $ArchivePath)){throw 'Archive path does not exist.'};if(Test-Blank $DestinationParent){throw 'Destination folder is empty.'};[System.IO.Directory]::CreateDirectory($DestinationParent)|Out-Null
    $work=New-SafeWorkRoot 'browse_stream' $ArchivePath;$payload=Join-Path $work 'payload';[System.IO.Directory]::CreateDirectory($payload)|Out-Null
    try{
        $manifest=$BrowseData.Manifest;$blockMap=@{};foreach($block in @($manifest.blocks)){$blockMap[(Convert-ToTarPath ([string]$block.path)).ToLowerInvariant()]=$block}
        $aliasMap=@{};foreach($alias in @($manifest.dedupAliases)){$p=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim();if(-not(Test-Blank $p)){$aliasMap[$p.ToLowerInvariant()]=$alias}}
        $storedKey=$storedRel.ToLowerInvariant()
        if(-not $IsFolder -and $aliasMap.ContainsKey($storedKey)){
            $alias=$aliasMap[$storedKey];$target=(Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim();$targetKey=$target.ToLowerInvariant()
            $targetEntry=$null;foreach($candidate in $BrowseData.EntryMap.Values){if(([string]$candidate.StoredRel).Equals($target,[System.StringComparison]::OrdinalIgnoreCase)){$targetEntry=$candidate;break}}
            if($null-eq$targetEntry){throw "Dedup target is missing from browse index: $target"}
            foreach($rb in @($targetEntry.Blocks)){$bk=(Convert-ToTarPath ([string]$rb)).ToLowerInvariant();$block=$blockMap[$bk];[void](Invoke-SmartTarStreamSelection $TarPath $ArchivePath ([string]$block.path) ([string]$block.sha256) $payload $target $false)}
            $physical=Get-SafePayloadPath $payload $target;if(-not(Test-Path -LiteralPath $physical -PathType Leaf)){throw "Dedup target was not extracted: $target"}
            $aliasPayload=Get-SafePayloadPath $payload $storedRel;[System.IO.Directory]::CreateDirectory((Split-Path -Parent $aliasPayload))|Out-Null;Copy-Item -LiteralPath $physical -Destination $aliasPayload -Force -ErrorAction Stop
        }else{
            $needed=@($BrowseData.EntryMap[$entryKey].Blocks);if($needed.Count -lt 1){throw "Selected item has no physical block mapping: $rel"}
            foreach($rb in $needed){$bk=(Convert-ToTarPath ([string]$rb)).ToLowerInvariant();$block=$blockMap[$bk];[void](Invoke-SmartTarStreamSelection $TarPath $ArchivePath ([string]$block.path) ([string]$block.sha256) $payload $storedRel $IsFolder)}
            if($IsFolder){
                $extra=@{};foreach($alias in @($manifest.dedupAliases)){$ap=(Convert-ToTarPath ([string]$alias.path)).Trim('/').Trim();if(-not($ap -eq $storedRel -or $ap.StartsWith($storedRel+'/',[System.StringComparison]::OrdinalIgnoreCase))){continue};$t=(Convert-ToTarPath ([string]$alias.target)).Trim('/').Trim();$tk=$t.ToLowerInvariant();$targetEntry=$null;foreach($candidate in $BrowseData.EntryMap.Values){if(([string]$candidate.StoredRel).Equals($t,[System.StringComparison]::OrdinalIgnoreCase)){$targetEntry=$candidate;break}};if($null-eq$targetEntry){throw "Dedup target is missing from browse index: $t"};foreach($tb in @($targetEntry.Blocks)){$extra[[string]$tb+'|'+$t]=[pscustomobject]@{Block=[string]$tb;Target=$t}}}
                foreach($x in $extra.Values){$bk=(Convert-ToTarPath ([string]$x.Block)).ToLowerInvariant();$block=$blockMap[$bk];[void](Invoke-SmartTarStreamSelection $TarPath $ArchivePath ([string]$block.path) ([string]$block.sha256) $payload ([string]$x.Target) $false)}
                Restore-SelectedDedupAliases $manifest $payload $storedRel $true
            }
        }
        $sourceItem=Get-SafePayloadPath $payload $storedRel;if(-not(Test-Path -LiteralPath $sourceItem)){throw "Selected item was not restored from archive: $rel"}
        $leaf=Split-Path -Leaf (Convert-ToLocalPath $rel)
        if($rel -ieq 'ADD'){$leaf=$sourceRoot+'_ADD'}
        if(Test-Blank $leaf){$leaf='selection'}
        $targetPath=Join-Path $DestinationParent $leaf
        if($IsFolder){[System.IO.Directory]::CreateDirectory($targetPath)|Out-Null;Copy-DirectoryContents $sourceItem $targetPath}else{Copy-Item -LiteralPath $sourceItem -Destination $targetPath -Force -ErrorAction Stop}
        if(-not(Test-Path -LiteralPath $targetPath)){throw "Browse extraction did not create output: $targetPath"};return $targetPath
    }catch{
        Set-BusyStatus 'Streamed Browse extraction unavailable. Using compatibility fallback...'
        $fallback=Extract-SmartArchiveSelectionLegacy $TarPath $ArchivePath $RelativePath $IsFolder $DestinationParent $storedRel
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
    param([string]$TarPath,[string]$ArchivePath,[string]$WorkRoot,[bool]$ExtractBlocks=$true)
    $outer=Join-Path $WorkRoot 'outer';[System.IO.Directory]::CreateDirectory($outer)|Out-Null
    $safe=if($ExtractBlocks){Prepare-SafeArchiveInput $ArchivePath $WorkRoot}else{$ArchivePath}
    if($ExtractBlocks){Invoke-Tar $TarPath @('-xf',$safe,'-C',$outer) 'Existing STAR extraction failed.'}
    $manifest=Read-StarArchiveManifest $TarPath $safe $outer
    return [pscustomobject]@{Outer=$outer;SafeArchive=$safe;Manifest=$manifest}
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

function Merge-SmartTarBrowseIndexes {
    param($OldIndex,$AddIndex)
    if($null-eq$OldIndex-or[int]$OldIndex.schema-ne2-or$null-eq$AddIndex-or[int]$AddIndex.schema-ne2){return $null}
    $roots=New-Object System.Collections.ArrayList;$rootMap=@{}
    foreach($root in @($OldIndex.roots)+@($AddIndex.roots)){$r=(Convert-ToTarPath ([string]$root)).Trim('/').Trim();$k=$r.ToLowerInvariant();if(-not$rootMap.ContainsKey($k)){$rootMap[$k]=$roots.Count;[void]$roots.Add($r)}}
    $blocks=New-Object System.Collections.ArrayList
    foreach($index in @($OldIndex,$AddIndex)){foreach($b in @($index.blocks)){$oldRoot=[int]$b.root;$rootName=(Convert-ToTarPath ([string]@($index.roots)[$oldRoot])).Trim('/').Trim();[void]$blocks.Add([ordered]@{id=[string]$b.id;root=[int]$rootMap[$rootName.ToLowerInvariant()];files=@($b.files)})}}
    $empty=New-Object System.Collections.ArrayList
    foreach($index in @($OldIndex,$AddIndex)){foreach($d in @($index.emptyDirectories)){$row=@($d);$oldRoot=[int]$row[0];$rootName=(Convert-ToTarPath ([string]@($index.roots)[$oldRoot])).Trim('/').Trim();[void]$empty.Add(@([int]$rootMap[$rootName.ToLowerInvariant()],[string]$row[1]))}}
    $virtual=@();foreach($root in $roots){$flag=$false;foreach($index in @($OldIndex,$AddIndex)){for($i=0;$i-lt@($index.roots).Count;$i++){if(([string]@($index.roots)[$i]).Equals([string]$root,[System.StringComparison]::OrdinalIgnoreCase)-and$null-ne$index.virtualRoots-and$i-lt@($index.virtualRoots).Count){$flag=$flag-or[bool]@($index.virtualRoots)[$i]}}};$virtual+=$flag}
    return [ordered]@{schema=2;roots=@($roots);virtualRoots=$virtual;blocks=@($blocks);emptyDirectories=@($empty)}
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
    $mergedBrowse=Merge-SmartTarBrowseIndexes $OldManifest.browseIndex $AddManifest.browseIndex
    $result=[ordered]@{
        format='STAR';formatVersion=2;layout='multi-root-additive';tool='SmartTAR';toolVersion='1.5.0';createdUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sourceName=$primary;sourceType='MultiRoot';sourceBytes=([int64]$stored+[int64]$aliasBytes)
        compressionMode='Additive';compressionProfile='Multi-root additive archive'
        build=[ordered]@{workrootMode='transactional-add';pipeline='append-new-blocks-preserve-existing';blockCleanup='after-append';catalogPosition='before-manifest';manifestPosition='last-outer-entry';outerTarFormat='pax';innerTarFormat='mixed:structure=gnutar,data=pax'}
        contentRoots=@($roots);addHistory=@($history)
        summary=[ordered]@{storedUniqueBytes=$stored;catalogFiles=($unique+$allAliases.Count);uniqueFiles=$unique;aliasFiles=$allAliases.Count;dedupAliasCount=$allAliases.Count;dedupAliasBytes=$aliasBytes}
        dedupAliasMode='unique-only-restored-on-extract';dedupAliases=@($allAliases);blocks=@($allBlocks)
    }
    if($null-ne$mergedBrowse){$result['browseIndex']=$mergedBrowse}
    return $result
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
        $addSourcePolicy=Get-SourceLayoutPolicy $Source
        $sourceLeaf=[string]$addSourcePolicy.SourceName;if(Test-Blank $sourceLeaf){$sourceLeaf='Added content'}
        $addInfo=Get-NextAddRoot $manifest $sourceLeaf
        $addParent=Join-Path $work 'add_source';[System.IO.Directory]::CreateDirectory($addParent)|Out-Null
        Set-BusyStatus "Preparing ADD batch $($addInfo.Batch)..."
        [void](New-AddSourceStage $Source $addParent $addInfo.Name)
        $crossAliases=Remove-AddDuplicatesAgainstArchive $addParent $addInfo.Name $existingIndex
        $mini=Join-Path $work 'add_generation.star'
        Set-BusyStatus 'Compressing new ADD generation...'
        # Compress from the common ADD root so both structure and data blocks
        # store the same complete path: ADD/ADD_timestamp/source/...
        Compress-SmartArchive $TarPath (Join-Path $addParent 'ADD') $mini $Mode $true
        $miniWork=Join-Path $work 'mini';[System.IO.Directory]::CreateDirectory($miniWork)|Out-Null
        $miniData=Get-StarOuterData $TarPath $mini $miniWork
        $preparedFileCount=@(Get-ChildItem -LiteralPath (Join-Path $addParent 'ADD') -File -Recurse -Force -ErrorAction Stop).Count;$represented=0;foreach($mb in @($miniData.Manifest.blocks)){if([string]$mb.group-ne'structure'){$represented+=[int]$mb.fileCount}};$represented+=@($miniData.Manifest.dedupAliases).Count;if($represented-ne$preparedFileCount){throw "ADD mini archive catalog mismatch. Destination was not modified."}
        $start=(Get-MaxStarBlockId $manifest)+1;$newBlocks=@();$i=$start
        $appendRoot=Join-Path $work 'append';$appendBlocks=Join-Path $appendRoot 'blocks';[System.IO.Directory]::CreateDirectory($appendBlocks)|Out-Null
        foreach($block in @($miniData.Manifest.blocks)){
            $oldId=[string]$block.id;$oldPath=Resolve-SafeBlockPath $miniData.Outer ([string]$block.path)
            $name=[System.IO.Path]::GetFileName([string]$block.path)
            $tail=$name -replace '^\d+_',''
            $generationSuffix='_add{0:D3}' -f [int]$addInfo.Generation
            $renamedTail=$tail -replace '(?=\.tar)', $generationSuffix
            $newId='{0:D6}' -f $i
            $newName=$newId+'_'+$renamedTail
            $dest=Join-Path $appendBlocks $newName;Copy-Item -LiteralPath $oldPath -Destination $dest -Force
            $block.id=$newId;$block.path='blocks/'+$newName;$block|Add-Member -NotePropertyName generation -NotePropertyValue ([int]$addInfo.Generation) -Force
            if($null-ne$miniData.Manifest.browseIndex){foreach($ib in @($miniData.Manifest.browseIndex.blocks)){if([string]$ib.id-eq$oldId){$ib.id=$newId}}}
            $newBlocks+=,$block;$i++
        }
        $newManifest=Merge-StarAddManifest $manifest $miniData.Manifest $crossAliases $addInfo $newBlocks
        $canonical=Test-StarCanonicalTailLayout $Destination $manifest
        if(Test-Path -LiteralPath $tempArchive){Remove-Item -LiteralPath $tempArchive -Force}
        Copy-Item -LiteralPath $Destination -Destination $tempArchive -Force
        Reset-StarTempToCanonicalDataEnd $tempArchive ([int64]$manifest.outerLayout.truncateOffset)
        foreach($block in $newBlocks){Add-StarOuterEntry $TarPath $tempArchive $appendRoot ([string]$block.path) 'ADD block append failed.'}
        $newDataLayout=Get-StarOuterTarLayout $tempArchive
        Set-BusyStatus 'Publishing merged catalog and manifest...'
        [void](Publish-StarCatalogAndManifest $TarPath $tempArchive $appendRoot $newManifest ([int64]$newDataLayout.EndOfEntriesOffset))
        Set-BusyStatus 'Checking updated STAR catalog integrity...'
        $checkRoot=Join-Path $work 'incremental_check';[System.IO.Directory]::CreateDirectory($checkRoot)|Out-Null
        $checked=Read-StarArchiveManifest $TarPath $tempArchive $checkRoot
        [void](Test-StarCanonicalTailLayout $tempArchive $checked)
        [void](Test-StarOuterBlockHashes $TarPath $tempArchive $newBlocks $checkRoot)
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
    param([string]$TarPath,[string]$Source,[string]$Destination,[string]$Mode,[bool]$AllowInternalSmartTarSource=$false)
    if(-not(Test-Path -LiteralPath $TarPath)){throw 'tar.exe was not found.'};$Source=Normalize-ArchiveSourcePath $Source;if(-not(Test-Path -LiteralPath $Source)){throw 'Source path does not exist.'}
    if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force};if($Mode-notin@('Balanced','Smart','Solid','Store')){$Mode='Balanced'}
    $smartTarTemp=Get-SmartTarWritableStandardTempRoot
    if($AllowInternalSmartTarSource){$sourceFull=[System.IO.Path]::GetFullPath($Source).TrimEnd([char]92,[char]47);$tempFull=[System.IO.Path]::GetFullPath($smartTarTemp).TrimEnd([char]92,[char]47);if(-not($sourceFull.StartsWith($tempFull+[System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase))){throw 'Internal SmartTAR source override is allowed only below SmartTAR temp.'}}
    $planWork=New-SafeWorkRoot 'plan' $Destination;$script:SourceEnumerationExcludedRoots=if($AllowInternalSmartTarSource){@()}else{@($smartTarTemp)}
    $work='';$outerTemp='';$published=$false
    try{
        Set-BusyStatus 'Checking TAR capabilities...';$capabilities=Test-TarCapabilities $TarPath $planWork;$script:tarCapabilities=$capabilities;$script:CompressionThreads=Get-CompressionThreadCount;$script:MultithreadCompatibilityRetries=0;if(-not$capabilities.store){throw 'No usable tar store method.'}
        $sourceItem=Get-Item -LiteralPath $Source -Force;$sourcePolicy=Get-SourceLayoutPolicy $Source;$sourceParent=[string]$sourcePolicy.BaseRoot;$sourceLeaf=[string]$sourcePolicy.SourceName;$script:sourceArchiveRootPrefix=[string]$sourcePolicy.StoredRootPrefix;$script:CurrentSourceIsDriveRoot=[bool]$sourcePolicy.IsDriveRoot
        Set-BusyStatus 'Cataloging source once before creating destination workroot...';$sourceCatalog=New-SmartTarSourceCatalog $sourceItem $Source $sourceParent;$profile=$sourceCatalog.Profile;$profileName=Get-CompressionProfileDisplayName $Mode (Get-CompressionPreferenceForMode $Mode);$groups=New-ArchiveGroups $Mode $capabilities $profile
        Initialize-SmartTarPlanningArtifacts $planWork;Stage-FilesPlan $sourceCatalog $Mode $groups;Test-PlannedDedupAliases $groups
        $structureStage=Join-Path $planWork 'structure_stage';[System.IO.Directory]::CreateDirectory($structureStage)|Out-Null;$dirCount=Create-StructureStage $sourceItem $Source $sourceParent $structureStage $sourceCatalog
        # Catalog is now sealed. Only now may destination-local .stw exist.
        $compressionWork=New-CompressionWorkRoot $Source $Destination;$work=[string]$compressionWork.WorkRoot;$allowCopy=[bool]$compressionWork.AllowGroupCopyFallback;$script:buildWorkMode=[string]$compressionWork.Mode
        $blocksDir=Join-Path $work 'blocks';[System.IO.Directory]::CreateDirectory($blocksDir)|Out-Null
        if($Mode-eq'Solid'-and$groups.Contains('solid')){$groups.solid.Method=Select-AutoSolidMethod $capabilities $profile $script:adaptiveStats;$groups.solid.Reason='Solid single-block method selected from content profile.'}
        $store=Select-TarMethod $capabilities 'store' $false;$outerTemp=New-StarOuterTempArchive $Destination;$blocks=Build-AndPublishBlocksSequential $TarPath $groups $blocksDir $work $structureStage $dirCount $store $allowCopy $outerTemp;if($blocks.Count-lt1){throw 'No blocks were created.'}
        $manifest=Build-Manifest $Source $sourceItem $sourceLeaf $Mode $capabilities $profile $blocks;$layout=Get-StarOuterTarLayout $outerTemp;[void](Publish-StarCatalogAndManifest $TarPath $outerTemp $work $manifest ([int64]$layout.EndOfEntriesOffset));Complete-StarOuterArchive $outerTemp $Destination;$published=$true
    }finally{if(-not$published-and-not(Test-Blank $outerTemp)-and(Test-Path -LiteralPath $outerTemp)){Remove-Item -LiteralPath $outerTemp -Force -ErrorAction SilentlyContinue};if(-not(Test-Blank $work)){Remove-SmartTarWorkAndRoot $work};Remove-SmartTarWorkAndRoot $planWork;$script:SourceEnumerationExcludedRoots=@()}
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
        $operationTimer=[System.Diagnostics.Stopwatch]::StartNew()
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
            $r=Get-StarFastSummary $tarPath $destination 'Add'
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
        $operationTimer.Stop();$details="`r`nOperation time: $(Format-OperationDuration $operationTimer.Elapsed)"
        if($action-eq'Compress'-or$action-eq'Add'){$xz=if(Test-TarThreadingSupported $script:tarCapabilities 'xz'){"Supported, $($script:CompressionThreads) threads"}else{'Unsupported, single-thread'};$zs=if(Test-TarThreadingSupported $script:tarCapabilities 'zstd'){"Supported, $($script:CompressionThreads) threads"}else{'Unsupported, single-thread'};$details+="`r`nCompression scheduler: Sequential`r`nActive TAR processes: 1`r`nXZ threading: $xz`r`nZSTD threading: $zs`r`nMultithread compatibility retries: $($script:MultithreadCompatibilityRetries)"};$r[29]=$details
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
        [string]$Title = 'SmartTAR STAR v1.5.0 Preview',
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
    Text            = 'SmartTAR - STAR 1.5.1 ZSTD Scanner Multi Root Browse Fix 6  .:: Copyright © 2026 eco-by-different ::.'
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