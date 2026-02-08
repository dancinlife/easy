import Foundation
import AVFoundation
import UIKit

@Observable
@MainActor
final class VoiceViewModel {
    // State
    var messages: [Message] = []
    var status: Status = .idle
    var error: String?
    var recognizedText: String = ""

    // Utterance Queue (mcp-voice-hooks 패턴)
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

    // Relay 상태
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

        // 실시간 텍스트 업데이트
        speech.onTextChanged = { [weak self] text in
            Task { @MainActor in
                self?.recognizedText = text
            }
        }

        // 발화 캡처 → 큐에 추가 (mcp-voice-hooks: pending)
        speech.onUtteranceCaptured = { [weak self] text in
            Task { @MainActor in
                self?.handleUtterance(text)
            }
        }

        // TTS 완료 → 큐 확인 또는 계속 듣기 (mcp-voice-hooks: auto-wait)
        tts.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.status = .listening
                self.processNextUtterance()
            }
        }

        relay.onServerInfo = { [weak self] info in
            Task { @MainActor in
                guard let self, let sid = self.currentSessionId,
                      var session = self.sessionStore.sessions.first(where: { $0.id == sid }) else { return }
                session.workDir = info.workDir
                session.hostname = info.hostname
                if session.name == "새 세션" {
                    let basename = (info.workDir as NSString).lastPathComponent
                    if !basename.isEmpty { session.name = basename }
                }
                self.sessionStore.updateSession(session)
            }
        }

        relay.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.relayState = newState
            }
        }

        // 포그라운드 복귀 시 재연결
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

    // MARK: - Utterance Queue (mcp-voice-hooks 패턴)

    private func handleUtterance(_ text: String) {
        pendingUtterances.append(text)

        if status == .speaking {
            // Barge-in: TTS 중단 + 새 발화 처리
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
            // 처리 완료 후 큐에 남은 것 확인
            processNextUtterance()
        }
    }

    private func sendToServer(_ text: String) async {
        ensureSession()
        status = .thinking
        recognizedText = text

        // 유저 메시지 추가
        messages.append(Message(role: .user, text: text))
        if let sid = currentSessionId {
            sessionStore.appendMessage(sessionId: sid, message: .init(role: .user, text: text))
        }

        do {
            let answer = try await relay.askText(
                text: text,
                sessionId: currentSessionId
            )

            // 어시스턴트 응답
            messages.append(Message(role: .assistant, text: answer))
            if let sid = currentSessionId {
                sessionStore.appendMessage(sessionId: sid, message: .init(role: .assistant, text: answer))
            }

            // TTS 재생 (마이크는 계속 열려 있음 → barge-in 가능)
            status = .speaking
            tts.speak(answer)
        } catch {
            self.error = error.localizedDescription
            status = .listening
            isProcessing = false
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
            error = "QR 코드를 스캔하여 페어링해주세요"
            return
        }
        guard !openAIKey.isEmpty else {
            error = "설정에서 OpenAI API 키를 입력해주세요"
            return
        }

        Task {
            let permitted = await speech.requestPermission()
            print("[VoiceVM] mic permission: \(permitted)")
            guard permitted else {
                self.error = "마이크 권한이 필요합니다"
                return
            }
            do {
                try speech.startListening()
                status = .listening
                error = nil
                recognizedText = ""
            } catch {
                self.error = "녹음 시작 실패: \(error.localizedDescription)"
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

    func startNewSession(with info: PairingInfo) {
        // 같은 room의 기존 세션이 있으면 재사용
        if let existing = sessionStore.sessions.first(where: { $0.room == info.room }) {
            currentSessionId = existing.id
        } else {
            var session = sessionStore.createSession()
            session.room = info.room
            sessionStore.updateSession(session)
            currentSessionId = session.id
            messages = []
        }

        pairedRelayURL = info.relayURL
        pairedRoom = info.room
        pairedServerPubKey = info.serverPublicKey

        Task {
            do {
                try await relay.connect(with: info)
                error = nil
            } catch {
                print("[VoiceVM] Relay 연결 실패: \(error)")
                self.error = "Relay 연결 실패: \(error)"
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
                print("[VoiceVM] Relay 연결 실패: \(error)")
                self.error = "Relay 연결 실패: \(error)"
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
                self.error = "재연결 실패: \(error.localizedDescription)"
            }
        }
    }

    var pendingNavigateToSession: String?

    func handlePairingURL(_ url: URL) {
        guard let info = PairingInfo(url: url) else {
            error = "유효하지 않은 페어링 URL: \(url.absoluteString)"
            return
        }
        startNewSession(with: info)
        pendingNavigateToSession = currentSessionId
    }
}
