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
            guard newValue != configuration.allowConnections else { return }
            guard update({ $0.allowConnections = newValue }) else { return }
            Log.app.info("HostAccess enabled=\(newValue)")
            onEnabledChange?(newValue)
        }
    }
    @ObservationIgnored var onEnabledChange: ((Bool) -> Void)?

    var remoteHosts: [RemoteHost] { configuration.remoteHosts }

    var selection: HostSelection {
        get { configuration.selection }
        set {
            guard newValue != configuration.selection else { return }
            if case .remote(let endpoint) = newValue, !configuration.remoteHosts.contains(where: { $0.endpoint == endpoint }) { return }
            guard update({ $0.selection = newValue }) else { return }
            Log.app.info("HostAccess.select host=\(Self.logName(newValue))")
        }
    }

    init() {
        configuration = (try? HostConfiguration.load()) ?? HostConfiguration()
    }

    @discardableResult
    func addRemoteHost(_ host: RemoteHost) -> Bool {
        guard !configuration.remoteHosts.contains(where: { $0.endpoint == host.endpoint }) else { return false }
        guard update({ $0.remoteHosts.append(host) }) else { return false }
        Log.app.info("HostAccess.addRemote endpoint=\(LogPrivacy.url(host.endpoint.absoluteString)) count=\(configuration.remoteHosts.count)")
        return true
    }

    func removeRemoteHost(_ endpoint: URL) {
        guard update({ next in
            next.remoteHosts.removeAll { $0.endpoint == endpoint }
            if next.selection == .remote(endpoint: endpoint) { next.selection = .local }
        }) else { return }
        Log.app.info("HostAccess.removeRemote endpoint=\(LogPrivacy.url(endpoint.absoluteString)) count=\(configuration.remoteHosts.count)")
    }

    private func update(_ change: (inout HostConfiguration) -> Void) -> Bool {
        do {
            guard try HostConfiguration.load() == configuration else {
                throw StorageMigrationError.collision("Host configuration changed externally")
            }
            var next = configuration
            change(&next)
            try next.save()
            configuration = next
            return true
        } catch {
            Log.app.error("HostAccess.save failed error=\(error.localizedDescription)")
            return false
        }
    }

    private static func logName(_ selection: HostSelection) -> String {
        switch selection {
        case .local: "local"
        case .remote(let endpoint): "remote:\(LogPrivacy.url(endpoint.absoluteString))"
        }
    }
}
