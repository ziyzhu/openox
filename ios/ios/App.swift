import SwiftUI

@main
struct OxApp: App {
    @AppStorage("app.hasCompletedOnboarding") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var skillImports = SkillImportCoordinator()
    @State private var chatImports = ChatImportCoordinator()
    @State private var presentations = AppPresentationCoordinator.shared
    private let runtime: OxRuntime

    init() {
        let runtime = OxRuntime.shared
        self.runtime = runtime
        AppRegion.shared.start()
        Log.app.info("Device.launch id=\(Device.id) internal=\(Device.isInternal)")
        PerfMonitor.shared.start()
        #if targetEnvironment(simulator)
        Task { @MainActor in
            DebugServer.shared.onCommand = { data, reply in
                DebugCommandRouter.handle(data, serviceManager: runtime.serviceManager, reply: reply)
            }
            DebugServer.shared.start()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    RootView(
                        runtime: runtime,
                        skillImports: skillImports,
                        chatImports: chatImports
                    )
                } else {
                    OnboardingView { onboarded = true }
                }
            }
            .environment(runtime.serviceManager)
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
                Task { await AppRegion.shared.refresh() }
            }
        }
    }
}
