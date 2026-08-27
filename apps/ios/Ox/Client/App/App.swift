import SwiftUI

@main
struct OxApp: App {
    @AppStorage("app.hasCompletedOnboarding") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var skillImports = SkillImportCoordinator()
    @State private var chatImports = ChatImportCoordinator()
    @State private var presentations = AppPresentationCoordinator.shared
    private let client: OxClient
    #if targetEnvironment(simulator)
    private let webSocketTransport: WebSocketOxHostTransport
    #endif

    init() {
        ScheduledSkillScheduler.shared.register()
        let host = IOSHost.shared
        client = OxClient(host: host)
        #if targetEnvironment(simulator)
        let webSocketTransport = WebSocketOxHostTransport(host: host)
        self.webSocketTransport = webSocketTransport
        #endif
        AppRegion.shared.start()
        Log.app.info("Device.launch id=\(Device.id) internal=\(Device.isInternal)")
        PerfMonitor.shared.start()
        #if targetEnvironment(simulator)
        Task { @MainActor in
            webSocketTransport.start()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    RootView(
                        client: client,
                        skillImports: skillImports,
                        chatImports: chatImports
                    )
                } else {
                    OnboardingView { onboarded = true }
                }
            }
            .environment(client.services)
            .themed()
            .appPresentations(presentations)
            .onOpenURL { url in
                switch url.pathExtension.lowercased() {
                case "skill": skillImports.receive(url)
                case "chat": chatImports.receive(url)
                default: Log.ui.info("DocumentImport.ignored source=\(url.lastPathComponent)")
                }
            }
            .task { await AppRegion.shared.refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await AppRegion.shared.refresh()
                    ScheduledSkillScheduler.shared.refresh()
                }
            }
        }
    }
}
