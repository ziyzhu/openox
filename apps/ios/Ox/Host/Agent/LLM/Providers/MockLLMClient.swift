import Foundation

public struct MockLLMClient: LLMClient {
    public var scenarios: [String: Scenario]
    public var fallback: Scenario
    public var clock: Clock

    public struct Clock: Sendable {
        public var firstToken: Duration = .milliseconds(150)
        public var betweenDeltas: Duration = .milliseconds(20)
        public var beforeToolCall: Duration = .milliseconds(80)
        public var beforeDone: Duration = .milliseconds(40)
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

    public static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        return !SimEnv.mockLLMDisabled
        #else
        return false
        #endif
    }

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
        let plan = if systemPrompt?.contains("context compression assistant") == true {
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

    // The active scenario is the most recent user message whose intent is a known key.
    // System events (an injected `[system] …` turn, e.g. a sign-in completing) are
    // transparent — we scan past them so a multi-turn scenario stays anchored across
    // an out-of-band turn — but a real, unrecognized user message falls back to the menu.
    private func plan(for messages: [Message]) -> (scenario: Scenario, turn: Int) {
        var turn = 0
        for message in messages.reversed() {
            switch message {
            case .assistant:
                turn += 1
            case .user(let u):
                let text = Self.firstText(of: u)
                let intent = Self.intent(in: text)
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
            Entry("15", "slowstream — reading-speed text (fade demo)", .slowStream),
            Entry("16", "links — labels stream while destinations stay hidden", .links),
            Entry("17", "faststream — CI-speed fade demo", .fastStream),
            Entry("18", "selectcode — selectable code while streaming", .selectableCodeStream),
            Entry("19", "background — stream after the reader scrolls away", .backgroundStream),
            Entry("20", "clearance — response near the focused composer", .composerClearance),
            Entry("21", "focusstream — stream while the composer is focused", .focusedStream),
            Entry("79", "formatstress — long single-block formatted stream", .formattedStreamStress),
        ]),
        ("Tool loops & interaction", [
            Entry("22", "parallel — two reads, synthesize", .parallelTools),
            Entry("24", "choice — yes/no gate (branches)", .binaryChoiceFlow),
            Entry("25", "choice — pick-one gate (branches)", .choiceFlow),
            Entry("26", "virtual machine cancel — stop pending JavaScript", .virtualMachineCancellation),
            Entry("27", "truncated tool — reject incomplete arguments", .truncatedToolCall),
            Entry("28", "pending stop — reject missing terminal reason", .pendingStopReason),
            Entry("29", "compaction — estimate, isolate, and summarize", .compaction),
        ]),
        ("HTML artifacts", [
            Entry("30", "chart — inline JavaScript", .htmlChart),
            Entry("31", "video — sibling media", .htmlVideo),
            Entry("32", "audio — sibling media", .htmlAudio),
            Entry("33", "map — native snapshot", .htmlMap),
        ]),
        ("End-to-end", [
            Entry("50", "signin — auth card → resume after sign-in", .signin),
            Entry("53", "recover — tool error, then fall back", .recover),
            Entry("58", "artifact — write, edit, rename, and present", .artifactWorkflow),
            Entry("59", "skills — create, copy, edit, and delete a user skill", .skillWorkflow),
            Entry("60", "budget — truncate oversized tool output", .toolResultBudget),
            Entry("61", "web fetch — HTTP responses plus explicit attachments", .webFetch),
            Entry("62", "web import — explicitly persist an HTTP response", .webImport),
            Entry("63", "html update — revise and redisplay", .htmlUpdate),
            Entry("65", "fail-fast — settle a late service invocation", .failFastInvocation),
            Entry("66", "settled compaction — compact after the final response", .settledCompaction),
            Entry("67", "overflow recovery — compact and retry once", .overflowRecovery),
            Entry("68", "overflow failure — stop after one retry", .overflowFailure),
            Entry("69", "solve — human-verification handoff", .botControl),
            Entry("70", "helper schemas — callable help and service inspection", .help),
            Entry("71", "rate limit — normalize provider quota errors", .rateLimited),
            Entry("72", "prompt context — stable system skills and transient service state", .skillCatalog),
            Entry("73", "memory — read durable context on demand", .memoryOnDemand),
            Entry("74", "progress — report, continue thinking, then answer", .progressReport),
            Entry("75", "shoveler — display non-interactive cards", .shoveler),
            Entry("76", "video — display inline artifact video", .video),
            Entry("77", "payment — user-controlled checkout", .payment),
            Entry("78", "URL context — annotate user and tool URLs with related services", .urlServiceContext),
            Entry("80", "app information — read settings and filter logs without secrets", .appInformation),
            Entry("81", "chat title — update agent titles", .chatTitle),
            Entry("82", "local service — create and edit Local source", .localServiceWorkflow),
            Entry("83", "local copy — copy and validate Local source", .localCopyWorkflow),
            Entry("84", "local history — commit, time travel, restore, and revert", .localHistoryWorkflow),
            Entry("85", "local history recovery — restore and revert pending test state", .localHistoryRecovery),
            Entry("86", "local diff — review working and committed changes", .localDiffWorkflow),
            Entry("87", "local delete — delete and restore a Local service", .localDeleteWorkflow),
            Entry("88", "system skill references — list and read progressive guidance", .systemSkillReferences),
            Entry("89", "browser screenshot — navigate and attach viewport image", .browserScreenshot),
            Entry("90", "app logs — approve or deny diagnostic access", .appLogs),
        ]),
    ]

    public static var defaultLibrary: [String: Scenario] {
        var library = Dictionary(uniqueKeysWithValues: catalog.flatMap(\.entries).map { ($0.number, $0.scenario) })
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

    static let browserScreenshot = Scenario(name: "browserScreenshot") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            const matches = await ox.service.find({ query: "browser screenshot", purpose: "Find Browser" });
            const browser = matches.find((service) => service.domain === "ios:browser");
            if (!browser) throw new Error("Browser service not found");
            await ox.fs.read({ path: browser.manifestPath, purpose: "Read Browser manifest" });
            await ox.service.attach({ domain: browser.domain, purpose: "Attach Browser" });
            console.log(await ox.service.inspect({ domain: browser.domain, actions: ["navigate", "screenshot"], purpose: "Inspect Browser actions" }));
            """)]
        }
        guard let output = ctx.resultText("execute") else {
            return [.say("Browser setup did not return an action contract."), .stop(.stop)]
        }
        if ctx.turn == 1 {
            return [execute("""
            await ox.service.invoke({ name: "ios:browser:navigate", input: { url: "https://example.com" }, purpose: "Open screenshot fixture" });
            console.log(await ox.service.invoke({ name: "ios:browser:screenshot", input: {}, purpose: "Capture browser viewport" }));
            """)]
        }
        let attachments = ctx.toolResults.last?.transientAttachments ?? []
        guard attachments.count == 1, attachments[0].kind == .image else {
            return [.say("Browser screenshot was not attached to model context."), .stop(.stop)]
        }
        return [.say("Browser screenshot attached to model context: \(attachments[0].mimeType), \(attachments[0].data.count) bytes. Result: \(output)"), .stop(.stop)]
    }

    static let markdown = Scenario(name: "markdown", steps: [
        .say("""
        # Mock markdown

        Paragraph with **bold**, *italic*, and `inline code`.

        - bullet one
        - bullet two with a [link](https://example.com)
        - bullet three

        - **nested group one**
          - nested item with enough text to wrap onto another line
          - nested item two
        - **nested group two**
          - nested item three

        1. ordered one
        2. ordered two
        3. ordered three
        4. ordered four
        5. ordered five
        6. ordered six
        7. ordered seven
        8. ordered eight
        9. ordered item with enough text to wrap onto another line
        10. ordered ten

        ```swift
        let answer = 42
        print(answer)
        ```

        > A blockquote, for good measure.

        | col a | col b |
        | ----- | ----- |
        | one   | two   |
        """),
        .stop(.stop)
    ])

    static let interleaved = Scenario(name: "interleave", steps: [
        .think("First, restate the question to make sure I understand it."),
        .say("Let me work through this in a few passes.\n\n"),
        .think("Pass two: weigh the options against each other."),
        .say("The trade-off comes down to latency versus cost.\n\n"),
        .think("Pass three: land on a recommendation."),
        .say("I'd go with the cheaper option — the latency difference is imperceptible here."),
        .stop(.stop)
    ])

    static let cjk = Scenario(name: "cjk", steps: [
        .say("""
        # 中文与表情符号 🍑

        这是一段**混合**的文字，用来测试 CJK 排版、换行，以及 emoji 🎉 的渲染。

        - 第一项：阳光 ☀️
        - 第二项：成熟的桃子 🍑
        - 第三项：`等宽代码`

        > 混合标点测试（故意保留半角标点）：Hello,世界!

        | 名称 | 描述 | 链接 | 状态 |
        | ---- | ---- | ---- | ---- |
        | 桃子 | 香甜、多汁、适合做甜点 | [官网](https://example.com/peach) | ✅ 成熟 |
        | 阳光 | 明亮，适合户外散步 | [天气](https://example.com/weather) | ☀️ 晴朗 |
        | 等宽代码 | `let fruit = "🍑"` | [文档](https://example.com/docs) | ⌘ 可复制 |
        | 世界 | 你好，世界！ | [地图](https://example.com/map) | 🌏 在线 |
        """),
        .stop(.stop)
    ])

    static let longOutput = Scenario(name: "long", steps: [
        .say(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 120)),
        .stop(.stop)
    ])

    static let thinkingOnly = Scenario(name: "thinking", steps: [
        .think("""
        **Weighing the request**

        Long internal reasoning that should collapse in the UI by default. Step one, step two, step three.

        **Settling on an answer**

        The sections above mirror how reasoning summaries arrive: each part opens with a bold headline.
        """),
        .say("Done."),
        .stop(.stop)
    ])

    static let slowThinking = Scenario(name: "thinkslow", steps: [
        .think("Reasoning slowly so the live thinking row stays on screen."),
        .wait(.seconds(4)),
        .think("Still working — the loader should sit centered on this line."),
        .wait(.seconds(4)),
        .say("Done."),
        .stop(.stop)
    ])

    private static let streamingMarkdown = """
        ## Streaming markdown demo

        Watch the leading edge: every word fades in softly, and **bold**, *italic*, and `inline code` \
        style themselves from the opening marker instead of snapping when the closer arrives.

        - bullets render as bullets from their first word
        - the dot and indent never reflow
        - only the last item's tail fades

        1. ordered lists too
        2. numbers appear immediately

        ```swift
        let answer = 42
        print("code streams inside its container", answer)
        ```

        > A quote keeps its bar and muted color while streaming.

        | fruit | color | taste |
        | --- | --- | --- |
        | peach | pink | sweet |
        | lime | green | sharp |

        A closing paragraph after the blank line: the settled blocks above must not move by a single pixel \
        while these words fade in at the tail.
        """

    static let slowStream = Scenario(name: "slowstream", steps: [
        .say(streamingMarkdown),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(120))

    static let fastStream = Scenario(name: "faststream", steps: [
        .say(streamingMarkdown),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(0))

    static let formattedStreamStress = Scenario(name: "formatstress", steps: [
        .say("**" + String(repeating: "A long formatted paragraph keeps growing without a settling boundary. ", count: 120) + "**"),
        .stop(.stop)
    ])

    static let focusedStream = Scenario(name: "focusstream") { _ in
        let prefix = (1...20).map { "Focus setup line \($0)." }.joined(separator: "\n")
        let continuation = (1...18).map { "Focus continuation line \($0)." }.joined(separator: "\n")
        return [
            .say("\(prefix)\nFocus checkpoint."),
            .wait(.seconds(4)),
            .say("\(continuation)\nFocus continuation complete."),
            .stop(.stop),
        ]
    }.pacing(betweenDeltas: .milliseconds(0))

    static let selectableCodeStream = Scenario(name: "selectcode", steps: [
        .say("""
        ```swift
        let answer = 42
        """),
        .wait(.seconds(8)),
        .say("""
        print(answer)
        ```
        """),
        .stop(.stop),
    ])

    static let backgroundStream = Scenario(name: "background", steps: [
        .wait(.seconds(3)),
        .say(String(repeating: "Background streaming must preserve the reader's position. ", count: 15)),
        .stop(.stop),
    ])

    static let composerClearance = Scenario(name: "clearance", steps: [
        .say("""
        # Clearance check

        First paragraph.

        Second paragraph.

        Third paragraph.

        Fourth paragraph.

        Fifth paragraph.
        """),
        .stop(.stop),
    ])

    static var links: Scenario {
        #if targetEnvironment(simulator)
        let root = SimEnv.servicesURL(path: "/mock").absoluteString
        #else
        let root = "https://example.com"
        #endif
        return Scenario(name: "links", steps: [
        .say("""
        ## Streaming links

        [Home](\(root) "Home page"), [Docs](\(root)/docs "Documentation"), \
        [Nested](\(root)/wiki/Function_(mathematics) "Nested destination"), and \
        [Status](https://status.example.com "Service status").
        """),
        .stop(.stop)
        ]).pacing(betweenDeltas: .milliseconds(180))
    }

    static let errorMidstream = Scenario(name: "error", steps: [
        .say("Starting some work…"),
        .fail(message: "mock provider failure", reason: .error)
    ])

    static let rateLimited = Scenario(name: "rate-limited", steps: [
        .fail(message: "RESOURCE_EXHAUSTED: exceeded your current quota", reason: .error)
    ])

    static let slowFirstToken = Scenario(name: "slow", steps: [
        .wait(.seconds(3)),
        .say("Sorry that took a moment."),
        .stop(.stop)
    ])

    static let truncated = Scenario(name: "truncated", steps: [
        .say(String(repeating: "This answer keeps going and going until the model hits its token ceiling ", count: 12)),
        .stop(.length)
    ])

    static let empty = Scenario(name: "empty", steps: [
        .stop(.stop)
    ])

    static let parallelTools = Scenario(name: "parallel") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Fanning out two reads at once.\n"),
                .think("Dispatching two independent reads."),
                execute("console.log({ city: \"SF\", tempF: 64 });"),
                execute("console.log({ city: \"NYC\", tempF: 58 });"),
            ]
        }
        let reads = ctx.resultsText("execute")
        let joined = reads.isEmpty ? "(no reads came back)" : reads.map { "- \($0)" }.joined(separator: "\n")
        return [
            .think("Combining both reads."),
            .wait(.seconds(2)),
            .say("Both reads are back:\n\n\(joined)"),
            .stop(.stop),
        ]
    }

    static let progressReport = Scenario(name: "progress-report") { ctx in
        if ctx.turn == 0 {
            return [
                .think("Planning the first pass."),
                execute("""
                await ox.user.reportProgress({ message: "I found the first result. I’m checking the remaining details now.", purpose: "Share progress" });
                console.log(await ox.fs.list({ path: "artifacts", purpose: "List artifacts" }));
                """),
            ]
        }
        return [
            .wait(.seconds(2)),
            .think("Checking the final details after the progress update."),
            .say("The progress update stayed in order."),
            .stop(.stop),
        ]
    }

    static let shoveler = Scenario(name: "shoveler") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            await ox.fs.write({ path: "artifacts/weekend-guide.txt", content: "Ocean Beach\\n\\nA windy, open shoreline on San Francisco's west side.", purpose: "Create weekend guide" });
            await ox.widget.shoveler({
              cards: [
                { description: "Ocean Beach — windy and open", badge: "Nearby", artifact: "weekend-guide.txt" },
                { title: "Cliffside trail" },
                { title: "Presidio", description: "Forest paths winding through the quietest corners of the park", badge: "Forest" }
              ],
              purpose: "Show quiet places"
            });
            """)]
        }
        return [.say("Three quiet places, ready to browse."), .stop(.stop)]
    }

    static let video = Scenario(name: "video") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            await ox.widget.video({
              video: "widget-video.mp4",
              purpose: "Show video"
            });
            """)]
        }
        return [.say("The video is ready to play."), .stop(.stop)]
    }

    static let binaryChoiceFlow = Scenario(name: "binary-choice") { ctx in
        guard let result = ctx.resultText("execute") else {
            return [
                .say("This will permanently delete 3 archived chats.\n"),
                execute("console.log({ choice: await ox.user.choose({ body: \"Delete 3 archived chats? This can't be undone.\", options: [\"Yes\", \"No\"], purpose: \"Confirm deletion\" }) });"),
            ]
        }
        if result.contains("\"choice\":\"Yes\"") {
            return [.say("Done — 3 archived chats deleted."), .stop(.stop)]
        }
        return [.say("Cancelled — nothing was deleted."), .stop(.stop)]
    }

    static let choiceFlow = Scenario(name: "choice") { ctx in
        guard let pick = ctx.resultText("execute") else {
            return [
                .say(
                    String(repeating: "This plan comparison includes the context needed to make an informed choice. ", count: 11)
                        + "\n\nWhich plan should I set you up with?\n"
                ),
                execute("console.log(await ox.user.choose({ body: \"Pick a plan:\", options: [\"Free\", \"Pro\", \"Team\"], purpose: \"Choose a plan\" }));"),
            ]
        }
        return [
            .think("Checking the selected plan."),
            .wait(.seconds(1)),
            .say("Great — setting you up on the **\(pick)** plan."),
            .stop(.stop),
        ]
    }.pacing(betweenDeltas: .milliseconds(1))

    static let signin = Scenario(name: "signin") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [
                .say("You're in. Top GitHub notification: **ox/services #42 — flaky CI on macOS runners**."),
                .stop(.stop),
            ]
        }
        let domain = "github.com"
        return [
            .say("You'll need to sign in first — use the handoff above the composer.\n"),
            execute("console.log(await ox.service.signIn({ domain: \"\(domain)\", purpose: \"Sign in to service\" }));"),
        ]
    }

    static let botControl = Scenario(name: "bot-control") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [.say("Verification completed."), .stop(.stop)]
        }
        #if targetEnvironment(simulator)
        let domain = SimEnv.servicesEndpoint == nil ? "archive.ph" : "127.0.0.1"
        #else
        let domain = "archive.ph"
        #endif
        return [
            .say("Complete the human-verification handoff above the composer.\n"),
            execute("await ox.service.solve({ domain: \"\(domain)\", args: { requestId: \"req-7\" }, purpose: \"Complete verification\" }); console.log({ verified: true });"),
        ]
    }

    static let payment = Scenario(name: "payment") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [.say("Checkout completed with reference **fixture-order-42**."), .stop(.stop)]
        }
        #if targetEnvironment(simulator)
        let domain = SimEnv.servicesEndpoint == nil ? "oftendining.com" : "127.0.0.1"
        #else
        let domain = "oftendining.com"
        #endif
        return [
            .say("Review and complete checkout in the handoff above the composer.\n"),
            execute("console.log(await ox.service.pay({ domain: \"\(domain)\", args: {}, purpose: \"Review checkout\" }));"),
        ]
    }

    static let urlServiceContext = Scenario(name: "url-service-context") { ctx in
        let userURL = "https://github.com/earendil-works/pi"
        let toolURL = "https://www.google.com/maps/place/Seattle"
        guard !ctx.systemPrompt.contains("<url-relations") else {
            return [.say("URL service context leaked into the system prompt."), .stop(.stop)]
        }
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            let text = result.content.compactMap { block in
                if case .text(let text) = block { text.text } else { nil }
            }.joined()
            guard text.contains("<url-relations provenance=\"runtime-generated\">")
                    && text.contains(toolURL)
                    && text.contains("- www.google.com |")
                    && text.contains("- google.com |") else {
                return [.say("Tool URL service context was incorrect."), .stop(.stop)]
            }
            return [.say("URL service context ready."), .stop(.stop)]
        }
        guard ctx.transientContext.contains("<url-relations provenance=\"runtime-generated\">")
                && ctx.transientContext.contains(userURL)
                && ctx.transientContext.contains("- github.com |") else {
            return [.say("User URL service context was incorrect."), .stop(.stop)]
        }
        return [execute("console.log({ url: \"\(toolURL)\" });")]
    }

    static let recover = Scenario(name: "recover") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Trying the primary feed…\n"),
                execute("throw new Error(\"primary feed unavailable\");"),
            ]
        }
        if ctx.turn == 1, ctx.toolResults.last(where: { $0.toolName == "execute" })?.isError == true {
            return [
                .say("Primary feed failed — falling back to the cached mirror.\n"),
                execute("console.log({ source: \"cache\", items: 7 });"),
            ]
        }
        if ctx.turn == 1 {
            return [.say("The failed tool result was not marked as an error."), .stop(.stop)]
        }
        let recovered = ctx.resultText("execute") ?? "n/a"
        return [
            .say("Recovered via the cached mirror: \(recovered)."),
            .stop(.stop),
        ]
    }

    private static func contextBudgetRegressionFailure() -> String? {
        var model = MockLLMClient().models[0]
        let empty = AgentContext(systemPrompt: "", messages: [], tools: [])
        var options = StreamOptions()
        options.maxTokens = 4096
        model.maxContext = 32768
        let small = AgentContextBudget(context: empty, model: model, options: options, threshold: 0.75)
        model.maxContext = 1_000_000
        let large = AgentContextBudget(context: empty, model: model, options: options, threshold: 0.75)
        guard large.inputLimit > small.inputLimit,
              large.reserveTokens == 4096 else { return "Model context sizing failed." }
        let occupied = AgentContext(systemPrompt: String(repeating: "药", count: 1000), messages: [], tools: [])
        let remaining = AgentContextBudget(context: occupied, model: model, options: options, threshold: 0.75)
        guard remaining.usedTokens == 3000 else { return "Multilingual context accounting failed." }
        var assistant = AssistantMessage(model: model.id)
        assistant.stopReason = .toolUse
        assistant.usage.input = 20000
        assistant.usage.output = 1000
        let history = AgentContext(systemPrompt: "Already counted", messages: [.assistant(assistant), .user(UserMessage(text: "药"))], tools: [])
        let measured = AgentContextBudget(context: history, model: model, options: options, threshold: 0.75)
        guard measured.usedTokens == 21015 else { return "Provider usage accounting failed." }
        var changedPrompt = history
        changedPrompt.systemPrompt = String(repeating: "A", count: 100000)
        let changed = AgentContextBudget(context: changedPrompt, model: model, options: options, threshold: 0.75)
        guard changed.usedTokens >= 25000 else { return "Changed prompt was omitted from the budget." }
        let full = String(repeating: "a", count: 120104)
        let message = ToolResultMessage(toolCallId: "budget-check", toolName: "execute", content: [.text(TextContent(full))], isError: false)
        guard message.content.concatenatedText == full,
              ToolResultParts(message, label: "budget-regression").text == full else {
            return "A downstream output cutoff remains."
        }
        let calls = ["a", "b", "c"].map { ToolCall(id: $0, name: "execute", arguments: .object([:])) }
        let results = calls.map { Message.toolResult(ToolResultMessage(toolCallId: $0.id, toolName: "execute", content: [.text(TextContent(String(repeating: "A", count: 40000)))], isError: false)) }
        let sequence: [Message] = [
            .user(UserMessage(text: "Original request")),
            .assistant(AssistantMessage(model: model.id, content: calls.prefix(2).map(ContentBlock.toolCall))),
            results[0], results[1],
            .assistant(AssistantMessage(model: model.id, content: [.toolCall(calls[2])])),
            results[2],
        ]
        guard AgentCompactor.cutIndex(messages: sequence, retainedTokens: 20000) == 4,
              AgentCompactor.cutIndex(messages: sequence, retainedTokens: 1) == 4,
              AgentCompactor.cutIndex(messages: Array(sequence.prefix(4)), retainedTokens: 1) == 1,
              AgentCompactor.cutIndex(messages: sequence, retainedTokens: 100000) == nil,
              AgentCompactor.cutIndex(messages: sequence + [.user(UserMessage(text: "Next request"))], retainedTokens: 1) == 6 else {
            return "Split-turn compaction boundary failed."
        }
        return nil
    }

    private static func outputLimitRegressionFailure() -> String? {
        let exactBytes = String(repeating: "A", count: 51200)
        let exactLines = String(repeating: "line\n", count: 2000)
        for value in ["", "\n", exactBytes, exactLines, "é药💊", "e\u{301}👨‍👩‍👧‍👦"] {
            guard JavaScriptOutputLimits.preview(value) == value else { return "A fitting output changed." }
        }
        guard JavaScriptOutputLimits.preview("X" + exactBytes) == exactBytes,
              JavaScriptOutputLimits.preview("old\n" + exactLines) == String(exactLines.dropLast()),
              JavaScriptOutputLimits.preview("old\r\n" + String(repeating: "line\r\n", count: 2000)) == String(decoding: String(repeating: "line\r\n", count: 2000).utf8.dropLast(), as: UTF8.self),
              JavaScriptOutputLimits.preview(exactBytes + "\nTAIL") == "TAIL" else {
            return "Fixed byte or line tail limit failed."
        }
        for value in ["é", "药", "💊", "e\u{301}👨‍👩‍👧‍👦"] {
            let output = String(repeating: value, count: 30000) + "TAIL"
            let preview = JavaScriptOutputLimits.preview(output)
            guard Array(output.utf8).suffix(preview.utf8.count).elementsEqual(preview.utf8),
                  preview.utf8.count <= 51200, preview.hasSuffix("TAIL"), !preview.contains("�") else {
                return "Unicode output boundary failed."
            }
        }
        return nil
    }

    static let toolResultBudget = Scenario(name: "budget") { ctx in
        if ctx.turn == 0 {
            if let failure = outputLimitRegressionFailure() {
                return [.say(failure), .stop(.stop)]
            }
            return [execute("console.log(\"A\".repeat(51196) + \"TAIL\");")]
        }
        if ctx.turn == 1 {
            guard let result = ctx.toolResults.last,
                  result.truncated != true,
                  ctx.resultText("execute") == String(repeating: "A", count: 51196) + "TAIL",
                  ToolResultParts(result, label: "budget-regression").text.count == 51200 else {
                return [.say("A fitting output was incorrectly truncated."), .stop(.stop)]
            }
            return [execute("console.log(\"药\".repeat(350000) + \"TAIL\");")]
        }
        if ctx.turn == 2 {
            guard let result = ctx.toolResults.last,
                  result.truncated == true,
                  let text = ctx.resultText("execute"),
                  text.hasPrefix(String(repeating: "药", count: 17065) + "TAIL\n[Tool output truncated:"),
                  let marker = text.range(of: "Full output id: "),
                  let id = UUID(uuidString: String(text[marker.upperBound...].prefix(36))) else {
                return [.say("Oversized output did not provide a recovery reference."), .stop(.stop)]
            }
            return [execute("""
            const text = await ox.output.read({ id: "\(id.uuidString)", purpose: "Recover full tool output" });
            if (text.length !== 350004 || text.slice(150000, 150003) !== "药药药" || text.slice(-4) !== "TAIL") throw new Error("Captured output was incomplete");
            for (let i = 0; i < 2001; i++) console.log("line " + i);
            """)]
        }
        if ctx.turn == 3 {
            guard let result = ctx.toolResults.last, result.isError == false, result.truncated == true,
                  let text = ctx.resultText("execute"), text.hasPrefix("line 1\nline 2\n"),
                  text.contains("line 2000\n[Tool output truncated:"),
                  let marker = text.range(of: "Full output id: "),
                  let id = UUID(uuidString: String(text[marker.upperBound...].prefix(36))) else {
                return [.say("Combined console line limit or byte-output recovery failed."), .stop(.stop)]
            }
            return [execute("""
            const text = await ox.output.read({ id: "\(id.uuidString)", purpose: "Recover every console line" });
            if (text.split("\\n").length !== 2001 || !text.startsWith("line 0\\n") || !text.endsWith("line 2000")) throw new Error("Captured lines were incomplete");
            console.log("Recovered complete oversized output, including its middle and tail.");
            """)]
        }
        let text = ctx.resultText("execute") ?? ""
        if ctx.turn == 4 {
            guard text.contains("Recovered complete oversized output"), ctx.toolResults.last?.isError == false else {
                return [.say("Output recovery failed: \(text)"), .stop(.stop)]
            }
            return [execute("console.log(\"A\".repeat(60000)); throw new Error(\"EXPECTED_OUTPUT_ERROR\");")]
        }
        guard ctx.toolResults.last?.isError == true, ctx.toolResults.last?.truncated == true,
              text.contains("EXPECTED_OUTPUT_ERROR"), text.contains("Full output id:") else {
            return [.say("Truncation lost the execution error."), .stop(.stop)]
        }
        return [.say("Fixed byte and line caps, Unicode boundaries, and full-output recovery passed."), .stop(.stop)]
    }

    static let artifactWorkflow = Scenario(name: "artifact") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Creating an artifact and presenting the finished file.\n"),
                execute("""
                await ox.fs.write({ path: "artifacts/agent-note.md", content: '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><text x="8" y="26">Hello</text></svg>', purpose: "Create agent note" });
                await ox.fs.edit({ path: "artifacts/agent-note.md", edits: [{ oldText: "Hello", newText: "Hello, Ox!" }], purpose: "Edit agent note" });
                const result = await ox.fs.read({ path: "artifacts/agent-note.md", purpose: "Read agent note" });
                await ox.artifact.rename({ filename: "agent-note.md", newFilename: "agent-image.svg", purpose: "Rename agent note" });
                await ox.fs.read({ path: "artifacts/agent-image.svg", purpose: "Read agent image" });
                for (const extension of ["md", "html"]) {
                    const path = "artifacts/utf8-read-check." + extension;
                    await ox.fs.write({ path, content: "Aé药💊Z", purpose: "Create UTF-8 read fixture" });
                    for (const [maxBytes, expected] of [[1, "A"], [2, "A"], [3, "Aé"], [4, "Aé"], [5, "Aé"], [6, "Aé药"], [7, "Aé药"], [8, "Aé药"], [9, "Aé药"], [10, "Aé药💊"], [11, "Aé药💊Z"], [12, "Aé药💊Z"]]) {
                        const read = await ox.fs.read({ path, options: { maxBytes }, purpose: "Verify UTF-8 byte boundary" });
                        if (read.text !== expected || read.truncated !== (maxBytes < 11)) throw new Error("UTF-8 boundary mismatch at " + maxBytes);
                    }
                    await ox.fs.write({ path, content: "药".repeat(50000), purpose: "Create complete read fixture" });
                    const read = await ox.fs.read({ path, purpose: "Verify complete default read" });
                    if (read.text !== "药".repeat(50000) || read.truncated) throw new Error("Default read was incomplete");
                    await ox.fs.write({ path, content: String.fromCharCode(0xFEFF) + "药", purpose: "Create UTF-8 BOM fixture" });
                    for (const maxBytes of [1, 2, 3, 4, 5, 6]) {
                        const read = await ox.fs.read({ path, options: { maxBytes }, purpose: "Verify UTF-8 BOM boundary" });
                        if (read.text !== (maxBytes < 6 ? "" : "药") || read.truncated !== (maxBytes < 6)) throw new Error("UTF-8 BOM boundary mismatch");
                    }
                    await ox.fs.delete({ path, purpose: "Remove UTF-8 read fixture" });
                }
                console.log(result.text.includes("Hello, Ox!") ? "Hello, Ox!" : result.text);
                """),
            ]
        }
        let text = ctx.resultText("execute") ?? ""
        if text.contains("ERROR") {
            return [.say("The artifact workflow failed: \(text)"), .stop(.stop)]
        }
        return [.say("The finished artifact contains: **\(text)** and read agent-image.svg."), .stop(.stop)]
    }

    static let webFetch = Scenario(name: "web-fetch") { ctx in
        if ctx.turn == 0 {
            #if targetEnvironment(simulator)
            let textURL = SimEnv.servicesURL(path: "/web/text").absoluteString
            let imageURL = SimEnv.servicesURL(path: "/web/image.png").absoluteString
            let secondImageURL = SimEnv.servicesURL(path: "/web/image.gif").absoluteString
            let pdfURL = SimEnv.servicesURL(path: "/web/document.pdf").absoluteString
            #else
            let textURL = "https://example.com/"
            let imageURL = "https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png"
            let secondImageURL = imageURL
            let pdfURL = "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
            #endif
            return [
                .say("Fetching mixed web resources.\n"),
                execute("""
                const [text, firstImage, pdf, secondImage] = await Promise.all([
                  ox.web.fetch({ url: "\(textURL)", purpose: "Fetch text fixture" }),
                  ox.web.fetch({ url: "\(imageURL)", purpose: "Fetch first image" }),
                  ox.web.fetch({ url: "\(pdfURL)", purpose: "Fetch PDF fixture" }),
                  ox.web.fetch({ url: "\(secondImageURL)", purpose: "Fetch second image" })
                ]);
                console.log({
                  text: text.text,
                  status: text.status,
                  contentType: text.headers["content-type"]
                });
                console.warn("FETCH STDERR");
                return "RETURN VALUE MUST NOT REACH THE MODEL";
                """),
            ]
        }
        let result = ctx.toolResults.last
        let attachments = result?.transientAttachments ?? []
        let kinds = attachments.map(\.kind)
        let outputLines = result?.content.concatenatedText.split(separator: "\n", omittingEmptySubsequences: false)
        let log = outputLines?.first.flatMap { JSONValue.parse(jsonString: String($0)) }?.objectValue
        guard result?.content.concatenatedText.contains("Ox fetch fixture") == true
                || result?.content.concatenatedText.contains("Example Domain") == true,
              log?["text"]?.stringValue?.contains("Ox fetch fixture") == true
                || log?["text"]?.stringValue?.contains("Example Domain") == true,
              outputLines?.dropFirst().first == "[warn] FETCH STDERR",
              result?.content.concatenatedText.contains("RETURN VALUE MUST NOT REACH THE MODEL") == false,
              kinds.count == 3,
              kinds[0] == .image,
              kinds[1] == .pdf,
              kinds[2] == .image,
              attachments[0].mimeType == "image/png",
              attachments[2].mimeType == "image/png",
              attachments[2].displayName.hasSuffix(".png"),
              attachments[2].data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) else {
            return [.say("Web fetch attachment delivery failed."), .stop(.stop)]
        }
        return [.say("Fetched HTTP resources and delivered 3 attachments."), .stop(.stop)]
    }

    static let webImport = Scenario(name: "web-import") { ctx in
        if ctx.turn == 0 {
            #if targetEnvironment(simulator)
            let url = SimEnv.servicesURL(path: "/health").absoluteString
            #else
            let url = "https://example.com/"
            #endif
            return [
                .say("Importing one fetched response.\n"),
                execute("""
                const artifact = await ox.artifact.import({
                  url: "\(url)",
                  filename: "web-health.txt",
                  purpose: "Import health response"
                });
                console.log(artifact);
                """),
            ]
        }
        let text = ctx.resultText("execute") ?? ""
        guard !text.contains("ERROR"), text.contains("web-health.txt") else {
            return [.say("Web response import failed."), .stop(.stop)]
        }
        return [.say("Imported the fetched response as web-health.txt."), .stop(.stop)]
    }

    static let failFastInvocation = Scenario(name: "fail-fast") { ctx in
        if ctx.turn == 0 {
            return [
                execute("""
                await Promise.all([
                  ox.service.invoke({
                    name: "web:127.0.0.1:delayedEcho",
                    input: { value: "late", delayMs: 800 },
                    purpose: "Exercise late invocation settlement"
                  }),
                  Promise.reject(new Error("fail fast"))
                ]);
                """),
            ]
        }
        return [.say("Fail-fast execution settled cleanly."), .stop(.stop)]
    }

    static let skillWorkflow = Scenario(name: "skills") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Loading the skill-authoring instructions.\n"),
                execute("""
                const manager = await ox.fs.read({ path: "skills/system:manage-skills/SKILL.md", purpose: "Read skill manager" });
                const workflow = await ox.fs.read({ path: "skills/system:manage-skills/references/user-skill.md", purpose: "Read user skill workflow" });
                console.log(manager.text + "\n" + workflow.text);
                """),
            ]
        }
        if ctx.turn == 1 {
            guard ctx.resultText("execute")?.contains("# Manage Skills") == true,
                  ctx.resultText("execute")?.contains("# User Skill") == true else {
                return [.say("The skill instructions could not be loaded."), .stop(.stop)]
            }
            return [
                .say("Creating and refining a reusable skill.\n"),
                execute("""
                await ox.skill.create({
                  name: "agent-weekly",
                  description: "Prepare a concise weekly review",
                  instructions: "Review completed work and choose the next priority.",
                  purpose: "Create review skill"
                });
                const before = await ox.fs.read({ path: "skills/agent-weekly/SKILL.md", purpose: "Read review skill" });
                await ox.fs.edit({
                  path: "skills/agent-weekly/SKILL.md",
                  edits: [
                    { oldText: 'description: "Prepare a concise weekly review"', newText: `description: "Prepare a weekly review with unfinished work"
                services: 127.0.0.1` },
                    { oldText: "choose the next priority", newText: "list unfinished work and choose the next priority" }
                  ],
                  purpose: "Refine review skill"
                });
                const listed = await ox.fs.glob({ pattern: "skills/*/SKILL.md", purpose: "List user skills" });
                const found = await ox.fs.grep({ pattern: "unfinished work", path: "skills", options: { literal: true }, purpose: "Search skill content" });
                const copied = await ox.skill.copy({ source: "agent-weekly", name: "agent-weekly-copy", purpose: "Copy review skill" });
                const deleted = await ox.skill.delete({ name: "agent-weekly-copy", purpose: "Delete copied skill" });
                console.log({
                  before: before.text,
                  final: "agent-weekly",
                  listed: listed.paths,
                  matches: found.matches.length,
                  copied: copied.name,
                  deleted: deleted.deleted
                });
                """),
            ]
        }
        let result = ctx.resultText("execute") ?? ""
        if result.contains("ERROR") {
            return [.say("The skill workflow failed: \(result)"), .stop(.stop)]
        }
        return [.say("Created **/agent-weekly** and refined its instructions."), .stop(.stop)]
    }

    static let localServiceWorkflow = Scenario(name: "local-service") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const created = await ox.service.create({ kind: "web", domain: "example.test", purpose: "Create test service" });
            const before = await ox.fs.read({ path: "services/web/example.test/actions.js", purpose: "Read Local actions" });
            let invalid;
            try {
              await ox.fs.write({ path: "services/web/example.test/actions.js", content: ")", purpose: "Test invalid actions" });
            } catch (error) {
              invalid = String(error);
            }
            const after = await ox.fs.read({ path: "services/web/example.test/actions.js", purpose: "Verify Local rollback" });
            await ox.fs.write({ path: "services/web/example.test/NOTES.md", content: "Local authoring fixture", purpose: "Write Local note" });
            const manifestPath = "services/web/example.test/service.json";
            const manifest = await ox.fs.read({ path: manifestPath, purpose: "Read Local manifest" });
            const firstManifest = JSON.parse(manifest.text);
            firstManifest.actions = [{
              id: "version",
              label: "Version",
              description: "Draft one",
              inputSchema: { type: "object", properties: {}, additionalProperties: false },
              outputSchema: {
                type: "object",
                properties: { value: { type: "string" } },
                required: ["value"],
                additionalProperties: false
              },
              requireApproval: false,
              requireAuth: false
            }];
            const firstSource = JSON.stringify(firstManifest, null, 2);
            await ox.fs.write({ path: manifestPath, content: firstSource, purpose: "Write first test draft" });
            const firstAttach = await ox.service.attach({ domain: "example.test", purpose: "Load first test draft" });
            const first = await ox.service.inspect({ domain: "example.test", actions: ["version"], purpose: "Inspect first test draft" });
            await ox.fs.edit({
              path: manifestPath,
              edits: [{ oldText: '"description": "Draft one"', newText: '"description": "Draft two"' }],
              purpose: "Write second test draft"
            });
            const stale = await ox.service.inspect({ domain: "example.test", actions: ["version"], purpose: "Inspect loaded test draft" });
            const secondAttach = await ox.service.attach({ domain: "example.test", purpose: "Load second test draft" });
            const second = await ox.service.inspect({ domain: "example.test", actions: ["version"], purpose: "Inspect second test draft" });
            const listed = await ox.fs.list({ path: "services/web/example.test", purpose: "List Local source" });
            console.log(JSON.stringify({
              created,
              before: before.text,
              after: after.text,
              invalid,
              firstAttach,
              first: first.actions.version.description,
              stale: stale.actions.version.description,
              secondAttach,
              second: second.actions.version.description,
              paths: listed.items.map(item => item.path)
            }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["created"]?.objectValue?["source"]?.stringValue == "local",
              result["before"]?.stringValue == result["after"]?.stringValue,
              result["invalid"]?.stringValue?.contains("actions.js syntax") == true,
              result["firstAttach"]?.objectValue?["reloaded"]?.boolValue == false,
              result["first"]?.stringValue == "Draft one",
              result["stale"]?.stringValue == "Draft one",
              result["secondAttach"]?.objectValue?["reloaded"]?.boolValue == true,
              result["second"]?.stringValue == "Draft two",
              result["paths"]?.arrayValue?.contains(.string("services/web/example.test/service.json")) == true,
              result["paths"]?.arrayValue?.contains(.string("services/web/example.test/actions.js")) == true,
              result["paths"]?.arrayValue?.contains(.string("services/web/example.test/NOTES.md")) == true else {
            return [.say("Local service authoring did not preserve its validation boundary."), .stop(.stop)]
        }
        return [.say("Created Local source, preserved the loaded draft across edits, and explicitly reloaded the next coherent draft."), .stop(.stop)]
    }

    static let localCopyWorkflow = Scenario(name: "local-copy") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const copied = await ox.service.copy({ domain: "archive.ph", purpose: "Copy test service" });
            const before = await ox.fs.read({ path: "services/web/archive.ph/service.json", purpose: "Read copied manifest" });
            let invalid;
            try {
              await ox.fs.edit({
                path: "services/web/archive.ph/service.json",
                edits: [{ oldText: '"domain": "archive.ph"', newText: '"domain": "wrong.example"' }],
                purpose: "Test invalid manifest"
              });
            } catch (error) {
              invalid = String(error);
            }
            const after = await ox.fs.read({ path: "services/web/archive.ph/service.json", purpose: "Verify manifest rollback" });
            const listed = await ox.fs.list({ path: "services/web/archive.ph", purpose: "List copied source" });
            console.log(JSON.stringify({ copied, restored: before.text === after.text, invalid, count: listed.items.length }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["copied"]?.objectValue?["source"]?.stringValue == "local",
              result["restored"]?.boolValue == true,
              result["invalid"]?.stringValue?.contains("identity mismatch") == true,
              (result["count"]?.intValue ?? 0) > 1 else {
            return [.say("Copied Local source did not preserve its validation boundary."), .stop(.stop)]
        }
        return [.say("Copied the selected service to Local and restored its manifest after a rejected invalid edit."), .stop(.stop)]
    }

    static let localHistoryWorkflow = Scenario(name: "local-history") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            await ox.service.create({ kind: "web", domain: "history.test", purpose: "Create history service" });
            await ox.fs.write({ path: "services/web/history.test/NOTES.md", content: "first version", purpose: "Write history note" });
            const first = await ox.service.git.commit({ message: "Add history test service", purpose: "Commit history service" });
            await ox.fs.write({ path: "services/web/history.test/NOTES.md", content: "second version", purpose: "Revise history note" });
            const second = await ox.service.git.commit({ message: "Revise history test note", purpose: "Commit revised note" });
            await ox.fs.delete({ path: "services/web/history.test/NOTES.md", purpose: "Delete history note" });
            await ox.service.git.restore({ path: "services/web/history.test/NOTES.md", purpose: "Restore history note" });
            const pathRestored = await ox.fs.read({ path: "services/web/history.test/NOTES.md", purpose: "Verify targeted restore" });
            const log = await ox.service.git.log({ limit: 3, purpose: "Read Local history" });
            const shown = await ox.service.git.show({ commitHash: first.commitHash, path: "web/history.test/NOTES.md", purpose: "Read first note" });
            const historical = await ox.service.git.checkout({ commitHash: first.commitHash, purpose: "Visit first version" });
            let readOnly;
            try {
              await ox.fs.write({ path: "services/web/history.test/NOTES.md", content: "forbidden", purpose: "Test historical write" });
            } catch (error) {
              readOnly = String(error);
            }
            await ox.service.git.checkout({ commitHash: "latest", purpose: "Return to latest" });
            await ox.fs.write({ path: "services/web/history.test/NOTES.md", content: "draft", purpose: "Write disposable draft" });
            const dirty = await ox.service.git.status({ purpose: "Inspect disposable draft" });
            await ox.service.git.restore({ purpose: "Discard disposable draft" });
            const restored = await ox.fs.read({ path: "services/web/history.test/NOTES.md", purpose: "Verify restored note" });
            await ox.service.git.revert({ commitHash: second.commitHash, message: "Revert revised history note", purpose: "Revert revised note" });
            const reverted = await ox.fs.read({ path: "services/web/history.test/NOTES.md", purpose: "Verify reverted note" });
            const clean = await ox.service.git.status({ purpose: "Verify clean history" });
            console.log(JSON.stringify({
              first: first.commitHash,
              second: second.commitHash,
              pathRestored: pathRestored.text,
              log: log.commits.map(commit => commit.commitHash),
              shown: shown.content,
              historical: historical.view,
              readOnly,
              dirty: dirty.dirty,
              restored: restored.text,
              reverted: reverted.text,
              clean: clean.dirty
            }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["first"]?.stringValue?.count == 40,
              result["second"]?.stringValue?.count == 40,
              result["pathRestored"]?.stringValue == "second version",
              result["log"]?.arrayValue?.count == 3,
              result["shown"]?.stringValue == "first version",
              result["historical"]?.stringValue == "historical",
              result["readOnly"]?.stringValue?.contains("historical commit") == true,
              result["dirty"]?.boolValue != nil,
              result["restored"]?.stringValue == "second version",
              result["reverted"]?.stringValue == "first version",
              result["clean"]?.boolValue == false else {
            return [.say("Local Git history did not preserve its linear authoring guarantees."), .stop(.stop)]
        }
        return [.say("Committed Local edits, visited an older commit read-only, restored a draft, and reverted a commit with a new inverse commit."), .stop(.stop)]
    }

    static let localHistoryRecovery = Scenario(name: "local-history-recovery") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const dirty = await ox.service.git.status({ purpose: "Inspect pending history draft" });
            await ox.service.git.restore({ purpose: "Discard pending history draft" });
            const log = await ox.service.git.log({ limit: 2, purpose: "Read pending history" });
            const target = log.commits[0];
            const before = await ox.fs.read({ path: "services/web/history.test/NOTES.md", purpose: "Read latest history note" });
            const inverse = await ox.service.git.revert({ commitHash: target.commitHash, message: "Revert revised history note", purpose: "Revert revised note" });
            const after = await ox.fs.read({ path: "services/web/history.test/NOTES.md", purpose: "Read reverted history note" });
            const clean = await ox.service.git.status({ purpose: "Verify clean Local history" });
            console.log(JSON.stringify({ dirty: dirty.dirty, before: before.text, after: after.text, inverse: inverse.commitHash, clean: clean.dirty }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["dirty"]?.boolValue == true,
              result["before"]?.stringValue == "second version",
              result["after"]?.stringValue == "first version",
              result["inverse"]?.stringValue?.count == 40,
              result["clean"]?.boolValue == false else {
            return [.say("Local restore or revert recovery failed."), .stop(.stop)]
        }
        return [.say("Restored the pending draft and reverted the latest Local commit with a clean inverse commit."), .stop(.stop)]
    }

    static let localDiffWorkflow = Scenario(name: "local-diff") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            await ox.service.create({ kind: "web", domain: "diff.test", purpose: "Create diff service" });
            await ox.fs.write({ path: "services/web/diff.test/NOTES.md", content: "diff fixture", purpose: "Write diff fixture" });
            const pending = await ox.service.git.diff({ path: "web/diff.test/NOTES.md", purpose: "Review pending diff" });
            const commit = await ox.service.git.commit({ message: "Add diff test service", purpose: "Commit diff service" });
            const committed = await ox.service.git.diff({ commitHash: commit.commitHash, path: "web/diff.test/NOTES.md", purpose: "Review committed diff" });
            console.log(JSON.stringify({ pending, commit, committed }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              let pending = result["pending"]?.objectValue,
              let committed = result["committed"]?.objectValue,
              let commitHash = result["commit"]?.objectValue?["commitHash"]?.stringValue,
              pending["workingTree"]?.boolValue == true,
              pending["files"]?.arrayValue?.first?.objectValue?["path"]?.stringValue == "web/diff.test/NOTES.md",
              pending["patch"]?.stringValue?.contains("+diff fixture") == true,
              committed["workingTree"]?.boolValue == false,
              committed["toCommitHash"]?.stringValue == commitHash,
              committed["patch"]?.stringValue?.contains("+diff fixture") == true else {
            return [.say("Local diff did not expose matching working and committed patches."), .stop(.stop)]
        }
        return [.say("Reviewed the same Local file as a pending working-tree diff and as a committed historical diff."), .stop(.stop)]
    }

    static let localDeleteWorkflow = Scenario(name: "local-delete") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            await ox.service.create({ kind: "web", domain: "delete.test", purpose: "Create delete fixture" });
            await ox.service.git.commit({ message: "Add delete test service", purpose: "Commit delete fixture" });
            const deleted = await ox.service.delete({ domain: "delete.test", purpose: "Delete Local fixture" });
            const dirty = await ox.service.git.status({ purpose: "Inspect service deletion" });
            await ox.service.git.restore({ purpose: "Restore deleted service" });
            const restored = await ox.fs.read({ path: "services/web/delete.test/service.json", purpose: "Verify restored service" });
            console.log(JSON.stringify({ deleted, dirty: dirty.dirty, restored: restored.text.includes('"domain" : "delete.test"') || restored.text.includes('"domain": "delete.test"') }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["deleted"]?.objectValue?["deleted"]?.boolValue == true,
              result["dirty"]?.boolValue == true,
              result["restored"]?.boolValue == true else {
            return [.say("Local service deletion did not remain recoverable through Git."), .stop(.stop)]
        }
        return [.say("Deleted a Local service, observed the pending Git change, and restored it."), .stop(.stop)]
    }

    static let skillCatalog = Scenario(name: "skill-catalog") { ctx in
        let userSkill = "- `skills/grocery-planner/SKILL.md` — Plan a weekly grocery list from meals, dietary needs, and pantry items."
        let manageArtifacts = "- `skills/system:manage-artifacts/SKILL.md` — Create, inspect, revise, import, rename, present, attach, or delete Profile artifacts, with specialized guidance for Markdown notes and interactive HTML canvases."
        let manageServices = "- `skills/system:manage-services/SKILL.md` — Create, inspect, copy, update, verify, version, or delete Ox service definitions and Local web-service source. Do not use merely to invoke a service."
        let manageSkills = "- `skills/system:manage-skills/SKILL.md` — Create, inspect, revise, copy, or delete Profile-owned and Local service-owned skills while respecting read-only system and external service skills."
        let serviceSkill = "- `skills/service:127.0.0.1:sanity/SKILL.md` — Deterministic fixture workflow for validating service skill loading."
        let expectsService = ctx.latestUserSaid("attached")
        let expectsUserSkill = ctx.latestUserSaid("user")
        let verifiesStablePrefix = ctx.latestUserSaid("cache")
        let activatesUserSkill = ctx.latestUserSaid("activate")
        let hasStableSystemSkills = ctx.systemPrompt.contains(manageArtifacts)
            && ctx.systemPrompt.contains(manageServices)
            && ctx.systemPrompt.contains(manageSkills)
        let hasTimestamp = ctx.serializedUserText
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.hasPrefix("[") && $0.hasSuffix(" \(TimeZone.autoupdatingCurrent.identifier)]") }
            == true
        let hasTurnStateAfterTimestamp = ctx.serializedUserText.contains("\n\n<turn-state>\n")
        let hasServiceSkill = ctx.transientContext.contains("Attached-service skills:")
            && ctx.transientContext.contains("skills/service:")
            && ctx.transientContext.contains("/SKILL.md` —")
        let hasFixtureServiceSkill = !ctx.transientContext.contains("127.0.0.1")
            || ctx.transientContext.contains(serviceSkill)
        let retainedServiceState = ctx.priorUserContext(containing: "attached")
            .map { $0.contains("Attached-service skills:") && $0.contains("skills/service:") }
            == true
        let languageDirective = AppLocale.resolvedResponseDirective
        guard ctx.systemPrompt.contains(userSkill) == expectsUserSkill,
              !ctx.systemPrompt.contains("## Language"),
              !ctx.transientContext.contains(userSkill),
              ctx.transientContext.contains("## Language") == !languageDirective.isEmpty,
              (languageDirective.isEmpty || ctx.transientContext.contains(languageDirective)),
              !ctx.transientContext.contains("User slash commands:"),
              !ctx.transientContext.contains("System skills:"),
              !ctx.transientContext.contains("127.0.0.1:delayedEcho"),
              hasStableSystemSkills,
              hasTimestamp,
              hasTurnStateAfterTimestamp == (expectsService || !languageDirective.isEmpty),
              !verifiesStablePrefix || retainedServiceState,
              hasFixtureServiceSkill,
              hasServiceSkill == expectsService else {
            return [.say("Skill catalog context was incorrect."), .stop(.stop)]
        }
        if activatesUserSkill {
            guard let result = ctx.toolResults.last else {
                return [
                    execute(#"console.log(await ox.fs.read({ path: "skills/grocery-planner/SKILL.md", purpose: "Activate grocery planning skill" }));"#),
                    .stop(.toolUse),
                ]
            }
            guard result.activatedSkills.contains(where: {
                $0.path == "skills/grocery-planner/SKILL.md"
                    && $0.content.contains("organize the grocery list by store section")
            }) else {
                return [.say("User skill activation context was not retained."), .stop(.stop)]
            }
            return [.say("User skill instructions activated."), .stop(.stop)]
        }
        let result = verifiesStablePrefix
            ? "Stable prompt prefix ready."
            : (expectsService ? "Attached skill catalog ready." : "Ox skill catalog ready.")
        return [.say(result), .stop(.stop)]
    }

    static let systemSkillReferences = Scenario(name: "system-skill-references") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const manager = await ox.fs.read({ path: "skills/system:manage-skills/SKILL.md", purpose: "Read skill manager" });
            const references = await ox.fs.list({ path: "skills/system:manage-skills/references", purpose: "List skill references" });
            const user = await ox.fs.read({ path: "skills/system:manage-skills/references/user-skill.md", purpose: "Read user skill workflow" });
            const matched = await ox.fs.glob({ path: "skills/system:manage-skills", pattern: "references/*.md", purpose: "Find skill references" });
            console.log(JSON.stringify({ manager: manager.text.includes("# Manage Skills"), references: references.items.map(item => item.path), user: user.text.includes("# User Skill"), matched: matched.paths }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["manager"]?.boolValue == true,
              result["user"]?.boolValue == true,
              result["references"]?.arrayValue?.compactMap(\.stringValue) == [
                "skills/system:manage-skills/references/service-skill.md",
                "skills/system:manage-skills/references/user-skill.md",
              ],
              result["matched"]?.arrayValue?.compactMap(\.stringValue) == [
                "skills/system:manage-skills/references/service-skill.md",
                "skills/system:manage-skills/references/user-skill.md",
              ] else {
            return [.say("System skill references were not mounted correctly."), .stop(.stop)]
        }
        return [.say("System skill references loaded progressively."), .stop(.stop)]
    }

    static let memoryOnDemand = Scenario(name: "memory-on-demand") { ctx in
        guard !ctx.transientContext.contains("transient-memory-must-not-be-injected") else {
            return [.say("Memory was injected into transient context."), .stop(.stop)]
        }
        if ctx.latestUserSaid("current") {
            guard ctx.systemPrompt.contains("current-memory-must-be-injected") else {
                return [.say("Current memory was missing from the system prompt."), .stop(.stop)]
            }
            return [.say("Current memory refreshed in the system prompt."), .stop(.stop)]
        }
        if ctx.resultText("execute") == nil {
            return [
                execute(#"console.log(await ox.fs.read({ path: "MEMORY.md", purpose: "Read memory" }));"#),
                .stop(.toolUse),
            ]
        }
        guard ctx.resultText("execute")?.contains("transient-memory-must-not-be-injected") == true else {
            return [.say("Memory could not be read on demand."), .stop(.stop)]
        }
        return [.say("Memory stayed on disk and loaded on demand."), .stop(.stop)]
    }

    static let appInformation = Scenario(name: "app-information") { ctx in
        guard let output = ctx.resultText("execute") else {
            do {
                try checkAppLogQuery()
            } catch {
                return [.say("App log checks failed: \(error.localizedDescription)"), .stop(.stop)]
            }
            return [execute("""
            const info = await ox.app.info({ purpose: "Read app identity" });
            const profile = await ox.app.profile({ purpose: "Read active Profile" });
            const notifications = await ox.app.notifications({ purpose: "Read notification permission" });
            const language = await ox.app.language({ purpose: "Read language" });
            const theme = await ox.app.theme({ purpose: "Read theme" });
            const voice = await ox.app.voice({ purpose: "Read voice" });
            const model = await ox.app.model({ purpose: "Read model" });
            const assert = (ok, message) => { if (!ok) throw new Error(message); };
            assert(typeof ox.app.inspect === "undefined", "Aggregate inspection must not be callable");
            assert(Object.keys(info).sort().join(",") === "build,name,region,version" && info.name === "Ox" && info.version.length > 0 && info.build.length > 0, "App info must contain identity only");
            assert(profile === null || (Object.keys(profile).sort().join(",") === "name,storage" && profile.name.length > 0 && ["local", "iCloud", "external"].includes(profile.storage)), "Invalid Profile information");
            assert(Object.keys(notifications).join(",") === "status" && ["granted", "denied", "notDetermined"].includes(notifications.status), "Invalid notification permission");
            assert(typeof language.locale === "string" && language.locale.length > 0, "Missing language locale");
            assert(["system", "en", "zh-Hans"].includes(language.selection), "Invalid language selection");
            assert(["creatorPick", "light", "dark"].includes(theme.selection), "Invalid theme selection");
            assert(theme.appearance === (theme.selection === "dark" ? "dark" : "light"), "Incorrect theme appearance");
            assert(voice.selection === null || typeof voice.selection === "string", "Invalid voice selection");
            assert(voice.effective === null || ["id", "name", "language"].every(key => typeof voice.effective[key] === "string" && voice.effective[key].length > 0), "Invalid effective voice");
            for (const [name, options] of [["info", { setup: true }], ["profile", { name: "test" }], ["notifications", { request: true }], ["language", { language: "en" }], ["theme", { theme: "dark" }], ["voice", { voiceId: "test" }], ["model", { modelId: "test" }], ["logs", { limit: 101 }], ["logs", { limit: 1.5 }], ["logs", { level: "fatal" }], ["logs", { since: "yesterday" }]]) {
              let rejected = false;
              try { await ox.app[name]({ ...options, purpose: "Reject invalid input" }); }
              catch { rejected = true; }
              assert(rejected, name + " must reject invalid input");
            }
            console.log(JSON.stringify({ info, profile, notifications, model }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["info"]?.objectValue?["name"]?.stringValue == "Ox",
              let model = result["model"]?.objectValue,
              model["provider"]?.objectValue?["name"]?.stringValue?.isEmpty == false,
              model["model"]?.objectValue?["name"]?.stringValue?.isEmpty == false,
              let authentication = model["authentication"]?.objectValue,
              authentication["status"]?.stringValue != nil,
              authentication["method"]?.stringValue != nil,
              result["notifications"]?.objectValue?["status"]?.stringValue != nil,
              !output.contains("credential"),
              !output.contains("accountLabel"),
              !output.contains("filesystem") else {
            return [.say("App information was incomplete or exposed private configuration."), .stop(.stop)]
        }
        return [.say("Ox read its identity, Profile, notification permission, language, theme, voice, and model without changing settings. Aggregate inspection is removed. Log filtering, limits, and credential redaction passed."), .stop(.stop)]
    }

    private static func checkAppLogQuery() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw RuntimeError.bridge(message) }
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ id: Int, _ level: Logger.Level, _ category: String, _ message: String) -> LogEntry {
            LogEntry(id: id, date: date.addingTimeInterval(Double(id)), level: level, category: category, thread: "test", location: "test", message: message)
        }
        let fixture = [
            entry(0, .info, "Agent", "ordinary event"),
            entry(1, .warning, "Service", "Retry request"),
            entry(2, .error, "Service", "RETRY failed"),
            entry(3, .error, "Network", #"{"api_key":"fixture-private-value","authorization":"Basic fixture-auth","Cookie":"session=fixture-session; csrf=fixture-csrf","client_secret":"fixture-client-secret","token":"fixture-token"}"#),
        ]
        func read(_ options: [String: JSONValue], _ entries: [LogEntry]? = nil) throws -> [String: JSONValue] {
            try AppLogQuery(options: .object(options)).read(entries ?? fixture).objectValue ?? [:]
        }
        let filtered = try read(["level": .string("warning"), "category": .string("Service"), "query": .string("retry"), "since": .string("2023-11-14T22:13:22.000Z")])
        try expect(filtered["entries"]?.arrayValue?.count == 1 && filtered["entries"]?.arrayValue?.first?.objectValue?["message"]?.stringValue == "RETRY failed", "Combined log filters failed")
        let seconds = try read(["since": .string("2023-11-14T22:13:22Z")])
        try expect(seconds["entries"]?.arrayValue?.count == 2, "Whole-second timestamp failed")
        let limited = try read(["limit": .int(1)])
        try expect(limited["entries"]?.arrayValue?.count == 1 && limited["truncated"] == .bool(true), "Log limit failed")
        let clean = try read([:])["entries"]?.jsonString() ?? ""
        try expect(!["fixture-private-value", "fixture-auth", "fixture-session", "fixture-csrf", "fixture-client-secret", "fixture-token"].contains(where: clean.contains), "Credentials escaped log redaction")
        let secretSearch = try read(["query": .string("fixture-private-value")])
        try expect(secretSearch["entries"]?.arrayValue?.isEmpty == true, "Log query searched unredacted credentials")
        let empty = try read([:], [])
        try expect(empty["entries"] == .array([]) && empty["truncated"] == .bool(false) && empty["oldestAvailable"] == .null, "Empty logs failed")
        let large = try read(["limit": .int(100)], (0..<100).map { entry($0, .info, "Agent", String(repeating: "界", count: 3_000)) })
        let largeEntries = large["entries"]?.arrayValue ?? []
        try expect(large["truncated"] == .bool(true) && !largeEntries.isEmpty && largeEntries.count < 100 && largeEntries.allSatisfy { $0.objectValue?["truncated"] == .bool(true) }, "Log byte or message budget failed")
        let invalidOptions: [[String: JSONValue]] = [["limit": .int(0)], ["limit": .int(101)], ["limit": .double(1.5)], ["level": .string("fatal")], ["since": .string("yesterday")], ["since": .string("2023-11-14T22:13:22")], ["query": .null], ["unknown": .bool(true)]]
        for options in invalidOptions {
            var rejected = false
            do { _ = try AppLogQuery(options: .object(options)) } catch { rejected = true }
            try expect(rejected, "Invalid log filter accepted")
        }
    }

    static let appLogs = Scenario(name: "app-logs") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            try {
              const result = await ox.app.logs({ level: "info", category: "Session", query: "Chat.", limit: 3, purpose: "Read diagnostic logs" });
              const valid = result.entries.length > 0 && result.entries.length <= 3 && result.entries.every((entry, index, entries) => entry.category === "Session" && ["info", "warning", "error"].includes(entry.level) && entry.message.toLowerCase().includes("chat.") && (index === 0 || entry.timestamp <= entries[index - 1].timestamp));
              console.log(JSON.stringify({ valid, count: result.entries.length, truncated: result.truncated }));
            } catch (error) {
              console.log(JSON.stringify({ error: String(error) }));
            }
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue else {
            return [.say("App logs returned an invalid result."), .stop(.stop)]
        }
        if result["error"]?.stringValue?.contains("the user declined") == true {
            return [.say("Log access was denied. No logs were returned."), .stop(.stop)]
        }
        guard result["valid"] == .bool(true) else {
            return [.say("App log approval or filtering failed."), .stop(.stop)]
        }
        return [.say("Approved log access returned bounded, filtered diagnostics in newest-first order."), .stop(.stop)]
    }

    static let chatTitle = Scenario(name: "chat-title") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const first = await ox.app.renameChat({ title: "Test concise chat titles", purpose: "Name this chat" });
            const second = await ox.app.renameChat({ title: "Updated chat title purpose", purpose: "Update this chat title" });
            const unchanged = await ox.app.renameChat({ title: "Updated chat title purpose", purpose: "Re-evaluate this chat title" });
            let tooLong;
            try {
              await ox.app.renameChat({ title: "one two three four five six seven eight nine ten eleven", purpose: "Use invalid long title" });
            } catch (error) {
              tooLong = String(error);
            }
            console.log(JSON.stringify({ first, second, unchanged, tooLong }));
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["first"]?.objectValue?["renamed"]?.boolValue == true,
              result["first"]?.objectValue?["title"]?.stringValue == "Test concise chat titles",
              result["second"]?.objectValue?["renamed"]?.boolValue == true,
              result["second"]?.objectValue?["title"]?.stringValue == "Updated chat title purpose",
              result["unchanged"]?.objectValue?["renamed"]?.boolValue == false,
              result["unchanged"]?.objectValue?["title"]?.stringValue == "Updated chat title purpose",
              result["tooLong"]?.stringValue?.contains("at most 10 words") == true else {
            return [.say("Chat title re-evaluation did not update agent-owned titles correctly."), .stop(.stop)]
        }
        return [.say("The chat title updated and remained concise."), .stop(.stop)]
    }

    static let help = Scenario(name: "help") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const schemas = { write: ox.fs.write.help(), fetch: ox.web.fetch.help() };
            const attached = await ox.service.listAttached({ kind: "web", purpose: "List web services" });
            const index = await ox.service.inspect({ domain: "127.0.0.1", purpose: "Inspect service actions" });
            const actions = Object.keys(index.actions).slice(0, 2);
            const service = await ox.service.inspect({ domain: "127.0.0.1", actions, purpose: "Inspect action schemas" });
            const functions = Object.values(ox).flatMap(namespace =>
              Object.values(namespace).filter(value => typeof value === "function")
            );
            const allRequirePurpose = functions.every(fn => fn.help().includes("\\n  purpose: string"));
            console.log({ schemas, attached, index, service, allRequirePurpose });
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue,
              let schemas = result["schemas"]?.objectValue,
              schemas["write"]?.stringValue?.contains("path: string") == true,
              schemas["write"]?.stringValue?.contains("content: string") == true,
              schemas["fetch"]?.stringValue?.contains("url: string") == true,
              schemas["fetch"]?.stringValue?.contains("output: exact object") == true,
              schemas["fetch"]?.stringValue?.contains("\"inputSchema\"") == false,
              result["allRequirePurpose"]?.boolValue == true,
              result["attached"]?.arrayValue?.contains(where: {
                  $0.objectValue?["domain"]?.stringValue == "127.0.0.1"
                      && $0.objectValue?["kind"]?.stringValue == "web"
              }) == true,
              let index = result["index"]?.objectValue?["actions"]?.objectValue,
              !index.isEmpty,
              index.values.allSatisfy({ $0.objectValue?["inputSchema"] == nil }),
              let serviceResult = result["service"]?.objectValue?["actions"]?.objectValue,
              !serviceResult.isEmpty,
              serviceResult.values.allSatisfy({ action in
                  action.objectValue?["inputSchema"] != nil && action.objectValue?["outputSchema"] != nil
              }) else {
            return [.say("Virtual machine help omitted a schema."), .stop(.stop)]
        }
        return [.say("Callable help and service inspection returned complete schemas."), .stop(.stop)]
    }

    static let virtualMachineCancellation = Scenario(name: "virtual-machine-cancel", steps: [
        .say("Waiting inside JavaScript…\n"),
        execute("await new Promise(() => {});"),
    ])

    static let truncatedToolCall = Scenario(name: "truncated-tool") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Attempting an incomplete tool call…\n"),
                execute("console.log(\"TRUNCATED_TOOL_EXECUTED\");"),
                .stop(.length),
            ]
        }
        let result = ctx.resultText("execute") ?? ""
        if result.contains("was not executed"), result.contains("output token limit") {
            return [.say("Truncated tool call was blocked before execution."), .stop(.stop)]
        }
        return [.say("Truncated tool safety check failed: \(result)"), .stop(.stop)]
    }

    static let pendingStopReason = Scenario(name: "pending-stop", steps: [
        .say("This response must not settle successfully."),
        .stop(.pending),
    ])

    static let compaction = Scenario(name: "compaction") { ctx in
        if ctx.turn == 0 {
            if let failure = contextBudgetRegressionFailure() { return [.say(failure), .stop(.stop)] }
            return [
                execute("""
                await ox.fs.read({ path: "skills/system:manage-artifacts/SKILL.md", purpose: "Activate skill before compaction" });
                console.log("EARLY_STEP_" + "A".repeat(50000));
                """),
            ]
        }
        if ctx.userSaid("SPLIT_TURN_CHECKPOINT") || ctx.userSaid("SPLIT_TURN_REPEATED") {
            var pending: Set<String> = []
            var skillRestored = false
            for message in ctx.messages {
                switch message {
                case .user:
                    if !pending.isEmpty { return [.say("Compaction orphaned tool calls."), .stop(.stop)] }
                case .assistant(let assistant):
                    if !pending.isEmpty { return [.say("Compaction separated tool calls and results."), .stop(.stop)] }
                    pending = Set(assistant.content.compactMap { if case .toolCall(let call) = $0 { call.id } else { nil } })
                case .toolResult(let result):
                    guard pending.remove(result.toolCallId) != nil else { return [.say("Compaction orphaned a tool result."), .stop(.stop)] }
                    if result.content.concatenatedText.hasPrefix("EARLY_STEP_") { return [.say("Compaction retained the early tool result."), .stop(.stop)] }
                    skillRestored = skillRestored || result.activatedSkills.contains { $0.path == "skills/system:manage-artifacts/SKILL.md" }
                }
            }
            guard pending.isEmpty, skillRestored, ctx.resultText("execute")?.contains("RECENT_STEP_") == true else {
                return [.say("Compaction lost recent work or activated skills."), .stop(.stop)]
            }
            if ctx.userSaid("SPLIT_TURN_REPEATED") {
                return [.say("Repeated split-turn compaction preserved recent work, tool pairs, and activated skills."), .stop(.stop)]
            }
            return [
                execute("console.log(\"SECOND_RECENT_STEP_\" + \"C\".repeat(50000));"),
                .usage(input: 900_000, output: 32),
                .stop(.toolUse),
            ]
        }
        if ctx.turn == 1 {
            return [
                execute("console.log(\"RECENT_STEP_\" + \"B\".repeat(50000));"),
                .usage(input: 900_000, output: 32),
                .stop(.toolUse),
            ]
        }
        return [.say("The long ongoing turn was not compacted."), .stop(.stop)]
    }

    static let compactionSummary = Scenario(name: "compaction-summary") { ctx in
        if ctx.userSaid("SPLIT_TURN_CHECKPOINT") {
            return [.say("<intent>29</intent> SPLIT_TURN_REPEATED: Earlier progress was summarized again; verify the retained recent step and activated skill."), .stop(.stop)]
        }
        if ctx.messages.contains(where: { if case .toolResult(let result) = $0 { result.content.concatenatedText.hasPrefix("EARLY_STEP_") } else { false } }) {
            guard ctx.latestUserSaid("partway through an ongoing turn") else {
                return [.say("Missing split-turn summarization instructions."), .stop(.stop)]
            }
            return [.say("<intent>29</intent> SPLIT_TURN_CHECKPOINT: The original request is to verify split-turn compaction. The early step completed; recent work is retained separately."), .stop(.stop)]
        }
        return [.say("Earlier conversation state was summarized for the retained turn."), .stop(.stop)]
    }

    static let settledCompaction = Scenario(name: "settled-compaction", steps: [
        .say("The final response settled after compacting its context."),
        .usage(input: 900_000, output: 12),
        .stop(.stop),
    ])

    static let overflowRecovery = Scenario(name: "overflow-recovery") { ctx in
        if ctx.messages.count <= 3 {
            return [.say("Recovered after one context-overflow compaction."), .stop(.stop)]
        }
        return [.usage(input: 990_000, output: 0), .stop(.length)]
    }

    static let overflowFailure = Scenario(name: "overflow-failure", steps: [
        .fail(message: "maximum context length exceeded after retry", reason: .error),
    ])

    private static let revenueDocument = #"""
        <style>body{margin:0;padding:24px;font:17px -apple-system;background:#fff8ef;color:#26180f}.bars{display:flex;align-items:end;gap:14px;height:280px}.bar{flex:1;min-width:0;background:#f28a2e;border-radius:12px 12px 4px 4px;height:calc(var(--value)*10px);transition:.3s}.bar span{display:block;text-align:center;transform:translateY(-24px);font-weight:700}button{margin-top:28px;width:100%;min-height:48px;border:0;border-radius:14px;background:#26180f;color:white;font:inherit;font-weight:700}</style><h1>Quarterly Revenue</h1><div class="bars"><div class="bar" style="--value:10"><span>Q1</span></div><div class="bar" style="--value:15"><span>Q2</span></div><div class="bar" style="--value:12"><span>Q3</span></div><div class="bar" id="q4" data-value="20" style="--value:20"><span>Q4</span></div></div><button id="toggle">Try a projection</button><script>toggle.onclick=()=>{const value=q4.dataset.value==='20'?'24':'20';q4.dataset.value=value;q4.style.setProperty('--value',value);toggle.textContent=value==='24'?'Use actuals':'Try a projection'}</script>
    """#

    static let htmlChart = Scenario(name: "html-chart") { context in
        if context.turn == 0 {
            return [
                .say("Here's the chart you asked for:\n\n"),
                .wait(.seconds(3)),
                execute(htmlArtifact("revenue", revenueDocument)),
                .stop(.toolUse)
            ]
        }
        return [.say("[Open Quarterly Revenue](sandbox:/mnt/data/mock-revenue.html)"), .stop(.stop)]
    }

    static let htmlUpdate = Scenario(name: "html-update") { context in
        if context.turn > 0 { return [.stop(.stop)] }
        return [
            .say("I'll write the updated artifact.\n\n"),
            execute(htmlArtifact(
                "revenue",
                revenueDocument.replacingOccurrences(of: "Quarterly Revenue", with: "Updated Quarterly Revenue")
            )),
            .stop(.toolUse)
        ]
    }

    static let htmlVideo = htmlScenario("video", lead: "A local video artifact:\n\n", document: #"""
    <style>body{margin:0;padding:24px;font:17px -apple-system;background:#fff8ef;color:#26180f}video{width:100%;border-radius:18px;background:#18120e}p{color:#745f50}</style><h1>Video</h1><video controls src="sample.mp4"></video><p>Media is loaded from a sibling artifact and never from the network.</p>
    """#)

    static let htmlAudio = htmlScenario("audio", lead: "A local audio artifact:\n\n", document: #"""
    <style>body{margin:0;padding:24px;font:17px -apple-system;background:#fff8ef;color:#26180f}audio{width:100%}p{color:#745f50}</style><h1>Audio</h1><audio controls src="sample.mp3"></audio><p>Media is loaded from a sibling artifact and never from the network.</p>
    """#)

    static let htmlMap = htmlScenario("map", lead: "A native map snapshot inside HTML:\n\n", document: #"""
    <style>body{margin:0;padding:24px;font:17px -apple-system;background:#fff8ef;color:#26180f}ox-map{display:block}p{color:#745f50}</style><h1>Coffee near you</h1><p>Tap the map to open Maps.</p><ox-map latitude="37.7749" longitude="-122.4194" radius="1600" aria-label="Coffee near San Francisco"><ox-marker latitude="37.7762" longitude="-122.4189" label="Blue Bottle"></ox-marker><ox-marker latitude="37.7724" longitude="-122.4231" label="Sightglass"></ox-marker></ox-map>
    """#)

    private static func htmlScenario(_ name: String, lead: String, document: String) -> Scenario {
        Scenario(name: "html-\(name)") { context in
            if context.turn > 0 { return [.stop(.stop)] }
            return [.say(lead), execute(htmlArtifact(name, document)), .stop(.toolUse)]
        }
    }


    private static func execute(_ source: String) -> Step {
        .tool(name: "execute", args: .object(["source": .string(source)]))
    }

    private static func htmlArtifact(_ id: String, _ document: String) -> String {
        let literal = String(decoding: try! JSONEncoder().encode(document), as: UTF8.self)
        return """
        await ox.fs.write({ path: "artifacts/mock-\(id).html", content: \(literal), purpose: "Create interactive artifact" });
        """
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
        for chunk in s.tokenizedForStreaming() {
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
