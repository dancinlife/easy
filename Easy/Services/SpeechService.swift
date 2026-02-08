import Foundation
import AVFoundation
import Speech
import os

private let log = Logger(subsystem: "com.ghost.easy", category: "speech")

final class SpeechService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?

    // Audio buffer for Whisper (active mode only)
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isSpeaking = false
    private var recordingSampleRate: Double = 16000

    var silenceTimeout: TimeInterval = 3.0
    var sttLanguage: String = "en"
    var speakerMode: Bool = false

    /// Wake word trigger
    var triggerWord: String = "easy"
    private(set) var isActivated: Bool = false
    var onTriggerDetected: (() -> Void)?

    /// Apple SFSpeechRecognizer for on-device wake word detection
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var passiveWatchdog: Timer?

    /// Whisper API service (injected externally)
    var whisperService: WhisperService?

    /// Delivers finalized utterance text
    var onUtteranceCaptured: ((String) -> Void)?
    /// Real-time status text
    var onTextChanged: ((String) -> Void)?
    /// Debug log callback
    var onDebugLog: ((String) -> Void)?

    private(set) var isListening = false

    /// VAD settings — relative drop detection
    private let dropThresholdDB: Float = 8  // dB drop from peak = silence
    private var peakDB: Float = -100
    private var speechStartTime: Date?

    /// Watchdog: track last callback time to detect stale recognition
    private var lastCallbackTime: Date?

    /// Activation timeout — return to passive if no speech after wake word
    private var activationTimer: Timer?
    var onActivationTimeout: (() -> Void)?

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
        if isListening { stopListening() }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        if speakerMode {
            try audioSession.overrideOutputAudioPort(.speaker)
        }

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
        log.info("Started (passive mode, on-device wake word)")
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        activationTimer?.invalidate()
        activationTimer = nil

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
        peakDB = -100

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()

        // Return to passive mode
        startPassiveRecognition()

        DispatchQueue.main.async {
            self.onTextChanged?("")
        }
        log.info("Back to passive mode")
    }

    // MARK: - Audio Tap Router

    private var tapCounter = 0
    private var callbackCounter = 0
    private func handleAudioTap(_ buffer: AVAudioPCMBuffer) {
        tapCounter += 1
        if isActivated {
            processAudioBuffer(buffer)
        } else {
            let hasReq = recognitionRequest != nil
            recognitionRequest?.append(buffer)
            if tapCounter % 200 == 0 {
                let tc = tapCounter
                let cc = callbackCounter
                DispatchQueue.main.async {
                    self.onDebugLog?("tap=\(tc) req=\(hasReq) cb=\(cc)")
                }
            }
        }
    }

    // MARK: - Passive Mode (SFSpeechRecognizer, on-device)

    private func startPassiveRecognition() {
        stopPassiveRecognition()
        DispatchQueue.main.async { self.onDebugLog?("init SFSpeech...") }

        // Always use English for wake word "easy"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer = recognizer

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        log.info("SFSpeech auth=\(authStatus.rawValue)")

        guard let recognizer, recognizer.isAvailable else {
            log.error("SFSpeechRecognizer not available! auth=\(authStatus.rawValue)")
            DispatchQueue.main.async { self.onDebugLog?("SFSpeech NOT avail auth=\(authStatus.rawValue)") }
            return
        }

        let onDevice = recognizer.supportsOnDeviceRecognition
        log.info("SFSpeech available, onDevice=\(onDevice)")
        DispatchQueue.main.async { self.onDebugLog?("SFSpeech ok onDev=\(onDevice)") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.callbackCounter += 1
            self.lastCallbackTime = Date()

            if let result {
                let text = result.bestTranscription.formattedString
                let lower = text.lowercased()
                log.debug("SFSpeech partial: \"\(text)\"")
                DispatchQueue.main.async { self.onDebugLog?("heard: \(lower)") }

                if self.containsTrigger(lower) {
                    log.notice("Wake word detected! \"\(text)\"")
                    self.stopPassiveRecognition()
                    self.isActivated = true
                    DispatchQueue.main.async {
                        self.onTextChanged?("")
                        self.onTriggerDetected?()
                        // Activation timeout: return to passive if no speech
                        self.activationTimer?.invalidate()
                        self.activationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                            guard let self, self.isActivated else { return }
                            log.info("Activation timeout, back to passive")
                            self.isActivated = false
                            self.isSpeaking = false
                            self.speechStartTime = nil
                            self.peakDB = -100
                            self.bufferLock.lock()
                            self.audioBuffer.removeAll()
                            self.bufferLock.unlock()
                            self.startPassiveRecognition()
                            DispatchQueue.main.async {
                                self.onDebugLog?("timeout → passive")
                                self.onActivationTimeout?()
                            }
                        }
                    }
                    return
                }

                // Utterance finalized → restart immediately for continuous listening
                if result.isFinal && self.isListening && !self.isActivated {
                    log.info("SFSpeech finalized, restarting")
                    self.startPassiveRecognition()
                    return
                }
            }

            if let error {
                let nsError = error as NSError
                // 1110 = normal cancellation (intentional stop/restart) — do NOT restart
                if nsError.code == 1110 {
                    return
                }
                log.error("SFSpeech error: \(nsError.domain) \(nsError.code) \(error.localizedDescription)")
                // Auto-restart quickly for real errors
                if self.isListening && !self.isActivated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, self.isListening, !self.isActivated else { return }
                        self.startPassiveRecognition()
                    }
                }
            }
        }

        tapCounter = 0
        callbackCounter = 0
        lastCallbackTime = nil
        log.info("Passive recognition started")
        DispatchQueue.main.async { self.onDebugLog?("passive started") }

        // Watchdog: repeating timer checks for stale recognition every 5s
        DispatchQueue.main.async { [weak self] in
            self?.passiveWatchdog?.invalidate()
            self?.passiveWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self, self.isListening, !self.isActivated else { return }
                // No callback ever received, or no callback in last 5s
                let stale: Bool
                if let last = self.lastCallbackTime {
                    stale = Date().timeIntervalSince(last) > 5.0
                } else {
                    stale = self.callbackCounter == 0
                }
                guard stale else { return }
                log.warning("SFSpeech watchdog: stale recognition, restarting (cb=\(self.callbackCounter))")
                DispatchQueue.main.async { self.onDebugLog?("watchdog restart") }
                self.startPassiveRecognition()
            }
        }
    }

    private func stopPassiveRecognition() {
        passiveWatchdog?.invalidate()
        passiveWatchdog = nil
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
            let dbVal = db
            let pk = peakDB
            let speaking = isSpeaking
            DispatchQueue.main.async {
                self.onDebugLog?("dB=\(String(format: "%.0f", dbVal)) pk=\(String(format: "%.0f", pk)) spk=\(speaking)")
            }
        }

        if !isSpeaking {
            // Not speaking yet — detect speech start when dB rises significantly
            // Use first few buffers to establish baseline, then detect rise
            if peakDB < -99 {
                // First buffer — set baseline
                peakDB = db
            } else if db > peakDB + 3 {
                // Significant rise from baseline = speech started
                isSpeaking = true
                peakDB = db
                speechStartTime = Date()
                resetSilenceTimer()
                DispatchQueue.main.async {
                    self.onTextChanged?("Listening...")
                }
            } else {
                // Update baseline (slowly track ambient level)
                peakDB = peakDB * 0.95 + db * 0.05
            }
        } else {
            // Speaking — track peak and detect drop
            if db > peakDB {
                peakDB = db
            }

            if db < peakDB - dropThresholdDB {
                // Significant drop — don't reset silence timer (let it expire)
            } else {
                // Still speaking — reset silence timer
                resetSilenceTimer()
            }
        }

        // Always capture audio once speaking starts
        if isSpeaking {
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()
        }
    }

    /// Reset active mode state for retry — keeps isActivated true, restarts activation timer
    private func resetActiveState() {
        isSpeaking = false
        speechStartTime = nil
        peakDB = -100
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()

        // Restart activation timer so it eventually times out
        activationTimer?.invalidate()
        activationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self, self.isActivated else { return }
            log.info("Activation timeout after retry, back to passive")
            self.isActivated = false
            self.isSpeaking = false
            self.peakDB = -100
            self.bufferLock.lock()
            self.audioBuffer.removeAll()
            self.bufferLock.unlock()
            self.startPassiveRecognition()
            DispatchQueue.main.async {
                self.onDebugLog?("timeout → passive")
                self.onActivationTimeout?()
            }
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

        // if let start = speechStartTime, Date().timeIntervalSince(start) < minSpeechDuration {
        //     isSpeaking = false
        //     speechStartTime = nil
        //     bufferLock.lock()
        //     audioBuffer.removeAll()
        //     bufferLock.unlock()
        //     return
        // }

        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        isSpeaking = false
        speechStartTime = nil
        peakDB = -100

        guard !samples.isEmpty else { return }

        let duration = Double(samples.count) / recordingSampleRate
        log.info("Captured: \(String(format: "%.1f", duration))s, \(samples.count) samples")

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let avgDB = 20 * log10(max(rms, 1e-10))
        log.debug("avgDB=\(String(format: "%.1f", avgDB))")

        DispatchQueue.main.async {
            self.onTextChanged?("Recognizing...")
            self.onDebugLog?("whisper: \(String(format: "%.1f", duration))s \(samples.count) samples")
        }

        let wavData = createWAV(from: samples, sampleRate: recordingSampleRate)
        let lang = sttLanguage

        Task {
            do {
                guard let whisper = whisperService else {
                    log.error("WhisperService not configured")
                    DispatchQueue.main.async { self.onDebugLog?("whisper: no service!") }
                    return
                }
                DispatchQueue.main.async { self.onDebugLog?("whisper: calling API...") }
                let text = try await whisper.transcribe(audioData: wavData, language: lang)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    DispatchQueue.main.async {
                        self.onDebugLog?("whisper: empty, retry...")
                        self.resetActiveState()
                    }
                    return
                }

                // Whisper hallucination filter
                let lower = trimmed.lowercased()
                let isHallucination = self.hallucinationPhrases.contains { lower.contains($0.lowercased()) }
                if isHallucination {
                    log.info("Hallucination filter: \"\(trimmed)\" → skip")
                    DispatchQueue.main.async {
                        self.onDebugLog?("whisper: hallucination, retry...")
                        self.resetActiveState()
                    }
                    return
                }

                log.notice("Whisper recognized: \"\(trimmed)\"")
                DispatchQueue.main.async { self.onDebugLog?("whisper: \"\(trimmed.prefix(30))\"") }

                // Valid result — cancel activation timer and deliver utterance
                DispatchQueue.main.async {
                    self.activationTimer?.invalidate()
                    self.activationTimer = nil
                }
                self.isActivated = false
                DispatchQueue.main.async {
                    self.onTextChanged?(trimmed)
                    self.onUtteranceCaptured?(trimmed)
                }
            } catch {
                log.error("Whisper error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onDebugLog?("whisper ERR: \(error.localizedDescription.prefix(60))")
                }
                self.isActivated = false
                // Delay restart so user can read error
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.restartRecognition()
                }
            }
        }
    }

    // MARK: - Ding Sound

    /// Play ding WITHOUT stopping engine — keeps Bluetooth audio route intact
    func playDing() {
        log.info("Playing ding (engine stays running)")

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
            log.info("Ding playing")

            // Clean up player after playback
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                self?.dingAudioPlayer = nil
            }
        } catch {
            log.error("Ding error: \(error)")
        }
    }

    // MARK: - Trigger Word

    /// Fuzzy match for wake word — accepts common SFSpeech misrecognitions
    private let triggerVariants: Set<String> = [
        // English
        "easy", "eazy", "ease", "eezy", "ezee", "easey",
        "izi", "izzy", "izzi", "izy", "isy",
        "eiji", "ichi", "vijay", "ej", "aj", "eg",
        "ez", "eze", "ezzy",
        // Misrecognitions
        "eating", "is it", "e z", "e g",
        "easing", "easily",
    ]

    private func containsTrigger(_ text: String) -> Bool {
        // Multi-word phrase check (e.g. "is it")
        for variant in triggerVariants where variant.contains(" ") {
            if text.contains(variant) { return true }
        }

        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }

        for word in words {
            if triggerVariants.contains(word) { return true }
            if word.hasPrefix("eas") || word.hasPrefix("eaz") || word.hasPrefix("eez")
                || word.hasPrefix("eij") || word.hasPrefix("eig") || word.hasPrefix("eag")
                || word.hasPrefix("itch") {
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
