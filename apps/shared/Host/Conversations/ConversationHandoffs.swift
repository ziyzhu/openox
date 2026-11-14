import Foundation

nonisolated struct UserInteractionResponse {
    let title: String
    let completed: Bool

    var prompt: String {
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<user_interaction>\n\(completed ? "Done" : "Cancelled"): \(escaped)\n</user_interaction>"
    }

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

extension Conversation {
    func requireNoPendingHandoff() throws {
        guard pendingHandoffs.isEmpty else {
            throw OxFunctionError(code: "awaiting_user", message: "A live page is awaiting Done or Cancel.",
                                  recovery: "Finish the turn. Do not poll, open another handoff, or continue dependent work until the user responds.")
        }
    }

    func scheduleHandoff(title: String, operation: @escaping @MainActor () async throws -> JSONValue) -> JSONValue {
        let interactionID = UUID()
        let handoffScope = scope
        pendingHandoffs[interactionID] = Task { @MainActor [weak self] in
            let completed: Bool
            var diagnostic = ""
            do {
                let result = try await operation()
                if let trace = result.objectValue?["loginTrace"], let self {
                    let steps = trace.objectValue?["steps"]?.arrayValue ?? []
                    var summary: [String: JSONValue] = [
                        "stepCount": .int(steps.count),
                        "origins": .array(Array(Set(steps.compactMap { $0.objectValue?["origin"]?.stringValue })).sorted().map(JSONValue.string)),
                        "truncated": trace.objectValue?["truncated"] ?? .bool(false),
                    ]
                    do { summary["path"] = .string(try await javaScriptOutputs.save(trace.jsonString())) }
                    catch { Log.session.warning("Conversation.handoff trace cache unavailable id=\(id)") }
                    diagnostic = "\n<login_trace>\n\(JSONValue.object(summary).jsonString())\n</login_trace>"
                }
                completed = result.objectValue?["completion"]?.stringValue != "cancelled"
            } catch {
                let failure = OxFunctionError.from(error)
                guard failure.code == "handoff_incomplete" else {
                    guard let self else { return }
                    guard pendingHandoffs.removeValue(forKey: interactionID) != nil,
                          scope == handoffScope, StorageRoot.currentScope == handoffScope else { return }
                    reportHandoffFailure(failure.message)
                    Log.session.error("Conversation.handoff failed id=\(id) interaction=\(interactionID) code=\(failure.code)")
                    return
                }
                completed = false
            }
            guard let self, pendingHandoffs.removeValue(forKey: interactionID) != nil,
                  scope == handoffScope, StorageRoot.currentScope == handoffScope else { return }
            let response = UserInteractionResponse(title: title, completed: completed)
            Log.session.info("Conversation.handoff resolved id=\(id) interaction=\(interactionID) completed=\(completed)")
            enqueue(response.prompt + diagnostic)
        }
        Log.session.info("Conversation.handoff scheduled id=\(id) interaction=\(interactionID)")
        return .object(["status": .string("awaiting_user"), "shown": .bool(true)])
    }
}
