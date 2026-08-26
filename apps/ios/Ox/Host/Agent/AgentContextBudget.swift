import Foundation

nonisolated struct AgentContextBudget {
    let inputLimit: Int
    let usedTokens: Int
    let reserveTokens: Int

    init(context: AgentContext, model: ProviderModel, options: StreamOptions, threshold: Double, fallbackUsage: Int = 0) {
        let window = max(0, model.maxContext)
        reserveTokens = min(window, max(0, options.maxTokens ?? model.maxTokens))
        let safety = min(window, max(256, window / 20))
        inputLimit = max(0, min(Int(Double(window) * min(1, max(0, threshold))), window - reserveTokens - safety))
        usedTokens = Self.estimate(context: context, fallbackUsage: fallbackUsage)
    }

    static func textTokens(_ text: String) -> Int {
        (text.utf8.reduce(0) { $0 + ($1 < 128 ? 1 : 4) } + 3) / 4
    }

    static func messageTokens(_ message: Message) -> Int {
        switch message {
        case .user(let user):
            return 12 + contentTokens(user.content) + textTokens(user.transientContext ?? "")
        case .assistant(let assistant):
            return 12 + contentTokens(assistant.content)
        case .toolResult(let result):
            return 12 + contentTokens(result.content) + result.transientAttachments.reduce(0) { $0 + attachmentTokens($1) }
        }
    }

    static func attachmentTokens(_ attachment: TransientAttachment) -> Int {
        switch attachment.kind {
        case .text:
            return textTokens(String(decoding: attachment.data, as: UTF8.self))
        case .image:
            return 4_800
        case .pdf, .file:
            return max(4_800, attachment.data.count)
        }
    }

    static func contentTokens(_ content: [ContentBlock]) -> Int {
        content.reduce(0) { count, block in
            switch block {
            case .text(let text): count + textTokens(text.text)
            case .thinking(let thinking): count + textTokens(thinking.thinking)
            case .toolCall(let call): count + 12 + textTokens(call.name) + textTokens(call.arguments.jsonString(fallback: ""))
            case .attachment(let artifact):
                count + (artifact.kind == .image ? 4_800 : max(4_800, artifact.size ?? 0))
            }
        }
    }

    private static func estimate(context: AgentContext, fallbackUsage: Int) -> Int {
        let prompt = textTokens(context.systemPrompt) + context.tools.reduce(0) {
            $0 + 12 + textTokens($1.name) + textTokens($1.description) + textTokens($1.parameters.jsonString(fallback: ""))
        }
        let estimated = prompt + context.messages.reduce(0) { $0 + messageTokens($1) }
        for index in context.messages.indices.reversed() {
            guard case .assistant(let assistant) = context.messages[index],
                  assistant.stopReason != .error, assistant.stopReason != .aborted,
                  assistant.stopReason != .pending else { continue }
            let usage = max(assistant.usage.totalTokens, assistant.usage.input + assistant.usage.output)
            guard usage > 0 else { continue }
            let measured = usage + context.messages[(index + 1)...].reduce(0) { $0 + messageTokens($1) }
            return max(estimated, measured)
        }
        return max(fallbackUsage, estimated)
    }
}
