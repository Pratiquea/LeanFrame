from logging import root
import os, json, time, subprocess, random
from pathlib import Path
import pygame
from pygame.locals import FULLSCREEN
# from .utils import load_image_surface
from .indexer import Library
from .config import AppCfg
from .constants import SUPPORTED_IMAGES, SUPPORTED_VIDEOS
from .fast_image_loader import FastImageLoader
from .server import runtime_bus
from urllib.parse import quote


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
        # dynamic reconfigure: subscribe once
        runtime_bus.subscribe(self._on_runtime_update)
        # -------- Flags-aware playlist state --------
        self._meta_cache: dict[str, dict] = {}
        self._meta_mtime: float = 0.0
        self._meta_path = Path(self.cfg.paths.library) / ".meta.json"
        self._playlist: list[tuple[int, str, str]] = []  # [(id, path, kind)]
        self._id_index: dict[int, int] = {}              # id -> index in _playlist
        self._rebuild_playlist()  # build initial playlist using flags

    @staticmethod
    def _id_from_library_path(root: Path, path: Path) -> str:
        rel = os.path.relpath(path, root)
        return quote(rel, safe="/-._~")
    
    # ---- Flags-aware playlist + meta helpers ----
    def _meta_path(self) -> Path:
        """Return path to .meta.json in the configured library."""
        return self.cfg.paths.library / ".meta.json"

    def _load_meta_if_changed(self) -> None:
        """
        Lazy-reload .meta.json if its mtime changed.
        Stores into self._meta_cache as {item_id: {"include": bool?, "exclude_from_shuffle": bool?}, ...}
        """
        try:
            p = self._meta_path()
            if not p.exists():
                if self._meta_cache:
                    self._meta_cache = {}
                self._meta_mtime = 0.0
                return
            m = p.stat().st_mtime
            if m != self._meta_mtime:
                self._meta_cache = json.loads(p.read_text() or "{}")
                self._meta_mtime = m
        except Exception:
            # Keep last good cache on any read/parse error
            pass

    def _eligible_filter(self, rows: list[tuple[int, str, str]]) -> list[tuple[int, str, str]]:
        self._load_meta_if_changed()

        inc_set: set[str] = set()
        exc_set: set[str] = set()
        for item_id, flags in self._meta_cache.items():
            if not isinstance(flags, dict):
                continue
            if flags.get("include") is True:
                inc_set.add(item_id)
            if flags.get("exclude_from_slideshow") is True or flags.get("exclude_from_shuffle") is True:
                exc_set.add(item_id)

        lib_root = Path(self.cfg.paths.library)

        def id_for_path(p_str: str) -> str:
            # exact same id scheme as the server
            p = Path(p_str)
            rel = os.path.relpath(p, lib_root)
            return quote(rel, safe="/-._~")

        # If any includes exist -> whitelist then subtract exclusions
        if inc_set:
            out = []
            for (mid, path, kind) in rows:
                iid = id_for_path(path)
                if iid in inc_set and iid not in exc_set:
                    out.append((mid, path, kind))
            return out

        # Otherwise -> global list minus exclusions
        out = []
        for (mid, path, kind) in rows:
            iid = id_for_path(path)
            if iid in exc_set:
                continue
            out.append((mid, path, kind))
        return out

    def _rebuild_playlist(self) -> None:
        """
        Build self._playlist ([(id, path, kind), ...]) and id->index map
        honoring include / exclude flags and shuffle preference.
        """
        # Pull raw ordered rows from DB
        rows = self.lib.list_ids()  # [(id, path, kind)]
        norm: list[tuple[int, str, str]] = []
        for r in rows:
            if len(r) == 3:
                norm.append((int(r[0]), str(r[1]), str(r[2])))
            else:
                # In case list_ids ever returns [id] form, normalize
                mid = int(r[0])
                rb = self.lib.get_by_id(mid)
                if rb:
                    norm.append((int(rb[0]), str(rb[1]), str(rb[2])))

        # Filter according to flags
        eligible = self._eligible_filter(norm)

        # If shuffle mode is on, randomize *but* keep a stable seed per boot for nice behavior
        if self.cfg.playback.shuffle:
            tmp = eligible[:]
            random.shuffle(tmp)
            self._playlist = tmp
        else:
            self._playlist = eligible

        # Rebuild index map
        self._id_index = {mid: i for i, (mid, _, _) in enumerate(self._playlist)}

        # If current isn't eligible anymore, move to the first eligible
        if self.current_id is not None and self.current_id not in self._id_index:
            self.current_id = self._playlist[0][0] if self._playlist else None

    def _next_play_id(self, after_id: int | None) -> int | None:
        """
        Return the next id to play based on current playlist and loop setting.
        In shuffle mode, walk the shuffled list (no immediate repeats).
        """
        if not self._playlist:
            return None
        if after_id is None:
            return self._playlist[0][0]

        i = self._id_index.get(after_id, None)
        if i is None:
            return self._playlist[0][0]

        j = i + 1
        if j < len(self._playlist):
            return self._playlist[j][0]
        # End reached
        return self._playlist[0][0] if self.cfg.playback.loop else None

    def _row_for_id(self, mid: int | None) -> tuple[int, str, str] | None:
        if mid is None:
            return None
        # Fast path: index lookup then tuple
        i = self._id_index.get(mid)
        if i is not None and 0 <= i < len(self._playlist):
            return self._playlist[i]
        # Fallback to DB (should be rare)
        rb = self.lib.get_by_id(mid)
        if rb:
            return (int(rb[0]), str(rb[1]), str(rb[2]))
        return None


    def _on_runtime_update(self, data: dict) -> None:
        """
        Apply runtime config updates pushed by the API (no restart).
        """
        try:
            r = data.get("render", {})
            p = (r.get("padding") or {})
            # Render
            self.cfg.render.mode = r.get("mode", self.cfg.render.mode)
            if hasattr(self.cfg.render, "padding") and self.cfg.render.padding:
                self.cfg.render.padding.style = p.get("style", self.cfg.render.padding.style)
                if "color" in p:
                    self.cfg.render.padding.color = p["color"]
                if "blur_amount" in p and hasattr(self.cfg.render.padding, "blur_amount"):
                    self.cfg.render.padding.blur_amount = p["blur_amount"]

            # Playback
            pb = data.get("playback", {})
            if "slide_duration_s" in pb:
                self.cfg.playback.slide_duration_s = float(pb["slide_duration_s"])
            if "shuffle" in pb:
                self.cfg.playback.shuffle = bool(pb["shuffle"])
            if "loop" in pb:
                self.cfg.playback.loop = bool(pb["loop"])
            if "crossfade_ms" in pb:
                # you use crossfade only if transitions_crossfade is True
                self.cfg.playback.crossfade_ms = int(pb["crossfade_ms"])
                self.crossfade_ms = int(pb["crossfade_ms"]) if getattr(self.cfg.playback, "transitions_crossfade", False) else 0

            # If you cache anything else (e.g., timers), refresh here if needed.
        except Exception:
            pass


    def _is_in_slideshow(self, path: Path) -> bool:
        """
        Honor both 'include' and 'exclude_from_slideshow'.
        Default behavior:
        - If include == False -> skip
        - Else if exclude_from_slideshow == True -> skip
        - Else -> show
        """
        try:
            self._load_meta_if_changed()
            item_id = self._id_from_library_path(Path(self.cfg.paths.library), path)
            flags = self._meta_cache.get(item_id) or {}
            if flags.get("include") is False:
                return False
            if flags.get("exclude_from_slideshow") is True or flags.get("exclude_from_shuffle") is True:
                return False
            return True
        except Exception:
            return True


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
                # rebuild playlist according to flags
                self._rebuild_playlist()
                self.watch_flag.clear()

            row = self._row_for_id(self.current_id)
            if not row:
                # draw message
                self.screen.fill((0,0,0))
                msg = font.render("No media found in data/library", True, (200,200,200))
                rect = msg.get_rect(center=(self.W//2, self.H//2))
                self.screen.blit(msg, rect)
                pygame.display.flip()
                # Try rescanning & rebuilding occasionally
                self.lib.scan_once(recursive=self.cfg.indexer.recursive, ignore_hidden=self.cfg.indexer.ignore_hidden)
                self._rebuild_playlist()
                self.current_id = self._next_play_id(None)
                time.sleep(2)
                continue

            mid, path, kind = row

            # respect "In Slideshow" flag
            if not self._is_in_slideshow(path):
                # skip to next immediately (do not display)
                self.current_id = self.lib.next_id(mid, loop=self.cfg.playback.loop)
                continue

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
            self._load_meta_if_changed()
            self._rebuild_playlist()
            # next according to flags-aware playlist
            self.current_id = self._next_play_id(mid)


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
            self._sleep_with_events(self.cfg.playback.slide_duration_s)

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
                self._sleep_with_events(self.cfg.playback.slide_duration_s)
                break

    def _preload_neighbors(self, current_id: int):
        """
        Warm prev/next **images** around the current item within the flags-aware playlist.
        """
        if not self._playlist or current_id not in self._id_index:
            return
        i = self._id_index[current_id]
        n = len(self._playlist)
        prev_i = (i - 1) % n
        next_i = (i + 1) % n

        def is_img(tup: tuple[int, str, str]) -> bool:
            _id, _p, _k = tup
            return Path(_p).suffix.lower() in SUPPORTED_IMAGES

        # Collect current lane: prev, curr, next if they are images
        lane = []
        for idx in (prev_i, i, next_i):
            tup = self._playlist[idx]
            if is_img(tup):
                lane.append(str(tup[1]))

        if lane:
            # idx of current within lane if present
            try:
                cur_idx = lane.index(str(self._playlist[i][1]))
            except ValueError:
                cur_idx = 0
            self.loader.preload_neighbors(lane, cur_idx)


    def _sleep_with_events(self, seconds: float):
        end = time.time() + seconds
        while time.time() < end:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit(); raise SystemExit
            self.clock.tick(60)
