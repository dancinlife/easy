import Foundation

/// QR 코드에서 파싱한 페어링 정보
/// URL 형식: easy://pair?relay=wss://...&room=<uuid>&pub=<base64url-pubkey>
struct PairingInfo: Codable, Equatable {
    let relayURL: String
    let room: String
    let serverPublicKey: Data

    init?(url: URL) {
        guard url.scheme == "easy",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }

        var relay: String?
        var room: String?
        var pub: String?

        for item in queryItems {
            switch item.name {
            case "relay": relay = item.value
            case "room": room = item.value
            case "pub": pub = item.value
            default: break
            }
        }

        guard let relay, let room, let pub,
              let pubData = Data(base64URLEncoded: pub) else { return nil }

        self.relayURL = relay
        self.room = room
        self.serverPublicKey = pubData
    }

    init(relayURL: String, room: String, serverPublicKey: Data) {
        self.relayURL = relayURL
        self.room = room
        self.serverPublicKey = serverPublicKey
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
