import Foundation
import Observation

@MainActor
@Observable
final class ProviderAuthenticationSession {
    enum Outcome: String {
        case authenticated
        case credentialStored = "credential-stored"
        case cancelled
        case failed
    }

    let definition: ProviderDefinition
    let client: any ProviderClient
    private(set) var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(definition: ProviderDefinition, client: any ProviderClient) {
        self.definition = definition
        self.client = client
    }

    func run() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome { continuation.resume(returning: outcome) }
                else if Task.isCancelled { continuation.resume(returning: .cancelled) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.complete(.cancelled) }
        }
    }

    func complete(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
        Log.ui.info("ProviderAuthentication completed provider=\(definition.id) outcome=\(outcome.rawValue)")
    }
}
