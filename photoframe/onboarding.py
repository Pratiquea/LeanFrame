# photoframe/onboarding.py
import io, json, time, pygame, requests
from PIL import Image
import qrcode
from pygame.locals import FULLSCREEN

SETUP_BASE = "http://192.168.4.1:8765"

def _make_qr(data: dict, size=360) -> pygame.Surface:
    # Single QR that includes all info the app needs
    payload = {
        "kind": "leanframe_setup_v1",
        **data,
    }
    qr = qrcode.QRCode(version=None, box_size=8, border=2)
    qr.add_data(json.dumps(payload))
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    img = img.resize((size, size), Image.LANCZOS)
    raw = img.tobytes()
    surf = pygame.image.frombuffer(raw, img.size, "RGB")
    return surf

def run(screen_size=(800, 480), fullscreen=True):
    pygame.init()
    flags = FULLSCREEN if fullscreen else 0
    screen = pygame.display.set_mode(screen_size, flags)
    pygame.mouse.set_visible(False)
    font_big = pygame.font.SysFont(None, 40)
    font_sm  = pygame.font.SysFont(None, 24)

    # Pull pair info from setup_server
    while True:
        try:
            r = requests.get(f"{SETUP_BASE}/pair", timeout=2)
            if r.status_code == 200:
                info = r.json()
                break
        except Exception:
            pass
        screen.fill((10, 10, 10))
        msg = font_big.render("Starting setup hotspot…", True, (220, 220, 220))
        screen.blit(msg, msg.get_rect(center=(screen.get_width()//2, screen.get_height()//2)))
        pygame.display.flip()
        for e in pygame.event.get():
            if e.type == pygame.QUIT: return
        time.sleep(0.5)

    qr = _make_qr(info, size=min(screen.get_width(), screen.get_height()) // 2)
    ssid = info["ap_ssid"]
    psk  = info["ap_psk"]
    code = info["pair_code"]

    while True:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                return

        screen.fill((18, 18, 18))
        title = font_big.render("LeanFrame — Setup", True, (255, 255, 255))
        screen.blit(title, (24, 18))
        screen.blit(qr, (24, 70))

        lines = [
            "1) On your phone: Open the LeanFrame app",
            f"2) Scan this QR, or manually connect to Wi-Fi:",
            f"      SSID: {ssid}",
            f"      Password: {psk}",
            f"3) Enter your home Wi-Fi and confirm pairing code:",
            f"      Pair code: {code}",
        ]
        y = 70
        for ln in lines:
            y += 34
            txt = font_sm.render(ln, True, (220, 220, 220))
            screen.blit(txt, (qr.get_width() + 48, y))

        pygame.display.flip()
        time.sleep(0.05)
