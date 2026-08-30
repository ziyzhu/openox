import Foundation

public struct OpenAIResponsesTransport: ProviderClient {
    public let id: String
    public let displayName: String
    public let models: [ProviderModel]
    public let regions: Set<LLMRegion>
    public let website: URL?
    public let authNotice: String?
    public let usesAPIKey: Bool
    public let acceptsAPIKey: Bool
    public let credentialKind: LLMCredentialKind
    public let subscriptionAccount: (any SubscriptionAccount)?
    public let auth: any OpenAIResponsesTransportAuth
    public let sessionHeaderName: String
    public let extraBody: [String: JSONValue]
    public let reasoningEffort: LLMReasoningEffort
    public let serviceTier: @Sendable (ProviderModel) -> String?
    public let streamingTransport: OpenAIResponsesStreamingTransport
    public var reasoningPolicy: LLMReasoningPolicy { reasoningEffort.policy }
    public func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { .openAIResponses }
    public init(
        id: String,
        displayName: String,
        models: [ProviderModel],
        regions: Set<LLMRegion> = [.global],
        website: URL? = nil,
        authNotice: String? = nil,
        usesAPIKey: Bool = true,
        acceptsAPIKey: Bool? = nil,
        credentialKind: LLMCredentialKind = .apiKey,
        subscriptionAccount: (any SubscriptionAccount)? = nil,
        auth: any OpenAIResponsesTransportAuth,
        sessionHeaderName: String = "x-session-id",
        extraBody: [String: JSONValue] = [:],
        reasoningEffort: LLMReasoningEffort = .none,
        serviceTier: @escaping @Sendable (ProviderModel) -> String? = { _ in nil },
        streamingTransport: OpenAIResponsesStreamingTransport = .serverSentEvents
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.regions = regions
        self.website = website
        self.authNotice = authNotice
        self.usesAPIKey = usesAPIKey
        self.acceptsAPIKey = acceptsAPIKey ?? usesAPIKey
        self.credentialKind = credentialKind
        self.subscriptionAccount = subscriptionAccount
        self.auth = auth
        self.sessionHeaderName = sessionHeaderName
        self.extraBody = extraBody
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.streamingTransport = streamingTransport
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
                model: model, systemPrompt: systemPrompt, messages: messages,
                tools: tools, options: options, continuation: continuation
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
        let cacheKey = options.sessionID ?? promptCacheKey(model: model, systemPrompt: systemPrompt, tools: tools)
        let promptCacheKey = options.promptCachePolicy == .standard ? cacheKey : nil
        let serviceTier = serviceTier(model)
        let body = try buildBody(
            model: model, systemPrompt: systemPrompt, messages: messages,
            tools: tools, promptCacheKey: promptCacheKey, serviceTier: serviceTier
        )
        LogContext.latency?.mark(.requestBodyReady)
        let label = "\(displayName).stream"

        var forceRefresh = false
        let maxAttempts = auth.canRefresh ? 2 : 1
        for attempt in 1...maxAttempts {
            let endpoint = try await auth.resolve(forceRefresh: forceRefresh)
            LogContext.latency?.mark(.authReady)

            if case .webSocketWithServerSentEventsFallback(let accountHeader) = streamingTransport,
               let accountID = endpoint.headers.first(where: { $0.key.caseInsensitiveCompare(accountHeader) == .orderedSame })?.value {
                let sessionID = options.promptCachePolicy == .standard ? options.sessionID : nil
                if !(await OpenAIResponsesWebSocketPool.shared.fallbackActive(sessionID: sessionID)) {
                    var reconnectAvailable = true
                    while true {
                        do {
                            try await runWebSocket(
                                endpoint: endpoint,
                                body: body,
                                model: model,
                                cacheKey: cacheKey,
                                sessionID: sessionID,
                                accountID: accountID,
                                label: label,
                                continuation: continuation
                            )
                            return
                        } catch let failure as OpenAIResponsesWebSocketFailure {
                            if reconnectAvailable, failure.connectionReused, !failure.eventsReceived {
                                reconnectAvailable = false
                                Log.network.warning("\(label) reused WebSocket failed before stream start; reconnecting error=\(LogPrivacy.text(failure.underlying.localizedDescription, limit: 2_048))")
                                continue
                            }
                            await OpenAIResponsesWebSocketPool.shared.recordFailure(
                                sessionID: sessionID,
                                message: failure.underlying.localizedDescription
                            )
                            if failure.eventsReceived { throw failure.underlying }
                            Log.network.warning("\(label) WebSocket failed before stream start; falling back to SSE error=\(LogPrivacy.text(failure.underlying.localizedDescription, limit: 2_048))")
                            break
                        }
                    }
                }
            }

            let response = try await openServerSentEvents(
                endpoint: endpoint,
                body: body,
                model: model,
                messages: messages,
                tools: tools,
                options: options,
                cacheKey: cacheKey,
                serviceTier: serviceTier,
                attempt: attempt,
                label: label
            )

            if response.statusCode == 401, attempt < maxAttempts {
                Log.network.warning("\(label) 401; forcing token refresh and retrying")
                forceRefresh = true
                continue
            }
            try await response.requireSuccess { _, text in
                OpenAIClientError(
                    message: "\(displayName) HTTP \(response.statusCode): \(text)",
                    failureKind: llmFailureKind(statusCode: response.statusCode, message: text)
                )
            }

            try await consumeServerSentEvents(bytes: response.bytes, model: model, label: label, continuation: continuation)
            return
        }
    }

    private func openServerSentEvents(
        endpoint: OpenAIResponsesEndpoint,
        body: Data,
        model: ProviderModel,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions,
        cacheKey: String,
        serviceTier: String?,
        attempt: Int,
        label: String
    ) async throws -> StreamingHTTP.Response {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(cacheKey, forHTTPHeaderField: sessionHeaderName)
        request.httpBody = body

        let toolNames = tools.map(\.name).joined(separator: ",")
        Log.network.info("\(label) SSE POST attempt=\(attempt) model=\(model.id) msgs=\(messages.count) tools=\(tools.count) [\(toolNames)] reasoning=\(reasoningPolicy.rawValue) tier=\(serviceTier ?? "standard") cache=\(options.promptCachePolicy == .standard ? "standard" : "disabled") session=\(cacheKey) bodyBytes=\(body.count)")
        return try await StreamingHTTP.open(request, label: label) {
            OpenAIClientError(message: "No HTTP response from \(displayName)")
        }
    }

    private func runWebSocket(
        endpoint: OpenAIResponsesEndpoint,
        body: Data,
        model: ProviderModel,
        cacheKey: String,
        sessionID: String?,
        accountID: String,
        label: String,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        guard var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else {
            throw OpenAIResponsesWebSocketFailure(
                underlying: OpenAIClientError(message: "Invalid ChatGPT Responses URL"),
                eventsReceived: false,
                connectionReused: false
            )
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else {
            throw OpenAIResponsesWebSocketFailure(
                underlying: OpenAIClientError(message: "Invalid ChatGPT WebSocket URL"),
                eventsReceived: false,
                connectionReused: false
            )
        }

        var request = URLRequest(url: url)
        for (key, value) in endpoint.headers where
            key.caseInsensitiveCompare("Accept") != .orderedSame
                && key.caseInsensitiveCompare("Content-Type") != .orderedSame
                && key.caseInsensitiveCompare("OpenAI-Beta") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(cacheKey, forHTTPHeaderField: sessionHeaderName)
        request.setValue(cacheKey, forHTTPHeaderField: "x-client-request-id")

        LogContext.latency?.mark(.httpStarted)
        let lease = await OpenAIResponsesWebSocketPool.shared.acquire(
            request: request,
            sessionID: sessionID,
            accountID: accountID
        )
        var eventsReceived = false
        do {
            let requestBody = try OpenAIResponsesWebSocketBody.request(body, continuing: lease.continuation)
            guard let message = String(data: requestBody, encoding: .utf8) else {
                throw OpenAIClientError(message: "Invalid ChatGPT WebSocket request encoding")
            }
            let continued = (try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any])?["previous_response_id"] != nil
            Log.network.info("\(label) WebSocket send connection=\(lease.reused ? "reused" : "new") continuation=\(continued ? "delta" : "full") session=\(cacheKey) bodyBytes=\(requestBody.count)")
            try await lease.task.send(.string(message))
            let completed = try await consume(
                events: OpenAIResponsesWebSocketEvents(task: lease.task),
                model: model,
                label: label,
                continuation: continuation,
                onEvent: {
                    if !eventsReceived {
                        eventsReceived = true
                        LogContext.latency?.mark(.responseHeaders)
                    }
                }
            )
            let next = completed.map {
                OpenAIResponsesWebSocketContinuation(
                    requestBody: body,
                    responseID: $0.responseID,
                    responseOutput: $0.responseOutput
                )
            }
            await OpenAIResponsesWebSocketPool.shared.release(
                lease,
                keep: true,
                continuation: next
            )
        } catch {
            await OpenAIResponsesWebSocketPool.shared.release(lease, keep: false, continuation: nil)
            throw OpenAIResponsesWebSocketFailure(
                underlying: error,
                eventsReceived: eventsReceived,
                connectionReused: lease.reused
            )
        }
    }

    private func consumeServerSentEvents(
        bytes: URLSession.AsyncBytes,
        model: ProviderModel,
        label: String,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        _ = try await consume(
            events: SSE.events(bytes, label: label),
            model: model,
            label: label,
            continuation: continuation
        )
    }

    private func consume<Events: AsyncSequence>(
        events: Events,
        model: ProviderModel,
        label: String,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation,
        onEvent: () -> Void = {}
    ) async throws -> OpenAIResponsesCompletion? where Events.Element == [String: Any] {
        var assembler = StreamAssembler(model: model, continuation: continuation)
        var stopReason: StopReason = .pending
        var sawTerminalResponse = false
        var failed = false
        var terminalResponseID: String?
        var terminalResponseOutput: Data?
        var textItems: [Int: Int] = [:]
        var reasoningItems: [Int: Int] = [:]
        var functionCallSlots: [Int: Int] = [:]
        var functionCallArgBuffers: [Int: String] = [:]
        var functionCallIds: [Int: String] = [:]
        var functionCallNames: [Int: String] = [:]
        var functionCallItemIds: [Int: String] = [:]
        var endedFunctionCalls = Set<Int>()

        func functionCall(_ outputIndex: Int) -> ToolCall {
            ToolCall(
                id: functionCallIds[outputIndex] ?? functionCallItemIds[outputIndex] ?? "",
                name: functionCallNames[outputIndex] ?? "",
                arguments: parseArguments(functionCallArgBuffers[outputIndex]),
                providerItemID: functionCallItemIds[outputIndex]
            )
        }

        let handleEvent: ([String: Any]) -> Bool = { evt in
            if let err = evt["error"] as? [String: Any] {
                let message = (err["message"] as? String) ?? "stream error"
                Log.network.error("\(label) mid-stream error: \(LogPrivacy.text(message, limit: 2_048))")
                assembler.fail(message); failed = true; return false
            }
            guard let type = evt["type"] as? String else { return true }
            switch type {
            case "response.created":
                assembler.setResponseID((evt["response"] as? [String: Any])?["id"] as? String)
            case "response.output_item.added":
                guard let outputIndex = evt["output_index"] as? Int,
                      let item = evt["item"] as? [String: Any]
                else { break }
                switch item["type"] as? String {
                case "message": textItems[outputIndex] = assembler.startTextItem()
                case "reasoning": reasoningItems[outputIndex] = assembler.startReasoningItem()
                case "function_call":
                    functionCallSlots[outputIndex] = assembler.openToolCall()
                    functionCallArgBuffers[outputIndex] = item["arguments"] as? String ?? ""
                    functionCallIds[outputIndex] = item["call_id"] as? String
                    functionCallNames[outputIndex] = item["name"] as? String
                    functionCallItemIds[outputIndex] = item["id"] as? String
                    if !(functionCallArgBuffers[outputIndex] ?? "").isEmpty {
                        assembler.start()
                        assembler.updateToolCall(at: functionCallSlots[outputIndex]!, functionCall(outputIndex))
                    }
                default: break
                }
            case "response.output_text.delta":
                assembler.start()
                if let delta = evt["delta"] as? String { assembler.textDelta(delta) }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                assembler.start()
                if let delta = evt["delta"] as? String { assembler.thinkingDelta(delta) }
            case "response.function_call_arguments.delta":
                guard let outputIndex = evt["output_index"] as? Int,
                      let delta = evt["delta"] as? String,
                      !delta.isEmpty
                else { break }
                if functionCallSlots[outputIndex] == nil {
                    functionCallSlots[outputIndex] = assembler.openToolCall()
                    functionCallArgBuffers[outputIndex] = ""
                }
                if let itemID = evt["item_id"] as? String { functionCallItemIds[outputIndex] = itemID }
                functionCallArgBuffers[outputIndex, default: ""] += delta
                assembler.start()
                assembler.updateToolCall(at: functionCallSlots[outputIndex]!, functionCall(outputIndex))
            case "response.function_call_arguments.done":
                guard let outputIndex = evt["output_index"] as? Int else { break }
                if functionCallSlots[outputIndex] == nil {
                    functionCallSlots[outputIndex] = assembler.openToolCall()
                }
                if let arguments = evt["arguments"] as? String { functionCallArgBuffers[outputIndex] = arguments }
                if let name = evt["name"] as? String { functionCallNames[outputIndex] = name }
                if let itemID = evt["item_id"] as? String { functionCallItemIds[outputIndex] = itemID }
                assembler.start()
                assembler.endToolCall(at: functionCallSlots[outputIndex]!, functionCall(outputIndex))
                endedFunctionCalls.insert(outputIndex)
                stopReason = .toolUse
            case "response.output_item.done":
                if let item = evt["item"] as? [String: Any] {
                    switch item["type"] as? String {
                    case "reasoning":
                        let outputIndex = evt["output_index"] as? Int
                        assembler.setReasoningItem(item, at: outputIndex.flatMap { reasoningItems.removeValue(forKey: $0) })
                    case "message":
                        let content = (item["content"] as? [[String: Any]])?.compactMap { part -> String? in
                            (part["text"] as? String) ?? (part["refusal"] as? String)
                        }.joined()
                        if let id = item["id"] as? String {
                            let outputIndex = evt["output_index"] as? Int
                            assembler.setTextItem(
                                id: id,
                                phase: item["phase"] as? String,
                                text: content,
                                at: outputIndex.flatMap { textItems.removeValue(forKey: $0) }
                            )
                        }
                    case "function_call":
                        guard let outputIndex = evt["output_index"] as? Int else { break }
                        functionCallArgBuffers[outputIndex] = item["arguments"] as? String ?? functionCallArgBuffers[outputIndex] ?? ""
                        functionCallIds[outputIndex] = item["call_id"] as? String ?? functionCallIds[outputIndex]
                        functionCallNames[outputIndex] = item["name"] as? String ?? functionCallNames[outputIndex]
                        functionCallItemIds[outputIndex] = item["id"] as? String ?? functionCallItemIds[outputIndex]
                        if !endedFunctionCalls.contains(outputIndex) {
                            assembler.start()
                            if let slot = functionCallSlots[outputIndex] {
                                assembler.endToolCall(at: slot, functionCall(outputIndex))
                            } else {
                                assembler.completeToolCall(functionCall(outputIndex))
                            }
                            endedFunctionCalls.insert(outputIndex)
                        }
                        stopReason = .toolUse
                    default:
                        break
                    }
                }
            case "response.failed":
                sawTerminalResponse = true
                let response = evt["response"] as? [String: Any]
                assembler.setResponseID(response?["id"] as? String)
                assembler.setRawStopReason(response?["status"] as? String)
                let error = response?["error"] as? [String: Any]
                let details = response?["incomplete_details"] as? [String: Any]
                let message = (error?["message"] as? String)
                    ?? (details?["reason"] as? String).map { "incomplete: \($0)" }
                    ?? "response failed"
                Log.network.error("\(label) response.failed: \(LogPrivacy.text(message, limit: 2_048))")
                assembler.fail(message); failed = true; return false
            case "response.completed", "response.incomplete":
                guard let response = evt["response"] as? [String: Any] else { return true }
                sawTerminalResponse = true
                terminalResponseID = response["id"] as? String
                assembler.setResponseID(terminalResponseID)
                if let output = response["output"] as? [Any] {
                    terminalResponseOutput = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                }
                let status = (response["status"] as? String) ?? (type == "response.incomplete" ? "incomplete" : "completed")
                assembler.setRawStopReason(status)
                stopReason = status == "incomplete" ? .length : (assembler.hasToolCalls ? .toolUse : .stop)
                for item in response["output"] as? [[String: Any]] ?? [] where (item["type"] as? String) == "reasoning" {
                    assembler.setReasoningItem(item)
                }
                if let usage = response["usage"] as? [String: Any] {
                    var u = Usage()
                    u.input = usage["input_tokens"] as? Int ?? 0
                    u.output = usage["output_tokens"] as? Int ?? 0
                    u.totalTokens = usage["total_tokens"] as? Int ?? (u.input + u.output)
                    let inputDetails = usage["input_tokens_details"] as? [String: Any]
                    u.cachedInput = inputDetails?["cached_tokens"] as? Int ?? 0
                    u.cacheWriteInput = inputDetails?["cache_write_tokens"] as? Int
                    assembler.setUsage(u)
                }
                return false
            default:
                break
            }
            return true
        }
        var lines = 0
        for try await event in events {
            lines += 1
            onEvent()
            if !handleEvent(event) { break }
        }
        if failed { return nil }
        guard sawTerminalResponse else {
            throw OpenAIClientError(message: "\(displayName) Responses stream ended before a terminal response event")
        }
        assembler.finish(reason: stopReason, label: label, lines: lines)
        guard let terminalResponseID, let terminalResponseOutput else { return nil }
        return OpenAIResponsesCompletion(
            responseID: terminalResponseID,
            responseOutput: terminalResponseOutput
        )
    }

    private func buildBody(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        promptCacheKey: String?,
        serviceTier: String?
    ) throws -> Data {
        var input: [[String: Any]] = []
        for (messageIndex, m) in messages.enumerated() {
            switch m {
            case .user(let u):
                let parts = UserMessageParts(u, label: "\(displayName).buildUser")
                var content: [[String: Any]] = []
                if !parts.text.isEmpty { content.append(["type": "input_text", "text": parts.text]) }
                for (a, data) in parts.media {
                    switch a.kind {
                    case .image:
                        content.append([
                            "type": "input_image",
                            "image_url": "data:\(a.mimeType);base64,\(data.base64EncodedString())",
                        ])
                    case .pdf:
                        let pdf = try PDFPreparer.prepareArtifact(data)
                        content.append([
                            "type": "input_file",
                            "filename": a.displayName,
                            "file_data": "data:\(pdf.mimeType);base64,\(pdf.data.base64EncodedString())",
                        ])
                    case .text, .html, .file:
                        break
                    }
                }
                if !content.isEmpty {
                    input.append(["type": "message", "role": "user", "content": content])
                }
            case .assistant(let a):
                for (blockIndex, block) in a.content.enumerated() {
                    switch block {
                    case .thinking(let content):
                        guard let signature = content.thinkingSignature,
                              let data = signature.data(using: .utf8),
                              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        input.append(item)
                    case .text(let content):
                        guard !content.text.isEmpty else { continue }
                        let signature = parseTextSignature(content.textSignature)
                        var item: [String: Any] = [
                            "type": "message",
                            "role": "assistant",
                            "content": [["type": "output_text", "text": content.text, "annotations": []]],
                            "status": "completed",
                            "id": signature.id ?? "msg_ox_\(messageIndex)_\(blockIndex)",
                        ]
                        if let phase = signature.phase { item["phase"] = phase }
                        input.append(item)
                    case .toolCall(let toolCall):
                        var item: [String: Any] = [
                            "type": "function_call",
                            "name": toolCall.name,
                            "arguments": toolCall.arguments.jsonString(),
                            "call_id": toolCall.id,
                        ]
                        if let providerItemID = toolCall.providerItemID, !providerItemID.isEmpty {
                            item["id"] = providerItemID
                        }
                        input.append(item)
                    case .attachment:
                        continue
                    }
                }
            case .toolResult(let r):
                let parts = ToolResultParts(r, label: "\(displayName).buildToolResult")
                let resultText = r.isError
                    ? JSONValue.object(["error": .string(parts.text)]).jsonString(fallback: parts.text)
                    : parts.text
                var output: [[String: Any]] = []
                if !resultText.isEmpty {
                    output.append(["type": "input_text", "text": resultText])
                }
                for attachment in parts.media {
                    switch attachment.kind {
                    case .image:
                        output.append([
                            "type": "input_image",
                            "image_url": "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())",
                        ])
                    case .pdf:
                        let pdf = try PDFPreparer.prepareArtifact(attachment.data)
                        output.append([
                            "type": "input_file",
                            "filename": attachment.displayName,
                            "file_data": "data:\(pdf.mimeType);base64,\(pdf.data.base64EncodedString())",
                        ])
                    case .text, .file:
                        output.append([
                            "type": "input_file",
                            "filename": attachment.displayName,
                            "file_data": "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())",
                        ])
                    }
                }
                input.append([
                    "type": "function_call_output",
                    "call_id": r.toolCallId,
                    "output": parts.media.isEmpty ? resultText : output,
                ])
            }
        }

        let toolDecls: [[String: Any]] = tools.map {
            let parameters = normalizeToolParameters($0.parameters, strict: $0.strict)
            return ["type": "function", "name": $0.name, "description": $0.description, "strict": $0.strict, "parameters": parameters.toAny()]
        }

        let selectedReasoningEffort = model.selectedReasoningEffort ?? reasoningEffort.rawValue
        var reasoning: [String: Any] = ["effort": selectedReasoningEffort]
        if selectedReasoningEffort != "none" { reasoning["summary"] = "auto" }
        var body: [String: Any] = [
            "model": model.wireID,
            "input": input,
            "tools": toolDecls,
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "reasoning": reasoning,
            "include": ["reasoning.encrypted_content"],
        ]
        for (key, value) in extraBody { body[key] = value.toAny() }
        if let serviceTier { body["service_tier"] = serviceTier }
        if let promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        if let sp = systemPrompt, !sp.isEmpty { body["instructions"] = sp }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func normalizeToolParameters(_ value: JSONValue, strict: Bool) -> JSONValue {
        switch value {
        case .array(let values):
            return .array(values.map { normalizeToolParameters($0, strict: strict) })
        case .object(let source):
            var schema = source.mapValues { normalizeToolParameters($0, strict: strict) }
            schema.removeValue(forKey: "uniqueItems")
            guard strict, isObjectSchema(schema), case .object(var properties)? = schema["properties"] else {
                return .object(schema)
            }

            let required = Set(source["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for name in properties.keys where !required.contains(name) {
                properties[name] = properties[name].map(nullableToolParameter)
            }
            schema["properties"] = .object(properties)
            schema["required"] = .array(properties.keys.sorted().map(JSONValue.string))
            schema["additionalProperties"] = .bool(false)
            return .object(schema)
        default:
            return value
        }
    }

    private func isObjectSchema(_ schema: [String: JSONValue]) -> Bool {
        if schema["type"]?.stringValue == "object" {
            return true
        }
        return schema["type"]?.arrayValue?.contains(.string("object")) == true
    }

    private func nullableToolParameter(_ value: JSONValue) -> JSONValue {
        guard case .object(var schema) = value else { return value }
        if let type = schema["type"]?.stringValue {
            schema["type"] = .array([.string(type), .string("null")])
        } else if case .array(var types)? = schema["type"], !types.contains(.string("null")) {
            types.append(.string("null"))
            schema["type"] = .array(types)
        } else if case .array(var alternatives)? = schema["anyOf"] {
            alternatives.append(.object(["type": .string("null")]))
            schema["anyOf"] = .array(alternatives)
        }
        return .object(schema)
    }

    private func parseArguments(_ raw: Any?) -> JSONValue {
        if let s = raw as? String { return JSONValue.parse(jsonString: s) ?? .object([:]) }
        if let raw { return JSONValue.from(raw) }
        return .object([:])
    }

    private func parseTextSignature(_ raw: String?) -> (id: String?, phase: String?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        guard raw.hasPrefix("{"),
              let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["v"] as? Int == 1
        else { return (raw, nil) }
        let phase = value["phase"] as? String
        return (value["id"] as? String, phase == "commentary" || phase == "final_answer" ? phase : nil)
    }
}
