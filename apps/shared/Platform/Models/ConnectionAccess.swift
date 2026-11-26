import Foundation
import Observation

@MainActor
@Observable
final class ConnectionAccess {
    private var profileID: UUID?
    private var settings = ConnectionSettings()
    @ObservationIgnored var onChange: (() -> Void)?

    var allowsConnections: Bool {
        get { settings.allowConnections }
        set {
            guard let profileID = StorageRoot.shared.activeId else { return }
            setAllowsConnections(newValue, for: profileID)
        }
    }

    init() {
        observeActiveProfile()
    }

    func allowsConnections(for profileID: UUID) -> Bool {
        if profileID == self.profileID { return settings.allowConnections }
        do {
            return try ConnectionSettings.load(for: profileID).allowConnections
        } catch {
            Log.app.error("ConnectionAccess.load failed profile=\(profileID) error=\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func setAllowsConnections(_ value: Bool, for profileID: UUID) -> Bool {
        let active = profileID == self.profileID
        do {
            var next = try ConnectionSettings.load(for: profileID)
            if active, next != settings { throw StorageMigrationError.collision("Connection settings changed externally") }
            guard next.allowConnections != value else { return true }
            next.allowConnections = value
            try next.save(for: profileID)
        } catch {
            Log.app.error("ConnectionAccess.save failed profile=\(profileID) error=\(error.localizedDescription)")
            return false
        }
        Log.app.info("ConnectionAccess allowConnections=\(value) profile=\(profileID) active=\(active)")
        if active { reload() }
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
        let next: ConnectionSettings
        do {
            next = try id.map(ConnectionSettings.load(for:)) ?? ConnectionSettings()
        } catch {
            Log.app.error("ConnectionAccess.load failed profile=\(id?.uuidString ?? "none") error=\(error.localizedDescription)")
            next = ConnectionSettings()
        }
        guard id != profileID || next != settings else { return }
        let changed = next.allowConnections != settings.allowConnections
        profileID = id
        settings = next
        Log.app.info("ConnectionAccess.activeProfile profile=\(id?.uuidString ?? "none") allowConnections=\(next.allowConnections)")
        if changed { onChange?() }
    }
}
