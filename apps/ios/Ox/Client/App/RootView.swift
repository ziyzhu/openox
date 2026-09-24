import SwiftUI
import UIKit
import WebKit

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
    let chat: Chat?
    let onAwaitingUser: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: chat?.activity, initial: true) { _, activity in
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
    let chatID: UUID
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

private struct ChatImportModifier: ViewModifier {
    let coordinator: ChatImportCoordinator
    let chats: ChatManager
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
                    ChatImportView(proposal: proposal, coordinator: coordinator, chats: chats)
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
        chats: ChatManager,
        ready: Bool,
        onProposalPresented: @escaping () -> Void,
        onImportedChat: @escaping (UUID) -> Void
    ) -> some View {
        modifier(ChatImportModifier(
            coordinator: coordinator,
            chats: chats,
            ready: ready,
            onProposalPresented: onProposalPresented,
            onImportedChat: onImportedChat
        ))
    }
}

struct RootView: View {
    private enum StartupPhase: String {
        case opening
        case updating
        case loadingChats

        var label: LocalizedStringKey {
            switch self {
            case .opening: "Opening your Profile…"
            case .updating: "Updating your Profile…"
            case .loadingChats: "Loading your chats…"
            }
        }
    }

    private enum Startup: Equatable {
        case idle
        case loading(StartupPhase)
        case failed(String)
        case ready

        var canBegin: Bool {
            switch self {
            case .idle, .failed: true
            case .loading, .ready: false
            }
        }
    }

    private enum Presentation: Identifiable {
        case settings(profileID: UUID?, skillDraft: SkillDraft?)
        case services(chatID: UUID)

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
    @State private var chats: ChatManager
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
        _chats = State(initialValue: client.chats)
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
                    chats.current?.setTranscriptVisible(false)
                    activeProfileMonitor.deactivate()
                    chats.flushAll()
                case .active:
                    chats.current?.setTranscriptVisible(true)
                    Task {
                        await storage.revalidateActive()
                        monitorActiveProfile()
                        await reconcileActiveProfile(ProfileContentArea.all, reason: "foreground")
                        importSharedNotes()
                    }
                default:
                    chats.current?.setTranscriptVisible(false)
                }
            }
            .environment(\.locale, AppLocale.shared.locale)
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
            CurrentChatActivityObserver(chat: chats.current, onAwaitingUser: handleAwaitingUser)
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
                            onSelectService: { startChat(with: $0) }
                        )
                    case .services(let chatID):
                        ServiceExplorePage(
                            onClose: dismissPresentation,
                            ready: startup == .ready,
                            primaryAction: .attach,
                            browserSessionID: chatID,
                            isAttached: { service in isServiceAttached(service, to: chatID) },
                            onSelect: { selectService($0, for: chatID) }
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
            chats: chats,
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
                chats.reset()
                Task {
                    await Soul.shared.waitUntilCurrent()
                    await UserMemory.shared.waitUntilCurrent()
                    await Skills.shared.waitUntilCurrent()
                    chats.startNewChat()
                    await chats.loadSummariesNow()
                    refreshCompactSidebar()
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
        Log.ui.info("RootView.awaitingUser chat=\(chats.currentId?.uuidString ?? "none") split=\(isSplitLayout)")
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
            summaries: chats.summaries,
            currentId: chats.currentId
        )
    }

    private var compactSidebarPanel: some View {
        makeSidebarPanel(
            summaries: compactSidebarSummaries,
            currentId: compactSidebarCurrentId
        )
        .equatable()
    }

    private func makeSidebarPanel(summaries: [ChatMeta], currentId: UUID?) -> ChatSidebar {
        ChatSidebar(
            summaries: summaries,
            activities: chats.activities,
            currentId: currentId,
            showsCloseButton: !isSplitLayout,
            onClose: { setSidebar(false) },
            onNewChat: {
                sidebarAction("newChat") {
                    let chat = chats.startNewChat()
                    requestComposerFocus(for: chat, reason: "newChat")
                    autoCloseSidebar()
                }
            },
            onOpen: { meta in
                sidebarAction("openChat") {
                    openChatFromSidebar(meta.id)
                }
            },
            onDelete: { meta in
                sidebarAction("deleteChat") {
                    chats.delete(meta.id)
                    refreshCompactSidebar()
                }
            },
            onRename: { meta, title in
                sidebarAction("renameChat") {
                    chats.rename(meta.id, to: title)
                    refreshCompactSidebar()
                }
            },
            onToggleFavorite: { meta in
                sidebarAction("toggleFavorite") {
                    chats.toggleFavorite(meta.id)
                    refreshCompactSidebar()
                }
            },
            onSettings: { sidebarAction("settings") {
                presentation = .settings(profileID: nil, skillDraft: nil)
            } }
        )
    }

    private func sidebarAction(_ name: String, perform: () -> Void) {
        guard !sidebarInteraction.actionsSuppressed else {
            Log.ui.info("RootView.sidebarAction suppressed=\(name)")
            return
        }
        perform()
    }

    @ViewBuilder
    private var chatLayer: some View {
        ZStack {
            if startup == .ready {
                readyChatLayer
                    .transition(.opacity)
            } else {
                startupLoadingView
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var readyChatLayer: some View {
        ZStack {
            if let chat = chats.current,
               chats.openingId == nil,
               !compactChatTransition.isClosing,
               pendingChatPresentationId == nil || pendingChatPresentationId == chat.id {
                ChatPage(chat: chat,
                         composerFocusRequestID: composerFocusRequest?.chatID == chat.id
                             ? composerFocusRequest?.id
                             : nil,
                         onComposerFocusRequestHandled: handleComposerFocusRequest,
                         onShowSidebar: { setSidebar(isSplitLayout ? !showSidebar : true) },
                         onToggleTemporary: { chats.toggleTemporaryChat() },
                         onDeleteChat: { chats.delete(chat.id) },
                         onBranch: { blockId in chats.branch(from: chat, atBlock: blockId) },
                         onRenameArtifact: { artifact, newFilename in
                             try await chats.renameArtifact(artifact, to: newFilename)
                         },
                         onDeleteArtifact: { artifact in
                             try await chats.deleteArtifact(artifact)
                         },
                         onExploreServices: { showServices(for: chat.id) },
                         onArtifactNavigationChange: setChildNavigationActive,
                         onInitialTranscriptPresented: { finishChatOpening(chat.id) })
                    .onAppear {
                        chat.setTranscriptVisible(scenePhase == .active)
                    }
                    .onDisappear { chat.setTranscriptVisible(false) }
                    .id(chat.id)
            }

            if chats.current == nil
                || chats.openingId != nil
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

    private var startupLoadingView: some View {
        VStack(spacing: Theme.Spacing.sm) {
            switch startup {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.title.weight(.medium))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                Text("Ox couldn’t update your data")
                    .font(Theme.Fonts.headline)
                Text(message)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                Button("Try Again") { bootstrap() }
                    .buttonStyle(.borderedProminent)
            case .loading(let phase):
                CellularAutomatonLoader()
                Text(phase.label)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .revealed(after: .milliseconds(500), id: phase)
                    .accessibilityIdentifier(A11yID.Startup.status)
            case .idle, .ready:
                CellularAutomatonLoader()
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surface)
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
        guard chats.currentId != id else {
            compactChatTransition = .idle
            setSidebar(false)
            return
        }
        pendingChatPresentationId = id
        compactChatTransition = .closing(id)
        Log.ui.info("ChatUX.lifecycle chat=\(id) phase=shellClosing")
        setSidebar(false) {
            guard compactChatTransition == .closing(id) else { return }
            compactChatTransition = .opening(id)
            Log.ui.info("ChatUX.lifecycle chat=\(id) phase=shellOpening")
            chats.open(id)
        }
    }

    private func finishChatOpening(_ visibleId: UUID) {
        guard pendingChatPresentationId == visibleId, chats.openingId == nil else { return }
        DispatchQueue.main.async {
            guard pendingChatPresentationId == visibleId, chats.openingId == nil else { return }
            withAnimation(reduceMotion ? nil : Theme.Animation.quick) {
                pendingChatPresentationId = nil
                compactChatTransition = .idle
            }
            Log.ui.info("ChatUX.lifecycle chat=\(visibleId) phase=shellReady")
        }
    }

    private func openChat(_ id: UUID) {
        guard chats.currentId != id else { return }
        pendingChatPresentationId = id
        chats.open(id)
    }

    private func showServices(for chatID: UUID) {
        presentation = .services(chatID: chatID)
        Log.ui.info("RootView.presentation show=services origin=chat:\(chatID)")
    }

    private func selectService(_ service: Service, for chatID: UUID) {
        guard chats.contains(chatID), let chat = chats.current, chat.id == chatID else {
            Log.ui.error("RootView.servicesAttach missingChat id=\(chatID) service=\(service.domain)")
            returnToChat(chatID)
            return
        }
        if chat.attachedServices.contains(where: { $0.domain == service.domain }) {
            chat.setAttachedServices(chat.attachedServices.filter { $0.domain != service.domain })
            Log.ui.info("RootView.servicesRemove chat=\(chatID) service=\(service.domain)")
        } else {
            chat.attachService(service)
            Haptics.impact(.serviceAttached)
            Log.ui.info("RootView.servicesAttach chat=\(chatID) service=\(service.domain)")
        }
        returnToChat(chatID)
    }

    private func isServiceAttached(_ service: Service, to chatID: UUID) -> Bool {
        guard let chat = chats.current, chat.id == chatID else { return false }
        return chat.attachedServices.contains { $0.domain == service.domain }
    }

    private func returnToChat(_ id: UUID) {
        if chats.contains(id) {
            openChat(id)
        } else {
            Log.ui.warning("RootView.servicesReturn missingChat id=\(id)")
            if chats.current == nil { chats.startNewChat() }
        }
        presentation = nil
        Log.ui.info("RootView.servicesReturn chat=\(id)")
    }

    private func startChat(with service: Service) {
        Log.ui.info("RootView.servicesStartChat service=\(service.domain)")
        let chat = chats.startNewChat()
        chat.setAttachedServices([service])
        requestComposerFocus(for: chat, reason: "serviceStartChat")
        presentation = nil
    }

    private func requestComposerFocus(for chat: Chat, reason: String) {
        let request = ComposerFocusRequest(chatID: chat.id, reason: reason)
        composerFocusRequest = request
        Log.ui.info("ChatUX.intent chat=\(chat.id) kind=focusRequest phase=requested request=\(request.id) reason=\(reason)")
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
            return try await chats.renameArtifact(artifact, to: newFilename)
        }
        return try await ProfileRepository.shared.renameArtifact(
            named: artifact.fileName,
            to: newFilename,
            in: scope
        )
    }

    private func deleteArtifact(_ artifact: Artifact, in scope: ProfileScope) async throws {
        if scope.profileID == storage.activeId {
            try await chats.deleteArtifact(artifact)
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

    private func setSidebar(_ open: Bool, completion: @escaping () -> Void = {}) {
        guard !open || chats.current?.activity.isAwaitingUser != true else {
            Log.ui.info("RootView.sidebarOpen suppressed=awaitingUser chat=\(chats.currentId?.uuidString ?? "none")")
            completion()
            return
        }
        if open { dismissKeyboard(via: "sidebarOpen") }
        if open {
            refreshCompactSidebar()
            refreshChatSummaries(reason: "sidebar")
        }
        withAnimation(sidebarAnimation, completionCriteria: .logicallyComplete) {
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
        Log.ui.info("ChatUX.intent chat=\(chats.currentId?.uuidString ?? "none") kind=dismissKeyboard via=\(via)")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func bootstrap() {
        guard startup.canBegin else { return }
        transitionStartup(to: .opening)
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
                try await client.prepare { phase in
                    switch phase {
                    case .opening: transitionStartup(to: .opening)
                    case .updating: transitionStartup(to: .updating)
                    case .loadingChats: transitionStartup(to: .loadingChats)
                    }
                }
                await manager.refreshServices(locale: serviceLocale)
                let chat = chats.current ?? chats.startNewChat()
                refreshCompactSidebar()
                Log.ui.info("RootView.startup phase=ready")
                withAnimation(reduceMotion ? Theme.Animation.press : Theme.Animation.standard, completionCriteria: .logicallyComplete) {
                    startup = .ready
                } completion: {
                    requestComposerFocus(for: chat, reason: "appEntry")
                }
                monitorActiveProfile()
                importSharedNotes()
            } catch {
                startup = .failed(error.localizedDescription)
                Log.app.error("RootView.startup failed: \(error.localizedDescription)")
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
                sharedNoteToast = Toast(message: L10n.string("Note added to Artifacts", comment: ""))
                Log.ui.info("ShareImport.imported count=\(outcome.imported.count) scope=\(scope.generation)")
            }
            if !outcome.failures.isEmpty {
                sharedNoteImportError = outcome.failures.joined(separator: "\n")
                Log.ui.error("ShareImport.failed count=\(outcome.failures.count) scope=\(scope.generation)")
            }
        }
    }

    private func transitionStartup(to phase: StartupPhase) {
        startup = .loading(phase)
        Log.ui.info("RootView.startup phase=\(phase.rawValue)")
    }

    private func refreshCompactSidebar() {
        compactSidebarSummaries = chats.summaries
        compactSidebarCurrentId = chats.currentId
    }

    private func refreshChatSummaries(reason: String) {
        Task {
            let startedAt = Date()
            await chats.loadSummariesNow()
            refreshCompactSidebar()
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Log.ui.info("RootView.chatSummaries reason=\(reason) durationMs=\(durationMs) count=\(chats.summaries.count)")
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
        }
        if areas.contains(.chats), reason != "filesystem" || showSidebar {
            await chats.loadSummariesNow()
            refreshCompactSidebar()
        }
        if areas.contains(.soul) {
            await Soul.shared.waitUntilCurrent()
        }
        if areas.contains(.memory) {
            await UserMemory.shared.waitUntilCurrent()
        }
        if areas.contains(.skills) {
            await Skills.shared.waitUntilCurrent()
        }
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let names = areas.map(\.rawValue).sorted().joined(separator: ",")
        Log.app.info("RootView.reconcileActiveProfile reason=\(reason) areas=\(names) durationMs=\(durationMs)")
    }
}

extension ChatSidebar: Equatable {
    static func == (lhs: ChatSidebar, rhs: ChatSidebar) -> Bool {
        lhs.summaries == rhs.summaries
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
