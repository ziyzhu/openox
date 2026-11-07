import SwiftUI

@main
struct OxApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        DeviceTemplate.preparePreferences()
        #endif
        #if DEBUG
        guard !OxDemoLaunch.enabled && !OxAppStoreScreenshotLaunch.enabled else { return }
        #endif
        StorageMigrator.migrateApplicationStorage()
        ScheduleScheduler.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if OxAppStoreScreenshotLaunch.enabled {
                OxAppStoreScreenshotView(screenshot: OxAppStoreScreenshotLaunch.screenshot)
            } else if OxDemoLaunch.enabled {
                OxDemoSceneView(
                    scene: OxDemoLaunch.scene,
                    completed: OxDemoLaunch.completed,
                    autoplay: OxDemoLaunch.autoplay
                )
            } else {
                OxApplicationView()
            }
            #else
            OxApplicationView()
            #endif
        }
    }
}

private struct OxApplicationView: View {
    private enum IncomingWebLink {
        case pending(URL)
        case failed(URL)
    }

    private struct WhatsNewPresentation: Identifiable {
        let releases: [WhatsNewRelease]

        var id: String { releases.map(\.id).joined(separator: ",") }
    }

    private enum WhatsNewLaunch {
        case waiting
        case presenting(WhatsNewPresentation)
        case finished
    }

    @AppStorage(Theme.Appearance.storageKey) private var appearance = Theme.Appearance.system
    @State private var incomingWebLink: IncomingWebLink?
    @State private var whatsNewLaunch = WhatsNewLaunch.waiting
    @State private var appState = AppStateStore.shared
    private var onboarded: Bool { appState.value.onboarded }
    @Environment(\.scenePhase) private var scenePhase
    @State private var skillImports = SkillImportCoordinator()
    @State private var conversationImports = ConversationImportCoordinator()
    @State private var serviceImports = ServiceImportCoordinator(manager: IOSHost.shared.services)
    @State private var presentations = AppPresentationCoordinator.shared
    @State private var hostAccess: HostAccess
    private let client: OxClient
    @State private var webSocketTransport: WebSocketOxHostTransport

    init() {
        let host = IOSHost.shared
        let access = HostAccess()
        _hostAccess = State(initialValue: access)
        client = OxClient(host: host)
        _webSocketTransport = State(initialValue: WebSocketOxHostTransport(host: host, access: access))
        AppRegion.shared.start()
        Log.app.info("Device.launch id=\(Device.id) internal=\(Device.isInternal)")
        PerfMonitor.shared.start()
    }

    var body: some View {
        appContent
            .appPresentations(presentations)
            .onChange(of: appearance, initial: true) { _, value in
                value.apply()
            }
            .environment(client.services)
            .environment(hostAccess)
            .onOpenURL { url in
                if case .web = ConversationLinkDestination(url) {
                    incomingWebLink = .pending(url)
                    Log.ui.info("Browser.externalLink received url=\(LogPrivacy.url(url.absoluteString))")
                    return
                }
                guard url.isFileURL else {
                    Log.ui.info("DocumentImport.ignored scheme=\(url.scheme ?? "none")")
                    return
                }
                switch url.pathExtension.lowercased() {
                case "skill": skillImports.receive(url)
                case "conversation", "chat": conversationImports.receive(url)
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
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .alert("Couldn't import service", isPresented: Binding(
                            get: { serviceImports.errorMessage != nil },
                            set: { if !$0 { serviceImports.dismissError() } }
                        )) {
                            Button("OK", role: .cancel) { serviceImports.dismissError() }
                        } message: {
                            Text(serviceImports.errorMessage ?? "")
                        }
                }
            }
            .alert("Couldn't import service", isPresented: Binding(
                get: { serviceImports.proposal == nil && serviceImports.errorMessage != nil },
                set: { if !$0, serviceImports.proposal == nil { serviceImports.dismissError() } }
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
            .alert("Couldn't Open Link", isPresented: Binding(
                get: { if case .failed = incomingWebLink { return true }; return false },
                set: { if !$0, case .failed = incomingWebLink { incomingWebLink = nil } }
            )) {
                Button("Try Again") {
                    if case .failed(let url) = incomingWebLink { incomingWebLink = .pending(url) }
                }
                Button("Cancel", role: .cancel) { incomingWebLink = nil }
            } message: {
                Text("Ox couldn't prepare the selected Profile. Try opening the link again.")
            }
            .sheet(item: whatsNewPresentation) { presentation in
                WhatsNewView(releases: presentation.releases, onDone: finishWhatsNew)
            }
            .task(id: canPresentWhatsNew) {
                guard canPresentWhatsNew, case .waiting = whatsNewLaunch else { return }
                do { try await client.prepare() } catch { return }
                guard !Task.isCancelled, canPresentWhatsNew, case .waiting = whatsNewLaunch else { return }
                let releases = WhatsNew.unseen(since: appState.value.whatsNewSeenVersion)
                guard !releases.isEmpty else {
                    whatsNewLaunch = .finished
                    return
                }
                Log.ui.info("WhatsNew.presented versions=\(releases.map(\.version).joined(separator: ","))")
                whatsNewLaunch = .presenting(WhatsNewPresentation(releases: releases))
            }
            .task(id: incomingURLToOpen) {
                guard let url = incomingURLToOpen else { return }
                do {
                    try await client.prepare()
                    try Task.checkCancellation()
                    guard incomingURLToOpen == url else { return }
                    if LinkOpener.open(url: url, serviceManager: client.services) {
                        incomingWebLink = nil
                        Log.ui.info("Browser.externalLink opened url=\(LogPrivacy.url(url.absoluteString))")
                    }
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled, incomingURLToOpen == url else { return }
                    incomingWebLink = .failed(url)
                    Log.ui.error("Browser.externalLink preparationFailed error=\(LogPrivacy.text(error.localizedDescription))")
                }
            }
            .task { await AppRegion.shared.refresh() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                webSocketTransport.reconcile()
                guard phase == .active else { return }
                appearance.apply()
                Task {
                    do {
                        try await client.prepare()
                        webSocketTransport.reconcile()
                    } catch {
                        Log.app.warning("OxHost transport unavailable: preparation failed")
                    }
                    await AppRegion.shared.refresh()
                    await ScheduleScheduler.shared.refresh()
                }
            }
    }

    private var incomingURLToOpen: URL? {
        guard isIdle, presentations.canOpenBrowser, !isPresentingWhatsNew,
              case .pending(let url) = incomingWebLink else { return nil }
        return url
    }

    private var isIdle: Bool {
        onboarded && scenePhase == .active && !StorageRoot.shared.isBusy
            && serviceImports.proposal == nil && serviceImports.errorMessage == nil
            && serviceImports.importedDomain == nil
            && skillImports.proposal == nil && skillImports.errorMessage == nil
            && conversationImports.proposal == nil && conversationImports.errorMessage == nil
    }

    private var canPresentWhatsNew: Bool {
        isIdle && incomingWebLink == nil && presentations.presented == nil
    }

    private var isPresentingWhatsNew: Bool {
        if case .presenting = whatsNewLaunch { return true }
        return false
    }

    private var whatsNewPresentation: Binding<WhatsNewPresentation?> {
        Binding(
            get: {
                if case .presenting(let presentation) = whatsNewLaunch { return presentation }
                return nil
            },
            set: { presentation in
                guard presentation == nil, isPresentingWhatsNew else { return }
                finishWhatsNew()
            }
        )
    }

    private func finishWhatsNew() {
        whatsNewLaunch = .finished
        do { try appState.update { $0.whatsNewSeenVersion = WhatsNew.appVersion } }
        catch { Log.app.error("WhatsNew.save failed error=\(error.localizedDescription)") }
    }

    @ViewBuilder
    private var appContent: some View {
        if onboarded {
            RootView(client: client, skillImports: skillImports, conversationImports: conversationImports)
        } else {
            OnboardingView {
                do {
                    try appState.update {
                        $0.onboarded = true
                        $0.whatsNewSeenVersion = WhatsNew.appVersion
                    }
                }
                catch { Log.app.error("Onboarding.save failed error=\(error.localizedDescription)") }
            }
        }
    }
}
