# SmartTAR STAR Archive Format

**Document:** `archive-format`  
**Project:** SmartTAR STAR v1.2.0  
**Build family:** SmartTAR STAR v1.2 stable  
**Current reference implementation:** `SmartTAR 1.2.ps1`  
**Container engine:** Windows `tar.exe` / `bsdtar`  
**Primary extension:** `.star`

---

## 1. Purpose

SmartTAR STAR is a transparent archive container format built on top of standard TAR-compatible building blocks.

SmartTAR is not a custom compression engine. It is a smart PowerShell wrapper and STAR container orchestrator built on top of Windows `tar.exe` / `bsdtar`.

The format is designed to be:

- manually recoverable with standard `tar.exe`,
- readable without a proprietary binary parser,
- structured around a JSON manifest,
- able to contain one or more internal TAR / TAR.XZ / TAR.ZST blocks,
- root-folder preserving,
- safe against path traversal during extraction,
- suitable for Balanced / Smart / Solid / Store compression profiles,
- block-verifiable using SHA256 hashes,
- salvage-friendly because payload data is split into independent internal blocks.

The most important design rule remains:

> **No folder-name deduplication.**  
> The selected root folder is preserved exactly.  
> Same-name child folders are valid content and must not be removed.

---

## 2. File extension

Recommended extension:

```text
.star
```

A `.star` file is internally a standard TAR archive. Therefore, if needed, a `.star` file can be inspected manually using:

```powershell
tar -tf archive.star
```

or extracted manually using:

```powershell
tar -xf archive.star -C outer
```

After extracting the outer container, the internal block files can be inspected or extracted individually with `tar.exe`.

---

## 3. Outer container layout

A STAR archive is a plain outer TAR container containing at minimum:

```text
manifest.json
blocks/
```

Example outer structure for the Smart profile:

```text
archive.star
├─ manifest.json
└─ blocks
   ├─ 000001_structure.tar.xz
   ├─ 000002_text.tar.xz
   ├─ 000003_unknown.tar.xz
   ├─ 000004_archives.tar
   └─ 000005_binary.tar.xz
```

The outer TAR container itself is not compressed. Compression is handled inside the internal block files.

Each internal block remains a standard tar-compatible unit:

```text
.tar
.tar.xz
.tar.zst
```

---

## 4. Manifest

The archive manifest is stored as UTF-8 JSON:

```text
manifest.json
```

The manifest describes:

- archive format,
- format version,
- SmartTAR tool version,
- backend engine,
- STAR model name,
- selected compression mode,
- selected compression profile,
- compression preference,
- content analysis scope,
- source name and source type,
- source size,
- source profile summary,
- adaptive analysis diagnostics,
- block list,
- SHA256 hash for each block.

---

## 5. Example manifest

```json
{
  "format": "STAR",
  "formatVersion": 1,
  "tool": "SmartTAR",
  "toolVersion": "1.2",
  "createdUtc": "2026-06-12T00:00:00Z",
  "engine": "Windows tar.exe",
  "model": "STAR v1.2",
  "compressionMode": "Smart",
  "compressionProfile": "Smart - max compression",
  "compressionPreference": "MaxCompression",
  "analysisScope": "FullAnalyze",
  "sourceName": "example-folder",
  "sourceType": "Folder",
  "sourceBytes": 435542769,
  "sourceProfile": {
    "fileCount": 3006,
    "dirCount": 232
  },
  "adaptiveDiagnostics": {
    "enabled": true,
    "analysisScope": "FullAnalyze",
    "unknownSeen": 3006,
    "unknownBytes": 435542769,
    "movedToText": 2488,
    "movedToBinary": 419,
    "movedToArchives": 89,
    "stayedUnknown": 10
  },
  "blocks": [
    {
      "id": "000001",
      "group": "structure",
      "path": "blocks/000001_structure.tar.xz",
      "method": "xz9",
      "display": "XZ9",
      "algorithm": "xz",
      "fileCount": 0,
      "dirCount": 232,
      "sourceBytes": 0,
      "sizeBytes": 2524,
      "sha256": "0123456789abcdef..."
    },
    {
      "id": "000002",
      "group": "text",
      "path": "blocks/000002_text.tar.xz",
      "method": "xz9",
      "display": "XZ9",
      "algorithm": "xz",
      "fileCount": 2488,
      "dirCount": 0,
      "sourceBytes": 25784422,
      "sizeBytes": 3894740,
      "sha256": "abcdef0123456789..."
    },
    {
      "id": "000004",
      "group": "archives",
      "path": "blocks/000004_archives.tar",
      "method": "store",
      "display": "STORE",
      "algorithm": "store",
      "fileCount": 89,
      "dirCount": 0,
      "sourceBytes": 12750684,
      "sizeBytes": 12835328,
      "sha256": "fedcba9876543210..."
    }
  ]
}
```

The exact shape of `sourceProfile` and `adaptiveDiagnostics` may evolve between builds, but the top-level manifest and block list are the primary compatibility contract.

---

## 6. Manifest fields

### 6.1 Required top-level fields

| Field | Type | Description |
|---|---:|---|
| `format` | string | Must be `STAR`. |
| `formatVersion` | integer | Format version. Current value: `1`. |
| `tool` | string | Tool name. Usually `SmartTAR`. |
| `toolVersion` | string | Tool version. Current stable value: `1.2`. |
| `createdUtc` | string | Archive creation time in UTC. |
| `engine` | string | Backend engine. Usually `Windows tar.exe`. |
| `model` | string | STAR model name, e.g. `STAR v1.2`. |
| `compressionMode` | string | Internal compression mode, e.g. `Smart`, `Balanced`, `Solid`, `Store`. |
| `compressionProfile` | string | User-facing compression profile name. |
| `compressionPreference` | string | Compression preference used by the mode, e.g. `Balanced` or `MaxCompression`. |
| `analysisScope` | string | Content analysis scope, e.g. `None`, `UnknownOnly`, `FullAnalyze`. |
| `sourceName` | string | Selected root file/folder name. |
| `sourceType` | string | `Folder` or `File`. |
| `sourceBytes` | integer | Original source size in bytes. |
| `blocks` | array | Internal block list. |

### 6.2 Optional top-level fields

| Field | Type | Description |
|---|---:|---|
| `sourceProfile` | object | Summary of source content. |
| `adaptiveDiagnostics` | object | Content analysis diagnostics. |
| `notes` | string/array | Human-readable notes. |
| `compatibility` | object | Optional compatibility information. |
| `manualRecovery` | array | Optional manual recovery commands. |

---

## 7. Block object fields

Each block entry describes one internal TAR, TAR.XZ, or TAR.ZST file.

| Field | Type | Description |
|---|---:|---|
| `id` | string | Stable block ID, e.g. `000001`. |
| `group` | string | Logical group name, e.g. `structure`, `text`, `binary`, `archives`, `stored`. |
| `path` | string | Relative path inside the outer STAR archive. |
| `method` | string | Method name, e.g. `xz9`, `zstd19`, `store`. |
| `display` | string | Human-readable method name, e.g. `XZ9`, `ZSTD19`, `STORE`. |
| `algorithm` | string | Compression algorithm, e.g. `xz`, `zstd`, `store`. |
| `fileCount` | integer | Number of files staged into the block. |
| `dirCount` | integer | Number of directories staged into the block. |
| `sourceBytes` | integer | Source bytes represented by the block. |
| `sizeBytes` | integer | Actual block file size. |
| `sha256` | string | SHA256 hash of the block file. |

---

## 8. Root preservation rule

SmartTAR STAR archives preserve the selected root folder.

If the selected source is:

```text
Z:\avinaptic-win64-20231012
```

and the source contains:

```text
Z:\avinaptic-win64-20231012\avinaptic-win64-20231012
Z:\avinaptic-win64-20231012\avinaptic.cfg
Z:\avinaptic-win64-20231012\avinaptic2.exe
```

then internal payload paths preserve the selected root prefix:

```text
avinaptic-win64-20231012/avinaptic-win64-20231012/...
avinaptic-win64-20231012/avinaptic.cfg
avinaptic-win64-20231012/avinaptic2.exe
```

The following would be invalid for a root-preserving folder archive:

```text
avinaptic.cfg
avinaptic2.exe
```

because those paths do not contain the selected root prefix.

---

## 9. No deduplication rule

SmartTAR STAR must not remove or skip folders only because the folder name matches the archive root name.

This case is valid and must be preserved:

```text
root
└─ root
   └─ file.txt
```

Example:

```text
avinaptic-win64-20231012
└─ avinaptic-win64-20231012
```

The extracted result must be:

```text
target\avinaptic-win64-20231012\avinaptic-win64-20231012
```

No folder-name deduplication is allowed.

---

## 10. Compression profiles

### 10.1 Balanced - mixed blocks

Recommended default profile.

Typical grouping:

```text
compressible  → XZ9
diskimage     → ZSTD19, if applicable
stored        → STORE
```

Known archive-like and media-like files are usually stored. Unknown files are analyzed only when needed.

Analysis scope:

```text
UnknownOnly
```

---

### 10.2 Smart - max compression

Maximum compression profile.

Smart performs full content analysis and uses XZ9 for compressible data.

Typical grouping:

```text
structure → XZ9
text      → XZ9
unknown   → XZ9
binary    → XZ9
archives  → STORE
```

Analysis scope:

```text
FullAnalyze
```

---

### 10.3 Solid - single block

Single-block profile.

Typical grouping:

```text
solid → one automatically selected method
```

The Solid profile is useful when a simple single data block is preferred. Depending on the source profile and available methods, the selected method may be XZ9 or ZSTD19.

Analysis scope:

```text
UnknownOnly
```

---

### 10.4 Store - no compression

No internal compression.

Typical grouping:

```text
store → STORE
```

Useful for speed, reference tests, or data that should not be recompressed.

Analysis scope:

```text
None
```

---

## 11. Block compression methods

### 11.1 STORE block

Extension:

```text
.tar
```

Typical creation command:

```powershell
tar -cf block.tar -C stage .
```

---

### 11.2 XZ9 block

Extension:

```text
.tar.xz
```

Typical creation command:

```powershell
tar --options xz:compression-level=9 -cJf block.tar.xz -C stage .
```

If XZ9 is not supported by the installed `tar.exe`, the implementation may fall back to another available method or STORE, depending on the block type.

---

### 11.3 ZSTD19 block

Extension:

```text
.tar.zst
```

Typical creation command:

```powershell
tar --zstd --options zstd:compression-level=19 -cf block.tar.zst -C stage .
```

ZSTD19 is mainly useful as a speed-oriented high-compression option for selected block strategies, especially where XZ9 is not the best practical trade-off.

---

## 12. Structure block

The directory structure block stores the directory skeleton of folder archives.

In SmartTAR STAR v1.2.0, the structure block is compressed with XZ9 when available:

```text
000001_structure.tar.xz
```

If XZ9 structure block creation fails, the implementation safely falls back to STORE:

```text
000001_structure.tar
```

The structure block remains separate from payload blocks for clarity, verification, and salvage safety.

---

## 13. Timestamp policy

SmartTAR may normalize selected staging metadata for compressed blocks to improve stable block behavior.

The reference implementation uses a stable timestamp baseline for XZ-related staging behavior:

```text
2000-01-01T00:00:00Z
```

Exact timestamp behavior may still depend on Windows `tar.exe`, filesystem behavior, and the selected block method.

---

## 14. Archive creation algorithm

High-level algorithm:

```text
1. Normalize selected source path.
2. Determine selected root name from source path.
3. Create temporary work directory.
4. Test available tar.exe capabilities.
5. Build a source profile.
6. Select compression profile.
7. Create archive groups for the selected profile.
8. Create a structure stage for directory metadata.
9. Analyze file content according to the selected analysis scope.
10. Assign files to logical groups.
11. Create one internal block per non-empty group.
12. Compress or store each block using its assigned method.
13. Hash every block with SHA256.
14. Write manifest.json.
15. Create outer .star TAR container with manifest.json and blocks/.
16. Verify the created archive.
17. Clean temporary work directory.
```

Important staging rule:

```text
relative path = path relative to parent of selected root
```

Example:

```text
source        = Z:\A
source parent = Z:\
file          = Z:\A\B\file.txt
relative path = A\B\file.txt
```

---

## 15. Extraction algorithm

High-level algorithm:

```text
1. Extract outer .star container into a temporary outer folder.
2. Read manifest.json.
3. For every block:
   a. Validate block path.
   b. Verify SHA256 hash when available.
   c. List block entries to detect unsafe paths.
   d. Extract block into a temporary payload folder.
4. Determine root name from manifest.sourceName.
5. Copy payload content into the final destination.
6. Clean temporary work directory.
```

No folder-name deduplication is performed.

---

## 16. Safe path requirements

Relative paths inside manifest and blocks must not contain:

```text
absolute paths
Windows drive paths, e.g. C:\
UNC paths
.. path traversal
```

Invalid examples:

```text
C:\Windows\file.txt
\\server\share\file.txt
../file.txt
folder/../../file.txt
```

Valid examples:

```text
root/file.txt
root/folder/file.txt
./
```

---

## 17. Verification

Verification checks:

```text
1. The outer STAR container can be extracted.
2. manifest.json exists and can be parsed.
3. Every manifest block path is safe.
4. Every referenced block exists.
5. Every block can be listed by tar.exe.
6. Every block SHA256 hash matches the manifest value when present.
```

A successful verification report shows:

```text
Verification: OK
Blocks failed: 0
```

---

## 18. Salvage behavior

Because STAR uses independent internal blocks, healthy blocks can still be extracted even if another block is damaged.

Salvage mode may skip failed blocks and extract the remaining valid blocks.

This is one of the key advantages of the STAR block model compared to a single monolithic compressed stream.

---

## 19. Manual recovery

Because STAR is TAR-based, the archive can be inspected manually.

### Step 1: Extract outer container

```powershell
mkdir outer
tar -xf archive.star -C outer
```

### Step 2: Inspect manifest

```powershell
type outer\manifest.json
```

### Step 3: List blocks

```powershell
dir outer\blocks
```

### Step 4: Extract a block manually

For an XZ9 block:

```powershell
mkdir restore
tar -xf outer\blocks\000002_text.tar.xz -C restore
```

For a STORE block:

```powershell
tar -xf outer\blocks\000004_archives.tar -C restore
```

For the structure block:

```powershell
tar -xf outer\blocks\000001_structure.tar.xz -C restore
```

---

## 20. Compatibility notes

A STAR archive is not a ZIP file.

It is a TAR-based container with this structure:

```text
outer TAR
├─ manifest.json
└─ blocks
   ├─ internal TAR / TAR.XZ / TAR.ZST block
   └─ internal TAR / TAR.XZ / TAR.ZST block
```

A generic archive tool may show only the outer layer first.
Manual extraction may require extracting the outer container and then extracting internal blocks.

---

## 21. Recommended file naming

Recommended archive names:

```text
project-name.star
folder-name.star
backup-name_yyyyMMdd_HHmmss.star
```

Recommended block naming:

```text
000001_structure.tar.xz
000002_text.tar.xz
000003_unknown.tar.xz
000004_archives.tar
000005_binary.tar.xz
```

---

## 22. Current known design decisions

- The selected root folder is always preserved.
- Same-name child folders are valid content.
- No folder-name deduplication is allowed.
- Blocks are independently recoverable.
- The manifest is mandatory.
- SHA256 verification is mandatory for block integrity.
- `.star` remains manually recoverable using standard TAR tooling.
- SmartTAR remains a wrapper over Windows `tar.exe` / `bsdtar`.
- No external compressor dependency is required.
- Structure metadata is stored in a separate structure block.
- The structure block is compressed with XZ9 when available.

---

## 23. Version notes

### SmartTAR STAR v1.2.0

Key changes:

- Introduces CPU-aware parallel content analysis using PowerShell RunspacePool.
- Uses safe worker scaling: 1 / 2 / 4 workers depending on logical CPU count.
- Cleans up user-facing profiles to Balanced / Smart / Solid / Store.
- Removes old Hybrid / SmartXZ naming from stable workflow.
- Improves Smart max-compression profile behavior.
- Compresses the structure block as `structure.tar.xz` when XZ9 is available.
- Keeps STORE fallback for structure block creation.
- Keeps SHA256 verification per block.
- Keeps transparent TAR-based recovery model.
- Simplifies stable report output.

---

## 24. Minimal compliance checklist

A valid STAR v1 archive should satisfy:

```text
[ ] Outer archive contains manifest.json
[ ] Outer archive contains blocks/
[ ] manifest.format == STAR
[ ] manifest.formatVersion == 1
[ ] manifest.sourceName is present
[ ] manifest.sourceType is Folder or File
[ ] Every block path is relative and safe
[ ] Every block exists in blocks/
[ ] Every block SHA256 matches manifest
[ ] Folder archive payload preserves the selected root name
[ ] No same-name folder is skipped during extraction
[ ] Structure block is readable by tar.exe
```

---

## 25. Example expected result

Source:

```text
Z:\avinaptic-win64-20231012
├─ avinaptic-win64-20231012
├─ avinaptic.cfg
├─ avinaptic2.exe
└─ iup.dll
```

Extraction target:

```text
Z:\Restore
```

Expected result:

```text
Z:\Restore\avinaptic-win64-20231012
├─ avinaptic-win64-20231012
├─ avinaptic.cfg
├─ avinaptic2.exe
└─ iup.dll
```

This result is correct because the inner `avinaptic-win64-20231012` folder is real content, not a duplicate to remove.
