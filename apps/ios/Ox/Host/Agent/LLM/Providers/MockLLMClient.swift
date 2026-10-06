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
            Entry("24", "choice — yes/no gate (branches)", .binaryChoiceFlow),
            Entry("25", "choice — pick-one gate (branches)", .choiceFlow),
            Entry("26", "virtual machine cancel — stop pending JavaScript", .virtualMachineCancellation),
            Entry("27", "truncated tool — reject incomplete arguments", .truncatedToolCall),
            Entry("28", "pending stop — reject missing terminal reason", .pendingStopReason),
            Entry("29", "compaction — estimate, isolate, and summarize", .compaction),
        ]),
        ("Artifacts & handoffs", [
            Entry("30", "chart — inline JavaScript", .htmlChart),
            Entry("50", "signin — auth card → resume after sign-in", .signin),
            Entry("53", "recover — tool error, then fall back", .recover),
            Entry("58", "artifact — write, edit, rename, and present", .artifactWorkflow),
            Entry("69", "solve — human-verification handoff", .botControl),
            Entry("74", "progress — report, continue thinking, then answer", .progressReport),
            Entry("75", "shoveler — display non-interactive cards", .shoveler),
            Entry("76", "video — display inline artifact video", .video),
            Entry("77", "payment — user-controlled checkout", .payment),
        ]),
        ("Context & diagnostics", [
            Entry("66", "final context — defer compaction until another request", .deferredCompaction),
            Entry("67", "overflow recovery — compact and retry once", .overflowRecovery),
            Entry("68", "overflow failure — stop after one retry", .overflowFailure),
            Entry("71", "rate limit — normalize provider quota errors", .rateLimited),
            Entry("72", "prompt context — unified skills and current service and artifact state", .skillCatalog),
            Entry("73", "memory — freeze prompt context and read updates on demand", .memoryOnDemand),
            Entry("78", "URL context — annotate user and tool URLs with related services", .urlServiceContext),
            Entry("80", "app information — read app identity and current model", .appInformation),
            Entry("90", "app logs — approve or deny diagnostic access", .appLogs),
        ]),
    ]

    public static var defaultLibrary: [String: Scenario] {
        var library = Dictionary(uniqueKeysWithValues: catalog.flatMap(\.entries).map { ($0.number, $0.scenario) })
        library["72 guidance"] = skillCatalog
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

    static let fastStream = Scenario(name: "faststream", steps: [
        .say(streamingMarkdown),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(0))

    static let characterStream = Scenario(name: "characterstream", steps: [
        .say("The opening phrase is almost full: extraordinaryphenomenon arrives next."),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(80)).characterStreaming()

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
            .say("You'll need to sign in first — use the sign-in card in this chat.\n"),
            execute("console.log(await ox.service.signIn({ domain: \"\(domain)\", purpose: \"Sign in to service\" }));"),
        ]
    }

    static let botControl = Scenario(name: "bot-control") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [.say("Verification completed."), .stop(.stop)]
        }
        let domain = "archive.ph"
        return [
            .say("Complete the human-verification card in this chat.\n"),
            execute("await ox.service.solve({ domain: \"\(domain)\", args: { url: \"https://example.com/\" }, purpose: \"Complete verification\" }); console.log({ verified: true });"),
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
            .say("Review and complete checkout using the payment card in this chat.\n"),
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

    static let artifactWorkflow = Scenario(name: "artifact") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            await ox.fs.write({ path: "artifacts/agent-note.md", content: '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><text x="8" y="26">Hello</text></svg>', purpose: "Create agent note" });
            await ox.fs.edit({ path: "artifacts/agent-note.md", edits: [{ oldText: "Hello", newText: "Hello, Ox!" }], purpose: "Edit agent note" });
            await ox.artifact.rename({ filename: "agent-note.md", newFilename: "agent-image.svg", purpose: "Rename agent note" });
            console.log((await ox.fs.read({ path: "artifacts/agent-image.svg", purpose: "Read agent image" })).text);
            """)]
        }
        guard ctx.toolResults.last?.isError == false,
              let text = ctx.resultText("execute"), text.contains("Hello, Ox!") else {
            return [.say("The artifact workflow failed."), .stop(.stop)]
        }
        return [.say("The finished artifact contains **Hello, Ox!** in agent-image.svg."), .stop(.stop)]
    }

    static let skillCatalog = Scenario(name: "skill-catalog") { ctx in
        let userSkill = "- `skills/grocery-planner/SKILL.md` — Plan a weekly grocery list from meals, dietary needs, and pantry items."
        let expectsService = ctx.latestUserSaid("attached")
        let expectsUserSkill = ctx.latestUserSaid("user")
        let verifiesStablePrefix = ctx.latestUserSaid("cache")
        let activatesUserSkill = ctx.latestUserSaid("activate")
        let hasStableGuidance = BuiltInGuidance.names.allSatisfy {
            ctx.systemPrompt.contains("guidance/\($0)/guide.md") && !ctx.transientContext.contains("skills/\($0)/SKILL.md")
        }
        let hasTimestamp = ctx.serializedUserText
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.hasPrefix("[") && $0.hasSuffix(" \(TimeZone.autoupdatingCurrent.identifier)]") }
            == true
        let hasTurnStateAfterTimestamp = ctx.serializedUserText.contains("\n\n<turn-state>\n")
        let hasServiceSkill = ctx.transientContext.contains("## Attached Services")
        let retainedServiceState = ctx.priorUserContext(containing: "attached")
            .map { $0.contains("## Attached Services") } == true
        let artifactPaths = ctx.messages.flatMap { message -> [String] in
            let content = switch message {
            case .user(let value): value.content
            case .assistant(let value): value.content
            case .toolResult(let value): value.content
            }
            return content.compactMap { block in
                guard case .attachment(let artifact) = block else { return nil }
                return "artifacts/\(artifact.fileName)"
            }
        }
        let hasArtifactState = artifactPaths.isEmpty
            || ctx.transientContext.contains("## Chat Artifacts")
                && artifactPaths.allSatisfy { ctx.transientContext.contains("`\($0)`") }
        guard let languageDirective = try? ModelPromptRenderer.shared.render(.responseDirective, input: AppLocale.resolvedResponseLanguage) else {
            return [.say("Response language could not be rendered."), .stop(.stop)]
        }
        guard ctx.transientContext.contains(userSkill) == expectsUserSkill,
              !ctx.systemPrompt.contains("## Language"),
              !ctx.systemPrompt.contains(userSkill),
              ctx.transientContext.contains("## Language") == !languageDirective.isEmpty,
              (languageDirective.isEmpty || ctx.transientContext.contains(languageDirective)),
              !ctx.transientContext.contains("User slash commands:"),
              !ctx.transientContext.contains("System skills:"),
              !ctx.transientContext.contains("127.0.0.1:delayedEcho"),
              hasStableGuidance,
              hasTimestamp,
              hasTurnStateAfterTimestamp,
              !verifiesStablePrefix || retainedServiceState,
              hasArtifactState,
              hasServiceSkill == expectsService else {
            return [.say("Skill catalog context was incorrect."), .stop(.stop)]
        }
        if ctx.latestUserSaid("guidance") {
            guard let result = ctx.toolResults.last else {
                return [execute("""
                const files = await ox.fs.glob({ path: "guidance", pattern: "**/guide.md", purpose: "Find built-in guidance" });
                const guide = await ox.fs.read({ path: "guidance/manage-skills/guide.md", purpose: "Read built-in guidance" });
                const references = await ox.fs.list({ path: "guidance/manage-skills/references", purpose: "List guidance references" });
                console.log({ count: files.paths.length, guide: guide.text.includes("# Manage Skills"), references: references.items.length });
                """), .stop(.toolUse)]
            }
            guard !result.isError, result.activatedSkills.isEmpty,
                  let text = ctx.resultText("execute"), let values = JSONValue.parse(jsonString: text)?.objectValue,
                  values["count"]?.intValue == 5, values["guide"]?.boolValue == true, values["references"]?.intValue == 2 else {
                return [.say("Built-in guidance context was incorrect."), .stop(.stop)]
            }
            return [.say("Built-in guidance loaded without activating a skill."), .stop(.stop)]
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

    static let memoryOnDemand = Scenario(name: "memory-on-demand") { ctx in
        guard !ctx.transientContext.contains("transient-memory-must-not-be-injected") else {
            return [.say("Memory was injected into transient context."), .stop(.stop)]
        }
        if ctx.latestUserSaid("current") {
            guard !ctx.systemPrompt.contains("current-memory-must-be-injected") else {
                return [.say("Current memory replaced the frozen system-prompt snapshot."), .stop(.stop)]
            }
            if ctx.resultText("execute") == nil {
                return [
                    execute(#"console.log(await ox.fs.read({ path: "MEMORY.md", purpose: "Read current memory" }));"#),
                    .stop(.toolUse),
                ]
            }
            guard ctx.resultText("execute")?.contains("current-memory-must-be-injected") == true else {
                return [.say("Current memory could not be read on demand."), .stop(.stop)]
            }
            return [.say("Memory stayed frozen in the system prompt and current memory remained available on demand."), .stop(.stop)]
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
            return [execute("""
            const info = await ox.app.info({ purpose: "Read app identity" });
            const model = await ox.app.model({ purpose: "Read current model" });
            console.log({ info, model });
            """)]
        }
        guard ctx.toolResults.last?.isError == false,
              let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["info"]?.objectValue?["name"]?.stringValue == "Ox",
              result["model"]?.objectValue?["model"]?.objectValue?["name"]?.stringValue?.isEmpty == false else {
            return [.say("App information could not be read."), .stop(.stop)]
        }
        return [.say("App information ready: \(output)"), .stop(.stop)]
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
            return [
                execute("""
                await ox.fs.read({ path: "skills/visualize/SKILL.md", purpose: "Activate skill before compaction" });
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
                    skillRestored = skillRestored || result.activatedSkills.contains { $0.path == "skills/visualize/SKILL.md" }
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
        if ctx.latestUserSaid("EARLY_STEP_") {
            return [.say("<intent>29</intent> SPLIT_TURN_CHECKPOINT: The original request is to verify split-turn compaction. The early step completed; recent work is retained separately."), .stop(.stop)]
        }
        return [.say("Earlier conversation state was summarized for the retained turn."), .stop(.stop)]
    }

    static let deferredCompaction = Scenario(name: "deferred-compaction", steps: [
        .say("The final response settled without starting another compaction."),
        .usage(input: 900_000, output: 12),
        .stop(.stop),
    ])

    static let overflowRecovery = Scenario(name: "overflow-recovery") { ctx in
        if ctx.messages.count <= 3 {
            return [.say("Recovered after one context-overflow compaction."), .stop(.stop)]
        }
        return [.say("This reply ran out of context and was cut off mid"), .usage(input: 995_000, output: 4_000), .stop(.length)]
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
