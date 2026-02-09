import ActivityKit
import AVFoundation
import Foundation
import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "com.ghost.easy", category: "voicevm")

@Observable
@MainActor
final class VoiceViewModel {
    static let shared = VoiceViewModel()

    // CarPlay
    var isCarPlayConnected: Bool = false

    // State
    var messages: [Message] = []
    var status: Status = .idle
    var error: String?
    var recognizedText: String = ""
    var isActivated: Bool = false
    var debugLog: String = ""

    // Utterance Queue (mcp-voice-hooks pattern)
    private var pendingUtterances: [String] = []
    private var isProcessing = false
    private var autoCompactPending = false

    // Live Activity
    private var currentActivity: Activity<EasyActivityAttributes>?

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
    var silenceTimeout: TimeInterval = UserDefaults.standard.object(forKey: "silenceTimeout") as? TimeInterval ?? 3.0 {
        didSet {
            speech.silenceTimeout = silenceTimeout
            UserDefaults.standard.set(silenceTimeout, forKey: "silenceTimeout")
        }
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
    var ttsSpeed: Double {
        get { UserDefaults.standard.object(forKey: "ttsSpeed") as? Double ?? 1.0 }
        set {
            UserDefaults.standard.set(newValue, forKey: "ttsSpeed")
            tts.speed = newValue
        }
    }

    // Theme
    var theme: String = UserDefaults.standard.string(forKey: "theme") ?? "system" {
        didSet { UserDefaults.standard.set(theme, forKey: "theme") }
    }

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    // Speaker mode
    var speakerMode: Bool = UserDefaults.standard.object(forKey: "speakerMode") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(speakerMode, forKey: "speakerMode")
            speech.speakerMode = speakerMode
            applySpeakerOverride(speakerMode)
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

        speech.silenceTimeout = silenceTimeout
        speech.sttLanguage = sttLanguage
        speech.speakerMode = UserDefaults.standard.object(forKey: "speakerMode") as? Bool ?? false
        speech.whisperService = whisper
        Task { await whisper.setAPIKey(openAIKey) }
        tts.apiKey = openAIKey.isEmpty ? nil : openAIKey
        tts.voice = ttsVoice
        tts.speed = ttsSpeed

        // Wake word debug (shows which word triggered)
        speech.onDebugLog = { [weak self] text in
            Task { @MainActor in
                self?.debugLog = text
            }
        }

        // Real-time text updates
        speech.onTextChanged = { [weak self] text in
            Task { @MainActor in
                self?.recognizedText = text
            }
        }

        // Wake word detected → stop TTS if playing → ding + activate
        speech.onTriggerDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.status == .speaking {
                    self.tts.stop()
                    self.isProcessing = false
                }
                self.isActivated = true
                self.status = .listening
                self.recognizedText = ""
                self.updateActivity(status: .listening)
                self.speech.playDing()
            }
        }

        // Utterance captured → add to queue (mcp-voice-hooks: pending)
        speech.onUtteranceCaptured = { [weak self] text in
            Task { @MainActor in
                self?.handleUtterance(text)
            }
        }

        // Activation timeout → back to passive
        speech.onActivationTimeout = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isActivated = false
                self.recognizedText = ""
            }
        }

        // TTS finished → check queue or resume listening
        tts.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.currentSessionId != nil else { return }
                // Skip if barge-in already took over
                guard !self.isActivated else { return }
                self.isProcessing = false

                // Auto-compact if pending and queue is empty
                if self.autoCompactPending && self.pendingUtterances.isEmpty {
                    self.autoCompactPending = false
                    Task { await self.performCompact() }
                    return
                }

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
                      var session = self.sessionStore.sessions.first(where: { $0.id == sid }) else {
                    log.warning("server_info ignored: no session")
                    return
                }
                session.hostname = info.hostname
                let newWorkDir = (info.workDir as NSString).expandingTildeInPath
                session.workDir = newWorkDir
                let basename = (newWorkDir as NSString).lastPathComponent
                log.info("server_info: workDir=\(info.workDir) → basename=\(basename) title=\(info.title ?? "nil")")
                self.debugLog = "workDir: \(info.workDir)"
                if let title = info.title, !title.isEmpty {
                    session.name = title
                } else if !basename.isEmpty {
                    session.name = basename
                }
                self.sessionStore.updateSession(session)
            }
        }

        relay.onSessionEnd = { [weak self] sessionId in
            Task { @MainActor in
                guard let self else { return }
                log.info("session_end: \(sessionId)")
                self.sessionStore.deleteSession(id: sessionId)
                if self.currentSessionId == sessionId {
                    self.stopAll()
                    self.currentSessionId = self.sessionStore.sessions.first?.id
                }
            }
        }

        relay.onCompactNeeded = { [weak self] sessionId in
            Task { @MainActor in
                guard let self else { return }
                guard self.currentSessionId == sessionId else { return }
                log.notice("auto-compact needed for session \(sessionId)")
                self.autoCompactPending = true
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

    // MARK: - Voice Commands

    private static let clearKeywords = ["clear", "new conversation", "reset conversation", "대화 초기화", "세션 초기화", "클리어", "새 대화"]
    private static let compactKeywords = ["compact", "summarize", "summary", "대화 정리", "대화 요약", "세션 요약", "컴팩트", "요약해"]

    private enum VoiceCommand {
        case clear
        case compact
    }

    private func detectVoiceCommand(_ text: String) -> VoiceCommand? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.clearKeywords.contains(where: { lower.contains($0) }) { return .clear }
        if Self.compactKeywords.contains(where: { lower.contains($0) }) { return .compact }
        return nil
    }

    // MARK: - Utterance Queue (mcp-voice-hooks pattern)

    private func handleUtterance(_ text: String) {
        isActivated = false

        // Check for voice commands before queueing
        if let command = detectVoiceCommand(text) {
            if status == .speaking {
                tts.stop()
            }
            pendingUtterances.removeAll()
            isProcessing = false
            Task { await executeVoiceCommand(command) }
            return
        }

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

    private func executeVoiceCommand(_ command: VoiceCommand) async {
        switch command {
        case .clear:
            guard let sid = currentSessionId else { return }
            log.info("Voice command: clear session \(sid)")
            await relay.sendSessionClear(sessionId: sid)
            messages = []
            if let session = sessionStore.sessions.first(where: { $0.id == sid }) {
                var cleared = session
                cleared.messages = []
                sessionStore.updateSession(cleared)
            }
            newSession()
            status = .speaking
            tts.speak(sttLanguage == "ko" ? "대화를 초기화했습니다." : "Conversation cleared.")
            do {
                try speech.startListening()
            } catch {
                log.error("mic restart after clear: \(error)")
            }

        case .compact:
            await performCompact()
        }
    }

    private func performCompact() async {
        guard let oldSid = currentSessionId else { return }
        log.info("Compact: summarizing session \(oldSid)")

        let compactPrompt = sttLanguage == "ko"
            ? "지금까지 대화를 간결하게 요약해줘."
            : "Briefly summarize our conversation so far."

        let summary = await sendToServer(compactPrompt)

        guard let summary, !summary.isEmpty else {
            log.warning("Compact: no summary received")
            return
        }

        // Send compact with summary to server (will inject into next session)
        await relay.sendSessionCompact(sessionId: oldSid, summary: summary)

        // Clear iOS messages and start new session
        messages = []
        newSession()
        log.info("Compact: done — summary (\(summary.count) chars) stored for next session")
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

    @discardableResult
    private func sendToServer(_ text: String) async -> String? {
        ensureSession()
        speech.stopListening()
        status = .thinking
        recognizedText = text
        updateActivity(status: .thinking, text: text)
        log.info("send: \(text.prefix(30))")

        // Add user message
        messages.append(Message(role: .user, text: text))
        if let sid = currentSessionId {
            sessionStore.appendMessage(sessionId: sid, message: .init(role: .user, text: text))
        }

        do {
            var fullText = ""
            var startedSpeaking = false

            let stream = await relay.askTextStreaming(
                text: text,
                sessionId: currentSessionId
            )

            for try await event in stream {
                guard currentSessionId != nil else {
                    log.warning("session closed!")
                    return nil
                }

                switch event {
                case .chunk(let sentence, let index):
                    log.info("chunk[\(index)]: \(sentence.prefix(40))")
                    fullText += (fullText.isEmpty ? "" : " ") + sentence

                    // Start TTS + mic on first chunk
                    if !startedSpeaking {
                        startedSpeaking = true
                        status = .speaking
                        updateActivity(status: .speaking, text: String(sentence.prefix(100)))
                        do {
                            try speech.startListening()
                        } catch {
                            log.error("mic restart during TTS: \(error)")
                        }
                    }
                    tts.enqueueSentence(sentence)

                case .done(let text):
                    log.info("done: \(text.prefix(40))")
                    // Use full text from server if no chunks were received
                    if fullText.isEmpty {
                        fullText = text
                        // No chunks came, play entire text
                        status = .speaking
                        updateActivity(status: .speaking, text: String(text.prefix(100)))
                        tts.enqueueSentence(text)
                        do {
                            try speech.startListening()
                        } catch {
                            log.error("mic restart during TTS: \(error)")
                        }
                    }
                }
            }

            // Save assistant response
            let answer = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }

            messages.append(Message(role: .assistant, text: answer))
            if let sid = currentSessionId {
                sessionStore.appendMessage(sessionId: sid, message: .init(role: .assistant, text: answer))
            }
            return answer
        } catch {
            guard currentSessionId != nil else { return nil }
            log.error("ERR: \(error.localizedDescription.prefix(50))")
            self.error = error.localizedDescription
            isProcessing = false
            if relayState == .paired {
                startListening()
            } else {
                status = .idle
                endActivity()
            }
            return nil
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
        log.info("startListening called, isConfigured=\(self.isConfigured), openAIKey=\(self.openAIKey.isEmpty ? "empty" : "set")")
        debugLog = "startListening..."
        guard isConfigured else {
            error = "Scan QR code to pair"
            debugLog = "not configured"
            return
        }
        guard !openAIKey.isEmpty else {
            error = "Enter OpenAI API key in Settings"
            debugLog = "no API key"
            return
        }

        Task {
            let permitted = await speech.requestPermission()
            log.info("mic permission: \(permitted)")
            guard permitted else {
                self.error = "Microphone permission required"
                debugLog = "no mic perm"
                return
            }
            do {
                debugLog = "starting engine..."
                try speech.startListening()
                status = .listening
                error = nil
                recognizedText = ""
                isActivated = false
                debugLog = "listening ok"
                if currentActivity == nil {
                    startActivity()
                } else {
                    updateActivity(status: .listening)
                }
            } catch {
                self.error = "Failed to start recording: \(error.localizedDescription)"
                debugLog = "engine err: \(error.localizedDescription.prefix(40))"
            }
        }
    }

    func stopAll() {
        speech.stopListening()
        tts.stop()
        pendingUtterances.removeAll()
        isProcessing = false
        status = .idle
        endActivity()
    }

    // MARK: - Speaker Mode

    private func applySpeakerOverride(_ on: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            log.error("Speaker override failed: \(error)")
        }
    }

    // MARK: - Live Activity

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let sessionName: String
        if let sid = currentSessionId,
           let session = sessionStore.sessions.first(where: { $0.id == sid }) {
            sessionName = session.name
        } else {
            sessionName = "Easy"
        }

        let attributes = EasyActivityAttributes(sessionName: sessionName)
        let state = EasyActivityAttributes.ContentState(status: .listening, recognizedText: "")

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            log.error("Live Activity start failed: \(error)")
        }
    }

    private func updateActivity(status activityStatus: EasyActivityAttributes.ContentState.Status, text: String = "") {
        guard let activity = currentActivity else { return }
        let state = EasyActivityAttributes.ContentState(status: activityStatus, recognizedText: text)
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func endActivity() {
        guard let activity = currentActivity else { return }
        let finalState = EasyActivityAttributes.ContentState(status: .listening, recognizedText: "")
        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    // MARK: - Relay

    func closeCurrentSession() {
        guard let id = currentSessionId else { return }
        endActivity()
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
                log.error("Relay connection failed: \(error)")
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
                log.error("Relay connection failed: \(error)")
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
