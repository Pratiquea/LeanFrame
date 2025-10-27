import os, json, time, subprocess, random
from pathlib import Path
import pygame
from pygame.locals import FULLSCREEN
from .utils import load_image_surface
from .indexer import Library
from .config import AppCfg
from .constants import SUPPORTED_IMAGES, SUPPORTED_VIDEOS
from .fast_image_loader import FastImageLoader


class Viewer:
    def __init__(self, cfg: AppCfg, lib: Library, watch_flag=None):
        self.cfg = cfg
        self.lib = lib
        self.watch_flag = watch_flag
        self.state_path = cfg.paths.state
        self.W, self.H = cfg.screen.width, cfg.screen.height
        flags = FULLSCREEN if cfg.screen.fullscreen else 0
        pygame.init()
        self.screen = pygame.display.set_mode((self.W, self.H), flags)
        self.loader = FastImageLoader(self.screen.get_size(), self.cfg.render)
        pygame.mouse.set_visible(not cfg.screen.cursor_hidden)
        self.clock = pygame.time.Clock()
        self.crossfade_ms = cfg.playback.crossfade_ms if cfg.playback.transitions_crossfade else 0
        self.current_id = self._load_resume_id() if cfg.playback.resume_on_start else None
        if not self.current_id:
            rows = self.lib.list_ids()
            self.current_id = rows[0][0] if rows else None

    def _load_resume_id(self):
        try:
            if self.state_path.exists():
                state = json.loads(self.state_path.read_text())
                return state.get("last_id")
        except Exception: pass
        return None

    def _save_resume_id(self, mid: int):
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps({"last_id": mid}))

    def _play_video(self, path: str):
        # Prefer mpv for low CPU and good scaling
        bin = os.environ.get("LEANFRAME_MPV", "mpv")
        try:
            subprocess.run([bin, "--fs", "--no-input-default-bindings", "--really-quiet", path], check=True)
        except Exception:
            # Fallback to ffplay
            subprocess.run(["ffplay", "-autoexit", "-fs", "-hide_banner", "-loglevel", "error", path])

    def loop(self):
        font = pygame.font.SysFont(None, 36)
        while True:
            # If watcher signaled changes, rescan here on the main thread
            if self.watch_flag is not None and self.watch_flag.is_set():
                print("[watchdog] running scan_once on viewer thread ...")
                self.lib.scan_once(recursive=self.cfg.indexer.recursive,
                                   ignore_hidden=self.cfg.indexer.ignore_hidden)
                self.watch_flag.clear()

            row = self.lib.get_by_id(self.current_id) if self.current_id else None
            if not row:
                # draw message
                self.screen.fill((0,0,0))
                msg = font.render("No media found in data/library", True, (200,200,200))
                rect = msg.get_rect(center=(self.W//2, self.H//2))
                self.screen.blit(msg, rect)
                pygame.display.flip()
                # try rescanning occasionally
                self.lib.scan_once(recursive=self.cfg.indexer.recursive, ignore_hidden=self.cfg.indexer.ignore_hidden)
                time.sleep(2)
                rows = self.lib.list_ids()
                self.current_id = rows[0][0] if rows else None
                continue
                time.sleep(1); continue
            mid, path, kind = row
            print(f"[viewer] showing id={mid} kind={kind} path={path}")
            path = Path(path)
            try:
                if path.suffix.lower() in SUPPORTED_IMAGES:
                    self._show_image(str(path))
                    self._save_resume_id(mid)
                else:
                    # let external player own the screen
                    pygame.display.iconify()
                    self._play_video(str(path))
                    pygame.display.set_mode((self.W, self.H), FULLSCREEN if self.cfg.screen.fullscreen else 0)
                    self._save_resume_id(mid)
            except FileNotFoundError:
                print(f"[viewer] missing; removing from DB and skipping: {path}")
                # remove stale row and continue
                self.lib.delete_id(mid)
                # try the next id immediately
                self.current_id = self.lib.next_id(mid, loop=self.cfg.playback.loop)
                continue
            # next
            self.current_id = self.lib.next_id(mid, loop=self.cfg.playback.loop)

    def _show_image(self, path: str):
        """
        Render using FastImageLoader:
          - Decodes directly to screen size (low CPU/RAM)
          - Applies EXIF orientation
          - Uses libjpeg-turbo DCT scaling for JPEGs if available
          - Centers image (letterboxed if aspect differs)
        """
        frame = self.loader.load_surface(path)
        # center the image; it may be smaller than screen if aspect ratio differs
        dst_rect = frame.get_rect(center=(self.W//2, self.H//2))
        if self.crossfade_ms > 0:
            self._crossfade(frame, dst_rect)
        else:
            self.screen.fill((0,0,0))
            self.screen.blit(frame, dst_rect.topleft)
            pygame.display.flip()
            self._sleep_with_events(self.cfg.playback.default_image_seconds)

    def _crossfade(self, new_surface: pygame.Surface, dst_rect: pygame.Rect):
        start = pygame.time.get_ticks()
        snapshot = self.screen.copy()
        while True:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit(); raise SystemExit
            t = pygame.time.get_ticks() - start
            alpha = min(255, int(255 * t / self.crossfade_ms))
            # draw previous frame snapshot as background
            self.screen.blit(snapshot, (0,0))
            # crossfade the centered image
            new_surface.set_alpha(alpha)
            self.screen.blit(new_surface, dst_rect.topleft)
            pygame.display.flip()
            self.clock.tick(60)
            if t >= self.crossfade_ms:
                # hold
                self.screen.fill((0,0,0))
                self.screen.blit(new_surface, dst_rect.topleft)
                pygame.display.flip()
                self._sleep_with_events(self.cfg.playback.default_image_seconds)
                break

    def _preload_neighbors(self, current_id: int):
        """
        Builds a tiny [prev, curr, next] list of image paths around current_id
        and asks the loader to warm prev/next in background.
        """
        rows = self.lib.list_ids() #[(id, path, kind), ...] or [(id.), ...]
        # Normalize to a list of (id, path, kind)
        norm = []
        for r in rows:
            if len(r) == 3:
                norm.append(r)
            else:
                mid = r[0]
                row = self.lib.get_by_id(mid)
                if row:
                    norm.append(row)
        if not norm:
            return

        ids = [r[0] for r in norm]
        try:
            i = ids.index(current_id)
        except ValueError:
            return
        
        n = len(norm)
        prev_i = (i-1) % n
        next_i = (i+1) % n

        # Only keep image paths (skip video preloading)
        def img_path(t):
            _id, _p, _k = t
            return str(_p) if Path(_p).suffix.lower() in SUPPORTED_IMAGES else None
        
        prev_p = img_path(norm[prev_i])
        curr_p = img_path(norm[i])
        next_p = img_path(norm[next_i])
        paths = [p for p in [prev_p, curr_p, next_p] if p]
        if paths and len(paths) >= 2:
            # idx=position of current within the paths list
            idx = paths.index(curr_p) if curr_p in paths else 0
            self.loader.preload_neighbors(paths, idx)


    def _sleep_with_events(self, seconds: float):
        end = time.time() + seconds
        while time.time() < end:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit(); raise SystemExit
            self.clock.tick(60)
