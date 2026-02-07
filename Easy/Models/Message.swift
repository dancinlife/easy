import Foundation

struct Message: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date

    enum Role {
        case user
        case assistant
    }

    init(role: Role, text: String) {
        self.role = role
        self.text = text
        self.timestamp = .now
    }
}
