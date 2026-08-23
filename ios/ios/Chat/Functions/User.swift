import Foundation

extension Chat {
    public func chooseUser(body: String, options: [String], purpose: String) async throws -> JSONValue? {
        guard (2...4).contains(options.count),
              options.allSatisfy({ !$0.isEmpty && $0.count <= 80 }),
              Set(options).count == options.count else {
            throw RuntimeError.bridge("ox.user.choose: options must contain 2-4 unique labels")
        }
        return try await tracked(.userChoose, .object([
            "body": .string(body),
            "options": .array(options.map(JSONValue.string)),
        ]), purpose: purpose) {
            let answer = await awaitPrompt(prompt: body, options: options, allowsCustomAnswer: true)
            guard answer != Self.abortedAnswer else {
                throw RuntimeError.bridge("ox.user.choose: the user stopped before answering")
            }
            return .string(answer)
        }
    }

    public func reportProgress(message: String, purpose: String) async throws -> JSONValue? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else {
            throw RuntimeError.bridge("ox.user.reportProgress: message must contain 1-2000 characters")
        }
        return try await tracked(.userReportProgress, .object(["message": .string(trimmed)]), purpose: purpose) {
            try appendReportedProgress(trimmed)
            Log.session.info("Chat.reportProgress id=\(id) chars=\(trimmed.count)")
            return nil
        }
    }
}
