# Changelog

All notable changes to this project should be documented in this file.

This project uses a practical beta versioning style until the archive format becomes stable.

---

## v0.1.0-beta - Initial public beta

### Added

- Initial public GitHub package structure.
- PowerShell WinForms GUI archiver concept.
- `.star` archive extension.
- Legacy `.sarc.tar` recognition.
- Outer TAR container with internal block layout.
- `manifest.json` metadata.
- SHA-256 hash verification for internal blocks.
- TAR capability detection.
- Compression modes:
  - Hybrid,
  - Smart,
  - Solid,
  - Smart XZ.
- XZ/XZ9 timestamp stabilization for XZ-related block stages.
- Create, extract, and verify reports.
- Extraction path safety checks.

### Notes

- This is a beta / experimental release.
- The `.star` archive format may change before a stable release.
- Use independent backups for critical data.
