#!/usr/bin/env node
// Easy Relay Server — Socket.IO room-based relay
// Stateless, no DB. Connects two peers in a room and relays messages.
//
// Events:
//   → emit("join", { room })
//   ← on("joined", { room, peers })
//   ← on("peer_joined")
//   → emit("relay", payload)
//   ← on("relay", payload)
//   ← on("peer_left")
//   ← on("error_msg", { message })

const { Server } = require("socket.io");

const PORT = parseInt(process.env.PORT || "8080", 10);
const io = new Server(PORT, {
  pingInterval: 15000,
  pingTimeout: 10000,
});

io.on("connection", (socket) => {
  let currentRoom = null;

  socket.on("join", (data) => {
    const room = data.room;
    if (!room || typeof room !== "string") {
      socket.emit("error_msg", { message: "room is required" });
      return;
    }

    const clients = io.sockets.adapter.rooms.get(room);

    // 2-peer limit
    if (clients && clients.size >= 2) {
      socket.emit("error_msg", { message: "room is full" });
      return;
    }

    if (currentRoom) socket.leave(currentRoom);
    currentRoom = room;
    socket.join(room);

    // Notify existing peer
    socket.to(room).emit("peer_joined");
    socket.emit("joined", { room, peers: (clients?.size || 0) + 1 });

    // If peer already exists, notify the newcomer too
    if (clients && clients.size >= 1) {
      socket.emit("peer_joined");
    }
  });

  socket.on("relay", (payload) => {
    if (currentRoom) {
      socket.to(currentRoom).emit("relay", payload);
    }
  });

  socket.on("disconnecting", () => {
    if (currentRoom) {
      socket.to(currentRoom).emit("peer_left");
    }
  });
});

console.log(`Easy Relay running on port ${PORT} (Socket.IO)`);
