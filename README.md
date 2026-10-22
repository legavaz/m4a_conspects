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
| `konspekt.ps1` | автономный (headless) запуск конспекта через `opencode run` (в корне проекта) |
| `programs\zoom_recorder.py` | основной скрипт-наблюдатель и рекордер |
| `programs\install.ps1` | установка зависимостей и настройка автозапуска «с нуля» |
| `programs\transcribe.ps1` | локальная транскрибация одной записи (движки: GigaAM-v3 e2e-RNN-T / NVIDIA Nemotron 3.5 ASR / whisper.cpp, без облака) |
| `programs\transcribe_gigaam.py` | хелпер движка GigaAM (onnx-asr + Silero VAD; DirectML/CPU) |
| `programs\transcribe-all.ps1` | пакетная транскрибация всех новых записей в папке |
| `programs\zoom_state.py` | БД состояния обработки (SQLite): sync / pending / mark / publish / status / session |
| `programs\hourly.ps1` | почасовой цикл: транскрибация новых записей (GigaAM) → создание конспектов |
| `programs\install-hourly.ps1` | регистрация/удаление задания планировщика `ZoomHourlyTranscribe` (каждый час, скрытый запуск) |
| `programs\run-hidden.vbs` | обёртка для планировщика: запускает `hourly.ps1` без окна (не перекрывает другие окна) |
| `programs\konspekt-command.md` | промпт автономного конспекта (вызывается `konspekt.ps1` по регламенту `prompt-konspekt.md`) |
| `programs\prompt-konspekt.md` | стандартный промпт для конспекта встречи (opencode) |
| `programs\MEMORY.md` | память проекта: факты, уроки, журнал обработки |
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

- Записи: `D:\video_cast\zoom\ГГГГ\ММ\ГГГГ-ММ-ДД\Zoom_ГГГГММДД_ЧЧММСС.m4a` (год/месяц/день — как в Obsidian)
- Лог: `D:\video_cast\zoom\recorder.log`
- Автозапуск: ярлык `ZoomRecorder.lnk` в папке «Автозагрузка» (`shell:startup`), запуск через `pythonw` — без окна.

## Конспект встречи (транскрибация + суммаризация)

Транскрибация — полностью локальная (токены LLM не расходуются). Доступны **три движка**:

- **GigaAM-v3 e2e-RNN-T** (по умолчанию, `-Engine gigaam`) — русскоязычная модель Sber/Salute (Conformer + RNN-T, ~180M, MIT), выход **с пунктуацией и регистром**. Длинные записи нарезаются по тишине (Silero VAD), поэтому подходит для встреч любой длины. Работает через `onnx-asr` в отдельном venv; ускорение на GPU через **DirectML** (CUDA невозможна на текущем драйвере — см. ниже). Порядок ~**30x realtime** на GPU (RTX 5050) / ~16x на CPU.
- **Nemotron 3.5 ASR** (`-Engine nemotron`) — NVIDIA, `nemo-speech` (NeMo-Speech.cpp, нативный C++/ggml). Быстрее (~0.5x realtime на CPU), но на русской речи с именами/1С-терминами может терять точность (модель 0.6B).
- **whisper.cpp** (`-Engine whisper`) — точнее Nemotron (large-v3-turbo, 809M), но медленнее (~0.9x realtime). Используется как автоматический резерв при сбое GigaAM/Nemotron.

```powershell
# одна запись (по умолчанию GigaAM)
powershell -ExecutionPolicy Bypass -File transcribe.ps1 "D:\video_cast\zoom\ГГГГ\ММ\ГГГГ-ММ-ДД\Zoom_....m4a"
# принудительно nemotron / whisper
powershell -ExecutionPolicy Bypass -File transcribe.ps1 "..." -Engine nemotron
powershell -ExecutionPolicy Bypass -File transcribe.ps1 "..." -Engine whisper
# вся папка (все новые записи)
powershell -ExecutionPolicy Bypass -File transcribe-all.ps1 "D:\video_cast\zoom\ГГГГ\ММ\ГГГГ-ММ-ДД"
```

- **GigaAM**: модель `gigaam-v3-e2e-rnnt` (fp32, ~890 МБ) в `D:\video_cast\zoom\models\gigaam-v3-e2e-rnnt`; интерпретатор — `D:\video_cast\zoom\.venv-gigaam\Scripts\python.exe`. Опции: `-GigaamModel` (каталог), `-GigaamProvider` (`auto` (по умолч.; cuda→dml→cpu) | `cuda` | `dml` | `cpu`), `-GigaamPython` (путь к python). Реализация — `programs\transcribe_gigaam.py` (onnx-asr + Silero VAD; пишет `.txt` и `.srt` по речевым сегментам). Установка окружения: `uv venv --python 3.12 .venv-gigaam` + `uv pip install --python .venv-gigaam\Scripts\python.exe "onnx-asr[hub]" onnxruntime-directml`.

- **whisper**: модель по умолчанию `ggml-large-v3-turbo` (лежит в `D:\video_cast\zoom\models`; при отсутствии скачается автоматически). Черновой быстрый вариант: `-Model ggml-small.bin`. Опции: `-NoVad`, `-Retries`, `-ChunkSeconds`, `-NoFallback`.
- Вход: `m4a`, `webm`, `mp4`, `mp3`, `wav`, `ogg`, `m4b` (декодирует ffmpeg).
- Результат: `<имя>.txt` и `<имя>.srt` (таймкоды) рядом с записью.
- Надёжность whisper: при сбое — автоповторы (`-Retries`), затем фолбэк (нарезка `-ChunkSeconds` + `ggml-small`) со склейкой `.txt`/`.srt`. При сбое GigaAM — автооткат на Nemotron, затем на whisper; при сбое Nemotron — автооткат на whisper (если не указан `-NoFallback`).
- Конспект делает opencode (LLM): в чате **`Конспект: <путь к .m4a>`** (или **`Конспект: <папка>`**) → транскрибация → Markdown-конспект в стиле executive summary (обзорный абзац, **Ключевые решения**, **Важные обновления статуса** с `==подсветкой==` цифр, **Следующие шаги**, **Открытые вопросы**; короткая хронология с таймкодами — опционально) сохраняется рядом с аудио и в Obsidian `Обсидиан/Встречи Zoom/ГГГГ/ММ/ГГГГ-ММ-ДД/ЧЧ-ММ — тема.md`.
- Полный текст промпта: `prompt-konspekt.md`.
- **Автономный запуск (без чата)**: `powershell -ExecutionPolicy Bypass -File konspekt.ps1 [-Target <папка|файл>] [-NoPause] [-Model "m1,m2,..."]` — запускает `opencode run --agent build --auto` с промптом из `programs\konspekt-command.md` и обрабатывает все готовые записи из `pending`; без `-Target` — весь проект, `-NoPause` — не ждать Enter (для планировщика). `-Model` — цепочка моделей через запятую, перебирается до первого успеха (по умолчанию Big Pickle → бесплатная → платная), защищает от исчерпанных лимитов провайдера.
- **Публикация в Obsidian**: конспект пишется только рядом с аудио, заметку создаёт команда `python programs\zoom_state.py publish "<конспект>" --obsidian "Обсидиан/Встречи Zoom/ГГГГ\ММ\ГГГГ-ММ-ДД\ЧЧ-ММ — тема.md"` — она копирует файл в vault и проставляет в БД `obsidian_path`/`done`. Писать заметку в Obsidian вручную нельзя: получаются дубли и расхождения с локальным файлом.

## Почасовой автозапуск (Task Scheduler)

Задание раз в час транскрибирует новые записи и создаёт конспекты:

- `programs\hourly.ps1` — сам цикл: `sync` → транскрибация всех записей в статусе `new` (движок по умолчанию GigaAM; пропускает файлы, изменённые за последние `-MinAgeMinutes` минут, чтобы не трогать идущую запись; записи без речи получают `no_speech` и больше не гоняются) → если есть `ready_for_konspekt`, запускает `konspekt.ps1`. Защищён мьютексом (без наложений), пишет лог `programs\hourly.log`.
- `programs\install-hourly.ps1` — регистрирует/снимает задание `ZoomHourlyTranscribe` (каждый час, от имени текущего пользователя, только при входе в сеанс). Задание запускает `wscript.exe //B //Nologo programs\run-hidden.vbs`: окно PowerShell скрыто, поэтому почасовой прогон не всплывает и не перехватывает фокус.

```powershell
# установить/обновить задание
powershell -ExecutionPolicy Bypass -File programs\install-hourly.ps1
# удалить задание
powershell -ExecutionPolicy Bypass -File programs\install-hourly.ps1 -Remove
# разовый ручной прогон (без ожидания Enter)
powershell -ExecutionPolicy Bypass -File programs\hourly.ps1 -NoPause
```

- Опции `hourly.ps1`: `-MinAgeMinutes 10` (возраст файла), `-SkipTranscribe`, `-SkipKonspekt` (для отладки), `-NoPause`.
- Запуск конспекта требует `opencode` в `PATH` (как и `konspekt.ps1`).

## Состояние обработки (SQLite)

Единая точка правды о том, что уже сделано с каждой записью — чтобы не перепроверять каждый файл и не гонять лишний раз. БД: `D:\video_cast\zoom\state.db`.

```powershell
python programs\zoom_state.py sync       # сверить БД с файлами (НЕ транскрибирует)
python programs\zoom_state.py pending    # что осталось: без транскрипта / готово к конспекту
python programs\zoom_state.py pending --json
python programs\zoom_state.py status     # сводка по статусам
python programs\zoom_state.py mark "<аудио>" done --konspekt "<путь>" --obsidian "<путь>"
```

- **Статусы**: `new` (нет транскрипта) → `transcribed` (есть `.txt`/`.srt`) → `done` (есть `_конспект.md`); `no_speech` (движок отработал, но оба файла пустые — запись без речи, повторно не гоняется); `deleted` (файл пропал).
- **Детект изменений**: `sync` сравнивает `size`/`mtime`; если запись перезаписана — статус сбрасывается в `new`.
- **Автоматическая транскрибация — только в почасовом задании** (`hourly.ps1`): оно берёт записи со статусом `new`, поэтому очередь не растёт и файлы не обрабатываются повторно. `sync`/`pending` сами ничего не транскрибируют; ручная транскрибация — отдельно и только с согласия пользователя.

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