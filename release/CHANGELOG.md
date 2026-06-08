# SmartTAR - STAR v1.0

**SmartTAR - STAR** is a Windows PowerShell GUI archiver built around the Windows `tar.exe` / bsdtar engine.  
It creates `.star` archives using an outer TAR container, an internal `manifest.json`, SHA-256 block metadata, and grouped block compression.

The goal of SmartTAR is to provide a simple desktop archiver for Windows while keeping the archive structure transparent, verifiable, and recoverable.

---

## Main features

- **STAR archive format** using an outer TAR container.
- **`manifest.json` metadata** with SHA-256 hashes for archive blocks.
- **Smart grouped block planning** based on detected file types.
- **Multiple compression modes**:
  - Hybrid
  - Smart
  - Solid
  - Smart XZ
  - Store
- **Group hardlink staging** for reliable block creation.
- **Chunk fallback** when group-stage creation fails.
- **XZ directory timestamp normalization** for more stable XZ output.
- **Responsive GUI** using a hidden worker process.
- **Safe temporary worker folder** with status, result, and report files.
- **VERIFY mode** for archive integrity checks.
- **Salvage extraction mode** for extracting usable blocks from partially damaged archives.

---

## Requirements

- Windows 10 / Windows 11
- Windows PowerShell 5.1 or newer
- Built-in Windows `tar.exe` / bsdtar available in `System32`

No external installation is required for standard use.

---

## How to run

1. Download `SmartTAR_STAR_v1.0.ps1`.
2. Right-click the file and choose **Run with PowerShell**.
3. If PowerShell execution policy blocks the script, run it from PowerShell with an appropriate policy for the current process, for example:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\SmartTAR_STAR_v1.0.ps1
```

---

## Basic usage

### Create an archive

1. Click **Add FILE** or **Add FOLDER**.
2. Select the destination archive path.
3. Choose a compression mode.
4. Click **COMPRESS**.

The output archive uses the `.star` extension.

### Extract an archive

1. Click **Add ARCHIVE**.
2. Select the destination parent folder.
3. Click **EXTRACT**.

SmartTAR extracts the stored source folder/file into the selected destination.

### Verify an archive

1. Click **Add ARCHIVE**.
2. Click **VERIFY**.

SmartTAR verifies the internal archive blocks and writes a verification report next to the archive.

---

## Compression modes

### Hybrid

Groups files by detected data type and selects suitable compression methods for each group.  
This is the default mode and usually the best general-purpose choice.

### Smart

Creates one block per detected data type.  
Useful when you want clear separation of file groups inside the archive.

### Solid

Creates one compressed block using an automatically selected method.  
Useful for maximum simplicity and often good compression.

### Smart XZ

Uses grouped XZ compression blocks.  
Useful when you prefer strong compression and deterministic XZ staging behavior.

### Store

Creates grouped TAR blocks without compression.  
Useful for speed, testing, or already-compressed files.

---

## Archive structure

A `.star` archive contains:

```text
manifest.json
blocks/
  block_*.tar / block_*.tar.xz / block_*.tar.gz / ...
```

The manifest stores metadata such as:

- tool name and version
- compression mode
- source name
- block list
- SHA-256 hash for each block
- source size and block statistics

---

## Verification and recovery

SmartTAR includes a **VERIFY** action that checks whether internal blocks are readable and match their recorded hashes.

If an archive is partially damaged, **Salvage mode** can be enabled during extraction. In that mode, SmartTAR tries to extract all usable blocks and skips broken ones where possible.

---

## Notes

- SmartTAR uses the Windows `tar.exe` implementation available on the system.
- Compression capabilities may depend on the installed Windows tar/bsdtar version.
- For best compatibility, keep archive paths short and avoid unusual characters in test scenarios.
- `.star` archives are TAR-based containers, but their internal layout is specific to SmartTAR.

---

## Version

**SmartTAR - STAR v1.0**

Copyright (c) 2026 eco-by-different
