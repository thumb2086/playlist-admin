# -*- coding: utf-8 -*-
"""Jam relay v2 全協議 E2E：真實 Cloudflare relay，A=房主、B=成員、C=第三端。
全部走 normalized 協議（chat_item/playback/queue_update/skip_count/progress/
host_next/promoted/member_left）。失敗即 exit 1。"""
import asyncio, json, sys
import websockets

RELAY = "wss://jam-relay.cpxru83.workers.dev/jam"
FAILS = []

def check(name, cond, detail=""):
    mark = "PASS" if cond else "FAIL"
    if not cond:
        FAILS.append(name)
    safe = detail.encode("ascii", "replace").decode()
    print("[%s] %s %s" % (mark, name.encode("ascii", "replace").decode(), safe), flush=True)

async def take(ws, timeout=6):
    """收下一封（不論型別）。"""
    try:
        async with asyncio.timeout(timeout):
            async for raw in ws:
                try:
                    return json.loads(raw)
                except Exception:
                    continue
    except asyncio.TimeoutError:
        return None
    return None

async def expect(ws, typ, timeout=6, exclude=()):
    """一直收到 typ 為止（其他型別當雜訊跳過）；超時回 None。"""
    try:
        async with asyncio.timeout(timeout):
            async for raw in ws:
                try:
                    m = json.loads(raw)
                except Exception:
                    continue
                if m.get("type") == typ:
                    return m
                # 雜訊：跳過繼續等目標
    except asyncio.TimeoutError:
        return None
    return None

async def main():
    a = await websockets.connect(RELAY, open_timeout=15)
    await a.send(json.dumps({"type": "create", "name": "hostA"}))
    m = await expect(a, "welcome")
    check("1 建房 welcome", m and m.get("type") == "welcome")
    code = m["state"]["code"]

    b = await websockets.connect(RELAY, open_timeout=15)
    await b.send(json.dumps({"type": "join", "code": code, "name": "guestB"}))
    mb = await expect(b, "welcome")
    check("2 加入 welcome(2人)", mb and len(mb["state"]["members"]) == 2)
    ma = await expect(a, "member_joined")
    check("3 房主收到 member_joined", ma and ma.get("type") == "member_joined")
    # join 附帶 skip_count 廣播
    ms = await expect(a, "skip_count")
    check("3b join 廣播 skip_count(0/1)", ms and ms.get("count") == 0 and ms.get("needed") == 1)

    # ---- 聊天 ----
    await a.send(json.dumps({"type": "chat", "text": "hi all"}))
    mc = await expect(b, "chat_item")
    check("4 房主聊天 → 成員 chat_item",
          mc and mc.get("type") == "chat_item"
          and mc["item"]["text"].startswith("hostA："), str(mc))

    # ---- 加歌 ×2（模擬房主解析後的與成員沒解析的） ----
    t1 = {"id": "t1", "title": "Song1", "artist": "Art", "audioUrl": "https://x/1.m4a", "votes": 0}
    t2 = {"id": "t2", "title": "Song2", "artist": "Art", "audioUrl": "", "votes": 0}
    await a.send(json.dumps({"type": "add", "track": t1}))
    q1 = await expect(a, "queue_update")
    check("5a 房主加歌 → 雙方 queue_update", q1 and len(q1["queue"]) == 1
          and q1["queue"][0]["addedBy"] == "hostA")
    await b.send(json.dumps({"type": "add", "track": t2}))
    q2 = await expect(a, "queue_update")
    check("5b 成員加歌 → queue_update(addedBy=guestB)",
          q2 and len(q2["queue"]) == 2 and q2["queue"][1]["addedBy"] == "guestB")

    # ---- 開播 ----
    await a.send(json.dumps({"type": "track_change", "current": t1,
                             "playing": True, "pos": 0, "ts": 1}))
    mt = await expect(b, "track_change")
    check("6 track_change → 成員(含 audioUrl)",
          mt and mt.get("current", {}).get("audioUrl") == "https://x/1.m4a")

    await a.send(json.dumps({"type": "play", "pos": 5000}))
    mp = await expect(a, "playback")  # 讀 A：先清掉自己的 play 回聲，7b 才會讀到 pause
    check("7a 房主 play → playback(playing,pos=5000)",
          mp and mp.get("playing") is True and mp.get("pos") == 5000)

    # ---- 成員控制：pause（不帶 pos，relay 用房主進度推算） ----
    await b.send(json.dumps({"type": "pause"}))
    mp2 = await expect(a, "playback")
    check("7b member pause -> playback(false, pos>=5000)",
          mp2 and mp2.get("playing") is False
          and isinstance(mp2.get("pos"), int) and mp2.get("pos") >= 5000,
          json.dumps(mp2))

    # ---- 投票 ----
    await b.send(json.dumps({"type": "vote", "trackId": "t2", "delta": 1}))
    mv = await expect(a, "queue_update")
    check("8 投票 → queue_update(votes=1)",
          mv and any(x["id"] == "t2" and x["votes"] == 1 for x in mv["queue"]))

    # ---- 跳過投票：2 人 needed=1 → 達標自動接下一首 ----
    await b.send(json.dumps({"type": "skip_vote"}))
    msk = await expect(a, "skip_count")
    # 達標流程：先廣播 0（重置）再 _advance → queue_update → host_next
    mq = await expect(a, "queue_update")
    mh = await expect(a, "host_next")
    check("9 達標跳過 → 房主收到 host_next(Song2)",
          mh and mh.get("track", {}).get("title") == "Song2",
          "skip_count=%s queue_len=%s" % (
              msk and msk.get("count"), mq and len(mq["queue"])))

    # 房主確認 host_next → 播 t2
    await a.send(json.dumps({"type": "track_change", "current": t2,
                             "playing": True, "pos": 0, "ts": 2}))
    mt2 = await expect(b, "track_change", exclude=("skip_count",))
    check("10 房主接播 t2 → 成員收到", mt2 and mt2.get("type") == "track_change")

    # ---- next：佇列只剩 t1(current=t2, t1≠current) ----
    await a.send(json.dumps({"type": "next"}))
    mh2 = await expect(a, "host_next")
    check("11 next → host_next(Song1)", mh2 and mh2.get("track", {}).get("title") == "Song1")

    # ---- prev：廣播 progress pos=0 ----
    await a.send(json.dumps({"type": "prev"}))
    mpr = await expect(b, "progress", exclude=("queue_update", "host_next", "track_change"))
    check("12 prev → progress(pos=0)", mpr and mpr.get("type") == "progress" and mpr.get("pos") == 0)

    # ---- 錯誤碼 ----
    c = await websockets.connect(RELAY, open_timeout=15)
    await c.send(json.dumps({"type": "join", "code": "ZZZZZZ", "name": "x"}))
    me = await expect(c, "error")
    check("13 錯誤碼 → error", me and me.get("type") == "error")

    # ---- 房主斷線 → 成員接任（relay 先 promoted 後 member_left） ----
    await a.close()
    mprom = await expect(b, "promoted")
    mleft = await expect(b, "member_left")
    check("14 房主斷線 → member_left + promoted",
          mleft and mprom and mprom.get("memberId") == mb["yourId"],
          "left=%s promoted=%s" % (mleft and mleft.get("type"), mprom and mprom.get("type")))

    # ---- 接任者可以驅動 next（relay 的 isHost 同步） ----
    # 佇列現為空（t1 被 next 拿走了）→ 先加一首
    await b.send(json.dumps({"type": "add", "track": {"id": "t9", "title": "S9"}}))
    # b 自己會收到 queue_update；先清掉
    await expect(b, "queue_update")
    await b.send(json.dumps({"type": "next"}))
    mh3 = await expect(b, "host_next")
    check("15 接任房主 next → host_next", mh3 and mh3.get("track", {}).get("id") == "t9")

    # ---- b 離開 → 房間清空 ----
    await b.close()
    await c.close()
    # 新建房間代碼應可用（房間已重置）
    d = await websockets.connect(RELAY, open_timeout=15)
    await d.send(json.dumps({"type": "join", "code": code, "name": "late"}))
    mlate = await expect(d, "error")
    check("16 清空後舊碼失效 → error", mlate and mlate.get("type") == "error")
    await d.close()

    print("\n===> %d FAIL, %d checks total" % (len(FAILS), 16))
    if FAILS:
        print("failed:", ", ".join(FAILS))
    return 1 if FAILS else 0

if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
