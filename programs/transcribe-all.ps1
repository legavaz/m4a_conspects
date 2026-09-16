<#
    transcribe-all.ps1 - пакетная транскрибация всех необработанных записей в папке.

    Использование:
        powershell -ExecutionPolicy Bypass -File transcribe-all.ps1 "D:\video_cast\zoom\2026-09-15"
        (без аргументов - папка текущего дня D:\video_cast\zoom\ГГГГ-ММ-ДД)

    Обрабатываются: m4a, webm, mp4, mp3, wav, ogg, m4b.
    Пропускаются файлы, у которых уже есть готовый .txt (если не указан -Force).

    Опции:
        -Path      папка с записями
        -Model     модель (по умолчанию ggml-large-v3-turbo.bin)
        -DeleteTxt удалять .txt после транскрибации (оставить .srt с таймкодами)
        -NoVad     отключить Voice Activity Detection
        -Force     перетранскрибировать даже если .txt уже есть
#>
param(
    [string]$Path = "",
    [string]$Model = "ggml-large-v3-turbo.bin",
    [switch]$DeleteTxt,
    [switch]$NoVad,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $Path) {
    $Path = Join-Path "D:\video_cast\zoom" (Get-Date -Format "yyyy-MM-dd")
}
if (-not (Test-Path -LiteralPath $Path)) { throw "Папка не найдена: $Path" }

$Script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "transcribe.ps1"
$exts = @(".m4a", ".webm", ".mp4", ".mp3", ".wav", ".ogg", ".m4b")

$files = @(Get-ChildItem -LiteralPath $Path -File |
    Where-Object { $exts -contains $_.Extension.ToLower() } |
    Sort-Object Name)

Write-Host ("Найдено записей: {0} в {1}" -f $files.Count, $Path) -ForegroundColor Cyan
if ($files.Count -eq 0) { exit 0 }

$done = 0; $failed = 0; $skipped = 0
foreach ($f in $files) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $have = Test-Path -LiteralPath (Join-Path $Path ($base + ".txt"))
    if ($have -and -not $Force) {
        Write-Host ("Пропускаю (уже есть .txt): {0}" -f $f.Name) -ForegroundColor DarkGray
        $skipped++
        continue
    }
    Write-Host ("`n=== {0} ===" -f $f.Name) -ForegroundColor Magenta
    $passArgs = @("-File", "`"$($f.FullName)`"", "-Model", $Model)
    if ($DeleteTxt) { $passArgs += "-DeleteTxt" }
    if ($NoVad)     { $passArgs += "-NoVad" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @passArgs
    if ($LASTEXITCODE -eq 0) { $done++ } else { $failed++ }
}

Write-Host ("`nИтог: обработано {0}, пропущено {1}, ошибок {2}" -f $done, $skipped, $failed) -ForegroundColor Green
exit $failed