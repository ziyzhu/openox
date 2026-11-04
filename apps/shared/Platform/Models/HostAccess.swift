import Foundation
import Observation

@MainActor
@Observable
final class HostAccess {
    static let preferenceKey = "host.allowConnections"

    private var configuration: HostConfiguration

    var enabled: Bool {
        get { configuration.allowConnections }
        set {
            do {
                guard try HostConfiguration.load() == configuration else {
                    throw StorageMigrationError.collision("Host configuration changed externally")
                }
                guard newValue != configuration.allowConnections else { return }
                var next = configuration
                next.allowConnections = newValue
                try next.save()
                configuration = next
                Log.app.info("HostAccess enabled=\(newValue)")
                onEnabledChange?(newValue)
            } catch {
                Log.app.error("HostAccess.save failed error=\(error.localizedDescription)")
            }
        }
    }
    @ObservationIgnored var onEnabledChange: ((Bool) -> Void)?

    init() {
        configuration = (try? HostConfiguration.load()) ?? HostConfiguration()
    }
}
