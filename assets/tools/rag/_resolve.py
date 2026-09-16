"""Resolve podcast RAG paths from the app config (same as the CLI/GUI)."""
import json
import os
import platform
from pathlib import Path


def _is_wsl() -> bool:
    """偵測是否在 WSL 中執行。"""
    if "microsoft" in platform.release().lower():
        return True
    if os.path.exists("/proc/sys/fs/binfmt_misc/WSLInterop"):
        return True
    return False


def _win_to_wsl(path: Path) -> Path:
    """將 Windows 路徑轉為 WSL /mnt/c/... 路徑。"""
    s = str(path)
    if len(s) >= 2 and s[1] == ":":
        drive = s[0].lower()
        rest = s[2:].replace("\\", "/")
        return Path(f"/mnt/{drive}{rest}")
    return path


def find_base() -> Path:
    env_bp = os.environ.get("BASE_PATH")
    if env_bp:
        bp = Path(env_bp)
        if _is_wsl():
            bp = _win_to_wsl(bp)
        return bp

    # WSL：優先 HOME/Music 推導，寫死的個人路徑只當最後 fallback。
    if _is_wsl():
        home_music = Path.home() / "Music" / "playlist-admin"
        if home_music.exists():
            return home_music
        try:
            hits = sorted(Path("/mnt/c/Users").glob("*/Music/playlist-admin"))
            if hits:
                return hits[0]
        except Exception:
            pass
        return Path("/mnt/c/Users/CPXru/Music/playlist-admin")

    # Windows: 讀 config.json
    local = os.environ.get("LOCALAPPDATA")
    pointer = None
    if local:
        pointer = Path(local) / "playlist-admin" / "data" / "config.json"
        if not pointer.exists():
            pointer = Path(local) / "Playlist Administrator" / "data" / "config.json"
    try:
        if pointer and pointer.exists():
            # utf-8-sig：BOM 檔用 utf-8 讀會讓 json.loads 炸掉。
            data = json.loads(pointer.read_text(encoding="utf-8-sig"))
            bp = data.get("base_path") or data.get("basePath")
            if bp:
                return Path(bp)
    except Exception:
        pass
    return Path(r"C:\Users\CPXru\Music\playlist-admin")


def podcast_downloads_dir() -> Path:
    return find_base() / "podcasts"


def rag_data_dir() -> Path:
    return find_base() / "cache" / "podcast"


def chroma_db_dir() -> Path:
    return rag_data_dir() / "chroma_db"