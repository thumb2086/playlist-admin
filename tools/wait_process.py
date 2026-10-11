# -*- coding: utf-8 -*-
"""等待 playlist-admin（或其他 PID）結束 —— 背景長任務的正確等待器。

為什麼需要：PowerShell 的 `& $exe > log 2>&1` 丟背景時，shell 會**立刻**
回報「完成」，但 exe 其實還在跑。於是主控以為任務結束、開始驗證/發版，
全都對不上（2026-10-12 踩過）。

用法：
    $p = Start-Process -FilePath <exe> -NoNewWindow -PassThru
    python tools/wait_process.py <pid> [log路徑]

行為：每 30 秒檢查 PID 存活；存活時印一行進度；行程結束才 exit 0，
並印出 log 最後幾行 —— 這個「完成」才是真的。
"""
import io
import os
import subprocess
import sys
import time

INTERVAL = 30
TAIL = 8


def alive(pid):
    r = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "if (Get-Process -Id %d -ErrorAction SilentlyContinue)"
         " {'Y'} else {'N'}" % pid],
        capture_output=True, text=True, timeout=20)
    return "Y" in (r.stdout or "")


def _cp950_safe(s):
    """Windows console 是 cp950：不可編碼字元（emoji、中日韓、俄文）換成 ?，
    否則 print 會 UnicodeEncodeError 讓等待器自己掛掉。"""
    enc = sys.stdout.encoding or "cp950"
    return s.encode(enc, errors="replace").decode(enc, errors="replace")


def tail(path, n=TAIL):
    try:
        with io.open(path, encoding="utf-8", errors="replace") as fh:
            lines = [l.rstrip() for l in fh if l.strip()]
        return lines[-n:]
    except Exception:
        return []


def main():
    if len(sys.argv) < 2:
        print("usage: wait_process.py <pid> [logfile]")
        return 2
    pid = int(sys.argv[1])
    log = sys.argv[2] if len(sys.argv) > 2 else None

    print("watching pid=%d%s"
          % (pid, (" log=%s" % log) if log else ""), flush=True)
    t0 = time.time()
    ticks = 0
    while alive(pid):
        time.sleep(INTERVAL)
        ticks += 1
        print("  %5.0fs  still running (pid=%d)" % (time.time() - t0, pid),
              flush=True)

    print("DONE pid=%d after %.0fs" % (pid, time.time() - t0), flush=True)
    if log and os.path.exists(log):
        print("--- log tail ---", flush=True)
        for line in tail(log):
            # Windows console 是 cp950，印 emoji/生僻字會 UnicodeEncodeError
            print("  " + _cp950_safe(line), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())