# LeanFrame

### 1) Install
```bash
sudo apt-get update
sudo apt-get install -y git python3-venv ffmpeg mpv
git clone <this-repo> && cd leanframe
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
cp config/leanframe.yaml.example config/leanframe.yaml  # edit as needed
```

### 2) Put media
```
mkdir -p data/library/images data/library/videos
```
copy JPG/PNG/WEBP to images/, MP4/MOV/MKV to videos/

### 3) Run
```
python -m photoframe
```
The viewer will take over the screen. The API will listen on http://0.0.0.0:8765.

### 4) Autostart
```
sudo ./scripts/create_systemd.sh
```

### 5) Uploads (Android/iOS)

Open the Flutter app in mobile/ with Android Studio or Xcode, build, and set the server URL (e.g. http://<frame-ip>:8765). Use the token from config/leanframe.yaml.

## Notes
* For best fluidity, ensure mpv is installed; videos will play hardware-accelerated on many SBCs.
* To resume at boot, the app writes data/state.json after each item.
* Inspired by Immich & photOS: we focus on on-device simplicity and low memory.
---

## Inspiration & future enhancements
- Optional thumbnail grid (secondary route) rendered with lightweight caching.
- Web UI for upload (PWA) so the mobile app becomes optional.
- Per-photo JSON sidecars to override `duration` and `transition`.
- WebSocket push updates when new media arrives; hot‑reload playlist.
- Blurhash/LQIP preload for snappier fades.
- On‑device HEIC→JPEG conversion via libheif if needed.
ad (PWA) so the mobile app becomes optional.
- Per-photo JSON sidecars to override `duration` and `transition`.
- WebSocket push updates when new media arrives; hot‑reload playlist.
- Blurhash/LQIP preload for snappier fades.
- On‑device HEIC→JPEG conversion via libheif if needed.
