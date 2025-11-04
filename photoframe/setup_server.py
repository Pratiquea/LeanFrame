# photoframe/setup_server.py
import json, socket
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from typing import Dict, Any
from .wifi import connect_wifi, current_state, mark_provisioned
import subprocess
AP_ENV = Path("/var/lib/leanframe/setup_ap.env")
AP_IP  = "192.168.4.1"

def read_ap_env():
    ssid = psk = None
    if AP_ENV.exists():
        for line in AP_ENV.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"): continue
            if line.startswith("AP_SSID="): ssid = line.split("=",1)[1]
            if line.startswith("AP_PSK="):  psk  = line.split("=",1)[1]
    return ssid, psk

def ensure_hotspot_started():
    # single source of truth: systemd service (idempotent)
    try:
        subprocess.run(["/usr/bin/systemctl", "start", "leanframe-hotspot.service"], check=False)
    except Exception:
        pass

def stop_hotspot():
    try:
        subprocess.run(["/usr/bin/systemctl", "stop", "leanframe-hotspot.service"], check=False)
    except Exception:
        pass

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
    ensure_hotspot_started()
    ssid, psk = read_ap_env()
    if not ssid or not psk:
        raise HTTPException(500, "AP env missing")
    # if you still want a pair code, derive it here (or from your state)
    st = current_state()
    dev = st.get("device_id") or "unknown"
    pair = st.get("pair_code") or "0000"
    return {
        "ap_ssid": ssid,
        "ap_psk": psk,
        "pair_code": pair,
        "device_id": dev,
        "setup_base": f"http://{AP_IP}:8765"
     }


@app.post("/provision")
async def provision(body: Dict[str, Any]):
    """
    Body: { "pair_code": "1234", "wifi": { "ssid": "...", "password": "..." } }
    """
    want_code = str(body.get("pair_code", "")).strip()
    wifi = body.get("wifi") or {}
    ssid = str(wifi.get("ssid", "")).strip()
    pw   = str(wifi.get("password", "")).strip()

    st = current_state()
    have_code = str(st.get("pair_code", ""))

    if not want_code or want_code != have_code:
        raise HTTPException(400, "Invalid pair_code")

    if not ssid or not pw:
        raise HTTPException(400, "Missing wifi.ssid/password")

    ok = connect_wifi(ssid, pw)
    if not ok:
        raise HTTPException(400, "Failed to join Wi-Fi (wrong SSID/password?)")

    # Success: stop AP (systemd) so the frame joins LAN
    stop_hotspot()

    # figure out a LAN IP to return (best effort)
    try:
        # Get primary IP by connecting a dummy UDP socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except Exception:
        ip = None

    mark_provisioned(ip)
    # Immediately flip services to normal mode (no reboot needed)
    try:
        print("[setup_server] Provisioning complete, restarting leanframe-switch.service to load main runtime…")
        subprocess.run(
            ["sudo", "systemctl", "restart", "leanframe-switch.service"],
            check=False,
        )
    except Exception as e:
        print(f"[setup_server] failed to restart leanframe-switch.service: {e}")
    return {"ok": True, "lan_ip": ip}

@app.get("/status")
def status():
    return current_state()

def main():
    # Ensure AP is up and QR has content
    ensure_hotspot_started()
    uvicorn.run(app, host="0.0.0.0", port=8765)

if __name__ == "__main__":
    main()
