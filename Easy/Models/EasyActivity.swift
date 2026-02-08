import ActivityKit
import Foundation

struct EasyActivityAttributes: ActivityAttributes {
    let sessionName: String

    struct ContentState: Codable, Hashable {
        enum Status: String, Codable { case listening, thinking, speaking }
        var status: Status
        var recognizedText: String
    }
}
