import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.ghost.easy", category: "relay")

/// E2E encrypted communication service via Relay server
actor RelayService {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionKey: SymmetricKey?
    private var pairingInfo: PairingInfo?
    private var connectionId: Int = 0

    private var pendingTextContinuation: CheckedContinuation<String, Error>?
    private var streamContinuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?

    enum StreamEvent: Sendable {
        case chunk(String, Int)  // sentence, index
        case done(String)        // full text
    }

    enum RelayError: LocalizedError {
        case notConnected
        case notPaired
        case keyExchangeFailed
        case timeout
        case decryptionFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to relay server"
            case .notPaired: "Not paired — scan QR code"
            case .keyExchangeFailed: "Key exchange failed"
            case .timeout: "Response timeout"
            case .decryptionFailed: "Decryption failed"
            case .invalidResponse: "Invalid response"
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
        let title: String?
    }

    nonisolated(unsafe) var onServerInfo: (@Sendable (ServerInfo) -> Void)?
    nonisolated(unsafe) var onStateChanged: (@Sendable (ConnectionState) -> Void)?
    nonisolated(unsafe) var onSessionEnd: (@Sendable (String) -> Void)?
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

        log.info("Connecting: \(info.relayURL) room: \(info.room)")

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

        // Wait for key_exchange_ack (set by handlePayload)
        for i in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            guard connectionId == myConnectionId else { return }
            if state == .paired {
                log.notice("Pairing complete (took \(i * 500)ms)")
                break
            }
        }

        if state != .paired {
            log.warning("Key exchange ack timeout (10s) — server not responding")
            state = .disconnected
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionKey = nil
        state = .disconnected
    }

    var isConnected: Bool { state == .paired }

    /// Send text + receive response (E2E encrypted)
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

    /// Send text + receive streamed response (E2E encrypted)
    func askTextStreaming(text: String, sessionId: String? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                guard let sessionKey = self.sessionKey else {
                    continuation.finish(throwing: RelayError.notPaired)
                    return
                }

                self.streamContinuation = continuation

                var payload: [String: Any] = ["text": text]
                if let sessionId {
                    payload["sessionId"] = sessionId
                }

                do {
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
                    try await self.sendJSON(msg)

                    // Timeout
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(120))
                        guard let self else { return }
                        let cont = await self.streamContinuation
                        if cont != nil {
                            await self.finishStream(throwing: RelayError.timeout)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    self.streamContinuation = nil
                }
            }
        }
    }

    private func finishStream(throwing error: Error? = nil) {
        if let error {
            streamContinuation?.finish(throwing: error)
        } else {
            streamContinuation?.finish()
        }
        streamContinuation = nil
    }

    func sendSessionClear(sessionId: String) async {
        guard let sessionKey else { return }
        do {
            let payload: [String: Any] = ["sessionId": sessionId]
            let plainData = try JSONSerialization.data(withJSONObject: payload)
            let sealed = try AES.GCM.seal(plainData, using: sessionKey)
            let encryptedBase64 = sealed.combined!.base64URLEncoded()

            let msg: [String: Any] = [
                "type": "message",
                "payload": [
                    "type": "session_clear",
                    "encrypted": encryptedBase64
                ] as [String: Any]
            ]
            try await sendJSON(msg)
            log.info("session_clear sent: \(sessionId)")
        } catch {
            log.error("session_clear send failed: \(error)")
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
            log.info("session_end sent: \(sessionId)")
        } catch {
            log.error("session_end send failed: \(error)")
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
                log.warning("Ping failed: \(error.localizedDescription)")
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

        log.debug("Received: type=\(type) payload.type=\((json["payload"] as? [String: Any])?["type"] as? String ?? "N/A")")

        switch type {
        case "joined":
            state = .connected
        case "peer_joined":
            break
        case "peer_left":
            log.notice("peer_left — server disconnected")
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

                let title = json["title"] as? String
                let info = ServerInfo(workDir: workDir, hostname: hostname, title: title)
                log.info("server_info received: workDir=\(workDir) hostname=\(hostname) title=\(title ?? "nil")")
                let callback = onServerInfo
                Task { @MainActor in
                    callback?(info)
                }
            } catch {
                log.error("server_info decryption failed: \(error)")
            }

        case "session_end":
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else { return }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let sessionId = json["sessionId"] as? String else { return }

                log.notice("session_end received: \(sessionId)")
                let callback = onSessionEnd
                Task { @MainActor in
                    callback?(sessionId)
                }
            } catch {
                log.error("session_end decryption failed: \(error)")
            }

        case "server_shutdown":
            log.notice("server_shutdown received")
            state = .disconnected

        case "text_stream":
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else { return }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let chunk = json["chunk"] as? String,
                      let index = json["index"] as? Int else { return }

                log.info("text_stream chunk[\(index)]: \(chunk.prefix(40))")
                streamContinuation?.yield(.chunk(chunk, index))
            } catch {
                log.error("text_stream decryption failed: \(error)")
            }

        case "text_done":
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else { return }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let fullText = json["fullText"] as? String else { return }

                log.info("text_done: \(fullText.prefix(50))")
                streamContinuation?.yield(.done(fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
                streamContinuation?.finish()
                streamContinuation = nil
            } catch {
                log.error("text_done decryption failed: \(error)")
                streamContinuation?.finish(throwing: RelayError.decryptionFailed)
                streamContinuation = nil
            }

        case "text_answer":
            // Legacy fallback: non-streaming response
            log.info("text_answer received, sessionKey=\(self.sessionKey != nil)")
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else {
                log.error("text_answer guard failed")
                pendingTextContinuation?.resume(throwing: RelayError.invalidResponse)
                pendingTextContinuation = nil
                // Also finish stream if active
                streamContinuation?.finish(throwing: RelayError.invalidResponse)
                streamContinuation = nil
                return
            }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let answer = json["answer"] as? String else {
                    log.error("text_answer JSON parse failed")
                    pendingTextContinuation?.resume(throwing: RelayError.invalidResponse)
                    pendingTextContinuation = nil
                    streamContinuation?.finish(throwing: RelayError.invalidResponse)
                    streamContinuation = nil
                    return
                }

                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                log.info("text_answer decrypted: \(trimmed.prefix(50))")

                // If streaming is active, deliver as done event
                if streamContinuation != nil {
                    streamContinuation?.yield(.done(trimmed))
                    streamContinuation?.finish()
                    streamContinuation = nil
                } else {
                    pendingTextContinuation?.resume(returning: trimmed)
                    pendingTextContinuation = nil
                }
            } catch {
                log.error("text_answer decryption failed: \(error)")
                pendingTextContinuation?.resume(throwing: RelayError.decryptionFailed)
                pendingTextContinuation = nil
                streamContinuation?.finish(throwing: RelayError.decryptionFailed)
                streamContinuation = nil
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
