# SmartTAR STAR

SmartTAR STAR is a simple Windows GUI tool for creating, verifying, and extracting transparent `.star` archives.

A `.star` archive is a standard TAR outer container with this internal structure:

```text
manifest.json
blocks/
```

Internal blocks are compressed according to the selected compression mode. Because the outer container is a normal TAR archive, the archive can be inspected or recovered manually with `tar.exe` if needed.

## Current version

Recommended version:

```text
SmartTAR STAR Fix 13 RC5
```

Fix 12 RC6 highlights:

- safe-path archive creation using a dedicated SmartTAR work folder,
- internal file blocks are created from temporary hardlink stages,
- hardlinks avoid full data copy when the safe work folder is on the same drive,
- automatic fallback to `Copy-Item` if hardlink creation is unavailable,
- final `.star` archive is created in the safe work folder first and then moved to the requested destination,
- avoids Windows `tar.exe` / `bsdtar` path error `GetVolumePathName failed: 123`,
- improved reliability with localized paths, spaced paths, user-profile paths and temporary folders,
- safe extraction and verification use a safe working copy of the selected archive,
- automatic temporary folder cleanup after operations,
- extraction target is a parent folder,
- optional salvage mode can skip broken internal blocks and extract all readable blocks,
- administrator mode is not required and is not recommended by default.

## Repository structure

```text
SmartTAR/
├─ src/
│  └─ SmartTAR.ps1
├─ docs/
│  ├─ FORMAT.md
│  └─ BUILD_EXE.md
├─ release/
│  └─ README.md
├─ CHANGELOG.md
├─ CONTRIBUTING.md
├─ LICENSE
├─ README.md
├─ RELEASE_CHECKLIST.md
├─ SECURITY.md
├─ TODO.md
└─ VERSION
```

## Source code

The main source file should be stored as:

```text
src/SmartTAR.ps1
```

For GitHub, use the stable source filename `src/SmartTAR.ps1`. Versioned filenames can be used for release assets if desired.

## Build EXE

Recommended build instructions are available in:

```text
docs/BUILD_EXE.md
```

## Temporary folder and safe work folder

SmartTAR uses a safe temporary working folder during archive creation, extraction and verification.

The safe work folder is created in a writable location such as:

```text
C:\SmartTAR_Temp
```

or, when appropriate:

```text
%PUBLIC%\SmartTAR_Temp
```

This is intentional. It avoids Windows `tar.exe` / `bsdtar` issues with mapped drives, Desktop folders, OneDrive-managed folders, protected paths, localized user-profile paths, spaces in paths and paths containing non-ASCII characters.

Temporary operation folders are removed automatically after each operation.

## How RC6 avoids full staging copies

SmartTAR STAR Fix 12 RC6 creates temporary hardlink stages for internal file blocks.

This means:

- file data is not fully copied when hardlinks are available,
- the staged file tree gives `tar.exe` clean and simple relative paths,
- internal blocks can still preserve the intended archive layout,
- if hardlinks cannot be created, SmartTAR falls back to `Copy-Item` for compatibility.

## Archive design

A `.star` archive is a standard TAR file containing a JSON manifest and one or more internal data blocks:

```text
archive.star
├─ manifest.json
└─ blocks/
   ├─ 000001_structure.tar
   ├─ 000002_compressible.tar.xz
   ├─ 000003_diskimage.tar.zst
   └─ ...
```

The `manifest.json` file stores metadata such as:

- archive format version,
- source name and source type,
- compression mode,
- block list,
- block compression method,
- original source size,
- internal block size,
- SHA-256 hash for each block.

## Compression modes

SmartTAR STAR supports these compression modes:

- **Hybrid** — recommended balanced mode using grouped blocks,
- **Smart** — detailed grouping by file type,
- **Solid** — auto-selected solid-style block planning,
- **Smart XZ** — grouped mode focused on XZ/XZ9 compression,
- **Store** — TAR blocks without compression.

Available compression methods depend on the local Windows `tar.exe` / `bsdtar` capabilities.

## Verification

The verify operation checks every internal block independently:

- outer TAR readability,
- `manifest.json` presence and validity,
- internal block presence,
- internal block TAR readability,
- SHA-256 hash match for each block.

## Extraction

Extraction restores the archived root into the selected parent folder.

SmartTAR performs safety checks before extracting internal blocks, including:

- rejecting absolute paths,
- rejecting drive-letter paths,
- rejecting path traversal entries such as `../`,
- verifying block hashes before extraction.

## Salvage mode

Salvage mode is optional.

When salvage mode is enabled, SmartTAR skips broken or unreadable internal blocks and extracts all readable blocks. A report is generated with the list of skipped blocks and reasons.

This can be useful when an archive is partially damaged but some internal blocks remain readable.

## Manual recovery

Because `.star` is based on standard TAR containers, manual recovery is possible.

Extract the outer container:

```powershell
tar.exe -xf archive.star -C outer
```

Inspect the manifest:

```text
outer/manifest.json
```

Extract a readable internal block manually:

```powershell
tar.exe -xf outer/blocks/000002_compressible.tar.xz -C restored
```

If a tool does not recognize the `.star` extension, rename the file to `.tar` and inspect it as a normal TAR archive.

## Administrator mode

Running SmartTAR as administrator is not required and is not recommended by default.

Elevated processes may not see the same mapped drives as the normal user session, which can make source or destination paths appear unavailable.

## License

MIT License. See `LICENSE`.
