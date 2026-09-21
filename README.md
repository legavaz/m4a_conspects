# Zoom Recorder

Автоматическая запись аудио совещаний Zoom: **системный звук (колонки) + микрофон** сводятся в один моно-файл **M4A**. Запись ведётся **только во время активной конференции** и стартует/останавливается сама.

## Как это работает

- Наблюдатель раз в 2 секунды проверяет наличие процесса **`CptHost.exe`** («Zoom Sharing Host»).
  - `Zoom.exe` открыт, но встречи нет → `CptHost.exe` отсутствует → **записи нет**.
  - Идёт встреча → `CptHost.exe` работает → **идёт запись**.
  - Встреча закончилась → процесс исчез → через 5 секунд запись финализируется.
- Захват звука (библиотека `soundcard`, WASAPI):
  - **loopback** — то, что играет в колонках/наушниках (голоса собеседников);
  - **микрофон** — default-устройство записи на момент старта (голос пользователя).
- Оба потока сводятся в моно и кодируются в AAC/M4A через **ffmpeg**.

## Файлы

| Файл | Назначение |
|---|---|
| `zoom_recorder.py` | основной скрипт-наблюдатель и рекордер |
| `install.ps1` | установка зависимостей и настройка автозапуска «с нуля» |
| `transcribe.ps1` | локальная транскрибация одной записи (движки: NVIDIA Nemotron 3.5 ASR / whisper.cpp, без облака) |
| `transcribe-all.ps1` | пакетная транскрибация всех новых записей в папке |
| `zoom_state.py` | БД состояния обработки (SQLite): sync / pending / mark / status |
| `konspekt.ps1` (корень проекта) | автономный (headless) запуск конспекта через `opencode run` |
| `konspekt-command.md` | промпт автономного конспекта (вызывается `konspekt.ps1` по регламенту `prompt-konspekt.md`) |
| `prompt-konspekt.md` | стандартный промпт для конспекта встречи (opencode) |
| `README.md` | этот файл |

## Зависимости

- **Python 3** (проверено на 3.14)
- **ffmpeg** в `PATH` (кодирование в AAC/M4A)
- Python-пакеты: `numpy`, `soundcard`, `cffi`, `psutil`

Всё ставится автоматически скриптом `install.ps1` (через Chocolatey для Python/ffmpeg).

## Установка

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Скрипт сам поднимет права администратора, поставит Python, ffmpeg, pip-пакеты, создаст папку записей, ярлык автозапуска и запустит наблюдатель.

## Результат

- Записи: `D:\video_cast\zoom\ГГГГ-ММ-ДД\Zoom_ДАТА_ВРЕМЯ.m4a` (подпапка текущего дня)
- Лог: `D:\video_cast\zoom\recorder.log`
- Автозапуск: ярлык `ZoomRecorder.lnk` в папке «Автозагрузка» (`shell:startup`), запуск через `pythonw` — без окна.

## Конспект встречи (транскрибация + суммаризация)

Транскрибация — полностью локальная (токены LLM не расходуются). Доступны **два движка**:

- **Nemotron 3.5 ASR** (по умолчанию) — NVIDIA, `nemo-speech` (NeMo-Speech.cpp, нативный C++/ggml). Быстрее (~0.5x realtime на CPU), но на русской речи с именами/1С-терминами может терять точность (модель 0.6B).
- **whisper.cpp** (`-Engine whisper`) — точнее на русском (large-v3-turbo, 809M), но медленнее (~0.9x realtime). Используется как автоматический резерв при сбое Nemotron.

```powershell
# одна запись (по умолчанию Nemotron)
powershell -ExecutionPolicy Bypass -File transcribe.ps1 "D:\video_cast\zoom\ГГГГ-ММ-ДД\Zoom_....m4a"
# принудительно whisper
powershell -ExecutionPolicy Bypass -File transcribe.ps1 "D:\video_cast\zoom\ГГГГ-ММ-ДД\Zoom_....m4a" -Engine whisper
# вся папка (все новые записи)
powershell -ExecutionPolicy Bypass -File transcribe-all.ps1 "D:\video_cast\zoom\ГГГГ-ММ-ДД"
```

- **Nemotron**: модель `nemotron-3.5` (GGUF Q8 ~707 МБ) лежит в `D:\video_cast\zoom\models` (подкаталог `nvidia\...`). Опции: `-NemoModel` (имя/путь), `-NemoDevice` (по умолч. `cpu`; `auto|cuda|vulkan`), язык — `-Lang` (`ru`). SRT-куски дробятся по границам предложений/пауз; `.txt` собирается из `.srt` одним проходом.
- **whisper**: модель по умолчанию `ggml-large-v3-turbo` (лежит в `D:\video_cast\zoom\models`; при отсутствии скачается автоматически). Черновой быстрый вариант: `-Model ggml-small.bin`. Опции: `-NoVad`, `-Retries`, `-ChunkSeconds`, `-NoFallback`.
- Вход: `m4a`, `webm`, `mp4`, `mp3`, `wav`, `ogg`, `m4b` (декодирует ffmpeg).
- Результат: `<имя>.txt` и `<имя>.srt` (таймкоды) рядом с записью.
- Надёжность whisper: при сбое — автоповторы (`-Retries`), затем фолбэк (нарезка `-ChunkSeconds` + `ggml-small`) со склейкой `.txt`/`.srt`. При сбое Nemotron — автооткат на whisper (если не указан `-NoFallback`).
- Конспект делает opencode (LLM): в чате **`Конспект: <путь к .m4a>`** (или **`Конспект: <папка>`**) → транскрибация → Markdown-конспект (участники, темы с таймкодами из `.srt`, решения, ❗важное с ==подсветкой==) сохраняется рядом с аудио и в Obsidian `Обсидиан/Встречи Zoom/ГГГГ/ММ/ГГГГ-ММ-ДД/ЧЧ-ММ — тема.md`.
- Полный текст промпта: `prompt-konspekt.md`.
- **Автономный запуск (без чата)**: `powershell -ExecutionPolicy Bypass -File konspekt.ps1 [-Target <папка|файл>] [-NoPause]` — запускает `opencode run --agent build --auto` с промптом из `programs\konspekt-command.md` и обрабатывает все готовые записи из `pending`; без `-Target` — весь проект, `-NoPause` — не ждать Enter (для планировщика).

## Состояние обработки (SQLite)

Единая точка правды о том, что уже сделано с каждой записью — чтобы не перепроверять каждый файл и не гонять лишний раз. БД: `D:\video_cast\zoom\state.db`.

```powershell
python programs\zoom_state.py sync       # сверить БД с файлами (НЕ транскрибирует)
python programs\zoom_state.py pending    # что осталось: без транскрипта / готово к конспекту
python programs\zoom_state.py pending --json
python programs\zoom_state.py status     # сводка по статусам
python programs\zoom_state.py mark "<аудио>" done --konspekt "<путь>" --obsidian "<путь>"
```

- **Статусы**: `new` (нет транскрипта) → `transcribed` (есть `.txt`/`.srt`) → `done` (есть `_конспект.md`); `deleted` (файл пропал).
- **Детект изменений**: `sync` сравнивает `size`/`mtime`; если запись перезаписана — статус сбрасывается в `new`.
- **Никакой авто-транскрибации**: `sync`/`pending` только фиксируют состояние. Файлы без транскрипта пропускаются; транскрибация — отдельно и только по явной просьбе.

## Настройки

Параметры задаются словарём `CONFIG` в начале `zoom_recorder.py`:

| Ключ | Значение по умолчанию | Описание |
|---|---|---|
| `output_dir` | `D:\video_cast\zoom` | папка для M4A |
| `log_file` | `D:\video_cast\zoom\recorder.log` | файл лога |
| `log_max_bytes` | `1000000` | размер лога до ротации, байт |
| `log_backup_count` | `3` | число архивных копий лога |
| `meeting_process` | `cpthost.exe` | процесс, означающий активную встречу |
| `poll_interval` | `2.0` | период проверки, сек |
| `stop_debounce` | `5.0` | пауза перед остановкой после выхода из встречи, сек |
| `min_duration` | `3.0` | короче этого — файл удаляется, сек |
| `sample_rate` | `48000` | частота дискретизации |
| `block_frames` | `4800` | размер блока чтения (~100 мс) |
| `aac_bitrate` | `128k` | битрейт AAC |

## Замечания

- Записывается **default-устройство воспроизведения** на момент старта встречи. Если во время звонка переключить вывод на другое устройство, запись продолжит брать старое.
- Если во время встречи запись не началась — проверь `recorder.log` и наличие `CptHost.exe` в диспетчере задач.
- Тело `zoom_recorder.py` можно останавливать/запускать вручную; ярлык в автозагрузке обеспечивает постоянную работу после входа в систему.