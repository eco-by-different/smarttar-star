# Release checklist

## Před buildem

- [ ] `src/SmartTAR.ps1` obsahuje finální Fix 4 kód.
- [ ] V kódu nejsou HTML escape znaky `&amp;`, `&gt;`, `&lt;`.
- [ ] Verze v GUI odpovídá Fix 4.
- [ ] Verze v manifestu odpovídá Fix 4.
- [ ] README popisuje `_smarttar_tmp`.
- [ ] README říká, že admin režim není potřeba.

## Test scriptu

- [ ] Compress file.
- [ ] Compress folder `A` obsahující `B` a `C`.
- [ ] Verify archive.
- [ ] Extract archive do parent složky.
- [ ] Ověřit výsledek `parent\A\B` a `parent\A\C`.
- [ ] Ověřit overwrite Yes/No, pokud `parent\A` existuje.
- [ ] Ověřit, že `_smarttar_tmp` se uklidí.

## Test EXE

- [ ] EXE jde spustit jako běžný uživatel.
- [ ] Compress funguje.
- [ ] Verify funguje.
- [ ] Extract funguje.
- [ ] Overwrite dialog funguje.
- [ ] `_smarttar_tmp` se uklidí.

## GitHub release assets

- [ ] `SmartTAR.exe`
- [ ] `README.md`
- [ ] `CHANGELOG.md`
- [ ] `LICENSE`
- [ ] volitelně `SmartTAR.ps1`
