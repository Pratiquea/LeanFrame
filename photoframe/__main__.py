from pathlib import Path
import threading
import uvicorn
from .config import AppCfg
from .indexer import Library
from .server import app as fastapi_app
from .viewer import Viewer
from .sync import Syncer

CFG_PATH = Path("config/leanframe.yaml")

# server.cfg is set inside server.startup via global; we inject once before run
import photoframe.server as server_module


def main():
    cfg = AppCfg.load(CFG_PATH)
    server_module.cfg = cfg

    lib = Library(cfg.paths.db, cfg.paths.library)

    # Optional: run one sync before starting viewer
    syncer = Syncer(cfg, lib)
    syncer.run_all()

    def run_server():
        uvicorn.run("photoframe.server:app", host=cfg.server.host, port=cfg.server.port, log_level="warning")

    t = threading.Thread(target=run_server, daemon=True)
    t.start()

    # Start viewer loop (blocking)
    viewer = Viewer(cfg, lib)
    viewer.loop()

if __name__ == "__main__":
    main()