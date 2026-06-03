# Changelog

## 1.0 Beta 1 Fix 4

Recommended GitHub / EXE version.

### Added

- Safe extraction through local `_smarttar_tmp`.
- Automatic cleanup of temporary working folders.
- Removal of the `_smarttar_tmp` root folder when it is empty.
- Default extraction target is now the archive parent folder.
- Overwrite / merge Yes-No dialog when the extracted root already exists.
- Manifest preview before extraction to determine `sourceName`.

### Changed

- The default extraction target is no longer `*_extracted`.
- An archive containing folder `A` is extracted as:

```text
<selected target folder>\A\...
```

### Fixed

- Fixed `tar.exe` permission errors when extracting directly to Desktop, protected folders, or localized paths.
- Reduced Windows `tar.exe` issues with mapped drives and localized paths by using local staging.

## 1.0 Beta 1 Fix 3

- Added safe extraction through `_smarttar_tmp`.
- PowerShell copies extracted results into the final destination folder.

## 1.0 Beta 1 Fix 2

- XZ9 / XZStable clean version.
- XZ/XZ9 blocks use timestamp stabilization.
