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
    case connect, memory, planning, publishing, local, offline, yours, providers, reddit, reuse

    var id: String { rawValue }
    var chapter: OxDemoChapter {
        switch self {
        case .connect, .memory, .planning, .publishing: .connect
        case .local, .offline: .local
        case .yours, .providers, .reddit, .reuse: .yours
        }
    }
    var isHeading: Bool { [.connect, .local, .yours].contains(self) }
    var prompt: String {
        switch self {
        case .memory: "Import my memory from ChatGPT, Claude, and Muse into Ox, and merge duplicates."
        case .planning: "Email Alex that the release is ready, schedule a review tomorrow at 10, and add a prep reminder at 9."
        case .publishing: "Open a pull request for feature/checklist in my demo repo, email Alex the link, and add a review reminder."
        case .offline: "Add a reminder for tomorrow at 9 to start a 45-minute focus block."
        case .reddit: "Create a reusable Reddit service that can publish posts and reply to comments."
        case .reuse: "Post my morning routine to my Reddit profile using the new service."
        default: ""
        }
    }
    var domains: [String] {
        switch self {
        case .memory: ["chatgpt.com", "claude.ai", "muse.ai"]
        case .planning: ["mail.google.com", "ios:calendar", "ios:reminders"]
        case .publishing: ["github.com", "mail.google.com", "ios:reminders"]
        case .offline: ["ios:reminders"]
        case .reuse: ["reddit.com"]
        default: []
        }
    }
    var reply: String {
        switch self {
        case .memory:
            """
            Imported the available memory from ChatGPT, Claude, and Muse, merged duplicates, and saved it in Ox.

            - **ChatGPT:** concise answers, with trade-offs up front.
            - **Claude:** Swift and TypeScript examples; small, reviewable changes.
            - **Muse:** protect the first morning focus block.

            This isn't a complete export of private memory stores. Source labels are kept so you can review the merge.
            """
        case .planning:
            """
            Done — the release review is set up.

            - **Gmail:** sent Alex “Release ready.”
            - **Calendar:** created “Release review,” tomorrow **10:00–10:30 AM**.
            - **Reminders:** added “Prepare release review,” due **9:00 AM**.

            The email includes the review time.
            """
        case .publishing:
            """
            Opened **Add morning checklist** from `feature/checklist` into `main` in your demo repository.

            - **GitHub:** pull request created.
            - **Gmail:** sent Alex the pull request link.
            - **Reminders:** added “Review morning checklist,” due tomorrow.

            The branch has not been merged.
            """
        case .offline:
            """
            Added **Morning focus block** to Reminders, due tomorrow at **9:00 AM**.

            The reminder includes these notes:

            - Choose one task before starting.
            - Silence notifications for 45 minutes.
            - Write down the next step before checking messages.
            """
        case .reddit:
            """
            Created **Reddit** in Local with **publish post** and **reply to comment** actions.

            Both write actions require your approval and a signed-in Reddit session.

            The service passed validation and is attached, ready to publish your morning routine.
            """
        case .reuse:
            """
            Published **My focused-morning routine** to your Reddit profile using the new service.

            The post includes:

            - Choose the first task the night before.
            - Start a 45-minute focus block at 9:00 AM.
            - Keep the phone out of reach until the first break.

            The reusable service handled publishing; no manual copy-and-paste was needed.
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
        case .planning:
            ["Sending the release email in Gmail",
             "Creating the review in Calendar",
             "Adding the preparation reminder"]
        case .publishing:
            ["Opening the checklist pull request in GitHub",
             "Sending Alex the pull request link",
             "Adding a review reminder"]
        case .reddit:
            ["Inspecting Reddit's post and comment forms",
             "Building reusable publishing and reply actions",
             "Validating the service and saving it in Local"]
        case .reuse:
            ["Preparing the morning-routine post",
             "Publishing through the saved Reddit service"]
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
    enum Presentation { case storyboard, appStore }

    private let presentation: Presentation
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

    init(scene: OxDemoScene = .connect, completed: Bool = false, presentation: Presentation = .storyboard) {
        self.scene = scene
        self.presentation = presentation
        let manager = ServiceManager()
        services = manager
        let names = [
            "chatgpt.com": "ChatGPT", "claude.ai": "Claude", "muse.ai": "Muse",
            "manus.im": "Manus", "doubao.com": "Doubao", "grok.com": "Grok",
            "outlook.live.com": "Outlook", "linkedin.com": "LinkedIn",
            "www.1point3acres.com": "1Point3Acres", "reddit.com": "Reddit",
            "mail.google.com": "Gmail", "github.com": "GitHub",
            "ios:calendar": "Calendar", "ios:reminders": "Reminders",
        ]
        var built: [String: Service] = [:]
        for (domain, name) in names {
            let definition: ServiceDefinition
            if domain.hasPrefix("ios:") {
                let url = Bundle.main.url(forResource: "OxServices", withExtension: "bundle")!
                    .appendingPathComponent("ios/\(domain.dropFirst(4))/service.json")
                let manifest = try! JSONDecoder().decode(IOSCatalogManifest.self, from: Data(contentsOf: url))
                definition = try! ServiceDefinition(iOS: manifest)
            } else {
                definition = try! ServiceDefinition(manifest: .object([
                    "domain": .string(domain), "name": .string(name),
                    "baseUrl": .string("https://\(domain)"), "actions": .array([]),
                ]))
            }
            let service = Service(definition: definition, manager: manager)
            service.setAuth(service.isIOSService ? .authorized : .observed(.init(
                value: .signedIn, observedAt: .distantPast, evidence: .configured
            )))
            built[domain] = service
        }
        catalog = built
        let bundle = Bundle.main.url(forResource: "OxDemoArtwork", withExtension: "bundle")
        artwork = Dictionary(uniqueKeysWithValues: (Array(names.keys) + ["www.kimi.com", "gemini.google.com", "qwen.ai"]).compactMap { domain in
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
        if presentation == .storyboard && [.planning, .publishing].contains(scene) {
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
        if [.planning, .publishing].contains(scene) { return }
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
