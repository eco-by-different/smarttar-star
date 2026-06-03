# Release checklist

## Before build

- [ ] `src/SmartTAR.ps1` contains the final Fix 4 source code.
- [ ] The source code contains no HTML escape strings: `&amp;`, `&gt;`, `&lt;`.
- [ ] GUI version text matches Fix 4.
- [ ] Manifest `toolVersion` matches Fix 4.
- [ ] README documents `_smarttar_tmp`.
- [ ] README states that administrator mode is not required.

## Script test

- [ ] Compress a single file.
- [ ] Compress a folder `A` containing folders `B` and `C`.
- [ ] Verify the archive.
- [ ] Extract the archive into a parent folder.
- [ ] Confirm output structure: `parent\A\B` and `parent\A\C`.
- [ ] Confirm the overwrite Yes/No prompt when `parent\A` already exists.
- [ ] Confirm that `_smarttar_tmp` is cleaned up.

## EXE test

- [ ] EXE starts as a normal user.
- [ ] Compress works.
- [ ] Verify works.
- [ ] Extract works.
- [ ] Overwrite dialog works.
- [ ] `_smarttar_tmp` is cleaned up.

## GitHub release assets

- [ ] `SmartTAR.exe`
- [ ] `README.md`
- [ ] `CHANGELOG.md`
- [ ] `LICENSE`
- [ ] optional: `SmartTAR.ps1`
