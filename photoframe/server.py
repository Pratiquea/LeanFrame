# photoframe/server.py
from fastapi import FastAPI, UploadFile, File, Header, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
import shutil

from .config import AppCfg

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
