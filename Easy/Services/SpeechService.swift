import Foundation
import AVFoundation
import Speech

final class SpeechService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?

    // Audio buffer for Whisper (active mode only)
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

    /// Apple SFSpeechRecognizer for on-device wake word detection
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Whisper API service (injected externally)
    var whisperService: WhisperService?

    /// Delivers finalized utterance text
    var onUtteranceCaptured: ((String) -> Void)?
    /// Real-time status text
    var onTextChanged: ((String) -> Void)?
    /// Debug log callback
    var onDebugLog: ((String) -> Void)?

    private(set) var isListening = false

    /// VAD settings
    private let speechThresholdDB: Float = -50
    private let minSpeechDuration: TimeInterval = 0.3
    private var speechStartTime: Date?

    /// Ding playback
    private var dingAudioPlayer: AVAudioPlayer?

    /// Whisper hallucination filter
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
            let micGranted = await AVAudioApplication.requestRecordPermission()
            if !micGranted { return false }
        } else if micStatus != .granted {
            return false
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        }
        return speechStatus == .authorized
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

        // Install audio tap — routes to either SFSpeech (passive) or VAD+Whisper (active)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.handleAudioTap(buffer)
        }

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        isSpeaking = false
        speechStartTime = nil
        isActivated = false

        engine.prepare()
        try engine.start()
        isListening = true

        // Start in passive mode (SFSpeechRecognizer for wake word)
        startPassiveRecognition()
        print("[Speech] Started (passive mode, on-device wake word)")
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        stopPassiveRecognition()

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

        // Return to passive mode
        startPassiveRecognition()

        DispatchQueue.main.async {
            self.onTextChanged?("")
        }
        print("[Speech] Back to passive mode")
    }

    // MARK: - Audio Tap Router

    private func handleAudioTap(_ buffer: AVAudioPCMBuffer) {
        if isActivated {
            // Active mode → VAD + accumulate for Whisper
            processAudioBuffer(buffer)
        } else {
            // Passive mode → feed to SFSpeechRecognizer
            recognitionRequest?.append(buffer)
        }
    }

    // MARK: - Passive Mode (SFSpeechRecognizer, on-device)

    private func startPassiveRecognition() {
        stopPassiveRecognition()

        // Always use English for wake word "easy"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer = recognizer

        guard let recognizer, recognizer.isAvailable else {
            print("[Speech] SFSpeechRecognizer not available!")
            DispatchQueue.main.async { self.onDebugLog?("SFSpeech NOT available") }
            return
        }

        let onDevice = recognizer.supportsOnDeviceRecognition
        print("[Speech] SFSpeech available, onDevice=\(onDevice)")
        DispatchQueue.main.async { self.onDebugLog?("SFSpeech ok, onDevice=\(onDevice)") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let lower = text.lowercased()
                print("[Speech] SFSpeech partial: \"\(text)\"")
                DispatchQueue.main.async { self.onDebugLog?("heard: \(lower)") }

                if self.containsTrigger(lower) {
                    print("[Speech] Wake word detected! \"\(text)\"")
                    self.stopPassiveRecognition()
                    self.isActivated = true
                    DispatchQueue.main.async {
                        self.onTextChanged?("")
                        self.onTriggerDetected?()
                    }
                    return
                }
            }

            if let error {
                let nsError = error as NSError
                print("[Speech] SFSpeech error: \(nsError.domain) \(nsError.code) \(error.localizedDescription)")
                DispatchQueue.main.async { self.onDebugLog?("err: \(nsError.code) \(error.localizedDescription)") }
                // Auto-restart (SFSpeech times out after ~1 min, code 216 = end of utterance)
                if self.isListening && !self.isActivated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.isListening, !self.isActivated else { return }
                        self.startPassiveRecognition()
                    }
                }
            }
        }

        print("[Speech] Passive recognition started")
    }

    private func stopPassiveRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        speechRecognizer = nil
    }

    // MARK: - Active Mode (VAD + Whisper)

    private var dbLogCounter = 0
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))

        dbLogCounter += 1
        if dbLogCounter % 50 == 0 {
            print("[Speech] dB=\(String(format: "%.1f", db)) threshold=\(speechThresholdDB) isSpeaking=\(isSpeaking)")
        }

        if db > speechThresholdDB {
            if !isSpeaking {
                isSpeaking = true
                speechStartTime = Date()
                DispatchQueue.main.async {
                    self.onTextChanged?("Listening...")
                }
            }

            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()

            resetSilenceTimer()
        } else if isSpeaking {
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()
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
        guard isSpeaking else { return }

        if let start = speechStartTime, Date().timeIntervalSince(start) < minSpeechDuration {
            isSpeaking = false
            speechStartTime = nil
            bufferLock.lock()
            audioBuffer.removeAll()
            bufferLock.unlock()
            return
        }

        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        isSpeaking = false
        speechStartTime = nil

        guard !samples.isEmpty else { return }

        let duration = Double(samples.count) / recordingSampleRate
        print("[Speech] Captured: \(String(format: "%.1f", duration))s, \(samples.count) samples")

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

                // Deliver utterance and deactivate
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

    // MARK: - Ding Sound

    /// Stop engine → play ding → restart engine fresh for active mode
    func playDing() {
        // Fully stop engine
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        print("[Speech] Engine stopped for ding")

        let sampleRate: Double = 44100
        let duration: Double = 0.25
        let count = Int(sampleRate * duration)

        var d = Data()
        let dataSize = UInt32(count * 2)
        d.append(contentsOf: [UInt8]("RIFF".utf8))
        d.appendLittleEndian(36 + dataSize)
        d.append(contentsOf: [UInt8]("WAVE".utf8))
        d.append(contentsOf: [UInt8]("fmt ".utf8))
        d.appendLittleEndian(UInt32(16))
        d.appendLittleEndian(UInt16(1))
        d.appendLittleEndian(UInt16(1))
        d.appendLittleEndian(UInt32(sampleRate))
        d.appendLittleEndian(UInt32(sampleRate) * 2)
        d.appendLittleEndian(UInt16(2))
        d.appendLittleEndian(UInt16(16))
        d.append(contentsOf: [UInt8]("data".utf8))
        d.appendLittleEndian(dataSize)

        // Siri-style two-tone rising chime
        let freq1: Double = 880   // A5
        let freq2: Double = 1320  // E6 (perfect fifth up)
        let midpoint = duration * 0.45
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let freq: Double
            let localT: Double
            if t < midpoint {
                freq = freq1
                localT = t / midpoint
            } else {
                freq = freq2
                localT = (t - midpoint) / (duration - midpoint)
            }
            // Smooth bell envelope: quick attack, gentle decay
            let envelope = sin(.pi * localT) * (1.0 - localT * 0.3)
            let value = sin(2.0 * .pi * freq * t) * envelope * 0.7
            let sample = Int16(max(-1, min(1, value)) * Double(Int16.max))
            d.appendLittleEndian(sample)
        }

        do {
            let player = try AVAudioPlayer(data: d, fileTypeHint: "wav")
            player.volume = 1.0
            dingAudioPlayer = player
            player.play()
            print("[Speech] Ding playing")

            // Restart engine fresh after ding
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                guard let self else { return }
                self.dingAudioPlayer = nil
                self.restartEngineForActiveMode()
            }
        } catch {
            print("[Speech] Ding error: \(error)")
            restartEngineForActiveMode()
        }
    }

    /// Create fresh engine for active mode (Whisper recording)
    private func restartEngineForActiveMode() {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        recordingSampleRate = nativeFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.handleAudioTap(buffer)
        }

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        isSpeaking = false
        speechStartTime = nil

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            engine.prepare()
            try engine.start()
            print("[Speech] Engine restarted for active mode")
        } catch {
            print("[Speech] Engine restart failed: \(error)")
        }
    }

    // MARK: - Trigger Word

    /// Fuzzy match for wake word — accepts common SFSpeech misrecognitions
    private let triggerVariants: Set<String> = [
        "easy", "eazy", "ease", "eezy", "e z",
        "izi", "izzy", "easey", "ezee",
    ]

    private func containsTrigger(_ text: String) -> Bool {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }

        for word in words {
            if triggerVariants.contains(word) { return true }
            // Substring check: any word starting with "eas" or "eaz"
            if word.hasPrefix("eas") || word.hasPrefix("eaz") || word.hasPrefix("eez") {
                return true
            }
        }
        return false
    }

    // MARK: - WAV Encoding

    private func createWAV(from samples: [Float], sampleRate: Double) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()

        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.appendLittleEndian(fileSize)
        data.append(contentsOf: [UInt8]("WAVE".utf8))

        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        data.append(contentsOf: [UInt8]("data".utf8))
        data.appendLittleEndian(dataSize)

        for sample in int16Samples {
            data.appendLittleEndian(sample)
        }

        return data
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
