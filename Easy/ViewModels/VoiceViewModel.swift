import Foundation
import AVFoundation

@Observable
@MainActor
final class VoiceViewModel {
    // State
    var messages: [Message] = []
    var status: Status = .idle
    var error: String?

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

    // Services
    var speech = SpeechService()
    var tts = TTSService()
    private let claude = ClaudeService()

    enum Status {
        case idle
        case listening
        case thinking
        case speaking
    }

    init() {
        speech.onSpeechFinished = { [weak self] text in
            Task { @MainActor in
                await self?.handleUserInput(text)
            }
        }

        tts.onFinished = { [weak self] in
            Task { @MainActor in
                self?.status = .idle
                if self?.autoListen == true {
                    self?.startListening()
                }
            }
        }
    }

    func startListening() {
        guard !serverHost.isEmpty else {
            error = "설정에서 서버 주소를 입력해주세요"
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

    private func handleUserInput(_ text: String) async {
        messages.append(Message(role: .user, text: text))
        status = .thinking

        do {
            let answer = try await claude.ask(
                question: text,
                host: serverHost,
                port: serverPort
            )
            messages.append(Message(role: .assistant, text: answer))
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
