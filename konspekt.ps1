# konspekt.ps1 - headless runner for the opencode "konspekt" workflow
# Regulation: programs\prompt-konspekt.md ; launch prompt: programs\konspekt-command.md
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File konspekt.ps1 [-Target <folder|file>] [-NoPause]
#
#   -Target   what to process; default = project root (all ready_for_konspekt sessions)
#   -NoPause  do not wait for Enter at the end (for Task Scheduler / unattended runs)
#   -Model    model fallback chain as a comma-separated string; tried in order until one
#             exits 0 (default: Big Pickle, then free, then a paid model).
#
# The script is intentionally ASCII-only: PowerShell 5.1 needs UTF-8 with BOM for
# Cyrillic literals, so all Russian text lives in the command file (read by opencode).

[CmdletBinding()]
param(
    [string] $Target,
    [switch] $NoPause,
    [string] $Model = 'opencode/big-pickle,opencode/step-5-preview-free,opencode/nemotron-3-ultra-free,opencode-go/gpt-5.6-luna'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# $PSScriptRoot is empty in param defaults under -File on PowerShell 5.1
if ([string]::IsNullOrWhiteSpace($Target)) { $Target = $PSScriptRoot }

Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Host '[konspekt] opencode not found in PATH' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Target)) {
    Write-Host ('[konspekt] target not found: ' + $Target) -ForegroundColor Red
    exit 2
}

$Target = (Resolve-Path -LiteralPath $Target).Path

Write-Host ''
Write-Host ('[konspekt] opencode run --agent build --auto (prompt: programs\konspekt-command.md) target: "' + $Target + '"') -ForegroundColor Cyan
Write-Host ''

$Prompt = "Read programs/konspekt-command.md in full and follow it exactly. Target: $Target"

$models = @($Model -split '\s*,\s*' | Where-Object { $_ -ne '' })
if ($models.Count -eq 0) { $models = @('') }
$rc = 1
foreach ($m in $models) {
    if ([string]::IsNullOrWhiteSpace($m)) {
        Write-Host '[konspekt] model: (default)' -ForegroundColor Cyan
        & opencode run --agent build --auto $Prompt
    } else {
        Write-Host ('[konspekt] model: ' + $m) -ForegroundColor Cyan
        & opencode run --agent build --auto --model $m $Prompt
    }
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { break }
    $label = if ([string]::IsNullOrWhiteSpace($m)) { '(default)' } else { $m }
    Write-Host ('[konspekt] model failed (exit ' + $rc + '): ' + $label + ' -> trying next') -ForegroundColor Yellow
}

Write-Host ''
if ($rc -eq 0) {
    Write-Host '[konspekt] finished OK' -ForegroundColor Green
} else {
    Write-Host ('[konspekt] finished with exit code ' + $rc) -ForegroundColor Yellow
}

if (-not $NoPause) {
    Read-Host 'Press Enter to close'
}
exit $rc
