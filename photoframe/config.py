from dataclasses import dataclass
from pathlib import Path
import yaml
from typing import Optional, List, Dict, Any

@dataclass
class ScreenCfg:
    width: int
    height: int
    fullscreen: bool = True
    cursor_hidden: bool = True

@dataclass
class PlaybackCfg:
    default_image_seconds: float = 12.0
    shuffle: bool = True
    loop: bool = True
    resume_on_start: bool = True
    transitions_crossfade: bool = True
    crossfade_ms: int = 350

@dataclass
class PathsCfg:
    library: Path
    import_dir: Path
    state: Path
    db: Path

@dataclass
class ServerCfg:
    host: str = "0.0.0.0"
    port: int = 8765
    auth_token: str = "change-me"
    max_upload_mb: int = 512
    allow_extensions: list[str] = None

@dataclass
class ConvertCfg:
    enabled: bool = True
    ffmpeg_bin: str = "ffmpeg"
    imagemagick_convert_bin: str = "convert"
    target_image_format: str = "jpg"
    target_video_format: str = "mp4"
    video_codec: str = "libx264"
    crf: int = 23

@dataclass
class IndexerCfg:
    watch: bool = True
    recursive: bool = True
    ignore_hidden: bool = True

@dataclass
class SyncRcloneJob:
    name: str
    remote: str
    include_ext: List[str] | None = None
    dest_subdir: str = "remote"
    one_way: bool = True

@dataclass
class SyncRcloneCfg:
    bin: str = "rclone"
    jobs: List[SyncRcloneJob] = None

@dataclass
class SyncCfg:
    enabled: bool = False
    mode: str = "off"            # "rclone" | "photos_api" | "off"
    interval_minutes: int = 10
    rclone: SyncRcloneCfg | None = None
    photos_api: Dict[str, Any] | None = None

@dataclass
class AppCfg:
    screen: ScreenCfg
    playback: PlaybackCfg
    paths: PathsCfg
    server: ServerCfg
    conversion: ConvertCfg
    indexer: IndexerCfg
    sync: SyncCfg | None = None

    @staticmethod
    def load(path: Path) -> "AppCfg":
        data = yaml.safe_load(Path(path).read_text())

        screen = ScreenCfg(**data["screen"])

        pb = dict(data.get("playback", {}))
        transitions = pb.pop("transitions", {}) or {}
        playback = PlaybackCfg(
            **pb,
            transitions_crossfade=bool(transitions.get("crossfade", True)),
            crossfade_ms=int(transitions.get("crossfade_ms", 350)),
        )

        p = data["paths"]
        paths = PathsCfg(
            library=Path(p["library"]).expanduser(),
            import_dir=Path(p["import"]).expanduser(),
            state=Path(p["state"]).expanduser(),
            db=Path(p["db"]).expanduser(),
        )
        print(f"[config] library path: {paths.library}")

        server = ServerCfg(**data["server"])
        conversion = ConvertCfg(**data["conversion"])
        indexer = IndexerCfg(**data["indexer"])

        # sync block
        sync_block = data.get("sync")
        if sync_block:
            mode = sync_block.get("mode", "off")
            # rclone sub-block
            rclone_block = sync_block.get("rclone")
            rclone_cfg = None
            if rclone_block:
                jobs = [
                    SyncRcloneJob(**j)
                    for j in (rclone_block.get("jobs") or [])
                ]
                rclone_cfg = SyncRcloneCfg(
                    bin=rclone_block.get("bin", "rclone"),
                    jobs=jobs
                )
            sync_cfg = SyncCfg(
                enabled=bool(sync_block.get("enabled", False)),
                mode=mode,
                interval_minutes=int(sync_block.get("interval_minutes", 10)),
                rclone=rclone_cfg,
                photos_api=sync_block.get("photos_api")
            )
        else:
            sync_cfg = SyncCfg(enabled=False, mode="off", interval_minutes=10)

        return AppCfg(
            screen=screen,
            playback=playback,
            paths=paths,
            server=server,
            conversion=conversion,
            indexer=indexer,
            sync=sync_cfg,   
        )
