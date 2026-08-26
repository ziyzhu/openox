@MainActor
protocol OxHost: AnyObject {
    var chats: ChatManager { get }
    var services: ServiceManager { get }

    func prepare(onPhase: (@MainActor (HostPreparationPhase) -> Void)?) async throws
}
