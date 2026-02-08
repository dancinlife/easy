import Foundation
import AVFoundation

@Observable
@MainActor
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    var isSpeaking = false
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    var speechRate: Float = 0.5
    var voiceIdentifier: String = "ko-KR"

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

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

    // AVSpeechSynthesizerDelegate
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // 오디오 세션 모드 유지 확인 (.voiceChat 통일)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])

        Task { @MainActor in
            self.isSpeaking = false
            self.onFinished?()
        }
    }
}
