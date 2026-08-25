import AppIntents
import Foundation

enum OxIntentCompletion: Sendable {
    case finished(ChatSubmissionOutcome)
    case continuing
    case requiresApplication

    var logLabel: String {
        switch self {
        case .finished(let outcome): outcome.logLabel
        case .continuing: "continuing"
        case .requiresApplication: "requires-application"
        }
    }
}

@MainActor
final class OxIntentBudget {
    nonisolated static let defaultResponseWindow: Duration = .seconds(24)

    private let window: Duration
    private var remainingWindow: Duration
    private var activeSince = ContinuousClock.now
    private var suspensionDepth = 0

    init(responseWindow: Duration = defaultResponseWindow) {
        let clamped = max(responseWindow, .zero)
        window = clamped
        remainingWindow = clamped
    }

    var elapsedMilliseconds: Int64 {
        Self.milliseconds(window - remaining)
    }

    func withSuspendedDeadline<T>(_ operation: () async throws -> T) async rethrows -> T {
        suspend()
        defer { resume() }
        return try await operation()
    }

    func waitForDeadline() async -> OxIntentCompletion {
        while !Task.isCancelled {
            let delay = min(remaining, .milliseconds(100))
            guard delay > .zero else { return .continuing }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return .finished(.cancelled)
            }
        }
        return .finished(.cancelled)
    }

    private var remaining: Duration {
        guard suspensionDepth == 0 else { return remainingWindow }
        return max(remainingWindow - activeSince.duration(to: .now), .zero)
    }

    private func suspend() {
        if suspensionDepth == 0 {
            remainingWindow = remaining
        }
        suspensionDepth += 1
    }

    private func resume() {
        guard suspensionDepth > 0 else { return }
        suspensionDepth -= 1
        if suspensionDepth == 0 {
            activeSince = .now
        }
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}

enum OxIntentSupport {
    @MainActor
    static func readyClient() async throws -> OxClient {
        guard UserDefaults.standard.bool(forKey: "app.hasCompletedOnboarding") else {
            throw OxIntentError.onboardingRequired
        }
        let client = OxClient.shared
        await client.prepare()
        return client
    }

    static func prompt(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OxIntentError.emptyPrompt }
        return trimmed
    }

    @MainActor
    static func waitForCompletion(
        budget: OxIntentBudget,
        chat: (@MainActor @Sendable () -> Chat?)? = nil,
        interaction: (@MainActor @Sendable (ChatPendingPrompt) async throws -> String)? = nil,
        operation: @escaping @MainActor @Sendable () async -> ChatSubmissionOutcome
    ) async -> OxIntentCompletion {
        await withTaskGroup(of: OxIntentCompletion.self) { group in
            group.addTask { @MainActor in
                .finished(await operation())
            }
            group.addTask {
                await budget.waitForDeadline()
            }
            if let chat, let interaction {
                group.addTask { @MainActor in
                    var handled: Set<UUID> = []
                    while !Task.isCancelled {
                        guard let source = chat(), let request = source.pendingPrompt(excluding: handled) else {
                            do {
                                try await Task.sleep(for: .milliseconds(50))
                            } catch {
                                return .finished(.cancelled)
                            }
                            continue
                        }
                        handled.insert(request.id)
                        Log.app.info(
                            "OxIntentSupport prompt presentation=\(String(describing: request.presentation)) options=\(request.options.count)"
                        )
                        guard request.presentation == .conversation, !request.options.isEmpty else {
                            return .requiresApplication
                        }
                        do {
                            let answer = try await budget.withSuspendedDeadline {
                                try await interaction(request)
                            }
                            source.resolvePendingPrompt(request, answer: answer)
                        } catch {
                            if !Task.isCancelled { source.cancelAll() }
                            return .finished(.cancelled)
                        }
                    }
                    return .finished(.cancelled)
                }
            }
            let completion = await group.next() ?? .finished(.cancelled)
            group.cancelAll()
            Log.app.info(
                "OxIntentSupport completed mode=\(completion.logLabel) activeMs=\(budget.elapsedMilliseconds)"
            )
            return completion
        }
    }

    static func response(from completion: OxIntentCompletion) async throws -> (value: String, spoken: String) {
        switch completion {
        case .continuing:
            let canNotify = await NativePermission.notifications.state() == .granted
            let message = canNotify
                ? String(localized: "Ox is still plowing. I'll let you know when it's ready.")
                : String(localized: "Ox is still plowing. Open Ox later, or ask Siri to read Ox's latest response.")
            return (message, message)
        case .requiresApplication:
            let message = String(localized: "Ox needs you to continue in the app.")
            return (message, message)
        case .finished(.completed(let response)):
            return renderedResponse(response)
        case .finished(.failed(let message)):
            throw OxIntentError.chatFailed(message)
        case .finished(.cancelled):
            throw OxIntentError.cancelled
        }
    }

    static func renderedResponse(_ response: String) -> (value: String, spoken: String) {
        let rendered = (try? AttributedString(markdown: response)).map { String($0.characters) } ?? response
        return (response, rendered.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func combinedPrompt(question: String, text: String?, url: URL?) throws -> String {
        let question = try prompt(question)
        var inputs: [String] = []
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            inputs.append(text)
        }
        if let url { inputs.append(url.absoluteString) }
        guard !inputs.isEmpty else { return question }
        return "Shortcut input:\n\n\(inputs.joined(separator: "\n\n"))\n\nQuestion:\n\n\(question)"
    }

    @MainActor
    static func importArtifacts(_ files: [IntentFile], using manager: ChatManager) async throws -> [Artifact] {
        guard let scope = StorageRoot.currentScope else { throw OxIntentError.importFailed }
        var artifacts: [Artifact] = []
        do {
            for file in files {
                let artifact = try await ArtifactImporter.importDataAsync(
                    file.data,
                    suggestedName: file.filename,
                    in: scope
                )
                artifacts.append(artifact)
            }
            return artifacts
        } catch {
            for artifact in artifacts { try? await manager.deleteArtifact(artifact) }
            throw OxIntentError.importFailed
        }
    }
}

extension AppIntent {
    func requestOxInput(_ request: ChatPendingPrompt) async throws -> String {
        let choices = request.options.map { option in
            IntentChoiceOption(title: LocalizedStringResource(stringLiteral: option))
        }
        let selected = try await requestChoice(
            between: choices,
            dialog: IntentDialog(stringLiteral: request.prompt)
        )
        guard let index = choices.firstIndex(of: selected) else { throw OxIntentError.cancelled }
        return request.options[index]
    }
}

enum OxIntentError: LocalizedError {
    case onboardingRequired
    case emptyPrompt
    case importFailed
    case chatFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .onboardingRequired: "Open Ox and finish setup before asking Siri to use it."
        case .emptyPrompt: "Ox needs a question."
        case .importFailed: "Ox could not import that input."
        case .chatFailed(let message): message
        case .cancelled: "The Ox request was cancelled."
        }
    }
}
