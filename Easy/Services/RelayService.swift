import Foundation
import CryptoKit

/// Relay 서버를 통한 E2E 암호화 통신 서비스
actor RelayService {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionKey: SymmetricKey?
    private var pairingInfo: PairingInfo?

    private var pendingContinuation: CheckedContinuation<String, Error>?

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

    /// QR 코드에서 파싱한 정보로 relay에 연결 + 키교환
    func connect(with info: PairingInfo) async throws {
        self.pairingInfo = info
        state = .connecting

        urlSession = URLSession(configuration: .default)

        guard let url = URL(string: info.relayURL) else {
            state = .disconnected
            throw RelayError.notConnected
        }

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        state = .connected

        // Room 참가
        let joinMsg: [String: Any] = ["type": "join", "room": info.room]
        try await sendJSON(joinMsg)

        // 수신 루프 시작
        startReceiveLoop()

        // 키교환 수행
        try await performKeyExchange(serverPublicKey: info.serverPublicKey)

        state = .paired
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionKey = nil
        state = .disconnected
    }

    var isConnected: Bool {
        state == .paired
    }

    /// 질문 전송 + 응답 수신 (E2E 암호화)
    func ask(question: String, workDir: String?) async throws -> String {
        guard let sessionKey else {
            throw RelayError.notPaired
        }

        // 질문 JSON 생성
        var questionJSON: [String: Any] = ["question": question]
        if let workDir, !workDir.isEmpty {
            questionJSON["workDir"] = workDir
        }

        // 암호화
        let plainData = try JSONSerialization.data(withJSONObject: questionJSON)
        let sealed = try AES.GCM.seal(plainData, using: sessionKey)
        let encryptedBase64 = sealed.combined!.base64URLEncoded()

        // 전송
        let msg: [String: Any] = [
            "type": "message",
            "payload": [
                "type": "ask",
                "encrypted": encryptedBase64
            ] as [String: Any]
        ]
        try await sendJSON(msg)

        // 응답 대기 (최대 120초)
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation

            // 타임아웃
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                await self?.handleTimeout()
            }
        }
    }

    // MARK: - Private

    private func handleTimeout() {
        if pendingContinuation != nil {
            pendingContinuation?.resume(throwing: RelayError.timeout)
            pendingContinuation = nil
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

        // 랜덤 세션키 생성
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

    private func startReceiveLoop() {
        Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        do {
            let message = try await webSocketTask.receive()
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
            // 계속 수신
            await receiveLoop()
        } catch {
            if state != .disconnected {
                state = .connecting
                // 재접속
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    if let info = await self?.pairingInfo {
                        try? await self?.connect(with: info)
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "joined":
            state = .connected

        case "peer_joined":
            break

        case "peer_left":
            sessionKey = nil
            state = .connected

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

        case "answer":
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else {
                pendingContinuation?.resume(throwing: RelayError.invalidResponse)
                pendingContinuation = nil
                return
            }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let answer = json["answer"] as? String else {
                    pendingContinuation?.resume(throwing: RelayError.invalidResponse)
                    pendingContinuation = nil
                    return
                }

                pendingContinuation?.resume(returning: answer.trimmingCharacters(in: .whitespacesAndNewlines))
                pendingContinuation = nil
            } catch {
                pendingContinuation?.resume(throwing: RelayError.decryptionFailed)
                pendingContinuation = nil
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
