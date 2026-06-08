![Repo size](https://img.shields.io/github/repo-size/eco-by-different/winzstd)
![Last commit](https://img.shields.io/github/last-commit/eco-by-different/winzstd)

# SmartTAR - STAR v1.0

First stable release of **SmartTAR - STAR**.

SmartTAR is a Windows PowerShell GUI archiver using the built-in Windows `tar.exe` / bsdtar engine. It creates `.star` archives with an outer TAR container, internal `manifest.json`, SHA-256 block metadata, grouped block compression, verification support, and salvage extraction mode.

## Highlights

- STAR outer TAR container
- Internal manifest with SHA-256 block metadata
- Smart grouped block planning
- Hybrid / Smart / Solid / Smart XZ / Store compression modes
- Group hardlink staging for reliable block creation
- Chunk fallback when group-stage creation fails
- XZ directory timestamp normalization
- Responsive GUI with hidden worker process
- VERIFY action with final report next to archive
- Salvage extraction mode for partially damaged archives

## Requirements

- Windows 10 / Windows 11
- Windows PowerShell 5.1+
- Built-in Windows `tar.exe`

## Run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\SmartTAR_STAR_v1.0.ps1
```

## Notes

The `.star` archive is TAR-based, but its internal structure is designed for SmartTAR. Use SmartTAR for full verification, extraction, and salvage behavior.
