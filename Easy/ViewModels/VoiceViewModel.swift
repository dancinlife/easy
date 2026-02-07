import Foundation
import AVFoundation

@Observable
@MainActor
final class VoiceViewModel {
    // State
    var messages: [Message] = []
    var status: Status = .idle
    var error: String?
    var pendingInput: String?

    // Connection Mode
    enum ConnectionMode: String, CaseIterable {
        case direct = "direct"
        case relay = "relay"

        var label: String {
            switch self {
            case .direct: "직접 연결 (Tailscale)"
            case .relay: "Relay (QR 페어링)"
            }
        }
    }

    var connectionMode: ConnectionMode {
        get {
            ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "direct") ?? .direct
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "connectionMode")
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

    // Settings
    var serverHost: String {
        get { UserDefaults.standard.string(forKey: "serverHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverHost") }
    }
    var serverPort: Int {
        get { UserDefaults.standard.integer(forKey: "serverPort").nonZero ?? 7777 }
        set { UserDefaults.standard.set(newValue, forKey: "serverPort") }
    }
    var autoListen: Bool {
        get { UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoListen") }
    }
    var workDir: String {
        get { UserDefaults.standard.string(forKey: "workDir") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "workDir") }
    }

    // Services
    var speech = SpeechService()
    var tts = TTSService()
    private let claude = ClaudeService()
    private let relay = RelayService()

    enum Status {
        case idle
        case listening
        case thinking
        case speaking
    }

    init() {
        speech.onSpeechFinished = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                if self.status == .thinking || self.status == .speaking {
                    // 응답 대기/TTS 중 → 추가 입력 누적 (barge-in)
                    if let existing = self.pendingInput {
                        self.pendingInput = existing + "\n" + text
                    } else {
                        self.pendingInput = text
                    }
                    self.messages.append(Message(role: .user, text: text))
                    // 계속 듣기
                    try? self.speech.startListening()
                } else {
                    await self.handleUserInput(text)
                }
            }
        }

        tts.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let pending = self.pendingInput {
                    self.pendingInput = nil
                    await self.handleUserInput(pending)
                } else {
                    self.status = .idle
                    if self.autoListen {
                        self.startListening()
                    }
                }
            }
        }

        // Relay 상태 변경 콜백
        relay.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.relayState = newState
            }
        }
    }

    /// 연결이 구성되었는지 확인
    var isConfigured: Bool {
        switch connectionMode {
        case .direct:
            return !serverHost.isEmpty
        case .relay:
            return relayState == .paired
        }
    }

    func startListening() {
        guard isConfigured else {
            switch connectionMode {
            case .direct:
                error = "설정에서 서버 주소를 입력해주세요"
            case .relay:
                error = "QR 코드를 스캔하여 페어링해주세요"
            }
            return
        }

        Task {
            let granted = await speech.requestPermission()
            guard granted else {
                error = speech.error
                return
            }

            do {
                try speech.startListening()
                status = .listening
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stopAll() {
        speech.stopListening()
        tts.stop()
        status = .idle
    }

    /// QR 코드 페어링 처리
    func configureRelay(with info: PairingInfo) {
        pairedRelayURL = info.relayURL
        pairedRoom = info.room

        Task {
            do {
                try await relay.connect(with: info)
                error = nil
            } catch {
                self.error = "Relay 연결 실패: \(error.localizedDescription)"
            }
        }
    }

    /// URL scheme으로 받은 페어링 처리
    func handlePairingURL(_ url: URL) {
        guard let info = PairingInfo(url: url) else {
            error = "유효하지 않은 페어링 URL"
            return
        }
        connectionMode = .relay
        configureRelay(with: info)
    }

    private func handleUserInput(_ text: String) async {
        messages.append(Message(role: .user, text: text))
        status = .thinking

        // 응답 대기 중에도 마이크 열어두기 (barge-in 지원)
        try? speech.startListening()

        do {
            let answer: String

            switch connectionMode {
            case .direct:
                answer = try await claude.ask(
                    question: text,
                    host: serverHost,
                    port: serverPort,
                    workDir: workDir
                )
            case .relay:
                answer = try await relay.ask(
                    question: text,
                    workDir: workDir.isEmpty ? nil : workDir
                )
            }

            messages.append(Message(role: .assistant, text: answer))
            speech.stopListening()
            status = .speaking
            tts.speak(answer)
        } catch {
            self.error = error.localizedDescription
            status = .idle
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
