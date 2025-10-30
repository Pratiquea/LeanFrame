# photoframe/wifi.py
import json, subprocess, secrets, string, os
from pathlib import Path

STATE = Path("/var/lib/leanframe/state.json")  # persisted small state

def load_state():
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {}

def save_state(d):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(d, indent=2))

def random_suffix(n=4):
    return ''.join(secrets.choice(string.digits) for _ in range(n))

def random_psk(n=12):
    # WPA2 PSK 8..63 chars, keep simple
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(n))

def ensure_ap_started():
    """Start/ensure a temporary AP named LeanFrame-Setup-XXXX running on wlan0."""
    st = load_state()
    ssid = st.get("ap_ssid")
    psk  = st.get("ap_psk")
    pair = st.get("pair_code")
    dev_id = st.get("device_id")

    if not ssid:
        ssid = f"LeanFrame-Setup-{random_suffix()}"
    if not psk:
        psk = random_psk(12)
    if not pair:
        pair = random_suffix(4)
    if not dev_id:
        # simple stable id: last 4 of CPU serial if available, else random
        try:
            ser = Path("/proc/cpuinfo").read_text()
            for line in ser.splitlines():
                if line.lower().startswith("serial"):
                    dev_id = line.split(":")[1].strip()[-8:]
                    break
            if not dev_id:
                dev_id = secrets.token_hex(4)
        except Exception:
            dev_id = secrets.token_hex(4)

    # Bring up hotspot via NetworkManager (idempotent)
    # If a connection with same ssid exists, delete it first
    try:
        existing = subprocess.run(
            ["nmcli", "-t", "-f", "NAME,TYPE", "con", "show"],
            check=True, capture_output=True, text=True
        ).stdout.splitlines()
        for line in existing:
            name, ctype = (line.split(":") + [""])[:2]
            if name == ssid and ctype == "wifi":
                subprocess.run(["nmcli", "con", "delete", name], check=True)
    except Exception:
        pass

    subprocess.run([
        "nmcli", "dev", "wifi", "hotspot",
        "ifname", "wlan0",
        "ssid", ssid,
        "password", psk
    ], check=True)

    # Pin AP to 192.168.4.1 (default for nmcli hotspot)
    st.update({"ap_ssid": ssid, "ap_psk": psk, "pair_code": pair, "device_id": dev_id, "provisioned": False})
    save_state(st)
    return ssid, psk, pair, dev_id

def stop_ap():
    # Delete the hotspot connection (safe if not present)
    st = load_state()
    ssid = st.get("ap_ssid")
    if ssid:
        subprocess.run(["nmcli", "con", "delete", ssid])
    return True

def connect_wifi(ssid: str, password: str):
    """Connect to user's Wi-Fi."""
    # If a connection profile exists with same name, delete to avoid wrong creds
    try:
        existing = subprocess.run(
            ["nmcli", "-t", "-f", "NAME,TYPE", "con", "show"],
            check=True, capture_output=True, text=True
        ).stdout.splitlines()
        for line in existing:
            name, ctype = (line.split(":") + [""])[:2]
            if name == ssid and ctype == "wifi":
                subprocess.run(["nmcli", "con", "delete", name], check=True)
    except Exception:
        pass

    r = subprocess.run(["nmcli", "dev", "wifi", "connect", ssid, "password", password])
    return r.returncode == 0

def mark_provisioned(lan_ip: str | None = None):
    st = load_state()
    st["provisioned"] = True
    if lan_ip:
        st["lan_ip"] = lan_ip
    save_state(st)

def current_state():
    return load_state()
