import Foundation
import Observation

@MainActor
@Observable
final class SecretEntryRequest: Identifiable, Equatable {
    enum State {
        case editing
        case saving
        case finished
    }

    nonisolated let id = UUID()
    let key: String
    private(set) var state = State.editing
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let save: (String, String) async throws -> Void

    init(key: String) {
        self.key = key
        save = { displayName, value in
            try Secret.set(key: key, displayName: displayName, value: value)
        }
    }

    nonisolated static func == (lhs: SecretEntryRequest, rhs: SecretEntryRequest) -> Bool {
        lhs.id == rhs.id
    }

    func submit(displayName: String, value: String, onSaved: @escaping () -> Void) {
        guard state == .editing else { return }
        state = .saving
        error = nil
        task = Task {
            do {
                try Task.checkCancellation()
                try await save(displayName, value)
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
