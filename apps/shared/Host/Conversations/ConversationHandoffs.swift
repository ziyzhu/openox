import Foundation

nonisolated struct UserInteractionResponse {
    let title: String
    let completed: Bool

    static func parse(_ text: String) -> Self? {
        let prompt = text.range(of: "\n<login_trace>").map { text[..<$0.lowerBound] } ?? text[...]
        let suffix = "\n</user_interaction>"
        guard prompt.hasSuffix(suffix) else { return nil }
        for completed in [true, false] {
            let prefix = "<user_interaction>\n\(completed ? "Done" : "Cancelled"): "
            guard prompt.hasPrefix(prefix) else { continue }
            let title = String(prompt.dropFirst(prefix.count).dropLast(suffix.count))
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&amp;", with: "&")
            guard !title.isEmpty else { return nil }
            return Self(title: title, completed: completed)
        }
        return nil
    }
}
