<#
    transcribe.ps1 - локальная транскрибация аудио/видео в текст (без облака).
    Движки: NVIDIA Nemotron 3.5 ASR (по умолчанию, nemo-speech) и whisper.cpp (резерв).

    Использование:
        powershell -ExecutionPolicy Bypass -File transcribe.ps1 "D:\video_cast\zoom\2026-09-15\Zoom_....m4a"

    Опции:
        -Engine    nemotron (по умолчанию) | whisper   выбор движка транскрибации
        -Model     whisper: ggml-large-v3-turbo.bin (по умолчанию; скачается при отсутствии)
                   ggml-small.bin - быстрая модель whisper
        -NemoModel nemotron: имя/путь GGUF (по умолчанию nemotron-3.5, из каталога моделей)
        -NemoDevice nemotron: cpu (по умолчанию) | auto | cuda | vulkan
        -Lang      ru (по умолчанию) | auto | en ...
        -Threads   14 (по умолчанию; whisper)
        -NoVad     отключить Voice Activity Detection (whisper)
        -DeleteTxt  удалить .txt (оставить только .srt с таймкодами)
        -Retries N  число повторов whisper-cli при сбое (по умолчанию 2)
        -ChunkSeconds N  длина куска для фолбэка whisper, сек (по умолчанию 600)
        -NoFallback  не использовать нарезку + ggml-small при сбое whisper
                   (и не откатываться nemotron -> whisper)

    Форматы входа: m4a, webm, mp4, wav, mp3, ogg и др. (декодирует ffmpeg).
    Результат: <имя>.txt и <имя>.srt (таймкоды) рядом с исходным файлом.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$File,
    [ValidateSet("nemotron", "whisper")]
    [string]$Engine = "nemotron",
    [string]$Model = "ggml-large-v3-turbo.bin",
    [string]$NemoModel = "nemotron-3.5",
    [string]$NemoDevice = "cpu",
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
$NemoCli       = $null
if (Get-Command nemo-speech -ErrorAction SilentlyContinue) { $NemoCli = "nemo-speech" }
elseif (Test-Path -LiteralPath "C:\Users\lega\AppData\Local\Programs\NeMoSpeech\bin\nemo-speech.exe") {
    $NemoCli = "C:\Users\lega\AppData\Local\Programs\NeMoSpeech\bin\nemo-speech.exe"
}

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

# Собрать .txt из .srt (одна строка текста на кусок), чтобы не гонять распознавание дважды.
function Get-TxtFromSrt([string]$srt, [string]$dest) {
    $sb = New-Object System.Text.StringBuilder
    $inText = $false
    foreach ($line in (Get-Content -LiteralPath $srt -Encoding UTF8)) {
        if ($line -match '^\s*\d+\s*$') { $inText = $false; continue }
        elseif ($line -match '^\d\d:\d\d:\d\d,\d\d\d\s*-->\s*\d\d:\d\d:\d\d,\d\d\d') { $inText = $true; continue }
        elseif ($inText) {
            $t = $line.Trim()
            if ($t) { [void]$sb.AppendLine($t) }
        }
    }
    [System.IO.File]::WriteAllText($dest, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $File)) { throw "Файл не найден: $File" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "ffmpeg не найден в PATH" }
if ($Engine -eq "whisper") {
    if (-not (Test-Path -LiteralPath $WhisperCli)) { throw "whisper-cli не найден: $WhisperCli" }
} else {
    if (-not $NemoCli) { throw "nemo-speech не найден. Установите NeMo-Speech.cpp (см. README) или укажите -Engine whisper" }
}

$full      = (Resolve-Path -LiteralPath $File).Path
$base      = [System.IO.Path]::GetFileNameWithoutExtension($full)
$dir       = Split-Path -Parent $full
$wav       = Join-Path $env:TEMP ("{0}_{1}.wav" -f $base, [guid]::NewGuid().ToString("N").Substring(0, 8))
$outPrefix = Join-Path $dir $base

# --- whisper: модель и VAD ---------------------------------------------------
$VadModelName = "ggml-silero-v5.1.2.bin"
$VadModelPath = Join-Path $ModelDir $VadModelName
$vadArgs = @()
function Init-Whisper {
    if (-not (Test-Path -LiteralPath $VadModelPath) -and -not $NoVad) {
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
    if (-not $NoVad) { $script:vadArgs = @("--vad", "-vm", "$VadModelPath") }
}

function Invoke-Whisper([string]$modelPath, [string]$audio, [string]$prefix) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $WhisperCli -m "$modelPath" -l $Lang -t $Threads @vadArgs -otxt -osrt -pp -of "$prefix" "$audio" | Write-Host
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("  whisper-cli: код {0}, время {1:hh\:mm\:ss}" -f $code, $sw.Elapsed) -ForegroundColor DarkGray
    return $code
}

# whisper: основной проход с повторами + фолбэк (нарезка + ggml-small). Вернёт $true при успехе.
function Invoke-WhisperPipeline([string]$audio, [string]$prefix) {
    Init-Whisper
    $modelPath = Get-ModelPath $Model
    $ok = $false
    $attempt = 0
    while (-not $ok -and $attempt -le $Retries) {
        $attempt++
        if ($attempt -eq 1) {
            Write-Host "Транскрибирую whisper (модель: $Model, язык: $Lang, потоков: $Threads)..." -ForegroundColor Cyan
        } else {
            Write-Host "Повтор whisper ($attempt из $($Retries + 1))..." -ForegroundColor Yellow
        }
        if ((Invoke-Whisper $modelPath $audio $prefix) -eq 0) { $ok = $true }
    }
    if (-not $ok) {
        if ($NoFallback) { return $false }
        Write-Host "whisper не справился. Фолбэк: нарезка по $ChunkSeconds с + $FallbackModel" -ForegroundColor Yellow
        $fallbackModelPath = Get-ModelPath $FallbackModel
        $chunkDir = Join-Path $env:TEMP ("chunks_{0}" -f [guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null

        & ffmpeg -hide_banner -loglevel error -y -i "$audio" -f segment -segment_time $ChunkSeconds -c:a pcm_s16le (Join-Path $chunkDir "chunk_%03d.wav")
        if ($LASTEXITCODE -ne 0) {
            Remove-Item $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
            throw "ffmpeg не смог нарезать WAV на куски"
        }

        $chunks = @(Get-ChildItem -LiteralPath $chunkDir -Filter "chunk_*.wav" | Sort-Object Name)
        Write-Host ("  кусков: {0}" -f $chunks.Count) -ForegroundColor Cyan

        $chunkTxt = @()
        $chunkSrt = @()
        for ($i = 0; $i -lt $chunks.Count; $i++) {
            $c = $chunks[$i]
            $cprefix = Join-Path $chunkDir ([System.IO.Path]::GetFileNameWithoutExtension($c.Name))
            Write-Host ("  кусок {0}/{1}..." -f ($i + 1), $chunks.Count) -ForegroundColor Cyan
            if ((Invoke-Whisper $fallbackModelPath $c.FullName $cprefix) -ne 0) {
                Remove-Item $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
                throw "Фолбэк не смог обработать кусок $($c.Name)"
            }
            $chunkTxt += "$cprefix.txt"
            $chunkSrt += "$cprefix.srt"
        }

        $sb = New-Object System.Text.StringBuilder
        foreach ($t in $chunkTxt) {
            if (Test-Path -LiteralPath $t) { [void]$sb.AppendLine((Get-Content -LiteralPath $t -Encoding UTF8 -Raw).Trim()) }
        }
        [System.IO.File]::WriteAllText("$prefix.txt", $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Merge-Srt -Files $chunkSrt -OffsetSeconds $ChunkSeconds -Dest "$prefix.srt"

        Remove-Item $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
        $ok = $true
    }
    return $ok
}

# nemotron: один проход через nemo-speech; при сбое - откат на whisper.
function Invoke-NemotronPipeline([string]$audio, [string]$prefix) {
    $env:NEMO_SPEECH_MODEL_DIR = $ModelDir
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Транскрибирую nemotron (модель: $NemoModel, язык: $Lang, устройство: $NemoDevice)..." -ForegroundColor Cyan
    & $NemoCli transcribe "$audio" --model $NemoModel --language $Lang --device $NemoDevice --format srt --output "$prefix.srt" | Write-Host
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("  nemo-speech: код {0}, время {1:hh\:mm\:ss}" -f $code, $sw.Elapsed) -ForegroundColor DarkGray
    if ($code -eq 0 -and (Test-Path -LiteralPath "$prefix.srt")) {
        Get-TxtFromSrt "$prefix.srt" "$prefix.txt"
        return $true
    }
    return $false
}

# --- Конвертация в WAV 16 кГц моно -----------------------------------------
Write-Host "Конвертирую в WAV 16 кГц моно..." -ForegroundColor Cyan
& ffmpeg -hide_banner -loglevel error -y -i "$full" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
if ($LASTEXITCODE -ne 0) {
    Remove-Item $wav -Force -ErrorAction SilentlyContinue
    throw "ffmpeg завершился с ошибкой"
}

# --- Транскрибация -----------------------------------------------------------
$ok = $false
if ($Engine -eq "nemotron") {
    $ok = Invoke-NemotronPipeline $wav $outPrefix
    if (-not $ok) {
        if ($NoFallback) {
            Write-Host "nemotron не справился (фолбэк отключён -NoFallback)." -ForegroundColor Red
        } else {
            Write-Host "nemotron не справился. Откат на whisper..." -ForegroundColor Yellow
            $ok = Invoke-WhisperPipeline $wav $outPrefix
        }
    }
} else {
    $ok = Invoke-WhisperPipeline $wav $outPrefix
}

Remove-Item $wav -Force -ErrorAction SilentlyContinue

if (-not $ok) { throw "Не удалось транскрибировать файл: $File" }

if ($DeleteTxt) { Remove-Item "$outPrefix.txt" -Force -ErrorAction SilentlyContinue }

Write-Host "Готово: $outPrefix.txt / $outPrefix.srt" -ForegroundColor Green