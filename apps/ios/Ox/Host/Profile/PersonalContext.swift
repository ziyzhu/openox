import Foundation

@MainActor
final class Soul {
    static let shared = Soul()

    private let file: TextFile
    private let scope: ProfileScope?

    var text: String {
        get { file.text }
        set {
            file.text = newValue
            if let scope, StorageRoot.currentScope?.profileID == scope.profileID {
                Self.shared.text = newValue
            }
        }
    }

    var isLoaded: Bool { file.isLoaded }

    private init() {
        scope = nil
        file = TextFile(name: "SOUL.md", fallback: Soul.defaultText)
    }

    init(scope: ProfileScope) {
        self.scope = scope
        file = TextFile(name: "SOUL.md", fallback: Soul.defaultText, scope: scope)
    }

    func reload() { file.reload() }

    func waitUntilCurrent() async throws { try await file.waitUntilCurrent() }

    var errorMessage: String? { file.errorMessage }

    var directive: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultText() throws -> String {
        try ModelPromptRenderer.defaultSoul()
    }
}

@MainActor
final class UserMemory {
    static let shared = UserMemory()

    private let file: TextFile
    private let scope: ProfileScope?

    var text: String {
        get { file.text }
        set {
            file.text = newValue
            if let scope, StorageRoot.currentScope?.profileID == scope.profileID {
                Self.shared.text = newValue
            }
        }
    }

    var isLoaded: Bool { file.isLoaded }

    private init() {
        scope = nil
        file = TextFile(name: "MEMORY.md", fallback: { "" })
    }

    init(scope: ProfileScope) {
        self.scope = scope
        file = TextFile(name: "MEMORY.md", fallback: { "" }, scope: scope)
    }

    func reload() { file.reload() }

    func waitUntilCurrent() async throws { try await file.waitUntilCurrent() }

    var errorMessage: String? { file.errorMessage }

}
