import Foundation

actor ClaudeService {
    private let session = URLSession.shared

    func ask(question: String, host: String, port: Int = 7777, workDir: String? = nil) async throws -> String {
        let url = URL(string: "http://\(host):\(port)/ask")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = ["question": question]
        if let workDir, !workDir.isEmpty {
            body["workDir"] = workDir
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClaudeError.serverError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["answer"] as? String else {
            throw ClaudeError.invalidResponse
        }

        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ClaudeError: LocalizedError {
    case serverError
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .serverError: "서버 연결 실패"
        case .invalidResponse: "응답 파싱 실패"
        }
    }
}
