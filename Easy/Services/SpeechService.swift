import Foundation
import AVFoundation

final class SpeechService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?

    // Audio buffer (accumulate Float samples)
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isSpeaking = false
    private var recordingSampleRate: Double = 16000

    var silenceTimeout: TimeInterval = 1.5
    var sttLanguage: String = "en"

    /// Wake word trigger
    var triggerWord: String = "easy"
    private(set) var isActivated: Bool = false
    var onTriggerDetected: (() -> Void)?

    /// Whisper API service (injected externally)
    var whisperService: WhisperService?

    /// Delivers finalized utterance text
    var onUtteranceCaptured: ((String) -> Void)?
    /// Real-time status text
    var onTextChanged: ((String) -> Void)?

    private(set) var isListening = false

    /// VAD settings
    private let speechThresholdDB: Float = -50  // speech detected above this
    private let minSpeechDuration: TimeInterval = 0.3  // min speech duration (sec)
    private var speechStartTime: Date?

    /// Whisper hallucination filter — known phrases repeated on silence/noise
    private let hallucinationPhrases: [String] = [
        "MBC 뉴스", "이덕영입니다", "시청해 주셔서 감사합니다",
        "구독과 좋아요", "영상이 도움이 되셨다면", "감사합니다",
        "자막 제공", "한국어 자막", "한글자막", "자막 by",
        "구독", "좋아요", "알림 설정", "채널에 가입",
        "you", "thank you", "thanks for watching",
        "subscribe", "like and subscribe",
        "sous-titres", "sous-titrage", "Untertitel",
        "请不吝点赞", "订阅", "小铃铛",
    ]

    func requestPermission() async -> Bool {
        let micStatus = AVAudioApplication.shared.recordPermission
        if micStatus == .undetermined {
            return await AVAudioApplication.requestRecordPermission()
        }
        return micStatus == .granted
    }

    func startListening() throws {
        guard !isListening else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        guard audioSession.isInputAvailable else { return }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        recordingSampleRate = nativeFormat.sampleRate

        // Install audio tap — RMS-based VAD + buffer accumulation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        isSpeaking = false
        speechStartTime = nil

        engine.prepare()
        try engine.start()
        isListening = true
        print("[Speech] Whisper mode started (\(sttLanguage))")
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        isListening = false
        isActivated = false
        isSpeaking = false
        speechStartTime = nil

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
    }

    func restartRecognition() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        isActivated = false
        isSpeaking = false
        speechStartTime = nil

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()

        DispatchQueue.main.async {
            self.onTextChanged?("")
        }
        print("[Speech] Recognition restarted")
    }

    // MARK: - Audio Processing

    private var dbLogCounter = 0
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        // RMS → dB calculation
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))

        dbLogCounter += 1
        if dbLogCounter % 50 == 0 {
            print("[Speech] dB=\(String(format: "%.1f", db)) threshold=\(speechThresholdDB) isSpeaking=\(isSpeaking)")
        }

        if db > speechThresholdDB {
            // Speech detected
            if !isSpeaking {
                isSpeaking = true
                speechStartTime = Date()
                DispatchQueue.main.async {
                    self.onTextChanged?("Listening...")
                }
            }

            // Append samples to buffer
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()

            // Reset silence timer
            resetSilenceTimer()
        } else if isSpeaking {
            // Speaking but quiet → keep adding to buffer (padding)
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()

            // Silence: don't reset timer → capture when existing timer expires
        }
    }

    private func resetSilenceTimer() {
        let timeout = silenceTimeout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                self?.captureAndTranscribe()
            }
        }
    }

    private func captureAndTranscribe() {
        guard isSpeaking else {
            print("[Speech] captureAndTranscribe: isSpeaking=false, skip")
            return
        }

        // Check minimum speech duration
        if let start = speechStartTime, Date().timeIntervalSince(start) < minSpeechDuration {
            isSpeaking = false
            speechStartTime = nil
            bufferLock.lock()
            audioBuffer.removeAll()
            bufferLock.unlock()
            return
        }

        // Copy buffer and clear
        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        isSpeaking = false
        speechStartTime = nil

        guard !samples.isEmpty else {
            print("[Speech] Empty buffer, skip")
            return
        }

        let duration = Double(samples.count) / recordingSampleRate
        print("[Speech] Captured: \(String(format: "%.1f", duration))s, \(samples.count) samples")

        // Audio energy check — skip if too quiet to prevent Whisper hallucination
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let avgDB = 20 * log10(max(rms, 1e-10))
        if avgDB < -45 {
            print("[Speech] avgDB=\(String(format: "%.1f", avgDB)) too quiet, skip")
            DispatchQueue.main.async { self.onTextChanged?("") }
            return
        }

        DispatchQueue.main.async {
            self.onTextChanged?("Recognizing...")
        }

        let wavData = createWAV(from: samples, sampleRate: recordingSampleRate)
        let lang = sttLanguage

        Task {
            do {
                guard let whisper = whisperService else {
                    print("[Speech] WhisperService not configured")
                    return
                }
                let text = try await whisper.transcribe(audioData: wavData, language: lang)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    DispatchQueue.main.async { self.onTextChanged?("") }
                    return
                }

                // Whisper hallucination filter
                let lower = trimmed.lowercased()
                let isHallucination = self.hallucinationPhrases.contains { lower.contains($0.lowercased()) }
                if isHallucination {
                    print("[Speech] Hallucination filter: \"\(trimmed)\" → skip")
                    DispatchQueue.main.async { self.onTextChanged?("") }
                    return
                }

                print("[Speech] Whisper recognized: \"\(trimmed)\"")

                // Wake word gate
                if !self.isActivated {
                    if self.isTriggerWord(trimmed) {
                        print("[Speech] Trigger word detected!")
                        self.isActivated = true
                        DispatchQueue.main.async {
                            self.onTextChanged?("")
                            self.onTriggerDetected?()
                        }
                    } else {
                        print("[Speech] Waiting for trigger word, ignoring: \"\(trimmed)\"")
                        DispatchQueue.main.async { self.onTextChanged?("") }
                    }
                    return
                }

                // Activated → deliver utterance and deactivate
                self.isActivated = false
                DispatchQueue.main.async {
                    self.onTextChanged?(trimmed)
                    self.onUtteranceCaptured?(trimmed)
                }
            } catch {
                print("[Speech] Whisper error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onTextChanged?("")
                }
            }
        }
    }

    // MARK: - Trigger Word

    private func isTriggerWord(_ text: String) -> Bool {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return cleaned == triggerWord.lowercased()
    }

    // MARK: - WAV Encoding

    private func createWAV(from samples: [Float], sampleRate: Double) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        // Float → Int16
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.appendLittleEndian(fileSize)
        data.append(contentsOf: [UInt8]("WAVE".utf8))

        // fmt chunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))       // chunk size
        data.appendLittleEndian(UInt16(1))         // PCM format
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        // data chunk
        data.append(contentsOf: [UInt8]("data".utf8))
        data.appendLittleEndian(dataSize)

        for sample in int16Samples {
            data.appendLittleEndian(sample)
        }

        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
