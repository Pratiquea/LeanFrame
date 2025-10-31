# photoframe/onboarding.py
import os, json, time, socket, uuid
from pathlib import Path
import sys
import pygame
import qrcode
from qrcode.image.pil import PilImage

PAIR_KIND    = "leanframe_setup_v1"
SETUP_BASE   = os.environ.get("SETUP_BASE", "http://rpi.local:8000")
PROVISION_OK = Path("/var/lib/leanframe/provisioned")
TIMEOUT_SEC  = 15 * 60  # 15 minutes

def _read_ap_env():
    ssid = psk = None
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"): continue
            if line.startswith("AP_SSID="): ssid = line.split("=",1)[1]
            if line.startswith("AP_PSK="):  psk  = line.split("=",1)[1]
    if not ssid or not psk:
        # Fallback: derive from machine-id to keep it stable
        mid = Path("/etc/machine-id").read_text().strip()[:8]
        ssid = ssid or f"LeanFrame-{mid}"
        psk  = psk  or f"Frame-{mid}"
    return ssid, psk

def _qr_pil_to_surface(img_pil):
    mode = img_pil.mode
    size = img_pil.size
    data = img_pil.tobytes()
    return pygame.image.fromstring(data, size, mode).convert()

def _detect_ip():
    try:
        import socket as s
        sock = s.socket(s.AF_INET, s.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
    except Exception:
        ip = "0.0.0.0"
    return ip

def main():
    device_id = Path("/etc/machine-id").read_text().strip()[:8]
    ap_ssid, ap_psk = _read_ap_env()
    pair_code = str(uuid.uuid4())[:4].upper()

    payload = {
        "kind": PAIR_KIND,
        "device_id": device_id,
        "pair_code": pair_code,
        "ap_ssid": ap_ssid,
        "ap_psk": ap_psk,
        "setup_base": SETUP_BASE,
    }

    qr = qrcode.QRCode(border=2, box_size=8)
    qr.add_data(json.dumps(payload))
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white",
                        image_factory=PilImage).convert("RGB")

    pygame.init()
    info = pygame.display.Info()
    W, H = info.current_w, info.current_h
    flags = pygame.FULLSCREEN  # | pygame.NOFRAME  # add NOFRAME if desired
    screen = pygame.display.set_mode((W, H), flags)
    pygame.display.set_caption("LeanFrame Setup")
    pygame.mouse.set_visible(False)
    clock = pygame.time.Clock()
    font = pygame.font.SysFont(None, 28)
    mono = pygame.font.SysFont("monospace", 22)

    qr_surf = _qr_pil_to_surface(img)
    qr_rect = qr_surf.get_rect()
    scale = min((W*0.6)/qr_rect.width, (H*0.6)/qr_rect.height)
    if scale < 1.0:
        qr_surf = pygame.transform.smoothscale(
            qr_surf, (int(qr_rect.width*scale), int(qr_rect.height*scale)))
        qr_rect = qr_surf.get_rect()

    host = socket.gethostname()
    ip   = _detect_ip()
    t0   = time.time()

    while True:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                pygame.quit(); return
            if e.type == pygame.KEYDOWN and e.key in (pygame.K_ESCAPE, pygame.K_q):
                pygame.quit(); return

        if PROVISION_OK.exists():
            screen.fill((235, 250, 235))
            msg = font.render("Provisioned. You can close this screen.", True, (0, 120, 0))
            screen.blit(msg, msg.get_rect(center=(W//2, H//2)))
            pygame.display.flip()
            time.sleep(2)
            pygame.quit()
            return

        if time.time() - t0 > TIMEOUT_SEC:
            screen.fill((255, 245, 235))
            msg = font.render("Setup timed out. Restarting later…", True, (150, 80, 0))
            screen.blit(msg, msg.get_rect(center=(W//2, H//2)))
            pygame.display.flip()
            time.sleep(2)
            pygame.quit()
            return

        screen.fill((250, 250, 250))
        title = font.render("Scan this QR in the LeanFrame app", True, (40, 40, 40))
        screen.blit(title, (W//2 - title.get_width()//2, 16))
        screen.blit(qr_surf, (W//2 - qr_rect.width//2, H//2 - qr_rect.height//2 - 20))

        screen.blit(mono.render(f"SSID: {ap_ssid}", True, (70,70,70)), (20, H-80))
        screen.blit(mono.render(f"PSK : {ap_psk}", True, (70,70,70)), (20, H-54))
        screen.blit(mono.render(f"Setup base: {SETUP_BASE}", True, (100,100,100)), (20, 56))
        screen.blit(mono.render(f"Host: {host}   IP: {ip}", True, (100,100,100)), (20, 82))

        pygame.display.flip()
        clock.tick(30)

if __name__ == "__main__":
    main()
