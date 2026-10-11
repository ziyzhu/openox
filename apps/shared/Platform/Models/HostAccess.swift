import Foundation
import Observation

@MainActor
@Observable
final class HostAccess {
    static let preferenceKey = "host.allowConnections"

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
            Log.app.info("HostAccess enabled=\(enabled)")
            onEnabledChange?(enabled)
        }
    }
    @ObservationIgnored var onEnabledChange: ((Bool) -> Void)?

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? false
    }
}
