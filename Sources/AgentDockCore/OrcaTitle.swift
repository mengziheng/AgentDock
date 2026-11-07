import Foundation

extension Conversation {
    public var displayTitle: String {
        guard application.id == TrackedApplication.orca.id else { return title }
        return OrcaTitle.clean(title)
    }
}

enum OrcaTitle {
    static func clean(_ title: String) -> String {
        // Terminal status decorations are displayed separately in the status badge.
        let name = title
            .replacingOccurrences(of: "^[\\u2800-\\u28FF]+\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^(?:\\[\\s*[!.]\\s*\\]\\s*)?Action Required\\s*\\|\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? title : name
    }
}
