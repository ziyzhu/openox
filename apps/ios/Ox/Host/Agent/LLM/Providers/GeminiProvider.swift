import Foundation
import CryptoKit

public struct GeminiConfig: Sendable {
    public var baseURL: URL
    public init(baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!) {
        self.baseURL = baseURL
    }
}

public struct GeminiProvider: ProviderClient {
    public let config: GeminiConfig
    public let models: [ProviderModel]
    public init(models: [ProviderModel], config: GeminiConfig = GeminiConfig()) {
        self.models = models
        self.config = config
    }

    public let id = "gemini"
    public let displayName = "Gemini"
    public let regions: Set<LLMRegion> = [.global]
    public let reasoningPolicy: LLMReasoningPolicy = .minimal
    public let website = URL(string: "https://aistudio.google.com/apikey")
    public var protocolDiagnostics: LLMProtocolDiagnostics {
        LLMProtocolDiagnostics(endpoint: config.baseURL.absoluteString)
    }
    public func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { .geminiGenerateContent }
    private func resolvedAPIKey() throws -> String {
        guard let key = Credentials.key(for: id) else {
            throw GeminiError(message: "Missing API key for Gemini. Add one in provider settings.")
        }
        return key
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

    public func prepare(
        model: ProviderModel,
        systemPrompt: String?,
        tools: [any AgentTool]
    ) async -> LLMPreparationOutcome {
        let fingerprint = cacheFingerprint(model: model, systemPrompt: systemPrompt, tools: tools)
        let name = await resolveCachedContent(
            fingerprint: fingerprint,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools
        )
        return name == nil ? .unavailable : .ready
    }

    private func runStream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        let fingerprint = cacheFingerprint(model: model, systemPrompt: systemPrompt, tools: tools)
        let cachedName: String? = if options.promptCachePolicy == .standard {
            await resolveCachedContent(
                fingerprint: fingerprint, model: model, systemPrompt: systemPrompt, tools: tools
            )
        } else {
            nil
        }

        let response = try await openStream(
            model: model, systemPrompt: systemPrompt, messages: messages,
            tools: tools, options: options, cachedContent: cachedName
        )

        if response.statusCode == 404, cachedName != nil {
            await Self.cacheStore.invalidate(fingerprint)
            let body = try await response.errorBody()
            Log.network.warning("Gemini.stream cache 404, retrying uncached: \(LogPrivacy.text(body.text, limit: 2_048))")
            let retry = try await openStream(
                model: model, systemPrompt: systemPrompt, messages: messages,
                tools: tools, options: options, cachedContent: nil
            )
            try await consumeStream(response: retry, model: model, continuation: continuation)
            return
        }

        try await consumeStream(response: response, model: model, continuation: continuation)
    }

    private func openStream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions,
        cachedContent: String?
    ) async throws -> StreamingHTTP.Response {
        var url = config.baseURL
        url.appendPathComponent("models/\(model.wireID):streamGenerateContent")
        url.append(queryItems: [URLQueryItem(name: "alt", value: "sse")])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(try resolvedAPIKey(), forHTTPHeaderField: "x-goog-api-key")
        LogContext.latency?.mark(.authReady)

        let body = try buildRequestBody(
            model: model, systemPrompt: systemPrompt, messages: messages,
            tools: tools, options: options, cachedContent: cachedContent
        )
        LogContext.latency?.mark(.requestBodyReady)
        req.httpBody = body

        let toolNames = tools.map(\.name).joined(separator: ",")
        let sysLen = systemPrompt?.count ?? 0
        let cacheTag = cachedContent.map { "cache=\($0) " } ?? ""
        Log.network.info("Gemini.stream POST \(LogPrivacy.url(url.absoluteString)) model=\(model.id) \(cacheTag)msgs=\(messages.count) sysChars=\(sysLen) tools=\(tools.count) [\(toolNames)] reasoning=\(reasoningPolicy.rawValue) bodyBytes=\(body.count)")
        Log.network.info("Gemini.stream wire=[\(messages.wireSignature)]")
        return try await StreamingHTTP.open(req, label: "Gemini.stream") {
            GeminiError(message: "No HTTP response")
        }
    }

    private func consumeStream(
        response: StreamingHTTP.Response,
        model: ProviderModel,
        label: String = "Gemini.stream",
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        try await response.requireSuccess { data, text in
            let message = Self.apiErrorMessage(data) ?? "HTTP \(response.statusCode): \(text)"
            return GeminiError(
                message: message,
                failureKind: llmFailureKind(statusCode: response.statusCode, message: message)
            )
        }

        var assembler = StreamAssembler(model: model, continuation: continuation)
        var toolCallSeq = 0
        var stopReason: StopReason = .pending
        var sawFinishReason = false
        var failed = false

        let lines = try await SSE.forEachDataChunk(response.bytes, label: label) { chunk in
            let payload = chunk
            assembler.setResponseID((payload["responseId"] as? String) ?? (chunk["traceId"] as? String))
            if let candidates = payload["candidates"] as? [[String: Any]], let candidate = candidates.first {
                assembler.start()

                let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                for part in parts {
                    if let fn = part["functionCall"] as? [String: Any] {
                        toolCallSeq += 1
                        let providerCallID = fn["id"] as? String
                        assembler.completeToolCall(ToolCall(
                            id: providerCallID ?? "call_\(toolCallSeq)",
                            name: fn["name"] as? String ?? "",
                            arguments: JSONValue.from(fn["args"] ?? [:]),
                            thoughtSignature: part["thoughtSignature"] as? String,
                            providerCallID: providerCallID
                        ))
                        continue
                    }
                    guard let txt = part["text"] as? String else { continue }
                    if let thoughtSignature = part["thoughtSignature"] as? String {
                        if (part["thought"] as? Bool) == true {
                            assembler.completeThinkingPart(txt, thoughtSignature: thoughtSignature)
                        } else {
                            assembler.completeTextPart(txt, thoughtSignature: thoughtSignature)
                        }
                        continue
                    }
                    if (part["thought"] as? Bool) == true {
                        assembler.thinkingDelta(txt)
                    } else {
                        assembler.textDelta(txt)
                    }
                }

                if let fr = candidate["finishReason"] as? String {
                    sawFinishReason = true
                    assembler.setRawStopReason(fr)
                    switch fr {
                    case "STOP": stopReason = assembler.hasToolCalls ? .toolUse : .stop
                    case "MAX_TOKENS": stopReason = .length
                    default:
                        Log.network.error("Gemini.stream finishReason=\(fr)")
                        assembler.fail("Gemini stopped: \(fr)")
                        failed = true
                        return false
                    }
                }
            }

            if let usage = payload["usageMetadata"] as? [String: Any] {
                var u = Usage()
                u.input = (usage["promptTokenCount"] as? Int) ?? 0
                u.output = (usage["candidatesTokenCount"] as? Int) ?? 0
                u.cachedInput = (usage["cachedContentTokenCount"] as? Int) ?? 0
                u.totalTokens = (usage["totalTokenCount"] as? Int) ?? (u.input + u.output)
                assembler.setUsage(u)
            }
            return true
        }
        if failed { return }
        guard sawFinishReason else {
            throw GeminiError(message: "Gemini stream ended before a finish reason")
        }
        assembler.finish(reason: stopReason, label: label, lines: lines)
    }

    private static func apiErrorMessage(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
    }

    private func buildRequestBody(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions,
        cachedContent: String?
    ) throws -> Data {
        var contents: [[String: Any]] = []
        for m in messages {
            switch m {
            case .user(let u): contents.append(try buildUserContent(u))
            case .assistant(let a): contents.append(buildAssistantContent(a))
            case .toolResult(let r):
                let content = try buildToolResultContent(r)
                if let last = contents.indices.last,
                   contents[last]["role"] as? String == "user",
                   let existing = contents[last]["parts"] as? [[String: Any]],
                   existing.contains(where: { $0["functionResponse"] != nil }),
                   let additional = content["parts"] as? [[String: Any]] {
                    contents[last]["parts"] = existing + additional
                } else {
                    contents.append(content)
                }
            }
        }

        var generationConfig: [String: Any] = [
            "maxOutputTokens": options.maxTokens ?? model.maxTokens
        ]
        if let t = options.temperature, !model.wireID.hasPrefix("gemini-3.") {
            generationConfig["temperature"] = t
        }
        generationConfig["thinkingConfig"] = [
            "includeThoughts": true,
            "thinkingLevel": model.selectedReasoningEffort ?? "minimal",
        ]

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig
        ]
        if let name = cachedContent {
            body["cachedContent"] = name
        } else {
            if let sys = buildSystemInstruction(systemPrompt) {
                body["systemInstruction"] = sys
            }
            if let toolDecls = buildToolDeclarations(tools) {
                body["tools"] = toolDecls
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildSystemInstruction(_ systemPrompt: String?) -> [String: Any]? {
        guard let sp = systemPrompt, !sp.isEmpty else { return nil }
        return ["parts": [["text": sp]]]
    }

    private func buildToolDeclarations(_ tools: [any AgentTool]) -> [[String: Any]]? {
        guard !tools.isEmpty else { return nil }
        let declarations = tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "parameters": normalizeToolParameters(tool.parameters).toAny(),
            ]
        }
        return [["functionDeclarations": declarations]]
    }

    private func normalizeToolParameters(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values):
            return .array(values.map(normalizeToolParameters))
        case .object(let source):
            var schema = source.mapValues(normalizeToolParameters)
            schema.removeValue(forKey: "additionalProperties")
            schema.removeValue(forKey: "uniqueItems")
            guard case .array(let declaredTypes)? = source["type"] else {
                return .object(schema)
            }

            let types = declaredTypes.compactMap(\.stringValue)
            let concreteTypes = types.filter { $0 != "null" }
            schema.removeValue(forKey: "type")
            if types.contains("null") {
                schema["nullable"] = .bool(true)
            }
            if concreteTypes.count == 1 {
                schema["type"] = .string(concreteTypes[0])
            } else if !concreteTypes.isEmpty {
                schema["anyOf"] = .array(concreteTypes.map { .object(["type": .string($0)]) })
            }
            return .object(schema)
        default:
            return value
        }
    }

    private func buildUserContent(_ u: UserMessage) throws -> [String: Any] {
        let split = UserMessageParts(u, label: "Gemini.buildUserContent")
        var parts: [[String: Any]] = []
        if !split.text.isEmpty { parts.append(["text": split.text]) }
        for (a, data) in split.media {
            let preparedData: Data
            if a.kind == .pdf {
                preparedData = try PDFPreparer.prepareArtifact(data).data
            } else {
                preparedData = data
            }
            parts.append([
                "inlineData": [
                    "mimeType": a.mimeType,
                    "data": preparedData.base64EncodedString()
                ]
            ])
        }
        if parts.isEmpty { parts = [["text": ""]] }
        return ["role": "user", "parts": parts]
    }

    private func buildAssistantContent(_ a: AssistantMessage) -> [String: Any] {
        var parts: [[String: Any]] = []
        for block in a.content {
            switch block {
            case .text(let content):
                guard !content.text.isEmpty || content.thoughtSignature != nil else { continue }
                var part: [String: Any] = ["text": content.text]
                if let signature = content.thoughtSignature { part["thoughtSignature"] = signature }
                parts.append(part)
            case .thinking(let content):
                guard let signature = content.thoughtSignature else { continue }
                parts.append([
                    "text": content.thinking,
                    "thought": true,
                    "thoughtSignature": signature,
                ])
            case .toolCall(let toolCall):
                var functionCall: [String: Any] = [
                    "name": toolCall.name,
                    "args": toolCall.arguments.toAny(),
                ]
                if let providerCallID = toolCall.providerCallID {
                    functionCall["id"] = providerCallID
                }
                var part: [String: Any] = ["functionCall": functionCall]
                if let signature = toolCall.thoughtSignature, !signature.isEmpty {
                    part["thoughtSignature"] = signature
                }
                parts.append(part)
            case .attachment:
                continue
            }
        }
        if parts.isEmpty { parts = [["text": ""]] }
        return ["role": "model", "parts": parts]
    }

    private func buildToolResultContent(_ r: ToolResultMessage) throws -> [String: Any] {
        let result = ToolResultParts(r, label: "Gemini.buildToolResultContent")
        var payload: [String: Any]
        if r.isError {
            payload = ["error": result.text]
        } else {
            payload = ["output": result.text]
        }
        if result.truncated { payload["truncated"] = true }
        let media = try result.media.map { attachment -> [String: Any] in
            let preparedData: Data
            if attachment.kind == .pdf {
                preparedData = try PDFPreparer.prepareArtifact(attachment.data).data
            } else {
                preparedData = attachment.data
            }
            return [
                "inlineData": [
                    "mimeType": attachment.mimeType,
                    "data": preparedData.base64EncodedString(),
                    "displayName": attachment.displayName,
                ]
            ]
        }
        var response: [String: Any] = [
            "name": r.toolName,
            "response": payload,
        ]
        if let providerCallID = r.providerCallID { response["id"] = providerCallID }
        if !media.isEmpty { response["parts"] = media }
        return [
            "role": "user",
            "parts": [[
                "functionResponse": response
            ]]
        ]
    }

    // MARK: - Explicit context caching

    private static let cacheStore = GeminiCacheStore()
    private static let cacheTTLSeconds: TimeInterval = 3600

    private func cacheFingerprint(
        model: ProviderModel, systemPrompt: String?, tools: [any AgentTool]
    ) -> String {
        let payload: [String: Any] = [
            "model": model.wireID,
            "systemInstruction": buildSystemInstruction(systemPrompt) ?? [:],
            "tools": buildToolDeclarations(tools) ?? []
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resolveCachedContent(
        fingerprint: String, model: ProviderModel, systemPrompt: String?, tools: [any AgentTool]
    ) async -> String? {
        let resolution = await Self.cacheStore.resolve(
            fingerprint,
            ttl: Self.cacheTTLSeconds
        ) {
            do {
                return .success(try await createCachedContent(
                    model: model,
                    systemPrompt: systemPrompt,
                    tools: tools
                ))
            } catch {
                return .failure((error as? GeminiError)?.message ?? error.localizedDescription)
            }
        }
        if resolution.created, let name = resolution.name {
            Log.network.info("Gemini.cache created name=\(name) fp=\(fingerprint.prefix(12))")
        }
        if let error = resolution.error {
            Log.network.warning("Gemini.cache create failed fp=\(fingerprint.prefix(12)) err=\(LogPrivacy.text(error, limit: 2_048)) — proceeding uncached")
        }
        return resolution.name
    }

    private func createCachedContent(
        model: ProviderModel, systemPrompt: String?, tools: [any AgentTool]
    ) async throws -> String {
        var url = config.baseURL
        url.appendPathComponent("cachedContents")

        var body: [String: Any] = [
            "model": "models/\(model.wireID)",
            "ttl": "\(Int(Self.cacheTTLSeconds))s"
        ]
        if let sys = buildSystemInstruction(systemPrompt) { body["systemInstruction"] = sys }
        if let toolDecls = buildToolDeclarations(tools) { body["tools"] = toolDecls }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try resolvedAPIKey(), forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError(message: "cachedContents: no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError(message: Self.apiErrorMessage(data) ?? "cachedContents HTTP \(http.statusCode): \(text)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else {
            throw GeminiError(message: "cachedContents: missing `name` in response")
        }
        return name
    }

}

public struct GeminiError: ProviderClientError {
    public let message: String
    public let failureKind: LLMFailureKind

    public init(message: String, failureKind: LLMFailureKind? = nil) {
        self.message = message
        self.failureKind = failureKind ?? llmFailureKind(message: message)
    }
}

actor GeminiCacheStore {
    enum Creation: Sendable {
        case success(String)
        case failure(String)
    }
    struct Resolution: Sendable {
        let name: String?
        let created: Bool
        let error: String?
    }
    private struct Entry {
        let name: String
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Creation, Never>] = [:]
    private var noCache: Set<String> = []
    private let expiryMargin: TimeInterval = 60

    func resolve(
        _ fingerprint: String,
        ttl: TimeInterval,
        create: @escaping @Sendable () async -> Creation
    ) async -> Resolution {
        if noCache.contains(fingerprint) {
            return Resolution(name: nil, created: false, error: nil)
        }
        if let entry = entries[fingerprint], entry.expiresAt.timeIntervalSinceNow > expiryMargin {
            return Resolution(name: entry.name, created: false, error: nil)
        }
        if entries[fingerprint] != nil {
            entries[fingerprint] = nil
        }
        if let task = pending[fingerprint] {
            return switch await task.value {
            case .success(let name): Resolution(name: name, created: false, error: nil)
            case .failure: Resolution(name: nil, created: false, error: nil)
            }
        }
        let task = Task { await create() }
        pending[fingerprint] = task
        let creation = await task.value
        pending[fingerprint] = nil
        switch creation {
        case .success(let name):
            entries[fingerprint] = Entry(name: name, expiresAt: Date().addingTimeInterval(ttl))
            noCache.remove(fingerprint)
            return Resolution(name: name, created: true, error: nil)
        case .failure(let error):
            entries[fingerprint] = nil
            noCache.insert(fingerprint)
            return Resolution(name: nil, created: false, error: error)
        }
    }

    func invalidate(_ fingerprint: String) {
        entries[fingerprint] = nil
        noCache.remove(fingerprint)
    }
}
