# fast_image_loader.py
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from collections import OrderedDict
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

from PIL import Image, ImageOps, ExifTags   # only for EXIF + fallback

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
    def __init__(self, screen_size):
        self.W, self.H = screen_size
        self.cache = SurfaceLRU(6)
        self.pool = ThreadPoolExecutor(max_workers=3)

    def _apply_orientation(self, pil_img):
        try:
            exif = pil_img.getexif()
            if not exif: return pil_img
            o = exif.get(_EXIF_ORIENT, 1)
            return ImageOps.exif_transpose(pil_img) if o != 1 else pil_img
        except Exception:
            return pil_img

    def _to_surface(self, arr_hw3):
        surf = pygame.image.frombuffer(arr_hw3.tobytes(), arr_hw3.shape[1::-1], "RGB")
        return surf.convert()  # match display format for fast blits

    def _decode_with_turbojpeg(self, path):
        # Choose denominator (1,2,4,8) to approach target size on decode
        # Start with 1, pick larger denom if image is much bigger than screen
        header = _jpeg.decode_header(open(path, 'rb').read(2048))
        print("width = {}, type = {}".format(header['width'], type(header['width'])))
        w, h = header['width'], header['height']
        denom = 1
        while denom < 8 and (w // (denom * 2) > self.W*1.25 or h // (denom * 2) > self.H*1.25):
            denom *= 2
        with open(path, 'rb') as f:
            rgb = _jpeg.decode(f.read(), pixel_format=TJPF_RGB, scaling_factor=(1, denom))
        arr = np.frombuffer(rgb, dtype=np.uint8).reshape(h//denom, w//denom, 3)
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
        key = (p, self.W, self.H, p.stat().st_mtime)
        def mk():
            # try EXIF-thumb-first showing (optional): you can split API to return “thumb, future”
            if _jpeg and p.suffix.lower() in (".jpg", ".jpeg"):
                arr = self._decode_with_turbojpeg(p)
            elif pyvips:
                arr = self._decode_with_pyvips(p)
            else:
                arr = self._decode_with_pillow(p)
            return self._to_surface(arr)
        return self.cache.get_put(key, mk)

    def preload_neighbors(self, paths, idx):
        for j in (idx+1, idx-1):
            if 0 <= j < len(paths):
                self.pool.submit(self.load_surface, paths[j])
