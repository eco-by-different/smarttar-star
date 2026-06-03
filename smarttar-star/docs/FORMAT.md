# STAR Format

`.star` je běžný TAR kontejner s pevnou vnitřní strukturou:

```text
manifest.json
blocks/
```

## manifest.json

Manifest obsahuje metadata archivu:

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

Důležité položky:

- `sourceName` - kořenový název původního souboru nebo složky.
- `sourceType` - `File` nebo `Folder`.
- `blocks` - seznam interních TAR bloků.
- `sha256` - hash každého interního bloku.

## Extrakční logika

Uživatel vybírá rodičovskou cílovou složku.

Příklad:

```text
sourceName = A
target = C:\Users\User\Desktop
```

Výsledek:

```text
C:\Users\User\Desktop\A\...
```

Pokud `C:\Users\User\Desktop\A` existuje, aplikace zobrazí Yes/No overwrite dialog.

## Ruční recovery

V nouzi lze `.star` přejmenovat nebo otevřít jako TAR:

```powershell
tar -xf archive.star -C outer
tar -xf outer\blocks\000001_solid.tar.xz -C restore
```
