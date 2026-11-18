import UniformTypeIdentifiers
import SwiftUI
import UIKit
import WebKit
import Security

private enum ConversationTransition: Equatable {
    case idle
    case opening
}

private struct CurrentConversationActivityObserver: View {
    let conversation: Conversation?
    let onAwaitingUser: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: conversation?.activity, initial: true) { _, activity in
                guard activity?.isAwaitingUser == true else { return }
                onAwaitingUser()
            }
    }
}

private struct SplitSidebarResizer: View {
    let width: CGFloat
    let limits: ClosedRange<CGFloat>
    let onResize: (CGFloat) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var hovered = false

    private var active: Bool {
        dragStartWidth != nil
    }

    var body: some View {
        Color.clear
            .frame(width: 28)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                if active || hovered {
                    Rectangle()
                        .fill(Theme.Colors.primary)
                        .frame(width: 2)
                }
            }
            .onHover { hovered = $0 }
            .gesture(resizeGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11yLabel.resizeSidebar)
            .accessibilityValue(Text(verbatim: "\(Int(width))"))
            .accessibilityIdentifier(A11yID.Sidebar.resizer)
            .accessibilityAction(named: A11yLabel.widenSidebar) {
                resize(to: width + 32, source: "accessibilityWiden")
            }
            .accessibilityAction(named: A11yLabel.narrowSidebar) {
                resize(to: width - 32, source: "accessibilityNarrow")
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStartWidth == nil {
                    dragStartWidth = width
                    Log.ui.info("RootView.sidebarResize phase=start width=\(Int(width))")
                }
                onResize(clamp((dragStartWidth ?? width) + value.translation.width))
            }
            .onEnded { value in
                let resizedWidth = clamp((dragStartWidth ?? width) + value.translation.width)
                onResize(resizedWidth)
                dragStartWidth = nil
                Log.ui.info("RootView.sidebarResize phase=end width=\(Int(resizedWidth))")
            }
    }

    private func resize(to newWidth: CGFloat, source: String) {
        let resizedWidth = clamp(newWidth)
        onResize(resizedWidth)
        Log.ui.info("RootView.sidebarResize phase=end source=\(source) width=\(Int(resizedWidth))")
    }

    private func clamp(_ width: CGFloat) -> CGFloat {
        min(limits.upperBound, max(limits.lowerBound, width))
    }
}

private struct ComposerFocusRequest: Equatable {
    let id = UUID()
    let conversationIdentity: ObjectIdentifier
    let reason: String
}

private struct SkillImportModifier: ViewModifier {
    let coordinator: SkillImportCoordinator
    let ready: Bool
    let onProposalPresented: () -> Void
    let onImportedSkill: (Skill) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { ready && coordinator.proposal != nil },
                set: { if !$0 { coordinator.dismissProposal() } }
            )) {
                if let proposal = coordinator.proposal {
                    SkillImportView(proposal: proposal, coordinator: coordinator)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Theme.Colors.background)
                        .errorAlert("Couldn't Import Skill", message: coordinator.errorMessage) { coordinator.dismissError() }
                }
            }
            .errorAlert("Couldn't Import Skill", message: coordinator.proposal == nil ? coordinator.errorMessage : nil) {
                coordinator.dismissError()
            }
            .onChange(of: coordinator.proposal?.id) { _, proposal in
                if proposal != nil { onProposalPresented() }
            }
            .onChange(of: coordinator.importedSkill) { _, skill in
                guard let skill else { return }
                onImportedSkill(skill)
                coordinator.consumeImportedSkill()
            }
    }
}

private struct ConversationImportModifier: ViewModifier {
    let coordinator: ConversationImportCoordinator
    let conversations: ConversationManager
    let ready: Bool
    let onProposalPresented: () -> Void
    let onImportedConversation: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { ready && coordinator.proposal != nil },
                set: { if !$0 { coordinator.dismissProposal() } }
            )) {
                if let proposal = coordinator.proposal {
                    ConversationImportView(proposal: proposal, coordinator: coordinator, conversations: conversations)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Theme.Colors.background)
                        .errorAlert("Couldn't Import Conversation", message: coordinator.errorMessage) { coordinator.dismissError() }
                }
            }
            .errorAlert("Couldn't Import Conversation", message: coordinator.proposal == nil ? coordinator.errorMessage : nil) {
                coordinator.dismissError()
            }
            .onChange(of: coordinator.proposal?.id) { _, proposal in
                if proposal != nil { onProposalPresented() }
            }
            .onChange(of: coordinator.importedConversationID) { _, id in
                guard let id else { return }
                onImportedConversation(id)
                coordinator.consumeImportedConversation()
            }
    }
}

private extension View {
    func skillImport(
        coordinator: SkillImportCoordinator,
        ready: Bool,
        onProposalPresented: @escaping () -> Void,
        onImportedSkill: @escaping (Skill) -> Void
    ) -> some View {
        modifier(SkillImportModifier(
            coordinator: coordinator,
            ready: ready,
            onProposalPresented: onProposalPresented,
            onImportedSkill: onImportedSkill
        ))
    }

    func conversationImport(
        coordinator: ConversationImportCoordinator,
        conversations: ConversationManager,
        ready: Bool,
        onProposalPresented: @escaping () -> Void,
        onImportedConversation: @escaping (UUID) -> Void
    ) -> some View {
        modifier(ConversationImportModifier(
            coordinator: coordinator,
            conversations: conversations,
            ready: ready,
            onProposalPresented: onProposalPresented,
            onImportedConversation: onImportedConversation
        ))
    }
}

struct RootView: View {
    private enum StartupRecovery: Equatable {
        case manual
        case updateBuild
        case locateFolder
        case missingFolder

        var title: LocalizedStringKey {
            switch self {
            case .manual: "Ox Couldn't Open Your Data"
            case .updateBuild: "Update Ox to Continue"
            case .locateFolder, .missingFolder: "Profile Folder Not Found"
            }
        }
    }

    private enum Startup: Equatable {
        case idle
        case openingStorage
        case loadingProfile
        case deferred
        case failed(message: String, recovery: StartupRecovery)
        case ready

        var canBegin: Bool {
            switch self {
            case .idle, .deferred, .failed: true
            case .openingStorage, .loadingProfile, .ready: false
            }
        }

        func sidebarContentState(listing: ConversationManager.SummaryListing) -> ConversationSidebar.ContentState {
            switch (self, listing) {
            case (.failed, _): .unavailable
            case (.ready, _), (_, .partial), (_, .paging), (_, .complete): .ready
            case (.idle, .pending), (.openingStorage, .pending), (.loadingProfile, .pending), (.deferred, .pending): .loading
            }
        }
    }

    private enum Presentation: Identifiable {
        case settings(profileID: UUID?, skillDraft: SkillDraft?)
        case services(conversationID: UUID)

        var id: String {
            switch self {
            case .settings: "settings"
            case .services: "services"
            }
        }

    }

    private let client: OxClient
    private let skillImports: SkillImportCoordinator
    private let conversationImports: ConversationImportCoordinator
    private var manager: ServiceManager { client.services }
    private var storage: StorageRoot { .shared }
    @State private var locatingMissingProfile = false
    @State private var profileLocationError: String?
    @State private var conversations: ConversationManager
    @State private var compactPage: CompactPage = .workspace
    @State private var showSplitSidebar = true
    @State private var splitSidebarWidth: CGFloat?
    @State private var compactSidebarSummaries: [ConversationMeta] = []
    @State private var compactSidebarCurrentId: UUID?
    @State private var conversationTransition = ConversationTransition.idle
    @State private var composerFocusRequest: ComposerFocusRequest?
    @State private var presentation: Presentation?
    @State private var browserBlockerOwner = UUID()
    @State private var startup = Startup.idle
    @State private var activeProfileMonitor = ActiveProfileMonitor()
    @State private var childNavigationActive = false
    @State private var conversationHistoryRequestID = UUID()
    @State private var sharedNoteImporting = false
    @State private var sharedNoteImportError: String?
    @State private var sharedNoteComposer: (conversation: ObjectIdentifier, composer: ConversationComposerModel)?
    @State private var sidebarInteraction = SidebarInteraction()
    @State private var completionBanner: (id: UUID, conversationID: UUID, title: String, body: String)?
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        client: OxClient,
        skillImports: SkillImportCoordinator,
        conversationImports: ConversationImportCoordinator
    ) {
        self.client = client
        self.skillImports = skillImports
        self.conversationImports = conversationImports
        _conversations = State(initialValue: client.conversations)
    }

    private var isSplitLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    private var showSidebar: Bool {
        isSplitLayout ? showSplitSidebar : compactPage == .sidebar
    }

    var body: some View {
        observedRoot
            .overlay(alignment: .top) {
                if let banner = completionBanner {
                    Button {
                        completionBanner = nil
                        dismissKeyboard(via: "completionBanner")
                        openConversationFromSidebar(banner.conversationID)
                        Log.ui.info("Conversation.banner opened id=\(banner.conversationID)")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: banner.title)
                                .font(Theme.Fonts.labelMd)
                                .lineLimit(1)
                            Text(verbatim: banner.body)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .alertGlassPill(in: RoundedRectangle(cornerRadius: Theme.Radius.xl))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("conversation.completionBanner")
                    .accessibilityHint("Open completed conversation")
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, 4)
                }
            }
            .task(id: completionBanner?.id) {
                guard let banner = completionBanner else { return }
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, completionBanner?.id == banner.id else { return }
                completionBanner = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: IOSConversationFeedback.didComplete)) { notification in
                guard scenePhase == .active,
                      let id = notification.object as? UUID,
                      id != conversations.currentId,
                      conversations.contains(id),
                      let title = notification.userInfo?["title"] as? String,
                      let body = notification.userInfo?["body"] as? String else { return }
                completionBanner = (UUID(), id, title, completionPreview(body))
                Log.ui.info("Conversation.banner shown id=\(id)")
            }
            .onChange(of: conversations.current.map(ObjectIdentifier.init)) { _, identity in
                if sharedNoteComposer?.conversation != identity { sharedNoteComposer = nil }
                if completionBanner?.conversationID == conversations.currentId { completionBanner = nil }
            }
            .errorAlert("Couldn't Attach Shared Files", message: $sharedNoteImportError)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { completionBanner = nil }
                switch phase {
                case .background:
                    conversations.current?.setTranscriptVisible(false)
                    activeProfileMonitor.deactivate()
                    conversations.flushAll()
                case .active:
                    if startup == .deferred { bootstrap() }
                    conversations.current?.setTranscriptVisible(true)
                    Task {
                        await storage.revalidateActive()
                        monitorActiveProfile()
                        await reconcileActiveProfile(ProfileContentArea.all, reason: "foreground")
                        importSharedNotes()
                    }
                default:
                    conversations.current?.setTranscriptVisible(false)
                }
            }
            .environment(\.locale, AppLocale.shared.locale)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                if startup == .deferred { bootstrap() }
            }
    }

    private func completionPreview(_ source: String) -> String {
        guard let parsed = try? AttributedString(markdown: source) else { return source }
        return parsed.runs[\.presentationIntent]
            .map { _, range in String(parsed[range].characters) }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private var rootLayout: some View {
        let workspace = conversationLayer
        return GeometryReader { geo in
            if isSplitLayout {
                splitLayout(width: geo.size.width)
            } else {
                compactLayout(geo: geo, workspace: workspace)
            }
        }
        .background(Theme.Colors.surface, ignoresSafeAreaEdges: .all)
        .overlay {
            CurrentConversationActivityObserver(conversation: conversations.current, onAwaitingUser: handleAwaitingUser)
        }
        .onChange(of: compactPage) { _, page in
            if page == .sidebar { Haptics.impact(.sidebarSettled) }
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, _ in
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            Log.ui.info("RootView.layoutSwitch split=\(isSplitLayout)")
            sidebarInteraction.dragActive = false
            sidebarInteraction.actionsSuppressed = false
            if isSplitLayout {
                showSplitSidebar = true
            } else {
                compactPage = .workspace
            }
        }
    }

    private var presentedRoot: some View {
        rootLayout
            .sheet(item: $presentation, onDismiss: {
                AppPresentationCoordinator.shared.unblockBrowser(owner: browserBlockerOwner)
            }) { presented in
                Group {
                    switch presented {
                    case let .settings(profileID, skillDraft):
                        SettingsSheet(
                            initialProfileID: profileID,
                            initialSkillDraft: skillDraft,
                            ready: startup == .ready,
                            onSelectService: { startConversation(with: $0) }
                        )
                    case .services(let conversationID):
                        ServiceExplorePage(
                            onClose: dismissPresentation,
                            ready: startup == .ready,
                            primaryAction: .attach,
                            browserSessionID: conversationID,
                            isAttached: { service in isServiceAttached(service, to: conversationID) },
                            onSelect: { selectService($0, for: conversationID) }
                        )
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.background)
            }
            .skillImport(
                coordinator: skillImports,
                ready: startup == .ready,
                onProposalPresented: { presentation = nil },
                onImportedSkill: handleImportedSkill
            )
        .conversationImport(
            coordinator: conversationImports,
            conversations: conversations,
            ready: startup == .ready,
            onProposalPresented: { presentation = nil },
            onImportedConversation: handleImportedConversation
        )
    }

    private var observedRoot: some View {
        presentedRoot
            .onAppear {
                bootstrap()
            }
            .onChange(of: presentation?.id, initial: true) { _, presented in
                if presented != nil {
                    AppPresentationCoordinator.shared.blockBrowser(owner: browserBlockerOwner)
                }
            }
            .onDisappear {
                activeProfileMonitor.deactivate()
                AppPresentationCoordinator.shared.unblockBrowser(owner: browserBlockerOwner)
            }
            .onChange(of: storage.switchEpoch) { _, _ in
                completionBanner = nil
                Log.ui.info("RootView.profileSwitch epoch=\(storage.switchEpoch) root=\(storage.root.path)")
                monitorActiveProfile()
                refreshCompactSidebar()
            }
            .onChange(of: conversations.summaries) { _, _ in
                if let banner = completionBanner, !conversations.contains(banner.conversationID) { completionBanner = nil }
                refreshCompactSidebar()
            }
            .onChange(of: AppLocale.shared.language) { _, _ in
                reloadServiceLocale()
            }
            .onChange(of: AppRegion.shared.region) { _, _ in
                reloadServiceLocale()
            }
    }

    private func handleImportedSkill(_ skill: Skill) {
        presentation = .settings(
            profileID: storage.activeId,
            skillDraft: SkillDraft(skill)
        )
    }

    private func handleImportedConversation(_ id: UUID) {
        Log.ui.info("RootView.importedConversation id=\(id)")
        setSidebar(false)
        refreshCompactSidebar()
    }

    private func handleAwaitingUser() {
        dismissLibraryPresentation()
        Log.ui.info("RootView.awaitingUser conversation=\(conversations.currentId?.uuidString ?? "none") split=\(isSplitLayout)")
        autoCloseSidebar()
    }

    private func compactLayout(geo: GeometryProxy, workspace: some View) -> some View {
        CompactPageLayout(
            page: $compactPage,
            size: geo.size,
            safeAreaInsets: geo.safeAreaInsets,
            interaction: sidebarInteraction,
            gestureEnabled: !childNavigationActive,
            onOpeningDrag: {
                refreshCompactSidebar()
                dismissKeyboard(via: "sidebarDrag")
            },
            onOpened: { refreshConversationSummaries(reason: "sidebarDrag") },
            sidebar: compactSidebarPanel,
            workspace: workspace
        )
    }

    private func splitLayout(width: CGFloat) -> some View {
        let limits = splitSidebarWidthLimits(for: width)
        let defaultWidth = max(280, min(width * 0.35, 360))
        let sidebarWidth = min(limits.upperBound, max(limits.lowerBound, splitSidebarWidth ?? defaultWidth))
        return HStack(spacing: 0) {
            if showSplitSidebar {
                sidebarPanel
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SplitSidebarResizer(
                            width: sidebarWidth,
                            limits: limits,
                            onResize: { splitSidebarWidth = $0 }
                        )
                        .offset(x: 14)
                        .zIndex(1)
                    }
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
            conversationLayer
        }
        .animation(sidebarAnimation, value: showSplitSidebar)
    }

    private func splitSidebarWidthLimits(for totalWidth: CGFloat) -> ClosedRange<CGFloat> {
        let minimum: CGFloat = 240
        let maximum = min(500, max(minimum, totalWidth - 360))
        return minimum...maximum
    }

    private var sidebarPanel: some View {
        makeSidebarPanel(
            summaries: conversations.summaries,
            currentId: conversations.currentId
        )
    }

    private var compactSidebarPanel: some View {
        makeSidebarPanel(
            summaries: compactSidebarSummaries,
            currentId: compactSidebarCurrentId
        )
        .equatable()
    }

    private func makeSidebarPanel(summaries: [ConversationMeta], currentId: UUID?) -> ConversationSidebar {
        ConversationSidebar(
            contentState: startup.sidebarContentState(listing: conversations.summaryListing),
            actionsEnabled: startup == .ready,
            summaries: summaries,
            canLoadMore: showSidebar && conversations.summaryListing.hasMore,
            activities: conversations.activities,
            currentId: currentId,
            showsCloseButton: !isSplitLayout,
            onClose: { setSidebar(false) },
            onLoadMore: { await conversations.loadMoreSummaries() },
            onSearch: { await conversations.loadAllSummaries() },
            onNewConversation: {
                sidebarAction("newConversation") {
                    let conversation = conversations.startNewConversation()
                    requestComposerFocus(for: conversation, reason: "newConversation")
                    autoCloseSidebar()
                }
            },
            onOpen: { meta in
                sidebarAction("openConversation") {
                    openConversationFromSidebar(meta.id)
                }
            },
            onDelete: { meta in
                sidebarAction("deleteConversation") {
                    conversations.delete(meta.id)
                    refreshCompactSidebar()
                }
            },
            onRename: { meta, title in
                sidebarAction("renameConversation") {
                    conversations.rename(meta.id, to: title)
                    refreshCompactSidebar()
                }
            },
            onToggleFavorite: { meta in
                sidebarAction("toggleFavorite") {
                    conversations.toggleFavorite(meta.id)
                    refreshCompactSidebar()
                }
            },
            onSettings: { sidebarAction("settings") {
                presentation = .settings(profileID: nil, skillDraft: nil)
            } }
        )
    }

    private func sidebarAction(_ name: String, perform: () -> Void) {
        guard startup == .ready, !sidebarInteraction.actionsSuppressed else {
            Log.ui.info("RootView.sidebarAction suppressed=\(name)")
            return
        }
        perform()
    }

    @ViewBuilder
    private var conversationLayer: some View {
        if case .failed(let message, let recovery) = startup {
            startupFailure(message: message, recovery: recovery)
        } else {
            readyConversationLayer
        }
    }

    @ViewBuilder
    private var readyConversationLayer: some View {
        ZStack {
            if let conversation = conversations.current,
               conversations.openingId == nil {
                ConversationPage(conversation: conversation,
                         historyOpenRequestID: conversationHistoryRequestID,
                         isCurrentConversation: { conversations.current === conversation },
                         allowsReviewRequest: startup == .ready && presentation == nil && (isSplitLayout || !showSidebar),
                         composerFocusRequestID: composerFocusRequest?.conversationIdentity == ObjectIdentifier(conversation)
                             ? composerFocusRequest?.id
                             : nil,
                         onComposerFocusRequestHandled: handleComposerFocusRequest,
                         onShowSidebar: { setSidebar(isSplitLayout ? !showSidebar : true) },
                         onToggleTemporary: { conversations.toggleTemporaryConversation() },
                         onDeleteConversation: { conversations.delete(conversation.id) },
                         onBranch: { blockId in conversations.branch(from: conversation, atBlock: blockId) },
                         onOpenConversation: { id in
                             openConversation(id)
                         },
                         onRenameFile: { file, newFilename in
                             try await conversations.renameFile(file, to: newFilename)
                         },
                         onDeleteFile: { file in
                             try await conversations.deleteFile(file)
                         },
                         onExploreServices: { showServices(for: conversation.id) },
                         onFileNavigationChange: setChildNavigationActive,
                         onInitialTranscriptPresented: { finishConversationOpening(conversation.id) },
                         composer: sharedNoteComposer.flatMap {
                             $0.conversation == ObjectIdentifier(conversation) ? $0.composer : nil
                         } ?? ConversationComposerModel())
                    .onAppear {
                        conversation.setTranscriptVisible(scenePhase == .active)
                    }
                    .onDisappear { conversation.setTranscriptVisible(false) }
                    .id(ObjectIdentifier(conversation))
                    .opacity(conversationTransition == .idle ? 1 : 0)
            }

            if conversations.current == nil
                || conversations.openingId != nil
                || conversationTransition != .idle {
                Group {
                    if let progress = storage.migrationProgress {
                        ProfileMigrationProgressView(stage: progress,
                                                     automationID: "startup.profileMigration")
                    } else {
                        CellularAutomatonLoader()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.conversationSurface.opacity(isSplitLayout ? 1 : 0))
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    private func startupFailure(message: String, recovery: StartupRecovery) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title.weight(.medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Text(recovery.title)
                .font(Theme.Fonts.headline)
            Text(message)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.Spacing.sm) {
                if recovery != .updateBuild {
                    Button("Try Again") { bootstrap() }
                        .buttonStyle(.bordered)
                        .tint(Theme.Colors.primary)
                }
                if recovery == .locateFolder {
                    Button("Locate Folder…") { locatingMissingProfile = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("startup.locateProfile")
                }
            }
            .font(Theme.Fonts.labelMd)
            if !storage.otherProfiles.isEmpty {
                Menu {
                    ForEach(storage.otherProfiles) { profile in
                        Button(profile.name) { switchStartupProfile(to: profile) }
                            .accessibilityIdentifier("startup.switchProfile.\(profile.id)")
                    }
                } label: {
                    Text("Switch Profile")
                        .font(Theme.Fonts.labelMd)
                        .padding(.horizontal, Theme.Spacing.md)
                        .minimumTouchTarget()
                }
                .tint(Theme.Colors.primary)
                .accessibilityIdentifier("startup.switchProfile")
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.conversationSurface)
        .fileImporter(isPresented: $locatingMissingProfile, allowedContentTypes: [.folder]) { result in
            do {
                guard let id = StorageRoot.shared.unavailableActiveID else { return }
                try StorageRoot.shared.locateProfile(at: result.get(), expectedID: id)
                bootstrap()
            } catch { profileLocationError = error.localizedDescription }
        }
        .errorAlert("Couldn't Locate Profile", message: $profileLocationError)
    }

    private func switchStartupProfile(to profile: Profile) {
        Log.app.info("RootView.startup switchProfile id=\(profile.id)")
        do {
            try storage.prefer(profile)
            bootstrap()
        } catch {
            startup = .failed(message: error.localizedDescription, recovery: .manual)
        }
    }

    private func autoCloseSidebar() {
        guard !isSplitLayout else { return }
        setSidebar(false)
    }

    private func openConversationFromSidebar(_ id: UUID) {
        guard !isSplitLayout, showSidebar else {
            conversationTransition = .idle
            openConversation(id)
            return
        }
        compactSidebarCurrentId = id
        guard conversations.currentId != id else {
            conversationTransition = .idle
            openConversation(id)
            setSidebar(false)
            return
        }
        conversationTransition = .opening
        conversations.open(id)
        if conversations.currentId == id {
            conversationTransition = .idle
            Log.ui.info("ConversationUX.lifecycle conversation=\(id) phase=shellOpening source=memory")
        } else {
            Log.ui.info("ConversationUX.lifecycle conversation=\(id) phase=shellOpening source=storage")
        }
        setSidebar(false)
    }

    private func finishConversationOpening(_ visibleId: UUID) {
        guard isAwaitingPresentation(of: visibleId) else { return }
        DispatchQueue.main.async {
            guard isAwaitingPresentation(of: visibleId) else { return }
            withAnimation(reduceMotion ? nil : Theme.Animation.quick) {
                conversationTransition = .idle
            }
            Log.ui.info("ConversationUX.lifecycle conversation=\(visibleId) phase=shellReady")
        }
    }

    private func isAwaitingPresentation(of visibleId: UUID) -> Bool {
        conversationTransition == .opening && conversations.openingId == nil && conversations.currentId == visibleId
    }

    private func openConversation(_ id: UUID) {
        guard conversations.currentId != id else {
            conversationHistoryRequestID = UUID()
            return
        }
        conversationTransition = .opening
        conversations.open(id)
    }

    private func showServices(for conversationID: UUID) {
        presentation = .services(conversationID: conversationID)
        Log.ui.info("RootView.presentation show=services origin=conversation:\(conversationID)")
    }

    private func selectService(_ service: Service, for conversationID: UUID) {
        guard conversations.contains(conversationID), let conversation = conversations.current, conversation.id == conversationID else {
            Log.ui.error("RootView.servicesAttach missingConversation id=\(conversationID) service=\(service.domain)")
            returnToConversation(conversationID)
            return
        }
        if conversation.attachedServices.contains(where: { $0.domain == service.domain }) {
            conversation.setAttachedServices(conversation.attachedServices.filter { $0.domain != service.domain })
            Log.ui.info("RootView.servicesRemove conversation=\(conversationID) service=\(service.domain)")
        } else {
            conversation.attachService(service)
            Haptics.impact(.serviceAttached)
            Log.ui.info("RootView.servicesAttach conversation=\(conversationID) service=\(service.domain)")
        }
        returnToConversation(conversationID)
    }

    private func isServiceAttached(_ service: Service, to conversationID: UUID) -> Bool {
        guard let conversation = conversations.current, conversation.id == conversationID else { return false }
        return conversation.attachedServices.contains { $0.domain == service.domain }
    }

    private func returnToConversation(_ id: UUID) {
        if conversations.contains(id) {
            openConversation(id)
        } else {
            Log.ui.warning("RootView.servicesReturn missingConversation id=\(id)")
            if conversations.current == nil { conversations.startNewConversation() }
        }
        presentation = nil
        Log.ui.info("RootView.servicesReturn conversation=\(id)")
    }

    private func startConversation(with service: Service) {
        Log.ui.info("RootView.servicesStartConversation service=\(service.domain)")
        let conversation = conversations.startNewConversation()
        conversation.setAttachedServices([service])
        requestComposerFocus(for: conversation, reason: "serviceStartConversation")
        presentation = nil
    }

    private func requestComposerFocus(for conversation: Conversation, reason: String) {
        let request = ComposerFocusRequest(conversationIdentity: ObjectIdentifier(conversation), reason: reason)
        composerFocusRequest = request
        Log.ui.info("ConversationUX.intent conversation=\(conversation.id) kind=focusRequest phase=requested request=\(request.id) reason=\(reason)")
    }

    private func handleComposerFocusRequest(_ id: UUID) {
        guard composerFocusRequest?.id == id else { return }
        composerFocusRequest = nil
    }

    private func dismissPresentation() {
        guard let presentation else { return }
        Log.ui.info("RootView.presentation dismiss=\(presentation.id)")
        self.presentation = nil
    }

    private func dismissLibraryPresentation() {
        switch presentation {
        case .services(_):
            dismissPresentation()
        case .settings, nil:
            return
        }
    }

    private func renameFile(
        _ file: FileItem,
        to newFilename: String,
        in scope: ProfileScope
    ) async throws -> FileItem {
        if scope.profileID == storage.activeId {
            return try await conversations.renameFile(file, to: newFilename)
        }
        return try await ProfileRepository.shared.renameFile(
            named: file.fileName,
            to: newFilename,
            in: scope
        )
    }

    private func deleteFile(_ file: FileItem, in scope: ProfileScope) async throws {
        if scope.profileID == storage.activeId {
            try await conversations.deleteFile(file)
            return
        }
        _ = try await ProfileRepository.shared.deleteFile(named: file.fileName, in: scope)
    }

    private func setChildNavigationActive(_ active: Bool) {
        guard childNavigationActive != active else { return }
        childNavigationActive = active
        Log.ui.info("RootView.childNavigation active=\(active)")
    }

    private static let sidebarSpring: Animation = .smooth(duration: 0.3)

    private var sidebarAnimation: Animation {
        reduceMotion ? Theme.Animation.quick : (isSplitLayout ? Self.sidebarSpring : Theme.Animation.page)
    }

    private func setSidebar(_ open: Bool) {
        guard !open || conversations.current?.activity.isAwaitingUser != true else {
            Log.ui.info("RootView.sidebarOpen suppressed=awaitingUser conversation=\(conversations.currentId?.uuidString ?? "none")")
            return
        }
        if open { dismissKeyboard(via: "sidebarOpen") }
        if open {
            refreshCompactSidebar()
        }
        withAnimation(sidebarAnimation, completionCriteria: .removed) {
            if isSplitLayout {
                showSplitSidebar = open
            } else {
                compactPage = open ? .sidebar : .workspace
            }
        } completion: {
            if open, showSidebar { refreshConversationSummaries(reason: "sidebar") }
        }
    }

    private func dismissKeyboard(via: String) {
        Log.ui.info("ConversationUX.intent conversation=\(conversations.currentId?.uuidString ?? "none") kind=dismissKeyboard via=\(via)")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func bootstrap() {
        guard startup.canBegin else { return }
        transitionStartup(to: .openingStorage)
        loadProfile()
    }

    private var serviceLocale: String? {
        AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
    }

    private func reloadServiceLocale() {
        let locale = serviceLocale
        Task { await manager.reloadServices(locale: locale) }
    }

    private func loadProfile() {
        Task {
            do {
                try await client.prepareStorage()
                withAnimation(reduceMotion ? Theme.Animation.press : Theme.Animation.standard, completionCriteria: .logicallyComplete) {
                    if conversations.current == nil { conversations.startNewConversation() }
                    transitionStartup(to: .loadingProfile)
                } completion: {
                    if let conversation = conversations.current, isSplitLayout || !showSidebar {
                        requestComposerFocus(for: conversation, reason: "appEntry")
                    }
                }
                try await client.prepare()
                refreshCompactSidebar()
                transitionStartup(to: .ready)
                monitorActiveProfile()
                importSharedNotes()
            } catch {
                let systemError = error as NSError
                let recovery: StartupRecovery?
                if case .unsupportedProfileVersion? = error as? StorageMigrationError {
                    recovery = .updateBuild
                } else if case .externalProfileUnavailable? = error as? StorageMigrationError {
                    recovery = .locateFolder
                } else if case .activeProfileUnavailable? = error as? StorageMigrationError {
                    recovery = .missingFolder
                } else if systemError.domain == NSOSStatusErrorDomain && systemError.code == Int(errSecMissingEntitlement) {
                    recovery = .updateBuild
                } else {
                    recovery = nil
                }
                if let recovery {
                    startup = .failed(message: error.localizedDescription, recovery: recovery)
                } else {
                    transitionStartup(to: .deferred)
                }
                Log.app.error("RootView.startup failed domain=\(systemError.domain) code=\(systemError.code) recovery=\(recovery.map { String(describing: $0) } ?? "deferred") retry=foreground error=\(error.localizedDescription)")
            }
        }
    }

    private func importSharedNotes() {
        guard startup == .ready, !sharedNoteImporting else { return }
        sharedNoteImporting = true
        Task {
            let outcome = await SharedNoteInbox.consume()
            if !outcome.staged.isEmpty {
                let conversation = conversations.startNewConversation(reusingEmpty: false)
                let composer = ConversationComposerModel()
                composer.attach(outcome.staged)
                sharedNoteComposer = (ObjectIdentifier(conversation), composer)
                conversationTransition = .idle
                presentation = nil
                setSidebar(false)
                requestComposerFocus(for: conversation, reason: "sharedFiles")
                Log.ui.info("ShareImport.staged conversation=\(conversation.id) count=\(outcome.staged.count)")
            }
            let failures = outcome.failures + (await outcome.acknowledge())
            sharedNoteImporting = false
            if !failures.isEmpty {
                sharedNoteImportError = failures.joined(separator: "\n")
                Log.ui.error("ShareImport.failed count=\(failures.count)")
            }
        }
    }

    private func transitionStartup(to phase: Startup) {
        startup = phase
        Log.ui.info("RootView.startup phase=\(String(describing: phase))")
    }

    private func refreshCompactSidebar() {
        compactSidebarSummaries = conversations.summaries
        compactSidebarCurrentId = conversations.currentId
    }

    private func refreshConversationSummaries(reason: String) {
        guard startup == .ready else { return }
        Task {
            let startedAt = Date()
            await conversations.loadSummariesNow()
            refreshCompactSidebar()
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Log.ui.info("RootView.conversationSummaries reason=\(reason) durationMs=\(durationMs) count=\(conversations.summaries.count)")
        }
    }

    private func monitorActiveProfile() {
        guard startup == .ready, scenePhase != .background else { return }
        let scope = storage.scope
        activeProfileMonitor.activate(scope: scope) { areas in
            Task { await reconcileActiveProfile(areas, reason: "filesystem") }
        }
    }

    private func reconcileActiveProfile(_ areas: Set<ProfileContentArea>, reason: String) async {
        guard startup == .ready else { return }
        let startedAt = Date()
        let scope = storage.scope
        if areas.contains(.configuration) {
            await storage.revalidateActive()
            guard storage.scope == scope else { return }
        }
        if areas.contains(.memory) {
            UserMemory.shared.reload()
        }
        if areas.contains(.skills) {
            Skills.shared.refresh()
        }
        if areas.contains(.files) {
            conversations.filesChanged()
        }
        if areas.contains(.conversations), reason != "filesystem" || showSidebar {
            await conversations.loadSummariesNow()
            refreshCompactSidebar()
        }
        do {
            if areas.contains(.memory) { try await UserMemory.shared.waitUntilCurrent() }
        } catch { Log.app.error("RootView Profile reconciliation failed: \(error.localizedDescription)"); return }
        if areas.contains(.skills) {
            await Skills.shared.waitUntilCurrent()
        }
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let names = areas.map(\.rawValue).sorted().joined(separator: ",")
        Log.app.info("RootView.reconcileActiveProfile reason=\(reason) areas=\(names) durationMs=\(durationMs)")
    }
}

extension ConversationSidebar: Equatable {
    static func == (lhs: ConversationSidebar, rhs: ConversationSidebar) -> Bool {
        lhs.summaries == rhs.summaries
            && lhs.canLoadMore == rhs.canLoadMore
            && lhs.contentState == rhs.contentState
            && lhs.actionsEnabled == rhs.actionsEnabled
            && lhs.activities == rhs.activities
            && lhs.currentId == rhs.currentId
            && lhs.showsCloseButton == rhs.showsCloseButton
    }
}

#Preview {
    let serviceManager = ServiceManager()
    RootView(
        client: OxClient.preview(serviceManager: serviceManager),
        skillImports: SkillImportCoordinator(),
        conversationImports: ConversationImportCoordinator()
    )
        .environment(serviceManager)
}
