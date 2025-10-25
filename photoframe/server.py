from fastapi import FastAPI, UploadFile, File, Header, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
import shutil, os
from .config import AppCfg

app = FastAPI(title="LeanFrame Server")
cfg: AppCfg | None = None

@app.on_event("startup")
async def startup():
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

async def auth(x_auth_token: str | None = Header(default=None)):
    if not x_auth_token or x_auth_token != cfg.server.auth_token:
        raise HTTPException(status_code=401, detail="Unauthorized")

@app.post("/upload", dependencies=[Depends(auth)])
async def upload(file: UploadFile = File(...)):
    ext = Path(file.filename).suffix.lower().lstrip('.')
    if cfg.server.allow_extensions and ext not in cfg.server.allow_extensions:
        raise HTTPException(400, f"Extension .{ext} not allowed")
    tmp = cfg.paths.import_dir
    tmp.mkdir(parents=True, exist_ok=True)
    dest_tmp = tmp / (file.filename + ".part")
    with dest_tmp.open('wb') as out:
        while True:
            chunk = await file.read(1024*1024)
            if not chunk: break
            out.write(chunk)
    # atomic move into library
    lib = cfg.paths.library
    (lib / ("images" if ext in {"jpg","jpeg","png","webp","bmp"} else "videos")).mkdir(parents=True, exist_ok=True)
    final = lib / ("images" if ext in {"jpg","jpeg","png","webp","bmp"} else "videos") / file.filename
    shutil.move(str(dest_tmp), str(final))
    return JSONResponse({"ok": True, "path": str(final)})