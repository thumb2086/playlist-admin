#!/usr/bin/env python3
"""
風格蒸餾 → 逐字稿 → RAG。

流程：
  1. 讀 style-distill/<channel>/*.mp3
  2. 用 ffmpeg 取「前 N 分鐘」當代表樣本（風格分析不需要整支 3 小時影片，
     而且 Workers STT 上限 100 MB，長檔直接切掉最省事）
  3. 走 CF 中轉 /v1/audio/transcriptions 轉逐字稿（RAG_TOKEN 認證）
  4. 寫進 podcasts/_風格_<channel>/<name>.txt（build_db.py 吃得這格式）
  5. 印出下一步指令

用法：
  python tools/style_rag.py                 # 全部頻道
  python tools/style_rag.py --minutes 20    # 每檔取前 20 分鐘
  python tools/style_rag.py --force         # 已有 txt 也重轉
"""
import argparse
import json
import os
import subprocess
import sys
import uuid
import urllib.request
import urllib.error

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

BASE = os.environ.get("PA_BASE", "https://groq.zixilive.dpdns.org")
SECRETS = os.path.expandvars(r"C:\Users\CPXru\.thumb-secrets")
MUSIC = os.path.expandvars(r"C:\Users\CPXru\Music\playlist-admin")
DISTILL = os.path.join(MUSIC, "style-distill")
PODCASTS = os.path.join(MUSIC, "podcasts")
TMP = os.path.expandvars(r"C:\Users\CPXru\AppData\Local\Temp\opencode\style_rag")
MODEL = os.environ.get("PA_STT_MODEL", "whisper-large-v3-turbo")
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0 Safari/537.36"


def token():
    p = os.path.join(SECRETS, "groq-router-ROUTER_TOKEN.txt")
    return open(p, encoding="utf-8").read().strip()


def ffmpeg_cut(src, dst, minutes):
    """取前 minutes 分鐘，降成 64k mono mp3（20 分鐘約 9 MB，遠低於 100 MB）。"""
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", src, "-t", str(minutes * 60),
        "-ac", "1", "-ar", "16000", "-b:a", "64k",
        dst,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    return r.returncode == 0 and os.path.exists(dst) and os.path.getsize(dst) > 1024


def transcribe(path, tok):
    boundary = "----pa" + uuid.uuid4().hex
    name = os.path.basename(path)
    pre = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="model"\r\n\r\n{MODEL}\r\n'
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="response_format"\r\n\r\nverbose_json\r\n'
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f"Content-Type: audio/mpeg\r\n\r\n"
    ).encode()
    body = pre + open(path, "rb").read() + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        BASE + "/v1/audio/transcriptions",
        data=body,
        headers={
            "Content-Type": "multipart/form-data; boundary=" + boundary,
            "User-Agent": UA,
            "Authorization": "Bearer " + tok,
            "X-API-Key": tok,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=1800) as r:
        return json.loads(r.read().decode())


def safe(s):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in s)[:60]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=20)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    os.makedirs(TMP, exist_ok=True)
    tok = token()
    if not tok:
        print("[ERR] 沒有 ROUTER_TOKEN")
        return 1

    channels = sorted(d for d in os.listdir(DISTILL) if os.path.isdir(os.path.join(DISTILL, d)))
    if not channels:
        print("[ERR] style-distill 沒有頻道資料夾，先跑 tools/style_distill.py")
        return 1

    total = ok = 0
    for ch in channels:
        src_dir = os.path.join(DISTILL, ch)
        out_dir = os.path.join(PODCASTS, "_風格_" + safe(ch))
        os.makedirs(out_dir, exist_ok=True)
        mp3s = sorted(f for f in os.listdir(src_dir) if f.lower().endswith(".mp3"))
        print(f"\n=== {ch} ({len(mp3s)} 檔) ===")
        for f in mp3s:
            total += 1
            stem = os.path.splitext(f)[0]
            txt = os.path.join(out_dir, stem + ".txt")
            if os.path.exists(txt) and os.path.getsize(txt) > 200 and not args.force:
                print(f"  跳過（已有）: {stem}")
                ok += 1
                continue
            src = os.path.join(src_dir, f)
            clip = os.path.join(TMP, safe(ch) + "_" + stem + ".mp3")
            print(f"  切前 {args.minutes} 分鐘: {f}")
            if not ffmpeg_cut(src, clip, args.minutes):
                print(f"    ✗ ffmpeg 失敗，跳過")
                continue
            mb = os.path.getsize(clip) / 1048576
            print(f"    取樣 {mb:.1f} MB → 轉寫中…")
            try:
                d = transcribe(clip, tok)
            except urllib.error.HTTPError as e:
                print(f"    ✗ STT HTTP {e.code}: {e.read().decode()[:160]}")
                continue
            except Exception as e:
                print(f"    ✗ STT 失敗: {e}")
                continue
            text = (d.get("text") or "").strip()
            if not text:
                print("    ✗ 回傳空文字")
                continue
            with open(txt, "w", encoding="utf-8") as fh:
                fh.write(text)
            print(f"    ✓ {len(text)} 字 → {os.path.basename(txt)}")
            ok += 1
            try:
                os.remove(clip)
            except Exception:
                pass

    print(f"\n完成：{ok}/{total} 檔有逐字稿")
    print("下一步建 RAG 索引：")
    print(r"  python rag\build_db.py")
    print("查詢：")
    print(r'  python rag\query.py "風格 語速 停頓" --topk 3')
    return 0


if __name__ == "__main__":
    sys.exit(main())
