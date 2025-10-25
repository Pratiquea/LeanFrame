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
        if not self.cfg.sync.enabled:
            return
        mode = self.cfg.sync.mode
        if mode == 'rclone':
            self._run_rclone_jobs()
        elif mode == 'photos_api':
            self._run_photos_api()
        # After any sync, rescan library
        self.lib.scan_once(recursive=self.cfg.indexer.recursive, ignore_hidden=self.cfg.indexer.ignore_hidden)

    def _run_rclone_jobs(self):
        rc = self.cfg.sync.rclone
        for job in rc['jobs']:
            dest = self.library_root / job.get('dest_subdir', 'remote')
            dest.mkdir(parents=True, exist_ok=True)
            remote = job['remote']
            include_ext = job.get('include_ext', [])
            filters = []
            if include_ext:
                for e in include_ext:
                    filters += ["--include", f"*.{e}"]
            cmd = [rc['bin'], 'sync' if job.get('one_way', True) else 'copy', remote, str(dest), '--fast-list'] + filters
            try:
                subprocess.run(cmd, check=True)
            except Exception as e:
                print('[sync] rclone job failed', job.get('name'), e)

    def _run_photos_api(self):
        # Minimal stub; we recommend rclone gphotos because it handles video variants & pagination well.
        # You can later extend this with google-photos-library-client to pull by album.
        print('[sync] photos_api mode is not yet implemented in this minimal build. Use rclone gphotos remote.')