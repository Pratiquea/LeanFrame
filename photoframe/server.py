# photoframe/server.py
from fastapi import FastAPI, UploadFile, File, Header, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
import shutil
from typing import Any, Dict, Callable, List
import yaml
import threading
from .config import AppCfg

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

# ---------- Runtime Config API ----------
# Shapes we expose:
# {
#   "render": {
#     "mode": "cover" | "contain",
#     "padding": {
#       "style": "blur" | "glass" | "solid" | ... (other known styles ok),
#       "color": "#RRGGBB",
#       "blur_amount": float >= 0
#     }
#   },
#   "playback": {
#     "slide_duration_s": float,
#     "shuffle": bool,
#     "loop": bool,
#     "crossfade_ms": int
#   }
# }

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

@app.get("/config/runtime")
async def get_runtime():
    data = _load_yaml()
    render = data.get("render", {})
    pad = render.get("padding", {})
    pb = data.get("playback", {})

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
            # keep compatibility: we accept/write both new+legacy keys on disk
            "slide_duration_s": float(pb.get("slide_duration_s", pb.get("default_image_seconds", 12.0))),
            "shuffle": bool(pb.get("shuffle", False)),
            "loop": bool(pb.get("loop", True)),
            "crossfade_ms": int(pb.get("crossfade_ms", pb.get("transition_crossfade_ms", 300))),
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

        pb = payload.get("playback", {})
        slide_duration_s = float(pb.get("slide_duration_s", 12.0))
        if slide_duration_s <= 0:
            raise ValueError("playback.slide_duration_s must be > 0")

        shuffle = bool(pb.get("shuffle", False))
        loop = bool(pb.get("loop", True))
        crossfade_ms = int(pb.get("crossfade_ms", 300))
        if crossfade_ms < 0:
            raise ValueError("playback.crossfade_ms must be >= 0")
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))

    # --------- Persist to YAML (preserve other keys) ----------
    data = _load_yaml()

    data.setdefault("render", {})
    data["render"]["mode"] = mode
    data["render"].setdefault("padding", {})
    data["render"]["padding"]["style"] = style
    data["render"]["padding"]["color"] = color
    data["render"]["padding"]["blur_amount"] = blur_amount

    data.setdefault("playback", {})
    # keep legacy on disk for backward compatibility
    data["playback"]["slide_duration_s"] = slide_duration_s
    data["playback"]["default_image_seconds"] = slide_duration_s
    data["playback"]["crossfade_ms"] = crossfade_ms
    data["playback"]["transition_crossfade_ms"] = crossfade_ms
    data["playback"]["shuffle"] = shuffle
    data["playback"]["loop"] = loop

    _save_yaml(data)

    # --------- Publish to subscribers (dynamic reconfigure) ----------
    runtime_bus.publish({
        "render": {
            "mode": mode,
            "padding": {"style": style, "color": color, "blur_amount": blur_amount},
        },
        "playback": {
            "slide_duration_s": slide_duration_s,
            "shuffle": shuffle,
            "loop": loop,
            "crossfade_ms": crossfade_ms,
        },
    })

    return JSONResponse({"ok": True})