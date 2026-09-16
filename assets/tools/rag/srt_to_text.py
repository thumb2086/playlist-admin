"""把沒有對應 .txt 的 .srt 字幕轉成 .txt (去除時間軸)，供向量庫補索引
用法: python rag/srt_to_txt.py
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _resolve import podcast_downloads_dir


def read_srt(srt_path: Path) -> str:
    """讀檔：utf-8-sig → utf-8 → big5 → gb18030，和 build_db 同順序。
    舊寫法只試 utf-8-sig，Big5 繁中字幕直接亂碼進庫。"""
    raw = srt_path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "big5", "gb18030"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def srt_to_text(srt_path: Path) -> str:
    text = read_srt(srt_path)
    # 移除 srt 索引行 (純數字行)
    text = re.sub(r"^\d+\s*$", "", text, flags=re.MULTILINE)
    # 移除時間軸行 (00:00:00,000 --> 00:00:01,000)
    text = re.sub(
        r"\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{3}",
        "",
        text,
    )
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines)


def main() -> None:
    root = podcast_downloads_dir()
    converted = 0
    for srt in sorted(root.rglob("*.srt")):
        name = srt.name
        if ".zh-TW.srt" in name or ".zh-Hans.srt" in name or ".zh-Hant.srt" in name:
            continue
        txt = srt.with_suffix(".txt")
        if txt.exists():
            continue
        try:
            content = srt_to_text(srt)
        except Exception as e:
            print(f"!! 失敗 {srt.name}: {e}")
            continue
        txt.write_text(content, encoding="utf-8")
        print(f"轉換: {srt.parent.name}/{srt.stem[:50]}")
        converted += 1
    print(f"完成! 轉換 {converted} 個 srt -> txt")


if __name__ == "__main__":
    main()