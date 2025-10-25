from PIL import Image, ImageOps
from pathlib import Path
from functools import lru_cache
import os

@lru_cache(maxsize=2)
def load_image_cover(path: str, target_wh: tuple[int,int]):
    """Open path lazily, apply EXIF orientation, scale+crop to cover target.
    Returns a Pillow Image in RGBA (suitable for pygame.frombuffer).
    Cached for prev/next frame only (maxsize=2)."""
    W,H = target_wh
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGBA")
        # scale to cover
        w,h = im.size
        scale = max(W/w, H/h)
        nw, nh = int(w*scale), int(h*scale)
        im = im.resize((nw, nh), resample=Image.LANCZOS)
        # center crop
        left = (nw - W)//2
        top  = (nh - H)//2
        im = im.crop((left, top, left+W, top+H))
        return im

def is_hidden(p: Path) -> bool:
    return any(part.startswith('.') for part in p.parts)

def ext(p: Path) -> str:
    return p.suffix.lower()