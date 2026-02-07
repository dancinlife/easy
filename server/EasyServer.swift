#!/usr/bin/env swift
/// Easy Server — Claude Code HTTP 래퍼 (Swift)
/// Mac에서 실행. iPhone Easy 앱이 이 서버에 요청을 보냄.
///
/// 사용법:
///     # HTTP 모드 (기존, Tailscale VPN 필요)
///     swift server/EasyServer.swift
///     # → http://0.0.0.0:7777
///
///     # Relay 모드 (VPN 불필요, E2E 암호화)
///     swift server/EasyServer.swift --relay wss://your-relay.fly.dev
///     # → QR 코드 표시 → iPhone에서 스캔

import Foundation
import CryptoKit
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let PORT: UInt16 = 7777

// MARK: - Relay Mode Detection

let args = CommandLine.arguments
var relayURL: String? = nil

if let idx = args.firstIndex(of: "--relay"), idx + 1 < args.count {
    relayURL = args[idx + 1]
}

if let relayURL {
    startRelayMode(relayURL: relayURL)
} else {
    startHTTPMode()
}

// MARK: - HTTP Mode (기존 로직)

func startHTTPMode() {
    let listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: PORT)!)

    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        receive(connection: connection)
    }

    print("Easy Server running on http://0.0.0.0:\(PORT)")
    print("Health check: http://localhost:\(PORT)/health")
    print("Ctrl+C to stop")

    listener.start(queue: .main)
    dispatchMain()
}

func receive(connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
        guard let data, error == nil else {
            connection.cancel()
            return
        }

        let request = String(data: data, encoding: .utf8) ?? ""
        handleRequest(request: request, connection: connection)
    }
}

func handleRequest(request: String, connection: NWConnection) {
    let lines = request.components(separatedBy: "\r\n")
    let firstLine = lines.first ?? ""

    if firstLine.hasPrefix("GET /health") {
        sendJSON(connection: connection, json: ["status": "ok"])
        return
    }

    guard firstLine.hasPrefix("POST /ask") else {
        sendError(connection: connection, code: 404, message: "Not Found")
        return
    }

    // Parse body (after empty line)
    let parts = request.components(separatedBy: "\r\n\r\n")
    guard parts.count >= 2, let bodyData = parts[1].data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let question = json["question"] as? String, !question.isEmpty else {
        sendJSON(connection: connection, json: ["error": "question is required"], code: 400)
        return
    }

    let workDir = json["workDir"] as? String

    if let workDir {
        print("[질문] (\(workDir)) \(question)")
    } else {
        print("[질문] \(question)")
    }

    let answer = runClaude(question: question, workDir: workDir)
    if let answer {
        let preview = answer.prefix(100)
        print("[응답] \(preview)...")
        sendJSON(connection: connection, json: ["answer": answer])
    } else {
        sendJSON(connection: connection, json: ["error": "claude 실행 실패"], code: 500)
    }
}

func sendJSON(connection: NWConnection, json: [String: Any], code: Int = 200) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    let statusText = code == 200 ? "OK" : "Error"
    let header = """
    HTTP/1.1 \(code) \(statusText)\r
    Content-Type: application/json; charset=utf-8\r
    Content-Length: \(body.count)\r
    Access-Control-Allow-Origin: *\r
    Connection: close\r
    \r\n
    """
    var response = header.data(using: .utf8)!
    response.append(body)

    connection.send(content: response, completion: .contentProcessed { _ in
        connection.cancel()
    })
}

func sendError(connection: NWConnection, code: Int, message: String) {
    sendJSON(connection: connection, json: ["error": message], code: code)
}

// MARK: - Shared: Run Claude

func runClaude(question: String, workDir: String?) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "claude --print \(shellEscape(question))"]
    process.environment = ProcessInfo.processInfo.environment

    if let workDir {
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
    }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let answer = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer
    } catch {
        return nil
    }
}

func shellEscape(_ str: String) -> String {
    "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Relay Mode

func startRelayMode(relayURL: String) {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let publicKey = privateKey.publicKey
    let roomID = UUID().uuidString.lowercased()

    // QR에 담을 페어링 URL
    let pubKeyBase64URL = publicKey.rawRepresentation.base64URLEncoded()
    let pairingURL = "easy://pair?relay=\(relayURL)&room=\(roomID)&pub=\(pubKeyBase64URL)"

    print("Easy Server — Relay Mode")
    print("Relay: \(relayURL)")
    print("Room: \(roomID)")
    print("")
    printQRCode(pairingURL)
    print("")
    print("페어링 URL: \(pairingURL)")
    print("iPhone에서 QR 코드를 스캔하세요.")
    print("")

    // WebSocket으로 relay에 접속
    let relayConnector = RelayConnector(
        relayURL: relayURL,
        roomID: roomID,
        privateKey: privateKey
    )
    relayConnector.connect()

    dispatchMain()
}

// MARK: - RelayConnector

class RelayConnector: NSObject, URLSessionWebSocketDelegate {
    let relayURL: String
    let roomID: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var webSocketTask: URLSessionWebSocketTask?
    var sessionKey: SymmetricKey?
    var session: URLSession!

    init(relayURL: String, roomID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.relayURL = relayURL
        self.roomID = roomID
        self.privateKey = privateKey
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        guard let url = URL(string: relayURL) else {
            print("[오류] 잘못된 relay URL: \(relayURL)")
            return
        }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // room 참가
        let joinMsg: [String: Any] = ["type": "join", "room": roomID]
        sendJSON(joinMsg)

        receiveLoop()
    }

    func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()

            case .failure(let error):
                print("[Relay] 연결 끊김: \(error.localizedDescription)")
                // 재접속 시도
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    print("[Relay] 재접속 시도...")
                    self.connect()
                }
            }
        }
    }

    func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "joined":
            let peers = json["peers"] as? Int ?? 0
            print("[Relay] Room 참가 완료 (피어: \(peers)명)")

        case "peer_joined":
            print("[Relay] iPhone 연결됨!")

        case "peer_left":
            print("[Relay] iPhone 연결 끊김")
            sessionKey = nil

        case "message":
            guard let payload = json["payload"] as? [String: Any] else { return }
            handlePayload(payload)

        case "error":
            let msg = json["message"] as? String ?? "unknown"
            print("[Relay 오류] \(msg)")

        default:
            break
        }
    }

    func handlePayload(_ payload: [String: Any]) {
        guard let msgType = payload["type"] as? String else { return }

        switch msgType {
        case "key_exchange":
            // iPhone이 보낸 키교환: 임시 공개키 + 암호화된 세션키
            guard let peerPubBase64 = payload["publicKey"] as? String,
                  let peerPubData = Data(base64URLEncoded: peerPubBase64),
                  let encryptedSessionKeyBase64 = payload["encryptedSessionKey"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedSessionKeyBase64) else {
                print("[오류] 키교환 데이터 파싱 실패")
                return
            }

            do {
                let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubData)
                let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

                // HKDF로 대칭키 도출
                let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: Data("easy-relay".utf8),
                    sharedInfo: Data("key-exchange".utf8),
                    outputByteCount: 32
                )

                // 암호화된 세션키 복호화
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let sessionKeyData = try AES.GCM.open(sealedBox, using: derivedKey)
                self.sessionKey = SymmetricKey(data: sessionKeyData)

                print("[Relay] 키교환 완료 — E2E 암호화 활성화")

                // 확인 응답
                let ack: [String: Any] = [
                    "type": "message",
                    "payload": ["type": "key_exchange_ack"]
                ]
                sendJSON(ack)
            } catch {
                print("[오류] 키교환 실패: \(error.localizedDescription)")
            }

        case "ask":
            // 암호화된 질문
            guard let sessionKey = self.sessionKey else {
                print("[오류] 세션키 없음 — 키교환 필요")
                return
            }

            guard let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else {
                print("[오류] 암호화된 질문 파싱 실패")
                return
            }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let question = json["question"] as? String else {
                    print("[오류] 질문 JSON 파싱 실패")
                    return
                }

                let workDir = json["workDir"] as? String
                if let workDir {
                    print("[질문] (\(workDir)) \(question)")
                } else {
                    print("[질문] \(question)")
                }

                // claude 실행 (백그라운드)
                DispatchQueue.global().async {
                    let answer = runClaude(question: question, workDir: workDir) ?? "오류: claude 실행 실패"
                    let preview = answer.prefix(100)
                    print("[응답] \(preview)...")

                    // 응답 암호화 후 전송
                    do {
                        let answerJSON: [String: Any] = ["answer": answer]
                        let answerData = try JSONSerialization.data(withJSONObject: answerJSON)
                        let sealed = try AES.GCM.seal(answerData, using: sessionKey)
                        let encryptedBase64 = sealed.combined!.base64URLEncoded()

                        let response: [String: Any] = [
                            "type": "message",
                            "payload": [
                                "type": "answer",
                                "encrypted": encryptedBase64
                            ]
                        ]
                        self.sendJSON(response)
                    } catch {
                        print("[오류] 응답 암호화 실패: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("[오류] 질문 복호화 실패: \(error.localizedDescription)")
            }

        case "key_exchange_ack":
            break

        default:
            break
        }
    }

    func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error {
                print("[Relay] 전송 오류: \(error.localizedDescription)")
            }
        }
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        print("[Relay] WebSocket 연결됨")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[Relay] WebSocket 닫힘")
    }
}

// MARK: - QR Code (Unicode block art)

func printQRCode(_ text: String) {
    // CoreImage QR 생성 → 유니코드 블록으로 터미널 출력
    // macOS에서만 CoreImage 사용 가능
    guard let data = text.data(using: .utf8) else { return }

    // 간단한 방식: qrencode CLI가 있으면 사용, 없으면 URL만 출력
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "which qrencode > /dev/null 2>&1 && qrencode -t ANSIUTF8 \(shellEscape(text)) || echo '[QR 표시하려면 qrencode를 설치하세요: brew install qrencode]'"]
    process.environment = ProcessInfo.processInfo.environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print(output)
    } catch {
        print("[QR 코드 생성 실패]")
    }
}

// MARK: - Base64URL Extensions

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
