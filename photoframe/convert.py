import subprocess, shutil
from pathlib import Path

def convert_image(src: Path, dst: Path, convert_bin="convert"):
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([convert_bin, str(src), str(dst)], check=True)

def convert_video(src: Path, dst: Path, ffmpeg="ffmpeg", vcodec="libx264", crf=23):
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([ffmpeg, '-y', '-i', str(src), '-c:v', vcodec, '-crf', str(crf), '-c:a', 'aac', str(dst)], check=True)