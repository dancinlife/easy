#!/usr/bin/env node
// Easy Server — Claude Code Voice Relay (Node.js)
// Mac에서 실행. iPhone Easy 앱과 Relay를 통해 E2E 암호화 통신.
//
// 설치: npm install -g easy-server
// 실행: easy --relay wss://your-relay.fly.dev

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
  console.log(`Easy — Claude Code 음성 인터페이스

사용법:
  easy                          기본 relay로 시작
  easy --relay <url>            커스텀 relay 서버 지정
  easy --new                    새 페어링 키 생성
  easy --help                   도움말`);
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
      console.log("[설정] 저장된 키 로드");
      return { privateKey, room: data.room, publicKeyRaw: Buffer.from(data.publicKeyRaw, "base64") };
    } catch (e) {
      console.log("[설정] 저장된 키 로드 실패, 새로 생성");
    }
  }

  const { privateKey, publicKey } = crypto.generateKeyPairSync("x25519");
  const room = crypto.randomUUID();

  // raw 공개키 (32바이트)
  const publicKeyRaw = publicKey.export({ type: "spki", format: "der" }).slice(-32);
  const privateKeyPkcs8 = privateKey.export({ type: "pkcs8", format: "der" });

  const data = {
    privateKeyPkcs8: privateKeyPkcs8.toString("base64"),
    publicKeyRaw: publicKeyRaw.toString("base64"),
    room,
  };
  fs.writeFileSync(IDENTITY_FILE, JSON.stringify(data, null, 2));
  console.log("[설정] 새 키 생성");

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
  // raw 32바이트 → SPKI DER 포맷으로 변환
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

// ─── Claude (async spawn, 직렬화) ───

let claudeQueue = Promise.resolve();

function runClaude(question, sessionId) {
  const job = claudeQueue.then(async () => {
    const result = await _runClaudeOnce(question, sessionId);
    if (result === null && sessionId) {
      console.log("[Claude] 세션 충돌 — 세션 없이 재시도");
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
      args.push("--session-id", sessionId);
    }
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
      console.log("[claude 타임아웃] 120초 초과, 프로세스 종료");
      child.kill("SIGTERM");
      resolve(null);
    }, 120_000);

    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        console.log(`[claude 오류] exit=${code} stderr=${stderr.slice(0, 200)}`);
      }
      const answer = stdout.trim();
      // 세션 락 해제 대기 (1초)
      setTimeout(() => resolve(answer || null), 1000);
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      console.log(`[claude 오류] ${err.message}`);
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
    console.log("[QR 표시 실패 — npm install qrcode-terminal]");
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
    console.log(`[Relay] 연결 중: ${this.relayURL}`);
    if (this.pingInterval) clearInterval(this.pingInterval);
    this.ws = new WebSocket(this.relayURL);

    this.ws.on("open", () => {
      console.log("[Relay] WebSocket 연결됨");
      this.send({ type: "join", room: this.room });
      // 15초마다 ping으로 연결 유지
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
          console.log(`[WS 수신] type=${msg.type} payload.type=${msg.payload?.type || "N/A"} (${str.length}bytes)`);
        }
        this.handleMessage(msg);
      } catch (err) {
        console.log(`[WS 파싱 오류] ${err.message} raw=${raw.toString().slice(0, 100)}`);
      }
    });

    this.ws.on("close", () => {
      console.log("[Relay] 연결 끊김, 3초 후 재접속...");
      if (this.pingInterval) clearInterval(this.pingInterval);
      this.sessionKey = null;
      setTimeout(() => this.connect(), 3000);
    });

    this.ws.on("error", (err) => {
      console.log(`[Relay 오류] ${err.message}`);
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
        console.log(`[Relay] Room 참가 완료 (피어: ${msg.peers || 0}명)`);
        break;
      case "peer_joined":
        console.log("[Relay] iPhone 연결됨!");
        break;
      case "peer_left":
        console.log("[Relay] iPhone 연결 끊김");
        this.sessionKey = null;
        break;
      case "message":
        if (msg.payload) this.handlePayload(msg.payload);
        break;
      case "error":
        console.log(`[Relay 오류] ${msg.message}`);
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

      console.log(`[키교환] peerPub: ${peerPubRaw.length}bytes, encrypted: ${encryptedData.length}bytes`);

      const derivedKey = deriveSharedKey(this.privateKey, peerPubRaw);

      console.log(`[키교환] derivedKey: ${derivedKey.slice(0, 8).toString("hex")}... (${derivedKey.length}bytes)`);
      console.log(`[키교환] encData nonce: ${encryptedData.slice(0, 12).toString("hex")}`);

      const sessionKeyData = aesGcmDecrypt(encryptedData, derivedKey);
      this.sessionKey = sessionKeyData;

      console.log(`[키교환] 세션키: ${sessionKeyData.slice(0, 8).toString("hex")}... (${sessionKeyData.length}bytes)`);
      console.log("[Relay] 키교환 완료 — E2E 암호화 활성화");
      this.send({ type: "message", payload: { type: "key_exchange_ack" } });

      // server_info 전송
      this.sendServerInfo();
    } catch (err) {
      console.log(`[오류] 키교환 실패: ${err.message}`);
      console.log(`[오류] 스택: ${err.stack?.split("\n").slice(0, 3).join(" | ")}`);
    }
  }

  sendServerInfo() {
    if (!this.sessionKey) return;
    try {
      const info = { type: "server_info", workDir: process.cwd(), hostname: os.hostname() };
      const plain = Buffer.from(JSON.stringify(info));
      const encrypted = aesGcmEncrypt(plain, this.sessionKey);
      this.send({ type: "message", payload: { type: "server_info", encrypted: base64url(encrypted) } });
      console.log(`[Relay] server_info 전송: workDir=${info.workDir} hostname=${info.hostname}`);
    } catch (err) {
      console.log(`[오류] server_info 전송 실패: ${err.message}`);
    }
  }

  sendShutdown() {
    if (!this.sessionKey) return;
    try {
      const plain = Buffer.from(JSON.stringify({ type: "server_shutdown" }));
      const encrypted = aesGcmEncrypt(plain, this.sessionKey);
      this.send({ type: "message", payload: { type: "server_shutdown", encrypted: base64url(encrypted) } });
      console.log("[Relay] server_shutdown 전송");
    } catch (err) {
      console.log(`[오류] server_shutdown 전송 실패: ${err.message}`);
    }
  }

  async handleAskText(payload) {
    if (!this.sessionKey) {
      console.log("[오류] 세션키 없음 — ask_text 무시");
      return;
    }

    try {
      const encryptedData = fromBase64url(payload.encrypted);
      const plainData = aesGcmDecrypt(encryptedData, this.sessionKey);
      const json = JSON.parse(plainData.toString());

      const text = json.text;
      const sessionId = json.sessionId ? json.sessionId.toLowerCase() : null;

      console.log(`[질문] "${text}" (세션: ${sessionId || "none"})`);

      // Claude 실행
      console.log("[Claude] 실행 중...");
      const answer = (await runClaude(text, sessionId)) || "오류: claude 실행 실패";
      console.log(`[응답] ${answer.slice(0, 100)}${answer.length > 100 ? "..." : ""}`);

      // 응답 전송
      this.sendTextAnswer(answer);
      console.log("[완료] 응답 전송됨");
    } catch (err) {
      console.log(`[오류] 텍스트 처리 실패: ${err.message}`);
      try {
        this.sendTextAnswer(`오류: ${err.message}`);
      } catch {}
    }
  }

  handleSessionEnd(payload) {
    if (!this.sessionKey) return;
    try {
      const encryptedData = fromBase64url(payload.encrypted);
      const plainData = aesGcmDecrypt(encryptedData, this.sessionKey);
      const json = JSON.parse(plainData.toString());
      console.log(`[세션] session_end 수신: sessionId=${json.sessionId || "unknown"}`);
    } catch (err) {
      console.log(`[오류] session_end 처리 실패: ${err.message}`);
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
      console.log(`[오류] 응답 암호화 실패: ${err.message}`);
    }
  }
}

// ─── Main ───

async function main() {
  let config = loadConfig();

  // relay URL: 인자 > config > 기본값
  if (relayIdx === -1 && config.relayURL) {
    relayURL = config.relayURL;
  }

  // Identity
  if (forceNew && fs.existsSync(IDENTITY_FILE)) {
    fs.unlinkSync(IDENTITY_FILE);
    console.log("[설정] 기존 키 삭제");
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
  console.log(`페어링 URL: ${pairingURL}`);
  console.log("iPhone에서 QR 코드를 스캔하세요.");
  console.log("");

  const connector = new RelayConnector(relayURL, room, privateKey, publicKeyRaw);
  connector.connect();

  process.on("SIGINT", () => {
    console.log("\n[종료] Ctrl+C — shutdown 전송 중...");
    connector.sendShutdown();
    setTimeout(() => process.exit(0), 300);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
