<#
    install.ps1 - установка Zoom-рекордера "с нуля" (например, после переустановки Windows).

    Что делает:
      1. Поднимает права администратора (нужно для Chocolatey).
      2. Ставит Chocolatey, если его нет.
      3. Ставит Python, если нет команды python.
      4. Ставит ffmpeg, если нет команды ffmpeg.
      5. Ставит Python-зависимости: numpy, soundcard, cffi, psutil.
      6. Создаёт папку для записей D:\video_cast\zoom.
      7. Создаёт ярлык автозапуска в папке Startup.
      8. Запускает наблюдатель.

    Запуск: правой кнопкой -> "Выполнить с помощью PowerShell"
            либо:  powershell -ExecutionPolicy Bypass -File install.ps1
#>

# --- Самоэлевация до администратора -----------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Требуются права администратора. Перезапускаю с повышением..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Recorder  = Join-Path $ScriptDir "zoom_recorder.py"
$OutDir    = "D:\video_cast\zoom"
$PipPkgs   = @("numpy", "soundcard", "cffi", "psutil")

function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

Write-Host "== Zoom recorder: установка ==" -ForegroundColor Cyan

# 1. Chocolatey
if (-not (Have "choco")) {
    Write-Host "-> Chocolatey не найден, устанавливаю..." -ForegroundColor Yellow
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
} else {
    Write-Host "-> Chocolatey уже есть." -ForegroundColor Green
}

# 2. Python
if (-not (Have "python")) {
    Write-Host "-> Python не найден, устанавливаю..." -ForegroundColor Yellow
    choco install python -y --no-progress
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
} else {
    Write-Host "-> Python уже есть: $((Get-Command python).Source)" -ForegroundColor Green
}

# 3. ffmpeg
if (-not (Have "ffmpeg")) {
    Write-Host "-> ffmpeg не найден, устанавливаю..." -ForegroundColor Yellow
    choco install ffmpeg -y --no-progress
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
} else {
    Write-Host "-> ffmpeg уже есть: $((Get-Command ffmpeg).Source)" -ForegroundColor Green
}

# 4. Python-пакеты
Write-Host "-> Ставлю Python-пакеты: $($PipPkgs -join ', ')..." -ForegroundColor Yellow
python -m pip install --upgrade pip
python -m pip install --upgrade @PipPkgs

# 5. Папка записей
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
Write-Host "-> Папка записей: $OutDir" -ForegroundColor Green

# 6. Ярлык автозапуска
$pythonw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
if (-not $pythonw) { $pythonw = (Get-Command python).Source -replace "python\.exe$", "pythonw.exe" }
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup "ZoomRecorder.lnk"
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnkPath)
$sc.TargetPath = $pythonw
$sc.Arguments = '"' + $Recorder + '"'
$sc.WorkingDirectory = $ScriptDir
$sc.Description = "Zoom meeting recorder"
$sc.WindowStyle = 7
$sc.Save()
Write-Host "-> Ярлык автозапуска: $lnkPath" -ForegroundColor Green

# 7. Запуск
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" |
    Where-Object { $_.CommandLine -like "*zoom_recorder.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process $pythonw -ArgumentList ('"' + $Recorder + '"') -WorkingDirectory $ScriptDir
Write-Host "-> Наблюдатель запущен." -ForegroundColor Green

Write-Host ""
Write-Host "Готово. Логи: $OutDir\recorder.log ; записи: $OutDir\ГГГГ-ММ-ДД\Zoom_*.m4a" -ForegroundColor Cyan
