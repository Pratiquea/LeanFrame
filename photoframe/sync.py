from __future__ import annotations
import subprocess, shlex, time
from pathlib import Path
from typing import Iterable
from .config import AppCfg
from .indexer import Library

class Syncer:
    def __init__(self, cfg: AppCfg, lib: Library):
        self.cfg = cfg
        self.lib = lib
        self.library_root = cfg.paths.library

    def run_all(self):
        s = getattr(self.cfg, "sync", None)
        if not s or not getattr(s, "enabled", False):
            return
        mode = getattr(s, "mode", "off")
        if mode == "rclone":
            self._run_rclone_jobs()
        elif mode == "photos_api":
            self._run_photos_api()
        self.lib.scan_once(
            recursive=self.cfg.indexer.recursive,
            ignore_hidden=self.cfg.indexer.ignore_hidden
        )


    def _run_rclone_jobs(self):
        s = self.cfg.sync
        if not s or not s.rclone or not s.rclone.jobs:
            return
        rc = s.rclone
        for job in rc.jobs:
            dest = self.library_root / job.dest_subdir
            dest.mkdir(parents=True, exist_ok=True)
            filters = []
            if job.include_ext:
                for e in job.include_ext:
                    filters += ["--include", f"*.{e}"]
            cmd = [rc.bin, 'sync' if job.one_way else 'copy', job.remote, str(dest), '--fast-list'] + filters
            try:
                subprocess.run(cmd, check=True)
            except Exception as e:
                print('[sync] rclone job failed', job.name, e)


    def _run_photos_api(self):
        # Minimal stub; we recommend rclone gphotos because it handles video variants & pagination well.
        # You can later extend this with google-photos-library-client to pull by album.
        print('[sync] photos_api mode is not yet implemented in this minimal build. Use rclone gphotos remote.')