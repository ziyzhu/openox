import Foundation

public struct MockLLMClient: ProviderClient {
    public var scenarios: [String: Scenario]
    public var fallback: Scenario
    public var clock: Clock

    public struct Clock: Sendable {
        public var firstToken: Duration = .milliseconds(150)
        public var betweenDeltas: Duration = .milliseconds(20)
        public var beforeToolCall: Duration = .milliseconds(80)
        public var beforeDone: Duration = .milliseconds(40)
        public var streamCharacters = false
        public init() {}
    }

    public init(
        scenarios: [String: Scenario] = Scenario.defaultLibrary,
        fallback: Scenario = .echo,
        clock: Clock = Clock()
    ) {
        self.scenarios = scenarios
        self.fallback = fallback
        self.clock = clock
    }

    public let id = "mock"
    public let displayName = "Mock"
    public let models = [
        ProviderModel(
            id: "mock",
            displayName: "Mock",
            maxTokens: 8192,
            maxContext: 1_000_000,
            modalities: ProviderModelModalities(input: [.text, .image, .pdf], output: [.text])
        ),
        ProviderModel(
            id: "mock-text-only",
            displayName: "Mock Text Only",
            maxTokens: 8192,
            maxContext: 1_000_000
        ),
    ]
    public let usesAPIKey = false
    public let inferenceLocation: LLMInferenceLocation = .onDevice

    public func prepare(
        model: ProviderModel,
        systemPrompt: String?,
        tools: [any AgentTool]
    ) async -> LLMPreparationOutcome {
        .ready
    }

    public func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        let plan = if systemPrompt?.contains("context summarization assistant") == true {
            (scenario: Scenario.compactionSummary, turn: 0)
        } else {
            self.plan(for: messages)
        }
        let context = TurnContext(
            turn: plan.turn,
            systemPrompt: systemPrompt ?? "",
            messages: messages,
            toolResults: Self.recentToolResults(in: messages)
        )
        let steps = plan.scenario.respond(context)
        let hasTransientContext = messages.contains { message in
            if case .user(let user) = message { return user.transientContext != nil }
            return false
        }
        return streamingTask(model: model, messages: messages) { continuation in
            LogContext.latency?.mark(.requestBodyReady)
            Log.agent.info("MockLLMClient scenario=\(plan.scenario.name) turn=\(plan.turn) steps=\(steps.count) tools=\(tools.count) results=\(context.toolResults.count) transient=\(hasTransientContext)")
            for try await event in Replayer(model: model.id, steps: steps, clock: plan.scenario.clock ?? clock).start() {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func plan(for messages: [Message]) -> (scenario: Scenario, turn: Int) {
        var turn = 0
        for message in messages.reversed() {
            switch message {
            case .assistant:
                turn += 1
            case .user(let u):
                let text = Self.firstText(of: u)
                let intent = Self.intent(in: text)
                if intent.hasPrefix("execute\n") {
                    let source = String(intent.dropFirst("execute\n".count))
                    let scenario = Scenario(name: "execute") { context in
                        context.turn == 0
                            ? [Scenario.execute(source)]
                            : [.say("(mock) Execution finished."), .stop(.stop)]
                    }
                    return (scenario, turn)
                }
                if intent.hasPrefix("reply\n") {
                    return (Scenario(name: "reply", steps: [.say(String(intent.dropFirst("reply\n".count))), .stop(.stop)]), turn)
                }
                if let scenario = scenarios[intent.lowercased()] { return (scenario, turn) }
                if intent.hasPrefix("[system]") { continue }
                return (fallback, turn)
            case .toolResult:
                continue
            }
        }
        return (fallback, 0)
    }

    private static func recentToolResults(in messages: [Message]) -> [ToolResultMessage] {
        var out: [ToolResultMessage] = []
        for message in messages.reversed() {
            switch message {
            case .toolResult(let r): out.append(r)
            case .assistant, .user: return out.reversed()
            }
        }
        return out.reversed()
    }

    private static func firstText(of message: UserMessage) -> String {
        for block in message.content {
            if case .text(let t) = block { return t.text }
        }
        return ""
    }

    private static func intent(in text: String) -> String {
        guard let open = text.range(of: "<intent"),
              let gt = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</intent>", range: gt.upperBound..<text.endIndex)
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text[gt.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TurnContext: Sendable {
    public var turn: Int
    public var systemPrompt: String
    public var messages: [Message]
    public var toolResults: [ToolResultMessage]

    public var serializedUserText: String {
        for message in messages.reversed() {
            if case .user(let user) = message {
                return UserMessageParts(user, label: "MockLLMClient.serializedUserText").text
            }
        }
        return ""
    }

    public func resultText(_ toolName: String? = nil) -> String? {
        resultsText(toolName).last
    }

    public func resultsText(_ toolName: String? = nil) -> [String] {
        let scoped = toolName.map { name in toolResults.filter { $0.toolName == name } } ?? toolResults
        return scoped.compactMap { result in
            for block in result.content {
                if case .text(let t) = block { return t.text }
            }
            return nil
        }
    }

    public var transientContext: String {
        for message in messages.reversed() {
            if case .user(let user) = message {
                return user.transientContext ?? ""
            }
        }
        return ""
    }

    public func latestUserSaid(_ needle: String) -> Bool {
        for message in messages.reversed() {
            guard case .user(let user) = message else { continue }
            return self.user(user, said: needle)
        }
        return false
    }

    public func priorUserContext(containing needle: String) -> String? {
        let users = messages.compactMap { message -> UserMessage? in
            guard case .user(let user) = message else { return nil }
            return user
        }
        for user in users.dropLast().reversed() {
            if self.user(user, said: needle) { return user.transientContext }
        }
        return nil
    }

    public func userSaid(_ needle: String) -> Bool {
        messages.contains { message in
            guard case .user(let user) = message else { return false }
            return self.user(user, said: needle)
        }
    }

    private func user(_ user: UserMessage, said needle: String) -> Bool {
        user.content.contains {
            if case .text(let text) = $0 { return text.text.localizedCaseInsensitiveContains(needle) }
            return false
        }
    }
}

public struct Scenario: Sendable {
    public var name: String
    public var respond: @Sendable (TurnContext) -> [Step]
    public var clock: MockLLMClient.Clock?

    public enum Step: Sendable {
        case think(String)
        case say(String)
        case tool(name: String, args: JSONValue)
        case wait(Duration)
        case usage(input: Int, output: Int)
        case fail(message: String, reason: StopReason)
        case stop(StopReason)
    }

    public init(name: String, respond: @escaping @Sendable (TurnContext) -> [Step]) {
        self.name = name
        self.respond = respond
    }

    public init(name: String, steps: [Step]) {
        self.init(name: name) { _ in steps }
    }

    func pacing(betweenDeltas: Duration) -> Scenario {
        var scenario = self
        var clock = MockLLMClient.Clock()
        clock.betweenDeltas = betweenDeltas
        scenario.clock = clock
        return scenario
    }

    func characterStreaming() -> Scenario {
        var scenario = self
        var clock = scenario.clock ?? MockLLMClient.Clock()
        clock.streamCharacters = true
        scenario.clock = clock
        return scenario
    }
}

extension Scenario {
    struct Entry {
        let number: String
        let label: String
        let scenario: Scenario
        init(_ number: String, _ label: String, _ scenario: Scenario) {
            self.number = number; self.label = label; self.scenario = scenario
        }
    }

    static let catalog: [(group: String, entries: [Entry])] = [
        ("Core & edges", [
            Entry("0", "empty — instant stop, no content", .empty),
            Entry("1", "long — one very long message", .longOutput),
            Entry("2", "slow — 3s before the first token", .slowFirstToken),
            Entry("3", "truncated — stops at the token ceiling", .truncated),
            Entry("4", "error — fails mid-stream", .errorMidstream),
        ]),
        ("Text & streaming", [
            Entry("10", "markdown — full markdown", .markdown),
            Entry("11", "cjk — CJK + emoji + tables", .cjk),
            Entry("12", "thinking — reason, then answer", .thinkingOnly),
            Entry("13", "thinkslow — live thinking row (~8s)", .slowThinking),
            Entry("14", "interleave — alternating think/say", .interleaved),
            Entry("17", "faststream — CI-speed fade demo", .fastStream),
            Entry("18", "selectcode — selectable code while streaming", .selectableCodeStream),
            Entry("19", "background — stream after the reader scrolls away", .backgroundStream),
            Entry("21", "focusstream — stream while the composer is focused", .focusedStream),
            Entry("97", "characterstream — partial words near a line break", .characterStream),
        ]),
        ("Tool loops & interaction", [
            Entry("22", "parallel — two reads, synthesize", .parallelTools),
            Entry("23", "model selection — stage a switch (23 error fails)", .modelSelectionChange),
            Entry("24", "choice — yes/no gate (branches)", .binaryChoiceFlow),
            Entry("25", "choice — pick-one gate (branches)", .choiceFlow),
            Entry("26", "virtual machine cancel — stop pending JavaScript", .virtualMachineCancellation),
            Entry("27", "truncated tool — reject incomplete arguments", .truncatedToolCall),
            Entry("28", "pending stop — reject missing terminal reason", .pendingStopReason),
            Entry("29", "compaction — estimate, isolate, and summarize", .compaction),
        ]),
        ("Files & handoffs", [
            Entry("30", "chart — inline JavaScript", .htmlChart),
            Entry("31", "diagrams — Mermaid block and SVG file", .diagrams),
            Entry("50", "signin — auth card → resume after sign-in", .signin),
            Entry("53", "recover — tool error, then fall back", .recover),
            Entry("58", "files — write, edit, rename, and display", .fileWorkflow),
            Entry("69", "solve — human-verification handoff", .botControl),
            Entry("74", "progress — report, continue thinking, then answer", .progressReport),
            Entry("75", "embeds — file and remote image", .embeds),
            Entry("76", "video — embed inline file video", .video),
            Entry("77", "payment — user-controlled checkout", .payment),
        ]),
        ("Context & diagnostics", [
            Entry("66", "final context — defer compaction until another request", .deferredCompaction),
            Entry("67", "overflow recovery — compact and retry once", .overflowRecovery),
            Entry("68", "overflow failure — stop after one retry", .overflowFailure),
            Entry("71", "rate limit — normalize provider quota errors", .rateLimited),
            Entry("72", "prompt context — unified skills and current service and file state", .skillCatalog),
            Entry("73", "memory — freeze prompt context and read updates on demand", .memoryOnDemand),
            Entry("78", "URL context — annotate user and tool URLs with related services", .urlServiceContext),
            Entry("80", "app information — read app identity and current model", .appInformation),
            Entry("90", "app logs — approve or deny diagnostic access", .appLogs),
        ]),
    ]

    public static var defaultLibrary: [String: Scenario] {
        var library = Dictionary(uniqueKeysWithValues: catalog.flatMap(\.entries).map { ($0.number, $0.scenario) })
        library["23 defaults"] = defaultModelSelection
        library["23 error"] = modelSelectionChange
        library["72 bundled"] = skillCatalog
        library[String(repeating: "slow ", count: 200).trimmingCharacters(in: .whitespaces)] = slowFirstToken
        return library
    }

    static var menuText: String {
        var lines = ["(mock) Type a number to run a scenario:\n"]
        for group in catalog {
            lines.append("**\(group.group)**")
            for entry in group.entries { lines.append("- `\(entry.number)` \(entry.label)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static var echo: Scenario { Scenario(name: "echo", steps: [.say(menuText), .stop(.stop)]) }

    static func execute(_ source: String) -> Step {
        .tool(name: "execute", args: .object(["purpose": .string("Run Mock scenario"), "source": .string(source)]))
    }
}

nonisolated private final class Replayer: @unchecked Sendable {
    let model: String
    let steps: [Scenario.Step]
    let clock: MockLLMClient.Clock

    init(model: String, steps: [Scenario.Step], clock: MockLLMClient.Clock) {
        self.model = model
        self.steps = steps
        self.clock = clock
    }

    func start() -> AsyncThrowingStream<AssistantEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [model, steps, clock] in
                var partial = AssistantMessage(model: model)
                continuation.yield(.start(partial: partial))
                try? await Task.sleep(for: clock.firstToken)

                var toolSeq = 0
                var stopReason: StopReason = .pending
                var explicitUsage: Usage?

                for step in steps {
                    if Task.isCancelled { break }
                    switch step {
                    case .think(let s):
                        let idx = partial.content.count
                        partial.content.append(.thinking(ThinkingContent("")))
                        await Replayer.streamText(
                            s, into: &partial, idx: idx,
                            isThinking: true, clock: clock,
                            continuation: continuation
                        )
                        continuation.yield(.thinkingEnd(index: idx, partial: partial))

                    case .say(let s):
                        let idx = partial.content.count
                        partial.content.append(.text(TextContent("")))
                        await Replayer.streamText(
                            s, into: &partial, idx: idx,
                            isThinking: false, clock: clock,
                            continuation: continuation
                        )
                        continuation.yield(.textEnd(index: idx, partial: partial))

                    case .tool(let name, let args):
                        try? await Task.sleep(for: clock.beforeToolCall)
                        toolSeq += 1
                        let call = ToolCall(id: "mock-\(toolSeq)", name: name, arguments: args)
                        let idx = partial.content.count
                        partial.content.append(.toolCall(call))
                        continuation.yield(.toolCallDelta(index: idx, partial: partial))
                        continuation.yield(.toolCallEnd(index: idx, toolCall: call, partial: partial))
                        stopReason = .toolUse

                    case .wait(let d):
                        try? await Task.sleep(for: d)

                    case .usage(let input, let output):
                        var usage = Usage()
                        usage.input = input
                        usage.output = output
                        usage.totalTokens = input + output
                        explicitUsage = usage

                    case .stop(let r):
                        stopReason = r

                    case .fail(let msg, let reason):
                        var err = partial
                        err.stopReason = reason
                        err.errorMessage = msg
                        err.failureKind = llmFailureKind(message: msg)
                        continuation.yield(.failed(reason: reason, error: err))
                        continuation.finish()
                        return
                    }
                }

                try? await Task.sleep(for: clock.beforeDone)
                if stopReason == .pending {
                    partial.stopReason = .error
                    partial.errorMessage = "mock scenario ended without a stop reason"
                    partial.failureKind = .provider
                    continuation.yield(.failed(reason: .error, error: partial))
                    continuation.finish()
                    return
                }
                if let explicitUsage {
                    partial.usage = explicitUsage
                } else {
                    partial.usage.output = partial.content.reduce(0) { count, block in
                        switch block {
                        case .text(let text): count + text.text.split(whereSeparator: \.isWhitespace).count
                        case .thinking(let content): count + content.thinking.split(whereSeparator: \.isWhitespace).count
                        case .toolCall, .attachment: count
                        }
                    }
                    partial.usage.totalTokens = partial.usage.output
                }
                partial.stopReason = stopReason
                continuation.yield(.done(reason: stopReason, message: partial))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamText(
        _ s: String,
        into partial: inout AssistantMessage,
        idx: Int,
        isThinking: Bool,
        clock: MockLLMClient.Clock,
        continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async {
        for chunk in clock.streamCharacters ? s.map(String.init) : s.tokenizedForStreaming() {
            if Task.isCancelled { return }
            switch partial.content[idx] {
            case .text(var t):
                t.text += chunk
                partial.content[idx] = .text(t)
            case .thinking(var content):
                content.thinking += chunk
                partial.content[idx] = .thinking(content)
            default:
                break
            }
            if isThinking {
                continuation.yield(.thinkingDelta(index: idx, delta: chunk, partial: partial))
            } else {
                continuation.yield(.textDelta(index: idx, delta: chunk, partial: partial))
            }
            try? await Task.sleep(for: clock.betweenDeltas)
        }
    }
}

nonisolated private extension String {
    func tokenizedForStreaming() -> [String] {
        var out: [String] = []
        var buf = ""
        for ch in self {
            buf.append(ch)
            if ch.isWhitespace {
                out.append(buf)
                buf = ""
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }
}
