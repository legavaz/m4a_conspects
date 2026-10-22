<#
    install-hourly.ps1 - register/update the hourly Zoom transcription + konspekt job.

    Creates (or updates) Task Scheduler task 'ZoomHourlyTranscribe':
        wscript.exe //B //Nologo programs\run-hidden.vbs
        (which starts powershell -File programs\hourly.ps1 -NoPause with a hidden window,
         so the job never pops up and never steals focus)
    Trigger: once, repeating every 1 hour (indefinitely).
    Runs as the current user, only when that user is logged on.

    Usage:
        powershell -ExecutionPolicy Bypass -File programs\install-hourly.ps1
        powershell -ExecutionPolicy Bypass -File programs\install-hourly.ps1 -Remove
#>
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Hourly    = Join-Path $ScriptDir 'hourly.ps1'
$Hidden    = Join-Path $ScriptDir 'run-hidden.vbs'
$TaskName  = 'ZoomHourlyTranscribe'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host ('removed task: ' + $TaskName)
    exit 0
}

if (-not (Test-Path -LiteralPath $Hourly)) { throw ('hourly.ps1 not found: ' + $Hourly) }
if (-not (Test-Path -LiteralPath $Hidden)) { throw ('run-hidden.vbs not found: ' + $Hidden) }

# wscript + run-hidden.vbs -> powershell runs with a hidden window (no focus stealing)
$wscript  = Join-Path $env:SystemRoot 'System32\wscript.exe'
$action   = New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "' + $Hidden + '"')
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Hourly: transcribe new Zoom recordings (GigaAM) and build konspekts' -Force | Out-Null

Write-Host ('registered task: ' + $TaskName)
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
(Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object NextRunTime, LastRunTime, LastTaskResult | Format-List | Out-String).Trim() | Write-Host
