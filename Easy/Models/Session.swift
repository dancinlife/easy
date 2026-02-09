import Foundation

struct Session: Identifiable, Codable {
    let id: String
    var name: String
    var room: String?
    var workDir: String?
    var hostname: String?
    var createdAt: Date
    var messages: [SessionMessage]
    var isPinned: Bool

    init(id: String = UUID().uuidString, name: String = "New Session", room: String? = nil, workDir: String? = nil, hostname: String? = nil, messages: [SessionMessage] = [], isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.room = room
        self.workDir = workDir
        self.hostname = hostname
        self.createdAt = .now
        self.messages = messages
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        room = try container.decodeIfPresent(String.self, forKey: .room)
        workDir = try container.decodeIfPresent(String.self, forKey: .workDir)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        messages = try container.decode([SessionMessage].self, forKey: .messages)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
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
        sessions = saved
    }

    func save() {
        if let data = try? encoder.encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func createSession() -> Session {
        let session = Session()
        // Insert below pinned sessions
        let firstUnpinnedIndex = sessions.firstIndex(where: { !$0.isPinned }) ?? sessions.count
        sessions.insert(session, at: firstUnpinnedIndex)
        save()
        return session
    }

    func togglePin(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()

        // Move pinned to top, unpinned below
        let session = sessions.remove(at: idx)
        if session.isPinned {
            let lastPinnedIndex = sessions.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
            sessions.insert(session, at: lastPinnedIndex)
        } else {
            let firstUnpinnedIndex = sessions.firstIndex(where: { !$0.isPinned }) ?? sessions.count
            sessions.insert(session, at: firstUnpinnedIndex)
        }
        save()
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        save()
    }

    func moveSessions(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
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
        save()
    }
}
