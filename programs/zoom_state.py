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
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta

ROOT = r"D:\video_cast\zoom"
DB_PATH = os.path.join(ROOT, "state.db")
MEDIA_EXTS = {".m4a", ".webm", ".mp4", ".mp3", ".wav", ".ogg", ".m4b"}
STATUSES = ("new", "transcribed", "done", "ignored", "deleted")

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
    cols = {d[1] for d in conn.execute("PRAGMA table_info(files)")}
    if "duration_s" not in cols:
        conn.execute("ALTER TABLE files ADD COLUMN duration_s REAL")
    if "session_id" not in cols:
        conn.execute("ALTER TABLE files ADD COLUMN session_id INTEGER")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            day            TEXT,
            label          TEXT,
            konspekt_path  TEXT,
            obsidian_path  TEXT
        )
        """
    )
    return conn


def get_duration(path):
    """Реальная длительность файла (ffprobe), секунды."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=60)
        return float(out.stdout.strip()) if out.stdout.strip() else None
    except Exception:
        return None


def parse_start(filename):
    """Начало записи из имени Zoom_ГГГГММДД_ЧЧММСС.m4a -> datetime."""
    m = re.search(r"_(\d{8})_(\d{6})", filename)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
    except ValueError:
        return None


def derive_status(media_path, session_konspekt=None):
    """Статус по файлам рядом с аудио (или по конспекту сессии). (status, konspekt_path)."""
    base = os.path.splitext(media_path)[0]
    konspekt = base + "_конспект.md"
    if os.path.exists(konspekt):
        return "done", konspekt
    if session_konspekt and os.path.exists(session_konspekt):
        return "done", session_konspekt
    if os.path.exists(base + ".txt") or os.path.exists(base + ".srt"):
        return "transcribed", None
    return "new", None


def session_konspekt(conn, session_id):
    """Путь к конспекту сессии (или None)."""
    if not session_id:
        return None
    row = conn.execute("SELECT konspekt_path FROM sessions WHERE id=?", (session_id,)).fetchone()
    return row["konspekt_path"] if row else None


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
        row = conn.execute("SELECT * FROM files WHERE path=?", (path,)).fetchone()
        sk = session_konspekt(conn, row["session_id"]) if row else None
        derived, konspekt = derive_status(path, sk)

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

        if row["status"] == "ignored":
            # помеченные "не обрабатывать" не трогаем, кроме size/mtime
            if row["size_bytes"] != size or row["mtime"] != mtime:
                conn.execute("UPDATE files SET size_bytes=?,mtime=? WHERE id=?",
                             (size, mtime, row["id"]))
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

    # группируем готовые к конспекту по сессии (одна сессия = один конспект)
    by_session = {}
    singles = []
    for r in rows:
        if r["status"] != "transcribed":
            continue
        if r["session_id"]:
            by_session.setdefault(r["session_id"], []).append(r)
        else:
            singles.append(r)

    def _start(rows_):
        st = parse_start(rows_[0]["filename"])
        return st.strftime("%H:%M") if st else rows_[0]["filename"]

    ready = []
    for sid, members in by_session.items():
        s = conn.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        ready.append({
            "session_id": sid,
            "day": members[0]["day"],
            "start": _start(members),
            "duration_s": sum(m["duration_s"] or 0 for m in members),
            "files": [m["path"] for m in members],
        })
    for r in singles:
        ready.append({
            "session_id": None,
            "day": r["day"],
            "start": _start([r]),
            "duration_s": r["duration_s"],
            "files": [r["path"]],
        })

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
    for g in ready:
        if g["session_id"]:
            print(f"  * [сессия #{g['session_id']}] {g['day']} {g['start']} "
                  f"({len(g['files'])} файлов, {g['duration_s']} с)")
            for f in g["files"]:
                print(f"      - {rel(f)}")
        else:
            print(f"  - {rel(g['files'][0])}")
    order = ["new", "transcribed", "done", "ignored", "deleted"]
    print("Статусы: " + ", ".join(f"{s}={counts.get(s, 0)}" for s in order))


def cmd_session_auto(args):
    conn = connect()
    gap = args.gap
    # все файлы (кроме удалённых), с разобранным временем начала
    rows = conn.execute(
        "SELECT * FROM files WHERE status != 'deleted' ORDER BY day, filename").fetchall()
    by_day = {}
    for r in rows:
        st = parse_start(r["filename"])
        if st is None:
            continue
        by_day.setdefault(r["day"], []).append((r, st))

    proposals = []
    for day, items in by_day.items():
        items.sort(key=lambda x: x[1])
        cur = [items[0]]
        groups = []
        for r, st in items[1:]:
            pr, pst = cur[-1]
            if pr["duration_s"] is None:
                d = get_duration(pr["path"])
                conn.execute("UPDATE files SET duration_s=? WHERE id=?", (d, pr["id"]))
                pr = conn.execute("SELECT * FROM files WHERE id=?", (pr["id"],)).fetchone()
                cur[-1] = (pr, pst)
            prev_end = pst + timedelta(seconds=(pr["duration_s"] or 0))
            if (st - prev_end).total_seconds() <= gap:
                cur.append((r, st))
            else:
                groups.append(cur)
                cur = [(r, st)]
        groups.append(cur)
        for g in groups:
            if len(g) > 1:
                proposals.append({"day": day, "files": [x[0]["path"] for x in g]})
    conn.commit()

    if args.apply:
        days = {p["day"] for p in proposals}
        for day in days:
            conn.execute("UPDATE files SET session_id=NULL WHERE day=?", (day,))
            conn.execute("DELETE FROM sessions WHERE day=?", (day,))
        for p in proposals:
            cur = conn.execute(
                "INSERT INTO sessions(day,label) VALUES(?,?)",
                (p["day"], os.path.basename(p["files"][0]))).lastrowid
            for f in p["files"]:
                conn.execute("UPDATE files SET session_id=? WHERE path=?", (cur, f))
        conn.commit()
        print(f"session auto: применено {len(proposals)} сессий")
    else:
        for p in proposals:
            print(f"  [{p['day']}] " + " | ".join(os.path.basename(f) for f in p["files"]))
        print(f"session auto: {len(proposals)} предложений (для применения добавьте --apply)")
    conn.close()


def cmd_session_merge(args):
    conn = connect()
    paths = [os.path.abspath(f) for f in args.files]
    ph = ",".join("?" * len(paths))
    rows = conn.execute(f"SELECT * FROM files WHERE path IN ({ph})", paths).fetchall()
    if len(rows) != len(paths):
        missing = set(paths) - {r["path"] for r in rows}
        print(f"не найдены в БД: {missing}", file=sys.stderr)
        sys.exit(2)
    day = rows[0]["day"]
    cur = conn.execute("INSERT INTO sessions(day,label) VALUES(?,?)",
                       (day, os.path.basename(rows[0]["path"]))).lastrowid
    for r in rows:
        conn.execute("UPDATE files SET session_id=? WHERE id=?", (cur, r["id"]))
    conn.commit()
    conn.close()
    print(f"session merge: {len(rows)} файлов -> сессия #{cur}")


def cmd_session_split(args):
    conn = connect()
    path = os.path.abspath(args.file)
    r = conn.execute("SELECT * FROM files WHERE path=?", (path,)).fetchone()
    if r is None:
        print("не найдено в БД", file=sys.stderr)
        sys.exit(2)
    sid = r["session_id"]
    conn.execute("UPDATE files SET session_id=NULL WHERE id=?", (r["id"],))
    if sid is not None:
        cnt = conn.execute("SELECT COUNT(*) n FROM files WHERE session_id=?",
                           (sid,)).fetchone()["n"]
        if cnt < 2:
            conn.execute("DELETE FROM sessions WHERE id=?", (sid,))
    conn.commit()
    conn.close()
    print(f"session split: {rel(path)} отсоединён (сессия {sid if sid else '-'})")


def cmd_session_list(args):
    conn = connect()
    sessions = conn.execute("SELECT * FROM sessions ORDER BY day, id").fetchall()
    out = []
    for s in sessions:
        files = conn.execute(
            "SELECT path,status FROM files WHERE session_id=? ORDER BY filename",
            (s["id"],)).fetchall()
        out.append({
            "id": s["id"], "day": s["day"], "label": s["label"],
            "konspekt": s["konspekt_path"], "files": [f["path"] for f in files],
            "statuses": [f["status"] for f in files],
        })
    conn.close()
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    if not out:
        print("Сессий нет")
        return
    for o in out:
        print(f"#{o['id']} [{o['day']}] {o['label']} "
              f"({len(o['files'])} файлов) статусы={o['statuses']}")
        for f in o["files"]:
            print(f"      - {rel(f)}")


def cmd_session_done(args):
    conn = connect()
    s = conn.execute("SELECT * FROM sessions WHERE id=?", (args.id,)).fetchone()
    if s is None:
        print("сессия не найдена", file=sys.stderr)
        sys.exit(2)
    members = conn.execute("SELECT * FROM files WHERE session_id=?",
                           (args.id,)).fetchall()
    ts = now()
    for f in members:
        conn.execute(
            "UPDATE files SET status='done', transcribed_at=COALESCE(transcribed_at,?),"
            "summarized_at=?, konspekt_path=?, obsidian_path=? WHERE id=?",
            (ts, ts, args.konspekt, args.obsidian, f["id"]))
    conn.execute("UPDATE sessions SET konspekt_path=?, obsidian_path=? WHERE id=?",
                 (args.konspekt, args.obsidian, args.id))
    conn.commit()
    conn.close()
    print(f"session {args.id} -> done ({len(members)} файлов)")


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

    p_sess = sub.add_parser("session", help="управление сессиями (объединение встреч)")
    ssub = p_sess.add_subparsers(dest="sub", required=True)
    p = ssub.add_parser("auto", help="предложить сессии по зазору времени")
    p.add_argument("--gap", type=int, default=30, help="макс. зазор между записями, сек (по умолч. 30)")
    p.add_argument("--apply", action="store_true", help="применить (иначе только показать)")
    p = ssub.add_parser("merge", help="объединить файлы в одну сессию")
    p.add_argument("files", nargs="+")
    p = ssub.add_parser("split", help="отсоединить файл от сессии")
    p.add_argument("file")
    p = ssub.add_parser("list", help="показать сессии")
    p.add_argument("--json", action="store_true")
    p = ssub.add_parser("done", help="пометить все файлы сессии одним конспектом")
    p.add_argument("id", type=int)
    p.add_argument("--konspekt", default=None)
    p.add_argument("--obsidian", default=None)

    args = ap.parse_args()
    if args.cmd == "session":
        {"auto": cmd_session_auto, "merge": cmd_session_merge,
         "split": cmd_session_split, "list": cmd_session_list,
         "done": cmd_session_done}[args.sub](args)
        return
    {"sync": cmd_sync, "pending": cmd_pending,
     "mark": cmd_mark, "status": cmd_status}[args.cmd](args)


if __name__ == "__main__":
    main()
