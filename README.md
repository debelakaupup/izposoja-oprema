# Izposoja opreme - full build

Ta repo vsebuje full build aplikacije v Base64 delih.

## Prenos / sestava ZIP

1. Klikni **Code -> Download ZIP**.
2. Razširi GitHub ZIP na računalnik.
3. V mapi repozitorija zaženi PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\rebuild_zip.ps1
```

4. Nastane datoteka:

```text
izposoja_full_build_fotografije_utf8.zip
```

5. To ZIP datoteko razširi in prepiši čez obstoječo aplikacijo.

## SHA256

```text
77ecccc6e8c5abecb4bb9cd924927442e815f362a4ab136246a310ef30f02399
```

## Vključeno

- nalaganje fotografij artiklov
- prikaz fotografij v šifrantu, zalogi in novi izposoji
- popravljeni šumniki / UTF-8
- poenotena baza na `C:\ProgramData\IzposojaOpreme\PodatkiBaza\app.db`
- migracija `inventory_items.image_filename`
