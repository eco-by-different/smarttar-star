# Changelog

## 1.0 Beta 1 Fix 4

Doporučená GitHub / EXE verze.

### Added

- Safe extraction přes lokální `_smarttar_tmp`.
- Automatický cleanup dočasných pracovních složek.
- Mazání kořenové `_smarttar_tmp`, pokud je po operaci prázdná.
- Default extrakce do rodičovské složky archivu.
- Overwrite / merge Yes-No dialog, pokud cílový root už existuje.
- Preview manifestu před extrakcí kvůli zjištění `sourceName`.

### Changed

- Výchozí extract target už není `*_extracted`.
- Archiv obsahující složku `A` se extrahuje jako:

```text
<vybraná cílová cesta>\A\...
```

### Fixed

- `tar.exe Permission denied` při rozbalování přímo na Plochu / do chráněných / lokalizovaných cest.
- Problémy s Windows `tar.exe` při práci s mapovanými disky a lokalizovanými cestami.

## 1.0 Beta 1 Fix 3

- Safe extraction přes `_smarttar_tmp`.
- PowerShell kopíruje výsledky do cílové složky.

## 1.0 Beta 1 Fix 2

- XZ9 / XZStable clean verze.
- XZ/XZ9 bloky používají stabilizaci timestampů.
