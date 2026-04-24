$ErrorActionPreference = "Stop"
$parts = Get-ChildItem -Path "parts" -Filter "part_*.b64" | Sort-Object Name
$content = ($parts | ForEach-Object { Get-Content $_.FullName -Raw }) -join ""
[IO.File]::WriteAllBytes("izposoja_full_build_fotografije_utf8.zip", [Convert]::FromBase64String($content))
Write-Host "Ustvarjeno: izposoja_full_build_fotografije_utf8.zip"
