from pathlib import Path
import threading
import uvicorn
from .config import AppCfg
from .indexer import Library, start_watcher
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
    lib.scan_once(recursive=cfg.indexer.recursive, ignore_hidden=cfg.indexer.ignore_hidden)

    watch_flag = None
    if cfg.indexer.watch:
        _, watch_flag = start_watcher(cfg.paths.library, recursive=cfg.indexer.recursive)

    # Optional: run one sync before starting viewer
    syncer = Syncer(cfg, lib)
    syncer.run_all()

    def run_server():
        uvicorn.run("photoframe.server:app", host=cfg.server.host, port=cfg.server.port, log_level="warning")

    t = threading.Thread(target=run_server, daemon=True)
    t.start()

    # Start viewer loop (blocking)
    # purge viewer cache
    lib.purge_missing()
    viewer = Viewer(cfg, lib, watch_flag=watch_flag)
    viewer.loop()

if __name__ == "__main__":
    main()
