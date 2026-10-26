import Foundation

nonisolated enum ProviderGeneration {
    private static let string = JSONValue.object(["type": .string("string")])
    private static let integer = JSONValue.object(["type": .string("integer"), "minimum": .int(0)])
    private static func object(_ fields: [String: JSONValue], required: [String]? = nil) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(fields), "required": .array((required ?? fields.keys.sorted()).map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private static let text = JSONValue.object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(131_072)])
    static let inputFields: [String: JSONValue] = [
        "id": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(200)]),
        "model": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
        "systemPrompt": text,
        "messages": .object([
            "type": .string("array"), "minItems": .int(1), "maxItems": .int(64),
            "items": object([
                "role": .object(["type": .string("string"), "enum": .array([.string("user"), .string("assistant")])]),
                "content": text,
            ]),
        ]),
        "maxOutputTokens": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(8192)]),
    ]
    private static let modalities = JSONValue.object(["type": .string("array"), "items": string])
    static let modelsSchema = JSONValue.object(["type": .string("array"), "items": object([
        "id": string, "name": string, "available": .object(["type": .string("boolean")]),
        "contextTokens": integer, "outputTokens": integer, "input": modalities, "output": modalities,
        "reasoningEfforts": modalities,
    ])])
    static let outputSchema = object([
        "id": string, "model": string, "text": string,
        "stopReason": .object(["type": .string("string"), "enum": .array([.string("stop"), .string("length")])]),
        "usage": object([
            "input": integer, "output": integer, "cachedInput": integer, "totalTokens": integer,
            "cacheWriteInput": .object(["type": .array([.string("integer"), .string("null")])]),
        ], required: ["input", "output", "cachedInput", "totalTokens"]),
    ])

    static func models(_ definition: ProviderDefinition, client: (any ProviderClient)?) -> JSONValue {
        let available = Set(client?.models.map(\.id) ?? [])
        return .array(definition.models.map { entry in
            let model = entry.runtimeModel
            return .object([
                "id": .string(model.id), "name": .string(model.displayName), "available": .bool(available.contains(model.id)),
                "contextTokens": .int(model.maxContext), "outputTokens": .int(model.maxTokens),
                "input": .array(model.modalities.input.map(\.rawValue).sorted().map(JSONValue.string)),
                "output": .array(model.modalities.output.map(\.rawValue).sorted().map(JSONValue.string)),
                "reasoningEfforts": .array(model.reasoningEfforts.map(JSONValue.string)),
            ])
        })
    }

    static func generate(_ fields: [String: JSONValue], client: any ProviderClient) async throws -> JSONValue {
        guard let modelID = fields["model"]?.stringValue,
              var model = client.models.first(where: { $0.id == modelID }),
              case .int(let limit) = fields["maxOutputTokens"], (1...8192).contains(limit), limit <= model.maxTokens,
              model.modalities.input.contains(.text), model.modalities.output.contains(.text),
              let entries = fields["messages"]?.arrayValue, (1...64).contains(entries.count) else {
            throw RuntimeError.bridge("Choose an available text model and an output limit within 1...8192 and the model's limit")
        }
        let systemPrompt: String?
        if let supplied = fields["systemPrompt"] {
            guard let value = supplied.stringValue, !value.isEmpty else { throw RuntimeError.bridge("systemPrompt must be nonempty text") }
            systemPrompt = value
        } else { systemPrompt = nil }
        var bytes = systemPrompt?.utf8.count ?? 0
        let messages: [Message] = try entries.map { entry in
            guard let value = entry.objectValue, Set(value.keys) == ["role", "content"],
                  let role = value["role"]?.stringValue, let content = value["content"]?.stringValue, !content.isEmpty else {
                throw RuntimeError.bridge("Messages require a user or assistant role and nonempty text content")
            }
            bytes += content.utf8.count
            switch role {
            case "user": return .user(UserMessage(text: content))
            case "assistant": return .assistant(AssistantMessage(model: model.wireID, content: [.text(TextContent(content))]))
            default: throw RuntimeError.bridge("Messages accept only user and assistant roles")
            }
        }
        guard bytes <= 131_072 else { throw RuntimeError.bridge("Supplied generation text exceeds 128 KiB") }
        model.reasoningEffort = model.defaultReasoningEffort
        let selected = model
        let result = try await withThrowingTaskGroup(of: AssistantMessage.self) { group in
            group.addTask {
                try await request(client: client, model: selected, systemPrompt: systemPrompt, messages: messages, limit: limit)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw RuntimeError.bridge("Provider generation timed out after 120 seconds")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RuntimeError.bridge("Provider returned no result") }
            return result
        }
        let text = result.content.compactMap { block -> String? in
            if case .text(let value) = block { return value.text }
            return nil
        }.joined()
        return .object([
            "id": .string(client.id), "model": .string(model.id), "text": .string(text),
            "stopReason": .string(result.stopReason.rawValue),
            "usage": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result.usage)),
        ])
    }

    private static func request(client: any ProviderClient, model: ProviderModel, systemPrompt: String?, messages: [Message], limit: Int) async throws -> AssistantMessage {
        try Task.checkCancellation()
        guard await client.prepareAuthentication() != .unavailable else {
            throw RuntimeError.bridge("Provider is not ready; authenticate or choose a supported model")
        }
        for try await event in client.stream(model: model, systemPrompt: systemPrompt, messages: messages, tools: [], options: StreamOptions(maxTokens: limit, promptCachePolicy: .disabled, sessionID: UUID().uuidString)) {
            try Task.checkCancellation()
            switch event {
            case .done(let reason, let message):
                guard reason == .stop || reason == .length,
                      !message.content.contains(where: { if case .toolCall = $0 { return true }; return false }) else {
                    throw RuntimeError.bridge("Provider generation returned an unsupported completion")
                }
                var completed = message
                completed.stopReason = reason
                return completed
            case .failed(_, let error): throw RuntimeError.bridge(error.errorMessage ?? "Provider generation failed")
            case .toolCallDelta, .toolCallEnd: throw RuntimeError.bridge("Provider generation does not support tool calls")
            default: break
            }
        }
        throw RuntimeError.bridge("Provider stream ended without a completion")
    }
}
