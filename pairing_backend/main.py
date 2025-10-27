import os, time, urllib.parse, re, requests
from typing import Optional, Dict, Any
from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(__file__)
load_dotenv(os.path.join(BASE_DIR, ".env"))

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://rpi.local:8000")
CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET", "")
SCOPE = os.getenv("GOOGLE_SCOPE", "https://www.googleapis.com/auth/drive.readonly")

if not CLIENT_ID:
    raise RuntimeError("Set GOOGLE_CLIENT_ID in pairing_backend/.env")

app = FastAPI()
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

# Single-device in-memory state (no pairing code needed)
STORE: Dict[str, Any] = {
    # "device": {...}, "token": {...}, "folder_id": "id", "status": "pending|waiting_for_folder|ready"
}
DEVICE_KEY = "singleton"

DEVICE_CODE_URL = "https://oauth2.googleapis.com/device/code"
TOKEN_URL = "https://oauth2.googleapis.com/token"

def now() -> float:
    return time.time()

def extract_folder_id(s: str) -> Optional[str]:
    s = s.strip()
    # 1) Bare-looking ID (33+ chars, letters/numbers/_-)
    if re.fullmatch(r"[A-Za-z0-9_-]{20,}", s):
        return s
    # 2) URL with id=...
    m = re.search(r"[?&]id=([A-Za-z0-9_-]{20,})", s)
    if m:
        return m.group(1)
    # 3) /folders/<id>
    m = re.search(r"/folders/([A-Za-z0-9_-]{20,})", s)
    if m:
        return m.group(1)
    return None

def reset_device_flow():
    STORE.clear()

def device_flow_active() -> bool:
    dev = STORE.get("device")
    if not dev:
        return False
    return dev.get("expires_at", 0) > now()

def device_flow_issue():
    # Request a new device_code
    data = {
        "client_id": CLIENT_ID,
        "scope": SCOPE,
    }
    r = requests.post(DEVICE_CODE_URL, data=data, timeout=15)
    r.raise_for_status()
    payload = r.json()
    interval = payload.get("interval", 5)
    expires_in = payload["expires_in"]
    STORE["device"] = {
        "device_code": payload["device_code"],
        "user_code": payload["user_code"],
        "verification_url": payload["verification_url"],   # often https://www.google.com/device
        "interval": interval,
        "issued_at": now(),
        "expires_at": now() + expires_in,
        "last_poll": 0.0,
    }
    STORE["status"] = "pending"

def try_poll_token():
    # Respect Google's polling interval
    dev = STORE.get("device")
    if not dev:
        return
    if now() < dev.get("last_poll", 0) + dev.get("interval", 5):
        return
    dev["last_poll"] = now()

    data = {
        "client_id": CLIENT_ID,
        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        "device_code": dev["device_code"],
    }
    # The secret is OPTIONAL for installed-app clients; include if you created a Web client
    if CLIENT_SECRET:
        data["client_secret"] = CLIENT_SECRET

    r = requests.post(TOKEN_URL, data=data, timeout=15)
    if r.status_code == 200:
        token = r.json()
        # Expect refresh_token in response (after user completes)
        STORE["token"] = token
        STORE["status"] = "waiting_for_folder"
        return

    # 400 with various errors is typical while waiting
    try:
        err = r.json().get("error")
    except Exception:
        err = "unknown_error"
    if err in ("authorization_pending", "slow_down"):
        return
    if err == "expired_token":
        # user took too long; reset
        reset_device_flow()
        return
    # any other error -> reset
    reset_device_flow()

@app.get("/pair", response_class=HTMLResponse)
def pair_page(request: Request):
    # Ensure we have a live device flow
    if not device_flow_active():
        reset_device_flow()
        device_flow_issue()
    # Opportunistic poll (page is refreshable)
    try_poll_token()

    status = STORE.get("status", "pending")
    dev = STORE.get("device", {})
    user_code = dev.get("user_code")
    verification_url = dev.get("verification_url")

    if status == "pending":
        return templates.TemplateResponse(
            "pair_device_code.html",
            {"request": request, "verification_url": verification_url, "user_code": user_code}
        )
    elif status == "waiting_for_folder":
        return templates.TemplateResponse(
            "enter_folder.html",
            {"request": request}
        )
    elif status == "ready":
        return HTMLResponse("<h3>All set! You can close this tab.</h3>")
    else:
        return HTMLResponse("<h3>Initializing… reload in a second.</h3>")

@app.post("/pair/folder", response_class=HTMLResponse)
def pair_folder_submit(request: Request, folder_input: str = Form(...)):
    fid = extract_folder_id(folder_input)
    if not fid:
        raise HTTPException(400, "Couldn't parse a valid Google Drive folder ID or URL.")
    if STORE.get("status") != "waiting_for_folder" or "token" not in STORE:
        raise HTTPException(400, "Not ready to accept a folder yet.")
    STORE["folder_id"] = fid
    STORE["status"] = "ready"
    return HTMLResponse("<h3>Folder saved — you can close this tab.</h3>")

# Device scripts poll here
@app.get("/v1/pair", response_model=dict)
def pair_status():
    status = STORE.get("status", "pending")
    if status == "ready":
        return {
            "status": "ready",
            "folder_id": STORE.get("folder_id"),
            "token": STORE.get("token"),
        }
    return {"status": status}
