DB_SCHEMA = """
CREATE TABLE IF NOT EXISTS media (
id INTEGER PRIMARY KEY AUTOINCREMENT,
path TEXT NOT NULL UNIQUE,
kind TEXT NOT NULL CHECK(kind IN ('image','video')),
width INT, height INT,
duration REAL, -- for video if known
mtime REAL NOT NULL,
etag TEXT
);
CREATE INDEX IF NOT EXISTS idx_media_kind ON media(kind);
"""


# Extended image formats including iPhone and Android common formats
SUPPORTED_IMAGES = {
".jpg", ".jpeg", ".png", ".webp", ".bmp", ".heic", ".heif",
".dng", ".cr2", ".arw", ".nef", ".rw2", ".orf", ".raf", ".srw",
".tiff", ".tif", ".avif", ".proraw"
}


# Common video formats supported by phones and cameras
SUPPORTED_VIDEOS = {
".mp4", ".mov", ".mkv", ".avi", ".3gp", ".m4v", ".webm"
}