# SmartTAR STAR Archive Format

**Document:** `archive-format`  
**Project:** SmartTAR STAR 1.0 Beta 1  
**Build family:** Root Preserving Smart Hybrid  
**Current reference implementation:** `root-preserving-smart-hybrid-v8`  
**Container engine:** Windows `tar.exe` / `bsdtar`  
**Primary extension:** `.star`

---

## 1. Purpose

SmartTAR STAR is a transparent archive format built on top of standard TAR containers.

The format is designed to be:

- manually recoverable with standard `tar.exe`,
- readable without a proprietary binary parser,
- structured around a JSON manifest,
- able to contain one or more internal TAR/TAR.XZ blocks,
- root-folder preserving,
- safe against path traversal during extraction,
- suitable for Smart / Hybrid / Solid / Store compression strategies.

The most important design rule is:

> **No folder-name deduplication.**  
> The selected root folder is preserved exactly.  
> Every internal block contains the selected root prefix.

---

## 2. File extension

Recommended extension:

```text
.star
```

Legacy or compatible extension:

```text
.sarc.tar
```

A `.star` file is internally a standard TAR archive. Therefore, if needed, a `.star` file can be inspected manually using:

```powershell
tar -tf archive.star
```

or extracted manually using:

```powershell
tar -xf archive.star -C outer
```

---

## 3. Outer container layout

A STAR archive is a TAR file containing at minimum:

```text
manifest.json
blocks/
```

Example outer structure:

```text
archive.star
├─ manifest.json
└─ blocks
   ├─ 000001_compressible.tar.xz
   ├─ 000002_stored.tar
   └─ 000003_text.tar.xz
```

The outer TAR container is always created as a plain TAR container.
Compression is handled inside the block files.

---

## 4. Manifest

The archive manifest is stored as UTF-8 JSON:

```text
manifest.json
```

The manifest describes:

- archive format,
- tool version,
- source root name,
- source type,
- compression mode,
- root preservation rule,
- deterministic timestamp policy,
- block list,
- SHA256 hash for each block.

---

## 5. Example manifest

```json
{
  "format": "STAR",
  "formatVersion": 1,
  "tool": "SmartTAR",
  "toolVersion": "root-preserving-smart-hybrid-v8",
  "createdUtc": "2026-06-04T00:00:00Z",
  "engine": "Windows tar.exe",
  "mode": "Hybrid",
  "sourceName": "avinaptic-win64-20231012",
  "sourceType": "Folder",
  "sourceBytes": 123456789,
  "rootRule": "No deduplication. Every block contains the selected root prefix.",
  "deterministicMetadata": {
    "enabled": true,
    "timestampUtc": "2000-01-01T00:00:00Z",
    "scope": "XZ9 blocks only"
  },
  "blocks": [
    {
      "id": "000001",
      "group": "compressible",
      "path": "blocks/000001_compressible.tar.xz",
      "method": "xz9",
      "compression": "xz",
      "fileCount": 25,
      "dirCount": 4,
      "sourceBytes": 1234567,
      "sizeBytes": 456789,
      "sha256": "0123456789abcdef..."
    },
    {
      "id": "000002",
      "group": "stored",
      "path": "blocks/000002_stored.tar",
      "method": "store",
      "compression": "store",
      "fileCount": 3,
      "dirCount": 4,
      "sourceBytes": 987654,
      "sizeBytes": 987999,
      "sha256": "abcdef0123456789..."
    }
  ]
}
```

---

## 6. Manifest fields

### 6.1 Required top-level fields

| Field | Type | Description |
|---|---:|---|
| `format` | string | Must be `STAR`. |
| `formatVersion` | integer | Format version. Current value: `1`. |
| `tool` | string | Tool name. Usually `SmartTAR`. |
| `toolVersion` | string | Tool/build version. |
| `createdUtc` | string | Archive creation time in UTC. |
| `engine` | string | Backend engine. Usually `Windows tar.exe`. |
| `mode` | string | Compression mode used. |
| `sourceName` | string | Selected root file/folder name. |
| `sourceType` | string | `Folder` or `File`. |
| `sourceBytes` | integer | Original source size in bytes. |
| `rootRule` | string | Root preservation rule text. |
| `blocks` | array | Internal block list. |

### 6.2 Optional top-level fields

| Field | Type | Description |
|---|---:|---|
| `deterministicMetadata` | object | Timestamp normalization policy. |
| `notes` | string/array | Human-readable notes. |
| `compatibility` | object | Optional compatibility information. |
| `manualRecovery` | array | Optional manual recovery commands. |

---

## 7. Block object fields

Each block entry describes one internal TAR or TAR.XZ file.

| Field | Type | Description |
|---|---:|---|
| `id` | string | Stable block ID, e.g. `000001`. |
| `group` | string | Logical group name, e.g. `compressible`, `stored`, `text`. |
| `path` | string | Relative path inside outer STAR archive. |
| `method` | string | Method name, e.g. `xz9`, `store`. |
| `compression` | string | Compression algorithm, e.g. `xz`, `store`. |
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

then every internal block must contain paths with the selected root prefix:

```text
avinaptic-win64-20231012/avinaptic-win64-20231012/...
avinaptic-win64-20231012/avinaptic.cfg
avinaptic-win64-20231012/avinaptic2.exe
```

The following is invalid for root-preserving SmartTAR blocks:

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

## 10. Compression modes

### 10.1 Hybrid

Recommended default mode.

Typical grouping:

```text
compressible  -> XZ9
stored        -> STORE
```

Media, archive-like files and disk images are usually stored. Text, config, binaries and unknown data are usually compressed.

### 10.2 Smart

Detailed grouping by file type:

```text
text
binary
executable
diskimage
media
archives
```

Each group is stored in a separate internal block.

### 10.3 Smart XZ

Similar to Smart mode, but non-stored groups prefer XZ9.

### 10.4 Solid

One root-preserving internal block.

Useful for maximum structure safety and simple recovery.

### 10.5 Store

No internal compression.

Useful for speed and maximum compatibility.

---

## 11. Block compression methods

### STORE block

Extension:

```text
.tar
```

Typical creation command:

```powershell
tar -cf block.tar -C stage .
```

### XZ9 block

Extension:

```text
.tar.xz
```

Typical creation command:

```powershell
tar --options xz:compression-level=9 -cJf block.tar.xz -C stage .
```

If XZ9 is not supported by the installed `tar.exe`, implementation may fall back to STORE.

---

## 12. Timestamp policy

The reference v8 implementation uses partial deterministic timestamp handling.

### XZ9 blocks

XZ9 block stages may be normalized to:

```text
2000-01-01T00:00:00Z
```

This improves deterministic behavior of compressed blocks.

### STORE blocks

STORE blocks may preserve natural timestamps, depending on `tar.exe` behavior and filesystem behavior.

### Future recommended option

A future version should expose a UI option:

```text
[ ] Deterministic timestamps for compressed blocks
```

Recommended modes:

```text
Preserve original timestamps
Deterministic timestamps
```

---

## 13. Archive creation algorithm

High-level algorithm:

```text
1. Normalize selected source path.
2. Determine selected root name from source path.
3. Create temporary work directory.
4. Create staging directories for selected mode.
5. For every staged item, compute relative path from parent of selected root.
6. Copy every staged file into the selected group stage with root prefix preserved.
7. Create one block per non-empty group.
8. Hash every block with SHA256.
9. Write manifest.json.
10. Create outer .star TAR container with manifest.json and blocks/.
11. Clean temporary work directory.
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

## 14. Extraction algorithm

High-level algorithm:

```text
1. Extract outer .star container into temporary outer folder.
2. Read manifest.json.
3. For every block:
   a. Validate block path.
   b. Verify SHA256 hash.
   c. List block entries to detect unsafe paths.
   d. Extract block into temporary payload folder.
4. Determine root name from manifest.sourceName.
5. If payload contains payload\rootName:
      copy contents of payload\rootName into target\rootName
   Else:
      copy contents of payload into target\rootName
6. Clean temporary work directory.
```

No deduplication is performed.

---

## 15. Safe path requirements

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

## 16. Manual recovery

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

```powershell
mkdir restore
tar -xf outer\blocks\000001_compressible.tar.xz -C restore
```

or for STORE blocks:

```powershell
tar -xf outer\blocks\000002_stored.tar -C restore
```

---

## 17. Compatibility notes

A STAR archive is not a ZIP file.

It is a TAR-based container with this structure:

```text
outer TAR
├─ manifest.json
└─ blocks
   ├─ internal TAR / TAR.XZ block
   └─ internal TAR / TAR.XZ block
```

A generic archive tool may show only the outer layer first.
Manual extraction may require extracting the outer container and then extracting internal blocks.

---

## 18. Recommended file naming

Recommended archive names:

```text
project-name.star
folder-name.star
backup-name_yyyyMMdd_HHmmss.star
```

Recommended block naming:

```text
000001_compressible.tar.xz
000002_stored.tar
000003_text.tar.xz
```

---

## 19. Current known design decisions

- The selected root folder is always preserved.
- Same-name child folders are valid content.
- No folder-name deduplication is allowed.
- Every block must contain the selected root prefix.
- Blocks are independently recoverable.
- The manifest is mandatory.
- SHA256 verification is mandatory for block integrity.
- `.star` remains manually recoverable using standard TAR tooling.

---

## 20. Version notes

### SmartTAR STAR 1.0 Beta 1 / Root Preserving Smart Hybrid v8

Key changes:

- Restores Smart / Hybrid / Solid / Store modes.
- Preserves root folder structure proven in v7.
- Fixes empty-root extraction issue caused by mixed block paths.
- Ensures every block contains selected root prefix.
- Removes folder-name deduplication behavior.
- Keeps SHA256 verification per block.
- Keeps transparent TAR-based recovery model.

---

## 21. Minimal compliance checklist

A valid root-preserving STAR archive should satisfy:

```text
[ ] Outer archive contains manifest.json
[ ] Outer archive contains blocks/
[ ] manifest.format == STAR
[ ] manifest.sourceName is present
[ ] manifest.sourceType is Folder or File
[ ] Every block path is relative and safe
[ ] Every block exists in blocks/
[ ] Every block SHA256 matches manifest
[ ] Every folder archive block contains sourceName as root prefix
[ ] No same-name folder is skipped during extraction
```

---

## 22. Example expected result

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
