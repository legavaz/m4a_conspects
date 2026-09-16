<#
    transcribe.ps1 - локальная транскрибация аудио/видео в текст (whisper.cpp, без облака).

    Использование:
        powershell -ExecutionPolicy Bypass -File transcribe.ps1 "D:\video_cast\zoom\2026-09-15\Zoom_....m4a"

    Опции:
        -Model   ggml-large-v3-turbo.bin (по умолчанию; скачается при отсутствии)
                 ggml-small.bin - быстрая модель
        -Lang    ru (по умолчанию) | auto | en ...
        -Threads 14 (по умолчанию)
        -NoVad   отключить Voice Activity Detection
        -DeleteTxt  удалить .txt (оставить только .srt с таймкодами)
        -Retries N  число повторов при сбое whisper-cli (по умолчанию 2)
        -ChunkSeconds N  длина куска для фолбэка, сек (по умолчанию 600)
        -NoFallback  не использовать нарезку + ggml-small при сбое

    Форматы входа: m4a, webm, mp4, wav, mp3, ogg и др. (декодирует ffmpeg).
    Результат: <имя>.txt и <имя>.srt (таймкоды) рядом с исходным файлом.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$File,
    [string]$Model = "ggml-large-v3-turbo.bin",
    [string]$Lang = "ru",
    [int]$Threads = 14,
    [switch]$NoVad,
    [switch]$DeleteTxt,
    [int]$Retries = 2,
    [int]$ChunkSeconds = 600,
    [switch]$NoFallback
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$WhisperCli    = "C:\Users\lega\.cache\opencode-voice\engines\whisper.cpp\win32-x64\whisper-cli.exe"
$ModelDir      = "D:\video_cast\zoom\models"
$FallbackModel = "ggml-small.bin"

function Get-ModelPath([string]$name) {
    $path = Join-Path $ModelDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        $url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$name"
        Write-Host "Модель $name не найдена, скачиваю в $ModelDir ..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
        & curl.exe -L --retry 3 -o "$path.part" $url
        if ($LASTEXITCODE -ne 0) {
            Remove-Item "$path.part" -Force -ErrorAction SilentlyContinue
            throw "Не удалось скачать модель ($url)"
        }
        Move-Item "$path.part" $path -Force
    }
    return $path
}

function Format-SrtTime([long]$ms) {
    $h = [int]($ms / 3600000); $m = [int](($ms % 3600000) / 60000); $s = [int](($ms % 60000) / 1000); $f = [int]($ms % 1000)
    return ("{0:00}:{1:00}:{2:00},{3:00}" -f $h, $m, $s, $f)
}

function Merge-Srt {
    param([string[]]$Files, [int]$OffsetSeconds, [string]$Dest)
    $out = New-Object System.Text.StringBuilder
    $n = 0
    $offsetMs = 0
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -Encoding UTF8)) {
            if ($line -match '^\s*(\d+)\s*$') {
                $n++
                [void]$out.AppendLine("$n")
            } elseif ($line -match '^(\d\d):(\d\d):(\d\d),(\d\d\d)\s*-->\s*(\d\d):(\d\d):(\d\d),(\d\d\d)') {
                $startMs = (([int]$matches[1]*3600 + [int]$matches[2]*60 + [int]$matches[3]) * 1000 + [int]$matches[4]) + $offsetMs
                $endMs   = (([int]$matches[5]*3600 + [int]$matches[6]*60 + [int]$matches[7]) * 1000 + [int]$matches[8]) + $offsetMs
                [void]$out.AppendLine((Format-SrtTime $startMs) + " --> " + (Format-SrtTime $endMs))
            } else {
                [void]$out.AppendLine($line)
            }
        }
        $offsetMs += $OffsetSeconds * 1000
    }
    [System.IO.File]::WriteAllText($Dest, $out.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $File)) { throw "Файл не найден: $File" }
if (-not (Test-Path -LiteralPath $WhisperCli)) { throw "whisper-cli не найден: $WhisperCli" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "ffmpeg не найден в PATH" }

$ModelPath = Get-ModelPath $Model

$full      = (Resolve-Path -LiteralPath $File).Path
$base      = [System.IO.Path]::GetFileNameWithoutExtension($full)
$dir       = Split-Path -Parent $full
$wav       = Join-Path $env:TEMP ("{0}_{1}.wav" -f $base, [guid]::NewGuid().ToString("N").Substring(0, 8))
$outPrefix = Join-Path $dir $base

# --- VAD-модель -------------------------------------------------------------
$VadModelName = "ggml-silero-v5.1.2.bin"
$VadModelPath = Join-Path $ModelDir $VadModelName
$vadArgs = @()
if (-not $NoVad) {
    if (-not (Test-Path -LiteralPath $VadModelPath)) {
        $VadModelUrl = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VadModelName"
        Write-Host "VAD-модель не найдена, скачиваю $VadModelName ..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
        & curl.exe -L --retry 3 -o "$VadModelPath.part" $VadModelUrl
        if ($LASTEXITCODE -ne 0) {
            Remove-Item "$VadModelPath.part" -Force -ErrorAction SilentlyContinue
            throw "Не удалось скачать VAD-модель ($VadModelUrl)"
        }
        Move-Item "$VadModelPath.part" $VadModelPath -Force
    }
    $vadArgs = @("--vad", "-vm", "$VadModelPath")
}

function Invoke-Whisper([string]$modelPath, [string]$audio, [string]$prefix) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $WhisperCli -m "$modelPath" -l $Lang -t $Threads @vadArgs -otxt -osrt -pp -of "$prefix" "$audio" | Write-Host
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("  whisper-cli: код {0}, время {1:hh\:mm\:ss}" -f $code, $sw.Elapsed) -ForegroundColor DarkGray
    return $code
}

# --- Конвертация в WAV 16 кГц моно -----------------------------------------
Write-Host "Конвертирую в WAV 16 кГц моно..." -ForegroundColor Cyan
& ffmpeg -hide_banner -loglevel error -y -i "$full" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
if ($LASTEXITCODE -ne 0) {
    Remove-Item $wav -Force -ErrorAction SilentlyContinue
    throw "ffmpeg завершился с ошибкой"
}

# --- Основная транскрибация с повторами ------------------------------------
$ok = $false
$attempt = 0
while (-not $ok -and $attempt -le $Retries) {
    $attempt++
    if ($attempt -eq 1) {
        Write-Host "Транскрибирую (модель: $Model, язык: $Lang, потоков: $Threads)..." -ForegroundColor Cyan
    } else {
        Write-Host "Повтор транскрибации ($attempt из $($Retries + 1))..." -ForegroundColor Yellow
    }
    if ((Invoke-Whisper $ModelPath $wav $outPrefix) -eq 0) { $ok = $true }
}

# --- Фолбэк: нарезка + ggml-small -------------------------------------------
if (-not $ok) {
    if ($NoFallback) {
        Remove-Item $wav -Force -ErrorAction SilentlyContinue
        throw "whisper-cli не смог обработать файл (фолбэк отключён)"
    }
    Write-Host "Основная модель не справилась. Фолбэк: нарезка по $ChunkSeconds с + $FallbackModel" -ForegroundColor Yellow
    $fallbackModelPath = Get-ModelPath $FallbackModel
    $chunkDir = Join-Path $env:TEMP ("chunks_{0}" -f [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null

    & ffmpeg -hide_banner -loglevel error -y -i "$wav" -f segment -segment_time $ChunkSeconds -c:a pcm_s16le (Join-Path $chunkDir "chunk_%03d.wav")
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $wav -Force -ErrorAction SilentlyContinue
        throw "ffmpeg не смог нарезать WAV на куски"
    }

    $chunks = @(Get-ChildItem -LiteralPath $chunkDir -Filter "chunk_*.wav" | Sort-Object Name)
    Write-Host ("  кусков: {0}" -f $chunks.Count) -ForegroundColor Cyan

    $chunkTxt = @()
    $chunkSrt = @()
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $c = $chunks[$i]
        $prefix = Join-Path $chunkDir ([System.IO.Path]::GetFileNameWithoutExtension($c.Name))
        Write-Host ("  кусок {0}/{1}..." -f ($i + 1), $chunks.Count) -ForegroundColor Cyan
        if ((Invoke-Whisper $fallbackModelPath $c.FullName $prefix) -ne 0) {
            Remove-Item $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $wav -Force -ErrorAction SilentlyContinue
            throw "Фолбэк не смог обработать кусок $($c.Name)"
        }
        $chunkTxt += "$prefix.txt"
        $chunkSrt += "$prefix.srt"
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($t in $chunkTxt) {
        if (Test-Path -LiteralPath $t) { [void]$sb.AppendLine((Get-Content -LiteralPath $t -Encoding UTF8 -Raw).Trim()) }
    }
    [System.IO.File]::WriteAllText("$outPrefix.txt", $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Merge-Srt -Files $chunkSrt -OffsetSeconds $ChunkSeconds -Dest "$outPrefix.srt"

    Remove-Item $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
    $ok = $true
}

Remove-Item $wav -Force -ErrorAction SilentlyContinue

if (-not $ok) { throw "Не удалось транскрибировать файл: $File" }

if ($DeleteTxt) { Remove-Item "$outPrefix.txt" -Force -ErrorAction SilentlyContinue }

Write-Host "Готово: $outPrefix.txt / $outPrefix.srt" -ForegroundColor Green
