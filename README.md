![Repo size](https://img.shields.io/github/repo-size/eco-by-different/winzstd)
![Last commit](https://img.shields.io/github/last-commit/eco-by-different/winzstd)

# SmartTAR - STAR v1.1

SmartTAR STAR is a lightweight Windows PowerShell GUI archiver built on top of Windows `tar.exe` / bsdtar.

The goal of SmartTAR is to provide a practical archive workflow with smart grouping, safer path handling, verification reports, and a stable `.star` archive format.

Recommended release file: SmartTAR 1.1.ps1

---

## What is SmartTAR - STAR?

SmartTAR STAR creates `.star` archives using a grouped block model.

Instead of blindly compressing everything the same way, SmartTAR separates data into logical groups and stores them as internal TAR blocks. This allows SmartTAR to:

- store already-compressed data without wasting time recompressing it,
- compress suitable data with stronger compression,
- verify archive blocks after creation,
- produce readable reports,
- work more safely across disks, virtual drives, and read-only media.

---

## Screenshot

![WinZSTD screenshot](docs/images/smarttar-gui.png)

---

## Current version

```text
SmartTAR STAR v1.1
```

This version is the current stable baseline.

---

## Supported archive format

SmartTAR uses the `.star` extension.

```text
example.star
```

The `.star` file is a SmartTAR container with internal grouped TAR blocks and a manifest.

---

## Supported compression methods

SmartTAR STAR v1.1 uses the stable method set:

```text
STORE
XZ9
ZSTD19
```

### STORE

Used for data that is already compressed or not worth recompressing.

Typical examples:

```text
.zip, .7z, .rar, .jpg, .png, .mp4, .mp3, .pdf
```

### XZ9

Used for highly compressible data where maximum compression ratio is preferred.

Typical examples:

```text
.txt, .log, .csv, .xml, .json, .ps1, .bat, .cmd, source/config files
```

### ZSTD19

Available when supported by the installed Windows tar/bsdtar implementation.

---

## Main features

- Windows PowerShell GUI.
- Uses Windows `tar.exe` / bsdtar.
- Creates `.star` archives.
- Supports grouped archive blocks.
- Supports STORE, XZ9, and ZSTD19.
- Verifies archives after creation.
- Generates readable reports.
- Supports extraction.
- Supports verify-only mode.
- Supports optional Adaptive deep analyze.
- Handles safer temp/report paths.
- Works better across different disks and read-only/virtual media.

---

## Smart staging behavior

SmartTAR STAR v1.1 improves the CREATE path policy.

For archive creation, SmartTAR now prefers staging on the same volume as the source data.

Example:

```text
Source: C:\Users\User\Desktop\Data
Output: Z:\Backup\Data.star
Create staging: C:\SmartTAR_Temp\...
Final archive: Z:\Backup\Data.star
```

This helps preserve hardlink support and prevents unnecessary block splitting.

---

## Why source-volume staging matters

Hardlinks work only on the same volume.

When source data and staging are on the same volume, SmartTAR can create a staging tree using hardlinks instead of copying all data.

This means:

- less temporary disk usage,
- faster staging,
- better chance of creating one large compressible block,
- better compression ratio for XZ9 data.

If source-volume staging is not possible, SmartTAR can fall back to standard temp storage and use copy-based group staging before falling back to chunked blocks.

---

## Fallback order during CREATE

SmartTAR STAR v1.1 uses this preferred order:

```text
1. Source-volume hardlink group-stage
2. Standard temp with copy group-stage
3. Chunked fallback blocks as last resort
```

Chunked fallback is intentionally kept as a safety path, but it is no longer the preferred fallback.

---

## VERIFY behavior

VERIFY uses standard SmartTAR temp storage.

This is intentional because verify only needs to read the archive and inspect/check its internal blocks.

This makes VERIFY more reliable for:

- virtual CD/DVD drives,
- mounted read-only images,
- read-only media,
- archive locations where writing next to the archive is not possible.

---

## Reports

SmartTAR creates text reports for operations.

Typical report types:

```text
create_report
extract_report
verify_report
```

Report behavior:

```text
CREATE  -> report near the created archive
EXTRACT -> report near the extraction target
VERIFY  -> report near the archive, with fallback when needed
```

If the preferred report location is not writable, SmartTAR uses a safe report fallback location under SmartTAR temp storage.

---

## Adaptive deep analyze

Adaptive deep analyze is optional.

When enabled, SmartTAR performs additional analysis on unknown file types using magic bytes and conservative byte/entropy checks.

This can help decide whether unknown files should be treated as:

```text
text / compressible
binary
already-compressed / STORE
unknown
```

For normal use, Adaptive can stay disabled unless you want deeper classification.

---

## Recommended usage

### Create archive

1. Start `SmartTAR_STAR_v1_1_Clean.ps1`.
2. Select a file or folder.
3. Choose target `.star` path.
4. Select compression mode.
5. Click create/compress.
6. Check the report for verification result.

### Verify archive

1. Select a `.star` archive.
2. Run Verify.
3. Check the generated verify report.

### Extract archive

1. Select a `.star` archive.
2. Select extraction target folder.
3. Run Extract.
4. Check the extraction report.

---

## Expected healthy report indicators

A healthy archive should show:

```text
Verification: OK
Blocks failed: 0
```

For typical Hybrid archives, SmartTAR should avoid unnecessary block splitting. A small number of grouped blocks is expected.

If you see many blocks like this:

```text
compressible_p001
compressible_p002
compressible_p003
...
```

it means SmartTAR used the chunked fallback path. The archive can still be valid, but the compression ratio may be worse.

---

## Notes and limitations

- SmartTAR depends on the available Windows `tar.exe` / bsdtar capabilities.
- ZSTD support depends on the installed tar implementation.
- CREATE may need temporary space for internal blocks.
- If hardlink staging cannot be used, copy fallback may require additional temporary space.
- Chunked fallback is safe, but may reduce compression efficiency.
- The tool is designed for practical Windows usage, not as a replacement for every advanced feature of dedicated archivers.

---

## Version 1.1 highlights

- Improved CREATE staging policy.
- Source-volume staging first.
- Hardlink-first group staging.
- Copy group-stage fallback before chunked fallback.
- VERIFY uses standard SmartTAR temp storage.
- Improved report path handling.
- Removed legacy SARC handling.
- Removed old beta/fix/rc labels.
- Cleaned internal versioning.
- Stable method set: STORE, XZ9, ZSTD19.

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
