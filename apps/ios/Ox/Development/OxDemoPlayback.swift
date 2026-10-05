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
            Your combined memory is ready to review in Ox.

            - **Communication:** concise explanations with practical next steps.
            - **Work:** protect focused mornings and keep a short list of priorities.
            - **Preferences:** keep useful context together and easy to edit.
            """
        case .offline:
            """
            Start with one priority:

            1. Choose a small, concrete first step.
            2. Put your phone aside for a 45-minute focus block.
            3. Check messages after the block.
            """
        case .reddit:
            """
            Reddit is now a reusable service.

            It can **browse posts**, **search discussions**, and **read comments**. These public reads don't require a Reddit sign-in.
            """
        case .reuse:
            """
            Three practical ideas from [r/productivity](https://www.reddit.com/r/productivity/):

            - Choose your first task the night before.
            - Put your phone out of reach.
            - Protect one focus block before opening your inbox.
            """
        default: ""
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
    let composer = ChatComposerModel()
    let speech = ChatSpeechInput()
    let sessionID = UUID()
    let artwork: [String: Data]
    private let catalog: [String: Service]
    private(set) var scene: OxDemoScene
    private(set) var sent = false
    private(set) var reply = ""
    private(set) var isStreaming = false
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
            built[domain] = Service(definition: definition, manager: manager)
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
        }
        serviceCreated = [.reddit, .reuse].contains(scene)
    }

    private func reset(_ scene: OxDemoScene) {
        self.scene = scene
        composer.replaceDraft("")
        sent = false
        reply = ""
        isStreaming = false
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
        try await Task.sleep(for: .milliseconds(800))
        var streamed = ""
        for character in scene.reply {
            try await Task.sleep(for: .milliseconds(14))
            streamed.append(character)
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
