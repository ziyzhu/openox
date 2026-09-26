import Foundation
import Observation

@MainActor
@Observable
final class SecretEntryRequest: Identifiable, Equatable {
    enum Form {
        case named(key: String)
        case githubPublication
    }

    enum State {
        case editing
        case saving
        case finished
    }

    nonisolated let id = UUID()
    let form: Form
    private(set) var state = State.editing
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let save: (String, String) async throws -> Void

    init(key: String) {
        form = .named(key: key)
        save = { displayName, value in
            try Secret.set(key: key, displayName: displayName, value: value)
        }
    }

    init(validate: @escaping RepositoryTokenValidation) {
        form = .githubPublication
        save = { displayName, value in
            try Secret.validateDisplayName(displayName)
            guard let data = value.data(using: .utf8),
                  let fields = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  fields.count == 1, let token = fields["token"] else {
                throw RuntimeError.bridge(String(localized: "GitHub publication requires a single token field."))
            }
            try await validate(token.trimmingCharacters(in: .whitespacesAndNewlines), displayName)
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
