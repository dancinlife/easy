import Foundation
import AVFoundation
import os

private let log = Logger(subsystem: "com.ghost.easy", category: "tts")

@Observable
@MainActor
final class TTSService: NSObject, AVAudioPlayerDelegate {
    var isSpeaking = false
    var onFinished: (() -> Void)?

    private var audioPlayer: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?
    private var sentenceQueue: [String] = []
    private var isPlayingFromQueue = false

    var apiKey: String?
    var voice: String = "nova"
    var speed: Double = 1.0

    /// Speak entire text at once (legacy, wraps enqueueSentence)
    func speak(_ text: String) {
        stop()
        enqueueSentence(text)
    }

    /// Enqueue a sentence for TTS playback. Starts immediately if idle.
    func enqueueSentence(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentenceQueue.append(trimmed)
        if !isPlayingFromQueue {
            playNextInQueue()
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        sentenceQueue.removeAll()
        isPlayingFromQueue = false
        isSpeaking = false
    }

    private func requestTTS(text: String, apiKey: String) async throws -> Data {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": voice,
            "speed": speed,
            "instructions": "Speak naturally in the same language as the input text.",
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TTS", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(statusCode)): \(body)"])
        }
        return data
    }

    private func playAudio(_ data: Data) throws {
        audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer?.delegate = self
        audioPlayer?.play()
    }

    private func playNextInQueue() {
        guard let apiKey, !apiKey.isEmpty else {
            log.warning("API key not set")
            sentenceQueue.removeAll()
            isPlayingFromQueue = false
            isSpeaking = false
            onFinished?()
            return
        }

        guard !sentenceQueue.isEmpty else {
            isPlayingFromQueue = false
            isSpeaking = false
            onFinished?()
            return
        }

        isPlayingFromQueue = true
        isSpeaking = true
        let sentence = sentenceQueue.removeFirst()

        currentTask = Task {
            do {
                let audioData = try await requestTTS(text: sentence, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                try playAudio(audioData)
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Error: \(error.localizedDescription)")
                // Try next sentence on error
                playNextInQueue()
            }
        }
    }

    // AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.playNextInQueue()
        }
    }
}
