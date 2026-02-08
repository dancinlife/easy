import Foundation
import AVFoundation

final class SpeechService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?

    // 오디오 버퍼 (Float 샘플 축적)
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isSpeaking = false
    private var recordingSampleRate: Double = 16000

    var silenceTimeout: TimeInterval = 1.5
    var sttLanguage: String = "en"

    /// Whisper API 서비스 (외부에서 주입)
    var whisperService: WhisperService?

    /// 발화 확정 시 텍스트 전달
    var onUtteranceCaptured: ((String) -> Void)?
    /// 실시간 상태 텍스트
    var onTextChanged: ((String) -> Void)?

    private(set) var isListening = false

    /// VAD 설정
    private let speechThresholdDB: Float = -50  // 이 값 초과 시 발화로 판단
    private let minSpeechDuration: TimeInterval = 0.3  // 최소 발화 길이 (초)
    private var speechStartTime: Date?

    /// Whisper 환각 필터 — 무음/노이즈에서 반복 출력되는 알려진 문구
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

        // 오디오 tap 설치 — RMS 기반 VAD + 버퍼 축적
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
        print("[Speech] Whisper 모드 시작 (\(sttLanguage))")
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
        isSpeaking = false
        speechStartTime = nil

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
    }

    func restartRecognition() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        isSpeaking = false
        speechStartTime = nil

        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()

        DispatchQueue.main.async {
            self.onTextChanged?("")
        }
        print("[Speech] 인식 재시작")
    }

    // MARK: - Audio Processing

    private var dbLogCounter = 0
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        // RMS → dB 계산
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))

        dbLogCounter += 1
        if dbLogCounter % 50 == 0 {
            print("[Speech] dB=\(String(format: "%.1f", db)) threshold=\(speechThresholdDB) isSpeaking=\(isSpeaking)")
        }

        if db > speechThresholdDB {
            // 발화 감지
            if !isSpeaking {
                isSpeaking = true
                speechStartTime = Date()
                DispatchQueue.main.async {
                    self.onTextChanged?("듣는 중...")
                }
            }

            // 버퍼에 샘플 추가
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()

            // 침묵 타이머 리셋
            resetSilenceTimer()
        } else if isSpeaking {
            // 발화 중이지만 조용 → 버퍼에 계속 추가 (패딩)
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()

            // 침묵 구간: 타이머 리셋하지 않음 → 기존 타이머가 만료되면 캡처
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

        // 최소 발화 길이 확인
        if let start = speechStartTime, Date().timeIntervalSince(start) < minSpeechDuration {
            isSpeaking = false
            speechStartTime = nil
            bufferLock.lock()
            audioBuffer.removeAll()
            bufferLock.unlock()
            return
        }

        // 버퍼 복사 후 클리어
        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        isSpeaking = false
        speechStartTime = nil

        guard !samples.isEmpty else {
            print("[Speech] 빈 버퍼, skip")
            return
        }

        let duration = Double(samples.count) / recordingSampleRate
        print("[Speech] 캡처 완료: \(String(format: "%.1f", duration))초, \(samples.count) samples")

        // 오디오 에너지 체크 — 너무 조용하면 Whisper 환각 방지
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let avgDB = 20 * log10(max(rms, 1e-10))
        if avgDB < -45 {
            print("[Speech] 평균 dB=\(String(format: "%.1f", avgDB)) 너무 조용, skip")
            DispatchQueue.main.async { self.onTextChanged?("") }
            return
        }

        DispatchQueue.main.async {
            self.onTextChanged?("인식 중...")
        }

        let wavData = createWAV(from: samples, sampleRate: recordingSampleRate)
        let lang = sttLanguage

        Task {
            do {
                guard let whisper = whisperService else {
                    print("[Speech] WhisperService 미설정")
                    return
                }
                let text = try await whisper.transcribe(audioData: wavData, language: lang)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    DispatchQueue.main.async { self.onTextChanged?("") }
                    return
                }

                // Whisper 환각 필터
                let lower = trimmed.lowercased()
                let isHallucination = self.hallucinationPhrases.contains { lower.contains($0.lowercased()) }
                if isHallucination {
                    print("[Speech] 환각 필터: \"\(trimmed)\" → skip")
                    DispatchQueue.main.async { self.onTextChanged?("") }
                    return
                }

                print("[Speech] Whisper 인식: \"\(trimmed)\"")
                DispatchQueue.main.async {
                    self.onTextChanged?(trimmed)
                    self.onUtteranceCaptured?(trimmed)
                }
            } catch {
                print("[Speech] Whisper 오류: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onTextChanged?("")
                }
            }
        }
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
