import SwiftUI

@main
struct OxApp: App {
    @AppStorage("app.hasCompletedOnboarding") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var skillImports = SkillImportCoordinator()
    @State private var chatImports = ChatImportCoordinator()
    @State private var serviceImports = ServiceImportCoordinator(manager: IOSHost.shared.services)
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
                case "service": serviceImports.receive(url)
                default: Log.ui.info("DocumentImport.ignored source=\(url.lastPathComponent)")
                }
            }
            .sheet(isPresented: Binding(
                get: { serviceImports.proposal != nil && client.services.repositoryState == .ready },
                set: { if !$0 { serviceImports.dismissProposal() } }
            )) {
                if let proposal = serviceImports.proposal {
                    ServiceImportView(proposal: proposal, coordinator: serviceImports)
                        .themed()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .alert("Couldn't import service", isPresented: Binding(
                get: { serviceImports.errorMessage != nil },
                set: { if !$0 { serviceImports.dismissError() } }
            )) {
                Button("OK", role: .cancel) { serviceImports.dismissError() }
            } message: {
                Text(serviceImports.errorMessage ?? "")
            }
            .alert("Service imported", isPresented: Binding(
                get: { serviceImports.importedDomain != nil },
                set: { if !$0 { serviceImports.dismissSuccess() } }
            )) {
                Button("OK", role: .cancel) { serviceImports.dismissSuccess() }
            } message: {
                Text(verbatim: serviceImports.importedDomain ?? "")
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
