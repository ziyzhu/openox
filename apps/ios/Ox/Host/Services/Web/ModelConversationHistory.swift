import Foundation

nonisolated enum ModelConversationHistory {
    static func newTurns(after history: [JSONValue], in messages: [JSONValue]) -> [JSONValue]? {
        guard !history.isEmpty, messages.count > history.count, messages.starts(with: history) else { return nil }
        let turns = Array(messages.dropFirst(history.count))
        guard turns.allSatisfy({ ["user", "tool"].contains($0.objectValue?["role"]?.stringValue ?? "") }) else { return nil }
        return turns
    }

    static func assistantTurn(_ text: String) -> JSONValue {
        .object(["role": .string("assistant"), "text": .string(text)])
    }

    static func referencedFileNames(_ names: [String], in turns: [JSONValue], excluding history: [JSONValue]) -> Set<String> {
        let texts = turns.compactMap(attachmentText)
        let earlier = history.compactMap(attachmentText)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return Set(names.filter { name in
            guard let data = try? encoder.encode(name) else { return false }
            let reference = "\"uploaded_file\":\(String(decoding: data, as: UTF8.self))"
            return texts.contains { $0.contains(reference) } && !earlier.contains { $0.contains(reference) }
        })
    }

    private static func attachmentText(_ turn: JSONValue) -> String? {
        guard let fields = turn.objectValue, let text = fields["text"]?.stringValue else { return nil }
        guard fields["role"] == .string("tool") else { return text }
        let start = "<ox_action_result>\n"
        let end = "\n</ox_action_result>"
        guard text.hasPrefix(start), text.hasSuffix(end),
              let data = String(text.dropFirst(start.count).dropLast(end.count)).data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return payload.objectValue?["content"]?.stringValue
    }
}
