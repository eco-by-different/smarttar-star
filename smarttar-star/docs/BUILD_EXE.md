# Build EXE

Tento dokument popisuje doporučený postup pro vytvoření `.exe` ze `src/SmartTAR.ps1`.

## Doporučení

- Build dělej z finálního `src/SmartTAR.ps1`.
- EXE nespouštěj defaultně jako administrátor.
- EXE nech vytvářet `_smarttar_tmp` ve složce, kde je EXE uložené.
- EXE ukládej do `dist/` nebo `release/`, které nejsou v Git repozitáři.

## Varianta přes PS2EXE

Příklad příkazu:

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

Pokud používáš grafickou verzi PS2EXE, nastav:

```text
Input:  src\SmartTAR.ps1
Output: dist\SmartTAR.exe
No console: yes
STA mode: yes, pokud je k dispozici
```

## Doporučený release obsah

```text
SmartTAR.exe
README.md
CHANGELOG.md
LICENSE
```

Volitelně:

```text
src\SmartTAR.ps1
```

## Test po buildu

1. Spustit EXE normálně jako běžný uživatel.
2. Komprimovat malou složku `A` se složkami `B` a `C`.
3. Ověřit `.star` přes Verify.
4. Extrahovat do parent složky.
5. Ověřit výsledek:

```text
parent\A\B
parent\A\C
```

6. Znovu extrahovat do stejného parentu a ověřit Yes/No overwrite dialog.
7. Ověřit, že po dokončení nezůstala neprázdná `_smarttar_tmp`.
