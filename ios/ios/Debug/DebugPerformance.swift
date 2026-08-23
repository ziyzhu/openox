#if targetEnvironment(simulator)
import Foundation

enum DebugPerformance {
    struct ChatFixture {
        let meta: ChatMeta
        let turns: [Turn]
    }

    struct ProjectionResult: Encodable {
        let name: String
        let turns: Int
        let blocks: Int
        let samplesMs: [Double]
        let medianMs: Double
    }

    struct SearchResult: Encodable {
        let rebuildSamplesMs: [Double]
        let exactSamplesMs: [Double]
        let prefixSamplesMs: [Double]
        let missSamplesMs: [Double]
    }

    struct Snapshot: Encodable {
        let projections: [ProjectionResult]
        let search: SearchResult
        let websiteDataSites: [String: String]
        let renderedTranscript: DebugTranscriptPerformance.Snapshot
    }

    static func snapshot() async -> Snapshot {
        requireSendable(Turn.self)
        requireSendable(ProfileScope.self)
        requireSendable(ServiceRepository.ManifestFile.self)
        requireSendable(ServiceRepository.Source.self)
        requireSendable(ChatState.self)
        requireSendable(ChatLoadResult.self)
        requireSendable(ChatSaveRequest.self)
        requireSendable(ChatSaveReceipt.self)
        async let search = searchBenchmark()
        let projections = [
            projection(name: "short", turns: 4, textLength: 240),
            projection(name: "medium", turns: 40, textLength: 600),
            projection(name: "long", turns: 200, textLength: 1200)
        ]
        return await Snapshot(
            projections: projections,
            search: search,
            websiteDataSites: [
                "secure.chase.com": ServiceManager.websiteDataSite(for: "secure.chase.com"),
                "www.example.co.uk": ServiceManager.websiteDataSite(for: "www.example.co.uk"),
                "foo.github.io": ServiceManager.websiteDataSite(for: "foo.github.io"),
                "127.0.0.1": ServiceManager.websiteDataSite(for: "127.0.0.1")
            ],
            renderedTranscript: DebugTranscriptPerformance.snapshot()
        )
    }

    private static func requireSendable<T: Sendable>(_: T.Type) {}

    static func chats(count: Int) -> [ChatFixture] {
        (0..<max(0, count)).map { chat(seed: $0, turns: 24, textLength: 600) }
    }

    static func renderedTranscript(turns: Int) -> ChatFixture? {
        guard turns == 200 || turns == 400 else { return nil }
        return chat(seed: 10_000 + turns, turns: turns / 2, textLength: 600)
    }

    private static func projection(name: String, turns: Int, textLength: Int) -> ProjectionResult {
        let fixture = chat(seed: turns, turns: turns, textLength: textLength)
        var samples: [Double] = []
        var blocks = 0
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            blocks = ChatProjection.render(fixture.turns).count
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            samples.append(Double(elapsed) / 1_000_000)
        }
        return ProjectionResult(
            name: name,
            turns: fixture.turns.count,
            blocks: blocks,
            samplesMs: samples,
            medianMs: median(samples)
        )
    }

    private static func chat(seed: Int, turns: Int, textLength: Int) -> ChatFixture {
        let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(seed))
        let text = String(repeating: "baseline projection text ", count: max(1, textLength / 25))
        var chatTurns: [Turn] = []
        for index in 0..<turns {
            let at = createdAt.addingTimeInterval(Double(index * 2))
            chatTurns.append(.user(UserTurn(intent: "fixture \(seed)-\(index)", attachments: [], at: at)))
            let generationID = AgentGenerationID()
            var steps: [Step] = [
                Step(generation: generationID, kind: .reasoning("Inspect fixture \(index). Compare the stable projection.")),
                Step(generation: generationID, kind: .text(String(text.prefix(textLength))))
            ]
            if index.isMultiple(of: 5) {
                steps.append(Step(generation: generationID, kind: .confirm(AgentPrompt(
                    prompt: "Continue fixture \(index)?",
                    options: ["Yes", "No"],
                    outcome: .answered(answer: "Yes", resolution: "Continued")
                ))))
            }
            let agentAt = at.addingTimeInterval(1)
            let outcome = TurnOutcome.completed(at: agentAt)
            chatTurns.append(.agent(AgentTurn(
                at: agentAt,
                generations: [ModelGeneration(id: generationID, at: agentAt, model: "mock", outcome: outcome)],
                steps: steps,
                outcome: outcome
            )))
        }
        let meta = ChatMeta(
            id: StableID.uuid("baseline.\(seed)"),
            createdAt: createdAt,
            lastActivity: chatTurns.last?.at,
            title: "Baseline \(seed)",
            isFavorite: false,
            modelID: "mock",
            clientID: "mock",
            monoRepositoryHash: nil,
            attachedServiceDomains: [],
            preview: "fixture \(seed)-0"
        )
        return ChatFixture(meta: meta, turns: chatTurns)
    }

    private static func searchBenchmark() async -> SearchResult {
        let fixtures = serviceFixtures()
        var rebuild: [Double] = []
        var exact: [Double] = []
        var prefix: [Double] = []
        var miss: [Double] = []
        for _ in 0..<5 {
            let index = ServiceSearchIndex()
            rebuild.append(await measure { _ = await index.rebuildLexical(from: fixtures, locale: "en") })
            exact.append(await measure { _ = await index.search("Echo fixture value") })
            prefix.append(await measure { _ = await index.search("ech") })
            miss.append(await measure { _ = await index.search("zzzxxyy no service") })
        }
        return SearchResult(
            rebuildSamplesMs: rebuild,
            exactSamplesMs: exact,
            prefixSamplesMs: prefix,
            missSamplesMs: miss
        )
    }

    private static func serviceFixtures() -> [ServiceDefinition] {
        (0..<24).map { index in
            let domain = "fixture\(index).example"
            return try! ServiceDefinition(manifest: .object([
                "domain": .string(domain),
                "name": .string("Fixture Service \(index)"),
                "description": .string("Deterministic catalog benchmark service"),
                "baseUrl": .string("https://\(domain)"),
                "actions": .array([
                    .object([
                        "id": .string("echo"),
                        "label": .string("Echo fixture value"),
                        "description": .string("Return a deterministic fixture value"),
                        "inputSchema": .object(["type": .string("object")]),
                        "outputSchema": .object(["type": .string("object")])
                    ]),
                    .object([
                        "id": .string("search"),
                        "label": .string("Search fixture records"),
                        "description": .string("Find deterministic benchmark records"),
                        "inputSchema": .object(["type": .string("object")]),
                        "outputSchema": .object(["type": .string("object")])
                    ])
                ])
            ]))
        }
    }

    private static func measure(_ operation: () async -> Void) async -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        await operation()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

@MainActor
enum DebugTranscriptPerformance {
    struct Snapshot: Encodable {
        let chatID: String?
        let requestedTurns: Int
        let totalTurns: Int
        let totalBlocks: Int
        let selectedRangeStart: Int
        let selectedRangeEnd: Int
        let renderedHistoricalBlocks: Int
        let loadedEarlierBlocks: Int
        let windowShiftCount: Int
        let windowShiftDirection: String?
        let blockViewBodies: Int
        let selectableTextViews: Int
        let windowMode: String
        let anchor: String?
        let pendingWindowOwner: String?
    }

    private static var chatID: UUID?
    private static var requestedTurns = 0
    private static var totalTurns = 0
    private static var totalBlocks = 0
    private static var selectedRangeStart = 0
    private static var selectedRangeEnd = 0
    private static var renderedHistoricalBlocks = 0
    private static var loadedEarlierBlocks = 0
    private static var windowShiftCount = 0
    private static var windowShiftDirection: String?
    private static var blockViewBodies = 0
    private static var selectableTextViews = 0
    private static var windowMode = "unbounded"
    private static var anchor: UUID?
    private static var pendingWindowOwner: String?

    static func begin(chatID: UUID, requestedTurns: Int, totalTurns: Int, totalBlocks: Int) {
        self.chatID = chatID
        self.requestedTurns = requestedTurns
        self.totalTurns = totalTurns
        self.totalBlocks = totalBlocks
        selectedRangeStart = 0
        selectedRangeEnd = 0
        renderedHistoricalBlocks = 0
        loadedEarlierBlocks = 0
        windowShiftCount = 0
        windowShiftDirection = nil
        blockViewBodies = 0
        selectableTextViews = 0
        windowMode = "unbounded"
        anchor = nil
        pendingWindowOwner = nil
    }

    static func recordTranscript(
        chatID: UUID,
        totalBlocks: Int,
        selectedRange: Range<Int>,
        renderedBlocks: Int,
        loadedEarlierBlocks: Int,
        windowShiftCount: Int,
        windowShiftDirection: String?,
        windowMode: String,
        anchor: UUID?,
        pendingWindowOwner: String?
    ) {
        guard self.chatID == chatID else { return }
        self.totalBlocks = totalBlocks
        selectedRangeStart = selectedRange.lowerBound
        selectedRangeEnd = selectedRange.upperBound
        renderedHistoricalBlocks = renderedBlocks
        self.loadedEarlierBlocks = loadedEarlierBlocks
        self.windowShiftCount = windowShiftCount
        self.windowShiftDirection = windowShiftDirection
        self.windowMode = windowMode
        self.anchor = anchor
        self.pendingWindowOwner = pendingWindowOwner
    }

    static func recordBlockViewBody(chatID: UUID) {
        guard self.chatID == chatID else { return }
        blockViewBodies += 1
    }

    static func recordSelectableTextView() {
        guard chatID != nil else { return }
        selectableTextViews += 1
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            chatID: chatID?.uuidString,
            requestedTurns: requestedTurns,
            totalTurns: totalTurns,
            totalBlocks: totalBlocks,
            selectedRangeStart: selectedRangeStart,
            selectedRangeEnd: selectedRangeEnd,
            renderedHistoricalBlocks: renderedHistoricalBlocks,
            loadedEarlierBlocks: loadedEarlierBlocks,
            windowShiftCount: windowShiftCount,
            windowShiftDirection: windowShiftDirection,
            blockViewBodies: blockViewBodies,
            selectableTextViews: selectableTextViews,
            windowMode: windowMode,
            anchor: anchor?.uuidString,
            pendingWindowOwner: pendingWindowOwner
        )
    }
}
#endif
