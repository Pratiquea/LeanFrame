# photoframe/setup_server.py
import json, socket, logging, os, time, traceback
from pathlib import Path
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from typing import Dict, Any
from .wifi import connect_wifi, current_state, mark_provisioned
import subprocess
from contextlib import contextmanager
import concurrent.futures
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout

LOGLEVEL = os.environ.get("LOGLEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOGLEVEL, logging.INFO),
    format="%(asctime)s | %(levelname)-7s | setup_server | %(message)s",
)
log = logging.getLogger("setup_server")

AP_ENV = Path("/var/lib/leanframe/setup_ap.env")
AP_IP  = "192.168.4.1"

def read_ap_env():
    """Read SSID/PSK from shared env file."""
    ssid = psk = None
    try:
        if AP_ENV.exists():
            log.debug(f"Reading AP env file: {AP_ENV}")
            for line in AP_ENV.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("AP_SSID="):
                    ssid = line.split("=", 1)[1]
                if line.startswith("AP_PSK="):
                    psk = line.split("=", 1)[1]
        else:
            log.warning(f"AP env not found at {AP_ENV}")
    except Exception as e:
        log.error(f"Failed reading AP env: {e}")
        log.debug(traceback.format_exc())
    log.info(f"AP env -> SSID={ssid!r}, PSK={'<set>' if psk else '<missing>'}")
    return ssid, psk

def ensure_hotspot_started():
    # single source of truth: systemd service (idempotent)
    try:
        log.info("Starting hotspot: systemctl start leanframe-hotspot.service")
        subprocess.run(["/usr/bin/systemctl", "start", "leanframe-hotspot.service"], check=False)
    except Exception as e:
        log.error(f"Hotspot start exception: {e}")
        log.debug(traceback.format_exc())

def stop_hotspot():
    try:
        log.info("Stopping hotspot: systemctl stop leanframe-hotspot.service")
        subprocess.run(["/usr/bin/systemctl", "stop", "leanframe-hotspot.service"], check=False)
    except Exception as e:
        log.error(f"Hotspot stop exception: {e}")
        log.debug(traceback.format_exc())

def _connect_with_timeout(ssid: str, pw: str, timeout_s: int = 25) -> bool:
    """
    Run connect_wifi(ssid, pw) with a timeout. Returns False on timeout.
    """
    with ThreadPoolExecutor(max_workers=1) as ex:
        fut = ex.submit(connect_wifi, ssid, pw)
        try:
            return fut.result(timeout=timeout_s)
        except FuturesTimeout:
            log.error(f"connect_wifi timed out after {timeout_s}s")
            return False
        except Exception as e:
            log.error(f"connect_wifi raised: {e}")
            log.debug(traceback.format_exc())
            return False

def _post_provision_work(ssid, pw):
    # do the disruptive work AFTER response is sent
    try:
        log.info(f"[bg] connecting to Wi-Fi {ssid!r}…")
        ok = connect_wifi(ssid, pw)
        log.info(f"[bg] connect_wifi -> {ok}")
        if not ok:
            log.error("[bg] connect failed; leaving AP up so user can retry")
            return
        stop_hotspot()
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
        except Exception:
            ip = None
        log.info(f"[bg] mark_provisioned ip={ip}")
        mark_provisioned(ip)
        log.info("[bg] restarting leanframe-switch.service")
        subprocess.run(["sudo", "systemctl", "restart", "leanframe-switch.service"], check=False)
    except Exception as e:
        log.error(f"[bg] post-provision failed: {e}")


app = FastAPI(title="LeanFrame Setup")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/pair")
def get_pair_info():
    """
    Returns QR payload (for app fallback) and shows matching WIFI: QR in onboarding.
    """
    log.info("GET /pair")
    ensure_hotspot_started()
    ssid, psk = read_ap_env()
    if not ssid or not psk:
        log.error("AP env missing SSID/PSK; returning 500")
        raise HTTPException(500, "AP env missing")

    st = current_state()
    dev = st.get("device_id") or "unknown"
    pair = st.get("pair_code") or "0000"
    log.info(f"/pair -> device_id={dev}, pair_code={pair}, setup_base=http://{AP_IP}:8765")

    return {
        "ap_ssid": ssid,
        "ap_psk": psk,
        "pair_code": pair,
        "device_id": dev,
        "setup_base": f"http://{AP_IP}:8765"
     }

@app.post("/provision")
async def provision(body: Dict[str, Any], background_tasks: BackgroundTasks):
    """
    Body: { "pair_code": "1234", "wifi": { "ssid": "...", "password": "..." } }
    """
    log.info("POST /provision")
    want_code = str(body.get("pair_code", "")).strip()
    wifi = body.get("wifi") or {}
    ssid = str(wifi.get("ssid", "")).strip()
    pw   = str(wifi.get("password", "")).strip()

    st = current_state()
    have_code = (str(st.get("pair_code", "")) or "").strip()

    # relaxed pair code (only enforce if stored)
    if have_code:
        if not want_code or want_code != have_code:
            raise HTTPException(400, "Invalid pair_code")
    if not ssid or not pw:
        raise HTTPException(400, "Missing wifi.ssid/password")

    # reply first, then flip networks in the background
    background_tasks.add_task(_post_provision_work, ssid, pw)
    return {"ok": True, "lan_ip": None}

@app.get("/status")
def status():
    log.info("GET /status")
    st = current_state()
    log.debug(f"State: {st}")
    return st

def main():
    # Ensure AP is up and QR has content
    log.info(f"Starting setup server on 0.0.0.0:8765 (AP_IP={AP_IP})")
    ensure_hotspot_started()
    # Note: uvicorn has its own access logs; ours complement them
    uvicorn.run(app, host="0.0.0.0", port=8765, log_level=LOGLEVEL.lower())

if __name__ == "__main__":
    main()