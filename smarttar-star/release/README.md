# SmartTAR STAR

SmartTAR STAR je jednoduchý Windows GUI nástroj pro vytváření a rozbalování transparentních `.star` archivů.

`.star` archiv je klasický TAR kontejner, který obsahuje:

```text
manifest.json
blocks/
```

Uvnitř jsou jednotlivé bloky komprimované podle zvoleného režimu. Archiv jde v nouzi otevřít ručně přes `tar.exe`, protože vnější kontejner je běžný TAR.

## Stav verze

Aktuální doporučená verze:

```text
SmartTAR STAR 1.0 Beta 1 Fix 4
```

Hlavní vlastnosti Fix 4:

- reliable local staging přes `_smarttar_tmp`,
- safe extraction přes `_smarttar_tmp`,
- automatický úklid dočasné složky po operaci,
- extrakce do rodičovské složky, ne do `*_extracted`,
- pokud cílový root existuje, zobrazí se Yes/No overwrite dotaz,
- není potřeba spouštět jako administrátor.

## Doporučená struktura repozitáře

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

## Jak vložit zdrojový kód

Do souboru:

```text
src/SmartTAR.ps1
```

vlož finální ověřený script:

```text
SmartTAR_STAR_1.0_beta1_fix4_safe_extract_cleanup_overwrite.ps1
```

Pro GitHub je lepší držet stabilní název `src/SmartTAR.ps1`, zatímco release asset může mít dlouhý verzovaný název.

## EXE build

Doporučený postup je popsaný v:

```text
docs/BUILD_EXE.md
```

## Dočasná složka

SmartTAR používá dočasnou složku vedle scriptu / EXE:

```text
_smarttar_tmp
```

Důvod je kompatibilita s Windows `tar.exe` u mapovaných disků, Plochy, OneDrive a lokalizovaných cest.

Dočasné pracovní složky se po operaci automaticky mažou. Kořenová `_smarttar_tmp` se smaže také, pokud je prázdná.

## Spouštění jako administrátor

Spuštění jako administrátor není potřeba a není doporučené jako výchozí režim. U mapovaných disků může elevated/admin proces vidět jiné disky než běžný uživatel.

## Licence

MIT License. Viz `LICENSE`.
