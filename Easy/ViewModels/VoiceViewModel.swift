import Foundation
import AVFoundation
import AudioToolbox
import UIKit

@Observable
@MainActor
final class VoiceViewModel {
    // State
    var messages: [Message] = []
    var status: Status = .idle
    var error: String?
    var recognizedText: String = ""
    var isActivated: Bool = false

    // Utterance Queue (mcp-voice-hooks pattern)
    private var pendingUtterances: [String] = []
    private var isProcessing = false

    // Session
    let sessionStore = SessionStore()
    var currentSessionId: String? {
        didSet {
            loadSessionMessages()
            UserDefaults.standard.set(currentSessionId, forKey: "currentSessionId")
        }
    }

    // Relay state
    var relayState: RelayService.ConnectionState = .disconnected
    var pairedRelayURL: String? {
        get { UserDefaults.standard.string(forKey: "pairedRelayURL") }
        set { UserDefaults.standard.set(newValue, forKey: "pairedRelayURL") }
    }
    var pairedRoom: String? {
        get { UserDefaults.standard.string(forKey: "pairedRoom") }
        set { UserDefaults.standard.set(newValue, forKey: "pairedRoom") }
    }
    private var pairedServerPubKey: Data? {
        get {
            guard let b64 = UserDefaults.standard.string(forKey: "pairedServerPubKey") else { return nil }
            return Data(base64URLEncoded: b64)
        }
        set {
            UserDefaults.standard.set(newValue?.base64URLEncoded(), forKey: "pairedServerPubKey")
        }
    }

    // Settings
    var silenceTimeout: TimeInterval {
        get { speech.silenceTimeout }
        set { speech.silenceTimeout = newValue }
    }
    var autoListen: Bool {
        get { UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoListen") }
    }
    var sttLanguage: String {
        get { UserDefaults.standard.string(forKey: "sttLanguage") ?? "en" }
        set {
            UserDefaults.standard.set(newValue, forKey: "sttLanguage")
            speech.sttLanguage = newValue
        }
    }
    var openAIKey: String {
        get { UserDefaults.standard.string(forKey: "openAIKey") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "openAIKey")
            Task { await whisper.setAPIKey(newValue) }
            tts.apiKey = newValue.isEmpty ? nil : newValue
        }
    }
    var ttsVoice: String {
        get { UserDefaults.standard.string(forKey: "ttsVoice") ?? "nova" }
        set {
            UserDefaults.standard.set(newValue, forKey: "ttsVoice")
            tts.voice = newValue
        }
    }

    // Services
    let speech = SpeechService()
    var tts = TTSService()
    private let relay = RelayService()
    private let whisper = WhisperService()

    enum Status {
        case idle
        case listening
        case thinking
        case speaking
    }

    var isConfigured: Bool {
        pairedRelayURL != nil && pairedRoom != nil
    }

    init() {
        currentSessionId = UserDefaults.standard.string(forKey: "currentSessionId")
        if currentSessionId == nil, let first = sessionStore.sessions.first {
            currentSessionId = first.id
        }
        loadSessionMessages()

        speech.sttLanguage = sttLanguage
        speech.whisperService = whisper
        Task { await whisper.setAPIKey(openAIKey) }
        tts.apiKey = openAIKey.isEmpty ? nil : openAIKey
        tts.voice = ttsVoice

        // Real-time text updates
        speech.onTextChanged = { [weak self] text in
            Task { @MainActor in
                self?.recognizedText = text
            }
        }

        // Wake word detected → ding + activate
        speech.onTriggerDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isActivated = true
                AudioServicesPlaySystemSound(1057)
            }
        }

        // Utterance captured → add to queue (mcp-voice-hooks: pending)
        speech.onUtteranceCaptured = { [weak self] text in
            Task { @MainActor in
                self?.handleUtterance(text)
            }
        }

        // TTS finished → check queue or resume listening
        tts.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.currentSessionId != nil else { return }
                self.isProcessing = false
                if self.pendingUtterances.isEmpty {
                    self.startListening()
                } else {
                    self.processNextUtterance()
                }
            }
        }

        relay.onServerInfo = { [weak self] info in
            Task { @MainActor in
                guard let self, let sid = self.currentSessionId,
                      var session = self.sessionStore.sessions.first(where: { $0.id == sid }) else { return }
                session.workDir = info.workDir
                session.hostname = info.hostname
                if session.name == "New Session" {
                    let basename = (info.workDir as NSString).lastPathComponent
                    if !basename.isEmpty { session.name = basename }
                }
                self.sessionStore.updateSession(session)
            }
        }

        relay.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.relayState == .paired
                self.relayState = newState
                if newState == .disconnected {
                    self.stopAll()
                    // Server shutdown → delete current session
                    if wasConnected, let id = self.currentSessionId {
                        self.sessionStore.deleteSession(id: id)
                        self.currentSessionId = nil
                        self.messages = []
                    }
                }
            }
        }

        // Stop audio when entering background
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.speech.stopListening()
            self.tts.stop()
            self.pendingUtterances.removeAll()
            self.isProcessing = false
            if self.status != .idle {
                self.status = .idle
            }
        }

        // Reconnect when returning to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.relayState != .paired {
                self.restorePairingIfNeeded()
            }
        }
    }

    // MARK: - Utterance Queue (mcp-voice-hooks pattern)

    private func handleUtterance(_ text: String) {
        isActivated = false
        pendingUtterances.append(text)

        if status == .speaking {
            // Barge-in: stop TTS + process new utterance
            tts.stop()
            status = .listening
        }

        if !isProcessing {
            processNextUtterance()
        }
    }

    private func processNextUtterance() {
        guard !pendingUtterances.isEmpty else {
            isProcessing = false
            return
        }

        isProcessing = true
        let text = pendingUtterances.removeFirst()

        Task {
            await sendToServer(text)
        }
    }

    private func sendToServer(_ text: String) async {
        ensureSession()
        speech.stopListening()
        status = .thinking
        recognizedText = text

        // Add user message
        messages.append(Message(role: .user, text: text))
        if let sid = currentSessionId {
            sessionStore.appendMessage(sessionId: sid, message: .init(role: .user, text: text))
        }

        do {
            let answer = try await relay.askText(
                text: text,
                sessionId: currentSessionId
            )

            // Ignore if session already closed
            guard currentSessionId != nil else { return }

            // Assistant response
            messages.append(Message(role: .assistant, text: answer))
            if let sid = currentSessionId {
                sessionStore.appendMessage(sessionId: sid, message: .init(role: .assistant, text: answer))
            }

            // TTS playback (mic stays open → barge-in possible)
            status = .speaking
            tts.speak(answer)
        } catch {
            guard currentSessionId != nil else { return }
            self.error = error.localizedDescription
            isProcessing = false
            if relayState == .paired {
                startListening()
            } else {
                status = .idle
            }
        }
    }

    // MARK: - Session Management

    func newSession() {
        let session = sessionStore.createSession()
        currentSessionId = session.id
        messages = []
    }

    func switchSession(id: String) {
        stopAll()
        currentSessionId = id
    }

    func deleteSession(id: String) {
        Task {
            await relay.sendSessionEnd(sessionId: id)
        }
        sessionStore.deleteSession(id: id)
        if currentSessionId == id {
            currentSessionId = sessionStore.sessions.first?.id
        }
    }

    private func loadSessionMessages() {
        guard let id = currentSessionId,
              let session = sessionStore.sessions.first(where: { $0.id == id }) else {
            messages = []
            return
        }
        messages = session.messages.map { msg in
            Message(role: msg.role == .user ? .user : .assistant, text: msg.text)
        }
    }

    private func ensureSession() {
        if currentSessionId == nil {
            let session = sessionStore.createSession()
            currentSessionId = session.id
        }
    }

    // MARK: - Listening

    func startListening() {
        print("[VoiceVM] startListening called, isConfigured=\(isConfigured), openAIKey=\(openAIKey.isEmpty ? "empty" : "set")")
        guard isConfigured else {
            error = "Scan QR code to pair"
            return
        }
        guard !openAIKey.isEmpty else {
            error = "Enter OpenAI API key in Settings"
            return
        }

        Task {
            let permitted = await speech.requestPermission()
            print("[VoiceVM] mic permission: \(permitted)")
            guard permitted else {
                self.error = "Microphone permission required"
                return
            }
            do {
                try speech.startListening()
                status = .listening
                error = nil
                recognizedText = ""
                isActivated = false
            } catch {
                self.error = "Failed to start recording: \(error.localizedDescription)"
            }
        }
    }

    func stopAll() {
        speech.stopListening()
        tts.stop()
        pendingUtterances.removeAll()
        isProcessing = false
        status = .idle
    }

    // MARK: - Relay

    func closeCurrentSession() {
        guard let id = currentSessionId else { return }
        stopAll()
        Task { await relay.sendSessionEnd(sessionId: id) }
        sessionStore.deleteSession(id: id)
        currentSessionId = nil
        messages = []
    }

    func startNewSession(with info: PairingInfo) {
        var session = sessionStore.createSession()
        session.room = info.room
        sessionStore.updateSession(session)
        currentSessionId = session.id
        messages = []

        pairedRelayURL = info.relayURL
        pairedRoom = info.room
        pairedServerPubKey = info.serverPublicKey

        Task {
            do {
                try await relay.connect(with: info)
                error = nil
            } catch {
                print("[VoiceVM] Relay connection failed: \(error)")
                self.error = "Relay connection failed: \(error)"
            }
        }
    }

    func configureRelay(with info: PairingInfo) {
        pairedRelayURL = info.relayURL
        pairedRoom = info.room
        pairedServerPubKey = info.serverPublicKey

        Task {
            do {
                try await relay.connect(with: info)
                error = nil
            } catch {
                print("[VoiceVM] Relay connection failed: \(error)")
                self.error = "Relay connection failed: \(error)"
            }
        }
    }

    func restorePairingIfNeeded() {
        guard relayState == .disconnected,
              let relayURL = pairedRelayURL,
              let room = pairedRoom,
              let pubKey = pairedServerPubKey else { return }

        let info = PairingInfo(relayURL: relayURL, room: room, serverPublicKey: pubKey)
        Task {
            do {
                try await relay.connect(with: info)
                error = nil
            } catch {
                self.error = "Reconnection failed: \(error.localizedDescription)"
            }
        }
    }

    var pendingNavigateToSession: String?

    func handlePairingURL(_ url: URL) {
        guard let info = PairingInfo(url: url) else {
            error = "Invalid pairing URL: \(url.absoluteString)"
            return
        }
        startNewSession(with: info)
        pendingNavigateToSession = currentSessionId
    }
}
