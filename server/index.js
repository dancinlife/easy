#!/usr/bin/env node
// Easy Server — Claude Code Voice Relay (Node.js)
// Runs on Mac. E2E encrypted communication with iPhone Easy app via Relay.
//
// Install: npm install -g easy-server
// Run: easy --relay wss://your-relay.fly.dev

const crypto = require("crypto");
const { execSync, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");
const WebSocket = require("ws");
const readline = require("readline");

// ─── Config ───

const CONFIG_DIR = path.join(os.homedir(), ".easy");
const CONFIG_FILE = path.join(CONFIG_DIR, "config.json");
const IDENTITY_FILE = path.join(CONFIG_DIR, "identity.json");

const DEFAULT_RELAY = "wss://easy-production-18f7.up.railway.app";

// ─── Args ───

const args = process.argv.slice(2);
const forceNew = args.includes("--new");

let relayURL = DEFAULT_RELAY;
const relayIdx = args.indexOf("--relay");
if (relayIdx !== -1 && args[relayIdx + 1]) {
  relayURL = args[relayIdx + 1];
}

if (args.includes("--help") || args.includes("-h")) {
  console.log(`Easy — Claude Code Voice Interface

Usage:
  easy                          Start with default relay
  easy --relay <url>            Specify custom relay server
  easy --new                    Generate new pairing key
  easy --help                   Show help`);
  process.exit(0);
}

// ─── Setup / Config ───

function ensureConfigDir() {
  if (!fs.existsSync(CONFIG_DIR)) {
    fs.mkdirSync(CONFIG_DIR, { recursive: true });
  }
}

function loadConfig() {
  ensureConfigDir();
  if (fs.existsSync(CONFIG_FILE)) {
    try {
      return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    } catch {
      return {};
    }
  }
  return {};
}

function saveConfig(config) {
  ensureConfigDir();
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
}

// ─── Identity (Curve25519 ECDH) ───

function loadOrCreateIdentity() {
  ensureConfigDir();

  if (!forceNew && fs.existsSync(IDENTITY_FILE)) {
    try {
      const data = JSON.parse(fs.readFileSync(IDENTITY_FILE, "utf8"));
      const privateKey = crypto.createPrivateKey({
        key: Buffer.from(data.privateKeyPkcs8, "base64"),
        format: "der",
        type: "pkcs8",
      });
      console.log("[Config] Loaded saved key");
      return { privateKey, room: data.room, publicKeyRaw: Buffer.from(data.publicKeyRaw, "base64") };
    } catch (e) {
      console.log("[Config] Failed to load saved key, generating new one");
    }
  }

  const { privateKey, publicKey } = crypto.generateKeyPairSync("x25519");
  const room = crypto.randomUUID();

  // raw public key (32 bytes)
  const publicKeyRaw = publicKey.export({ type: "spki", format: "der" }).slice(-32);
  const privateKeyPkcs8 = privateKey.export({ type: "pkcs8", format: "der" });

  const data = {
    privateKeyPkcs8: privateKeyPkcs8.toString("base64"),
    publicKeyRaw: publicKeyRaw.toString("base64"),
    room,
  };
  fs.writeFileSync(IDENTITY_FILE, JSON.stringify(data, null, 2));
  console.log("[Config] New key generated");

  return { privateKey, room, publicKeyRaw };
}

// ─── Crypto helpers ───

function base64url(buf) {
  return buf
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function fromBase64url(str) {
  let b64 = str.replace(/-/g, "+").replace(/_/g, "/");
  while (b64.length % 4) b64 += "=";
  return Buffer.from(b64, "base64");
}

function aesGcmEncrypt(plaintext, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  // combined: iv(12) + encrypted + tag(16)
  return Buffer.concat([iv, encrypted, tag]);
}

function aesGcmDecrypt(combined, key) {
  const iv = combined.slice(0, 12);
  const tag = combined.slice(-16);
  const encrypted = combined.slice(12, -16);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

function deriveSharedKey(privateKey, peerPublicKeyRaw) {
  // raw 32 bytes → SPKI DER format conversion
  const spkiPrefix = Buffer.from("302a300506032b656e032100", "hex");
  const spkiDer = Buffer.concat([spkiPrefix, peerPublicKeyRaw]);
  const peerPubKey = crypto.createPublicKey({ key: spkiDer, format: "der", type: "spki" });

  const shared = crypto.diffieHellman({ privateKey, publicKey: peerPubKey });

  // HKDF (SHA256, salt="easy-relay", info="key-exchange", 32bytes)
  // hkdfSync returns ArrayBuffer → explicit Uint8Array copy for safety
  const derived = crypto.hkdfSync(
    "sha256",
    shared,
    Buffer.from("easy-relay"),
    Buffer.from("key-exchange"),
    32
  );
  return Buffer.from(new Uint8Array(derived));
}

// ─── Claude (async spawn, serialized) ───

let claudeQueue = Promise.resolve();
const activeSessions = new Set(); // track already created sessions

function runClaude(question, sessionId) {
  const job = claudeQueue.then(async () => {
    const result = await _runClaudeOnce(question, sessionId);
    if (result === null && sessionId) {
      console.log("[Claude] Session failed — retrying without session");
      return _runClaudeOnce(question, null);
    }
    return result;
  });
  claudeQueue = job.catch(() => {});
  return job;
}

function _runClaudeOnce(question, sessionId) {
  return new Promise((resolve) => {
    const args = ["--print"];
    if (sessionId) {
      if (activeSessions.has(sessionId)) {
        args.push("--resume", sessionId);
      } else {
        args.push("--session-id", sessionId);
      }
    }
    args.push("--append-system-prompt", "You are being used via a voice interface (TTS). Keep responses concise and conversational. No markdown, no code blocks, no bullet points. Speak naturally as if talking to a developer. When explaining code changes, describe what you did briefly instead of showing code.");
    args.push(question);

    console.log(`[Claude] claude ${args.join(" ").slice(0, 100)}`);

    const child = spawn("claude", args, {
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ""}`,
      },
    });

    child.stdin.end();

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (data) => { stdout += data.toString(); });
    child.stderr.on("data", (data) => { stderr += data.toString(); });

    const timer = setTimeout(() => {
      console.log("[Claude] Timeout: 120s exceeded, killing process");
      child.kill("SIGTERM");
      resolve(null);
    }, 120_000);

    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        console.log(`[Claude] Error: exit=${code} stderr=${stderr.slice(0, 200)}`);
      } else if (sessionId) {
        activeSessions.add(sessionId);
      }
      const answer = stdout.trim();
      resolve(answer || null);
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      console.log(`[Claude] Error: ${err.message}`);
      resolve(null);
    });
  });
}

function shellEscape(str) {
  return "'" + str.replace(/'/g, "'\\''") + "'";
}

// ─── QR Code ───

function printQR(text) {
  try {
    const qr = require("qrcode-terminal");
    qr.generate(text, { small: true }, (code) => console.log(code));
  } catch {
    console.log("[QR display failed — npm install qrcode-terminal]");
  }
}

// ─── Relay Connector ───

class RelayConnector {
  constructor(relayURL, room, privateKey, publicKeyRaw) {
    this.relayURL = relayURL;
    this.room = room;
    this.privateKey = privateKey;
    this.publicKeyRaw = publicKeyRaw;
    this.sessionKey = null;
    this.ws = null;
  }

  connect() {
    console.log(`[Relay] Connecting: ${this.relayURL}`);
    if (this.pingInterval) clearInterval(this.pingInterval);
    this.ws = new WebSocket(this.relayURL);

    this.ws.on("open", () => {
      console.log("[Relay] WebSocket connected");
      this.send({ type: "join", room: this.room });
      // Keep alive with ping every 15s
      this.pingInterval = setInterval(() => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.ping();
        }
      }, 15000);
    });

    this.ws.on("message", (raw) => {
      try {
        const str = raw.toString();
        const msg = JSON.parse(str);
        if (msg.type !== "message" || !msg.payload?.type?.startsWith("key_exchange")) {
          console.log(`[WS recv] type=${msg.type} payload.type=${msg.payload?.type || "N/A"} (${str.length}bytes)`);
        }
        this.handleMessage(msg);
      } catch (err) {
        console.log(`[WS parse error] ${err.message} raw=${raw.toString().slice(0, 100)}`);
      }
    });

    this.ws.on("close", () => {
      console.log("[Relay] Disconnected, reconnecting in 3s...");
      if (this.pingInterval) clearInterval(this.pingInterval);
      this.sessionKey = null;
      setTimeout(() => this.connect(), 3000);
    });

    this.ws.on("error", (err) => {
      console.log(`[Relay] Error: ${err.message}`);
    });
  }

  send(obj) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
    }
  }

  handleMessage(msg) {
    switch (msg.type) {
      case "joined":
        console.log(`[Relay] Joined room (peers: ${msg.peers || 0})`);
        break;
      case "peer_joined":
        console.log("[Relay] iPhone connected!");
        break;
      case "peer_left":
        console.log("[Relay] iPhone disconnected");
        this.sessionKey = null;
        break;
      case "message":
        if (msg.payload) this.handlePayload(msg.payload);
        break;
      case "error":
        console.log(`[Relay] Error: ${msg.message}`);
        break;
    }
  }

  handlePayload(payload) {
    switch (payload.type) {
      case "key_exchange":
        this.handleKeyExchange(payload);
        break;
      case "ask_text":
        this.handleAskText(payload);
        break;
      case "session_end":
        this.handleSessionEnd(payload);
        break;
      case "key_exchange_ack":
        break;
    }
  }

  handleKeyExchange(payload) {
    try {
      const peerPubRaw = fromBase64url(payload.publicKey);
      const encryptedData = fromBase64url(payload.encryptedSessionKey);

      console.log(`[KeyExchange] peerPub: ${peerPubRaw.length}bytes, encrypted: ${encryptedData.length}bytes`);

      const derivedKey = deriveSharedKey(this.privateKey, peerPubRaw);

      console.log(`[KeyExchange] derivedKey: ${derivedKey.slice(0, 8).toString("hex")}... (${derivedKey.length}bytes)`);
      console.log(`[KeyExchange] encData nonce: ${encryptedData.slice(0, 12).toString("hex")}`);

      const sessionKeyData = aesGcmDecrypt(encryptedData, derivedKey);
      this.sessionKey = sessionKeyData;

      console.log(`[KeyExchange] sessionKey: ${sessionKeyData.slice(0, 8).toString("hex")}... (${sessionKeyData.length}bytes)`);
      console.log("[Relay] Key exchange complete — E2E encryption active");
      this.send({ type: "message", payload: { type: "key_exchange_ack" } });

      // Send server_info
      this.sendServerInfo();
    } catch (err) {
      console.log(`[Error] Key exchange failed: ${err.message}`);
      console.log(`[Error] Stack: ${err.stack?.split("\n").slice(0, 3).join(" | ")}`);
    }
  }

  sendServerInfo() {
    if (!this.sessionKey) return;
    try {
      const info = { type: "server_info", workDir: process.cwd(), hostname: os.hostname() };
      const plain = Buffer.from(JSON.stringify(info));
      const encrypted = aesGcmEncrypt(plain, this.sessionKey);
      this.send({ type: "message", payload: { type: "server_info", encrypted: base64url(encrypted) } });
      console.log(`[Relay] server_info sent: workDir=${info.workDir} hostname=${info.hostname}`);
    } catch (err) {
      console.log(`[Error] server_info send failed: ${err.message}`);
    }
  }

  sendSessionEnd(sessionId) {
    if (!this.sessionKey) return;
    try {
      const plain = Buffer.from(JSON.stringify({ sessionId }));
      const encrypted = aesGcmEncrypt(plain, this.sessionKey);
      this.send({ type: "message", payload: { type: "session_end", encrypted: base64url(encrypted) } });
      console.log(`[Relay] session_end sent: ${sessionId}`);
    } catch (err) {
      console.log(`[Error] session_end send failed: ${err.message}`);
    }
  }

  sendShutdown() {
    if (!this.sessionKey) return;
    // End all active sessions first
    for (const sid of activeSessions) {
      this.sendSessionEnd(sid);
    }
    try {
      const plain = Buffer.from(JSON.stringify({ type: "server_shutdown" }));
      const encrypted = aesGcmEncrypt(plain, this.sessionKey);
      this.send({ type: "message", payload: { type: "server_shutdown", encrypted: base64url(encrypted) } });
      console.log("[Relay] server_shutdown sent");
    } catch (err) {
      console.log(`[Error] server_shutdown send failed: ${err.message}`);
    }
  }

  async handleAskText(payload) {
    if (!this.sessionKey) {
      console.log("[Error] No session key — ignoring ask_text");
      return;
    }

    try {
      const encryptedData = fromBase64url(payload.encrypted);
      const plainData = aesGcmDecrypt(encryptedData, this.sessionKey);
      const json = JSON.parse(plainData.toString());

      const text = json.text;
      const sessionId = json.sessionId ? json.sessionId.toLowerCase() : null;

      console.log(`[Question] "${text}" (session: ${sessionId || "none"})`);

      // Run Claude
      console.log("[Claude] Running...");
      const answer = (await runClaude(text, sessionId)) || "Error: claude execution failed";
      console.log(`[Answer] ${answer.slice(0, 100)}${answer.length > 100 ? "..." : ""}`);

      // Send response
      this.sendTextAnswer(answer);
      console.log("[Done] Response sent");
    } catch (err) {
      console.log(`[Error] Text processing failed: ${err.message}`);
      try {
        this.sendTextAnswer(`Error: ${err.message}`);
      } catch {}
    }
  }

  handleSessionEnd(payload) {
    if (!this.sessionKey) return;
    try {
      const encryptedData = fromBase64url(payload.encrypted);
      const plainData = aesGcmDecrypt(encryptedData, this.sessionKey);
      const json = JSON.parse(plainData.toString());
      const sid = json.sessionId;
      console.log(`[Session] session_end received: sessionId=${sid || "unknown"}`);
      if (sid) activeSessions.delete(sid);
    } catch (err) {
      console.log(`[Error] session_end processing failed: ${err.message}`);
    }
  }

  sendTextAnswer(answer) {
    if (!this.sessionKey) return;

    try {
      const plain = Buffer.from(JSON.stringify({ answer }));
      const encrypted = aesGcmEncrypt(plain, this.sessionKey);

      this.send({
        type: "message",
        payload: {
          type: "text_answer",
          encrypted: base64url(encrypted),
        },
      });
    } catch (err) {
      console.log(`[Error] Response encryption failed: ${err.message}`);
    }
  }
}

// ─── Main ───

async function main() {
  let config = loadConfig();

  // relay URL: args > config > default
  if (relayIdx === -1 && config.relayURL) {
    relayURL = config.relayURL;
  }

  // Identity
  if (forceNew && fs.existsSync(IDENTITY_FILE)) {
    fs.unlinkSync(IDENTITY_FILE);
    console.log("[Config] Deleted existing key");
  }

  const { privateKey, room, publicKeyRaw } = loadOrCreateIdentity();
  const pubKeyB64URL = base64url(publicKeyRaw);

  const pairingURL = `easy://pair?relay=${encodeURIComponent(relayURL)}&room=${room}&pub=${pubKeyB64URL}`;

  console.log("");
  console.log("━━━ Easy Server ━━━");
  console.log(`Relay: ${relayURL}`);
  console.log(`Room:  ${room}`);
  console.log("");
  printQR(pairingURL);
  console.log("");
  console.log(`Pairing URL: ${pairingURL}`);
  console.log("Scan the QR code from your iPhone.");
  console.log("");

  const connector = new RelayConnector(relayURL, room, privateKey, publicKeyRaw);
  connector.connect();

  process.on("SIGINT", () => {
    console.log("\n[Exit] Ctrl+C — sending shutdown...");
    connector.sendShutdown();
    setTimeout(() => process.exit(0), 300);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
