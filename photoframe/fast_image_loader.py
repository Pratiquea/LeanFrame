# fast_image_loader.py
from __future__ import annotations
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from collections import OrderedDict
from PIL import Image, ImageOps, ImageFilter, ImageDraw 
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

    @staticmethod
    def _avg_color(img: Image.Image) -> tuple[int, int, int]:
        # Compute quickly on tiny thumbnail
        t = img.convert("RGB")
        t.thumbnail((32, 32), Image.LANCZOS)
        arr = np.asarray(t, dtype=np.uint8).reshape(-1, 3)
        m = arr.mean(axis=0).astype(np.uint8)
        return (int(m[0]), int(m[1]), int(m[2]))

    @staticmethod
    def _lerp(a: tuple[int,int,int], b: tuple[int,int,int], t: float) -> tuple[int,int,int]:
        return (int(a[0] + (b[0]-a[0])*t),
                int(a[1] + (b[1]-a[1])*t),
                int(a[2] + (b[2]-a[2])*t))

    def _make_linear_gradient(self, size, c0, c1, vertical=True) -> Image.Image:
        W, H = size
        base = Image.new("RGB", (W, H), c0)
        overlay = Image.new("RGB", (W, H), c1)
        mask = Image.new("L", (W, H))
        draw = ImageDraw.Draw(mask)
        if vertical:
            for y in range(H):
                draw.line((0, y, W, y), fill=int(255 * y / max(1, H-1)))
        else:
            for x in range(W):
                draw.line((x, 0, x, H), fill=int(255 * x / max(1, W-1)))
        return Image.composite(overlay, base, mask)

    def _make_radial_gradient(self, size, c0, c1) -> Image.Image:
        W, H = size
        cx, cy = W/2.0, H/2.0
        y, x = np.ogrid[:H, :W]
        r = np.sqrt((x - cx)**2 + (y - cy)**2)
        r /= r.max() if r.max() > 0 else 1.0
        # mask 0..255
        mask = (r * 255.0).astype(np.uint8)
        mask_img = Image.fromarray(mask, mode="L")
        base = Image.new("RGB", (W, H), c0)
        overlay = Image.new("RGB", (W, H), c1)
        return Image.composite(overlay, base, mask_img)

    def _mirror_pad_canvas(self, src: Image.Image, size) -> Image.Image:
        """Create a mirror-padded canvas (reflect edges) then center-crop to size."""
        W, H = size
        w, h = src.size
        # scale to fit (contain), then mirror-pad around to at least W×H
        s = min(W / w, H / h)
        nw, nh = max(1, int(w * s)), max(1, int(h * s))
        main = src.resize((nw, nh), Image.LANCZOS).convert("RGB")
        pad_x = max(0, (W - nw) // 2)
        pad_y = max(0, (H - nh) // 2)
        # Build big canvas by tiling mirrors (left/right/top/bottom)
        canvas = Image.new("RGB", (nw + 2*pad_x, nh + 2*pad_y))
        # center
        canvas.paste(main, (pad_x, pad_y))
        # mirror helpers
        left = main.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        right = left
        top = main.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        bottom = top
        # horizontal bands
        if pad_x:
            canvas.paste(left.crop((nw - pad_x, 0, nw, nh)), (0, pad_y))
            canvas.paste(main.crop((0, 0, pad_x, nh)).transpose(Image.Transpose.FLIP_LEFT_RIGHT), (pad_x + nw, pad_y))
        # vertical bands
        if pad_y:
            canvas.paste(top.crop((0, nh - pad_y, nw, nh)), (pad_x, 0))
            canvas.paste(main.crop((0, 0, nw, pad_y)).transpose(Image.Transpose.FLIP_TOP_BOTTOM), (pad_x, pad_y + nh))
        # corners
        if pad_x and pad_y:
            tl = main.crop((0, 0, pad_x, pad_y)).transpose(Image.Transpose.ROTATE_180)
            tr = main.crop((nw - pad_x, 0, nw, pad_y)).transpose(Image.Transpose.ROTATE_180)
            bl = main.crop((0, nh - pad_y, pad_x, nh)).transpose(Image.Transpose.ROTATE_180)
            br = main.crop((nw - pad_x, nh - pad_y, nw, nh)).transpose(Image.Transpose.ROTATE_180)
            canvas.paste(tl, (0, 0))
            canvas.paste(tr, (pad_x + nw, 0))
            canvas.paste(bl, (0, pad_y + nh))
            canvas.paste(br, (pad_x + nw, pad_y + nh))
        # final crop (already exact, but keep consistent)
        return canvas.crop((0, 0, W, H))

    def _stretch_pad_canvas(self, src: Image.Image, size) -> Image.Image:
        """Pixel-stretch edges to fill remaining area."""
        W, H = size
        w, h = src.size
        s = min(W / w, H / h)
        nw, nh = max(1, int(w * s)), max(1, int(h * s))
        main = src.resize((nw, nh), Image.LANCZOS).convert("RGB")
        bg = Image.new("RGB", (W, H))
        off = ((W - nw) // 2, (H - nh) // 2)
        # stretch left/right
        pad_left = off[0]
        pad_right = W - (off[0] + nw)
        pad_top = off[1]
        pad_bottom = H - (off[1] + nh)
        if pad_left > 0:
            strip = main.crop((0, 0, 1, nh)).resize((pad_left, nh))
            bg.paste(strip, (0, off[1]))
        if pad_right > 0:
            strip = main.crop((nw-1, 0, nw, nh)).resize((pad_right, nh))
            bg.paste(strip, (off[0]+nw, off[1]))
        if pad_top > 0:
            strip = main.crop((0, 0, nw, 1)).resize((nw, pad_top))
            bg.paste(strip, (off[0], 0))
        if pad_bottom > 0:
            strip = main.crop((0, nh-1, nw, nh)).resize((nw, pad_bottom))
            bg.paste(strip, (off[0], off[1]+nh))
        bg.paste(main, off)
        return bg

    def _texture_canvas(self, size, base_color=(12,12,12), blur_amt = 0.5) -> Image.Image:
        """Generate a subtle grain texture (no assets required)."""
        W, H = size
        rng = np.random.default_rng(12345)
        noise = rng.normal(0, 8, (H, W, 3)).astype(np.int16)
        base = np.full((H, W, 3), base_color, dtype=np.int16)
        arr = np.clip(base + noise, 0, 255).astype(np.uint8)
        return Image.fromarray(arr, mode="RGB").filter(ImageFilter.GaussianBlur(radius=blur_amt))

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
        elif pad_style == "blur":
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
        elif pad_style == "average":
            avg = self._avg_color(src_img)
            bg = Image.new("RGB", (W, H), avg)
        elif pad_style == "mirror":
            bg = self._mirror_pad_canvas(src_img, (W, H))
        elif pad_style == "stretch":
            bg = self._stretch_pad_canvas(src_img, (W, H))
        elif pad_style == "gradient_linear":
            c0 = self._avg_color(src_img)
            c1 = pad_color_rgb or (0, 0, 0)
            bg = self._make_linear_gradient((W, H), c0, c1, vertical=True)
        elif pad_style == "gradient_radial":
            c0 = self._avg_color(src_img)
            c1 = pad_color_rgb or (0, 0, 0)
            bg = self._make_radial_gradient((W, H), c0, c1)
        elif pad_style == "glass":
            # frosted glass = blur + slight brighten
            s = max(W / w, H / h)
            cw, ch = max(1, int(w * s)), max(1, int(h * s))
            bg = src_img.resize((cw, ch), Image.LANCZOS).convert("RGB")
            l = max(0, (cw - W) // 2); t = max(0, (ch - H) // 2)
            bg = bg.crop((l, t, l + W, t + H)).filter(ImageFilter.GaussianBlur(radius=blur_amt))
            # brighten a tad by blending toward white
            bg = Image.blend(bg, Image.new("RGB", (W, H), (255, 255, 255)), alpha=0.06)
        elif pad_style == "motion":
            # cheap directional blur: average a few shifted copies
            s = max(W / w, H / h)
            cw, ch = max(1, int(w * s)), max(1, int(h * s))
            base = src_img.resize((cw, ch), Image.LANCZOS).convert("RGB")
            l = max(0, (cw - W) // 2); t = max(0, (ch - H) // 2)
            base = base.crop((l, t, l + W, t + H))
            acc = np.zeros((H, W, 3), dtype=np.float32)
            for dx in (-4, -2, 0, 2, 4):
                shifted = Image.new("RGB", (W, H))
                shifted.paste(base, (dx, 0))
                acc += np.asarray(shifted, dtype=np.float32)
            acc /= 5.0
            bg = Image.fromarray(np.clip(acc, 0, 255).astype(np.uint8), "RGB")
        elif pad_style == "texture":
            c0 = self._avg_color(src_img)
            bg = self._texture_canvas((W, H), base_color=c0)
        elif pad_style == "dim":
            avg = self._avg_color(src_img)
            bg = Image.new("RGB", (W, H), avg)
            bg = Image.blend(bg, Image.new("RGB", (W, H), (0, 0, 0)), alpha=0.4)
        else:
            # default fallback = blur
            s = max(W / w, H / h)
            cw, ch = max(1, int(w * s)), max(1, int(h * s))
            bg = src_img.resize((cw, ch), Image.LANCZOS).convert("RGB")
            l = max(0, (cw - W) // 2); t = max(0, (ch - H) // 2)
            bg = bg.crop((l, t, l + W, t + H)).filter(ImageFilter.GaussianBlur(radius=blur_amt))
            bg = Image.blend(bg, Image.new("RGB", (W, H), (0, 0, 0)), alpha=0.08)

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
