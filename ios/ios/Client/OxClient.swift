@MainActor
final class OxClient {
    static let shared = OxClient(host: IOSHost.shared)

    private let host: any OxHost

    var chats: ChatManager { host.chats }
    var services: ServiceManager { host.services }

    init(host: any OxHost) {
        self.host = host
    }

    func prepare(onPhase: (@MainActor (HostPreparationPhase) -> Void)? = nil) async {
        await host.prepare(onPhase: onPhase)
    }

    static func preview(serviceManager: ServiceManager) -> OxClient {
        OxClient(host: IOSHost(
            serviceManager: serviceManager,
            presentations: .unavailable
        ))
    }
}
