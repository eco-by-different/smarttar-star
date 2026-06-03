# Build EXE

This document describes the recommended process for building an `.exe` from `src/SmartTAR.ps1`.

## Recommendations

- Build from the final `src/SmartTAR.ps1` file.
- Do not require administrator mode by default.
- Let the EXE create `_smarttar_tmp` next to the EXE file.
- Store build outputs in `dist/` or `release/`. These folders are ignored by Git.

## Build with PS2EXE

Example command:

```powershell
Invoke-ps2exe `
  -inputFile ".\src\SmartTAR.ps1" `
  -outputFile ".\dist\SmartTAR.exe" `
  -noConsole `
  -title "SmartTAR STAR" `
  -description "SmartTAR STAR archive tool" `
  -company "SmartTAR" `
  -product "SmartTAR STAR" `
  -version "1.0.0.4"
```

If a PS2EXE GUI is used, recommended settings are:

```text
Input:  src\SmartTAR.ps1
Output: dist\SmartTAR.exe
No console: yes
STA mode: yes, if available
```

## Recommended release assets

```text
SmartTAR.exe
README.md
CHANGELOG.md
LICENSE
```

Optional:

```text
SmartTAR.ps1
```

## Post-build test

1. Run the EXE as a normal user.
2. Compress a small folder `A` containing folders `B` and `C`.
3. Verify the `.star` archive.
4. Extract the archive into a parent folder.
5. Confirm the output structure:

```text
parent\A\B
parent\A\C
```

6. Extract again into the same parent folder and confirm that the Yes/No overwrite dialog appears.
7. Confirm that `_smarttar_tmp` is cleaned up after the operation.
