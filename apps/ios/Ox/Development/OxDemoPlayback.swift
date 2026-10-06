#if DEBUG
import SwiftUI
import Observation

nonisolated enum OxDemoChapter: String {
    case connect = "Connect anything"
    case local = "Local first"
    case yours = "Yours"

    var symbol: String {
        switch self {
        case .connect: "hammer"
        case .local: "chevron.left.forwardslash.chevron.right"
        case .yours: "hand.raised"
        }
    }
    var description: String {
        switch self {
        case .connect: "Ox works across AI assistants, apps, and websites to get things done for you."
        case .local: "Ox runs on your device, keeping your conversations, credentials, and memory stored locally."
        case .yours: "Open source and malleable, Ox evolves with you and uses the models you choose."
        }
    }
}

nonisolated enum OxDemoScene: String, CaseIterable, Identifiable {
    case connect, memory, research, jobs, local, offline, yours, providers, reddit, reuse

    var id: String { rawValue }
    var chapter: OxDemoChapter {
        switch self {
        case .connect, .memory, .research, .jobs: .connect
        case .local, .offline: .local
        case .yours, .providers, .reddit, .reuse: .yours
        }
    }
    var isHeading: Bool { [.connect, .local, .yours].contains(self) }
    var prompt: String {
        switch self {
        case .memory: "Import all of my memory into Ox."
        case .research: "Do deep research on stock trading tips across my assistants."
        case .jobs: "What are the best job opportunities for me?"
        case .offline: "Help me plan a focused morning."
        case .reddit: "Find Reddit discussions about focused mornings, and create a reusable Reddit service as you go."
        case .reuse: "Find Reddit tips for focused mornings."
        default: ""
        }
    }
    var domains: [String] {
        switch self {
        case .memory: ["chatgpt.com", "claude.ai", "muse.ai"]
        case .research: ["manus.im", "doubao.com", "grok.com"]
        case .jobs: ["outlook.live.com", "linkedin.com", "www.1point3acres.com"]
        case .reuse: ["reddit.com"]
        default: []
        }
    }
    var reply: String {
        switch self {
        case .memory:
            """
            Imported what ChatGPT, Claude, and Muse exposed; merged overlapping preferences into Ox memory.

            - **ChatGPT:** concise answers, with trade-offs up front.
            - **Claude:** Swift and TypeScript examples; small, reviewable changes.
            - **Muse:** protect the first morning focus block.

            This isn't a complete export of private memory stores. Source labels are kept so you can review the merge.
            """
        case .offline:
            """
            Protect one hour, rather than planning the entire morning.

            1. **9:00–9:05:** Choose one task and define what “done” means.
            2. **9:05–9:50:** Silence notifications and work only on that task.
            3. **9:50–10:00:** Note the next step, then check messages.

            If you get interrupted, return to the same task instead of restarting the plan.
            """
        case .reddit:
            """
            Created **Reddit** in Local and checked its search and comment-reading actions.

            Start with [r/productivity](https://www.reddit.com/r/productivity/) for distractions and protecting your first work block, or [r/GetDisciplined](https://www.reddit.com/r/GetDisciplined/) for routines that are easier to repeat.

            The service is attached. I'll use it for the next search. These public reads don't need a Reddit sign-in.
            """
        case .reuse:
            """
            A recurring theme in [r/productivity](https://www.reddit.com/r/productivity/): make starting easier instead of adding more rules.

            - Pick one concrete first task the night before.
            - Keep your phone outside the workspace until the first break.
            - Check messages after a 45-minute block, not before.

            Try the first two tomorrow. Measure whether you started on time, not whether the morning was perfect.
            """
        default: ""
        }
    }

    var progress: [String] {
        switch self {
        case .memory:
            ["Reading preferences exposed by ChatGPT, Claude, and Muse",
             "Merging overlaps and preserving source labels",
             "Saving the combined notes to Ox memory"]
        case .reddit:
            ["Checking Reddit's pages and available reads",
             "Building reusable search and comment-reading actions",
             "Checking the saved service with a public search"]
        case .reuse:
            ["Searching discussions about focused mornings",
             "Reading comments and comparing practical suggestions"]
        default: []
        }
    }
}

nonisolated enum OxDemoLaunch {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["OX_DEMO"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--ox-demo")
    }
    static var scene: OxDemoScene {
        OxDemoScene(rawValue: ProcessInfo.processInfo.environment["OX_DEMO_SCENE"] ?? "") ?? .connect
    }
    static var completed: Bool { ProcessInfo.processInfo.environment["OX_DEMO_COMPLETE"] == "1" }
    static var autoplay: Bool { ProcessInfo.processInfo.environment["OX_DEMO_AUTOPLAY"] == "1" }
}

/// In-memory presentation fixtures. Never prepares a Host, checks service access, or calls a model.
@MainActor
@Observable
final class OxDemoPlayback {
    let services: ServiceManager
    let composer = ConversationComposerModel()
    let speech = ConversationSpeechInput()
    let sessionID = UUID()
    let artwork: [String: Data]
    private let catalog: [String: Service]
    private(set) var scene: OxDemoScene
    private(set) var sent = false
    private(set) var reply = ""
    private(set) var isStreaming = false
    private(set) var thinking: ThinkingTrace?
    private(set) var thinkingStartedAt = Date()
    private(set) var serviceCreated = false
    var focusComposer = false
    var selectedProvider: String? = "chatgpt"
    @ObservationIgnored private var task: Task<Void, Never>?

    init(scene: OxDemoScene = .connect, completed: Bool = false) {
        self.scene = scene
        let manager = ServiceManager()
        services = manager
        let names = [
            "chatgpt.com": "ChatGPT", "claude.ai": "Claude", "muse.ai": "Muse",
            "manus.im": "Manus", "doubao.com": "Doubao", "grok.com": "Grok",
            "outlook.live.com": "Outlook", "linkedin.com": "LinkedIn",
            "www.1point3acres.com": "1Point3Acres", "reddit.com": "Reddit",
        ]
        var built: [String: Service] = [:]
        for (domain, name) in names {
            let definition = try! ServiceDefinition(manifest: .object([
                "domain": .string(domain), "name": .string(name),
                "baseUrl": .string("https://\(domain)"), "actions": .array([]),
            ]))
            let service = Service(definition: definition, manager: manager)
            service.setAuth(domain == "reddit.com" ? .notRequired : .observed(.init(
                value: .signedIn, observedAt: .distantPast, evidence: .configured
            )))
            built[domain] = service
        }
        catalog = built
        let bundle = Bundle.main.url(forResource: "OxDemoArtwork", withExtension: "bundle")
        artwork = Dictionary(uniqueKeysWithValues: (Array(names.keys) + ["github.com", "www.kimi.com", "gemini.google.com", "qwen.ai"]).compactMap { domain in
            guard let url = bundle?.appendingPathComponent("\(domain).png"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (domain, data)
        })
        Log.ui.info("Demo.fixture initialized artwork=\(artwork.count) liveRequests=false")
        if completed { showCompletedScene() }
    }

    var attachedServices: [Service] {
        (scene.domains + (scene == .reddit && serviceCreated ? ["reddit.com"] : [])).compactMap { catalog[$0] }
    }

    func select(_ scene: OxDemoScene) {
        stop()
        reset(scene)
    }

    func stop() {
        task?.cancel()
        task = nil
        focusComposer = false
        isStreaming = false
        if thinking != nil { thinking?.completedAt = Date() }
    }

    func play(reduceMotion: Bool) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let scenes = OxDemoScene.allCases
                let start = scenes.firstIndex(of: scene) ?? 0
                for next in scenes[start...] {
                    try Task.checkCancellation()
                    await animate(reduceMotion: reduceMotion) { self.reset(next) }
                    Log.ui.info("Demo.scene start scene=\(next.rawValue) liveRequests=false")
                    try await perform(reduceMotion: reduceMotion)
                }
                task = nil
            } catch is CancellationError {
                Log.ui.info("Demo.playback cancelled")
            } catch {
                Log.ui.error("Demo.playback failed error=\(error.localizedDescription)")
            }
        }
    }

    func showCompletedScene() {
        stop()
        composer.replaceDraft("")
        if [.research, .jobs].contains(scene) {
            composer.replaceDraft(scene.prompt)
        } else if !scene.prompt.isEmpty {
            sent = true
            reply = scene.reply
            if !scene.progress.isEmpty {
                let now = Date()
                thinkingStartedAt = now.addingTimeInterval(-Double(scene.progress.count) * 1.6)
                thinking = ThinkingTrace(
                    entries: scene.progress.map { .reasoning(Reasoning(text: $0)) },
                    completedAt: now
                )
            }
        }
        serviceCreated = [.reddit, .reuse].contains(scene)
    }

    private func reset(_ scene: OxDemoScene) {
        self.scene = scene
        composer.replaceDraft("")
        sent = false
        reply = ""
        isStreaming = false
        thinking = nil
        serviceCreated = false
        focusComposer = false
    }

    private func perform(reduceMotion: Bool) async throws {
        if scene.isHeading || scene == .providers {
            try await Task.sleep(for: .milliseconds(scene.isHeading ? 3200 : 4500))
            return
        }
        if scene == .offline {
            // Present existing messages immediately; no simulated radio switch or offline generation.
            sent = true
            reply = scene.reply
            try await Task.sleep(for: .seconds(5))
            return
        }
        focusComposer = true
        try await Task.sleep(for: .milliseconds(900))
        var typed = ""
        for character in scene.prompt {
            try await Task.sleep(for: .milliseconds(38))
            typed.append(character)
            composer.replaceDraft(typed)
        }
        try await Task.sleep(for: .milliseconds(1300))
        if [.research, .jobs].contains(scene) { return }
        await animate(reduceMotion: reduceMotion) {
            self.focusComposer = false
            self.composer.replaceDraft("")
            self.sent = true
        }
        isStreaming = true
        if !scene.progress.isEmpty {
            thinkingStartedAt = Date()
            thinking = ThinkingTrace(entries: [], completedAt: nil)
            for label in scene.progress {
                thinking?.entries.append(.reasoning(Reasoning(text: label)))
                try await Task.sleep(for: .milliseconds(1600))
            }
            thinking?.completedAt = Date()
        }
        try await Task.sleep(for: .milliseconds(500))
        var streamed = ""
        for (index, word) in scene.reply.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            try await Task.sleep(for: .milliseconds(word.contains("\n") ? 220 : index.isMultiple(of: 5) ? 180 : 65))
            if index > 0 { streamed.append(" ") }
            streamed.append(contentsOf: word)
            reply = streamed
        }
        isStreaming = false
        if scene == .reddit { serviceCreated = true }
        try await Task.sleep(for: .milliseconds(2300))
    }

    private func animate(reduceMotion: Bool, updates: () -> Void) async {
        await withCheckedContinuation { continuation in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0), completionCriteria: .logicallyComplete) {
                updates()
            } completion: {
                continuation.resume()
            }
        }
    }
}
#endif
