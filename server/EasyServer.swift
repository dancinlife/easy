#!/usr/bin/env swift
/// Easy Server — Claude Code HTTP 래퍼 (Swift)
/// Mac에서 실행. iPhone Easy 앱이 이 서버에 요청을 보냄.
///
/// 사용법:
///     swift server/EasyServer.swift
///     # → http://0.0.0.0:7777

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let PORT: UInt16 = 7777

// MARK: - Simple HTTP Server using NWListener (macOS 10.15+)

import Network

let listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: PORT)!)

listener.newConnectionHandler = { connection in
    connection.start(queue: .global())
    receive(connection: connection)
}

func receive(connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
        guard let data, error == nil else {
            connection.cancel()
            return
        }

        let request = String(data: data, encoding: .utf8) ?? ""
        handleRequest(request: request, connection: connection)
    }
}

func handleRequest(request: String, connection: NWConnection) {
    let lines = request.components(separatedBy: "\r\n")
    let firstLine = lines.first ?? ""

    if firstLine.hasPrefix("GET /health") {
        sendJSON(connection: connection, json: ["status": "ok"])
        return
    }

    guard firstLine.hasPrefix("POST /ask") else {
        sendError(connection: connection, code: 404, message: "Not Found")
        return
    }

    // Parse body (after empty line)
    let parts = request.components(separatedBy: "\r\n\r\n")
    guard parts.count >= 2, let bodyData = parts[1].data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let question = json["question"] as? String, !question.isEmpty else {
        sendJSON(connection: connection, json: ["error": "question is required"], code: 400)
        return
    }

    print("[\u{c9c8}\u{bb38}] \(question)")

    // Run claude --print
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "claude --print \(shellEscape(question))"]
    process.environment = ProcessInfo.processInfo.environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let answer = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let preview = answer.prefix(100)
        print("[\u{c751}\u{b2f5}] \(preview)...")
        sendJSON(connection: connection, json: ["answer": answer])
    } catch {
        sendJSON(connection: connection, json: ["error": error.localizedDescription], code: 500)
    }
}

func shellEscape(_ str: String) -> String {
    "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func sendJSON(connection: NWConnection, json: [String: Any], code: Int = 200) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    let statusText = code == 200 ? "OK" : "Error"
    let header = """
    HTTP/1.1 \(code) \(statusText)\r
    Content-Type: application/json; charset=utf-8\r
    Content-Length: \(body.count)\r
    Access-Control-Allow-Origin: *\r
    Connection: close\r
    \r\n
    """
    var response = header.data(using: .utf8)!
    response.append(body)

    connection.send(content: response, completion: .contentProcessed { _ in
        connection.cancel()
    })
}

func sendError(connection: NWConnection, code: Int, message: String) {
    sendJSON(connection: connection, json: ["error": message], code: code)
}

print("Easy Server running on http://0.0.0.0:\(PORT)")
print("Health check: http://localhost:\(PORT)/health")
print("Ctrl+C to stop")

listener.start(queue: .main)
dispatchMain()
