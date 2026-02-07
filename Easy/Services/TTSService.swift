import Foundation
import AVFoundation

@Observable
@MainActor
final class TTSService {
    var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = TTSDelegate()
    var onFinished: (() -> Void)?

    var speechRate: Float = 0.5
    var voiceIdentifier: String = "ko-KR"

    init() {
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
                self?.onFinished?()
            }
        }
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceIdentifier)
        utterance.rate = speechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

private final class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
