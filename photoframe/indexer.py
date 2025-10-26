from pathlib import Path
import sqlite3, time
from .constants import DB_SCHEMA, SUPPORTED_IMAGES, SUPPORTED_VIDEOS
from .utils import ext, is_hidden
import os

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