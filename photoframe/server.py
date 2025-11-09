# photoframe/server.py
from fastapi import FastAPI, UploadFile, File, Header, HTTPException, Depends
from fastapi.responses import JSONResponse, FileResponse 
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
import shutil
from typing import Any, Dict, Callable, List
import yaml
import threading
from .config import AppCfg
from fastapi import Path as FPath
from fastapi.responses import Response
from typing import Optional
from io import BytesIO
import json
import os
import mimetypes
import math
from datetime import datetime
from PIL import Image, ImageDraw, ExifTags
from urllib.parse import quote, unquote
import hashlib

_IMG_EXT = { "jpg","jpeg","png","webp","bmp","heic","heif","dng","tif","tiff","avif" }
_VID_EXT = { "mp4","mov","m4v","avi","mkv","webm","hevc","heif","heifv" }  # extend as you like

_LIB_REV = 1
_REV_LOCK = threading.RLock()

def _bump_rev():
    global _LIB_REV
    with _REV_LOCK:
        _LIB_REV += 1


def _lib_root() -> Path:
    assert cfg and cfg.paths and cfg.paths.library, "cfg.paths.library not set"
    return Path(cfg.paths.library)

def _images_dir() -> Path:
    return _lib_root() / "images"

def _videos_dir() -> Path:
    return _lib_root() / "videos"

def _is_image(p: Path) -> bool:
    return p.suffix.lower().lstrip(".") in _IMG_EXT

def _is_video(p: Path) -> bool:
    return p.suffix.lower().lstrip(".") in _VID_EXT

def _iter_media() -> list[Path]:
    items: list[Path] = []
    for base in (_images_dir(), _videos_dir()):
        if not base.exists():
            continue
        for r, _, files in os.walk(base):
            for f in files:
                p = Path(r) / f
                # only known media
                if _is_image(p) or _is_video(p):
                    items.append(p)
    return items

def _id_from_path(p: Path) -> str:
    # Stable, URL-safe id relative to library root (posix style)
    rel = p.relative_to(_lib_root()).as_posix()
    # keep it readable; only quote unsafe chars
    return quote(rel, safe="/-._~")

def _path_from_id(item_id: str) -> Path:
    # Prevent traversal
    rel = Path(unquote(item_id))
    if rel.is_absolute() or ".." in rel.parts:
        raise HTTPException(400, "invalid id")
    p = _lib_root() / rel
    try:
        p.resolve().relative_to(_lib_root().resolve())
    except Exception:
        raise HTTPException(400, "invalid id")
    if not p.exists() or not p.is_file():
        raise HTTPException(404, "not found")
    return p

_META_PATH = lambda: _lib_root() / ".meta.json"
_META_LOCK = threading.RLock()

def _load_meta() -> dict:
    with _META_LOCK:
        p = _META_PATH()
        if not p.exists():
            return {}
        try:
            return json.loads(p.read_text())
        except Exception:
            return {}

def _save_meta(d: dict) -> None:
    with _META_LOCK:
        p = _META_PATH()
        p.write_text(json.dumps(d, indent=2, sort_keys=True))

_EXIF_TAGS = {v: k for k, v in ExifTags.TAGS.items()}
def _image_meta_from_exif(p: Path) -> dict:
    """Best-effort EXIF parse: date, gps lat/lon."""
    out: dict = {}
    try:
        with Image.open(p) as im:
            exif = im.getexif()
            if exif:
                # Date
                dt_key = _EXIF_TAGS.get('DateTimeOriginal') or _EXIF_TAGS.get('DateTime')
                if dt_key and exif.get(dt_key):
                    raw = str(exif.get(dt_key))
                    # "YYYY:MM:DD HH:MM:SS" → ISO-ish
                    try:
                        d = datetime.strptime(raw, "%Y:%m:%d %H:%M:%S")
                        out["date_taken"] = d.isoformat()
                    except Exception:
                        out["date_taken"] = raw
                # GPS
                gps_key = _EXIF_TAGS.get('GPSInfo')
                if gps_key and exif.get(gps_key):
                    gps = exif.get(gps_key)
                    def _to_deg(rat, ref):
                        if not rat or len(rat) < 3: return None
                        def num(v): return float(v[0]) / float(v[1]) if isinstance(v, tuple) else float(v)
                        deg = num(rat[0]) + num(rat[1]) / 60.0 + num(rat[2]) / 3600.0
                        if ref in ("S", "W"): deg *= -1.0
                        return deg
                    lat = _to_deg(gps.get(2), gps.get(1))
                    lon = _to_deg(gps.get(4), gps.get(3))
                    if lat is not None and lon is not None:
                        out["gps"] = {"lat": lat, "lon": lon}
    except Exception:
        pass
    return out

def _file_size(p: Path) -> int:
    try:
        return p.stat().st_size
    except Exception:
        return 0


# Helpers to locate YAML
def _cfg_yaml_path() -> Path:
    # Prefer cfg.paths.config/leanframe.yaml if available; else fallback to ./config/leanframe.yaml
    if cfg and hasattr(cfg, "paths") and hasattr(cfg.paths, "config"):
        return Path(cfg.paths.config) / "leanframe.yaml"
    return Path("config/leanframe.yaml")

def _load_yaml() -> Dict[str, Any]:
    p = _cfg_yaml_path()
    if not p.exists():
        return {}
    return yaml.safe_load(p.read_text()) or {}

def _save_yaml(data: Dict[str, Any]) -> None:
    p = _cfg_yaml_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(yaml.safe_dump(data, sort_keys=False))

# In-process pub/sub (dynamic reconfigure)
class RuntimeBus:
    def __init__(self) -> None:
        self._subs: List[Callable[[Dict[str, Any]], None]] = []
        self._lock = threading.RLock()

    def subscribe(self, cb: Callable[[Dict[str, Any]], None]) -> None:
        with self._lock:
            self._subs.append(cb)

    def publish(self, payload: Dict[str, Any]) -> None:
        with self._lock:
            subs = list(self._subs)
        for cb in subs:
            try:
                cb(payload)
            except Exception:
                pass

runtime_bus = RuntimeBus()

app = FastAPI(title="LeanFrame Server")

# ADD CORS MIDDLEWARE AT IMPORT TIME (before startup)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global cfg injected by __main__.py
cfg: AppCfg | None = None

async def auth(x_auth_token: str | None = Header(default=None)):
    if not x_auth_token or not cfg or x_auth_token != cfg.server.auth_token:
        raise HTTPException(status_code=401, detail="Unauthorized")

@app.get("/library/rev", dependencies=[Depends(auth)])
async def library_rev():
    with _REV_LOCK:
        return JSONResponse({"rev": _LIB_REV})

@app.get("/config/runtime")
async def get_runtime():
    data = _load_yaml()
    render = data.get("render", {})
    pad = render.get("padding", {})
    pb = data.get("playback", {})
    trans = pb.get("transitions", {}) or {}

    crossfade_ms_val = trans.get("crossfade_ms", pb.get("crossfade_ms", 300))

    out = {
        "render": {
            "mode": render.get("mode", "cover"),
            "padding": {
                "style": pad.get("style", "blur"),
                "color": pad.get("color", "#000000"),
                "blur_amount": float(pad.get("blur_amount", 16.0)),
            },
        },
        "playback": {
            # only support either legacy or alias keys, not both
            "slide_duration_s": float(pb.get("slide_duration_s", 12.0)),
            "shuffle": bool(pb.get("shuffle", False)),
            "loop": bool(pb.get("loop", True)),
            "crossfade_ms": int(crossfade_ms_val),
        },
    }
    return JSONResponse(out)

@app.post("/upload", dependencies=[Depends(auth)])
async def upload(file: UploadFile = File(...)):
    ext = Path(file.filename).suffix.lower().lstrip(".")
    if cfg and cfg.server.allow_extensions and ext not in cfg.server.allow_extensions:
        raise HTTPException(400, f"Extension .{ext} not allowed")

    tmp = cfg.paths.import_dir
    tmp.mkdir(parents=True, exist_ok=True)
    dest_tmp = tmp / (file.filename + ".part")
    with dest_tmp.open("wb") as out:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)

    lib = cfg.paths.library
    img_exts = {"jpg","jpeg","png","webp","bmp","heic","heif","dng","tif","tiff","avif"}
    sub = "images" if ext in img_exts else "videos"
    (lib / sub).mkdir(parents=True, exist_ok=True)
    final = lib / sub / file.filename
    shutil.move(str(dest_tmp), str(final))
    _bump_rev()  # bump library revision
    return JSONResponse({"ok": True, "path": str(final)})

@app.put("/config/runtime", dependencies=[Depends(auth)])
async def put_runtime(payload: Dict[str, Any]):
    # --------- Validator ----------
    try:
        render = payload.get("render", {})
        mode = str(render.get("mode", "cover")).lower()
        if mode not in ("cover", "contain"):
            raise ValueError("render.mode must be 'cover' or 'contain'")

        pad = render.get("padding", {})
        style = str(pad.get("style", "blur")).lower()
        # Allow all the styles you support in fast_image_loader:
        allowed_styles = {
            "solid", "blur", "average", "mirror", "stretch",
            "gradient_linear", "gradient_radial", "glass",
            "motion", "texture", "dim",
        }
        if style not in allowed_styles:
            raise ValueError(f"render.padding.style must be one of {sorted(allowed_styles)}")


        color = pad.get("color", "#000000")
        if not isinstance(color, str) or not color.startswith("#") or len(color.lstrip("#")) not in (3, 6):
            raise ValueError("render.padding.color must be '#RGB' or '#RRGGBB'")

        blur_amount = float(pad.get("blur_amount", 16.0))
        if blur_amount < 0 or blur_amount > 1000:
            raise ValueError("render.padding.blur_amount must be between 0 and 1000")

        pb_req = payload.get("playback", {}) or {}

        # Validation (unchanged logic; still allow omitting keys)
        slide_duration_s = float(pb_req.get("slide_duration_s", 12.0))
        if slide_duration_s <= 0:
            raise HTTPException(400, "playback.slide_duration_s must be > 0")

        shuffle = bool(pb_req.get("shuffle", False))
        loop = bool(pb_req.get("loop", True))

        # Accept crossfade_ms from request if present; default only for publishing/response
        crossfade_ms = pb_req.get("crossfade_ms", 300)
        try:
            crossfade_ms = int(crossfade_ms)
        except Exception:
            raise HTTPException(400, "playback.crossfade_ms must be an integer")
        if crossfade_ms < 0:
            raise HTTPException(400, "playback.crossfade_ms must be >= 0")
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))

    # --------- Persist to YAML (preserve other keys) ----------
    data = _load_yaml()
    pb_yaml = data.setdefault("playback", {})
    trans_yaml = pb_yaml.setdefault("transitions", {})

    # Only write keys that were actually present in the request
    if "slide_duration_s" in pb_req:
        pb_yaml["slide_duration_s"] = slide_duration_s
    if "shuffle" in pb_req:
        pb_yaml["shuffle"] = shuffle
    if "loop" in pb_req:
        pb_yaml["loop"] = loop
    if "crossfade_ms" in pb_req:
        trans_yaml["crossfade_ms"] = crossfade_ms
        # Clean up legacy flat key if it exists
        if "crossfade_ms" in pb_yaml:
            del pb_yaml["crossfade_ms"]

    _save_yaml(data)

    # --- Publish to subscribers (keep API/IPC flat for the running app) ---
    pb_out = {}
    if "slide_duration_s" in pb_req: pb_out["slide_duration_s"] = slide_duration_s
    if "shuffle" in pb_req:          pb_out["shuffle"] = shuffle
    if "loop" in pb_req:             pb_out["loop"] = loop
    if "crossfade_ms" in pb_req:     pb_out["crossfade_ms"] = crossfade_ms

    runtime_bus.publish({
        "render": {
            "mode": mode,
            "padding": {"style": style, "color": color, "blur_amount": blur_amount},
        },
        "playback": pb_out,  # still flat for live viewers
    })

    return JSONResponse({"ok": True})

@app.get("/stats/storage", dependencies=[Depends(auth)])
async def stats_storage():
    root = _lib_root()
    root.mkdir(parents=True, exist_ok=True)
    # Filesystem totals
    du = shutil.disk_usage(str(root))
    total = int(du.total)
    used_fs = int(du.used)

    # App library breakdown by summing file sizes
    images_bytes = 0
    videos_bytes = 0
    for p in _iter_media():
        if _is_image(p):
            images_bytes += _file_size(p)
        elif _is_video(p):
            videos_bytes += _file_size(p)
    # "Other" = everything else used on the FS minus media we know about
    other_bytes = max(0, used_fs - images_bytes - videos_bytes)

    return JSONResponse({
        "total_bytes": total,
        "used_bytes": used_fs,
        "images_bytes": images_bytes,
        "videos_bytes": videos_bytes,
        "other_bytes": other_bytes,
    })

@app.get("/library", dependencies=[Depends(auth)])
async def list_library():
    meta = _load_meta()
    items = []
    for p in _iter_media():
        item = {
            "id": _id_from_path(p),
            "kind": "image" if _is_image(p) else "video",
            "bytes": _file_size(p),
        }
        # attach flags if exist
        if item["id"] in meta:
            item["flags"] = meta[item["id"]]
        items.append(item)
    # newest last modified first 
    items.sort(key=lambda x: (_lib_root() / unquote(x["id"])).stat().st_mtime if (_lib_root() / unquote(x["id"])).exists() else 0, reverse=True)

    # ETag from rev (fast) or from hash of ids (slower but precise)
    with _REV_LOCK:
        etag = f'W/"librev-{_LIB_REV}"'
    resp = Response(
        content=json.dumps({"items": items}),
        media_type="application/json",
    )
    resp.headers["ETag"] = etag

    return JSONResponse({ "items": items })

def _thumb_for_image(p: Path, max_w: int) -> bytes:
    with Image.open(p) as im:
        im = im.convert("RGB")
        # simple contain resize
        w, h = im.size
        if w > max_w:
            new_h = max(1, math.floor(h * (max_w / float(w))))
            im = im.resize((max_w, new_h), Image.LANCZOS)
        buf = BytesIO()
        im.save(buf, format="JPEG", quality=88)
        return buf.getvalue()

def _thumb_for_video_placeholder(p: Path, max_w: int) -> bytes:
    # A soft gray rectangle with a play triangle overlay (no ffmpeg dependency)
    W = max(64, min(720, max_w))
    H = int(W * 9 / 16)
    img = Image.new("RGB", (W, H), (200, 205, 210))
    draw = ImageDraw.Draw(img)
    # play triangle
    s = int(min(W, H) * 0.35)
    cx, cy = W // 2, H // 2
    tri = [(cx - s//3, cy - s//2), (cx - s//3, cy + s//2), (cx + s//2, cy)]
    draw.polygon(tri, fill=(255, 255, 255))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()

@app.get("/media/{item_id:path}", dependencies=[Depends(auth)])
async def get_media(item_id: str = FPath(...)):
    """
    Stream the original file (images/videos).
    """
    p = _path_from_id(item_id)
    mime, _ = mimetypes.guess_type(str(p))
    return FileResponse(str(p), media_type=mime or "application/octet-stream")

@app.get("/thumb/{item_id:path}", dependencies=[Depends(auth)])
async def get_thumb(item_id: str = FPath(..., description="library-relative id"), w: Optional[int] = None):
    max_w = int(w or 360)
    p = _path_from_id(item_id)
    try:
        if _is_image(p):
            data = _thumb_for_image(p, max_w)
            return Response(content=data, media_type="image/jpeg")
        elif _is_video(p):
            data = _thumb_for_video_placeholder(p, max_w)
            return Response(content=data, media_type="image/png")
        else:
            raise HTTPException(415, "unsupported media")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"thumb error: {e}")

@app.get("/library/{item_id:path}", dependencies=[Depends(auth)])
async def get_item_meta(item_id: str = FPath(...)):
    """
    Return metadata + flags for one library item.
    """
    p = _path_from_id(item_id)
    kind = "image" if _is_image(p) else "video" if _is_video(p) else "other"
    meta_file = _load_meta()
    flags = meta_file.get(item_id, {})
    info = {
        "id": item_id,
        "kind": kind,
        "bytes": _file_size(p),
        "mtime": int(p.stat().st_mtime),
        "flags": flags,
        "name": p.name,
        "relpath": p.relative_to(_lib_root()).as_posix(),
    }
    if _is_image(p):
        info.update(_image_meta_from_exif(p))
    return JSONResponse(info)

@app.delete("/library/{item_id:path}", dependencies=[Depends(auth)])
async def delete_item(item_id: str = FPath(...)):
    p = _path_from_id(item_id)
    try:
        p.unlink(missing_ok=False)
    except FileNotFoundError:
        raise HTTPException(404, "not found")
    except Exception as e:
        raise HTTPException(500, f"delete failed: {e}")
    # also prune metadata if present
    meta = _load_meta()
    if item_id in meta:
        del meta[item_id]
        _save_meta(meta)

    _bump_rev()  # bump library revision
    return JSONResponse({"ok": True})

@app.post("/library/{item_id:path}/flags", dependencies=[Depends(auth)])
async def set_flags(item_id: str = FPath(...), payload: Dict[str, Any] = None):
    _ = _path_from_id(item_id)  # validate exists
    payload = payload or {}

    include = payload.get("include")
    # accept old key for backward compatibility
    exclude = payload.get("exclude_from_slideshow")
    if exclude is None:
        exclude = payload.get("exclude_from_shuffle")

    # validate
    if include is not None and not isinstance(include, bool):
        raise HTTPException(400, "include must be boolean")
    if exclude is not None and not isinstance(exclude, bool):
        raise HTTPException(400, "exclude_from_slideshow must be boolean")

    meta = _load_meta()
    rec = meta.get(item_id, {})
    if include is not None:
        rec["include"] = include
    if exclude is not None:
        # store canonically
        rec["exclude_from_slideshow"] = exclude
        # remove legacy key if present
        if "exclude_from_shuffle" in rec:
            del rec["exclude_from_shuffle"]

    meta[item_id] = rec
    _save_meta(meta)
    _bump_rev()
    return JSONResponse({"ok": True, "flags": rec})
