import Foundation
import Observation

@MainActor
@Observable
final class HostAccess {
    nonisolated static let preferenceKey = "host.allowConnections"

    private var profileID: UUID?
    private var configuration = HostConfiguration()

    var enabled: Bool {
        get { configuration.allowConnections }
        set {
            guard let profileID = StorageRoot.shared.activeId else { return }
            setAllowsConnections(newValue, for: profileID)
        }
    }
    @ObservationIgnored var onEnabledChange: ((Bool) -> Void)?

    init() {
        observeActiveProfile()
    }

    func allowsConnections(for profileID: UUID) -> Bool {
        if profileID == self.profileID { return configuration.allowConnections }
        do {
            return try HostConfiguration.load(for: profileID).allowConnections
        } catch {
            Log.app.error("HostAccess.load failed profile=\(profileID) error=\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func setAllowsConnections(_ value: Bool, for profileID: UUID) -> Bool {
        do {
            var next = try HostConfiguration.load(for: profileID)
            if profileID == self.profileID, next != configuration {
                throw StorageMigrationError.collision("Host configuration changed externally")
            }
            guard next.allowConnections != value else { return true }
            next.allowConnections = value
            try next.save(for: profileID)
        } catch {
            Log.app.error("HostAccess.save failed profile=\(profileID) error=\(error.localizedDescription)")
            return false
        }
        Log.app.info("HostAccess allowConnections=\(value) profile=\(profileID) active=\(profileID == self.profileID)")
        if profileID == self.profileID { reload() }
        return true
    }

    private func observeActiveProfile() {
        withObservationTracking {
            _ = StorageRoot.shared.activeId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeActiveProfile() }
        }
        reload()
    }

    private func reload() {
        let id = StorageRoot.shared.activeId
        let next: HostConfiguration
        do {
            next = try id.map(HostConfiguration.load(for:)) ?? HostConfiguration()
        } catch {
            Log.app.error("HostAccess.load failed profile=\(id?.uuidString ?? "none") error=\(error.localizedDescription)")
            next = HostConfiguration()
        }
        guard id != profileID || next != configuration else { return }
        let wasEnabled = configuration.allowConnections
        profileID = id
        configuration = next
        Log.app.info("HostAccess.activeProfile profile=\(id?.uuidString ?? "none") enabled=\(next.allowConnections)")
        if wasEnabled != next.allowConnections { onEnabledChange?(next.allowConnections) }
    }
}
