import Foundation
import os

private let log = Logger(subsystem: "com.ghost.easy", category: "whisper")

actor WhisperService {
    private var apiKey: String?
    private let session = URLSession(configuration: .default)

    func setAPIKey(_ key: String) {
        apiKey = key.isEmpty ? nil : key
    }

    func transcribe(audioData: Data, language: String = "ko") async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw WhisperError.noAPIKey
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // file
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        // model
        body.appendMultipart(boundary: boundary, name: "model", value: "whisper-1")
        // language
        body.appendMultipart(boundary: boundary, name: "language", value: language)
        // temperature 0 = deterministic, reduces hallucination
        body.appendMultipart(boundary: boundary, name: "temperature", value: "0")
        // verbose_json to get no_speech_prob
        body.appendMultipart(boundary: boundary, name: "response_format", value: "verbose_json")
        // prompt — dev context hint
        body.appendMultipart(boundary: boundary, name: "prompt", value: "Software development using Claude Code.")

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown"
            throw WhisperError.apiError(statusCode: http.statusCode, message: errorText)
        }

        let result = try JSONDecoder().decode(VerboseWhisperResponse.self, from: data)

        // Filter noise using segment-level metrics
        if let seg = result.segments?.first {
            log.info("Whisper: \"\(result.text)\" no_speech=\(String(format: "%.2f", seg.no_speech_prob)) logprob=\(String(format: "%.2f", seg.avg_logprob)) compress=\(String(format: "%.1f", seg.compression_ratio))")

            // High no_speech_prob = likely not real speech (threshold per OpenAI paper: 0.6)
            if seg.no_speech_prob > 0.6 {
                log.info("skip: no_speech_prob \(String(format: "%.2f", seg.no_speech_prob))")
                return ""
            }
            // Very low avg_logprob = poor recognition quality
            if seg.avg_logprob < -1.0 {
                log.info("skip: avg_logprob \(String(format: "%.2f", seg.avg_logprob))")
                return ""
            }
            // High compression ratio = repetitive hallucination
            if seg.compression_ratio > 2.4 {
                log.info("skip: compression_ratio \(String(format: "%.1f", seg.compression_ratio))")
                return ""
            }
        } else {
            log.info("Whisper: \"\(result.text)\" (no segments)")
        }

        return result.text
    }

    enum WhisperError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "OpenAI API key not configured"
            case .invalidResponse: "Invalid response"
            case .apiError(let code, let msg): "Whisper API error (\(code)): \(msg)"
            }
        }
    }

    private struct VerboseWhisperResponse: Decodable {
        let text: String
        let segments: [Segment]?

        struct Segment: Decodable {
            let no_speech_prob: Double
            let avg_logprob: Double
            let compression_ratio: Double
        }
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
