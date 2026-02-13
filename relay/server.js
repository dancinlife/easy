#!/usr/bin/env node
// Easy Relay Server — room-based WebSocket relay
// 무상태, DB 없음. 두 피어를 room으로 연결하고 메시지를 중계할 뿐.
//
// 프로토콜:
//   → { type: "join", room: "<uuid>" }
//   ← { type: "peer_joined" }           (상대방이 들어왔을 때)
//   → { type: "message", payload: ... }  (암호화된 데이터)
//   ← { type: "message", payload: ... }  (상대방에게 전달)
//   ← { type: "peer_left" }             (상대방이 나갔을 때)

const { WebSocketServer } = require("ws");

const PORT = parseInt(process.env.PORT || "8080", 10);
const wss = new WebSocketServer({ port: PORT });

// room → Set<ws>
const rooms = new Map();

// Heartbeat: detect dead connections (WiFi→LTE 등)
const HEARTBEAT_INTERVAL = 15000;
const heartbeat = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) {
      console.log("[Heartbeat] Terminating dead connection");
      ws.terminate();
      return;
    }
    ws.isAlive = false;
    ws.ping();
  });
}, HEARTBEAT_INTERVAL);

wss.on("close", () => clearInterval(heartbeat));

wss.on("connection", (ws) => {
  ws.isAlive = true;
  ws.on("pong", () => { ws.isAlive = true; });

  let currentRoom = null;

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      ws.send(JSON.stringify({ type: "error", message: "invalid JSON" }));
      return;
    }

    if (msg.type === "join") {
      const room = msg.room;
      if (!room || typeof room !== "string") {
        ws.send(JSON.stringify({ type: "error", message: "room is required" }));
        return;
      }

      // 이전 room에서 나가기
      if (currentRoom) leaveRoom(ws, currentRoom);

      currentRoom = room;
      if (!rooms.has(room)) rooms.set(room, new Set());
      const peers = rooms.get(room);

      if (peers.size >= 2) {
        // Evict dead connections before rejecting
        for (const peer of [...peers]) {
          if (peer.readyState !== 1 /* OPEN */) {
            console.log("[Room] Evicting non-OPEN peer");
            leaveRoom(peer, room);
            peer.terminate();
          }
        }
        if (peers.size >= 2) {
          // Force ping to detect stale TCP — evict non-responsive
          for (const peer of [...peers]) {
            try { peer.ping(); } catch {
              console.log("[Room] Evicting ping-failed peer");
              leaveRoom(peer, room);
              peer.terminate();
            }
          }
        }
        if (peers.size >= 2) {
          ws.send(JSON.stringify({ type: "error", message: "room is full" }));
          currentRoom = null;
          return;
        }
      }

      // 기존 피어에게 알림
      for (const peer of peers) {
        peer.send(JSON.stringify({ type: "peer_joined" }));
      }

      peers.add(ws);
      ws.send(JSON.stringify({ type: "joined", room, peers: peers.size }));

      // 새로 들어온 쪽에도 이미 피어가 있으면 알림
      if (peers.size === 2) {
        ws.send(JSON.stringify({ type: "peer_joined" }));
      }

      return;
    }

    if (msg.type === "message") {
      if (!currentRoom || !rooms.has(currentRoom)) {
        ws.send(JSON.stringify({ type: "error", message: "not in a room" }));
        return;
      }

      // payload를 상대 피어에게 그대로 전달
      const peers = rooms.get(currentRoom);
      for (const peer of peers) {
        if (peer !== ws && peer.readyState === 1) {
          peer.send(JSON.stringify({ type: "message", payload: msg.payload }));
        }
      }
      return;
    }
  });

  ws.on("close", () => {
    if (currentRoom) leaveRoom(ws, currentRoom);
  });

  ws.on("error", () => {
    if (currentRoom) leaveRoom(ws, currentRoom);
  });
});

function leaveRoom(ws, room) {
  const peers = rooms.get(room);
  if (!peers) return;

  peers.delete(ws);

  // 남은 피어에게 알림
  for (const peer of peers) {
    peer.send(JSON.stringify({ type: "peer_left" }));
  }

  if (peers.size === 0) rooms.delete(room);
}

console.log(`Easy Relay running on ws://0.0.0.0:${PORT}`);
