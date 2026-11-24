#!/usr/bin/env python3
"""
風格蒸餾 (Style Distillation) — 只擷取 YouTube 頻道「音檔」，不做畫面。

用途：把某個頻道/影片的「聲音風格」蒸餾成可分析的素材（語速、音調、停頓、
能量分布、詞頻），而不是下載整支影片。

輸出結構：
  <out>/<channel>/<NN>_<id>.mp3        音檔（bestaudio, 無影片）
  <out>/<channel>/index.json           清單 + 基本資訊
  <out>/<channel>/style.json           風格特徵（若有 ffprobe/分析）

用法：
  python tools/style_distill.py "https://www.youtube.com/@TheValley101" --limit 5
  python tools/style_distill.py "https://www.youtube.com/@kellytsaii" --limit 5
  python tools/style_distill.py <影片URL> --limit 1
"""

import argparse
import json
import os
import re
import subprocess
import sys

# Windows 主控台預設 cp950，中文標題會 UnicodeEncodeError → 強制 UTF-8 輸出
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

COOKIES = os.path.expandvars(r"C:\Users\CPXru\Desktop\yt_cookies.txt")
DEFAULT_OUT = os.path.expandvars(r"C:\Users\CPXru\Music\playlist-admin\style-distill")


def run(cmd, timeout=1800):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                          encoding="utf-8", errors="replace")


def list_entries(url, cookies, limit):
    """用 --flat-playlist 取清單（快，不下載）。"""
    cmd = [sys.executable, "-m", "yt_dlp", "--flat-playlist",
           "--print", "%(id)s\t%(title)s\t%(duration)s",
           "--cookies", cookies, url]
    if limit:
        cmd += ["--playlist-end", str(limit)]
    r = run(cmd, timeout=300)
    out = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0].strip():
            dur = 0
            if len(parts) >= 3:
                try:
                    dur = int(float(parts[2]))
                except ValueError:
                    dur = 0
            out.append({"id": parts[0].strip(), "title": parts[1].strip(), "duration": dur})
    return out


def safe(name, maxlen=80):
    name = re.sub(r'[\\/:*?"<>|]', "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:maxlen]


def download_audio(vid_id, out_path, cookies):
    """只下載音檔：bestaudio → mp3，絕對不抓影片流。"""
    cmd = [sys.executable, "-m", "yt_dlp",
           "-f", "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best",
           "-x", "--audio-format", "mp3", "--audio-quality", "0",
           "--no-playlist",
           "--no-overwrites",
           "--no-check-certificates",
           "--embed-thumbnail",           # 封面寫進 mp3 tag（不是影片畫面）
           "--embed-metadata",
           "--add-header", "Accept-Language:zh-TW,zh;q=0.9,en;q=0.5",
           "--cookies", cookies,
           "-o", out_path,
           f"https://www.youtube.com/watch?v={vid_id}"]
    return run(cmd, timeout=1800)


def probe(path):
    """ffprobe 取基本音訊特徵（若可用）。"""
    try:
        r = run(["ffprobe", "-v", "quiet", "-print_format", "json",
                 "-show_format", "-show_streams", path], timeout=60)
        if r.returncode != 0:
            return {}
        d = json.loads(r.stdout)
        st = next((s for s in d.get("streams", []) if s.get("codec_type") == "audio"), {})
        fmt = d.get("format", {})
        return {
            "codec": st.get("codec_name"),
            "sample_rate": int(st.get("sample_rate", 0) or 0),
            "channels": st.get("channels"),
            "bit_rate": int(st.get("bit_rate", 0) or 0),
            "duration": float(fmt.get("duration", 0) or 0),
        }
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url", help="頻道 / 播放清單 / 影片 URL")
    ap.add_argument("--limit", type=int, default=5, help="最多處理幾支（0=全部）")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--cookies", default=COOKIES)
    ap.add_argument("--dry-run", action="store_true", help="只列出清單，不下載")
    args = ap.parse_args()

    if not os.path.exists(args.cookies):
        print(f"[ERR] 找不到 cookies: {args.cookies}")
        return 1

    # 頻道/清單名稱 → 資料夾
    m = re.search(r"@([^/]+)", args.url)
    channel = safe(m.group(1)) if m else "distill"
    outdir = os.path.join(args.out, channel)
    os.makedirs(outdir, exist_ok=True)

    print(f"[1/3] 列出清單: {args.url}")
    entries = list_entries(args.url, args.cookies, args.limit)
    if not entries:
        print("[ERR] 清單是空的（可能需要 cookies 或 URL 有誤）")
        return 1
    # 頻道 URL 不支援 --playlist-end，這裡再自行截斷
    if args.limit and len(entries) > args.limit:
        entries = entries[:args.limit]
    print(f"      共 {len(entries)} 支")

    if args.dry_run:
        for i, e in enumerate(entries, 1):
            print(f"  {i:02d}. {e['id']}  {e['title'][:70]}")
        return 0

    index = []
    print(f"[2/3] 下載音檔 → {outdir}")
    for i, e in enumerate(entries, 1):
        name = f"{i:02d}_{e['id']}"
        dst = os.path.join(outdir, name + ".mp3")
        if os.path.exists(dst) and os.path.getsize(dst) > 4096:
            print(f"  [{i}/{len(entries)}] 已存在，跳過: {name}")
            info = {"index": i, "id": e["id"], "title": e["title"],
                    "file": name + ".mp3", "skipped": True}
            index.append(info)
            continue
        print(f"  [{i}/{len(entries)}] {e['title'][:60]}")
        r = download_audio(e["id"], dst, args.cookies)
        if r.returncode != 0 or not os.path.exists(dst):
            tail = (r.stderr or "").strip().splitlines()
            print(f"      ✗ 失敗: {tail[-1][:100] if tail else 'unknown'}")
            continue
        info = {"index": i, "id": e["id"], "title": e["title"],
                "duration_src": e["duration"], "file": name + ".mp3"}
        info.update(probe(dst))
        index.append(info)

    # 寫入 index.json（原子寫入，避免 0-byte）
    idx_path = os.path.join(outdir, "index.json")
    tmp_path = idx_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, idx_path)

    print(f"[3/3] 完成：{len(index)} 筆 → {outdir}")
    print("      下一步可用 whisper 轉逐字稿做「文字風格」分析，")
    print("      或用 librosa 做「聲音風格」（音調/語速/能量）分析。")
    return 0


if __name__ == "__main__":
    sys.exit(main())