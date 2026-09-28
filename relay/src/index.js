import { DurableObject } from "cloudflare:workers";

// Jam Relay v2 — 規格化協議（與 lib/services/jam_service.dart 的 _onMessage 對齊）。
// v1 是無腦轉發原始訊息，客戶端吃的是 normalized 型別（chat_item/playback/
// queue_update/skip_count/progress），雙方對不上 → 聊天、播放、投票全壞。
// v2：Durable Object 持有房間真相（佇列/播放狀態/跳過票），廣播規格化訊息。

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/jam") {
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("Jam Relay", { status: 426 });
      }
      const id = env.JAM_ROOMS.idFromName("jam-relay");
      return env.JAM_ROOMS.get(id).fetch(request);
    }
    if (url.pathname === "/health") return new Response("ok");
    return new Response("Jam Relay v2");
  },
};

export class JamRoom extends DurableObject {
  constructor(state, env) {
    super(state, env);
    this.clients = new Map(); // ws -> {id, name, isHost}（喚醒時從 attachment 重建）
    this.roomCode = "";
    this.rs = this._empty();
    this.skipVoters = new Set(); // 目前這首的跳過票（member id）
    this._hydrated = false;
  }

  // ---------- 持久化 ----------
  // Hibernation API（acceptWebSocket）會在 DO 休眠時清空建構期記憶體；
  // 只放 this 的話，喚醒後 clients.get(ws)=undefined → 所有訊息靜默丟棄（殭屍房）。
  // 修法：房間狀態存 ctx.storage、每支 socket 身分存 serializeAttachment、
  // 喚醒時 getWebSockets() 重建登錄。
  async _ensureHydrated() {
    if (this._hydrated) return;
    this._hydrated = true;
    try {
      const saved = await this.ctx.storage.get("room");
      if (saved) {
        this.rs = saved.rs || this._empty();
        this.roomCode = saved.roomCode || "";
        this.skipVoters = new Set(saved.skipVoters || []);
      }
    } catch {}
    for (const ws of this.ctx.getWebSockets()) {
      try {
        const info = ws.deserializeAttachment();
        if (info) this.clients.set(ws, info);
      } catch {}
    }
  }

  _persist() {
    return this.ctx.storage.put("room", {
      rs: this.rs,
      roomCode: this.roomCode,
      skipVoters: [...this.skipVoters],
    });
  }

  _persistSoon() {
    try { this.ctx.waitUntil(this._persist()); } catch {}
  }

  _empty() {
    return {
      code: "", members: [], queue: [], current: null,
      playing: false, time: 0, ts: 0, chat: [],
      skipVotes: 0, skipNeeded: 1,
    };
  }

  async fetch(request) {
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws, raw) {
    await this._ensureHydrated();
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    const t = msg.type;

    // ---------- 建房：乾淨重置（踢舊連線，不繼承舊房狀態） ----------
    if (t === "create") {
      const olds = [...this.clients.keys()];
      this.clients.clear();
      this.skipVoters.clear();
      this.rs = this._empty();
      for (const old of olds) {
        try { old.close(1000, "new room"); } catch {}
      }
      this.roomCode = this._genCode();
      const mid = this._genId();
      const name = msg.name || "我";
      const info = { id: mid, name, isHost: true };
      this.clients.set(ws, info);
      try { ws.serializeAttachment(info); } catch {}
      this.rs.code = this.roomCode;
      this.rs.members = [{ id: mid, name, isHost: true }];
      ws.send(JSON.stringify({ type: "welcome", yourId: mid, state: { ...this.rs } }));
      this._persistSoon();
      return;
    }

    // ---------- 加入 ----------
    if (t === "join") {
      if (this.roomCode === "" ||
          (msg.code || "").toUpperCase().trim() !== this.roomCode) {
        ws.send(JSON.stringify({ type: "error", message: "房間代碼錯誤" }));
        return;
      }
      if (this.clients.size >= 30) {
        ws.send(JSON.stringify({ type: "error", message: "房間已滿" }));
        return;
      }
      const mid = this._genId();
      const name = msg.name || "你";
      const m = { id: mid, name, isHost: false };
      this.clients.set(ws, m);
      try { ws.serializeAttachment(m); } catch {}
      this.rs.members.push(m);
      ws.send(JSON.stringify({ type: "welcome", yourId: mid, state: { ...this.rs } }));
      this._broadcast({ type: "member_joined", member: m }, ws);
      this._recalcSkipNeeded();
      this._bcastSkipCount();
      this._persistSoon();
      return;
    }

    let info = this.clients.get(ws);
    if (!info) {
      // 喚醒後第一封（getWebSockets 漏登錄時）：身分從 attachment 補回。
      try { info = ws.deserializeAttachment(); } catch {}
      if (!info) return;
      this.clients.set(ws, info);
    }

    try {
      switch (t) {
      // ---------- 聊天：格式化名字前綴、存歷史、排除送信者（已本地回聲） ----------
      case "chat": {
        const text = (msg.text || "").toString().trim();
        if (!text) return;
        const item = { text: `${info.name}：${text}`, ts: Date.now() };
        this.rs.chat.push(item);
        if (this.rs.chat.length > 100) this.rs.chat.shift();
        this._broadcast({ type: "chat_item", item }, ws);
        return;
      }

      // ---------- 佇列：DO 持有真相 ----------
      case "add": {
        const tr = msg.track && typeof msg.track === "object" ? { ...msg.track } : {};
        if (!tr.id) tr.id = "t-" + Math.random().toString(36).slice(2, 10);
        tr.addedBy = info.name;
        tr.votes = 0;
        if (!tr.kind) tr.kind = "stream";
        this.rs.queue.push(tr);
        this._bcast({ type: "queue_update", queue: this.rs.queue });
        return;
      }

      case "vote": {
        const tr = this.rs.queue.find((x) => x.id === msg.trackId);
        if (!tr) return;
        tr.votes = Math.max(0, (tr.votes || 0) + (msg.delta || 0));
        this._bcast({ type: "queue_update", queue: this.rs.queue });
        return;
      }

      case "remove": {
        if (!info.isHost) return;
        this.rs.queue = this.rs.queue.filter((x) => x.id !== msg.trackId);
        this._bcast({ type: "queue_update", queue: this.rs.queue });
        return;
      }

      // ---------- 播放狀態：任何人可控制，DO 定時戳、廣播 playback ----------
      case "play": {
        this.rs.playing = true;
        if (typeof msg.pos === "number") this.rs.time = msg.pos;
        this.rs.ts = Date.now();
        this._bcast({ type: "playback", playing: true, pos: this.rs.time, ts: this.rs.ts });
        return;
      }

      case "pause": {
        // 成員按暫停沒帶 pos（他不能當真相）：用房主上次進度 + 流逝時間推算。
        let pos = this.rs.time;
        if (typeof msg.pos === "number") pos = msg.pos;
        else if (this.rs.playing) pos = this.rs.time + (Date.now() - this.rs.ts);
        this.rs.playing = false;
        this.rs.time = pos;
        this.rs.ts = Date.now();
        this._bcast({ type: "playback", playing: false, pos, ts: this.rs.ts });
        return;
      }

      case "seek": {
        this.rs.time = msg.pos || 0;
        this.rs.ts = Date.now();
        this._bcast({ type: "progress", pos: this.rs.time, ts: this.rs.ts });
        return;
      }

      case "progress": {
        // 房主每 4s 推一次真實進度（pause 推算、斷線重連都靠它）。
        if (!info.isHost) return;
        this.rs.time = msg.pos || 0;
        this.rs.ts = msg.ts || Date.now();
        return;
      }

      // ---------- 換歌：房主廣播、清跳過票、排除送信者（房主已本地播放） ----------
      case "track_change": {
        if (!info.isHost) return;
        this.rs.current = msg.current || null;
        this.rs.playing = msg.playing ?? true;
        this.rs.time = msg.pos || 0;
        this.rs.ts = msg.ts || Date.now();
        this.skipVoters.clear();
        this.rs.skipVotes = 0;
        this._bcastSkipCount();
        this._broadcast({
          type: "track_change",
          current: this.rs.current,
          playing: this.rs.playing,
          pos: this.rs.time,
          ts: this.rs.ts,
        }, ws);
        return;
      }

      case "next": {
        if (!info.isHost) return;
        this._advance();
        return;
      }

      case "prev": {
        if (!info.isHost) return;
        this.rs.time = 0;
        this.rs.ts = Date.now();
        this._bcast({ type: "progress", pos: 0, ts: this.rs.ts });
        return;
      }

      // ---------- 跳過投票：DO 計票，達標自動接下一首 ----------
      case "skip_vote": {
        this.skipVoters.add(info.id);
        this.rs.skipVotes = this.skipVoters.size;
        this._recalcSkipNeeded();
        if (this.skipVoters.size >= this.rs.skipNeeded) {
          this.skipVoters.clear();
          this.rs.skipVotes = 0;
          this._bcastSkipCount();
          this._advance();
        } else {
          this._bcastSkipCount();
        }
        return;
      }
      }
    } finally {
      // 每封訊息後持久化（含 no-op）：休眠前狀態一定已落盤。
      this._persistSoon();
    }
  }

  // 取出「非當前曲」的第一首 → 通知房主解析 audioUrl 後播放（relay 不會解析網址）。
  // current 會留在佇列（UI 高亮靠 id 比對），所以不能無腦 shift。
  _advance() {
    const curId = this.rs.current ? this.rs.current.id : null;
    const idx = this.rs.queue.findIndex((x) => x.id !== curId);
    if (idx === -1) {
      // 沒有下一首：停（房主與成員一起停，別讓 rs.playing 停在 true）。
      if (this.rs.playing) {
        this.rs.playing = false;
        this.rs.ts = Date.now();
        this._bcast({
          type: "playback", playing: false, pos: this.rs.time, ts: this.rs.ts,
        });
      }
      return;
    }
    const [track] = this.rs.queue.splice(idx, 1);
    this._bcast({ type: "queue_update", queue: this.rs.queue });
    for (const [peer, i] of this.clients) {
      if (i.isHost) {
        try { peer.send(JSON.stringify({ type: "host_next", track })); } catch {}
        return;
      }
    }
  }

  _recalcSkipNeeded() {
    this.rs.skipNeeded = Math.max(1, Math.ceil(this.rs.members.length / 2));
  }

  _bcastSkipCount() {
    this._bcast({ type: "skip_count", count: this.rs.skipVotes, needed: this.rs.skipNeeded });
  }

  async webSocketClose(ws) { await this._ensureHydrated(); await this._remove(ws); }
  async webSocketError(ws) { await this._ensureHydrated(); await this._remove(ws); }

  async _remove(ws) {
    let info = this.clients.get(ws);
    if (!info) {
      // 休眠喚醒後的 close：登記可能還沒重建，從 attachment 補。
      try { info = ws.deserializeAttachment(); } catch {}
    }
    if (!info) return; // 已被新房間踢除
    this.clients.delete(ws);
    this.skipVoters.delete(info.id);
    this.rs.skipVotes = this.skipVoters.size;
    this.rs.members = this.rs.members.filter((m) => m.id !== info.id);

    if (this.rs.members.length === 0) {
      this.rs = this._empty();
      this.roomCode = "";
      this.skipVoters.clear();
      this._persistSoon();
      return;
    }

    if (info.isHost) {
      // 房主斷線：第一個成員接任（clients、attachment、rs 三處同步，
      // 否則 relay 找不到新房主 / 喚醒後 isHost 丟失）。
      const succ = this.rs.members[0];
      succ.isHost = true;
      for (const [peer, i] of this.clients) {
        if (i.id === succ.id) {
          i.isHost = true;
          try { peer.serializeAttachment(i); } catch {}
        }
      }
      this._bcast({ type: "promoted", memberId: succ.id });
    }
    this._recalcSkipNeeded();
    this._bcast({ type: "member_left", memberId: info.id });
    this._bcastSkipCount();
    this._persistSoon();
  }

  _broadcast(msg, exclude) {
    const data = JSON.stringify(msg);
    for (const [ws] of this.clients) {
      if (ws !== exclude) try { ws.send(data); } catch {}
    }
  }

  _bcast(msg) { this._broadcast(msg); }

  _genCode() {
    const c = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    let r = "";
    for (let i = 0; i < 6; i++) r += c[Math.floor(Math.random() * c.length)];
    return r;
  }

  _genId() {
    return Math.random().toString(36).slice(2, 10);
  }
}
