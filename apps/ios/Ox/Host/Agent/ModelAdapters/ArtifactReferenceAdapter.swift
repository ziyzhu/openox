import Foundation

nonisolated struct ArtifactReferenceAdapter: ModelAdapter {
    let id = "lazy-artifact-reference"

    func transform(messages: [Message], model: ProviderModel) async -> ModelAdapterOutcome {
        var transformedMessages: [Message] = []
        var changed = false
        transformedMessages.reserveCapacity(messages.count)
        for message in messages {
            let transformed = transform(message)
            transformedMessages.append(transformed.message)
            changed = changed || transformed.changed
        }
        return changed ? .transformed(transformedMessages) : .unchanged
    }

    private func transform(_ message: Message) -> (message: Message, changed: Bool) {
        switch message {
        case .user(var user):
            let transformed = transform(user.content)
            user.content = transformed.content
            return (.user(user), transformed.changed)
        case .toolResult(var result):
            let transformed = transform(result.content)
            result.content = transformed.content
            return (.toolResult(result), transformed.changed)
        case .assistant:
            return (message, false)
        }
    }

    private func transform(_ content: [ContentBlock]) -> (content: [ContentBlock], changed: Bool) {
        var changed = false
        let transformed = content.map { block in
            guard case .attachment(let artifact) = block else { return block }
            changed = true
            return .text(TextContent(ArtifactPromptReference.text(for: artifact)))
        }
        return (transformed, changed)
    }
}
