import Foundation

nonisolated enum StreamingHTTP {
    nonisolated struct Response {
        let http: HTTPURLResponse
        let bytes: URLSession.AsyncBytes
        let label: String

        var statusCode: Int { http.statusCode }

        func errorBody() async throws -> (data: Data, text: String) {
            let limit = 64 * 1024
            var data = Data()
            data.reserveCapacity(limit)
            var truncated = false
            for try await byte in bytes {
                if data.count == limit {
                    truncated = true
                    break
                }
                data.append(byte)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return (data, truncated ? body + "…" : body)
        }

        func requireSuccess(_ makeError: (Data, String) -> any Error) async throws {
            guard !(200..<300).contains(statusCode) else { return }
            let body = try await errorBody()
            Log.network.error("\(label) HTTP \(statusCode): \(LogPrivacy.text(body.text, limit: 2_048))")
            throw makeError(body.data, body.text)
        }
    }

    static func open(
        _ request: URLRequest,
        label: String,
        noHTTPError: () -> any Error
    ) async throws -> Response {
        LogContext.latency?.mark(.httpStarted)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        LogContext.latency?.mark(.responseHeaders)
        guard let http = response as? HTTPURLResponse else {
            Log.network.error("\(label) non-HTTP response")
            throw noHTTPError()
        }
        let diagnostics = responseDiagnostics(http)
        Log.network.info("\(label) response status=\(http.statusCode)\(diagnostics.isEmpty ? "" : " \(diagnostics)")")
        return Response(http: http, bytes: bytes, label: label)
    }

    private static func responseDiagnostics(_ response: HTTPURLResponse) -> String {
        let fields: [(String, [String])] = [
            ("requestId", ["x-request-id", "request-id", "x-goog-request-id"]),
            ("generationId", ["x-generation-id"]),
            ("trace", ["traceparent", "cf-ray"]),
            ("retryAfter", ["retry-after"]),
            ("rateLimitRemainingRequests", ["x-ratelimit-remaining-requests", "ratelimit-remaining"]),
            ("rateLimitResetRequests", ["x-ratelimit-reset-requests", "ratelimit-reset"]),
            ("rateLimitRemainingTokens", ["x-ratelimit-remaining-tokens"]),
            ("rateLimitResetTokens", ["x-ratelimit-reset-tokens"]),
        ]
        return fields.compactMap { label, headerNames in
            guard let value = headerNames.lazy.compactMap({ response.value(forHTTPHeaderField: $0) }).first else {
                return nil
            }
            return "\(label)=\(LogPrivacy.text(value, limit: 128))"
        }.joined(separator: " ")
    }
}

nonisolated enum SSE {
    // Iterates "data:" lines, parses each JSON payload, and hands it to body.
    // Handles the "[DONE]" sentinel and skips malformed chunks with a warning.
    // body returns false to stop early. Returns the number of lines consumed.
    static func forEachDataChunk(
        _ bytes: URLSession.AsyncBytes,
        label: String,
        _ body: ([String: Any]) throws -> Bool
    ) async throws -> Int {
        var lineCount = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" {
                Log.network.info("\(label) [DONE] lines=\(lineCount)")
                break
            }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Log.network.warning("\(label) skipped non-JSON SSE chunk chars=\(payload.count) data=\(LogPrivacy.text(payload, limit: 200))")
                continue
            }
            if try !body(chunk) { break }
        }
        return lineCount
    }
}

// Accumulates streamed deltas into an AssistantMessage and emits the
// matching AssistantEvents, so clients only translate provider JSON.
nonisolated struct StreamAssembler {
    private(set) var message: AssistantMessage
    private let continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    private var emittedStart = false
    private var textIndex: Int?
    private var thinkingIndex: Int?
    private let startedAt = Date()
    private var firstTokenAt: Date?

    init(model: ProviderModel, continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation) {
        self.message = AssistantMessage(model: model.id)
        self.continuation = continuation
    }

    mutating func start() {
        guard !emittedStart else { return }
        emittedStart = true
        continuation.yield(.start(partial: message))
    }

    private mutating func markFirstToken() {
        if firstTokenAt == nil { firstTokenAt = Date() }
    }

    mutating func textDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        markFirstToken()
        endThinking()
        if textIndex == nil {
            textIndex = message.content.count
            message.content.append(.text(TextContent("")))
        }
        if case .text(let cur) = message.content[textIndex!] {
            message.content[textIndex!] = .text(TextContent(cur.text + delta))
        }
        continuation.yield(.textDelta(index: textIndex!, delta: delta, partial: message))
    }

    // Some models (e.g. qwen via OpenRouter) stream reasoning after content has
    // already begun. Emitting those deltas live would interleave a thinking block
    // into the middle of streamed text downstream, so late reasoning is buffered
    // silently and merged into the leading thinking block at finish.
    private var lateThinking = ""
    private var hasNonThinkingContent: Bool {
        message.content.contains { if case .thinking = $0 { return false } else { return true } }
    }

    mutating func thinkingDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        markFirstToken()
        if thinkingIndex == nil, hasNonThinkingContent {
            lateThinking += delta
            return
        }
        if thinkingIndex == nil {
            thinkingIndex = message.content.count
            message.content.append(.thinking(ThinkingContent("")))
        }
        if case .thinking(var content) = message.content[thinkingIndex!] {
            content.thinking += delta
            message.content[thinkingIndex!] = .thinking(content)
        }
        continuation.yield(.thinkingDelta(index: thinkingIndex!, delta: delta, partial: message))
    }

    mutating func completeTextPart(_ text: String, thoughtSignature: String) {
        endThinking()
        endText()
        markFirstToken()
        let index = message.content.count
        message.content.append(.text(TextContent(text, thoughtSignature: thoughtSignature)))
        if !text.isEmpty {
            continuation.yield(.textDelta(index: index, delta: text, partial: message))
        }
        continuation.yield(.textEnd(index: index, partial: message))
    }

    mutating func completeThinkingPart(_ text: String, thoughtSignature: String) {
        endThinking()
        endText()
        markFirstToken()
        let index = message.content.count
        message.content.append(.thinking(ThinkingContent(text, thoughtSignature: thoughtSignature)))
        if !text.isEmpty {
            continuation.yield(.thinkingDelta(index: index, delta: text, partial: message))
        }
        continuation.yield(.thinkingEnd(index: index, partial: message))
    }

    mutating func endThinking() {
        guard let ti = thinkingIndex else { return }
        continuation.yield(.thinkingEnd(index: ti, partial: message))
        thinkingIndex = nil
    }

    mutating func endText() {
        guard let xi = textIndex else { return }
        continuation.yield(.textEnd(index: xi, partial: message))
        textIndex = nil
    }

    mutating func startTextItem() -> Int {
        endThinking()
        endText()
        let index = message.content.count
        message.content.append(.text(TextContent("")))
        textIndex = index
        return index
    }

    mutating func startReasoningItem() -> Int {
        endThinking()
        endText()
        let index = message.content.count
        message.content.append(.thinking(ThinkingContent("")))
        thinkingIndex = index
        return index
    }

    // The call arrives complete in a single chunk (Gemini style).
    mutating func completeToolCall(_ call: ToolCall) {
        markFirstToken()
        endThinking()
        let idx = message.content.count
        message.content.append(.toolCall(call))
        continuation.yield(.toolCallDelta(index: idx, partial: message))
        continuation.yield(.toolCallEnd(index: idx, toolCall: call, partial: message))
    }

    // The call accretes across chunks (OpenAI style): open a slot, update it
    // as fragments arrive, then close it once the stream ends.
    mutating func openToolCall() -> Int {
        let idx = message.content.count
        message.content.append(.toolCall(ToolCall(id: "", name: "", arguments: .object([:]))))
        return idx
    }

    mutating func updateToolCall(at idx: Int, _ call: ToolCall) {
        markFirstToken()
        message.content[idx] = .toolCall(call)
        continuation.yield(.toolCallDelta(index: idx, partial: message))
    }

    mutating func endToolCall(at idx: Int, _ call: ToolCall) {
        markFirstToken()
        message.content[idx] = .toolCall(call)
        continuation.yield(.toolCallEnd(index: idx, toolCall: call, partial: message))
    }

    mutating func setUsage(_ usage: Usage) {
        message.usage = usage
    }

    mutating func setResponseID(_ responseID: String?) {
        if let responseID, !responseID.isEmpty { message.responseID = responseID }
    }

    mutating func setRawStopReason(_ rawStopReason: String?) {
        message.rawStopReason = rawStopReason
    }

    mutating func setThinkingSignature(_ signature: String, at index: Int) {
        guard message.content.indices.contains(index), case .thinking(var content) = message.content[index] else { return }
        content.thinkingSignature = signature
        message.content[index] = .thinking(content)
    }

    mutating func setTextItem(id: String, phase: String?, text: String?, at preferredIndex: Int? = nil) {
        let existingIndex = preferredIndex ?? message.content.lastIndex(where: {
            if case .text = $0 { return true }
            return false
        })
        let index: Int
        var content: TextContent
        if let existingIndex, case .text(let existing) = message.content[existingIndex] {
            index = existingIndex
            content = existing
        } else {
            index = message.content.count
            content = TextContent("")
            message.content.append(.text(content))
        }
        if let text, !text.isEmpty { content.text = text }
        var signature: [String: Any] = ["v": 1, "id": id]
        if let phase, phase == "commentary" || phase == "final_answer" { signature["phase"] = phase }
        if let data = try? JSONSerialization.data(withJSONObject: signature, options: [.sortedKeys]) {
            content.textSignature = String(data: data, encoding: .utf8)
        }
        message.content[index] = .text(content)
        if textIndex == index { endText() }
    }

    mutating func setReasoningItem(_ item: [String: Any], at preferredIndex: Int? = nil) {
        guard let id = item["id"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]),
              let signature = String(data: data, encoding: .utf8)
        else { return }
        let matching = message.content.lastIndex { block in
            guard case .thinking(let content) = block,
                  let existing = content.thinkingSignature,
                  let data = existing.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return object["id"] as? String == id
        }
        let fallback = message.content.lastIndex { block in
            if case .thinking = block { return true }
            return false
        }
        let summary = (item["summary"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        let raw = (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        let replacement = [summary, raw].compactMap({ $0 }).first(where: { !$0.isEmpty })
        guard let index = preferredIndex ?? matching ?? fallback else {
            message.content.append(.thinking(ThinkingContent(replacement ?? "", thinkingSignature: signature)))
            return
        }
        guard case .thinking(var content) = message.content[index] else { return }
        if let replacement {
            content.thinking = replacement
        }
        content.thinkingSignature = signature
        message.content[index] = .thinking(content)
        if thinkingIndex == index { endThinking() }
    }

    var hasToolCalls: Bool {
        message.content.contains { if case .toolCall = $0 { return true } else { return false } }
    }

    mutating func fail(_ errorMessage: String, kind: LLMFailureKind? = nil) {
        start()
        endThinking()
        message.stopReason = .error
        message.errorMessage = errorMessage
        message.failureKind = kind ?? llmFailureKind(message: errorMessage)
        continuation.yield(.failed(reason: .error, error: message))
        continuation.finish()
    }

    // Some models (e.g. qwen via OpenRouter) stream reasoning after content,
    // so thinking blocks can land out of order. Merge them into one block at
    // the front, where a turn's reasoning belongs.
    private mutating func hoistThinking(label: String) {
        let thinkingPositions = message.content.indices.filter {
            if case .thinking = message.content[$0] { return true } else { return false }
        }
        guard !thinkingPositions.isEmpty, thinkingPositions != [0] else { return }
        var thinking = ""
        var thinkingSignature: String?
        var rest: [ContentBlock] = []
        for block in message.content {
            if case .thinking(let content) = block {
                thinking += content.thinking
                thinkingSignature = content.thinkingSignature ?? thinkingSignature
            } else {
                rest.append(block)
            }
        }
        rest.insert(.thinking(ThinkingContent(thinking, thinkingSignature: thinkingSignature)), at: 0)
        message.content = rest
        Log.network.info("\(label) hoisted thinking from \(thinkingPositions) to [0] ahead of \(rest.count - 1) block(s)")
    }

    mutating func finish(reason: StopReason, label: String, lines: Int) {
        guard reason != .pending else {
            fail("stream ended without a provider stop reason")
            return
        }
        endThinking()
        endText()
        if !lateThinking.isEmpty {
            Log.network.info("\(label) buffered \(lateThinking.count) chars of late reasoning behind content; merging at front")
            message.content.append(.thinking(ThinkingContent(lateThinking)))
            lateThinking = ""
        }
        start()
        hoistThinking(label: label)
        let reason: StopReason = (reason == .stop && hasToolCalls) ? .toolUse : reason
        message.stopReason = reason
        let u = message.usage
        let hitRate = u.input > 0 ? Int(Double(u.cachedInput) / Double(u.input) * 100) : 0
        let cacheWrite = u.cacheWriteInput.map(String.init) ?? "n/a"
        let now = Date()
        let ttft = firstTokenAt.map { "\(Int($0.timeIntervalSince(startedAt) * 1000))ms" } ?? "n/a"
        let decodeSecs = now.timeIntervalSince(firstTokenAt ?? startedAt)
        let tps = decodeSecs > 0 ? String(format: "%.1f", Double(u.output) / decodeSecs) : "n/a"
        Log.network.info("\(label) done responseId=\(LogPrivacy.text(message.responseID ?? "none", limit: 128)) reason=\(reason) rawReason=\(LogPrivacy.text(message.rawStopReason ?? "none", limit: 128)) lines=\(lines) blocks=\(message.content.count) seq=[\(message.content.blockKinds)] tokens=\(u.totalTokens) input=\(u.input) cached=\(u.cachedInput) (\(hitRate)%) cacheWrite=\(cacheWrite) output=\(u.output) ttft=\(ttft) tok/s=\(tps)")
        continuation.yield(.done(reason: reason, message: message))
        continuation.finish()
    }
}

// Splits a UserMessage into provider-neutral parts: all text (with text-file
// attachments inlined as fenced code blocks) plus loaded binary attachments.
nonisolated struct UserMessageParts {
    let text: String
    let media: [(attachment: Artifact, data: Data)]

    init(_ u: UserMessage, label: String) {
        var textParts: [String] = []
        if let transientContext = u.transientContext, !transientContext.isEmpty {
            textParts.append(transientContext)
        }
        var media: [(Artifact, Data)] = []
        for block in u.content {
            switch block {
            case .text(let t):
                if !t.text.isEmpty { textParts.append(t.text) }
            case .attachment(let a):
                textParts.append(ArtifactPromptReference.text(for: a))
                switch a.kind {
                case .text, .html:
                    if let raw = try? String(contentsOf: a.fileURL, encoding: .utf8) {
                        let lang = Self.languageHint(for: a.fileURL.pathExtension)
                        textParts.append("```\(lang) filename=\(a.displayName)\n\(raw)\n```")
                    } else {
                        Log.network.error("\(label): failed to read text attachment \(a.fileURL.lastPathComponent)")
                    }
                case .image, .pdf:
                    if let data = try? Data(contentsOf: a.fileURL) {
                        media.append((a, data))
                    } else {
                        Log.network.error("\(label): failed to read \(a.kind.rawValue) attachment \(a.fileURL.lastPathComponent)")
                    }
                case .file:
                    Log.network.error("\(label): unsupported attachment \(a.fileURL.lastPathComponent)")
                }
            default:
                continue
            }
        }
        let body = textParts.joined(separator: "\n\n")
        let prefix = Self.timestampPrefix(for: u.timestamp)
        self.text = body.isEmpty ? prefix : "\(prefix)\n\n\(body)"
        self.media = media
    }

    private static func timestampPrefix(for date: Date) -> String {
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.weekday, .year, .month, .day, .hour, .minute], from: date)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekday = components.weekday.flatMap { weekdays.indices.contains($0 - 1) ? weekdays[$0 - 1] : nil } ?? "???"
        return String(
            format: "[%@ %04d-%02d-%02d %02d:%02d %@]",
            weekday,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            timeZone.identifier
        )
    }

    static func languageHint(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "ts", "tsx": return "ts"
        case "js", "jsx", "mjs", "cjs": return "js"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "hpp": return "cpp"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "md", "markdown": return "md"
        case "sh", "bash", "zsh": return "bash"
        case "html": return "html"
        case "css": return "css"
        case "csv": return "csv"
        case "sql": return "sql"
        default: return ext.lowercased()
        }
    }
}

nonisolated struct ToolResultParts {
    let text: String
    let truncated: Bool
    let media: [TransientAttachment]

    init(_ result: ToolResultMessage, label: String) {
        let artifactReferences = result.content.compactMap { block -> String? in
            guard case .attachment(let artifact) = block else { return nil }
            return ArtifactPromptReference.text(for: artifact)
        }
        let sourceText = [result.content.concatenatedText, artifactReferences.joined(separator: "\n\n")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        text = sourceText
        truncated = result.truncated == true
        var attachments = result.content.reduce(into: [TransientAttachment]()) { media, block in
            guard case .attachment(let attachment) = block,
                  attachment.kind == .image || attachment.kind == .pdf,
                  !media.contains(where: {
                      $0.displayName.caseInsensitiveCompare(attachment.fileName) == .orderedSame
                  }) else { return }
            guard let data = try? Data(contentsOf: attachment.fileURL) else {
                Log.network.error("\(label): failed to read \(attachment.kind.rawValue) tool result \(attachment.fileURL.lastPathComponent)")
                return
            }
            media.append(TransientAttachment(
                kind: attachment.kind == .image ? .image : .pdf,
                mimeType: attachment.mimeType,
                displayName: attachment.displayName,
                data: data
            ))
        }
        attachments.append(contentsOf: result.transientAttachments)
        media = attachments
        let mediaBytes = media.reduce(0) { $0 + $1.data.count }
        Log.network.info("\(label): model input tool=\(result.toolName) id=\(result.toolCallId) textChars=\(text.count) truncated=\(truncated) media=\(media.count) mediaBytes=\(mediaBytes)")
    }
}

nonisolated extension Array where Element == ContentBlock {
    var concatenatedText: String {
        reduce(into: "") { if case .text(let t) = $1 { $0 += t.text } }
    }

    var concatenatedThinking: String {
        reduce(into: "") { if case .thinking(let t) = $1 { $0 += t.thinking } }
    }

    var toolCalls: [ToolCall] {
        compactMap { if case .toolCall(let tc) = $0 { return tc } else { return nil } }
    }

    var blockKinds: String {
        map {
            switch $0 {
            case .text: return "text"
            case .thinking: return "think"
            case .attachment: return "attach"
            case .toolCall(let c): return "tool(\(c.name))"
            }
        }.joined(separator: ",")
    }
}

nonisolated func requiredInputModalities(in messages: [Message]) -> Set<ProviderModelModality> {
    var modalities: Set<ProviderModelModality> = [.text]

    func include(_ artifact: Artifact) {
        switch artifact.kind {
        case .image: modalities.insert(.image)
        case .pdf: modalities.insert(.pdf)
        case .text, .html, .file: break
        }
    }

    func include(_ attachment: TransientAttachment) {
        switch attachment.kind {
        case .image: modalities.insert(.image)
        case .pdf: modalities.insert(.pdf)
        case .text, .file: break
        }
    }

    for message in messages {
        switch message {
        case .user(let user):
            for block in user.content {
                if case .attachment(let artifact) = block { include(artifact) }
            }
        case .toolResult(let result):
            for block in result.content {
                if case .attachment(let artifact) = block { include(artifact) }
            }
            result.transientAttachments.forEach(include)
        case .assistant:
            break
        }
    }
    return modalities
}

nonisolated struct UnsupportedModelInputError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind = .unsupportedInput
}

nonisolated func modelInputCompatibilityError(
    messages: [Message],
    model: ProviderModel
) -> UnsupportedModelInputError? {
    let unsupported = requiredInputModalities(in: messages)
        .subtracting(model.modalities.input)
        .sorted { $0.rawValue < $1.rawValue }
    guard !unsupported.isEmpty else { return nil }
    let labels = unsupported.map { $0 == .pdf ? "PDF" : $0.rawValue }
    let description = ListFormatter.localizedString(byJoining: labels)
    return UnsupportedModelInputError(
        message: "\(model.displayName) doesn't support \(description) input. Switch to a compatible model or remove those attachments."
    )
}

nonisolated extension Array where Element == Message {
    var wireSignature: String {
        enumerated().map { i, m in
            switch m {
            case .user: return "\(i):user"
            case .assistant(let a): return "\(i):assistant[\(a.content.blockKinds)]"
            case .toolResult(let r): return "\(i):result(\(r.toolName)\(r.isError ? "!" : ""))"
            }
        }.joined(separator: " ")
    }
}

nonisolated extension AgentTool {
    var declarationJSON: [String: Any] {
        ["name": name, "description": description, "parameters": parameters.toAny()]
    }
}
