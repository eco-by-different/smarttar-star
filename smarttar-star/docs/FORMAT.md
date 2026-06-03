# STAR Format

A `.star` file is a standard TAR outer container with this internal structure:

```text
manifest.json
blocks/
```

## manifest.json

The manifest contains archive metadata:

```json
{
  "format": "STAR",
  "formatVersion": 1,
  "tool": "SmartTAR",
  "toolVersion": "1.0-beta1-fix4-safe-extract-target-cleanup-overwrite",
  "sourceName": "A",
  "sourceType": "Folder",
  "blocks": []
}
```

Important fields:

- `sourceName` - root name of the original file or folder.
- `sourceType` - `File` or `Folder`.
- `blocks` - list of internal TAR blocks.
- `sha256` - integrity hash of each internal block.

## Extraction behavior

The user selects a parent target folder.

Example:

```text
sourceName = A
target = C:\Users\User\Desktop
```

Output:

```text
C:\Users\User\Desktop\A\...
```

If `C:\Users\User\Desktop\A` already exists, SmartTAR displays a Yes/No overwrite dialog.

## Manual recovery

A `.star` archive can be inspected or recovered manually as a TAR archive:

```powershell
tar -xf archive.star -C outer
tar -xf outer\blocks\000001_solid.tar.xz -C restore
```
