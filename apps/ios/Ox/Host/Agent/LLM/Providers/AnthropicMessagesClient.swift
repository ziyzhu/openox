import Foundation

nonisolated struct AnthropicMessagesClient: LLMClient {
    let id: String
    let displayName: String
    let models: [ProviderModel]
    let endpoint: URL
    let regions: Set<LLMRegion>
    let website: URL?
    let credentialKind: LLMCredentialKind
    let credentialID: String
    let adaptiveThinkingModelIDs: Set<String>
    let reasoningPolicy: LLMReasoningPolicy = .low
    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { .anthropicMessages }

    init(
        id: String,
        displayName: String,
        models: [ProviderModel],
        endpoint: URL,
        regions: Set<LLMRegion> = [.global],
        website: URL? = nil,
        credentialKind: LLMCredentialKind = .apiKey,
        credentialID: String? = nil,
        adaptiveThinkingModelIDs: Set<String> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.endpoint = endpoint
        self.regions = regions
        self.website = website
        self.credentialKind = credentialKind
        self.credentialID = credentialID ?? id
        self.adaptiveThinkingModelIDs = adaptiveThinkingModelIDs
    }

    func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { continuation in
            try await runStream(
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                options: options,
                continuation: continuation
            )
        }
    }

    private func runStream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        guard let key = Credentials.key(for: credentialID) else {
            throw OpenAIAuthError.missingAPIKey(displayName)
        }
        LogContext.latency?.mark(.authReady)
        let body = try buildBody(
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools,
            options: options
        )
        LogContext.latency?.mark(.requestBodyReady)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = body

        let label = "\(displayName).messages"
        let toolNames = tools.map(\.name).joined(separator: ",")
        Log.network.info("\(label) POST \(LogPrivacy.url(endpoint.absoluteString)) model=\(model.id) msgs=\(messages.count) tools=\(tools.count) [\(toolNames)] reasoning=\(reasoningPolicy.rawValue) cache=\(options.promptCachePolicy == .standard ? "standard" : "disabled") bodyBytes=\(body.count)")
        Log.network.info("\(label) wire=[\(messages.wireSignature)]")

        let response = try await StreamingHTTP.open(request, label: label) {
            AnthropicMessagesError(message: "No HTTP response from \(displayName)")
        }
        try await response.requireSuccess { _, text in
            AnthropicMessagesError(
                message: "\(displayName) HTTP \(response.statusCode): \(text)",
                failureKind: llmFailureKind(statusCode: response.statusCode, message: text)
            )
        }
        try await consume(response.bytes, model: model, label: label, continuation: continuation)
    }

    private func consume(
        _ bytes: URLSession.AsyncBytes,
        model: ProviderModel,
        label: String,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        var assembler = StreamAssembler(model: model, continuation: continuation)
        var contentSlots: [Int: Int] = [:]
        var toolIDs: [Int: String] = [:]
        var toolNames: [Int: String] = [:]
        var toolArguments: [Int: String] = [:]
        var thinkingSignatures: [Int: String] = [:]
        var usage = Usage()
        var stopReason: StopReason = .pending
        var sawMessageStop = false
        var failed = false

        func toolCall(_ index: Int) -> ToolCall {
            ToolCall(
                id: toolIDs[index] ?? "",
                name: toolNames[index] ?? "",
                arguments: JSONValue.parse(jsonString: toolArguments[index] ?? "") ?? .object([:])
            )
        }

        let lines = try await SSE.forEachDataChunk(bytes, label: label) { event in
            let type = event["type"] as? String
            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any] {
                    assembler.setResponseID(message["id"] as? String)
                    applyUsage(message["usage"] as? [String: Any], to: &usage)
                    assembler.setUsage(usage)
                }
            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any],
                      let blockType = block["type"] as? String else { break }
                assembler.start()
                switch blockType {
                case "text":
                    contentSlots[index] = assembler.startTextItem()
                    if let text = block["text"] as? String { assembler.textDelta(text) }
                case "thinking":
                    contentSlots[index] = assembler.startReasoningItem()
                    if let thinking = block["thinking"] as? String { assembler.thinkingDelta(thinking) }
                case "redacted_thinking":
                    let slot = assembler.startReasoningItem()
                    contentSlots[index] = slot
                    if let signature = encodedSignature(type: blockType, value: block["data"] as? String) {
                        assembler.setThinkingSignature(signature, at: slot)
                    }
                case "tool_use":
                    let slot = assembler.openToolCall()
                    contentSlots[index] = slot
                    toolIDs[index] = block["id"] as? String
                    toolNames[index] = block["name"] as? String
                    if let input = block["input"] as? [String: Any], !input.isEmpty {
                        toolArguments[index] = jsonString(input) ?? ""
                    } else {
                        toolArguments[index] = ""
                    }
                    assembler.updateToolCall(at: slot, toolCall(index))
                default:
                    break
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String { assembler.textDelta(text) }
                case "thinking_delta":
                    if let thinking = delta["thinking"] as? String { assembler.thinkingDelta(thinking) }
                case "signature_delta":
                    thinkingSignatures[index, default: ""] += delta["signature"] as? String ?? ""
                case "input_json_delta":
                    toolArguments[index, default: ""] += delta["partial_json"] as? String ?? ""
                    if let slot = contentSlots[index] {
                        assembler.updateToolCall(at: slot, toolCall(index))
                    }
                default:
                    break
                }
            case "content_block_stop":
                guard let index = event["index"] as? Int, let slot = contentSlots[index] else { break }
                if let signature = encodedSignature(type: "thinking", value: thinkingSignatures[index]) {
                    assembler.setThinkingSignature(signature, at: slot)
                }
                if toolIDs[index] != nil {
                    assembler.endToolCall(at: slot, toolCall(index))
                } else {
                    assembler.endThinking()
                    assembler.endText()
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let raw = delta["stop_reason"] as? String {
                    assembler.setRawStopReason(raw)
                    stopReason = mappedStopReason(raw)
                }
                applyUsage(event["usage"] as? [String: Any], to: &usage)
                assembler.setUsage(usage)
            case "message_stop":
                sawMessageStop = true
                return false
            case "error":
                let error = event["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "Anthropic Messages stream error"
                assembler.fail(message)
                failed = true
                return false
            default:
                break
            }
            return true
        }
        if failed { return }
        guard sawMessageStop else {
            throw AnthropicMessagesError(message: "\(displayName) Messages stream ended before message_stop")
        }
        assembler.finish(reason: stopReason, label: label, lines: lines)
    }

    private func buildBody(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) throws -> Data {
        var wireMessages: [[String: Any]] = []

        func append(role: String, content: [[String: Any]]) {
            guard !content.isEmpty else { return }
            if let last = wireMessages.indices.last,
               wireMessages[last]["role"] as? String == role,
               let existing = wireMessages[last]["content"] as? [[String: Any]] {
                wireMessages[last]["content"] = existing + content
            } else {
                wireMessages.append(["role": role, "content": content])
            }
        }

        for message in messages {
            switch message {
            case .user(let user):
                append(role: "user", content: try userContent(user))
            case .assistant(let assistant):
                append(role: "assistant", content: assistantContent(assistant))
            case .toolResult(let result):
                append(role: "user", content: [try toolResultContent(result)])
            }
        }

        var body: [String: Any] = [
            "model": model.wireID,
            "max_tokens": options.maxTokens ?? model.maxTokens,
            "messages": wireMessages,
            "stream": true,
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            var system: [String: Any] = ["type": "text", "text": systemPrompt]
            if options.promptCachePolicy == .standard {
                system["cache_control"] = ["type": "ephemeral"]
            }
            body["system"] = [system]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.toAny()]
            }
            body["tool_choice"] = ["type": "auto"]
        }
        if adaptiveThinkingModelIDs.contains(model.id) {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": model.selectedReasoningEffort ?? "low"]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func userContent(_ user: UserMessage) throws -> [[String: Any]] {
        let parts = UserMessageParts(user, label: "\(displayName).messages.user")
        var content: [[String: Any]] = []
        if !parts.text.isEmpty { content.append(["type": "text", "text": parts.text]) }
        for (attachment, data) in parts.media {
            let kind: TransientAttachment.Kind = attachment.kind == .image ? .image : .pdf
            content.append(try mediaContent(
                kind: kind,
                mimeType: attachment.mimeType,
                displayName: attachment.displayName,
                data: data
            ))
        }
        return content
    }

    private func assistantContent(_ assistant: AssistantMessage) -> [[String: Any]] {
        assistant.content.compactMap { block in
            switch block {
            case .thinking(let content):
                guard let signature = content.thinkingSignature else { return nil }
                if let decoded = decodedSignature(signature) {
                    var replay = decoded
                    if replay["type"] as? String == "thinking" { replay["thinking"] = content.thinking }
                    return replay
                }
                return ["type": "thinking", "thinking": content.thinking, "signature": signature]
            case .text(let content):
                return content.text.isEmpty ? nil : ["type": "text", "text": content.text]
            case .toolCall(let toolCall):
                return ["type": "tool_use", "id": toolCall.id, "name": toolCall.name, "input": toolCall.arguments.toAny()]
            case .attachment:
                return nil
            }
        }
    }

    private func toolResultContent(_ result: ToolResultMessage) throws -> [String: Any] {
        let parts = ToolResultParts(result, label: "\(displayName).messages.toolResult")
        var content: [[String: Any]] = []
        if !parts.text.isEmpty { content.append(["type": "text", "text": parts.text]) }
        for attachment in parts.media {
            content.append(try mediaContent(
                kind: attachment.kind,
                mimeType: attachment.mimeType,
                displayName: attachment.displayName,
                data: attachment.data
            ))
        }
        var block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": result.toolCallId,
            "content": content,
        ]
        if result.isError { block["is_error"] = true }
        return block
    }

    private func mediaContent(
        kind: TransientAttachment.Kind,
        mimeType: String,
        displayName: String,
        data: Data
    ) throws -> [String: Any] {
        let source: [String: Any] = [
            "type": "base64",
            "media_type": mimeType,
            "data": data.base64EncodedString(),
        ]
        switch kind {
        case .image:
            return ["type": "image", "source": source]
        case .pdf:
            let pdf = try PDFPreparer.prepareArtifact(data)
            return [
                "type": "document",
                "source": ["type": "base64", "media_type": pdf.mimeType, "data": pdf.data.base64EncodedString()],
            ]
        case .text:
            return ["type": "text", "text": String(data: data, encoding: .utf8) ?? ""]
        case .file:
            return ["type": "text", "text": "[Unsupported file attachment: \(displayName)]"]
        }
    }

    private func applyUsage(_ source: [String: Any]?, to usage: inout Usage) {
        guard let source else { return }
        let uncached = source["input_tokens"] as? Int ?? 0
        let cacheRead = source["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = source["cache_creation_input_tokens"] as? Int ?? 0
        if uncached + cacheRead + cacheWrite > 0 {
            usage.input = uncached + cacheRead + cacheWrite
            usage.cachedInput = cacheRead
            usage.cacheWriteInput = cacheWrite
        }
        if let output = source["output_tokens"] as? Int { usage.output = output }
        usage.totalTokens = usage.input + usage.output
    }

    private func mappedStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "tool_use": .toolUse
        case "max_tokens", "model_context_window_exceeded": .length
        default: .stop
        }
    }

    private func encodedSignature(type: String, value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return jsonString(["type": type, type == "thinking" ? "signature" : "data": value])
    }

    private func decodedSignature(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func jsonString(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated enum AnthropicClient {
    static func make() -> AnthropicMessagesClient {
        AnthropicMessagesClient(
            id: "anthropic",
            displayName: "Anthropic",
            models: ModelsDevCatalog.models(for: "anthropic"),
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            website: URL(string: "https://console.anthropic.com/settings/keys"),
            adaptiveThinkingModelIDs: ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"]
        )
    }
}

nonisolated struct AnthropicMessagesError: LLMClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(message: String, failureKind: LLMFailureKind? = nil) {
        self.message = message
        self.failureKind = failureKind ?? llmFailureKind(message: message)
    }
}
