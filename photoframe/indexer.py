from pathlib import Path
import sqlite3, time
from .constants import DB_SCHEMA, SUPPORTED_IMAGES, SUPPORTED_VIDEOS
from .utils import ext, is_hidden
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileSystemEvent
import threading, fnmatch

# Extensions we actually care about (same spirit as SUPPORTED_IMAGES/VIDEOS)
WATCH_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".heic", ".heif",
              ".dng", ".tif", ".tiff", ".avif", ".mp4", ".mov", ".mkv", ".m4v", ".webm"}

# Ignore junk/temp patterns that cause noisy events
IGNORE_GLOBS = [
    ".*",           # hidden files
    "*.part",       # our uploader temp
    "*.tmp", "*.swp", "*~",
]

class Library:
    def __init__(self, db_path: Path, library_root: Path):
        self.db_path = db_path
        self.root = library_root
        self.conn = sqlite3.connect(db_path)
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self.conn.executescript(DB_SCHEMA)

    def close(self):
        self.conn.close()

    def scan_once(self, recursive=True, ignore_hidden=True):
        files = self.root.rglob('*') if recursive else self.root.glob('*')
        for p in files:
            if not p.is_file():
                continue
            if ignore_hidden and is_hidden(p.relative_to(self.root)):
                continue
            e = ext(p)
            kind = 'image' if e in SUPPORTED_IMAGES else 'video' if e in SUPPORTED_VIDEOS else None
            if not kind:
                continue
            mtime = p.stat().st_mtime
            try:
                self.conn.execute(
                    "INSERT OR IGNORE INTO media(path,kind,mtime) VALUES(?,?,?)",
                    (str(p), kind, mtime)
                )
                self.conn.execute(
                    "UPDATE media SET mtime=? WHERE path=? AND mtime<>?",
                    (mtime, str(p), mtime)
                )
            except Exception as e:
                print("index error", p, e)
        self.conn.commit()

    def delete_id(self, mid: int):
        self.conn.execute("DELETE FROM media WHERE id=?", (mid,))
        self.conn.commit()

    def purge_missing(self):
        cur = self.conn.execute("SELECT id, path FROM media")
        to_delete = []
        for mid, path in cur.fetchall():
            if not os.path.exists(path):
                to_delete.append(mid)
        if to_delete:
            self.conn.executemany("DELETE FROM media WHERE id=?", [(m,) for m in to_delete])
            self.conn.commit()
            print(f"[indexer] purged {len(to_delete)} missing files")

    def list_ids(self, kind=None):
        cur = self.conn.cursor()
        if kind:
            cur.execute("SELECT id,path,kind FROM media WHERE kind=? ORDER BY id", (kind,))
        else:
            cur.execute("SELECT id,path,kind FROM media ORDER BY id")
        return cur.fetchall()

    def get_by_id(self, mid: int):
        cur = self.conn.execute("SELECT id,path,kind FROM media WHERE id=?", (mid,))
        return cur.fetchone()

    def next_id(self, mid: int, loop=True):
        cur = self.conn.execute("SELECT id FROM media WHERE id>? ORDER BY id LIMIT 1", (mid,))
        row = cur.fetchone()
        if row:
            return row[0]
        if loop:
            row = self.conn.execute("SELECT id FROM media ORDER BY id LIMIT 1").fetchone()
            return row[0] if row else None
        return None

class _SignalHandler(FileSystemEventHandler):
    """
    Watchdog handler that:
      - ignores directories and temp files
      - only reacts to created/moved/deleted
      - coalesces bursts (debounce)
      - never touches SQLite (just signals via Event)
    """
    def __init__(self, flag: "threading.Event", debounce_s: float = 1.0):
        self.flag = flag
        self.debounce_s = debounce_s
        self._lock = threading.Lock()
        self._scheduled = False
        self._last_burst_log = 0.0

    def on_any_event(self, event: FileSystemEvent):
        # Ignore directory events
        if event.is_directory:
            return

        p = event.src_path
        name = os.path.basename(p)

        # Ignore temp/junk patterns
        for pat in IGNORE_GLOBS:
            if fnmatch.fnmatch(name, pat):
                return

        # Only act on meaningful change types
        if event.event_type not in ("created", "moved", "deleted"):
            # (optional) if you really want modified, uncomment next line
            # if event.event_type == "modified": pass
            return

        # Check extension
        ext = os.path.splitext(name)[1].lower()
        if ext not in WATCH_EXTS:
            return

        # Coalesce bursts: schedule a single flag set per burst
        with self._lock:
            now = time.time()
            # One log line per burst (every debounce window)
            if now - self._last_burst_log >= self.debounce_s:
                print(f"[watchdog] change detected: {event.event_type} {p}")
                self._last_burst_log = now

            if not self._scheduled:
                self._scheduled = True
                # Arm a one-shot timer that sets the flag after debounce window
                t = threading.Timer(self.debounce_s, self._arm_flag)
                t.daemon = True
                t.start()

    def _arm_flag(self):
        try:
            self.flag.set()   # viewer thread will do scan_once()
        finally:
            with self._lock:
                self._scheduled = False


def start_watcher(path: Path, recursive: bool = True):
    """
    Start a background observer and return (observer, event_flag).
    The caller should poll `event_flag.is_set()` from the main/viewer thread,
    run lib.scan_once(), then `event_flag.clear()`.
    """
    flag = threading.Event()
    handler = _SignalHandler(flag, debounce_s=1.0)
    obs = Observer()
    obs.schedule(handler, str(path), recursive=recursive)
    obs.daemon = True
    obs.start()
    print(f"[watchdog] watching {path} (recursive={recursive})")
    return obs, flag