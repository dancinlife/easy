import Foundation
import AVFoundation
import Speech
import os

private let log = Logger(subsystem: "com.ghost.easy", category: "speech")

// MARK: - Voice Flow State Machine

enum VoiceFlowState: String {
    case idle          // Engine off
    case passive       // SFSpeech wake word listening
    case activated     // Wake word detected, waiting for speech (owns activationTimer)
    case capturing     // VAD capturing audio (owns silenceTimer)
    case transcribing  // Whisper API call in progress
    case delivered     // Utterance delivered, waiting for VM
}

final class SpeechService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var recordingSampleRate: Double = 16000

    // MARK: - State Store (thread-safe via OSAllocatedUnfairLock)

    private struct StateStore {
        var flowState: VoiceFlowState = .idle
        var audioBuffer: [Float] = []
        var peakDB: Float = -100
        var isSpeechDetected: Bool = false
        var speechStartTime: Date? = nil
    }

    private let store = OSAllocatedUnfairLock(initialState: StateStore())

    // MARK: - Settings

    var silenceTimeout: TimeInterval = 3.0
    var sttLanguage: String = "en"
    var speakerMode: Bool = false
    var triggerWord: String = "easy"

    // MARK: - Callbacks

    var onFlowStateChanged: ((VoiceFlowState) -> Void)?
    var onTriggerDetected: (() -> Void)?
    var onUtteranceCaptured: ((String) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onDebugLog: ((String) -> Void)?
    var onActivationTimeout: (() -> Void)?

    // MARK: - Whisper

    var whisperService: WhisperService?
    private var whisperTask: Task<Void, Never>?

    // MARK: - SFSpeech (passive mode)

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var passiveWatchdog: Timer?
    private var lastCallbackTime: Date?
    private var tapCounter = 0
    private var callbackCounter = 0

    // MARK: - Timers (owned by specific states)

    private var activationTimer: Timer?   // owned by .activated
    private var silenceTimer: Timer?       // owned by .capturing

    // MARK: - VAD

    private let dropThresholdDB: Float = 8
    private var dbLogCounter = 0

    // MARK: - Ding

    private var dingAudioPlayer: AVAudioPlayer?

    // MARK: - Whisper hallucination filter

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

    // MARK: - Public read-only state

    var flowState: VoiceFlowState {
        store.withLock { $0.flowState }
    }

    var isListening: Bool {
        let state = flowState
        return state != .idle
    }

    var isActivated: Bool {
        let state = flowState
        return state == .activated || state == .capturing || state == .transcribing || state == .delivered
    }

    // MARK: - Permissions

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

    // MARK: - Start / Stop

    func startListening() throws {
        let current = flowState
        if current != .idle { stopListening() }

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.handleAudioTap(buffer)
        }

        store.withLock {
            $0.audioBuffer.removeAll()
            $0.peakDB = -100
            $0.isSpeechDetected = false
            $0.speechStartTime = nil
        }

        engine.prepare()
        try engine.start()

        transition(to: .passive)
        log.info("Started (passive mode, on-device wake word)")
    }

    func stopListening() {
        whisperTask?.cancel()
        whisperTask = nil

        teardown(flowState)

        stopPassiveRecognition()

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        store.withLock {
            $0.flowState = .idle
            $0.audioBuffer.removeAll()
            $0.peakDB = -100
            $0.isSpeechDetected = false
            $0.speechStartTime = nil
        }

        DispatchQueue.main.async {
            self.onFlowStateChanged?(.idle)
        }
    }

    /// Restart to passive without restarting the audio engine (for barge-in)
    func restartToPassive() {
        let current = flowState
        guard current != .idle && current != .passive else { return }

        whisperTask?.cancel()
        whisperTask = nil

        teardown(current)

        store.withLock {
            $0.audioBuffer.removeAll()
            $0.peakDB = -100
            $0.isSpeechDetected = false
            $0.speechStartTime = nil
        }

        transition(to: .passive)
        DispatchQueue.main.async {
            self.onTextChanged?("")
        }
        log.info("Back to passive mode (no engine restart)")
    }

    // MARK: - State Machine

    private func transition(to newState: VoiceFlowState) {
        let oldState = flowState

        // Teardown old state resources
        teardown(oldState)

        // Update state
        store.withLock { $0.flowState = newState }

        // Setup new state resources
        setup(newState)

        log.info("State: \(oldState.rawValue) → \(newState.rawValue)")
        DispatchQueue.main.async {
            self.onFlowStateChanged?(newState)
        }
    }

    private func teardown(_ state: VoiceFlowState) {
        switch state {
        case .idle:
            break
        case .passive:
            DispatchQueue.main.async {
                self.passiveWatchdog?.invalidate()
                self.passiveWatchdog = nil
            }
            // Don't stop recognition here — startPassiveRecognition handles cleanup
        case .activated:
            DispatchQueue.main.async {
                self.activationTimer?.invalidate()
                self.activationTimer = nil
            }
        case .capturing:
            DispatchQueue.main.async {
                self.silenceTimer?.invalidate()
                self.silenceTimer = nil
            }
        case .transcribing:
            // whisperTask cancellation handled explicitly where needed
            break
        case .delivered:
            break
        }
    }

    private func setup(_ state: VoiceFlowState) {
        switch state {
        case .idle:
            break

        case .passive:
            startPassiveRecognition()

        case .activated:
            store.withLock {
                $0.audioBuffer.removeAll()
                $0.peakDB = -100
                $0.isSpeechDetected = false
                $0.speechStartTime = nil
            }
            dbLogCounter = 0
            // Start activation timer (5s timeout)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    let current = self.flowState
                    guard current == .activated else { return }
                    log.info("Activation timeout, back to passive")
                    self.transition(to: .passive)
                    DispatchQueue.main.async {
                        self.onDebugLog?("timeout → passive")
                        self.onActivationTimeout?()
                    }
                }
            }

        case .capturing:
            // Start silence timer
            startSilenceTimer()

        case .transcribing:
            break

        case .delivered:
            break
        }
    }

    // MARK: - Audio Tap Router

    private func handleAudioTap(_ buffer: AVAudioPCMBuffer) {
        tapCounter += 1
        let state = flowState

        switch state {
        case .activated, .capturing:
            processAudioBuffer(buffer)
        case .passive:
            let hasReq = recognitionRequest != nil
            recognitionRequest?.append(buffer)
            if tapCounter % 200 == 0 {
                let tc = tapCounter
                let cc = callbackCounter
                DispatchQueue.main.async {
                    self.onDebugLog?("tap=\(tc) req=\(hasReq) cb=\(cc)")
                }
            }
        default:
            break
        }
    }

    // MARK: - Passive Mode (SFSpeechRecognizer, on-device)

    private func startPassiveRecognition() {
        stopPassiveRecognition()
        DispatchQueue.main.async { self.onDebugLog?("init SFSpeech...") }

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
                    // Transition to activated
                    self.transition(to: .activated)
                    DispatchQueue.main.async {
                        self.onTextChanged?("")
                        self.onTriggerDetected?()
                    }
                    return
                }

                // Utterance finalized → restart for continuous listening
                if result.isFinal && self.flowState == .passive {
                    log.info("SFSpeech finalized, restarting")
                    self.startPassiveRecognition()
                    return
                }
            }

            if let error {
                let nsError = error as NSError
                if nsError.code == 1110 { return } // normal cancellation
                log.error("SFSpeech error: \(nsError.domain) \(nsError.code) \(error.localizedDescription)")
                if self.flowState == .passive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, self.flowState == .passive else { return }
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

        // Watchdog timer
        DispatchQueue.main.async { [weak self] in
            self?.passiveWatchdog?.invalidate()
            self?.passiveWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self, self.flowState == .passive else { return }
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

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))

        let state = flowState

        dbLogCounter += 1
        if dbLogCounter % 50 == 0 {
            let pk = store.withLock { $0.peakDB }
            let spk = state == .capturing
            DispatchQueue.main.async {
                self.onDebugLog?("dB=\(String(format: "%.0f", db)) pk=\(String(format: "%.0f", pk)) spk=\(spk)")
            }
        }

        if state == .activated {
            // Waiting for speech start
            let peakDB = store.withLock { $0.peakDB }
            if peakDB < -99 {
                store.withLock { $0.peakDB = db }
            } else if db > peakDB + 3 {
                // Speech detected! Transition activated → capturing
                store.withLock {
                    $0.isSpeechDetected = true
                    $0.peakDB = db
                    $0.speechStartTime = Date()
                    $0.audioBuffer.append(contentsOf: samples)
                }
                // activationTimer is invalidated by teardown(.activated) inside transition
                transition(to: .capturing)
                DispatchQueue.main.async {
                    self.onTextChanged?("Listening...")
                }
            } else {
                store.withLock { $0.peakDB = $0.peakDB * 0.95 + db * 0.05 }
            }
        } else if state == .capturing {
            // Capturing audio — track peak and detect silence
            let peakDB = store.withLock { $0.peakDB }
            if db > peakDB {
                store.withLock { $0.peakDB = db }
            }

            if db < peakDB - dropThresholdDB {
                // Significant drop — let silence timer expire
            } else {
                // Still speaking — reset silence timer
                startSilenceTimer()
            }

            store.withLock { $0.audioBuffer.append(contentsOf: samples) }
        }
    }

    private func startSilenceTimer() {
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
        guard flowState == .capturing else { return }

        let samples = store.withLock { state -> [Float] in
            let buf = state.audioBuffer
            state.audioBuffer.removeAll()
            state.isSpeechDetected = false
            state.speechStartTime = nil
            state.peakDB = -100
            return buf
        }

        guard !samples.isEmpty else {
            // No audio captured — go back to activated to retry
            transition(to: .activated)
            return
        }

        // Transition to transcribing
        transition(to: .transcribing)

        let duration = Double(samples.count) / recordingSampleRate
        log.info("Captured: \(String(format: "%.1f", duration))s, \(samples.count) samples")

        DispatchQueue.main.async {
            self.onTextChanged?("Recognizing...")
            self.onDebugLog?("whisper: \(String(format: "%.1f", duration))s \(samples.count) samples")
        }

        let wavData = createWAV(from: samples, sampleRate: recordingSampleRate)
        let lang = sttLanguage

        whisperTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let whisper = self.whisperService else {
                    log.error("WhisperService not configured")
                    DispatchQueue.main.async { self.onDebugLog?("whisper: no service!") }
                    return
                }
                DispatchQueue.main.async { self.onDebugLog?("whisper: calling API...") }
                let text = try await whisper.transcribe(audioData: wavData, language: lang)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !Task.isCancelled else { return }

                guard !trimmed.isEmpty else {
                    log.info("Whisper: empty result, retry")
                    DispatchQueue.main.async { self.onDebugLog?("whisper: empty, retry...") }
                    self.transition(to: .activated)
                    return
                }

                // Hallucination filter
                let lower = trimmed.lowercased()
                let isHallucination = self.hallucinationPhrases.contains { lower.contains($0.lowercased()) }
                if isHallucination {
                    log.info("Hallucination filter: \"\(trimmed)\" → skip")
                    DispatchQueue.main.async { self.onDebugLog?("whisper: hallucination, retry...") }
                    self.transition(to: .activated)
                    return
                }

                log.notice("Whisper recognized: \"\(trimmed)\"")
                DispatchQueue.main.async { self.onDebugLog?("whisper: \"\(trimmed.prefix(30))\"") }

                // Valid result — transition to delivered
                self.transition(to: .delivered)
                DispatchQueue.main.async {
                    self.onTextChanged?(trimmed)
                    self.onUtteranceCaptured?(trimmed)
                }
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Whisper error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onDebugLog?("whisper ERR: \(error.localizedDescription.prefix(60))")
                }
                // Delay then restart to passive
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.transition(to: .passive)
                    DispatchQueue.main.async { self.onTextChanged?("") }
                }
            }
        }
    }

    // MARK: - Ding Sound

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

        let freq1: Double = 880
        let freq2: Double = 1320
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

            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                self?.dingAudioPlayer = nil
            }
        } catch {
            log.error("Ding error: \(error)")
        }
    }

    // MARK: - Trigger Word

    private let triggerVariants: Set<String> = [
        "easy", "eazy", "ease", "eezy", "ezee", "easey",
        "izi", "izzy", "izzi", "izy", "isy",
        "eiji", "ichi", "vijay", "ej", "aj", "eg",
        "ez", "eze", "ezzy",
        "eating", "is it", "e z", "e g",
        "easing", "easily",
    ]

    private func containsTrigger(_ text: String) -> Bool {
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
