import Foundation
import CryptoKit
import os
@preconcurrency import SocketIO

private let log = Logger(subsystem: "com.ghost.easy", category: "relay")

/// Sendable wrapper for [String: Any] payload from Socket.IO callbacks
private struct DictWrapper: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// E2E encrypted communication service via Relay server (Socket.IO)
actor RelayService {
    nonisolated(unsafe) private var manager: SocketManager?
    nonisolated(unsafe) private var socket: SocketIOClient?
    private var sessionKey: SymmetricKey?
    private var pairingInfo: PairingInfo?

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
    nonisolated(unsafe) var onCompactNeeded: (@Sendable (String) -> Void)?
    nonisolated(unsafe) var onPeerLeft: (@Sendable () -> Void)?
    nonisolated(unsafe) var onServerShutdown: (@Sendable () -> Void)?
    nonisolated(unsafe) var onDebugLog: (@Sendable (String) -> Void)?
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
        disconnect()
        self.pairingInfo = info
        state = .connecting

        log.info("Connecting: \(info.relayURL) room: \(info.room)")
        debugLog("Connecting...")

        guard let url = URL(string: info.relayURL) else {
            state = .disconnected
            throw RelayError.notConnected
        }

        let manager = SocketManager(socketURL: url, config: [
            .reconnects(true),
            .reconnectAttempts(-1),
            .reconnectWait(3),
            .reconnectWaitMax(30),
            .log(false),
            .forceWebsockets(false),
        ])
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket

        setupHandlers(socket: socket, info: info)
        socket.connect()

        // Wait for paired state (max 30s)
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if state == .paired { return }
            if state == .disconnected { throw RelayError.notConnected }
        }
        if state != .paired {
            throw RelayError.timeout
        }
    }

    func disconnect() {
        socket?.disconnect()
        manager?.disconnect()
        socket = nil
        manager = nil
        sessionKey = nil
        state = .disconnected
    }

    var isConnected: Bool { state == .paired }

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

                    self.emitRelay([
                        "type": "ask_text",
                        "encrypted": encryptedBase64
                    ] as [String: Any])

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

            emitRelay([
                "type": "session_clear",
                "encrypted": encryptedBase64
            ] as [String: Any])
            log.info("session_clear sent: \(sessionId)")
        } catch {
            log.error("session_clear send failed: \(error)")
        }
    }

    func sendSessionCompact(sessionId: String, summary: String) async {
        guard let sessionKey else { return }
        do {
            let payload: [String: Any] = ["sessionId": sessionId, "summary": summary]
            let plainData = try JSONSerialization.data(withJSONObject: payload)
            let sealed = try AES.GCM.seal(plainData, using: sessionKey)
            let encryptedBase64 = sealed.combined!.base64URLEncoded()

            emitRelay([
                "type": "session_compact",
                "encrypted": encryptedBase64
            ] as [String: Any])
            log.info("session_compact sent: \(sessionId) summary=\(summary.prefix(50))")
        } catch {
            log.error("session_compact send failed: \(error)")
        }
    }

    func sendSessionEnd(sessionId: String) async {
        guard let sessionKey else { return }
        do {
            let payload: [String: Any] = ["sessionId": sessionId]
            let plainData = try JSONSerialization.data(withJSONObject: payload)
            let sealed = try AES.GCM.seal(plainData, using: sessionKey)
            let encryptedBase64 = sealed.combined!.base64URLEncoded()

            emitRelay([
                "type": "session_end",
                "encrypted": encryptedBase64
            ] as [String: Any])
            log.info("session_end sent: \(sessionId)")
        } catch {
            log.error("session_end send failed: \(error)")
        }
    }

    // MARK: - Private

    private func setupHandlers(socket: SocketIOClient, info: PairingInfo) {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handleConnect(info: info) }
        }

        socket.on("joined") { [weak self] data, _ in
            guard let self else { return }
            let peers = (data.first as? [String: Any])?["peers"] as? Int ?? 0
            Task { await self.handleJoined(peers: peers) }
        }

        socket.on("peer_joined") { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handlePeerJoined(info: info) }
        }

        socket.on("relay") { [weak self] data, _ in
            guard let self else { return }
            guard let payload = data.first as? [String: Any] else { return }
            let sendable = DictWrapper(payload)
            Task { await self.handleRelay(sendable) }
        }

        socket.on("peer_left") { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handlePeerLeft() }
        }

        socket.on("error_msg") { [weak self] data, _ in
            guard let self else { return }
            let message = (data.first as? [String: Any])?["message"] as? String ?? "unknown"
            Task { await self.handleErrorMsg(message) }
        }

        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handleDisconnect() }
        }

        socket.on(clientEvent: .reconnect) { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handleReconnect(info: info) }
        }
    }

    // MARK: - Socket.IO Event Handlers

    private func handleConnect(info: PairingInfo) {
        log.info("Socket.IO connected")
        debugLog("Connected")
        state = .connecting
        socket?.emit("join", ["room": info.room])
    }

    private func handleJoined(peers: Int) {
        log.info("Joined room (peers: \(peers))")
        debugLog("Joined room")
        state = .connected
    }

    private func handlePeerJoined(info: PairingInfo) {
        log.info("Peer joined — sending key exchange")
        debugLog("Peer joined — keying")
        if state == .connected || state == .connecting {
            Task {
                try? await performKeyExchange(serverPublicKey: info.serverPublicKey)
            }
        }
    }

    private func handleRelay(_ wrapper: DictWrapper) {
        handlePayload(wrapper.value)
    }

    private func handlePeerLeft() {
        log.notice("Peer left — server disconnected")
        sessionKey = nil
        let callback = onPeerLeft
        Task { @MainActor in callback?() }
        state = .disconnected
    }

    private func handleErrorMsg(_ message: String) {
        log.warning("Relay error: \(message)")
        debugLog("Relay: \(message)")
    }

    private func handleDisconnect() {
        log.info("Socket.IO disconnected")
        debugLog("Disconnected (reconnecting...)")
        if state == .paired {
            state = .connecting
        }
    }

    private func handleReconnect(info: PairingInfo) {
        log.info("Socket.IO reconnected")
        debugLog("Reconnected")
        socket?.emit("join", ["room": info.room])
    }

    // MARK: - Helpers

    private func debugLog(_ text: String) {
        let msg = "[Relay] \(text)"
        print(msg)
        log.info("\(msg)")
        let callback = onDebugLog
        Task { @MainActor in callback?(text) }
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

        emitRelay([
            "type": "key_exchange",
            "publicKey": ephemeralKey.publicKey.rawRepresentation.base64URLEncoded(),
            "encryptedSessionKey": encryptedSessionKey
        ] as [String: Any])

        self.sessionKey = sessionKeyData
        debugLog("Key exchange sent")
    }

    private func emitRelay(_ payload: [String: Any]) {
        socket?.emit("relay", payload)
    }

    private func handlePayload(_ payload: [String: Any]) {
        guard let msgType = payload["type"] as? String else { return }

        switch msgType {
        case "key_exchange_ack":
            state = .paired
            debugLog("Paired!")

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
            let callback = onServerShutdown
            Task { @MainActor in callback?() }
            state = .disconnected

        case "compact_needed":
            guard let sessionKey,
                  let encryptedBase64 = payload["encrypted"] as? String,
                  let encryptedData = Data(base64URLEncoded: encryptedBase64) else { return }

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let plainData = try AES.GCM.open(sealedBox, using: sessionKey)

                guard let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                      let sessionId = json["sessionId"] as? String else { return }

                let inputTokens = json["inputTokens"] as? Int ?? 0
                log.notice("compact_needed: session=\(sessionId) tokens=\(inputTokens)")
                let callback = onCompactNeeded
                Task { @MainActor in
                    callback?(sessionId)
                }
            } catch {
                log.error("compact_needed decryption failed: \(error)")
            }

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
}
