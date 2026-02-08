import Foundation
import CryptoKit

/// Relay 서버를 통한 E2E 암호화 통신 서비스
actor RelayService {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionKey: SymmetricKey?
    private var pairingInfo: PairingInfo?
    private var connectionId: Int = 0

    private var pendingTextContinuation: CheckedContinuation<String, Error>?

    enum RelayError: LocalizedError {
        case notConnected
        case notPaired
        case keyExchangeFailed
        case timeout
        case decryptionFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConnected: "Relay 서버에 연결되지 않음"
            case .notPaired: "페어링되지 않음 — QR 코드를 스캔하세요"
            case .keyExchangeFailed: "키교환 실패"
            case .timeout: "응답 시간 초과"
            case .decryptionFailed: "복호화 실패"
            case .invalidResponse: "잘못된 응답"
            }
        }
    }

    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case paired
    }

    struct ServerInfo: Sendable {
        let workDir: String
        let hostname: String
    }

    nonisolated(unsafe) var onServerInfo: (@Sendable (ServerInfo) -> Void)?
    nonisolated(unsafe) var onStateChanged: (@Sendable (ConnectionState) -> Void)?
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            let callback = onStateChanged
            let newState = state
            Task { @MainActor in
                callback?(newState)
            }
        }
    }

    init() {}

    func connect(with info: PairingInfo) async throws {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionKey = nil
        connectionId += 1
        let myConnectionId = connectionId

        self.pairingInfo = info
        state = .connecting

        print("[RelayService] 연결 시작: \(info.relayURL) room: \(info.room)")

        urlSession = URLSession(configuration: .default)

        guard let url = URL(string: info.relayURL) else {
            state = .disconnected
            throw RelayError.notConnected
        }

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        try await Task.sleep(for: .milliseconds(500))
        guard connectionId == myConnectionId else { return }

        state = .connected

        let joinMsg: [String: Any] = ["type": "join", "room": info.room]
        try await sendJSON(joinMsg)

        startReceiveLoop(connectionId: myConnectionId)
        startPingLoop(connectionId: myConnectionId)

        try await performKeyExchange(serverPublicKey: info.serverPublicKey)

        guard connectionId == myConnectionId else { return }
        state = .paired
        print("[RelayService] 페어링 완료")
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionKey = nil
        state = .disconnected
    }

    var isConnected: Bool { state == .paired }

    /// 텍스트 전송 + 응답 수신 (E2E 암호화)
    func askText(text: String, sessionId: String? = nil) async throws -> String {
        guard let sessionKey else {
            throw RelayError.notPaired
        }

        var payload: [String: Any] = ["text": text]
        if let sessionId {
            payload["sessionId"] = sessionId
        }

        let plainData = try JSONSerialization.data(withJSONObject: payload)
        let sealed = try AES.GCM.seal(plainData, using: sessionKey)
        let encryptedBase64 = sealed.combined!.base64URLEncoded()

        let msg: [String: Any] = [
            "type": "message",
            "payload": [
                "type": "ask_text",
                "encrypted": encryptedBase64
            ] as [String: Any]
        ]
        try await sendJSON(msg)

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingTextContinuation = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                await self?.handleTextTimeout()
            }
        }
    }

    func sendSessionEnd(sessionId: String) async {
        guard let sessionKey else { return }
        do {
            let payload: [String: Any] = ["sessionId": sessionId]
            let plainData = try JSONSerialization.data(withJSONObject: payload)
            let sealed = try AES.GCM.seal(plainData, using: sessionKey)
            let encryptedBase64 = sealed.combined!.base64URLEncoded()

            let msg: [String: Any] = [
                "type": "message",
                "payload": [
                    "type": "session_end",
                    "encrypted": encryptedBase64
                ] as [String: Any]
            ]
            try await sendJSON(msg)
            print("[RelayService] session_end 전송: \(sessionId)")
        } catch {
            print("[RelayService] session_end 전송 실패: \(error)")
        }
    }

    // MARK: - Private

    private func handleTextTimeout() {
        if pendingTextContinuation != nil {
            pendingTextContinuation?.resume(throwing: RelayError.timeout)
            pendingTextContinuation = nil
        }
    }

    private func performKeyExchange(serverPublicKey: Data) async throws {
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let serverPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKey)

        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: serverPubKey)

        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("easy-relay".utf8),
            sharedInfo: Data("key-exchange".utf8),
            outputByteCount: 32
        )

        let sessionKeyData = SymmetricKey(size: .bits256)
        let sessionKeyRaw = sessionKeyData.withUnsafeBytes { Data($0) }

        let sealed = try AES.GCM.seal(sessionKeyRaw, using: derivedKey)
        let encryptedSessionKey = sealed.combined!.base64URLEncoded()

        let keyExMsg: [String: Any] = [
            "type": "message",
            "payload": [
                "type": "key_exchange",
                "publicKey": ephemeralKey.publicKey.rawRepresentation.base64URLEncoded(),
                "encryptedSessionKey": encryptedSessionKey
            ] as [String: Any]
        ]
        try await sendJSON(keyExMsg)

        self.sessionKey = sessionKeyData
        try await Task.sleep(for: .milliseconds(500))
    }

    private func startPingLoop(connectionId: Int) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                guard await self.connectionId == connectionId else { return }
                await self.sendPing()
            }
        }
    }

    private func sendPing() {
        webSocketTask?.sendPing { error in
            if let error {
                print("[RelayService] ping 실패: \(error.localizedDescription)")
            }
        }
    }

    private func startReceiveLoop(connectionId: Int) {
        Task { [weak self] in
            await self?.receiveLoop(connectionId: connectionId)
        }
    }

    private func receiveLoop(connectionId: Int) async {
        guard self.connectionId == connectionId,
              let webSocketTask else { return }

        do {
            let message = try await webSocketTask.receive()
            guard self.connectionId == connectionId else { return }
            switch message {
            case .string(let text):
                handleMessage(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    handleMessage(text)
                }
            @unknown default:
                break
            }
            await receiveLoop(connectionId: connectionId)
        } catch {
            guard self.connectionId == connectionId else { return }
            if state != .disconnected {
                state = .connecting
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    guard await self.connectionId == connectionId else { return }
                    if let info = await self.pairingInfo {
                        try? await self.connect(with: info)
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        print("[RelayService] 수신: type=\(type) payload.type=\((json["payload"] as? [String: Any])?["type"] as? String ?? "N/A")")

        switch type {
        case "joined":
            state = .connected
        case "peer_joined":
            break
        case "peer_left":
            print("[RelayService] peer_left — 서버 연결 끊김")
            sessionKey = nil
            state = .disconnected
        case "message":
            guard let payload = json["payload"] as? [String: Any] else { return }
            handlePayload(payload)
        default:
            break
        }
    }

    private func handlePayload(_ payload: [String: Any]) {
        guard let msgType = payload["type"] as? String else { return }

        switch msgType {
        case "key_exchange_ack":
            state = .paired

        case "server_info":
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else { return }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let workDir = json["workDir"] as? String,
                      let hostname = json["hostname"] as? String else { return }

                let info = ServerInfo(workDir: workDir, hostname: hostname)
                print("[RelayService] server_info 수신: workDir=\(workDir) hostname=\(hostname)")
                let callback = onServerInfo
                Task { @MainActor in
                    callback?(info)
                }
            } catch {
                print("[RelayService] server_info 복호화 실패: \(error)")
            }

        case "server_shutdown":
            print("[RelayService] server_shutdown 수신")
            state = .disconnected

        case "text_answer":
            print("[RelayService] text_answer 수신, sessionKey=\(sessionKey != nil), continuation=\(pendingTextContinuation != nil)")
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else {
                print("[RelayService] text_answer guard 실패")
                pendingTextContinuation?.resume(throwing: RelayError.invalidResponse)
                pendingTextContinuation = nil
                return
            }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let answer = json["answer"] as? String else {
                    print("[RelayService] text_answer JSON 파싱 실패")
                    pendingTextContinuation?.resume(throwing: RelayError.invalidResponse)
                    pendingTextContinuation = nil
                    return
                }

                print("[RelayService] text_answer 복호화 성공: \(answer.prefix(50))")
                pendingTextContinuation?.resume(returning: answer.trimmingCharacters(in: .whitespacesAndNewlines))
                pendingTextContinuation = nil
            } catch {
                print("[RelayService] text_answer 복호화 실패: \(error)")
                pendingTextContinuation?.resume(throwing: RelayError.decryptionFailed)
                pendingTextContinuation = nil
            }

        default:
            break
        }
    }

    private func sendJSON(_ json: [String: Any]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        try await webSocketTask?.send(.string(text))
    }
}
