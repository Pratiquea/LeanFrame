import os, json, time, subprocess, random
from pathlib import Path
import pygame
from pygame.locals import FULLSCREEN
from .utils import load_image_cover
from .indexer import Library
from .config import AppCfg
from .constants import SUPPORTED_IMAGES, SUPPORTED_VIDEOS

class Viewer:
    def __init__(self, cfg: AppCfg, lib: Library):
        self.cfg = cfg
        self.lib = lib
        self.state_path = cfg.paths.state
        self.W, self.H = cfg.screen.width, cfg.screen.height
        flags = FULLSCREEN if cfg.screen.fullscreen else 0
        pygame.init()
        self.screen = pygame.display.set_mode((self.W, self.H), flags)
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
            if path.suffix.lower() in SUPPORTED_IMAGES:
                self._show_image(str(path))
                self._save_resume_id(mid)
            else:
                # let external player own the screen
                pygame.display.iconify()
                self._play_video(str(path))
                pygame.display.set_mode((self.W, self.H), FULLSCREEN if self.cfg.screen.fullscreen else 0)
                self._save_resume_id(mid)
            # next
            self.current_id = self.lib.next_id(mid, loop=self.cfg.playback.loop)

    def _show_image(self, path: str):
        target = (self.W, self.H)
        img = load_image_cover(path, target)
        frame = pygame.image.frombuffer(img.tobytes(), img.size, img.mode)
        if self.crossfade_ms > 0:
            self._crossfade(frame)
        else:
            self.screen.blit(frame, (0,0))
            pygame.display.flip()
            self._sleep_with_events(self.cfg.playback.default_image_seconds)

    def _crossfade(self, new_surface: pygame.Surface):
        start = pygame.time.get_ticks()
        snapshot = self.screen.copy()
        while True:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit(); raise SystemExit
            t = pygame.time.get_ticks() - start
            alpha = min(255, int(255 * t / self.crossfade_ms))
            self.screen.blit(snapshot, (0,0))
            new_surface.set_alpha(alpha)
            self.screen.blit(new_surface, (0,0))
            pygame.display.flip()
            self.clock.tick(60)
            if t >= self.crossfade_ms:
                # hold
                self.screen.blit(new_surface, (0,0))
                pygame.display.flip()
                self._sleep_with_events(self.cfg.playback.default_image_seconds)
                break

    def _sleep_with_events(self, seconds: float):
        end = time.time() + seconds
        while time.time() < end:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit(); raise SystemExit
            self.clock.tick(60)