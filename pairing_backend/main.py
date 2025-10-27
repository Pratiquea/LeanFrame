import os, time, secrets, string, urllib.parse, requests
from typing import Dict
from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://rpi.local:8000")
CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID")
CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET")
REDIRECT_URI = os.getenv("GOOGLE_REDIRECT_URI", f"{PUBLIC_BASE_URL}/oauth2/callback")
SCOPE = os.getenv("GOOGLE_SCOPE", "https://www.googleapis.com/auth/drive.readonly")

if not CLIENT_ID or not CLIENT_SECRET:
    raise RuntimeError("GOOGLE_CLIENT_ID/SECRET not configured")

app = FastAPI()
templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))

# Super-simple in-memory store: { code -> {"status": "pending"|"ready", "token": {...}, "folder_id": "id"} }
PAIR_STORE: Dict[str, dict] = {}

def urlsafe_state(n=32):
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))

@app.post("/v1/pair/init")
def pair_init(payload: dict):
    code = payload.get("code")
    if not code:
        raise HTTPException(400, "code required")
    PAIR_STORE.setdefault(code, {"status": "pending", "created_at": time.time()})
    return {"status": "ok"}

@app.get("/v1/pair/{code}")
def pair_status(code: str):
    entry = PAIR_STORE.get(code)
    if not entry:
        return {"status": "pending"}  # not registered yet
    if entry.get("status") == "ready":
        return {
            "status": "ready",
            "folder_id": entry["folder_id"],
            "token": entry["token"],
        }
    return {"status": "pending"}

@app.get("/pair", response_class=HTMLResponse)
def pair_page(request: Request, code: str):
    # Register code if not present
    PAIR_STORE.setdefault(code, {"status": "pending", "created_at": time.time()})
    return templates.TemplateResponse("pair.html", {"request": request, "code": code, "public_base": PUBLIC_BASE_URL})

@app.get("/oauth2/start")
def oauth2_start(code: str):
    # We’ll stash the requested pairing code in the OAuth state and round-trip it.
    state = code + ":" + urlsafe_state(8)
    params = {
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
        "include_granted_scopes": "true",
    }
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(params)
    return RedirectResponse(auth_url)

@app.get("/oauth2/callback", response_class=HTMLResponse)
def oauth2_callback(request: Request, code: str, state: str):
    # Extract pairing code from state
    if ":" not in state:
        raise HTTPException(400, "invalid state")
    pairing_code = state.split(":")[0]

    # Exchange code for tokens
    data = {
        "code": code,
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "redirect_uri": REDIRECT_URI,
        "grant_type": "authorization_code",
    }
    token_resp = requests.post("https://oauth2.googleapis.com/token", data=data, timeout=15)
    if token_resp.status_code != 200:
        raise HTTPException(400, f"token exchange failed: {token_resp.text}")
    token_json = token_resp.json()
    # token_json includes access_token, expires_in, refresh_token (if offline), scope, token_type

    # List folders so the user can pick one (first 200 folders)
    headers = {"Authorization": f"Bearer {token_json['access_token']}"}
    # Drive v3 search for folders
    q = "mimeType='application/vnd.google-apps.folder' and trashed=false"
    list_url = "https://www.googleapis.com/drive/v3/files"
    params = {"q": q, "fields": "files(id,name),nextPageToken", "pageSize": 200}
    drive_resp = requests.get(list_url, headers=headers, params=params, timeout=15)
    if drive_resp.status_code != 200:
        raise HTTPException(400, f"drive list failed: {drive_resp.text}")
    folders = drive_resp.json().get("files", [])

    # Stash token temporarily in memory keyed by pairing code until user picks a folder
    entry = PAIR_STORE.setdefault(pairing_code, {"status": "pending"})
    entry["temp_token"] = token_json

    return templates.TemplateResponse("folders.html", {"request": request, "code": pairing_code, "folders": folders})

@app.post("/complete", response_class=HTMLResponse)
def complete(request: Request, code: str = Form(...), folder_id: str = Form(...)):
    entry = PAIR_STORE.get(code)
    if not entry or "temp_token" not in entry:
        raise HTTPException(400, "no active pairing")
    entry["token"] = entry.pop("temp_token")
    entry["folder_id"] = folder_id
    entry["status"] = "ready"
    return HTMLResponse("<h3>All set! You can close this tab.</h3>")
