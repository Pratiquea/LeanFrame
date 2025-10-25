from dataclasses import dataclass
from pathlib import Path
import yaml

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
class AppCfg:
    screen: ScreenCfg
    playback: PlaybackCfg
    paths: PathsCfg
    server: ServerCfg
    conversion: ConvertCfg
    indexer: IndexerCfg

    @staticmethod
    def load(path: Path) -> "AppCfg":
        data = yaml.safe_load(Path(path).read_text())
        p = data["paths"]
        return AppCfg(
            screen=ScreenCfg(**data["screen"]),
            playback=PlaybackCfg(**data["playback"],
                                 transitions_crossfade=data["playback"]["transitions"]["crossfade"],
                                 crossfade_ms=data["playback"]["transitions"]["crossfade_ms"]),
            paths=PathsCfg(library=Path(p["library"]).expanduser(),
                           import_dir=Path(p["import"]).expanduser(),
                           state=Path(p["state"]).expanduser(),
                           db=Path(p["db"]).expanduser()),
            server=ServerCfg(**data["server"]),
            conversion=ConvertCfg(**data["conversion"]),
            indexer=IndexerCfg(**data["indexer"]),
        )