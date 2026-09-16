#!/usr/bin/env python3
"""zoom_state.py - состояние обработки Zoom-записей (SQLite).

Назначение: единая точка правды о том, что уже сделано с каждой записью,
чтобы не перепроверять каждый файл и не гонять лишний раз.

ВАЖНО: скрипт НЕ транскрибирует. Он только фиксирует состояние.
Транскрибация запускается отдельно (transcribe.ps1) и только по явной просьбе.

Команды:
    sync                 обход папок, сверка с БД (детект изменений по size/mtime,
                         докрутка статусов из файлов: _конспект.md / .txt / .srt)
    pending [--json]     что нужно сделать: без транскрипта (пропуск) и готово к конспекту
    mark <файл> <статус> проставить статус: new|transcribed|done|deleted
                         [--konspekt PATH] [--obsidian PATH]
    status               сводка по статусам + последние конспекты

БД: D:\\video_cast\\zoom\\state.db
"""
import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime

ROOT = r"D:\video_cast\zoom"
DB_PATH = os.path.join(ROOT, "state.db")
MEDIA_EXTS = {".m4a", ".webm", ".mp4", ".mp3", ".wav", ".ogg", ".m4b"}
STATUSES = ("new", "transcribed", "done", "deleted")

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def connect():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS files (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            path           TEXT NOT NULL UNIQUE,
            day            TEXT,
            filename       TEXT,
            size_bytes     INTEGER,
            mtime          INTEGER,
            status         TEXT NOT NULL DEFAULT 'new',
            transcribed_at TEXT,
            summarized_at  TEXT,
            konspekt_path  TEXT,
            obsidian_path  TEXT,
            error          TEXT
        )
        """
    )
    return conn


def derive_status(media_path):
    """Статус по файлам рядом с аудио. Возвращает (status, konspekt_path)."""
    base = os.path.splitext(media_path)[0]
    konspekt = base + "_конспект.md"
    if os.path.exists(konspekt):
        return "done", konspekt
    if os.path.exists(base + ".txt") or os.path.exists(base + ".srt"):
        return "transcribed", None
    return "new", None


def iter_media():
    """Все медиа-файлы в корне и в папках-днях (ГГГГ-ММ-ДД)."""
    dirs = [ROOT]
    for name in sorted(os.listdir(ROOT)):
        d = os.path.join(ROOT, name)
        if os.path.isdir(d) and len(name) == 10 and name[4] == "-" and name[7] == "-":
            dirs.append(d)
    for d in dirs:
        for fn in sorted(os.listdir(d)):
            p = os.path.join(d, fn)
            if os.path.isfile(p) and os.path.splitext(fn)[1].lower() in MEDIA_EXTS:
                day = "" if d == ROOT else os.path.basename(d)
                yield day, p


def rel(path):
    try:
        return os.path.relpath(path, ROOT)
    except ValueError:
        return path


def cmd_sync(args):
    conn = connect()
    seen = set()
    added = changed = reconciled = missing = 0
    for day, path in iter_media():
        seen.add(path)
        st = os.stat(path)
        size, mtime = st.st_size, int(st.st_mtime)
        derived, konspekt = derive_status(path)
        row = conn.execute("SELECT * FROM files WHERE path=?", (path,)).fetchone()

        if row is None:
            conn.execute(
                "INSERT INTO files(path,day,filename,size_bytes,mtime,status,"
                "transcribed_at,summarized_at,konspekt_path) VALUES(?,?,?,?,?,?,?,?,?)",
                (path, day, os.path.basename(path), size, mtime, derived,
                 now() if derived in ("transcribed", "done") else None,
                 now() if derived == "done" else None,
                 konspekt))
            added += 1
            continue

        if row["size_bytes"] != size or row["mtime"] != mtime:
            # файл изменился (перезаписан) -> сброс состояния по факту файлов
            conn.execute(
                "UPDATE files SET size_bytes=?,mtime=?,status=?,transcribed_at=?,"
                "summarized_at=?,konspekt_path=?,obsidian_path=NULL,error=NULL WHERE id=?",
                (size, mtime, derived,
                 now() if derived in ("transcribed", "done") else None,
                 now() if derived == "done" else None,
                 konspekt, row["id"]))
            changed += 1
            continue

        # файл не менялся -> докрутить статус по факту (вверх/вниз по файлам)
        sets, params = [], []
        if row["status"] != derived:
            sets.append("status=?")
            params.append(derived)
            if derived in ("transcribed", "done") and not row["transcribed_at"]:
                sets.append("transcribed_at=?")
                params.append(now())
            if derived == "done" and not row["summarized_at"]:
                sets.append("summarized_at=?")
                params.append(now())
        if konspekt and not row["konspekt_path"]:
            sets.append("konspekt_path=?")
            params.append(konspekt)
        if sets:
            params.append(row["id"])
            conn.execute("UPDATE files SET " + ",".join(sets) + " WHERE id=?", params)
            reconciled += 1

    for r in conn.execute("SELECT id,path,status FROM files").fetchall():
        if r["path"] not in seen and r["status"] != "deleted":
            conn.execute("UPDATE files SET status='deleted' WHERE id=?", (r["id"],))
            missing += 1

    conn.commit()
    conn.close()
    print(f"sync: добавлено {added}, изменено {changed}, докручено {reconciled}, "
          f"помечено удалёнными {missing}")


def cmd_pending(args):
    conn = connect()
    rows = conn.execute(
        "SELECT * FROM files WHERE status IN ('new','transcribed') "
        "ORDER BY day, filename").fetchall()
    no_transcript = [r["path"] for r in rows if r["status"] == "new"]
    ready = [r["path"] for r in rows if r["status"] == "transcribed"]
    counts = {r["status"]: r["n"] for r in
              conn.execute("SELECT status, COUNT(*) AS n FROM files GROUP BY status")}
    conn.close()

    if args.json:
        print(json.dumps({
            "counts": counts,
            "no_transcript": no_transcript,
            "ready_for_konspekt": ready,
        }, ensure_ascii=False, indent=2))
        return

    print(f"Без транскрипта — пропускаем ({len(no_transcript)}):")
    for p in no_transcript:
        print("  -", rel(p))
    print(f"Готово к конспекту ({len(ready)}):")
    for p in ready:
        print("  -", rel(p))
    order = ["new", "transcribed", "done", "deleted"]
    print("Статусы: " + ", ".join(f"{s}={counts.get(s, 0)}" for s in order))


def cmd_mark(args):
    conn = connect()
    path = os.path.abspath(args.file)
    if args.status not in STATUSES:
        print(f"неверный статус: {args.status}", file=sys.stderr)
        sys.exit(2)
    row = conn.execute("SELECT * FROM files WHERE path=?", (path,)).fetchone()
    if row is None:
        st = os.stat(path) if os.path.exists(path) else None
        conn.execute(
            "INSERT INTO files(path,day,filename,size_bytes,mtime,status) VALUES(?,?,?,?,?,?)",
            (path,
             os.path.basename(os.path.dirname(path)),
             os.path.basename(path),
             st.st_size if st else None,
             int(st.st_mtime) if st else None,
             args.status))
        row = conn.execute("SELECT * FROM files WHERE path=?", (path,)).fetchone()

    sets, params = ["status=?"], [args.status]
    if args.status == "transcribed" and not row["transcribed_at"]:
        sets.append("transcribed_at=?")
        params.append(now())
    if args.status == "done":
        if not row["transcribed_at"]:
            sets.append("transcribed_at=?")
            params.append(now())
        sets.append("summarized_at=?")
        params.append(now())
    if args.konspekt:
        sets.append("konspekt_path=?")
        params.append(args.konspekt)
    if args.obsidian:
        sets.append("obsidian_path=?")
        params.append(args.obsidian)
    params.append(row["id"])
    conn.execute("UPDATE files SET " + ",".join(sets) + " WHERE id=?", params)
    conn.commit()
    conn.close()
    print(f"mark: {rel(path)} -> {args.status}")


def cmd_status(args):
    conn = connect()
    counts = {r["status"]: r["n"] for r in
              conn.execute("SELECT status, COUNT(*) AS n FROM files GROUP BY status")}
    total = sum(counts.values())
    print(f"Всего записей: {total}")
    for s in STATUSES:
        print(f"  {s:<12} {counts.get(s, 0)}")
    print("\nПоследние конспекты:")
    for r in conn.execute(
            "SELECT path, summarized_at FROM files WHERE status='done' "
            "ORDER BY summarized_at DESC LIMIT 10"):
        print(f"  {r['summarized_at'] or '?':<20} {rel(r['path'])}")
    conn.close()


def main():
    ap = argparse.ArgumentParser(description="Состояние обработки Zoom-записей (SQLite)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("sync", help="сверить БД с файлами (не транскрибирует)")

    p_pending = sub.add_parser("pending", help="что осталось сделать")
    p_pending.add_argument("--json", action="store_true", help="вывод в JSON")

    p_mark = sub.add_parser("mark", help="проставить статус файлу")
    p_mark.add_argument("file")
    p_mark.add_argument("status", choices=STATUSES)
    p_mark.add_argument("--konspekt", default=None)
    p_mark.add_argument("--obsidian", default=None)

    sub.add_parser("status", help="сводка по статусам")

    args = ap.parse_args()
    {"sync": cmd_sync, "pending": cmd_pending,
     "mark": cmd_mark, "status": cmd_status}[args.cmd](args)


if __name__ == "__main__":
    main()
