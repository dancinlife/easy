import Foundation

struct Session: Identifiable, Codable {
    let id: String
    var name: String
    var room: String?
    var workDir: String?
    var hostname: String?
    var createdAt: Date
    var messages: [SessionMessage]

    init(id: String = UUID().uuidString, name: String = "새 세션", room: String? = nil, workDir: String? = nil, hostname: String? = nil, messages: [SessionMessage] = []) {
        self.id = id
        self.name = name
        self.room = room
        self.workDir = workDir
        self.hostname = hostname
        self.createdAt = .now
        self.messages = messages
    }

    struct SessionMessage: Identifiable, Codable {
        let id: String
        let role: Role
        let text: String
        let timestamp: Date

        enum Role: String, Codable {
            case user
            case assistant
        }

        init(role: Role, text: String) {
            self.id = UUID().uuidString
            self.role = role
            self.text = text
            self.timestamp = .now
        }
    }
}

@Observable
@MainActor
final class SessionStore {
    private let key = "sessions"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var sessions: [Session] = []

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? decoder.decode([Session].self, from: data) else {
            sessions = []
            return
        }
        sessions = saved.sorted { $0.createdAt > $1.createdAt }
    }

    func save() {
        if let data = try? encoder.encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func createSession() -> Session {
        let session = Session()
        sessions.insert(session, at: 0)
        save()
        return session
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        save()
    }

    func updateSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            save()
        }
    }

    func appendMessage(sessionId: String, message: Session.SessionMessage) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].messages.append(message)

        // 최근 유저 메시지로 세션 이름 업데이트
        if message.role == .user {
            let name = String(message.text.prefix(30))
            if !name.isEmpty { sessions[idx].name = name }
        }

        save()
    }
}
