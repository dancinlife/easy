import Foundation

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

        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
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

    private struct WhisperResponse: Decodable {
        let text: String
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
