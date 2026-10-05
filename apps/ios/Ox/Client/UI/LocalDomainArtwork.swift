import SwiftUI

private struct LocalDomainArtworkKey: EnvironmentKey {
    static let defaultValue: [String: Data] = [:]
}

extension EnvironmentValues {
    /// Optional in-memory artwork for previews and other network-independent presentations.
    var localDomainArtwork: [String: Data] {
        get { self[LocalDomainArtworkKey.self] }
        set { self[LocalDomainArtworkKey.self] = newValue }
    }
}
