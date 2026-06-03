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
SmartTAR STAR 1.0 Beta 1 Fix 4
```

Fix 4 highlights:

- reliable local staging through `_smarttar_tmp`,
- safe extraction through `_smarttar_tmp`,
- automatic temporary folder cleanup after operations,
- extraction target is now a parent folder, not `*_extracted`,
- Yes/No overwrite prompt when the extracted root already exists,
- administrator mode is not required and is not recommended by default.

## Repository structure

```text
SmartTAR/
├─ src/
│  └─ SmartTAR.ps1
├─ docs/
│  ├─ FORMAT.md
│  └─ BUILD_EXE.md
├─ CHANGELOG.md
├─ LICENSE
├─ README.md
├─ RELEASE_CHECKLIST.md
├─ VERSION
└─ .gitignore
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

## Temporary folder

SmartTAR creates a temporary local staging folder next to the script or executable:

```text
_smarttar_tmp
```

This is intentional. It avoids Windows `tar.exe` issues with mapped drives, Desktop folders, OneDrive-managed folders, protected paths, and localized user-profile paths.

Temporary working folders are removed automatically after each operation. The `_smarttar_tmp` root folder is also removed when it is empty.

## Administrator mode

Running SmartTAR as administrator is not required and is not recommended by default. Elevated processes may not see the same mapped drives as the normal user session.

## License

MIT License. See `LICENSE`.
