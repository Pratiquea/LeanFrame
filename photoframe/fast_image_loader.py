# fast_image_loader.py
from __future__ import annotations
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from collections import OrderedDict
from PIL import Image, ImageOps, ImageFilter
import numpy as np
import pygame

# Optional accelerators
try:
    from turbojpeg import TurboJPEG, TJPF_RGB
    _jpeg = TurboJPEG()
except Exception:
    _jpeg = None

try:
    import pyvips
except Exception:
    pyvips = None

from PIL import Image, ImageOps, ExifTags, ImageFilter  # EXIF + fallback + blur
from .config import RenderCfg, RenderPaddingCfg

_EXIF_ORIENT = {v: k for k, v in ExifTags.TAGS.items()}.get('Orientation', None)

class SurfaceLRU(OrderedDict):
    def __init__(self, cap=6): super().__init__(); self.cap = cap
    def get_put(self, key, mk):
        if key in self:
            self.move_to_end(key); return self[key]
        val = mk(); self[key] = val
        while len(self) > self.cap: self.popitem(last=False)
        return val

class FastImageLoader:
    def __init__(self, screen_size, render: RenderCfg | None = None):
        self.W, self.H = screen_size
        self.cache = SurfaceLRU(6)
        self.pool = ThreadPoolExecutor(max_workers=3)
        # default render if not provided
        self.render = render or RenderCfg()

    def _apply_orientation(self, pil_img):
        try:
            exif = pil_img.getexif()
            if not exif: return pil_img
            o = exif.get(_EXIF_ORIENT, 1)
            return ImageOps.exif_transpose(pil_img) if o != 1 else pil_img
        except Exception:
            return pil_img

    def _read_orientation_tag(self, path: Path) -> int:
        """Lightweight: read orientation without fully decoding pixels for turbojpeg/pyvips paths."""
        try:
            with Image.open(path) as im:
                exif = im.getexif()
                return int(exif.get(_EXIF_ORIENT, 1)) if exif else 1
        except Exception:
            return 1

    @staticmethod
    def _hex_to_rgb(s: str) -> tuple[int, int, int]:
        s = s.strip().lstrip('#')
        if len(s) == 3:  # #abc
            s = ''.join(ch*2 for ch in s)
        try:
            return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))
        except Exception:
            return (0, 0, 0)

    def _compose_frame(self, src_img: Image.Image, orientation_tag: int) -> np.ndarray:
        """
        Returns an RGB numpy array with shape (H, W, 3), already composed to the
        screen size (W,H) according to self.render.mode and padding settings.
        """
        W, H = self.W, self.H
        # Apply orientation first
        try:
            if orientation_tag != 1:
                src_img = ImageOps.exif_transpose(src_img)
        except Exception:
            pass

        w, h = src_img.size
        if w == 0 or h == 0:
            # guard
            canvas = Image.new("RGB", (W, H), (0, 0, 0))
            return np.asarray(canvas)

        mode = (self.render.mode or "cover").lower()  # "cover" | "contain"
        blur_amt = int(self.render.padding.blur_amount) if self.render and self.render.padding else 28
        # clilp blur amount to reasonable range
        blur_amt = max(1, min(blur_amt, 100))
        pad_style = (self.render.padding.style if self.render.padding else "blur").lower()
        pad_color_rgb = self._hex_to_rgb(self.render.padding.color if self.render.padding else "#000000")

        if mode == "cover":
            # scale to fill, then center-crop
            scale = max(W / w, H / h)
            nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
            im = src_img.resize((nw, nh), Image.LANCZOS)
            left = max(0, (nw - W) // 2)
            top = max(0, (nh - H) // 2)
            im = im.crop((left, top, left + W, top + H))
            return np.asarray(im.convert("RGB"))

        # CONTAIN: keep aspect, add padding to fit exactly W×H
        scale = min(W / w, H / h)
        nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
        main = src_img.resize((nw, nh), Image.LANCZOS).convert("RGB")

        # Background canvas
        if pad_style == "solid":
            bg = Image.new("RGB", (W, H), pad_color_rgb)
        else:
            # "blur" modern padding: take a cover-scaled version, heavily blur
            s = max(W / w, H / h)
            cw, ch = max(1, int(w * s)), max(1, int(h * s))
            bg = src_img.resize((cw, ch), Image.LANCZOS).convert("RGB")
            # center-crop to W×H
            l = max(0, (cw - W) // 2)
            t = max(0, (ch - H) // 2)
            bg = bg.crop((l, t, l + W, t + H))
            # blur + slight darken to emphasize main image
            try:
                bg = bg.filter(ImageFilter.GaussianBlur(radius=blur_amt))
                # optional: subtle dim
                bg = Image.blend(bg, Image.new("RGB", bg.size, (0, 0, 0)), alpha=0.08)
            except Exception:
                pass

        # Paste main centered
        canvas = bg.copy()
        off = ((W - nw) // 2, (H - nh) // 2)
        canvas.paste(main, off)
        return np.asarray(canvas)

    def _to_surface(self, arr_hw3):
        surf = pygame.image.frombuffer(arr_hw3.tobytes(), arr_hw3.shape[1::-1], "RGB")
        return surf.convert()  # match display format for fast blits

    def _decode_with_turbojpeg(self, path):
        """
        Robust JPEG fast path:
          - Works with PyTurboJPEG header as dict *or* tuple (older builds on Pi).
          - Reads the whole file (partial header reads can fail on some JPEGs).
          - If reshape dims are off (MCU rounding), falls back gracefully.
        """
        with open(path, "rb") as f:
            data = f.read()
        # PyTurboJPEG header can be dict or tuple depending on version.
        hdr = _jpeg.decode_header(data)
        if isinstance(hdr, dict):
            w, h = int(hdr.get("width")), int(hdr.get("height"))
        else:
            # Older API: (width, height, subsamp, colorspace)
            w, h = int(hdr[0]), int(hdr[1])
        # Choose denominator (1,2,4,8) to approach target size on decode.
        denom = 1
        while denom < 8 and (w // (denom * 2) > self.W * 1.25 or h // (denom * 2) > self.H * 1.25):
            denom *= 2
        try:
            rgb = _jpeg.decode(data, pixel_format=TJPF_RGB, scaling_factor=(1, denom))
        except Exception:
            # If turbojpeg decode fails for any reason, defer to Pillow path.
            return self._decode_with_pillow(Path(path))
        # Some builds return a numpy array already; others return bytes.
        if isinstance(rgb, np.ndarray):
            arr = rgb
        else:
            out_w = max(1, w // denom)
            out_h = max(1, h // denom)
            arr = np.frombuffer(rgb, dtype=np.uint8)
            # Guard against MCU rounding mismatches; try the expected shape first.
            try:
                arr = arr.reshape(out_h, out_w, 3)
            except ValueError:
                # Final fallback: ask Pillow to infer shape from bytes.
                from PIL import Image
                im = Image.frombuffer("RGB", (out_w, out_h), rgb, "raw", "RGB", 0, 1)
                arr = np.asarray(im)
        return arr

    def _decode_with_pyvips(self, path):
        # Shrink on read; keeps memory tiny
        img = pyvips.Image.new_from_file(str(path), access="sequential")
        scale = min(self.W / img.width, self.H / img.height, 1.0)
        out = img.resize(scale) if scale < 1.0 else img
        # to numpy
        mem = out.write_to_memory()
        arr = np.frombuffer(mem, dtype=np.uint8).reshape(out.height, out.width, out.bands)
        if arr.shape[2] == 4: arr = arr[:, :, :3]  # drop alpha for pygame fast path
        return arr

    def _decode_with_pillow(self, path):
        im = Image.open(path)
        im = self._apply_orientation(im)
        im.thumbnail((self.W, self.H), Image.Resampling.BILINEAR)
        return np.array(im.convert("RGB"))

    def _decode_exif_thumb(self, path):
        try:
            im = Image.open(path)
            thumb = im.getexif().get_ifd(0x8769)  # may raise, handled below
        except Exception:
            thumb = None
        try:
            t = Image.open(path)
            t.thumbnail((self.W, self.H))
            if hasattr(t, "getexif") and t.getexif().get(0x501B):  # fallback attempt
                pass
            # Simpler, portable EXIF preview:
            preview = t._getexif().get(0x501B)  # may fail on many files
            return None  # keep it conservative; EXIF thumb varies widely
        except Exception:
            return None

    def load_surface(self, path):
        p = Path(path)
        # key = (p, self.W, self.H, p.stat().st_mtime)
        try:
            mtime = p.stat().st_mtime
        except FileNotFoundError:
            # Surface was requested but file is missing
            raise FileNotFoundError(f"Missing media: {p}")
        # Cache key must reflect render settings too
        key = (p, self.W, self.H, mtime,
               getattr(self.render, "mode", "cover"),
               getattr(self.render.padding, "style", "blur") if self.render and self.render.padding else "blur",
               getattr(self.render.padding, "color", "#000000") if self.render and self.render.padding else "#000000")
        def mk():
            # Decode (fast-paths if available)
            orientation_tag = 1
            if _jpeg and p.suffix.lower() in (".jpg", ".jpeg"):
                arr = self._decode_with_turbojpeg(p)
                # fetch EXIF orientation cheaply
                orientation_tag = self._read_orientation_tag(p)
                pil = Image.fromarray(arr, mode="RGB")
            elif pyvips:
                arr = self._decode_with_pyvips(p)
                # EXIF for non-JPEG may be absent; try anyway
                orientation_tag = self._read_orientation_tag(p)
                pil = Image.fromarray(arr, mode="RGB")
            else:
                # pillow decode (we'll re-orient during compose)
                arr = self._decode_with_pillow(p)
                orientation_tag = self._read_orientation_tag(p)
                pil = Image.fromarray(arr, mode="RGB")

            # Compose to screen size according to render settings
            composed = self._compose_frame(pil, orientation_tag)
            return self._to_surface(composed)
        return self.cache.get_put(key, mk)

    def preload_neighbors(self, paths, idx):
        for j in (idx+1, idx-1):
            if 0 <= j < len(paths):
                self.pool.submit(self.load_surface, paths[j])
