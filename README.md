![Repo size](https://img.shields.io/github/repo-size/eco-by-different/winzstd)
![Last commit](https://img.shields.io/github/last-commit/eco-by-different/winzstd)

# SmartTAR - STAR

**SmartTAR - STAR** is an experimental Windows PowerShell GUI archiver built on top of the native Windows `tar.exe` (bsdtar) engine.

It creates transparent `.star` archives containing:
- An outer TAR container
- A central `manifest.json` file
- Internal compressed TAR blocks
- SHA-256 block integrity hashes
- Recovery-friendly metadata

SmartTAR focuses on **transparent recovery, human-readable archive structure, and automatic compression planning** instead of using a proprietary black-box format.

> Current status: v1.0

---

## Highlights

- **Native GUI:** Built with PowerShell and Windows Forms (WinForms).
- **Zero Dependencies:** Relies strictly on the built-in Windows `tar.exe`.
- **Flexible Extensions:** Uses `.star` by default; supports legacy `.sarc.tar`.
- **Structured Layout:** Block-based architecture managed via a JSON manifest.
- **Intelligent Planning:** Four distinct compression modes:
  - `Hybrid` — Recommended balanced automated planner
  - `Smart` — Granular file-type grouping
  - `Solid` — Single auto-selected compression block
  - `Smart XZ` — Granular grouping optimized for XZ9 compression
  - `Store` — No internal compression.
- **Dynamic Detection:** Automatic capability testing for available TAR compression algorithms.
- **Integrity Validation:** Strict SHA-256 hashing for all internal blocks.
- **Safety First:** Path-traversal protection and extraction safety checks.
- **Audit Logs:** Detailed operation reports for creation, extraction, and verification.

---

## Screenshot

![SmartTAR STAR GUI](docs/images/smarttar-gui.png)

---

## Archive Design

A `.star` archive is a standard, uncompressed TAR file. SmartTAR organizes data inside this container as follows:

```text
archive.star
├── manifest.json
└── blocks/
    ├── 000001_structure.tar
    ├── 000002_text.tar.xz
    ├── 000003_binary.tar.zst
    └── ...
```

The `manifest.json` stores archive metadata, source profiles, compression modes, block lists, SHA-256 hashes, sizes, and deterministic timestamps. 

Because the outer container is a standard TAR file, it can be inspected natively by any standard archive manager.

---

## Compression Methods

SmartTAR performs a runtime capability test on `tar.exe` and utilizes only the supported algorithms.


| Method | Extension | Target Data & Purpose |
| :--- | :--- | :--- |
| **STORE** | `.tar` | No compression. Used for directory structures, media, and pre-compressed files. |
| **GZIP** | `.tar.gz` | Standard fallback compression. |
| **BZIP2** | `.tar.bz2` | High-ratio fallback compression. |
| **XZ9** | `.tar.xz` | XZ compression at maximum level 9 (when supported). |
| **XZ** | `.tar.xz` | Standard XZ compression fallback. |
| **ZSTD19** | `.tar.zst` | Zstandard compression at level 19 (when supported). |

*Note: If a preferred high-ratio method is unavailable, SmartTAR automatically falls back to the next best alternative.*

---

## Compression Modes

### Hybrid (Recommended)
The default balanced planner. It groups files into four broad categories:
- `structure`: Directory hierarchy (Stored).
- `compressible`: General text and documents (Prefers XZ9/XZ).
- `diskimage`: Virtual disks and raw images (Prefers ZSTD19).
- `stored`: Media and archives (Stored to prevent redundant compression).

### Smart
A granular grouping mode that segregates files into specific blocks:
- Text & Unknown data (Prefers XZ9/XZ)
- Binary, Executables & Disk Images (Prefers ZSTD19)
- Media & Archives (Stored)

### Solid
Consolidates all files into a single main block. The compression method is auto-selected based on the dominant file type in the source payload (ZSTD19 for binaries, XZ9/XZ otherwise).

### Smart XZ
Follows the same granular grouping as **Smart** mode, but forces all compressible groups to use XZ9/XZ.

---

## Deterministic Timestamp Handling

To optimize deduplication and block consistency, SmartTAR includes targeted timestamp stabilization for XZ/XZ9 blocks.

When an XZ-based block is generated, SmartTAR normalizes the timestamps within those specific staging trees to a fixed baseline:
```text
2000-01-01T00:00:00Z
```

**Key Behaviors:**
- Normalization applies **only** to XZ/XZ9 block stages.
- STORE, GZIP, BZIP2, and ZSTD stages preserve their original timestamps.
- The `manifest.json` logs whether deterministic metadata was applied and its exact scope.

---

## Requirements

- **OS:** Windows 10 / 11 or Windows Server.
- **Environment:** Windows PowerShell (or PowerShell 7+) with WinForms support.
- **Engine:** Windows `tar.exe` located in `%SystemRoot%\System32\` or available via system `PATH`.

*No external binaries or third-party archiving tools are required.*

---

## How to Run

1. Save the script to: `src/SmartTAR.ps1`
2. Open PowerShell and execute the GUI using the appropriate command:

**Windows PowerShell (Built-in):**
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\src\SmartTAR.ps1
```

**PowerShell 7+ (Core):**
```powershell
pwsh.exe -ExecutionPolicy Bypass -File .\src\SmartTAR.ps1
```

---

## Basic Usage

### Create an Archive
1. Click **Add FILE** or **Add FOLDER** to load your source data.
2. Define your destination archive path.
3. Select a **Compression Mode** (e.g., *Hybrid*).
4. Click **COMPRESS**. A creation report will be generated alongside the new archive.

### Extract an Archive
1. Click **Add ARCHIVE** and select a `.star` or `.sarc.tar` file.
2. Specify the target destination folder.
3. Click **EXTRACT**. SmartTAR will validate the blocks and unpack the contents safely.

### Verify an Archive
1. Click **Add ARCHIVE**.
2. Click **VERIFY**.
3. The engine will perform a full structural audit: checking container readability, manifest validity, block sizes, and SHA-256 integrity hashes.

---

## Reports

SmartTAR automatically generates detailed text logs in the destination directory:

```text
archive.star.create_report.20260101_120000.txt
archive.star.extract_report.20260101_120000.txt
archive.star.verify_report.20260101_120000.txt
```
Reports contain operation benchmarks, compression ratios, applied methods, deterministic scopes, and block-by-block verification results.

---

## Manual Recovery

Since the `.star` format is built entirely on open standards, you do not need SmartTAR to recover your data. If the GUI is unavailable, extract the files manually using any command-line tool:

1. **Extract the outer container:**
   ```powershell
   tar -xf archive.star -C outer_extraction/
   ```
2. **Inspect the contents:** Navigate to `outer_extraction/manifest.json` and the `blocks/` directory.
3. **Extract individual data blocks:**
   ```powershell
   tar -xf outer_extraction/blocks/000002_text.tar.xz -C restored_data/
   ```
*(Note: If your extraction tool does not recognize the `.star` extension, simply rename the file to `.tar`)*

---

## Safety Features

To prevent malicious exploits during extraction, SmartTAR enforces strict safety checks:
- **Path Sanitization:** Rejects absolute paths and drive letters (`C:\`) in the manifest.
- **Traversal Protection:** Blocks path traversal attempts (e.g., `../`).
- **Dry-Run Inspection:** Pre-lists TAR block contents before writing to disk.
- **Integrity Enforcement:** Fails extraction if SHA-256 hashes do not match the manifest records.

---

## Limitations

- **Dependency Limits:** Feature availability (like ZSTD) relies entirely on the capabilities of the host's `tar.exe`.
- **UI Progress:** Progress indicators are currently indeterminate (marquee) due to limitations in native `tar.exe` CLI output parsing.
- **Staging Overhead:** Large folder trees require temporary disk space and time during the staging/grouping phase.
- **Status:** The format is experimental. Layouts and manifest schemas may change in future releases.

---

## Disclaimer

SmartTAR is currently a **Beta** tool. Always verify critical archives and maintain independent backups. 

While the architecture is explicitly designed for high transparency and manual recovery, no software can guarantee recovery from severe physical drive corruption, interrupted write cycles, or non-compliant system environments.
