import Foundation
import Observation

@MainActor
@Observable
final class TextFile {
    let name: String
    private let fallback: String
    private let fixedScope: ProfileScope?
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var operation: Task<Void, Never>?

    private(set) var isLoaded = false

    var text: String {
        didSet {
            guard !reloading else { return }
            revision &+= 1
            write()
        }
    }

    init(name: String, fallback: String, scope: ProfileScope? = nil) {
        self.name = name
        self.fallback = fallback
        self.fixedScope = scope
        self.text = fallback
        reload()
    }

    private var scope: ProfileScope? {
        fixedScope ?? StorageRoot.currentScope
    }

    func reload() {
        guard let scope else { isLoaded = true; return }
        isLoaded = false
        let expectedRevision = revision
        enqueue { [weak self] repository in
            guard let self else { return }
            do {
                let loaded: String
                if let saved = try await repository.readTextFile(named: self.name, in: scope) {
                    loaded = saved
                } else {
                    try await repository.writeTextFile(self.fallback, named: self.name, in: scope)
                    loaded = self.fallback
                    Log.app.info("TextFile.seed \(self.name) chars=\(loaded.count)")
                }
                guard self.scope == scope, self.revision == expectedRevision else { return }
                self.reloading = true
                self.text = loaded
                self.reloading = false
                self.isLoaded = true
                Log.app.info("TextFile.reload \(self.name) chars=\(loaded.count)")
            } catch {
                if self.scope == scope { self.isLoaded = true }
                Log.app.info("TextFile.read \(self.name) default: \(error.localizedDescription)")
            }
        }
    }

    func waitUntilCurrent() async {
        await operation?.value
    }

    private func write() {
        guard let scope else { return }
        let value = text
        enqueue { [weak self] repository in
            guard let self else { return }
            do {
                try await repository.writeTextFile(value, named: self.name, in: scope)
                Log.app.info("TextFile.write \(self.name) chars=\(value.count)")
            } catch {
                Log.app.error("TextFile.write \(self.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func enqueue(_ work: @escaping @MainActor (ProfileRepository) async -> Void) {
        let previous = operation
        let repository = ProfileRepository.shared
        operation = Task { @MainActor in
            await previous?.value
            await work(repository)
        }
    }
}
