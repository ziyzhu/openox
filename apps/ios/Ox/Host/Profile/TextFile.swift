import Foundation
import Observation

@MainActor
@Observable
final class TextFile {
    private enum State {
        case pending(ProfileScope?, failure: (any Error)?)
        case ready(ProfileScope, revision: UInt64, operation: UInt64)
        case failed(ProfileScope?, any Error)

        var failure: (any Error)? {
            switch self {
            case .pending(_, let failure): failure
            case .ready: nil
            case .failed(_, let failure): failure
            }
        }
    }

    let name: String
    private let fallback: String
    private let fixedScope: ProfileScope?
    private var value = ""
    private var state = State.pending(nil, failure: nil)
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var operationID: UInt64 = 0
    @ObservationIgnored private var operation: Task<Void, Never>?

    var isLoaded: Bool {
        guard case .ready(let loadedScope, let loadedRevision, let loadedOperation) = state else { return false }
        return scope == loadedScope && revision == loadedRevision && operationID == loadedOperation
    }

    var errorMessage: String? { state.failure?.localizedDescription }

    var text: String {
        get { value }
        set {
            value = newValue
            revision &+= 1
            write()
        }
    }

    init(name: String, fallback: String, scope: ProfileScope? = nil) {
        self.name = name
        self.fallback = fallback
        self.fixedScope = scope
        reload()
    }

    private var scope: ProfileScope? {
        fixedScope ?? StorageRoot.currentScope
    }

    func reload() {
        guard let scope, scope.profileID != nil else {
            state = .failed(scope, CocoaError(.fileNoSuchFile))
            return
        }
        let name = name
        let fallback = fallback
        let expectedRevision = revision
        enqueue(in: scope) { [weak self] repository, operationID in
            do {
                let loaded: String
                if let saved = try await repository.readTextFile(named: name, in: scope) {
                    loaded = saved
                } else {
                    let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
                        "action": .string("fileSeed"), "path": .string(name), "text": .string(fallback),
                    ]))
                    guard let content = result.objectValue?["content"]?.stringValue else {
                        throw RuntimeError.bridge("Profile document seed did not return text: \(name)")
                    }
                    loaded = content
                    Log.app.info("TextFile.seed name=\(name) profile=\(scope.profileID?.uuidString ?? "nil") bytes=\(loaded.utf8.count)")
                }
                guard let self, self.scope == scope, self.revision == expectedRevision else { return }
                self.value = loaded
                self.state = .ready(scope, revision: expectedRevision, operation: operationID)
                Log.app.info("TextFile.reload name=\(name) profile=\(scope.profileID?.uuidString ?? "nil") bytes=\(loaded.utf8.count)")
            } catch {
                if self?.scope == scope { self?.state = .failed(scope, error) }
                Log.app.error("TextFile.read name=\(name) profile=\(scope.profileID?.uuidString ?? "nil") error=\(error.localizedDescription)")
            }
        }
    }

    func waitUntilCurrent() async throws {
        let expectedScope = scope
        try Task.checkCancellation()
        while let current = operation {
            let expectedOperation = operationID
            await current.value
            try Task.checkCancellation()
            if expectedOperation == operationID { break }
        }
        guard scope == expectedScope else { throw RuntimeError.bridge("Profile changed while waiting for its document: \(name)") }
        if let failure = state.failure { throw failure }
        guard isLoaded else { throw RuntimeError.bridge("Profile document is not current: \(name); reload it") }
    }

    private func write() {
        guard let scope, scope.profileID != nil else {
            state = .failed(scope, CocoaError(.fileNoSuchFile))
            return
        }
        let name = name
        let text = value
        let expectedRevision = revision
        enqueue(in: scope) { [weak self] repository, operationID in
            do {
                try await repository.writeTextFile(text, named: name, in: scope)
                if let self, self.scope == scope, self.revision == expectedRevision {
                    self.state = .ready(scope, revision: expectedRevision, operation: operationID)
                }
                Log.app.info("TextFile.write name=\(name) profile=\(scope.profileID?.uuidString ?? "nil") bytes=\(text.utf8.count)")
            } catch {
                if self?.scope == scope { self?.state = .failed(scope, error) }
                Log.app.error("TextFile.write name=\(name) profile=\(scope.profileID?.uuidString ?? "nil") error=\(error.localizedDescription)")
            }
        }
    }

    private func enqueue(in scope: ProfileScope, _ work: @escaping @MainActor (ProfileRepository, UInt64) async -> Void) {
        let previous = operation
        let repository = ProfileRepository.shared
        operationID &+= 1
        let currentOperation = operationID
        state = .pending(scope, failure: state.failure)
        operation = Task { @MainActor in
            await previous?.value
            await work(repository, currentOperation)
        }
    }
}
