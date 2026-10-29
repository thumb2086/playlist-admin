/**
 * Jam Relay - Cloudflare Worker + Durable Object
 * 
 * WebSocket relay for "一起聽" (Spotify Jam clone) feature.
 * Handles room creation, joining, state sync, and message routing.
 * 
 * Protocol (all JSON):
 * - create: { type: "create", name: "host name" }
 * - join: { type: "join", code: "6-char", name: "guest name" }
 * - add: { type: "add", track: {...} }
 * - remove: { type: "remove", trackId: "..." }
 * - play/pause: { type: "play"|"pause", pos: ms }
 * - seek: { type: "seek", pos: ms }
 * - next/prev: { type: "next"|"prev" }
 * - skip_vote: { type: "skip_vote" }
 * - chat: { type: "chat", text: "..." }
 * - vote: { type: "vote", trackId, delta: -1|0|1 }
 * 
 * Server messages:
 * - welcome: { type: "welcome", yourId, state }
 * - member_joined/member_left
 * - track_change, playback, progress, queue_update
 * - skip_count, chat_item, host_next, promoted
 * - search_results, search_error, error
 */

export class JamRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sessions = new Map(); // ws -> { id, name, isHost }
    this.roomCode = "";
    this.hostId = "";
    this.queue = [];
    this.current = null;
    this.playing = false;
    this.positionMs = 0;
    this.ts = 0;
    this.members = [];
    this.chat = [];
    this.skipVotes = 0;
    this.skipNeeded = 0;
    this.votes = new Map(); // trackId -> Map(userId -> delta)
    this.searchId = 0;
    this.searchWaiters = new Map(); // reqId -> resolver
  }

  // Initialize room state from storage
  async initialize() {
    const stored = await this.state.storage.get("room");
    if (stored) {
      this.roomCode = stored.roomCode || "";
      this.hostId = stored.hostId || "";
      this.queue = stored.queue || [];
      this.current = stored.current || null;
      this.playing = stored.playing || false;
      this.positionMs = stored.positionMs || 0;
      this.ts = stored.ts || 0;
      this.members = stored.members || [];
      this.chat = stored.chat || [];
      this.skipVotes = stored.skipVotes || 0;
      this.skipNeeded = stored.skipNeeded || 0;
    }
  }

  // Persist state to storage
  async persist() {
    await this.state.storage.put("room", {
      roomCode: this.roomCode,
      hostId: this.hostId,
      queue: this.queue,
      current: this.current,
      playing: this.playing,
      positionMs: this.positionMs,
      ts: this.ts,
      members: this.members,
      chat: this.chat,
      skipVotes: this.skipVotes,
      skipNeeded: this.skipNeeded,
    });
  }

  // Generate 6-char room code
  generateCode() {
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no I/O/0/1
    let code = "";
    for (let i = 0; i < 6; i++) {
      code += chars[Math.floor(Math.random() * chars.length)];
    }
    return code;
  }

  // Broadcast to all sessions
  broadcast(msg, excludeId = null) {
    const data = JSON.stringify(msg);
    for (const [ws, session] of this.sessions) {
      if (session.id !== excludeId && ws.readyState === 1) {
        try { ws.send(data); } catch (_) {}
      }
    }
  }

  // Send to specific session
  send(ws, msg) {
    if (ws.readyState === 1) {
      try { ws.send(JSON.stringify(msg)); } catch (_) {}
    }
  }

  // Find session by WebSocket
  findSession(ws) {
    return this.sessions.get(ws);
  }

  // Find session by user ID
  findById(id) {
    for (const [ws, session] of this.sessions) {
      if (session.id === id) return { ws, session };
    }
    return null;
  }

  // Handle incoming WebSocket message
  async handleMessage(ws, raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (_) {
      return; // ignore malformed
    }

    const session = this.sessions.get(ws);
    const type = msg.type;

    switch (type) {
      case "create":
        await this.handleCreate(ws, msg);
        break;
      case "join":
        await this.handleJoin(ws, msg);
        break;
      case "add":
        await this.handleAdd(session, msg);
        break;
      case "remove":
        await this.handleRemove(session, msg);
        break;
      case "play":
      case "pause":
        await this.handlePlayPause(session, msg);
        break;
      case "seek":
        await this.handleSeek(session, msg);
        break;
      case "next":
        await this.handleNext(session);
        break;
      case "prev":
        await this.handlePrev(session);
        break;
      case "skip_vote":
        await this.handleSkipVote(session);
        break;
      case "chat":
        await this.handleChat(session, msg);
        break;
      case "vote":
        await this.handleVote(session, msg);
        break;
      case "search":
        await this.handleSearch(ws, msg);
        break;
      default:
        // ignore unknown
        break;
    }
  }

  async handleCreate(ws, msg) {
    const name = (msg.name || "我").slice(0, 32);
    const id = crypto.randomUUID();
    const code = this.generateCode();

    this.roomCode = code;
    this.hostId = id;
    this.members = [{ id, name, isHost: true }];
    this.queue = [];
    this.current = null;
    this.playing = false;
    this.positionMs = 0;
    this.ts = 0;
    this.chat = [];
    this.skipVotes = 0;
    this.skipNeeded = 0;
    this.votes.clear();

    this.sessions.set(ws, { id, name, isHost: true });

    await this.persist();

    this.send(ws, {
      type: "welcome",
      yourId: id,
      state: this.getState(),
    });
  }

  async handleJoin(ws, msg) {
    if (!this.roomCode) {
      this.send(ws, { type: "error", message: "房間不存在" });
      ws.close();
      return;
    }

    const code = (msg.code || "").toUpperCase().trim();
    if (code !== this.roomCode) {
      this.send(ws, { type: "error", message: "代碼錯誤" });
      ws.close();
      return;
    }

    const name = (msg.name || "我").slice(0, 32);
    const id = crypto.randomUUID();

    const member = { id, name, isHost: false };
    this.members.push(member);
    this.sessions.set(ws, { id, name, isHost: false });

    await this.persist();

    this.send(ws, {
      type: "welcome",
      yourId: id,
      state: this.getState(),
    });

    this.broadcast({ type: "member_joined", member });
  }

  getState() {
    return {
      code: this.roomCode,
      members: this.members,
      queue: this.queue,
      current: this.current,
      playing: this.playing,
      time: this.positionMs,
      ts: this.ts,
      chat: this.chat.slice(-50),
      skipVotes: this.skipVotes,
      skipNeeded: this.skipNeeded,
    };
  }

  async handleAdd(session, msg) {
    if (!session || session.isHost) {
      // 房主加歌走 hostAddTrack，這裡處理成員加歌
      if (session && session.isHost) return; // 房主已在前端處理
      if (!session) return;
    }

    const track = msg.track;
    if (!track || !track.title) return;

    const normalized = {
      id: track.id || `t-${Date.now().toString(16)}`,
      title: track.title,
      artist: track.artist || "",
      coverUrl: track.coverUrl || "",
      audioUrl: "", // 房主會解析
      addedBy: session.name,
      votes: 0,
    };

    this.queue.push(normalized);
    await this.persist();

    this.broadcast({ type: "queue_update", queue: this.queue });

    // 如果佇列原本空、也沒在播 → 通知房主播放
    if (this.queue.length === 1 && !this.current) {
      this.broadcast({ type: "host_next", track: normalized });
    }
  }

  async handleRemove(session, msg) {
    if (!session || !session.isHost) return;
    const trackId = msg.trackId;
    this.queue = this.queue.filter(t => t.id !== trackId);
    await this.persist();
    this.broadcast({ type: "queue_update", queue: this.queue });
  }

  async handlePlayPause(session, msg) {
    if (!session || !session.isHost) return;
    const playing = msg.type === "play";
    const pos = msg.pos ?? 0;

    this.playing = playing;
    this.positionMs = pos;
    this.ts = Date.now();
    await this.persist();

    this.broadcast({ type: "playback", playing, pos, ts: this.ts }, session.id);
  }

  async handleSeek(session, msg) {
    if (!session || !session.isHost) return;
    const pos = msg.pos ?? 0;
    this.positionMs = pos;
    this.ts = Date.now();
    await this.persist();
    this.broadcast({ type: "progress", pos, ts: this.ts }, session.id);
  }

  async handleNext(session) {
    if (!session || !session.isHost) return;
    this.broadcast({ type: "next" });
  }

  async handlePrev(session) {
    if (!session || !session.isHost) return;
    this.broadcast({ type: "prev" });
  }

  async handleSkipVote(session) {
    if (!session) return;
    this.skipVotes++;
    this.skipNeeded = Math.max(1, Math.ceil(this.members.length * 0.5));
    await this.persist();
    this.broadcast({ type: "skip_count", count: this.skipVotes, needed: this.skipNeeded });
  }

  async handleChat(session, msg) {
    if (!session) return;
    const text = (msg.text || "").trim();
    if (!text) return;
    const item = { text: `${session.name}：${text}`, ts: Date.now() };
    this.chat.push(item);
    if (this.chat.length > 100) this.chat.shift();
    await this.persist();
    this.broadcast({ type: "chat_item", item });
  }

  async handleVote(session, msg) {
    if (!session) return;
    const trackId = msg.trackId;
    const delta = msg.delta;
    if (!trackId || ![-1, 0, 1].includes(delta)) return;

    const userVotes = this.votes.get(trackId) || new Map();
    const cur = userVotes.get(session.id) || 0;
    const newDelta = cur === delta ? 0 : delta;
    userVotes.set(session.id, newDelta);
    this.votes.set(trackId, userVotes);

    // 計算總票數
    let total = 0;
    for (const v of userVotes.values()) total += v;

    // 更新佇列中的票數
    for (const t of this.queue) {
      if (t.id === trackId) {
        t.votes = total;
        break;
      }
    }
    await this.persist();
    this.broadcast({ type: "vote", trackId, delta: newDelta, total });
  }

  async handleSearch(ws, msg) {
    const query = (msg.query || "").trim();
    if (!query) return;

    const reqId = ++this.searchId;
    const waiter = new Promise((resolve) => {
      this.searchWaiters.set(reqId, resolve);
    });

    // Forward to all hosts (usually just one)
    this.broadcast({ type: "search", query, reqId });

    try {
      const results = await Promise.race([
        waiter,
        new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 8000)),
      ]);
      this.send(ws, { type: "search_results", reqId, items: results });
    } catch (_) {
      this.send(ws, { type: "search_error", reqId, message: "搜尋超時" });
    } finally {
      this.searchWaiters.delete(reqId);
    }
  }

  // Handle messages from host (search_results, host_next, etc.)
  async handleHostMessage(ws, msg) {
    const type = msg.type;
    if (type === "search_results") {
      const waiter = this.searchWaiters.get(msg.reqId);
      if (waiter) {
        waiter(msg.items);
        this.searchWaiters.delete(msg.reqId);
      }
    } else if (type === "host_next") {
      // Already handled by broadcast
    }
  }

  // Handle WebSocket close
  async handleClose(ws) {
    const session = this.sessions.get(ws);
    if (!session) return;

    this.sessions.delete(ws);

    // If host left, promote next member
    if (session.id === this.hostId) {
      const remaining = Array.from(this.sessions.values());
      if (remaining.length > 0) {
        const newHost = remaining[0];
        this.hostId = newHost.id;
        newHost.isHost = true;
        // Update member list
        for (const m of this.members) {
          if (m.id === newHost.id) m.isHost = true;
          else m.isHost = false;
        }
        await this.persist();
        this.broadcast({ type: "promoted", memberId: newHost.id });
      } else {
        // Room empty, cleanup
        this.state.storage.deleteAll();
      }
    } else {
      // Regular member left
      this.members = this.members.filter(m => m.id !== session.id);
      await this.persist();
      this.broadcast({ type: "member_left", memberId: session.id });
    }
  }

  // WebSocket handler
  async fetch(request) {
    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader !== "websocket") {
      return new Response("Expected WebSocket", { status: 400 });
    }

    const [client, server] = Object.values(new WebSocketPair());
    await this.initialize();

    server.accept();
    this.sessions.set(server, { id: "", name: "", isHost: false });

    server.addEventListener("message", (event) => {
      this.handleMessage(server, event.data);
    });

    server.addEventListener("close", () => {
      this.handleClose(server);
    });

    server.addEventListener("error", () => {
      this.handleClose(server);
    });

    return new Response(null, { status: 101, webSocket: client });
  }
}

export default {
  async fetch(request, env) {
    // Route to Durable Object
    const url = new URL(request.url);
    const roomName = url.searchParams.get("room") || "default";
    const id = env.ROOM.idFromName(roomName);
    const stub = env.ROOM.get(id);
    return stub.fetch(request);
  },
};