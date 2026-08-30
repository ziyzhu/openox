import Foundation

public struct OpenAIChatTransport: ProviderClient {
    public let id: String
    public let displayName: String
    public let models: [ProviderModel]
    public let regions: Set<LLMRegion>
    public let auth: any OpenAIChatTransportAuth
    public let usesAPIKey: Bool
    public let acceptsAPIKey: Bool
    public let credentialKind: LLMCredentialKind
    public let credentialID: String
    public let subscriptionAccount: (any SubscriptionAccount)?
    public let extraBody: [String: JSONValue]
    public let cachesSystemPrompt: Bool
    public let promptCacheRouting: PromptCacheRouting
    public let maxTokensField: MaxTokensField
    public let reasoningReplayModelIDs: Set<String>
    public let reasoningControl: ReasoningControl
    public let website: URL?
    public let inferenceLocation: LLMInferenceLocation
    public let diagnosticsEndpoint: URL?
    public func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { .openAIChatCompletions }
    public var protocolDiagnostics: LLMProtocolDiagnostics {
        LLMProtocolDiagnostics(
            promptCacheRouting: promptCacheRouting.rawValue,
            maxTokensField: maxTokensField.rawValue,
            endpoint: diagnosticsEndpoint?.absoluteString
        )
    }

    public enum PromptCacheRouting: String, Sendable {
        case sessionHeader = "x-session-id"
        case requestBody = "prompt_cache_key"
    }

    public enum MaxTokensField: String, Sendable {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    public enum ReasoningControl: Sendable {
        public enum DisableFormat: Sendable {
            case reasoning
            case thinking
            case chatTemplate
            case qwen
        }

        case effort(LLMReasoningEffort)
        case reasoningObject
        case disabled(DisableFormat)
        case providerDefault

        var policy: LLMReasoningPolicy {
            switch self {
            case .effort(let effort): effort.policy
            case .reasoningObject: .providerDefault
            case .disabled: .none
            case .providerDefault: .providerDefault
            }
        }

        func apply(to body: inout [String: Any], model: ProviderModel) {
            switch self {
            case .effort(let effort):
                body["reasoning_effort"] = model.selectedReasoningEffort ?? effort.rawValue
            case .reasoningObject:
                if let effort = model.selectedReasoningEffort {
                    body["reasoning"] = ["effort": effort]
                }
            case .disabled(.reasoning):
                body["reasoning"] = ["enabled": false]
            case .disabled(.thinking):
                body["thinking"] = ["type": "disabled"]
            case .disabled(.chatTemplate):
                body["chat_template_kwargs"] = ["enable_thinking": false]
            case .disabled(.qwen):
                body["enable_thinking"] = false
            case .providerDefault:
                break
            }
        }
    }

    public var reasoningPolicy: LLMReasoningPolicy { reasoningControl.policy }

    public init(
        id: String,
        displayName: String,
        models: [ProviderModel],
        regions: Set<LLMRegion>,
        auth: any OpenAIChatTransportAuth,
        usesAPIKey: Bool = true,
        acceptsAPIKey: Bool? = nil,
        credentialKind: LLMCredentialKind = .apiKey,
        credentialID: String? = nil,
        subscriptionAccount: (any SubscriptionAccount)? = nil,
        extraBody: [String: JSONValue] = [:],
        cachesSystemPrompt: Bool = false,
        promptCacheRouting: PromptCacheRouting = .sessionHeader,
        maxTokensField: MaxTokensField = .maxTokens,
        reasoningReplayModelIDs: Set<String> = [],
        reasoningControl: ReasoningControl = .providerDefault,
        website: URL? = nil,
        inferenceLocation: LLMInferenceLocation = .remote,
        diagnosticsEndpoint: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.regions = regions
        self.auth = auth
        self.usesAPIKey = usesAPIKey
        self.acceptsAPIKey = acceptsAPIKey ?? usesAPIKey
        self.credentialKind = credentialKind
        self.credentialID = credentialID ?? id
        self.subscriptionAccount = subscriptionAccount
        self.extraBody = extraBody
        self.cachesSystemPrompt = cachesSystemPrompt
        self.promptCacheRouting = promptCacheRouting
        self.maxTokensField = maxTokensField
        self.reasoningReplayModelIDs = reasoningReplayModelIDs
        self.reasoningControl = reasoningControl
        self.website = website
        self.inferenceLocation = inferenceLocation
        self.diagnosticsEndpoint = diagnosticsEndpoint
    }

    public init(
        id: String,
        displayName: String,
        models: [ProviderModel],
        regions: Set<LLMRegion> = [.global],
        baseURL: URL,
        extraHeaders: [String: String] = [:],
        extraBody: [String: JSONValue] = [:],
        cachesSystemPrompt: Bool = false,
        promptCacheRouting: PromptCacheRouting = .sessionHeader,
        maxTokensField: MaxTokensField = .maxTokens,
        website: URL? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            models: models,
            regions: regions,
            auth: OpenAIAPIKeyAuth(clientID: id, baseURL: baseURL, extraHeaders: extraHeaders),
            extraBody: extraBody,
            cachesSystemPrompt: cachesSystemPrompt,
            promptCacheRouting: promptCacheRouting,
            maxTokensField: maxTokensField,
            website: website,
            diagnosticsEndpoint: baseURL
        )
    }

    public func stream(
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
        let label = "\(displayName).stream"
        let toolNames = tools.map(\.name).joined(separator: ",")
        let sysLen = systemPrompt?.count ?? 0
        let cacheKey = options.promptCachePolicy == .standard
            ? options.sessionID ?? promptCacheKey(model: model, systemPrompt: systemPrompt, tools: tools)
            : nil
        let body = try buildRequestBody(
            model: model, systemPrompt: systemPrompt, messages: messages,
            tools: tools, options: options,
            promptCacheKey: promptCacheRouting == .requestBody ? cacheKey : nil
        )
        LogContext.latency?.mark(.requestBodyReady)

        var forceRefresh = false
        let maxAttempts = auth.canRefresh ? 2 : 1
        for attempt in 1...maxAttempts {
            let endpoint = try await auth.resolve(forceRefresh: forceRefresh)
            LogContext.latency?.mark(.authReady)
            var url = endpoint.baseURL
            url.appendPathComponent("chat/completions")

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
            if promptCacheRouting == .sessionHeader, let cacheKey {
                req.setValue(cacheKey, forHTTPHeaderField: "x-session-id")
            }
            req.httpBody = body

            Log.network.info("\(label) POST \(LogPrivacy.url(url.absoluteString)) attempt=\(attempt) model=\(model.id) msgs=\(messages.count) sysChars=\(sysLen) tools=\(tools.count) [\(toolNames)] reasoning=\(reasoningPolicy.rawValue) cache=\(options.promptCachePolicy == .standard ? "standard" : "disabled") route=\(promptCacheRouting.rawValue) session=\(cacheKey ?? "none") bodyBytes=\(body.count)")
            Log.network.info("\(label) wire=[\(messages.wireSignature)]")
            let response = try await StreamingHTTP.open(req, label: label) {
                OpenAIClientError(message: "No HTTP response")
            }
            let genId = response.http.value(forHTTPHeaderField: "X-Generation-Id") ?? "?"
            Log.network.info("\(label) response genId=\(LogPrivacy.text(genId, limit: 128))")

            if response.statusCode == 401, attempt < maxAttempts {
                Log.network.warning("\(label) 401; refreshing token and retrying")
                forceRefresh = true
                continue
            }
            try await response.requireSuccess { _, text in
                OpenAIClientError(
                    message: "HTTP \(response.statusCode): \(text)",
                    failureKind: llmFailureKind(statusCode: response.statusCode, message: text)
                )
            }

            try await consume(bytes: response.bytes, model: model, label: label, genId: genId, continuation: continuation)
            return
        }
    }

    private func consume(
        bytes: URLSession.AsyncBytes,
        model: ProviderModel,
        label: String,
        genId: String,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        var assembler = StreamAssembler(model: model, continuation: continuation)
        var toolCallSlots: [Int: Int] = [:]
        var toolCallArgBuffers: [Int: String] = [:]
        var toolCallIds: [Int: String] = [:]
        var toolCallNames: [Int: String] = [:]
        var stopReason: StopReason = .pending
        var sawFinishReason = false
        var failed = false

        func slotToolCall(_ slot: Int) -> ToolCall {
            ToolCall(
                id: toolCallIds[slot] ?? "",
                name: toolCallNames[slot] ?? "",
                arguments: JSONValue.parse(jsonString: toolCallArgBuffers[slot] ?? "") ?? .object([:])
            )
        }

        let lines = try await SSE.forEachDataChunk(bytes, label: label) { chunk in
            if let err = chunk["error"] as? [String: Any] {
                let message = (err["message"] as? String) ?? "stream error"
                let code = err["code"].map { "\($0)" } ?? "unknown"
                Log.network.error("\(label) mid-stream error genId=\(LogPrivacy.text(genId, limit: 128)) code=\(LogPrivacy.text(code, limit: 128)): \(LogPrivacy.text(message, limit: 2_048))")
                assembler.fail(message)
                failed = true
                return false
            }

            if let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first {
                assembler.start()
                assembler.setResponseID(chunk["id"] as? String)

                if let delta = choice["delta"] as? [String: Any] {
                    if let r = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String) {
                        assembler.thinkingDelta(r)
                    }
                    if let txt = delta["content"] as? String {
                        assembler.textDelta(txt)
                    }
                    if let tcs = delta["tool_calls"] as? [[String: Any]] {
                        for tc in tcs {
                            let slot = tc["index"] as? Int ?? 0
                            if toolCallSlots[slot] == nil {
                                toolCallSlots[slot] = assembler.openToolCall()
                                toolCallArgBuffers[slot] = ""
                            }
                            if let id = tc["id"] as? String { toolCallIds[slot] = id }
                            if let fn = tc["function"] as? [String: Any] {
                                if let n = fn["name"] as? String, !n.isEmpty {
                                    toolCallNames[slot] = (toolCallNames[slot] ?? "") + n
                                }
                                if let a = fn["arguments"] as? String, !a.isEmpty {
                                    toolCallArgBuffers[slot, default: ""] += a
                                }
                            }
                            assembler.updateToolCall(at: toolCallSlots[slot]!, slotToolCall(slot))
                        }
                    }
                }

                if let fr = choice["finish_reason"] as? String {
                    sawFinishReason = true
                    assembler.setRawStopReason(fr)
                    switch fr {
                    case "tool_calls": stopReason = .toolUse
                    case "length": stopReason = .length
                    case "error":
                        Log.network.error("\(label) finish_reason=error genId=\(genId)")
                        assembler.fail("stream ended with finish_reason=error")
                        failed = true
                        return false
                    default: stopReason = .stop
                    }
                }
            }

            if let usage = chunk["usage"] as? [String: Any] {
                var u = Usage()
                u.input = (usage["prompt_tokens"] as? Int) ?? 0
                u.output = (usage["completion_tokens"] as? Int) ?? 0
                u.cachedInput = (usage["cached_tokens"] as? Int)
                    ?? (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
                    ?? 0
                u.cacheWriteInput = (usage["prompt_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int
                u.totalTokens = (usage["total_tokens"] as? Int) ?? (u.input + u.output)
                assembler.setUsage(u)
            }
            return true
        }
        if failed { return }
        guard sawFinishReason else {
            throw OpenAIClientError(message: "Chat Completions stream ended before a finish reason")
        }

        assembler.endThinking()
        assembler.endText()
        for (slot, idx) in toolCallSlots {
            assembler.endToolCall(at: idx, slotToolCall(slot))
        }
        assembler.finish(reason: stopReason, label: label, lines: lines)
    }

    private func buildRequestBody(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions,
        promptCacheKey: String?
    ) throws -> Data {
        var msgs: [[String: Any]] = []
        if let sp = systemPrompt, !sp.isEmpty {
            msgs.append(systemMessage(sp, useCache: options.promptCachePolicy == .standard))
        }
        var pendingToolMedia: [TransientAttachment] = []
        func flushToolMedia() throws {
            guard !pendingToolMedia.isEmpty else { return }
            msgs.append(try buildToolMediaMessage(pendingToolMedia))
            pendingToolMedia = []
        }
        for m in messages {
            switch m {
            case .user(let u):
                try flushToolMedia()
                msgs.append(try buildUserMessage(u))
            case .assistant(let a):
                try flushToolMedia()
                msgs.append(buildAssistantMessage(a, model: model))
            case .toolResult(let r):
                let result = ToolResultParts(r, label: "\(displayName).buildToolResultMessage")
                msgs.append(buildToolResultMessage(r, text: result.text))
                pendingToolMedia.append(contentsOf: result.media)
            }
        }
        try flushToolMedia()

        var body: [String: Any] = [
            "model": model.wireID,
            "messages": msgs,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if let t = options.temperature { body["temperature"] = t }
        body[maxTokensField.rawValue] = options.maxTokens ?? model.maxTokens
        reasoningControl.apply(to: &body, model: model)
        if let promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        for (key, value) in extraBody { body[key] = value.toAny() }

        let allTools: [[String: Any]] = tools.map { ["type": "function", "function": $0.declarationJSON] }
        if !allTools.isEmpty { body["tools"] = allTools }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func systemMessage(_ text: String, useCache: Bool) -> [String: Any] {
        guard cachesSystemPrompt, useCache else { return ["role": "system", "content": text] }
        return [
            "role": "system",
            "content": [["type": "text", "text": text, "cache_control": ["type": "ephemeral"]]]
        ]
    }

    private func buildUserMessage(_ u: UserMessage) throws -> [String: Any] {
        let split = UserMessageParts(u, label: "\(displayName).buildUserMessage")
        if split.media.isEmpty {
            return ["role": "user", "content": split.text]
        }
        var parts: [[String: Any]] = []
        if !split.text.isEmpty {
            parts.append(["type": "text", "text": split.text])
        }
        for (a, data) in split.media {
            let b64 = data.base64EncodedString()
            switch a.kind {
            case .image:
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(a.mimeType);base64,\(b64)"]
                ])
            case .pdf:
                let pdf = try PDFPreparer.prepareArtifact(data)
                parts.append([
                    "type": "file",
                    "file": [
                        "filename": a.displayName,
                        "file_data": "data:\(pdf.mimeType);base64,\(pdf.data.base64EncodedString())"
                    ]
                ])
            case .text, .html:
                break
            case .file:
                break
            }
        }
        return ["role": "user", "content": parts]
    }

    private func buildAssistantMessage(_ a: AssistantMessage, model: ProviderModel) -> [String: Any] {
        let toolCalls: [[String: Any]] = a.content.toolCalls.map { tc in
            [
                "id": tc.id,
                "type": "function",
                "function": [
                    "name": tc.name,
                    "arguments": tc.arguments.jsonString()
                ]
            ]
        }
        let text = a.content.concatenatedText
        var msg: [String: Any] = ["role": "assistant"]
        msg["content"] = text.isEmpty ? NSNull() : text
        let thinking = a.content.concatenatedThinking
        if reasoningReplayModelIDs.contains(model.wireID), !thinking.isEmpty {
            msg["reasoning_content"] = thinking
        }
        if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
        return msg
    }

    private func buildToolResultMessage(_ r: ToolResultMessage, text: String) -> [String: Any] {
        let content = r.isError
            ? JSONValue.object(["error": .string(text)]).jsonString(fallback: text)
            : text
        return [
            "role": "tool",
            "tool_call_id": r.toolCallId,
            "content": content
        ]
    }

    private func buildToolMediaMessage(_ media: [TransientAttachment]) throws -> [String: Any] {
        var parts: [[String: Any]] = []
        for attachment in media {
            switch attachment.kind {
            case .image:
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"]
                ])
            case .pdf:
                let pdf = try PDFPreparer.prepareArtifact(attachment.data)
                parts.append([
                    "type": "file",
                    "file": [
                        "filename": attachment.displayName,
                        "file_data": "data:\(pdf.mimeType);base64,\(pdf.data.base64EncodedString())"
                    ]
                ])
            case .text, .file:
                parts.append([
                    "type": "file",
                    "file": [
                        "filename": attachment.displayName,
                        "file_data": "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
                    ]
                ])
            }
        }
        return ["role": "user", "content": parts]
    }

}

public struct OpenAIClientError: ProviderClientError {
    public let message: String
    public let failureKind: LLMFailureKind

    public init(message: String, failureKind: LLMFailureKind? = nil) {
        self.message = message
        self.failureKind = failureKind ?? llmFailureKind(message: message)
    }
}
