<#
    hourly.ps1 - hourly job: transcribe new Zoom recordings, then build konspekts.

    Steps:
      1. sync state DB
      2. for every recording without transcript (not modified in the last -MinAgeMinutes,
         to skip in-progress recordings) run transcribe.ps1 (default engine = gigaam)
      3. if any session is ready_for_konspekt, run konspekt.ps1 (opencode headless)

    Usage:
        powershell -ExecutionPolicy Bypass -File programs\hourly.ps1 [-NoPause]
            [-MinAgeMinutes 10] [-SkipTranscribe] [-SkipKonspekt]

    Scheduled hourly via Task Scheduler (task name: ZoomHourlyTranscribe).
    Intentionally ASCII-only (PowerShell 5.1 + Cyrillic needs UTF-8 BOM).
#>
[CmdletBinding()]
param(
    [switch]$NoPause,
    [int]$MinAgeMinutes = 10,
    [switch]$SkipTranscribe,
    [switch]$SkipKonspekt,
    [string]$KonspektModel
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $PSScriptRoot is empty in param defaults under -File on PowerShell 5.1
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root      = Split-Path -Parent $ScriptDir
$StatePy   = Join-Path $ScriptDir 'zoom_state.py'
$LogFile   = Join-Path $ScriptDir 'hourly.log'
$Transcribe= Join-Path $ScriptDir 'transcribe.ps1'
$Konspekt  = Join-Path $Root 'konspekt.ps1'
$Py        = 'python'

function Log([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

# single instance (do not overlap if a previous run is still busy)
$mutex = New-Object System.Threading.Mutex($false, 'Global\ZoomHourlyJob')
if (-not $mutex.WaitOne(0)) {
    Log 'another instance is already running, exit'
    exit 0
}

try {
    Log '---- hourly job start ----'

    & $Py -X utf8 $StatePy sync | Out-Null

    if (-not $SkipTranscribe) {
        $pending = (& $Py -X utf8 $StatePy pending --json | Out-String) | ConvertFrom-Json
        $files   = @($pending.no_transcript)
        $cutoff  = (Get-Date).AddMinutes(-$MinAgeMinutes)
        $todo    = @()
        foreach ($f in $files) {
            if ([string]::IsNullOrWhiteSpace($f)) { continue }
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $item = Get-Item -LiteralPath $f
            if ($item.LastWriteTime -gt $cutoff) {
                Log ('skip recent (maybe still recording): ' + $f)
                continue
            }
            $todo += $f
        }
        Log ('files to transcribe: ' + $todo.Count)
        foreach ($f in $todo) {
            Log ('transcribe: ' + $f)
            & powershell -NoProfile -ExecutionPolicy Bypass -File $Transcribe $f 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { Log '  transcribe ok' } else { Log ('  transcribe failed (exit ' + $LASTEXITCODE + ')') }
        }
        & $Py -X utf8 $StatePy sync | Out-Null
    }

    if (-not $SkipKonspekt) {
        $pending2 = (& $Py -X utf8 $StatePy pending --json | Out-String) | ConvertFrom-Json
        $ready    = @($pending2.ready_for_konspekt)
        Log ('sessions ready for konspekt: ' + $ready.Count)
        if ($ready.Count -gt 0) {
            Log 'running konspekt.ps1'
            $kargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Konspekt, '-NoPause')
            if ($KonspektModel) { $kargs += @('-Model', $KonspektModel) }
            $kout = & powershell @kargs 2>&1 | Out-String
            $krc  = $LASTEXITCODE
            foreach ($ln in ($kout -split "`r?`n")) {
                if ($ln.Trim().Length -gt 0) { Log ('  konspekt| ' + $ln.Trim()) }
            }
            Log ('konspekt exit ' + $krc)
        } else {
            Log 'nothing to konspekt'
        }
    }

    Log '---- hourly job done ----'
}
catch {
    Log ('ERROR: ' + $_.Exception.Message)
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    if (-not $NoPause -and -not [Console]::IsInputRedirected) { Read-Host 'Press Enter to close' | Out-Null }
}
