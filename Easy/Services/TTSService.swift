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

    var apiKey: String?
    var voice: String = "nova"
    var speed: Double = 1.0

    func speak(_ text: String) {
        stop()

        guard let apiKey, !apiKey.isEmpty else {
            log.warning("API key not set")
            onFinished?()
            return
        }

        isSpeaking = true

        currentTask = Task {
            do {
                let audioData = try await requestTTS(text: text, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                try playAudio(audioData)
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Error: \(error.localizedDescription)")
                isSpeaking = false
                onFinished?()
            }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
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

    // AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.isSpeaking = false
            self.onFinished?()
        }
    }
}
