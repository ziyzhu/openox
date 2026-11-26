import Foundation
import Observation

nonisolated struct SecretEntrySpec: Sendable, Equatable {
    let key: String
    let type: SecretType
    let serviceID: String?
    var prefill: [String: String] = [:]

    var serviceDomain: String? {
        serviceID.map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 }
    }

    func displayName(values: [String: String]) -> String {
        if type == .account, let username = values["username"], !username.isEmpty {
            return String(username.prefix(80))
        }
        return String((serviceDomain ?? key).prefix(80))
    }
}

@MainActor
@Observable
final class SecretEntryRequest: Identifiable, Equatable {
    enum State {
        case editing
        case saving
        case finished
    }

    nonisolated let id = UUID()
    let spec: SecretEntrySpec
    private(set) var state = State.editing
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let save: ([String: String]) async throws -> Void

    var key: String { spec.key }

    init(spec: SecretEntrySpec, save: (([String: String]) async throws -> Void)? = nil) {
        self.spec = spec
        self.save = save ?? { values in
            try Secret.setTyped(key: spec.key, displayName: spec.displayName(values: values), type: spec.type,
                                serviceID: spec.serviceID, values: values)
        }
    }

    nonisolated static func == (lhs: SecretEntryRequest, rhs: SecretEntryRequest) -> Bool {
        lhs.id == rhs.id
    }

    func submit(values: [String: String], onSaved: @escaping () -> Void) {
        guard state == .editing else { return }
        state = .saving
        error = nil
        task = Task {
            do {
                try Task.checkCancellation()
                try await save(values)
                try Task.checkCancellation()
                state = .finished
                task = nil
                onSaved()
            } catch is CancellationError {
                cancel()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                state = .editing
                task = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .finished
    }
}
