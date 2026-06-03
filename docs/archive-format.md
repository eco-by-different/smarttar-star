# SmartTAR STAR Archive Format

This document describes the high-level archive layout used by SmartTAR STAR.

> Status: Experimental / beta.

---

## Outer Container

A `.star` file is a standard TAR archive.

Typical layout:

```text
archive.star
├── manifest.json
└── blocks/
    ├── 000001_structure.tar
    ├── 000002_text.tar.xz
    ├── 000003_binary.tar.zst
    └── ...
```

The outer TAR container is intentionally simple so the archive can be inspected manually.

---

## Manifest

The manifest is stored as:

```text
manifest.json
```

Current archives are written with:

```json
{
  "format": "STAR",
  "formatVersion": 1
}
```

SmartTAR currently accepts these format identifiers when reading archives:

- `STAR`
- `SARC`
- `SmartTarArc`

---

## Blocks

Internal archive blocks are stored in:

```text
blocks/
```

Each block is itself a TAR archive, optionally compressed by a method supported by the system TAR engine.

Example block names:

```text
000001_structure.tar
000002_text.tar.xz
000003_binary.tar.zst
```

The manifest records for each block:

- block ID,
- group name,
- relative path,
- container type,
- compression algorithm,
- method display name,
- compression level when applicable,
- source byte count,
- block size,
- SHA-256 hash,
- reason for selected method.

---

## Recovery Model

Manual recovery can be performed in two stages:

```powershell
tar -xf archive.star -C outer
```

Then extract one or more internal blocks:

```powershell
tar -xf outer\blocks\000001_solid.tar.xz -C restore
```

If the `.star` extension is not recognized by a tool, the file may be renamed to `.tar` for manual inspection.

---

## Format Stability

The format is currently experimental. Future versions may add fields, change planning metadata, or introduce a newer format version.

Consumers should ignore unknown manifest fields where possible.
