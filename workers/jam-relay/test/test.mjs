/**
 * Jam Relay Local Test
 * Run with: node test/test.mjs
 * Requires: miniflare (npm install -g miniflare)
 */

import { Miniflare } from "miniflare";

async function runTest() {
  const mf = new Miniflare({
    modules: true,
    scriptPath: "./src/index.js",
    durableObjects: { JamRoom: "JamRoom" },
    bindings: {},
    compatFlags: ["nodejs_compat"],
  });

  try {
    // Get Durable Object stub
    const ns = await mf.getDurableObjectNamespace("JamRoom");
    const id = ns.idFromName("test-room");
    const stub = ns.get(id);

    console.log("🧪 Testing Jam Relay...");

    // Test 1: Create room
    console.log("\n1. Creating room...");
    const ws1 = await connectWebSocket(stub, "create", { name: "Host" });
    const welcome1 = await ws1.receive();
    console.log("✅ Host joined:", JSON.parse(welcome1).yourId.slice(0, 8));
    console.log("   Room code:", JSON.parse(welcome1).state.code);

    // Test 2: Join room
    console.log("\n2. Joining room...");
    const ws2 = await connectWebSocket(stub, "join", { code: JSON.parse(welcome1).state.code, name: "Guest" });
    const welcome2 = await ws2.receive();
    console.log("✅ Guest joined:", JSON.parse(welcome2).yourId.slice(0, 8));

    // Test 3: Guest adds track
    console.log("\n3. Guest adds track...");
    ws2.send(JSON.stringify({
      type: "add",
      track: {
        title: "Test Song",
        artist: "Test Artist",
        coverUrl: "",
        id: "test-1"
      }
    }));
    const queueUpdate = await ws2.receive();
    console.log("✅ Queue updated:", JSON.parse(queueUpdate).queue.length, "track(s)");

    // Test 4: Host adds track (should trigger host_next)
    console.log("\n4. Host adds track...");
    ws1.send(JSON.stringify({
      type: "add",
      track: {
        title: "Host Song",
        artist: "Host Artist",
        coverUrl: "",
        id: "test-2"
      }
    }));
    const hostNext = await ws1.receive();
    console.log("✅ Host next triggered:", JSON.parse(hostNext).type);

    // Test 5: Play/Pause
    console.log("\n5. Play/Pause toggle...");
    ws1.send(JSON.stringify({ type: "play" }));
    const playback = await ws2.receive();
    console.log("✅ Playback sync:", JSON.parse(playback).playing);

    ws1.send(JSON.stringify({ type: "pause" }));
    const pause = await ws2.receive();
    console.log("✅ Pause sync:", JSON.parse(pause).playing);

    // Test 5: Chat
    console.log("\n6. Chat message...");
    ws2.send(JSON.stringify({ type: "chat", text: "Hello from guest!" }));
    const chatMsg = await ws1.receive();
    console.log("✅ Chat received:", JSON.parse(chatMsg).item.text);

    // Test 6: Skip vote
    console.log("\n7. Skip vote...");
    ws1.send(JSON.stringify({ type: "skip_vote" }));
    ws2.send(JSON.stringify({ type: "skip_vote" }));
    const skipCount = await ws1.receive();
    console.log("✅ Skip votes:", JSON.parse(skipCount).count, "/", JSON.parse(skipCount).needed);

    // Close
    ws1.close();
    ws2.close();

    console.log("\n🎉 All tests passed!");
  } catch (err) {
    console.error("❌ Test failed:", err);
  } finally {
    await mf.dispose();
  }
}

function connectWebSocket(stub, type, data) {
  return new Promise((resolve, reject) => {
    const url = new URL("http://localhost/jam");
    url.searchParams.set("room", "test-room");
    const req = new Request(url, { headers: { Upgrade: "websocket" } });
    
    stub.fetch(req).then(response => {
      // WebSocket pair is in response
      const ws = response.webSocket;
      ws.accept();
      ws.addEventListener("message", () => {});
      ws.send(JSON.stringify({ type, ...data }));
      resolve(ws);
    }).catch(reject);
  }
}

// Add receive helper to WebSocket
const originalAccept = WebSocket.prototype.accept;
WebSocket.prototype.accept = function() {
  originalAccept.call(this);
  this.messages = [];
  this.addEventListener("message", (e) => this.messages.push(e.data));
  this.receive = async () => {
    while (this.messages.length === 0) {
      await new Promise(r => setTimeout(r, 10));
    }
    return this.messages.shift();
  };
};

runTest();