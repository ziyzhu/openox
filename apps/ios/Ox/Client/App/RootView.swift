import SwiftUI
import UIKit
import WebKit
import Security

@Observable
final class SidebarInteraction {
    private struct PageSwitchExclusion {
        let bounds: CGRect
        let includesAreaBelow: Bool

        func contains(_ point: CGPoint) -> Bool {
            includesAreaBelow ? point.y >= bounds.minY : bounds.contains(point)
        }
    }

    var dragActive = false
    var actionsSuppressed = false
    private var pageSwitchExclusions: [UUID: PageSwitchExclusion] = [:]

    func setPageSwitchExclusion(owner: UUID, bounds: CGRect, includesAreaBelow: Bool) {
        pageSwitchExclusions[owner] = PageSwitchExclusion(bounds: bounds, includesAreaBelow: includesAreaBelow)
    }

    func clearPageSwitchExclusion(owner: UUID) {
        pageSwitchExclusions.removeValue(forKey: owner)
    }

    func excludesPageSwitch(at point: CGPoint) -> Bool {
        pageSwitchExclusions.values.contains { $0.contains(point) }
    }
}

extension EnvironmentValues {
    @Entry var sidebarInteraction = SidebarInteraction()
}

private struct PageSwitchExclusionModifier: ViewModifier {
    let includesAreaBelow: Bool
    @Environment(\.sidebarInteraction) private var sidebarInteraction
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds in
                sidebarInteraction.setPageSwitchExclusion(owner: owner, bounds: bounds, includesAreaBelow: includesAreaBelow)
            }
            .onDisappear {
                sidebarInteraction.clearPageSwitchExclusion(owner: owner)
            }
    }
}

extension View {
    func excludesCompactPageSwitch(includingAreaBelow: Bool = false) -> some View {
        modifier(PageSwitchExclusionModifier(includesAreaBelow: includingAreaBelow))
    }
}

private enum CompactPage: String {
    case sidebar
    case workspace
}

private enum CompactChatTransition: Equatable {
    case idle
    case closing(UUID)
    case opening(UUID)

    var isClosing: Bool {
        if case .closing = self { true } else { false }
    }

    var openingChatId: UUID? {
        guard case .opening(let id) = self else { return nil }
        return id
    }
}

private struct CompactPageLayout<Sidebar: View, Workspace: View>: View {
    private enum DragPhase: Equatable {
        case idle
        case rejected
        case active(origin: CompactPage, translation: CGFloat)

        var translation: CGFloat {
            guard case .active(_, let translation) = self else { return 0 }
            return translation
        }
    }

    @Binding var page: CompactPage
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let interaction: SidebarInteraction
    let gestureEnabled: Bool
    let onOpeningDrag: () -> Void
    let sidebar: Sidebar
    let workspace: Workspace

    @State private var dragPhase = DragPhase.idle
    @State private var settlingBlurRadius: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let minimumDistance: CGFloat = 8
    private let horizontalIntentRatio: CGFloat = 1.2
    private let maximumBlurRadius: CGFloat = 5
    private let blurRamp = Animation.smooth(duration: 0.07)

    private var travel: CGFloat {
        let settled = page == .sidebar ? size.width : 0
        return min(size.width, max(0, settled + dragPhase.translation))
    }

    private var progress: CGFloat {
        guard size.width > 0 else { return 0 }
        return travel / size.width
    }

    private var blurAllowed: Bool {
        !reduceMotion && !reduceTransparency
    }

    private var blurRadius: CGFloat {
        guard blurAllowed else { return 0 }
        return max(dragBlurRadius, settlingBlurRadius)
    }

    private var dragBlurRadius: CGFloat {
        guard case .active = dragPhase else { return 0 }
        return maximumBlurRadius * progress
    }

    var body: some View {
        ZStack(alignment: .leading) {
            sidebar
                .frame(width: size.width)
                .offset(x: reduceMotion ? 0 : travel - size.width)
                .opacity(reduceMotion ? progress : 1)
                .allowsHitTesting(page == .sidebar && !interaction.actionsSuppressed)
                .accessibilityHidden(page != .sidebar)

            workspace
                .environment(\.sidebarInteraction, interaction)
                .safeAreaPadding(safeAreaInsets)
                .ignoresSafeArea(.container)
                .blur(radius: blurRadius)
                .offset(x: reduceMotion ? 0 : travel)
                .opacity(reduceMotion ? 1 - progress : 1)
                .allowsHitTesting(page == .workspace && !interaction.actionsSuppressed)
                .accessibilityHidden(page != .workspace)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(pageDrag, isEnabled: gestureEnabled)
        .onChange(of: blurAllowed) { _, allowed in
            if !allowed { settlingBlurRadius = 0 }
        }
    }

    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { value in
                switch dragPhase {
                case .idle:
                    guard !SelectableTextSelection.isActive else {
                        dragPhase = .rejected
                        Log.ui.info("RootView.sidebarDrag phase=rejected reason=textSelection")
                        return
                    }
                    guard page != .workspace || !interaction.excludesPageSwitch(at: value.startLocation) else {
                        dragPhase = .rejected
                        Log.ui.info("RootView.sidebarDrag phase=rejected reason=pageSwitchExclusion")
                        return
                    }
                    let horizontal = abs(value.translation.width) > abs(value.translation.height) * horizontalIntentRatio
                    let correctDirection = page == .workspace
                        ? value.translation.width > 0
                        : value.translation.width < 0
                    guard horizontal, correctDirection else {
                        dragPhase = .rejected
                        return
                    }
                    if page == .workspace { onOpeningDrag() }
                    settlingBlurRadius = 0
                    interaction.dragActive = true
                    interaction.actionsSuppressed = true
                    dragPhase = .active(
                        origin: page,
                        translation: translation(value.translation.width, from: page)
                    )
                    Log.ui.info("RootView.sidebarDrag phase=start page=\(page.rawValue) translation=\(Int(value.translation.width))")
                case .active(let origin, _):
                    dragPhase = .active(
                        origin: origin,
                        translation: translation(value.translation.width, from: origin)
                    )
                case .rejected:
                    return
                }
            }
            .onEnded { value in
                guard case .active(let origin, let translation) = dragPhase else {
                    dragPhase = .idle
                    return
                }
                let predicted = origin == .workspace
                    ? value.predictedEndTranslation.width
                    : -value.predictedEndTranslation.width
                let changesPage = max(abs(translation), predicted) > size.width * 0.3
                let target = changesPage ? opposite(of: origin) : origin
                Log.ui.info("RootView.sidebarDrag phase=end origin=\(origin.rawValue) translation=\(Int(translation)) predicted=\(Int(predicted)) target=\(target.rawValue)")
                if target != origin { Haptics.impact(.sidebarSettled) }
                settle(on: target)
            }
    }

    private func translation(_ translation: CGFloat, from origin: CompactPage) -> CGFloat {
        switch origin {
        case .workspace:
            min(size.width, max(0, translation))
        case .sidebar:
            min(0, max(-size.width, translation))
        }
    }

    private func opposite(of page: CompactPage) -> CompactPage {
        page == .sidebar ? .workspace : .sidebar
    }

    private func settle(on target: CompactPage) {
        let animation = reduceMotion ? Theme.Animation.press : RootView.sidebarSettleAnimation
        let returnsToOrigin = target == page
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            page = target
            dragPhase = .idle
        } completion: {
            interaction.dragActive = false
        }
        if returnsToOrigin { beginSettlingBlur() }
        Task { @MainActor in
            await Task.yield()
            interaction.actionsSuppressed = false
        }
    }

    private func beginSettlingBlur() {
        guard blurAllowed else { return }
        withAnimation(blurRamp, completionCriteria: .logicallyComplete) {
            settlingBlurRadius = maximumBlurRadius
        } completion: {
            withAnimation(Theme.Animation.quick) { settlingBlurRadius = 0 }
        }
    }
}

private struct CurrentChatActivityObserver: View {
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
                }
            }
            .alert("Couldn't import skill", isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.dismissError() } }
            )) {
                Button("OK", role: .cancel) { coordinator.dismissError() }
            } message: {
                Text(coordinator.errorMessage ?? "")
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
    let coordinator: ChatImportCoordinator
    let conversations: ConversationManager
    let ready: Bool
    let onProposalPresented: () -> Void
    let onImportedChat: (UUID) -> Void

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
                }
            }
            .alert("Couldn't import chat", isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.dismissError() } }
            )) {
                Button("OK", role: .cancel) { coordinator.dismissError() }
            } message: {
                Text(coordinator.errorMessage ?? "")
            }
            .onChange(of: coordinator.proposal?.id) { _, proposal in
                if proposal != nil { onProposalPresented() }
            }
            .onChange(of: coordinator.importedChatID) { _, id in
                guard let id else { return }
                onImportedChat(id)
                coordinator.consumeImportedChat()
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

    func chatImport(
        coordinator: ChatImportCoordinator,
        conversations: ConversationManager,
        ready: Bool,
        onProposalPresented: @escaping () -> Void,
        onImportedChat: @escaping (UUID) -> Void
    ) -> some View {
        modifier(ConversationImportModifier(
            coordinator: coordinator,
            conversations: conversations,
            ready: ready,
            onProposalPresented: onProposalPresented,
            onImportedChat: onImportedChat
        ))
    }
}

struct RootView: View {
    private enum StartupRecovery: Equatable {
        case manual
        case whenAvailable
        case updateBuild
    }

    private enum Startup: Equatable {
        case idle
        case openingStorage
        case loadingProfile
        case failed(message: String, recovery: StartupRecovery)
        case ready

        var canBegin: Bool {
            switch self {
            case .idle, .failed: true
            case .openingStorage, .loadingProfile, .ready: false
            }
        }

        var sidebarContentState: ConversationSidebar.ContentState {
            switch self {
            case .idle, .openingStorage, .loadingProfile: .loading
            case .failed: .unavailable
            case .ready: .ready
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
    private let chatImports: ChatImportCoordinator
    private var manager: ServiceManager { client.services }
    private var storage: StorageRoot { .shared }
    @State private var conversations: ConversationManager
    @State private var compactPage: CompactPage = .workspace
    @State private var showSplitSidebar = true
    @State private var splitSidebarWidth: CGFloat?
    @State private var compactSidebarSummaries: [ChatMeta] = []
    @State private var compactSidebarCurrentId: UUID?
    @State private var compactChatTransition = CompactChatTransition.idle
    @State private var pendingChatPresentationId: UUID?
    @State private var composerFocusRequest: ComposerFocusRequest?
    @State private var presentation: Presentation?
    @State private var startup = Startup.idle
    @State private var activeProfileMonitor = ActiveProfileMonitor()
    @State private var artifactRefreshEpoch = 0
    @State private var childNavigationActive = false
    @State private var sharedNoteImporting = false
    @State private var sharedNoteImportError: String?
    @State private var sharedNoteToast: Toast?
    @State private var sidebarInteraction = SidebarInteraction()
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        client: OxClient,
        skillImports: SkillImportCoordinator,
        chatImports: ChatImportCoordinator
    ) {
        self.client = client
        self.skillImports = skillImports
        self.chatImports = chatImports
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
            .toast($sharedNoteToast)
            .alert("Couldn't import shared note", isPresented: Binding(
                get: { sharedNoteImportError != nil },
                set: { if !$0 { sharedNoteImportError = nil } }
            )) {
                Button("OK", role: .cancel) { sharedNoteImportError = nil }
            } message: {
                Text(sharedNoteImportError ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    conversations.current?.setTranscriptVisible(false)
                    activeProfileMonitor.deactivate()
                    conversations.flushAll()
                case .active:
                    if case .failed(_, .whenAvailable) = startup { bootstrap() }
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
                if case .failed(_, .whenAvailable) = startup { bootstrap() }
            }
    }

    private var rootLayout: some View {
        GeometryReader { geo in
            if isSplitLayout {
                splitLayout(width: geo.size.width)
            } else {
                compactLayout(geo: geo)
            }
        }
        .background(Theme.Colors.surface, ignoresSafeAreaEdges: .all)
        .overlay {
            CurrentChatActivityObserver(conversation: conversations.current, onAwaitingUser: handleAwaitingUser)
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
            .sheet(item: $presentation) { presented in
                Group {
                    switch presented {
                    case let .settings(profileID, skillDraft):
                        SettingsSheet(
                            initialProfileID: profileID,
                            initialSkillDraft: skillDraft,
                            ready: startup == .ready,
                            artifactRefreshEpoch: artifactRefreshEpoch,
                            onRenameArtifact: renameArtifact,
                            onDeleteArtifact: deleteArtifact,
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
        .chatImport(
            coordinator: chatImports,
            conversations: conversations,
            ready: startup == .ready,
            onProposalPresented: { presentation = nil },
            onImportedChat: handleImportedChat
        )
    }

    private var observedRoot: some View {
        presentedRoot
            .onAppear {
                bootstrap()
            }
            .onDisappear {
                activeProfileMonitor.deactivate()
            }
            .onChange(of: storage.switchEpoch) { _, _ in
                Log.ui.info("RootView.profileSwitch epoch=\(storage.switchEpoch) root=\(storage.root.path)")
                Soul.shared.reload()
                UserMemory.shared.reload()
                Skills.shared.refresh()
                monitorActiveProfile()
                conversations.reset()
                Task {
                    do {
                        try await Soul.shared.waitUntilCurrent()
                        try await UserMemory.shared.waitUntilCurrent()
                        await Skills.shared.waitUntilCurrent()
                        conversations.startNewChat()
                        await conversations.loadSummariesNow()
                        refreshCompactSidebar()
                    } catch { Log.app.error("RootView Profile documents unavailable: \(error.localizedDescription)") }
                }
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

    private func handleImportedChat(_ id: UUID) {
        Log.ui.info("RootView.importedChat id=\(id)")
        setSidebar(false)
        refreshCompactSidebar()
    }

    private func handleAwaitingUser() {
        dismissLibraryPresentation()
        Log.ui.info("RootView.awaitingUser conversation=\(conversations.currentId?.uuidString ?? "none") split=\(isSplitLayout)")
        autoCloseSidebar()
    }

    private func compactLayout(geo: GeometryProxy) -> some View {
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
            sidebar: compactSidebarPanel,
            workspace: chatLayer
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
            chatLayer
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

    private func makeSidebarPanel(summaries: [ChatMeta], currentId: UUID?) -> ConversationSidebar {
        ConversationSidebar(
            contentState: startup.sidebarContentState,
            summaries: summaries,
            activities: conversations.activities,
            currentId: currentId,
            showsCloseButton: !isSplitLayout,
            onClose: { setSidebar(false) },
            onNewChat: {
                sidebarAction("newChat") {
                    let conversation = conversations.startNewChat()
                    requestComposerFocus(for: conversation, reason: "newChat")
                    autoCloseSidebar()
                }
            },
            onOpen: { meta in
                sidebarAction("openChat") {
                    openChatFromSidebar(meta.id)
                }
            },
            onDelete: { meta in
                sidebarAction("deleteConversation") {
                    conversations.delete(meta.id)
                    refreshCompactSidebar()
                }
            },
            onRename: { meta, title in
                sidebarAction("renameChat") {
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
    private var chatLayer: some View {
        if case .failed(let message, let recovery) = startup {
            startupFailure(message: message, recovery: recovery)
        } else {
            readyChatLayer
        }
    }

    @ViewBuilder
    private var readyChatLayer: some View {
        ZStack {
            if let conversation = conversations.current,
               conversations.openingId == nil,
               !compactChatTransition.isClosing,
               pendingChatPresentationId == nil || pendingChatPresentationId == conversation.id {
                ConversationPage(conversation: conversation,
                         composerFocusRequestID: composerFocusRequest?.conversationIdentity == ObjectIdentifier(conversation)
                             ? composerFocusRequest?.id
                             : nil,
                         onComposerFocusRequestHandled: handleComposerFocusRequest,
                         onShowSidebar: { setSidebar(isSplitLayout ? !showSidebar : true) },
                         onToggleTemporary: { conversations.toggleTemporaryChat() },
                         onDeleteChat: { conversations.delete(conversation.id) },
                         onBranch: { blockId in conversations.branch(from: conversation, atBlock: blockId) },
                         onRenameArtifact: { artifact, newFilename in
                             try await conversations.renameArtifact(artifact, to: newFilename)
                         },
                         onDeleteArtifact: { artifact in
                             try await conversations.deleteArtifact(artifact)
                         },
                         onExploreServices: { showServices(for: conversation.id) },
                         onArtifactNavigationChange: setChildNavigationActive,
                         onInitialTranscriptPresented: { finishChatOpening(conversation.id) })
                    .onAppear {
                        conversation.setTranscriptVisible(scenePhase == .active)
                    }
                    .onDisappear { conversation.setTranscriptVisible(false) }
                    .id(ObjectIdentifier(conversation))
            }

            if conversations.current == nil
                || conversations.openingId != nil
                || compactChatTransition.isClosing
                || pendingChatPresentationId != nil {
                CellularAutomatonLoader()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.surface)
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
            Text("Ox couldn’t update your data")
                .font(Theme.Fonts.headline)
            Text(message)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .multilineTextAlignment(.center)
            if recovery != .updateBuild {
                Button("Try Again") { bootstrap() }
                    .font(Theme.Fonts.labelMd)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.chatSurface)
    }

    private func autoCloseSidebar() {
        guard !isSplitLayout else { return }
        setSidebar(false)
    }

    private func openChatFromSidebar(_ id: UUID) {
        Haptics.impact(.chatOpened)
        guard !isSplitLayout, showSidebar else {
            compactChatTransition = .idle
            openChat(id)
            return
        }
        compactSidebarCurrentId = id
        guard conversations.currentId != id else {
            compactChatTransition = .idle
            setSidebar(false)
            return
        }
        pendingChatPresentationId = id
        compactChatTransition = .closing(id)
        Log.ui.info("ChatUX.lifecycle conversation=\(id) phase=shellClosing")
        setSidebar(false, completionCriteria: .removed) {
            guard compactChatTransition == .closing(id) else { return }
            compactChatTransition = .opening(id)
            Log.ui.info("ChatUX.lifecycle conversation=\(id) phase=shellOpening")
            conversations.open(id)
        }
    }

    private func finishChatOpening(_ visibleId: UUID) {
        guard pendingChatPresentationId == visibleId, conversations.openingId == nil else { return }
        DispatchQueue.main.async {
            guard pendingChatPresentationId == visibleId, conversations.openingId == nil else { return }
            withAnimation(reduceMotion ? nil : Theme.Animation.quick) {
                pendingChatPresentationId = nil
                compactChatTransition = .idle
            }
            Log.ui.info("ChatUX.lifecycle conversation=\(visibleId) phase=shellReady")
        }
    }

    private func openChat(_ id: UUID) {
        guard conversations.currentId != id else { return }
        pendingChatPresentationId = id
        conversations.open(id)
    }

    private func showServices(for conversationID: UUID) {
        presentation = .services(conversationID: conversationID)
        Log.ui.info("RootView.presentation show=services origin=conversation:\(conversationID)")
    }

    private func selectService(_ service: Service, for conversationID: UUID) {
        guard conversations.contains(conversationID), let conversation = conversations.current, conversation.id == conversationID else {
            Log.ui.error("RootView.servicesAttach missingChat id=\(conversationID) service=\(service.domain)")
            returnToChat(conversationID)
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
        returnToChat(conversationID)
    }

    private func isServiceAttached(_ service: Service, to conversationID: UUID) -> Bool {
        guard let conversation = conversations.current, conversation.id == conversationID else { return false }
        return conversation.attachedServices.contains { $0.domain == service.domain }
    }

    private func returnToChat(_ id: UUID) {
        if conversations.contains(id) {
            openChat(id)
        } else {
            Log.ui.warning("RootView.servicesReturn missingChat id=\(id)")
            if conversations.current == nil { conversations.startNewChat() }
        }
        presentation = nil
        Log.ui.info("RootView.servicesReturn conversation=\(id)")
    }

    private func startConversation(with service: Service) {
        Log.ui.info("RootView.servicesStartChat service=\(service.domain)")
        let conversation = conversations.startNewChat()
        conversation.setAttachedServices([service])
        requestComposerFocus(for: conversation, reason: "serviceStartChat")
        presentation = nil
    }

    private func requestComposerFocus(for conversation: Conversation, reason: String) {
        let request = ComposerFocusRequest(conversationIdentity: ObjectIdentifier(conversation), reason: reason)
        composerFocusRequest = request
        Log.ui.info("ChatUX.intent conversation=\(conversation.id) kind=focusRequest phase=requested request=\(request.id) reason=\(reason)")
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

    private func renameArtifact(
        _ artifact: Artifact,
        to newFilename: String,
        in scope: ProfileScope
    ) async throws -> Artifact {
        if scope.profileID == storage.activeId {
            return try await conversations.renameArtifact(artifact, to: newFilename)
        }
        return try await ProfileRepository.shared.renameArtifact(
            named: artifact.fileName,
            to: newFilename,
            in: scope
        )
    }

    private func deleteArtifact(_ artifact: Artifact, in scope: ProfileScope) async throws {
        if scope.profileID == storage.activeId {
            try await conversations.deleteArtifact(artifact)
            return
        }
        _ = try await ProfileRepository.shared.deleteArtifact(named: artifact.fileName, in: scope)
    }

    private func setChildNavigationActive(_ active: Bool) {
        guard childNavigationActive != active else { return }
        childNavigationActive = active
        Log.ui.info("RootView.childNavigation active=\(active)")
    }

    private static let sidebarSpring: Animation = .smooth(duration: 0.3)
    fileprivate static let sidebarSettleAnimation: Animation = .smooth(duration: 0.25)

    private var sidebarAnimation: Animation {
        reduceMotion ? Theme.Animation.quick : Self.sidebarSpring
    }

    private func setSidebar(
        _ open: Bool,
        completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
        completion: @escaping () -> Void = {}
    ) {
        guard !open || conversations.current?.activity.isAwaitingUser != true else {
            Log.ui.info("RootView.sidebarOpen suppressed=awaitingUser conversation=\(conversations.currentId?.uuidString ?? "none")")
            completion()
            return
        }
        if open { dismissKeyboard(via: "sidebarOpen") }
        if open {
            refreshCompactSidebar()
            refreshChatSummaries(reason: "sidebar")
        }
        withAnimation(sidebarAnimation, completionCriteria: completionCriteria) {
            if isSplitLayout {
                showSplitSidebar = open
            } else {
                compactPage = open ? .sidebar : .workspace
            }
        } completion: {
            completion()
        }
    }

    private func dismissKeyboard(via: String) {
        Log.ui.info("ChatUX.intent conversation=\(conversations.currentId?.uuidString ?? "none") kind=dismissKeyboard via=\(via)")
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
                    if conversations.current == nil { conversations.startNewChat() }
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
                let keychainError = error as NSError
                let recovery: StartupRecovery
                if keychainError.domain == NSOSStatusErrorDomain && keychainError.code == Int(errSecMissingEntitlement) {
                    recovery = .updateBuild
                } else if keychainError.domain == NSOSStatusErrorDomain
                    && [Int(errSecInteractionNotAllowed), Int(errSecNotAvailable)].contains(keychainError.code) {
                    recovery = .whenAvailable
                } else {
                    recovery = .manual
                }
                startup = .failed(message: error.localizedDescription, recovery: recovery)
                Log.app.error("RootView.startup failed domain=\(keychainError.domain) code=\(keychainError.code) recovery=\(String(describing: recovery)) error=\(error.localizedDescription)")
            }
        }
    }

    private func importSharedNotes() {
        guard startup == .ready, !sharedNoteImporting else { return }
        sharedNoteImporting = true
        let scope = storage.scope
        Task {
            let outcome = await SharedNoteInbox.consume(in: scope)
            sharedNoteImporting = false
            if !outcome.imported.isEmpty {
                artifactRefreshEpoch &+= 1
                sharedNoteToast = Toast(message: L10n.string("File added", comment: ""))
                Log.ui.info("ShareImport.imported count=\(outcome.imported.count) scope=\(scope.generation)")
            }
            if !outcome.failures.isEmpty {
                sharedNoteImportError = outcome.failures.joined(separator: "\n")
                Log.ui.error("ShareImport.failed count=\(outcome.failures.count) scope=\(scope.generation)")
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

    private func refreshChatSummaries(reason: String) {
        guard startup == .ready else { return }
        Task {
            let startedAt = Date()
            await conversations.loadSummariesNow()
            refreshCompactSidebar()
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Log.ui.info("RootView.chatSummaries reason=\(reason) durationMs=\(durationMs) count=\(conversations.summaries.count)")
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
        if areas.contains(.soul) {
            Soul.shared.reload()
        }
        if areas.contains(.memory) {
            UserMemory.shared.reload()
        }
        if areas.contains(.skills) {
            Skills.shared.refresh()
        }
        if areas.contains(.artifacts) {
            artifactRefreshEpoch &+= 1
            conversations.artifactFilesChanged()
        }
        if areas.contains(.chats), reason != "filesystem" || showSidebar {
            await conversations.loadSummariesNow()
            refreshCompactSidebar()
        }
        do {
            if areas.contains(.soul) { try await Soul.shared.waitUntilCurrent() }
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
            && lhs.contentState == rhs.contentState
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
        chatImports: ChatImportCoordinator()
    )
        .environment(serviceManager)
}
