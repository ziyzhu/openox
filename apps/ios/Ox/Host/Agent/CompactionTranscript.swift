import Foundation

nonisolated enum CompactionTranscript {
    static let toolResultCharacterLimit = 2_000

    static func render(_ messages: [Message]) -> String {
        messages.compactMap(entry).joined(separator: "\n\n")
    }

    private static func entry(_ message: Message) -> String? {
        switch message {
        case .user(let user):
            return labeled("User", lines([user.transientContext ?? ""] + user.content.compactMap(visibleText)))
        case .assistant(let assistant):
            let parts = [
                labeled("Assistant thinking", lines(assistant.content.compactMap(thinking))),
                labeled("Assistant", lines(assistant.content.compactMap(visibleText))),
                labeled("Assistant tool calls", assistant.content.compactMap(toolCall).joined(separator: "; ")),
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case .toolResult(let result):
            let body = lines(
                result.content.compactMap(visibleText)
                    + result.transientAttachments.map { "Transient attachment: \($0.displayName) (\($0.mimeType))" }
            )
            return labeled(result.isError ? "Tool error" : "Tool result", truncated(body, limit: toolResultCharacterLimit))
        }
    }

    private static func visibleText(_ block: ContentBlock) -> String? {
        switch block {
        case .text(let text): text.text
        case .attachment(let artifact): ArtifactPromptReference.text(for: artifact)
        case .thinking, .toolCall: nil
        }
    }

    private static func thinking(_ block: ContentBlock) -> String? {
        guard case .thinking(let thinking) = block else { return nil }
        return thinking.thinking
    }

    private static func toolCall(_ block: ContentBlock) -> String? {
        guard case .toolCall(let call) = block else { return nil }
        return "\(call.name)(\(call.arguments.jsonString(fallback: "{}")))"
    }

    private static func lines(_ parts: [String]) -> String {
        parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }

    private static func labeled(_ label: String, _ text: String) -> String? {
        text.isEmpty ? nil : "[\(label)]: \(text)"
    }

    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n\n[... \(text.count - limit) more characters truncated]"
    }
}
