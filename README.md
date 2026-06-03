# SmartTAR STAR

**SmartTAR STAR** is an experimental Windows PowerShell GUI archiver built on top of the built-in Windows `tar.exe` / bsdtar engine.

It creates transparent `.star` archives containing:

- an outer TAR container,
- a `manifest.json` file,
- one or more internal compressed TAR blocks,
- SHA-256 block hashes,
- recovery-friendly metadata.

SmartTAR focuses on **transparent recovery, readable archive structure, and automatic compression planning** rather than using a proprietary black-box format.

> Current status: **Beta / experimental**  
> Documented version: **SmartTAR STAR 1.0 Beta 1 Fix 2 XZ9 XZStable - Clean**

---

## Highlights

- Windows GUI built with PowerShell WinForms.
- Uses Windows `tar.exe` only.
- Default archive extension: `.star`.
- Supports legacy archive extension: `.sarc.tar`.
- Block-based archive layout with a JSON manifest.
- Multiple compression modes:
  - **Hybrid** — recommended balanced planner,
  - **Smart** — detailed grouped blocks,
  - **Solid** — one auto-selected block,
  - **Smart XZ** — grouped XZ9-oriented blocks.
- Automatic capability detection for available TAR compression methods.
- SHA-256 verification of internal blocks.
- Manual recovery-friendly structure.
- Extraction safety checks against unsafe paths.
- Operation reports for create, extract, and verify actions.

---

## Screenshot

![SmartTAR STAR GUI](docs/images/smarttar-gui.png)

---

## Archive Design

A `.star` archive is a standard TAR file. Inside it, SmartTAR stores a manifest and internal blocks:

```text
archive.star
├── manifest.json
└── blocks/
    ├── 000001_structure.tar
    ├── 000002_text.tar.xz
    ├── 000003_binary.tar.zst
    └── ...
```

The manifest describes the archive, source profile, compression mode, block list, compression methods, SHA-256 hashes, sizes, and deterministic timestamp metadata.

Because the outer archive is a standard TAR container, it can be inspected manually with common TAR tools.

---

## Compression Methods

SmartTAR checks which methods are supported by the available `tar.exe` and uses only methods that pass a runtime capability test.

| Method | Extension | Purpose |
|---|---:|---|
| STORE | `.tar` | No compression. Useful for directory structure, media, and already-compressed files. |
| GZIP | `.tar.gz` | Fallback compression. |
| BZIP2 | `.tar.bz2` | Fallback compression. |
| XZ9 | `.tar.xz` | XZ compression level 9 when supported. |
| XZ | `.tar.xz` | Default XZ fallback. |
| ZSTD19 | `.tar.zst` | Zstandard level 19 when supported by the TAR engine. |

If a preferred method is unavailable, SmartTAR automatically falls back to the next usable method.

---

## Compression Modes

### Hybrid

Recommended default mode.

Hybrid mode groups files into broad categories:

- `structure` — directory structure, stored,
- `compressible` — general compressible files, prefers XZ9/XZ,
- `diskimage` — disk image files, prefers ZSTD19,
- `stored` — media and archive-like files, stored without recompression.

### Smart

Detailed grouped mode.

Smart mode separates files into more specific groups:

- text,
- binary,
- executable,
- disk image,
- media,
- archives,
- unknown.

Text and unknown data prefer XZ9/XZ. Binary, executable, and disk image data prefer ZSTD19 when available. Media and archive-like files are stored.

### Solid

Creates one main block using an automatically selected compression method based on the source profile.

If binary-like data dominates and ZSTD19 is available, ZSTD19 may be selected. Otherwise, XZ9/XZ is preferred.

### Smart XZ

Groups files similarly to Smart mode, but compressible groups prefer XZ9/XZ. Media and archive-like groups are stored because they are usually already compressed.

---

## Deterministic Timestamp Handling

SmartTAR includes targeted timestamp stabilization for XZ/XZ9 blocks.

When any XZ/XZ9 block is used, SmartTAR normalizes timestamps for those XZ-related staging trees to:

```text
2000-01-01T00:00:00Z
```

Important details:

- Timestamp normalization is applied only to XZ/XZ9 block stages.
- STORE and ZSTD stages keep their natural timestamps.
- The manifest records whether deterministic metadata was enabled and what scope was affected.

---

## Requirements

- Windows.
- PowerShell with Windows Forms support.
- Windows `tar.exe` available in:
  - `%SystemRoot%\System32\tar.exe`, or
  - a location discoverable through `PATH`.

No additional compression binaries are bundled or required by the script itself.

---

## How to Run

Save the script as:

```text
src/SmartTAR.ps1
```

Run it from PowerShell:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\src\SmartTAR.ps1
```

Or with PowerShell 7:

```powershell
pwsh.exe -ExecutionPolicy Bypass -File .\src\SmartTAR.ps1
```

The script opens a GUI window.

---

## Basic Usage

### Create an Archive

1. Click **Add FILE** or **Add FOLDER**.
2. Select the source file or folder.
3. Choose the destination archive path.
4. Select a compression mode.
5. Click **COMPRESS**.
6. After completion, SmartTAR shows a summary and writes a create report next to the archive.

### Extract an Archive

1. Click **Add ARCHIVE**.
2. Select a `.star` or `.sarc.tar` archive.
3. Choose the extraction folder.
4. Click **EXTRACT**.
5. SmartTAR extracts verified internal blocks into the destination folder.

### Verify an Archive

1. Click **Add ARCHIVE**.
2. Select a `.star` or `.sarc.tar` archive.
3. Click **VERIFY**.
4. SmartTAR checks the outer container, manifest, internal blocks, TAR readability, SHA-256 hashes, and sizes.

---

## Reports

SmartTAR writes text reports next to the selected archive.

Examples:

```text
archive.star.create_report.20260101_120000.txt
archive.star.extract_report.20260101_120000.txt
archive.star.verify_report.20260101_120000.txt
```

Reports include operation status, archive size, source size, compression ratio, used methods, deterministic metadata information, and per-block verification details.

---

## Manual Recovery

Because the outer archive is a standard TAR file, it can be unpacked manually.

```powershell
tar -xf archive.star -C outer
```

Then inspect:

```text
outer\manifest.json
outer\blocks\
```

Extract a block manually:

```powershell
tar -xf outer\blocks\000001_solid.tar.xz -C restore
```

If a tool does not recognize `.star`, rename the archive to `.tar` and inspect it manually.

---

## Safety Features

SmartTAR performs several safety checks during extraction and verification:

- validates that block paths in the manifest are relative and safe,
- rejects absolute paths,
- rejects drive-letter paths,
- rejects path traversal using `..`,
- lists TAR block contents before extraction,
- validates SHA-256 hashes when present.

These checks help reduce the risk of unsafe extraction paths.

---

## Limitations

- Compression support depends on the installed Windows `tar.exe` / bsdtar capabilities.
- ZSTD support may not be available on every Windows installation.
- Progress is shown as an indeterminate progress bar, not an exact percentage.
- Very large folder trees may take time during staging because files are copied into temporary grouped staging folders.
- The archive format is currently experimental and may change before a stable release.
- SmartTAR is not intended to replace mature production archivers at this stage.

---

## Recommended Default

For most users, use:

```text
Hybrid - recommended, balanced planner
```

This mode gives a practical balance between compression efficiency, speed, and avoiding unnecessary recompression of already-compressed media or archive files.

---

## Disclaimer

SmartTAR is a beta tool. Always verify important archives and keep independent backups of critical data.

Although the archive layout is designed to be transparent and recovery-friendly, no archiving tool can guarantee recovery from all forms of file corruption, hardware failure, interrupted writes, or unsupported compression engines.
