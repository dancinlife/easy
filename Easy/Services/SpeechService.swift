import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechService {
    var recognizedText = ""
    var isListening = false
    var error: String?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var silenceTimer: Timer?
    var silenceTimeout: TimeInterval = 1.5
    var onSpeechFinished: ((String) -> Void)?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    }

    func requestPermission() async -> Bool {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            error = "음성 인식 권한이 필요합니다"
            return false
        }

        let audioStatus = await AVAudioApplication.requestRecordPermission()
        guard audioStatus else {
            error = "마이크 권한이 필요합니다"
            return false
        }

        return true
    }

    func startListening() throws {
        guard let recognizer, recognizer.isAvailable else {
            error = "음성 인식을 사용할 수 없습니다"
            return
        }

        stopListening()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true
        if #available(iOS 18.0, *) {
            recognitionRequest.addsPunctuation = true
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.recognizedText = result.bestTranscription.formattedString
                self.resetSilenceTimer()
            }

            if let error {
                self.error = error.localizedDescription
                self.stopListening()
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        recognizedText = ""
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            let text = self.recognizedText
            if !text.isEmpty {
                self.stopListening()
                self.onSpeechFinished?(text)
            }
        }
    }
}
