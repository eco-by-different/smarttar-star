![Repo size](https://img.shields.io/github/repo-size/eco-by-different/winzstd)
![Last commit](https://img.shields.io/github/last-commit/eco-by-different/winzstd)

# SmartTAR STAR v1.2.2

## Release Title

**v1.2.2 - Full Sequential Build Pipeline, Compact Manifest, Hidden Work Folder, and Stable STAR Compatibility**

---

## Release Notes

SmartTAR STAR v1.2.2 is a stability, storage-efficiency, and cleanup release for the STAR v1.2 line.

This release introduces a new full sequential block publishing pipeline.  
Instead of creating all archive blocks first and only then wrapping them into the final `.star` container, SmartTAR now creates each block, appends it into the outer STAR archive, and immediately removes the standalone block file.

This significantly reduces peak temporary disk usage during archive creation.

SmartTAR v1.2.2 also introduces a compact production manifest, a hidden destination-local work folder, and cleaner user-facing reports while keeping optional debug diagnostics available internally.

> SmartTAR is not a custom compression engine.  
> It is a smart PowerShell GUI wrapper and STAR container orchestrator built on top of Windows `tar.exe` / `bsdtar`.

The archive format version remains compatible with the existing STAR v1.x layout:

```text
formatVersion = 1
```

---

# Antivirus Notice (False Positives)

The `.exe` binary is generated using IExpress, which some sensitive antivirus engines, including Windows Defender or machine-learning based scanners, may flag as a false positive.

The underlying PowerShell script is clean.  
If your system blocks the `.exe`, you can safely run the raw `SmartTAR.ps1` script instead.

---

## Screenshot


![SmartTAR screenshot](docs/images/smarttar-gui.png)

---

## Main Highlights

```text
full sequential block publish pipeline
lower peak temporary disk usage
compact production manifest
hidden destination-local work folder
manifest-based duplicate file alias restore
optional debug diagnostics
C# native content analyzer
faster Smart profile planning
stable Verify / Extract behavior
STAR formatVersion = 1 compatibility
```

---

## Full Sequential Block Publishing

Previous SmartTAR builds used an all-blocks-first model:

```text
create all blocks
keep all block files on disk
create final outer .star archive
clean up temporary files
```

SmartTAR STAR v1.2.2 replaces this with a full sequential publishing model:

```text
create one block
append block into the outer .star.tmp container
delete standalone block file
continue with the next block
append manifest.json as the last outer entry
rename .star.tmp to final .star
```

This reduces peak temporary disk usage because SmartTAR no longer needs to keep all generated block files and the final STAR archive at the same time.

---

## Hidden Destination-Local Work Folder

SmartTAR now creates its build work folder next to the destination archive.

The work folder is now hidden by default:

```text
.SmartTAR_Work
```

On Windows, SmartTAR also applies the `Hidden` file attribute to this folder.

Example:

```text
C:\Users\User\Desktop\.SmartTAR_Work
```

The final temporary archive file remains visible during publishing:

```text
ArchiveName.star.tmp
```

This keeps the internal work folder out of the way while preserving predictable destination-local disk usage.

---

## Compact Manifest

SmartTAR STAR v1.2.2 uses a compact production manifest by default.

The manifest now focuses on:

```text
core archive metadata
source information
compression profile
build pipeline summary
block metadata
dedup alias metadata
verification hashes
short user-facing summary
```

Verbose development diagnostics are no longer written into the manifest by default.

Removed from the default manifest:

```text
large source profile dumps
full adaptive analysis diagnostics
full file dedup diagnostics
full planning diagnostics
temporary catalog paths
temporary dedup map paths
temporary build plan paths
```

This keeps the archive manifest easier to read and avoids storing temporary local build paths.

---

## Optional Debug Diagnostics

Debug diagnostics are still available when needed.

By default, debug output is disabled:

```powershell
$script:IncludeDebugDiagnosticsInManifest = $false
$script:ExportDebugBundle = $false
$script:KeepDebugArtifacts = $false
```

If a problem needs deeper investigation, these variables can be enabled in a debug build to include or preserve additional diagnostic data.

This gives SmartTAR a cleaner production manifest while keeping development diagnostics available when required.

---

## Manifest-Based File Deduplication

SmartTAR STAR v1.2.2 keeps the unique-only manifest alias dedup model.

Duplicate files are omitted from data blocks and restored during extraction from manifest aliases.

The archive stores:

```text
one physical copy of duplicate file content
manifest aliases for duplicate paths
alias restore information for extraction
```

Example dedup summary:

```text
File dedup: ON
Dedup mode: unique-only-restored-on-extract
STAR manifest aliases: 5
Alias bytes: 18.31 MB
```

During extraction, SmartTAR restores alias files from their stored target files:

```text
Dedup alias restore:
Aliases: 5, restored: 5, errors: 0
```

---

## C# Native Analyzer

SmartTAR continues to use the embedded C# native analyzer introduced in the v1.2 line.

The native analyzer handles:

```text
sample reading
magic byte detection
zero-byte counting
unique byte counting
entropy calculation
text / binary / archive-like classification
```

This makes the `Smart - max compression` planning phase significantly faster, especially when analyzing many files.

PowerShell remains responsible for:

```text
GUI
workflow orchestration
staging
tar.exe / bsdtar execution
manifest generation
verification
extraction
reporting
```

---

## Smart Profile Behavior

The `Smart - max compression` profile uses content-aware planning.

Current Smart strategy:

```text
structure metadata              → XZ9
text-like data                  → XZ9
binary / executable-like data   → XZ9 or best available high-density method
archive-like data               → STORE
unknown data                    → XZ9
```

Archive-like or already-compressed data is stored without unnecessary recompression.  
Compressible data is grouped and compressed using the best available configured method.

This avoids wasting CPU on data that is already compressed while still achieving strong compression on text, binary, and structured data.

---

## Compression Profiles

Available profiles:

```text
Balanced - mixed blocks
Smart - max compression
Solid - single block
Store - no compression
```

---

## STAR Format Compatibility

SmartTAR STAR v1.2.2 keeps the STAR archive format version compatible with the existing v1.x layout.

The internal manifest still uses:

```text
formatVersion = 1
```

A typical Smart archive layout may contain:

```text
blocks/
  000001_structure.tar.xz
  000002_text.tar.xz
  000003_unknown.tar.xz
  000004_archives.tar
  000005_binary.tar.xz
manifest.json
```

In v1.2.2, `manifest.json` is appended as the last outer STAR entry.

Each block remains a standard tar-compatible unit:

```text
.tar
.tar.xz
.tar.zst
```

The STAR container adds:

```text
manifest metadata
block grouping
block hashing
verification
dedup alias restore
salvage-friendly structure
```

---

## User-Facing Report Cleanup

SmartTAR v1.2.2 replaces verbose diagnostic-style output with shorter summaries.

The report now focuses on:

```text
archive size
compression ratio
saved percentage
compression groups
compression method summary
archive summary
file dedup summary
build summary
verification result
dedup alias verification / restore result
```

Example report sections:

```text
Archive summary:
Compression profile: Smart - max compression

File dedup summary:
File dedup: ON
STAR manifest aliases: 5
Stored unique source: 397.06 MB

Build summary:
Build pipeline: full-sequential-block-publish
Block cleanup: after-append
Manifest position: last-outer-entry
```

---

## Validation Summary

SmartTAR STAR v1.2.2 was validated across the main workflows:

```text
Smart - max compression   OK
Store - no compression    OK
Verify                    OK
Extract                   OK
Dedup alias restore       OK
Cross-drive workflow      OK
```

Example validation result:

```text
Source size: 415.37 MB
Archive size: 136.54 MB
Ratio: 32.87 %
Saved: 67.13 %
Blocks OK: 5
Blocks failed: 0
Verification: OK
Dedup alias verification: OK
Dedup alias restore: errors: 0
```

The following workflow was also validated:

```text
source on one drive
archive created on another drive
archive verified from destination drive
archive extracted back to another drive
```

---

## What Changed Since v1.2.1

Added:

```text
full sequential block publish pipeline
destination-local hidden work folder
compact production manifest
optional debug diagnostics switch
manifest-last outer STAR layout
block cleanup immediately after append
```

Changed:

```text
archive creation no longer depends on the old all-blocks-first build model
default manifest is now compact instead of diagnostic-heavy
report output is shorter and more user-focused
work folder is now .SmartTAR_Work and hidden
```

Removed from the default production path:

```text
old Build-Blocks all-blocks compression path
verbose diagnostics in default manifest
temporary work paths in default manifest
per-alias duplicate mode field
```

Still preserved:

```text
STAR formatVersion = 1
Verify compatibility
Extract compatibility
Smart profile behavior
C# native analyzer
manifest alias dedup restore
salvage-friendly block layout
```

---

## Design Philosophy

SmartTAR STAR is not intended to replace specialized compression engines.

Instead, SmartTAR focuses on:

```text
smart block planning
content-aware grouping
safe use of Windows tar.exe / bsdtar
clear compact manifest structure
block-level verification
manifest-based duplicate file restore
salvage-friendly archive layout
low peak temporary disk usage
no external compressor dependencies
```

SmartTAR gets more practical value from the built-in Windows archiving backend through better orchestration.

---

## Summary

SmartTAR STAR v1.2.2 is a stability and architecture cleanup release for the STAR v1.2 line.

Main improvements:

```text
full sequential block publish
lower peak temporary disk usage
compact production manifest
hidden destination-local work folder
optional debug diagnostics
manifest alias dedup restore
stable Verify / Extract behavior
STAR formatVersion = 1 compatibility
```

This release is the recommended stable v1.2.x build.

---

## License

MIT License

Copyright (c) 2026 Jan Simak

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
