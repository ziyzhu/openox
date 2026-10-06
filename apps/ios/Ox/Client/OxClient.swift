@MainActor
final class OxClient {
    static let shared = OxClient(host: IOSHost.shared)

    private let host: any OxHost

    var conversations: ConversationManager { host.conversations }
    var services: ServiceManager { host.services }

    func listChats() -> [HostChatSummary] { host.listChats() }

    init(host: any OxHost) {
        self.host = host
    }

    func prepareStorage() async throws {
        try await host.prepareStorage()
    }

    func prepare() async throws {
        try await host.prepare()
    }

    static func preview(serviceManager: ServiceManager) -> OxClient {
        OxClient(host: IOSHost(
            serviceManager: serviceManager,
            presentations: .unavailable
        ))
    }
}
