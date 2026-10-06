import SwiftUI
import AVFAudio
import UIKit
import WebKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import Observation

@MainActor
@Observable
private final class ConversationBotControlPresenter: ServiceHandoffPresenting {
    private(set) var session: ServiceHandoffSession?
    let pageMount = WebPageMountCoordinator()

    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        guard self.session == nil else {
            Log.ui.warning("ConversationBotControlPresenter rejected domain=\(session.serviceDomain) reason=occupied")
            session.presentationFailed()
            return .failed
        }
        self.session = session
        pageMount.reconcile(page: session.page, ownerIDs: [session.id])
        Log.ui.info("ConversationBotControlPresenter present domain=\(session.serviceDomain)")
        let outcome = await session.run()
        if self.session === session {
            pageMount.clear()
            self.session = nil
        }
        Log.ui.info("ConversationBotControlPresenter finish domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
        return outcome
    }
}

@MainActor
@Observable
private final class ConversationServiceAuthPresenter: ServiceAuthPresenting {
    private(set) var session: ServiceAuthSession?
    let pageMount = WebPageMountCoordinator()

    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        if let outcome = await session.preflight(for: .seconds(1)) {
            Log.ui.info("ConversationServiceAuthPresenter preflight domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
            return outcome
        }
        guard self.session == nil else {
            Log.ui.warning("ConversationServiceAuthPresenter rejected domain=\(session.serviceDomain) reason=occupied")
            session.presentationFailed()
            return .failed
        }
        self.session = session
        pageMount.reconcile(page: session.page, ownerIDs: [session.id])
        Log.ui.info("ConversationServiceAuthPresenter present domain=\(session.serviceDomain)")
        let outcome = await session.run()
        if self.session === session {
            pageMount.clear()
            self.session = nil
        }
        Log.ui.info("ConversationServiceAuthPresenter finish domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
        return outcome
    }
}

private struct InlineServicePageHost: View {
    let anchor: Anchor<CGRect>
    let mount: WebPageMount

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry[anchor]
            MountedWebPageView(mount: mount)
                .frame(width: frame.width, height: frame.height)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: Theme.Radius.lg,
                        bottomTrailingRadius: Theme.Radius.lg,
                        style: .continuous
                    )
                )
                .position(x: frame.midX, y: frame.midY)
        }
        .clipped()
    }
}

private struct SidebarScrollLockModifier: ViewModifier {
    @Environment(\.sidebarInteraction) private var sidebarInteraction

    func body(content: Content) -> some View {
        content.scrollDisabled(sidebarInteraction.dragActive)
    }
}

private struct EmptyChatMark: View {
    private let strongCells: Set<Int> = [0, 3, 4, 5, 6, 7, 9, 10, 13, 14]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(at: row * 4 + column))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
    }

    private func color(at index: Int) -> Color {
        strongCells.contains(index)
            ? Theme.Colors.primary.dynamic
            : Color(uiColor: UIColor(hex: 0xFDF2D9))
    }
}

private struct ScrollToBottomButton: View {
    let composerButtonSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: composerButtonSize, height: composerButtonSize)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .minimumTouchTarget()
        .accessibilityLabel(A11yLabel.scrollToBottom)
        .accessibilityIdentifier(A11yID.Chat.scrollToBottom)
    }
}

private struct ScrollToBottomControl: View {
    let composer: ConversationComposerModel
    let composerFocused: Bool
    let isEditingMessage: Bool
    let hasArtifacts: Bool
    let hasAttachedServices: Bool
    let floatsTopStrip: Bool
    let composerButtonSize: CGFloat
    let action: () -> Void

    var body: some View {
        ScrollToBottomButton(composerButtonSize: composerButtonSize, action: action)
            .offset(y: offset)
    }

    private var offset: CGFloat {
        let touchTargetInset = max(0, (Theme.Size.minimumTouchTarget - composerButtonSize) / 2)
        let isResting = !composerFocused && composer.isEmpty && !isEditingMessage
        let showsTopStrip = isEditingMessage || hasArtifacts || hasAttachedServices
        let firstSurfaceTop = ConversationComposer.firstSurfaceTopOffset(
            isResting: isResting,
            showsTopStrip: showsTopStrip,
            floatsTopStrip: floatsTopStrip
        )
        return firstSurfaceTop - ConversationComposer.surfaceSpacing - composerButtonSize - touchTargetInset
    }
}

private struct ConversationTranscriptProjectionSnapshot {
    let key: ConversationTranscriptProjectionKey
    let totalBlockCount: Int
    let sourceRange: Range<Int>
    let sourceBlockIDs: [UUID]
    let blocks: [ConversationBlock]
    let latestCanvasBlockIDs: [URL: UUID]

    init(key: ConversationTranscriptProjectionKey, conversation: Conversation) {
        self.key = key
        let sourceWindow = conversation.blocksWithTurnID(in: key.requestedSourceRange)
        let projectedBlocks = ConversationBlock.project(
            sourceWindow.blocks,
            thinkingActivity: key.thinkingActivity,
            isBusy: key.isBusy,
            interaction: key.interaction
        )
        let requestedOffset = key.requestedSourceRange.lowerBound - sourceWindow.range.lowerBound
        let requestedSourceIDs = sourceWindow.blocks.dropFirst(requestedOffset).map(\.block.id)
        let blocks: [ConversationBlock]
        if requestedOffset > 0 {
            let requestedSourceIDSet = Set(requestedSourceIDs)
            blocks = projectedBlocks.filter {
                requestedSourceIDSet.contains($0.sourceBlockID) || $0.isActiveInteraction
            }
        } else {
            blocks = projectedBlocks
        }
        totalBlockCount = key.totalBlockCount
        sourceRange = key.requestedSourceRange
        sourceBlockIDs = requestedSourceIDs
        self.blocks = blocks
        latestCanvasBlockIDs = ConversationBlock.latestCanvasBlockIDs(in: sourceWindow.blocks.map(\.block))
    }
}

private struct ConversationTranscriptProjectionKey: Equatable {
    let conversationID: UUID
    let transcriptRevision: UInt64
    let totalBlockCount: Int
    let requestedSourceRange: Range<Int>
    let thinkingActivity: Conversation.ThinkingActivity?
    let isBusy: Bool
    let interaction: Conversation.Interaction?
}

private struct DelayedActivityKey: Equatable {
    let conversationID: UUID
    let activity: Conversation.Activity
    let transcriptRevision: UInt64
}

private final class ConversationTranscriptProjectionCache {
    private var snapshot: ConversationTranscriptProjectionSnapshot?

    func snapshot(for key: ConversationTranscriptProjectionKey, conversation: Conversation) -> ConversationTranscriptProjectionSnapshot {
        if let snapshot, snapshot.key == key { return snapshot }
        let resolved = ConversationTranscriptProjectionSnapshot(key: key, conversation: conversation)
        snapshot = resolved
        return resolved
    }
}

private struct ConversationTranscriptProjection<Content: View>: View {
    let conversation: Conversation
    let transcriptWindow: TranscriptWindow
    let interaction: Conversation.Interaction?
    let content: (ConversationTranscriptProjectionSnapshot) -> Content

    @State private var cache = ConversationTranscriptProjectionCache()

    var body: some View {
        content(cache.snapshot(for: projectionKey, conversation: conversation))
    }

    private var projectionKey: ConversationTranscriptProjectionKey {
        let totalBlockCount = conversation.transcriptBlockCount
        let requestedSourceRange = transcriptWindow.resolvedRange(total: totalBlockCount)
        return ConversationTranscriptProjectionKey(
            conversationID: conversation.id,
            transcriptRevision: conversation.transcriptRevision,
            totalBlockCount: totalBlockCount,
            requestedSourceRange: requestedSourceRange,
            thinkingActivity: conversation.thinkingActivity,
            isBusy: conversation.isBusy,
            interaction: interaction
        )
    }
}

struct ConversationPage: View {
    private enum SendHandoff: Equatable {
        case idle
        case waitingForAnchor(UUID)
        case animating(submissionID: UUID, anchorID: UUID)
    }

    let conversation: Conversation
    let composerFocusRequestID: UUID?
    let onComposerFocusRequestHandled: (UUID) -> Void
    let onShowSidebar: () -> Void
    let onToggleTemporary: () -> Void
    let onDeleteChat: () -> Void
    let onBranch: (UUID) -> Void
    let onRenameArtifact: (Artifact, String) async throws -> Artifact
    let onDeleteArtifact: (Artifact) async throws -> Void
    let onExploreServices: () -> Void
    let onArtifactNavigationChange: (Bool) -> Void
    let onInitialTranscriptPresented: () -> Void
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.appTheme) private var appTheme
    private var providerRegistry: ProviderRegistry { .shared }
    private var isModelConfigured: Bool { providerRegistry.defaultModel != nil }

    private var modelService: Service? {
        guard let provider = conversation.client as? WebServiceModelProvider else { return nil }
        return serviceManager.service(domain: provider.domain)
    }

    private var modelAccessNeedsAttention: Bool {
        guard let service = modelService else { return false }
        return !service.signInState.isAuthenticated && service.signInState != .notRequired
    }

    @State var composer = ConversationComposerModel()
    @State private var speechInput = ConversationSpeechInput()
    @Environment(\.scenePhase) private var scenePhase
    @State private var latestSubmissionID: UUID?
    @State private var sendHandoff = SendHandoff.idle
    @FocusState private var composerFocused: Bool
    @State private var editedBlockID: UUID?
    @State private var editDraft = AttributedString()
    @State private var pendingArtifactPreview: Artifact?
    @State private var navigationArtifact: Artifact?
    @State private var navigationSkill: SkillDraft?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var artifactMutation: ArtifactMutation?
    @State private var artifactRevision = 0

    private enum ModalPresentation: Identifiable {
        case modelPicker
        case serviceDetail(Service)
        case camera
        case photos
        case files
        case attachment(URL)
        case artifacts
        case artifactPicker
        case botControl(ServiceHandoffSession)
        case serviceAuth(ServiceAuthSession)

        var id: String {
            switch self {
            case .modelPicker: "modelPicker"
            case .serviceDetail(let service): "serviceDetail:\(service.domain)"
            case .camera: "camera"
            case .photos: "photos"
            case .files: "files"
            case .attachment(let url): "attachment:\(url.absoluteString)"
            case .artifacts: "artifacts"
            case .artifactPicker: "artifactPicker"
            case .botControl(let session): "botControl:\(session.id)"
            case .serviceAuth(let session): "serviceAuth:\(session.id)"
            }
        }
    }
    @State private var modalPresentation: ModalPresentation?

    private enum AlertPresentation: Identifiable {
        case deleteConversation
        case branch(UUID)
        case retry(UUID)

        var id: String {
            switch self {
            case .deleteConversation: "deleteConversation"
            case .branch(let id): "branch:\(id)"
            case .retry(let id): "retry:\(id)"
            }
        }
    }
    @State private var alertPresentation: AlertPresentation?

    @State private var copiedBlockId: UUID?
    @State private var toast: Toast?
    @State private var choiceInputFocused = false
    @State private var showsDelayedActivity = false

    @State private var viewportLayout = ConversationViewportLayout()
    @State private var transcriptWindow = TranscriptWindow()
    @State private var botControlPresenter = ConversationBotControlPresenter()
    @State private var serviceAuthPresenter = ConversationServiceAuthPresenter()
    @State private var browserPageMount = WebPageMountCoordinator()
    @State private var expandedBotControlSessionID: UUID?
    @State private var expandedServiceAuthSessionID: UUID?

    private var browserPage: WebPage? {
        guard let service = serviceManager.inspectionService(domain: BrowserFunctionCatalog.publicNamespace),
              let session = serviceManager.browserActionSessions.existingSession(for: conversation.id, service: service) else {
            return nil
        }
        return session.webPage
    }

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private typealias TurnID = UUID

    @ScaledMetric(relativeTo: .title3) private var iconButtonSize: CGFloat = 44

    @ScaledMetric(relativeTo: .body) private var composerButtonSize: CGFloat = 34

    private func isPresenting(_ presentation: ModalPresentation) -> Binding<Bool> {
        Binding(
            get: { modalPresentation?.id == presentation.id },
            set: { presented in
                if presented {
                    modalPresentation = presentation
                } else if modalPresentation?.id == presentation.id {
                    modalPresentation = nil
                }
            }
        )
    }

    private var sheetModal: Binding<ModalPresentation?> {
        Binding(
            get: {
                switch modalPresentation {
                case .modelPicker, .serviceDetail, .artifacts, .artifactPicker: modalPresentation
                default: nil
                }
            },
            set: { if $0 == nil { modalPresentation = nil } else { modalPresentation = $0 } }
        )
    }

    private var fullScreenModal: Binding<ModalPresentation?> {
        Binding(
            get: {
                switch modalPresentation {
                case .camera, .botControl, .serviceAuth: modalPresentation
                default: nil
                }
            },
            set: { if $0 == nil { modalPresentation = nil } else { modalPresentation = $0 } }
        )
    }

    private var serviceDetailPresentation: Binding<Service?> {
        Binding(
            get: {
                guard case .serviceDetail(let service) = modalPresentation else { return nil }
                return service
            },
            set: { service in
                if let service {
                    Log.ui.info("ChatPage.serviceDetailPresent conversation=\(conversation.id) domain=\(service.domain) composerFocused=\(composerFocused)")
                    composerFocused = false
                    modalPresentation = .serviceDetail(service)
                } else if case .serviceDetail = modalPresentation {
                    modalPresentation = nil
                }
            }
        )
    }

    private var previewAttachmentURL: Binding<URL?> {
        Binding(
            get: {
                guard case .attachment(let url) = modalPresentation else { return nil }
                return url
            },
            set: { url in modalPresentation = url.map(ModalPresentation.attachment) }
        )
    }

    var body: some View {
        NavigationStack {
            page
                .navigationDestination(isPresented: artifactNavigationPresented) {
                    if let artifact = navigationArtifact {
                        Group {
                            if artifact.usesDedicatedPreview {
                                ArtifactNavigationPage(artifact: artifact)
                            } else {
                                ArtifactPreviewPresentation(artifact: artifact)
                            }
                        }
                            .onAppear {
                                Log.ui.info("ChatPage.artifactNavigation present conversation=\(conversation.id) filename=\(artifact.fileName)")
                                onArtifactNavigationChange(true)
                            }
                            .onDisappear {
                                Log.ui.info("ChatPage.artifactNavigation return conversation=\(conversation.id) filename=\(artifact.fileName)")
                                onArtifactNavigationChange(false)
                            }
                    }
                }
                .navigationDestination(item: $navigationSkill) { draft in
                    SkillEditorView(
                        draft: draft,
                        skills: .shared,
                        profileID: StorageRoot.shared.activeId
                    )
                        .onAppear {
                            Log.ui.info("ChatPage.skillNavigation present conversation=\(conversation.id) name=\(draft.name)")
                            onArtifactNavigationChange(true)
                        }
                        .onDisappear {
                            Log.ui.info("ChatPage.skillNavigation return conversation=\(conversation.id) name=\(draft.name)")
                            onArtifactNavigationChange(false)
                        }
                }
        }
        .background(Theme.Colors.chatSurface)
    }

    private var page: some View {
        let interaction = activeInteraction
        let showsComposer = interaction == nil && isModelConfigured
        let authProbe = conversation.pendingServiceControl.flatMap { item -> Conversation.PendingServiceControl? in
            guard isAttached(item.control), case .signIn = item.control else { return nil }
            return item
        }
        let botControlProbe = conversation.pendingServiceControl.flatMap { item -> Conversation.PendingServiceControl? in
            guard case .botControl = item.control else { return nil }
            return item
        }
        return ConversationTranscriptProjection(
            conversation: conversation,
            transcriptWindow: transcriptWindow,
            interaction: interaction
        ) { projection in
            projectedPage(
                projection,
                showsComposer: showsComposer,
                authProbe: authProbe,
                botControlProbe: botControlProbe
            )
        }
    }

    private func projectedPage(
        _ projection: ConversationTranscriptProjectionSnapshot,
        showsComposer: Bool,
        authProbe: Conversation.PendingServiceControl?,
        botControlProbe: Conversation.PendingServiceControl?
    ) -> some View {
        let floatsTopStrip = floatsTopStrip(showsComposer: showsComposer)
        let dockClearance = ConversationViewportLayout.responseComposerSpacing
            + (floatsTopStrip ? ConversationComposer.floatingTopStripClearance : 0)
        let totalBlockCount = projection.totalBlockCount
        let requestedSourceRange = projection.sourceRange
        let requestedSourceIDs = projection.sourceBlockIDs
        let blocks = projection.blocks
        let browserPage = browserPage
        let servicePageOwnerIDs = blocks.compactMap { block -> UUID? in
            guard case .agentContent(.serviceInspector) = block.kind else { return nil }
            return block.id
        }
        let transcript = transcript(
            blocks: blocks,
            latestCanvasBlockIDs: projection.latestCanvasBlockIDs,
            totalBlockCount: totalBlockCount,
            sourceRange: requestedSourceRange,
            sourceBlockIDs: requestedSourceIDs,
            dockClearance: dockClearance
        )
            .onChange(of: servicePageOwnerIDs, initial: true) { _, ownerIDs in
                browserPageMount.reconcile(page: browserPage, ownerIDs: ownerIDs)
            }
            .onChange(of: browserPage.map(ObjectIdentifier.init), initial: true) { _, _ in
                browserPageMount.reconcile(page: browserPage, ownerIDs: servicePageOwnerIDs)
            }
            .toast($toast)
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    pageTopBar(blockCount: totalBlockCount)
                    if modelAccessNeedsAttention {
                        modelAccessNotice
                    }
                }
            }
            .onChange(of: toast?.id) { _, _ in
                if toast == nil {
                    copiedBlockId = nil
                    conversation.clearNotice()
                }
            }
            .onChange(of: conversation.notice, initial: true) { previous, notice in
                if let message = notice.errorMessage {
                    toast = Toast(message: message, role: .error)
                } else if previous.errorMessage != nil, toast?.role == .error {
                    toast = nil
                }
            }
            .onChange(of: serviceManager.repositoryState, initial: true) { _, state in
                guard case .failed(let failure) = state else { return }
                let message = String(
                    format: L10n.string(
                        "Ox Server: %@",
                        comment: "Error shown on chat when the configured Ox Server cannot be reached."
                    ),
                    failure
                )
                toast = Toast(message: message, role: .error, duration: 4)
            }
        let composedTranscript = transcript
            .accessibilityHidden(speechInput.isPresented)
            .overlay {
                if speechInput.isPresented {
                    HoldToTalkBackdrop()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsComposer {
                    composerDock(
                        isChatEmpty: conversation.canChangeRetention && blocks.isEmpty,
                        totalBlockCount: totalBlockCount,
                        floatsTopStrip: floatsTopStrip
                    )
                        .frame(maxWidth: Theme.ContainerWidth.readable)
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                            scroller.viewportResized()
                        }
                }
        }
        .background(Theme.Colors.chatSurface)
        .overlay(alignment: .bottom) {
            if !showsComposer, scroller.showsJumpButton {
                ScrollToBottomButton(composerButtonSize: composerButtonSize) {
                    transcriptWindow.showLatest(total: totalBlockCount)
                    DispatchQueue.main.async { scroller.rideToBottom() }
                }
                    .padding(.bottom, Theme.Spacing.md)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showsComposer {
                servicePickerOverlay(floatsTopStrip: floatsTopStrip)
            }
        }
        .overlay(alignment: .bottom) {
            if showsComposer {
                slashPickerOverlay(floatsTopStrip: floatsTopStrip)
            }
        }
        let observedTranscript = composedTranscript
        .onChange(of: speechInput.notice) { _, message in
            guard let message else { return }
            toast = Toast(message: message, duration: 5)
            speechInput.notice = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { speechInput.interrupt() }
        }
        .onChange(of: showsComposer) { _, visible in
            if !visible { composerFocused = false }
        }
        .onChange(of: conversation.id) { _, _ in
            sendHandoff = .idle
            scroller.endSendHandoff()
            speechInput.cancel(reason: "chatChanged")
            cancelEditing(reason: "chatChanged", keepFocus: false)
        }
        .onChange(of: editedBlockID) { _, blockID in
            if blockID == nil {
                ClientAutomation.setEditDraft = nil
            } else {
                ClientAutomation.setEditDraft = { editDraft = AttributedString($0) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            speechInput.interrupt()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            speechInput.interrupt()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            speechInput.interrupt()
        }
        .quickLookPreview(previewAttachmentURL)
        .onAppear {
            ClientAutomation.composer = composer
        }
        .onDisappear {
            speechInput.cancel(reason: "pageDisappear")
            ClientAutomation.setEditDraft = nil
        }
        .task(id: conversation.serviceBootstrapRevision) {
            let updated = await conversation.syncToMonoRepository()
            guard !Task.isCancelled else { return }
            if !updated.isEmpty {
                let msg = updated.count == 1
                    ? "\(updated[0]) updated"
                    : "\(updated.count) services updated"
                toast = Toast(message: msg)
            }
            await refreshAttachedServiceAuth()
        }
        .task(id: "\(modelService?.domain ?? ""):\(scenePhase)") {
            guard scenePhase == .active, let service = modelService else { return }
            await service.checkAccess(policy: .current, reason: .modelSignIn)
        }
        .task(id: authProbe?.id) {
            await resolveSignInControl(authProbe)
        }
        .task(id: botControlProbe?.id) {
            await resolveBotControl(botControlProbe)
        }
        .onChange(of: botControlPresenter.session?.id) { _, sessionID in
            guard sessionID == nil, case .botControl = modalPresentation else { return }
            modalPresentation = nil
        }
        .onChange(of: serviceAuthPresenter.session?.id) { _, sessionID in
            guard sessionID == nil, case .serviceAuth = modalPresentation else { return }
            modalPresentation = nil
        }
        .task(id: DelayedActivityKey(
            conversationID: conversation.id,
            activity: conversation.activity,
            transcriptRevision: conversation.transcriptRevision
        )) {
            await updateDelayedActivity()
        }
        return observedTranscript
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: sheetModal, onDismiss: sheetDidDismiss) { presented in
            Group {
                switch presented {
                case .modelPicker:
                    ModelPickerSheet(conversation: conversation)
                        .presentationDetents([.medium, .large])
                case .serviceDetail(let service):
                    NavigationStack {
                        ServiceDetailView(
                            initialService: service,
                            primaryAction: .attach,
                            isAttached: conversation.attachedServices.contains { $0.domain == service.domain },
                            onPrimaryAction: {
                                toggleServiceAttachment(service)
                                modalPresentation = nil
                            },
                            browserSessionID: conversation.id
                        )
                    }
                    .presentationDetents([.medium, .large])
                case .artifacts:
                    ConversationArtifactsSheet(artifacts: chatArtifacts) { artifact in
                        pendingArtifactPreview = artifact
                        modalPresentation = nil
                        Log.ui.info("ChatPage.artifactPreview select conversation=\(conversation.id) filename=\(artifact.fileName)")
                    }
                    .presentationDetents([.medium, .large])
                case .artifactPicker:
                    ArtifactPickerSheet(attachedIDs: composer.draftArtifactIDs) { picked in
                        picked.forEach(composer.attachArtifact)
                        Log.ui.info("ChatPage.attachArtifacts conversation=\(conversation.id) count=\(picked.count)")
                    }
                    .presentationDetents([.medium, .large])
                case .camera, .photos, .files, .attachment, .botControl, .serviceAuth:
                    EmptyView()
                }
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.background)
        }
        .fullScreenCover(item: fullScreenModal, onDismiss: sheetDidDismiss) { presented in
            switch presented {
            case .camera:
                CameraPicker { image in
                    if let image { ingestCameraImage(image) }
                }
                .ignoresSafeArea()
            case .botControl(let session):
                BotControlSheetView(session: session)
            case .serviceAuth(let session):
                ServiceSessionSheetView(session: session, mode: .signIn, returnsInline: true)
            case .modelPicker, .serviceDetail, .photos, .files, .attachment, .artifacts, .artifactPicker:
                EmptyView()
            }
        }
        .alert(item: $alertPresentation) { presented in
            switch presented {
            case .deleteConversation:
                Alert(
                    title: Text("Delete this chat?"),
                    message: Text("This removes the chat from your history. This can't be undone."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Delete Chat")) {
                        Log.ui.info("ChatPage.deleteConversation conversation=\(conversation.id) blocks=\(conversation.transcript.count)")
                        conversation.cancelAll()
                        onDeleteChat()
                    }
                )
            case .branch(let id):
                Alert(
                    title: Text("Branch into a new chat?"),
                    message: Text("Forks this chat at this reply and switches to the new one. The original stays put."),
                    primaryButton: .cancel(),
                    secondaryButton: .default(Text("Branch")) {
                        Log.ui.info("ChatPage.branch conversation=\(conversation.id) atBlock=\(id)")
                        onBranch(id)
                    }
                )
            case .retry(let id):
                Alert(
                    title: Text("Regenerate this reply?"),
                    message: Text("Creates a new branch from this prompt. The original conversation is kept."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Regenerate")) {
                        Log.ui.info("ChatPage.retry conversation=\(conversation.id) atBlock=\(id)")
                        latestSubmissionID = conversation.retry(at: id)?.id
                    }
                )
            }
        }
        .artifactMutationAlerts(
            $artifactMutation,
            onRename: renameArtifact,
            onDelete: deleteArtifact
        )
        .photosPicker(
            isPresented: isPresenting(.photos),
            selection: $photoPickerItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            let snapshot = items
            photoPickerItems = []
            ingestPhotoItems(snapshot)
        }
        .fileImporter(
            isPresented: isPresenting(.files),
            allowedContentTypes: [.pdf, .image, .plainText, .sourceCode, .json, .commaSeparatedText],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): ingestFileURLs(urls)
            case .failure(let err):
                Log.ui.error("ChatPage.fileImporter error=\(err.localizedDescription)")
                showAttachmentError(err)
            }
        }
    }

    private func pageTopBar(blockCount: Int) -> some View {
        ConversationPageTopBar(
            conversation: conversation,
            blockCount: blockCount,
            hasArtifacts: !chatArtifacts.isEmpty,
            showsModelPicker: isModelConfigured,
            iconButtonSize: iconButtonSize,
            onShowSidebar: onShowSidebar,
            onToggleTemporary: onToggleTemporary,
            onPickModel: { modalPresentation = .modelPicker },
            onShowArtifacts: { modalPresentation = .artifacts },
            onCopyTranscript: { copyTranscript(blockCount: blockCount) },
            onDeleteConversation: { alertPresentation = .deleteConversation }
        )
    }

    private func presentPendingArtifactPreview() {
        guard let artifact = pendingArtifactPreview else { return }
        pendingArtifactPreview = nil
        navigationArtifact = artifact
    }

    private func sheetDidDismiss() {
        if let expandedBotControlSessionID,
           let session = botControlPresenter.session,
           session.id == expandedBotControlSessionID {
            botControlPresenter.pageMount.restore(page: session.page, ownerID: session.id)
        }
        expandedBotControlSessionID = nil
        if let expandedServiceAuthSessionID,
           let session = serviceAuthPresenter.session,
           session.id == expandedServiceAuthSessionID {
            serviceAuthPresenter.pageMount.restore(page: session.page, ownerID: session.id)
        }
        expandedServiceAuthSessionID = nil
        presentPendingArtifactPreview()
    }

    private var artifactNavigationPresented: Binding<Bool> {
        Binding(
            get: { navigationArtifact != nil },
            set: { presented in
                if !presented { navigationArtifact = nil }
            }
        )
    }

    private func startServiceMention() {
        composer.startMention()
        DispatchQueue.main.async { composerFocused = true }
        Log.ui.info("ChatPage.startServiceMention conversation=\(conversation.id)")
    }

    @ViewBuilder
    private func servicePickerOverlay(floatsTopStrip: Bool) -> some View {
        if editedBlockID == nil {
            ComposerServicePicker(
                composer: composer,
                excludedDomains: Set(conversation.attachedServices.map(\.domain)),
                composerHeight: effectiveComposerHeight(floatsTopStrip: floatsTopStrip),
                onSelect: selectMentionService,
                onExplore: openServiceExplorer
            )
        }
    }

    @ViewBuilder
    private func slashPickerOverlay(floatsTopStrip: Bool) -> some View {
        if editedBlockID == nil {
            ComposerSlashPicker(
                composer: composer,
                isFocused: composerFocused,
                composerHeight: effectiveComposerHeight(floatsTopStrip: floatsTopStrip),
                onSelect: { submitSkill($0, argument: "") }
            )
        }
    }

    private func effectiveComposerHeight(floatsTopStrip: Bool) -> CGFloat {
        viewportLayout.composerHeight
            + (floatsTopStrip ? ConversationComposer.floatingTopStripClearance : 0)
    }

    private func selectMentionService(_ service: Service) {
        composer.finishMention()
        attachService(service)
        DispatchQueue.main.async { composerFocused = true }
    }

    private func openServiceExplorer() {
        composer.finishMention()
        composerFocused = false
        onExploreServices()
        Log.ui.info("ChatPage.openServiceExplorer conversation=\(conversation.id)")
    }

    private func handleAttachChoice(_ choice: AttachmentChoice) {
        switch choice {
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                Log.ui.warning("ChatPage.attachCamera: no camera on this device")
                showAttachmentError(L10n.string("This device has no camera."))
                return
            }
            modalPresentation = .camera
        case .photos:
            modalPresentation = .photos
        case .files:
            modalPresentation = .files
        case .artifacts:
            composerFocused = false
            modalPresentation = .artifactPicker
        case .service(let picked):
            attachService(picked)
        }
    }

    private func attachService(_ picked: Service) {
        Log.ui.info("ChatPage.attachService conversation=\(conversation.id) picked=\(picked.domain)")
        if conversation.attachService(picked) {
            Haptics.impact(.serviceAttached)
        }
    }

    private func removeService(_ service: Service) {
        Log.ui.info("ChatPage.removeService conversation=\(conversation.id) service=\(service.domain)")
        conversation.setAttachedServices(conversation.attachedServices.filter { $0.domain != service.domain })
    }

    private func toggleServiceAttachment(_ service: Service) {
        if conversation.attachedServices.contains(where: { $0.domain == service.domain }) {
            removeService(service)
        } else {
            attachService(service)
        }
    }

    private var anyInputFocused: Bool {
        composerFocused || choiceInputFocused
    }

    private var showsActivity: Bool {
        switch conversation.activity {
        case .running(.thinking):
            conversation.thinkingActivity == nil
        case .running(.awaiting(_)):
            activeInteraction == nil
        case .running(.streaming):
            showsDelayedActivity
        case .idle:
            false
        }
    }

    private func updateDelayedActivity() async {
        showsDelayedActivity = false
        guard conversation.activity == .running(.streaming) else { return }
        do {
            try await Task.sleep(for: .milliseconds(700))
        } catch {
            return
        }
        guard !Task.isCancelled, conversation.activity == .running(.streaming) else { return }
        withAnimation(Theme.Animation.standard) {
            showsDelayedActivity = true
        }
    }

    private var chatArtifacts: [Artifact] {
        conversation.referencedArtifacts
    }

    private var submissionAnchor: Conversation.SubmissionAnchor? {
        latestSubmissionID.flatMap { conversation.anchor(forSubmissionID: $0) }
    }

    private var anchoredTurnID: TurnID? {
        submissionAnchor?.id
    }

    private var anchoredQueuedMessage: Conversation.QueuedMessage? {
        guard case .queued(let id) = submissionAnchor else { return nil }
        return conversation.queuedMessages.first { $0.id == id }
    }

    private var anchorSlack: CGFloat {
        viewportLayout.slack(anchorContentHeight: anchoredTurnID == nil ? nil : scroller.anchorContentHeight)
    }

    private func floatsTopStrip(showsComposer: Bool) -> Bool {
        showsComposer
            && (editedBlockID != nil || !chatArtifacts.isEmpty || !conversation.attachedServices.isEmpty)
    }

    private func messageControls(sourceBlockID: UUID, editableBlock: Block? = nil) -> MessageControls {
        MessageControls(
            onCopy: { text in copyMessage(text, blockId: sourceBlockID) },
            isCopied: copiedBlockId == sourceBlockID,
            canMutate: !conversation.isBusy && !conversation.isTemporary,
            onBranch: { alertPresentation = .branch(sourceBlockID) },
            onRetry: { alertPresentation = .retry(sourceBlockID) },
            onEdit: {
                if let editableBlock { beginEditing(editableBlock) }
            }
        )
    }

    private var artifactControls: ArtifactControls {
        ArtifactControls(
            revision: artifactRevision,
            canMutate: !conversation.isTemporary,
            onRename: { beginRenamingArtifact($0) },
            onDelete: { artifactMutation = .deleting($0) }
        )
    }

    @ViewBuilder
    private func chatBlockHost(_ block: ConversationBlock, latestCanvasBlockIDs: [URL: UUID]) -> some View {
        switch block.kind {
        case .responseFooter(let text, let phase):
            ResponseFooterBlockView(
                id: block.id,
                text: text,
                isVisible: phase.isVisible,
                controls: messageControls(sourceBlockID: block.sourceBlockID)
            )
            .overlay(alignment: .topLeading) {
                if phase == .streaming, showsActivity {
                    ActivityBubble()
                        .padding(
                            .top,
                            ConversationTranscriptMetrics.blockSpacing - ConversationTranscriptMetrics.responseFooterSpacing
                        )
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
            }
        case .prompt(let prompt):
            promptBlock(prompt, sourceBlockID: block.sourceBlockID)
                .padding(.horizontal, 4)
        case .serviceControl(let control, let interactionID):
            serviceControlBlock(control, interactionID: interactionID)
                .padding(.horizontal, 4)
        case .userText, .userSkill, .agentContent, .thinking, .contextCompaction:
            transcriptContentBlock(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
        }
    }

    @ViewBuilder
    private func promptBlock(_ prompt: ConversationPromptBlock, sourceBlockID: UUID) -> some View {
        if let request = prompt.secretEntry, prompt.isActive {
            SecretEntryRequestCard(request: request, onSaved: {
                conversation.resolvePrompt(blockId: sourceBlockID, answer: "Saved")
            }, onCancel: {
                conversation.resolvePrompt(blockId: sourceBlockID, answer: "Cancelled")
            })
            .id(request.id)
        } else {
        switch prompt.kind {
        case .permission:
            if let request = PermissionRequest(
                id: sourceBlockID,
                prompt: prompt.prompt,
                options: prompt.options,
                presentation: prompt.permission
            ) {
                PermissionRequestCard(
                    request: request,
                    selection: prompt.answer,
                    resolution: prompt.resolution
                ) { option in
                    guard prompt.isActive else { return }
                    conversation.resolvePrompt(blockId: sourceBlockID, answer: option)
                }
                .allowsHitTesting(prompt.isActive)
                .opacity(prompt.isActive || prompt.answer != nil ? 1 : 0.6)
            } else if prompt.isActive {
                ActivityBubble()
            }
        case .choice:
            let request = AgentChoiceRequest(
                id: sourceBlockID,
                prompt: prompt.prompt,
                options: prompt.options,
                allowsCustomAnswer: prompt.allowsCustomAnswer
            )
            AgentChoiceRequestCard(
                request: request,
                selection: prompt.answer,
                resolution: prompt.resolution,
                composerButtonSize: composerButtonSize,
                onCustomFocusChange: { choiceInputFocused = $0 }
            ) { option in
                guard prompt.isActive else { return }
                conversation.resolvePrompt(blockId: sourceBlockID, answer: option)
            }
            .allowsHitTesting(prompt.isActive)
            .opacity(prompt.isActive || prompt.answer != nil ? 1 : 0.6)
        }
        }
    }

    private func serviceControlBlock(_ control: ServiceControl, interactionID: UUID?) -> some View {
        Group {
            if case .botControl = control, interactionID != nil {
                InlineBotControlView(
                    control: control,
                    session: botControlPresenter.session,
                    pageMount: botControlPresenter.pageMount,
                    isPresentedInSheet: isBotControlPresentedInSheet,
                    expand: expandBotControl,
                    cancel: { $0.cancel() }
                )
            } else if case .signIn = control, interactionID != nil {
                InlineServiceAuthView(
                    control: control,
                    session: serviceAuthPresenter.session,
                    pageMount: serviceAuthPresenter.pageMount,
                    isPresentedInSheet: expandedServiceAuthSessionID != nil,
                    expand: expandServiceAuth,
                    cancel: {
                        if let session = serviceAuthPresenter.session {
                            session.cancel()
                        } else if let interactionID {
                            conversation.resolveServiceControl(id: interactionID, result: nil)
                        }
                    }
                )
            } else {
                ServiceControlView(
                    control: control,
                    isActive: interactionID != nil,
                    reflectsAuthentication: false,
                    signIn: { domain in
                        guard prepareServiceControl(control) else { return false }
                        return await conversation.signInService(domain: domain, resumeAgent: false)
                    },
                    completeBotControl: { domain, args in
                        guard prepareServiceControl(control) else { return false }
                        return await conversation.completeBotControl(domain: domain, args: args, resumeAgent: false)
                    },
                    completePayment: { domain, args in
                        guard prepareServiceControl(control) else { return nil }
                        return await conversation.completePayment(domain: domain, args: args)
                    },
                    onResolved: { result in
                        guard let interactionID else { return }
                        conversation.resolveServiceControl(id: interactionID, result: result)
                    }
                )
            }
        }
    }

    private var isBotControlPresentedInSheet: Bool {
        expandedBotControlSessionID != nil
    }

    private func expandBotControl(_ session: ServiceHandoffSession) {
        Task { @MainActor in
            guard await botControlPresenter.pageMount.detach(page: session.page, ownerID: session.id),
                  botControlPresenter.session === session else { return }
            expandedBotControlSessionID = session.id
            modalPresentation = .botControl(session)
        }
    }

    private func expandServiceAuth(_ session: ServiceAuthSession) {
        Task { @MainActor in
            guard await serviceAuthPresenter.pageMount.detach(page: session.page, ownerID: session.id),
                  serviceAuthPresenter.session === session else { return }
            expandedServiceAuthSessionID = session.id
            modalPresentation = .serviceAuth(session)
        }
    }

    private func resolveBotControl(_ pending: Conversation.PendingServiceControl?) async {
        guard let pending,
              case .botControl(let domain, _, let args) = pending.control else { return }
        guard prepareServiceControl(pending.control) else {
            conversation.resolveServiceControl(id: pending.id, result: nil)
            return
        }
        let completed = await conversation.completeBotControl(
            domain: domain,
            args: args,
            resumeAgent: false,
            using: botControlPresenter
        )
        conversation.resolveServiceControl(id: pending.id, result: completed ? .null : nil)
    }

    private func prepareServiceControl(_ control: ServiceControl) -> Bool {
        if isAttached(control) { return true }
        guard let service = serviceManager.service(domain: control.domain) else {
            Log.ui.warning("ChatPage.serviceControl unavailable conversation=\(conversation.id) domain=\(control.domain)")
            return false
        }
        conversation.attachService(service)
        return true
    }

    private func composerBlock(
        isChatEmpty: Bool,
        floatsTopStrip: Bool,
        isEmbedded: Bool
    ) -> some View {
        inputBar(
            isChatEmpty: isChatEmpty,
            floatsTopStrip: floatsTopStrip,
            isEmbedded: isEmbedded
        )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard viewportLayout.measureComposerHeight(height) else { return }
                scroller.viewportResized()
            }
    }

    private func transcriptContentBlock(_ block: ConversationBlock, latestCanvasBlockIDs: [URL: UUID]) -> some View {
        let isTail = block.sourceBlockID == conversation.transcript.last?.id
        let isLatestCanvas: Bool = if case .agentContent(.artifact(let artifact)) = block.kind,
                                      artifact.kind == .html {
            latestCanvasBlockIDs[artifact.fileURL] == block.id
        } else {
            false
        }
        return BlockView(
            block: block,
            isLatestCanvas: isLatestCanvas,
            isStreamingTail: conversation.isBusy && isTail,
            conversationID: conversation.id,
            browserPageMount: browserPageMount,
            isThinkingTail: block.isLiveThinking,
            controls: messageControls(
                sourceBlockID: block.sourceBlockID,
                editableBlock: editableBlock(block)
            ),
            artifactControls: artifactControls,
            onOpenAttachment: { artifact, sourceID in openAttachment(artifact, sourceID: sourceID) },
            onOpenSkill: { openSkill($0) },
            onOpenLink: { openLink($0) }
        )
    }

    private func editableBlock(_ block: ConversationBlock) -> Block? {
        let kind: Block.Kind
        switch block.kind {
        case .userText(let text, let attachments):
            kind = .userText(text, attachments: attachments)
        case .userSkill(let invocation, let attachments):
            kind = .userSkill(invocation, attachments: attachments)
        case .agentContent, .thinking, .contextCompaction, .prompt, .serviceControl, .responseFooter:
            return nil
        }
        return Block(id: block.sourceBlockID, createdAt: block.createdAt, kind: kind)
    }

    @ViewBuilder
    private func blockRow(
        _ block: ConversationBlock,
        latestCanvasBlockIDs: [URL: UUID],
        identified: Bool = true
    ) -> some View {
        let row = chatBlockHost(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
            .padding(.top, block.spacingBefore)

        if identified {
            row.id(block.id)
        } else {
            row
        }
    }

    @ViewBuilder
    private func activityRow(blocks: [ConversationBlock]) -> some View {
        if showsActivity, !blocks.contains(where: {
            if case .responseFooter(_, .streaming) = $0.kind { return true }
            return false
        }) {
            ActivityBubble()
                .id("__activity")
                .transition(.opacity)
                .padding(.top, ConversationTranscriptMetrics.blockSpacing)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var stoppedRow: some View {
        if conversation.showsStoppedTurn {
            StoppedTurnDivider()
                .id("__stopped")
                .padding(.top, ConversationTranscriptMetrics.blockSpacing)
        }
    }

    @ViewBuilder
    private func queuedRow(_ queued: Conversation.QueuedMessage, identified: Bool = true) -> some View {
        let row = QueuedBubble(
            message: queued,
            onOpenAttachment: { artifact, sourceID in openAttachment(artifact, sourceID: sourceID) },
            onOpenSkill: { openSkill($0) }
        ) { conversation.cancelQueued(queued.id) }
            .transition(.opacity)
            .padding(.top, ConversationTranscriptMetrics.blockSpacing)
        if identified {
            row.id(queued.id)
        } else {
            row
        }
    }

    private var queuedRows: some View {
        ForEach(conversation.queuedMessages) { queued in
            queuedRow(queued)
        }
    }

    @State private var scroller = ConversationViewportController()

    private func transcript(
        blocks: [ConversationBlock],
        latestCanvasBlockIDs: [URL: UUID],
        totalBlockCount: Int,
        sourceRange: Range<Int>,
        sourceBlockIDs: [UUID],
        dockClearance: CGFloat
    ) -> some View {
        let anchoredViewportHeight = max(
            0,
            max(viewportLayout.anchorFloor, viewportLayout.contentFloorHeight)
        )
        return GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    transcriptRows(
                        blocks: blocks,
                        renderedBlocks: blocks,
                        latestCanvasBlockIDs: latestCanvasBlockIDs,
                        anchoredViewportHeight: anchoredViewportHeight,
                        scrollToTurn: { id in
                            anchorBecameReady(id, proxy: proxy)
                        }
                    )
                }
                .overlayPreferenceValue(LivePageCardAnchorKey.self) { anchors in
                    if let page = browserPage,
                       let ownerID = browserPageMount.inlineOwnerID(for: page),
                       let anchor = anchors[ownerID] {
                        InlineServicePageHost(
                            anchor: anchor,
                            mount: WebPageMount(page: page, ownerID: ownerID, coordinator: browserPageMount)
                        )
                    }
                }
                .contentMargins(.bottom, dockClearance, for: .scrollContent)
                .onScrollGeometryChange(for: ConversationViewportController.Frame?.self) { geo in
                    let frame = ConversationViewportController.Frame(geo)
                    return frame.insetTop == 0 && frame.insetBottom == 0 ? nil : frame
                } action: { _, new in
                    guard let new else { return }
                    scroller.geometryChanged(new)
                }
                .onScrollPhaseChange { old, new in
                    scroller.phaseChanged(from: old, to: new)
                    if new == .interacting {
                        requestEarlierReveal(blocks: blocks)
                    }
                    if new == .idle,
                       let anchor = transcriptWindow.applyPendingEarlier() {
                        scroller.preservePageAnchor(anchor)
                        logTranscriptWindow(reason: "earlier", total: totalBlockCount)
                    }
                }
                .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) {
                    scroller.visibleTargetsChanged($0)
                }
                .scrollPosition($scroller.position)
                .modifier(SidebarScrollLockModifier())
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollDismissesKeyboard(.interactively)
                .dismissesSelectableTextSelection {
                    Log.ui.info("ChatPage.dismissTextSelection conversation=\(conversation.id) via=transcriptTap")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    guard anyInputFocused else { return }
                    Log.ui.info("ChatUX.intent conversation=\(conversation.id) kind=dismissKeyboard via=transcriptTap")
                    composerFocused = false
                    if choiceInputFocused {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                })
                .onChange(of: totalBlockCount) { _, total in
                    transcriptWindow.reconcile(total: total)
                    logTranscriptWindow(reason: "blocks", total: total)
                }
                .onChange(of: conversation.isBusy) { _, busy in
                    logTranscriptWindow(reason: busy ? "busy" : "settled", total: totalBlockCount)
                }
                .onChange(of: submissionAnchor) { old, new in
                    guard old != new, let new else { return }
                    transcriptWindow.showLatest(total: totalBlockCount)
                    transcriptWindow.anchor(
                        on: new.id,
                        in: sourceBlockIDs,
                        startingAt: sourceRange.lowerBound
                    )
                    logTranscriptWindow(reason: "submissionAnchor", total: totalBlockCount)
                }
                .onChange(of: composerFocused) { _, _ in
                    scroller.focusChanged(
                        anyInputFocused,
                        slack: anchorSlack,
                        source: "composer"
                    )
                }
                .onChange(of: choiceInputFocused) { _, _ in
                    scroller.focusChanged(
                        anyInputFocused,
                        slack: anchorSlack,
                        source: "choice"
                    )
                }
                .onChange(of: outer.size.height, initial: true) { _, height in
                    viewportLayout.measureViewport(
                        height,
                        bottomMargin: dockClearance,
                        focused: anyInputFocused
                    )
                }
                .onAppear {
                    transcriptWindow.open(total: totalBlockCount)
                    Log.ui.info("ChatUX.lifecycle conversation=\(conversation.id) phase=viewportOpening target=bottom range=\(transcriptWindow.range.lowerBound)..<\(transcriptWindow.range.upperBound) total=\(totalBlockCount) anchor=\(submissionAnchor?.id.uuidString ?? "none") scale=\(displayScale) dynamicType=\(String(describing: dynamicTypeSize)) reduceMotion=\(reduceMotion) reduceTransparency=\(reduceTransparency)")
                    scroller.openAtBottom(conversationID: "\(conversation.id)", onSettled: onInitialTranscriptPresented)
                }
            }
        }
    }

    private func transcriptRows(
        blocks: [ConversationBlock],
        renderedBlocks: [ConversationBlock],
        latestCanvasBlockIDs: [URL: UUID],
        anchoredViewportHeight: CGFloat,
        scrollToTurn: @escaping (TurnID) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if conversation.canChangeRetention {
                emptyChatState
            }
            earlierWindowBoundary(blocks: blocks)
            if let anchor = anchoredQueuedMessage {
                ForEach(renderedBlocks) { block in
                    blockRow(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
                }
                activityRow(blocks: renderedBlocks)
                stoppedRow
                ForEach(conversation.queuedMessages.filter { $0.id != anchor.id }) { queued in
                    queuedRow(queued)
                }
                VStack(spacing: 0) {
                    queuedRow(anchor, identified: false)
                        .id(anchor.id)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    scroller.measureAnchorContent($0)
                }
                .frame(minHeight: anchoredViewportHeight, alignment: .top)
                .task(id: anchor.id) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollToTurn(anchor.id)
                }
            } else if let anchorID = anchoredTurnID,
                      let anchorIndex = renderedBlocks.firstIndex(where: { $0.id == anchorID }) {
                ForEach(Array(renderedBlocks[..<anchorIndex])) { block in
                    blockRow(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
                }
                VStack(spacing: 0) {
                    blockRow(
                        renderedBlocks[anchorIndex],
                        latestCanvasBlockIDs: latestCanvasBlockIDs,
                        identified: false
                    )
                    .id(anchorID)
                    ForEach(Array(renderedBlocks.dropFirst(anchorIndex + 1))) { block in
                        blockRow(block, latestCanvasBlockIDs: latestCanvasBlockIDs, identified: false)
                    }
                    activityRow(blocks: renderedBlocks)
                    stoppedRow
                    queuedRows
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    scroller.measureAnchorContent($0)
                }
                .frame(minHeight: anchoredViewportHeight, alignment: .top)
                .task(id: anchorID) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollToTurn(anchorID)
                }
            } else {
                ForEach(renderedBlocks) { block in
                    blockRow(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
                }
                activityRow(blocks: renderedBlocks)
                stoppedRow
                queuedRows
            }
            Color.clear
                .frame(height: 1)
                .onScrollVisibilityChange(threshold: 0.5, scroller.bottomVisibilityChanged)
                .onDisappear { scroller.bottomVisibilityChanged(false) }
        }
        .scrollTargetLayout()
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: Theme.ContainerWidth.readable)
        .frame(maxWidth: .infinity, minHeight: viewportLayout.contentFloorHeight, alignment: .top)
        .contentShape(Rectangle())
        .background(KeyboardDismissPadding(padding: viewportLayout.composerHeight))
    }

    private func anchorBecameReady(_ anchorID: TurnID, proxy: ScrollViewProxy) {
        guard case .waitingForAnchor(let submissionID) = sendHandoff,
              latestSubmissionID == submissionID,
              submissionAnchor?.id == anchorID else {
            scroller.rideToTurn(
                anchorID,
                animation: reduceMotion ? nil : Theme.Animation.ride
            ) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            return
        }

        scroller.beginSendHandoff()
        sendHandoff = .animating(submissionID: submissionID, anchorID: anchorID)
        Log.ui.info("ChatUX.sendHandoff conversation=\(conversation.id) phase=animating submission=\(submissionID) anchor=\(anchorID)")
        let dismissesKeyboard = anyInputFocused
        if dismissesKeyboard { prepareComposerSubmission() }
        scroller.rideToTurn(
            anchorID,
            animation: reduceMotion ? nil : (dismissesKeyboard ? Theme.Animation.handoff : Theme.Animation.ride)
        ) {
            proxy.scrollTo(anchorID, anchor: .top)
        } completion: {
            guard sendHandoff == .animating(
                submissionID: submissionID,
                anchorID: anchorID
            ) else { return }
            sendHandoff = .idle
            scroller.endSendHandoff()
            Log.ui.info("ChatUX.sendHandoff conversation=\(conversation.id) phase=settled submission=\(submissionID) anchor=\(anchorID)")
        }
    }

    @ViewBuilder
    private var emptyChatState: some View {
        if !isModelConfigured {
            modelSetupState
        } else if conversation.isTemporary {
            temporaryEmptyState
        } else {
            persistedEmptyState
        }
    }

    private var modelSetupState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Text("Choose a default model to start chatting.")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Colors.onSurface)
                .multilineTextAlignment(.center)
            Button("Choose default model") { modalPresentation = .modelPicker }
                .font(Theme.Fonts.labelMd)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Colors.primary)
                .accessibilityIdentifier(A11yID.Chat.modelSetup)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: viewportLayout.contentFloorHeight, alignment: .center)
    }

    private var persistedEmptyState: some View {
        EmptyChatMark()
            .saturation(appTheme == .dark ? 0 : 0.25)
            .opacity(0.3)
            .frame(width: 40, height: 40)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: viewportLayout.contentFloorHeight, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New chat")
            .accessibilityIdentifier(A11yID.Chat.persistedEmpty)
    }

    private var temporaryEmptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("Temporary chat")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Colors.onSurface)
            Text("This chat won’t be saved by Ox or synced with iCloud. Temporary mode changes Ox’s storage only; your selected model’s data policy still applies.")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: viewportLayout.contentFloorHeight, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Chat.temporaryEmpty)
    }

    private func earlierWindowBoundary(blocks: [ConversationBlock]) -> some View {
        Color.clear
            .frame(height: transcriptWindow.hasEarlier ? 1 : 0)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                transcriptWindow.setEarlierBoundaryVisible(visible)
                if visible { requestEarlierReveal(blocks: blocks) }
            }
    }

    private func requestEarlierReveal(blocks: [ConversationBlock]) {
        transcriptWindow.requestEarlier(
            anchor: readerAnchor(in: blocks),
            isUserScrolling: scroller.isUserScrolling
        )
    }

    private func readerAnchor(in blocks: [ConversationBlock]) -> UUID? {
        if let visible = scroller.visibleBlockID { return visible }
        return blocks.first?.id
    }

    private func logTranscriptWindow(reason: String, total: Int) {
        Log.ui.info("ChatUX.content conversation=\(conversation.id) reason=\(reason) range=\(transcriptWindow.range.lowerBound)..<\(transcriptWindow.range.upperBound) total=\(total) anchor=\(submissionAnchor?.id.uuidString ?? "none") busy=\(conversation.isBusy)")
    }

    private func inputBar(
        isChatEmpty: Bool,
        floatsTopStrip: Bool,
        isEmbedded: Bool
    ) -> some View {
        ConversationComposer(
            composer: composer,
            isEditingMessage: editedBlockID != nil,
            editDraft: $editDraft,
            speech: speechInput,
            attachedServices: conversation.attachedServices,
            chatArtifacts: chatArtifacts,
            fieldFocused: $composerFocused,
            isFieldFocused: composerFocused,
            sessionID: conversation.id,
            isChatEmpty: isChatEmpty,
            isTemporary: conversation.isTemporary,
            isBusy: conversation.isBusy,
            followIntents: conversation.followIntents,
            floatsTopStrip: floatsTopStrip,
            isEmbedded: isEmbedded,
            iconButtonSize: iconButtonSize,
            composerButtonSize: composerButtonSize,
            onOpenAttachment: { artifact, sourceID in openAttachment(artifact, sourceID: sourceID) },
            onOpenChatArtifact: { openAttachment($0) },
            onPasteImages: ingestPastedImages,
            onOpenService: { serviceDetailPresentation.wrappedValue = $0 },
            onRemoveService: removeService,
            onAttachmentChoice: handleAttachChoice,
            onServices: startServiceMention,
            onSubmitSkill: submitSkill,
            onPreparationIntent: conversation.setModelPreparationIntent,
            onCancelEdit: { cancelEditing(reason: "user", keepFocus: true) },
            onSend: { send() },
            onStop: {
                Log.ui.info("ChatPage.stop conversation=\(conversation.id)")
                conversation.stopCurrentTurn()
            },
            onSpeechBegin: beginSpeech
        )
        .equatable()
        .task(id: composerFocusRequestID) {
            guard let composerFocusRequestID else { return }
            await Task.yield()
            composerFocused = true
            Log.ui.info("ChatUX.intent conversation=\(conversation.id) kind=focusRequest phase=applied request=\(composerFocusRequestID)")
            onComposerFocusRequestHandled(composerFocusRequestID)
        }
    }

    private func composerDock(
        isChatEmpty: Bool,
        totalBlockCount: Int,
        floatsTopStrip: Bool
    ) -> some View {
        composerBlock(isChatEmpty: isChatEmpty, floatsTopStrip: floatsTopStrip, isEmbedded: false)
            .transition(.opacity)
            .overlay(alignment: .top) {
                if scroller.showsJumpButton {
                    ScrollToBottomControl(
                        composer: composer,
                        composerFocused: composerFocused,
                        isEditingMessage: editedBlockID != nil,
                        hasArtifacts: !chatArtifacts.isEmpty,
                        hasAttachedServices: !conversation.attachedServices.isEmpty,
                        floatsTopStrip: floatsTopStrip,
                        composerButtonSize: composerButtonSize
                    ) {
                        transcriptWindow.showLatest(total: totalBlockCount)
                        DispatchQueue.main.async { scroller.rideToBottom() }
                    }
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : Theme.Animation.standard,
                value: scroller.showsJumpButton
            )
    }

    private var modelAccessNotice: some View {
        Button { modalPresentation = .modelPicker } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.Colors.primary)
                Text(verbatim: modelAccessNoticeTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .font(Theme.Fonts.bodySm)
            .foregroundStyle(Theme.Colors.onSurface)
            .alertGlassPill(in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .minimumTouchTarget()
        .accessibilityIdentifier(A11yID.Chat.modelAccessNotice)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
        .frame(maxWidth: Theme.ContainerWidth.readable)
        .frame(maxWidth: .infinity)
    }

    private var modelAccessNoticeTitle: String {
        switch modelService?.auth {
        case .unknown?, .checking?: L10n.string("Checking sign-in…")
        case .unavailable?: L10n.string("Sign-in unavailable")
        default: String(localized: "Sign in with \(conversation.client.displayName)")
        }
    }

    private func ensureModelAccess() -> Bool {
        guard modelAccessNeedsAttention else { return true }
        Log.ui.info("ChatPage.modelAccess blocked conversation=\(conversation.id) provider=\(conversation.client.id) state=\(modelService?.signInState.rawValue ?? "unknown")")
        modalPresentation = .modelPicker
        return false
    }

    private var activeInteraction: Conversation.Interaction? {
        conversation.interaction
    }

    private func isAttached(_ control: ServiceControl) -> Bool {
        conversation.attachedServices.contains { $0.domain == control.domain }
    }

    private func refreshAttachedServiceAuth() async {
        await withTaskGroup(of: Void.self) { group in
            for service in conversation.attachedServices {
                group.addTask { @MainActor in
                    await service.checkAccess(reason: .chatOpen)
                }
            }
        }
    }

    private func resolveSignInControl(_ item: Conversation.PendingServiceControl?) async {
        guard let item,
              case .signIn(let domain, _) = item.control,
              let service = conversation.attachedService(domain: domain) else { return }
        Log.ui.info("ChatPage.authProbe start conversation=\(conversation.id) domain=\(domain) state=\(service.signInState.rawValue)")
        await service.checkAccess(policy: .current, reason: .pendingSignIn, preflight: item.accessPreflight)
        guard !Task.isCancelled else {
            Log.ui.info("ChatPage.authProbe canceled conversation=\(conversation.id) domain=\(domain)")
            return
        }
        await service.attemptSilentSignIn(reason: .chatOpen)
        guard !Task.isCancelled else { return }
        Log.ui.info("ChatPage.authProbe done conversation=\(conversation.id) domain=\(domain) state=\(service.signInState.rawValue)")
        if service.signInState.isAuthenticated {
            conversation.resolveServiceControl(id: item.id, result: .null)
        } else {
            let signedIn = await conversation.signInService(
                domain: domain,
                resumeAgent: false,
                using: service.supportsWebAuthentication ? serviceAuthPresenter : nil
            )
            conversation.resolveServiceControl(id: item.id, result: signedIn ? .null : nil)
        }
    }

    private func copyTranscript(blockCount: Int) {
        Task {
            do {
                let text = String(decoding: try await conversation.exportTranscript(), as: UTF8.self)
                UIPasteboard.general.string = text
                Haptics.impact(.copy)
                Log.ui.info("ChatPage.copyTranscript conversation=\(conversation.id) blocks=\(blockCount) chars=\(text.count)")
                showCopiedToast()
            } catch {
                Log.ui.error("ChatPage.copyTranscript conversation=\(conversation.id) encode failed: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func copyMessage(_ text: String, blockId: UUID) {
        UIPasteboard.general.string = text
        Haptics.impact(.copy)
        Log.ui.info("ChatPage.copyMessage conversation=\(conversation.id) block=\(blockId) chars=\(text.count)")
        copiedBlockId = blockId
        showCopiedToast()
    }

    private func showCopiedToast() {
        toast = Toast(message: L10n.string("Message copied", comment: "Toast shown after the user copies a chat message to the clipboard."))
    }

    private func send() {
        guard ensureModelAccess() else { return }
        if let editedBlockID {
            commitEdit(blockID: editedBlockID)
            return
        }
        guard let message = composer.takeMessage() else { return }
        enqueue(message)
    }

    private func beginSpeech(accessible: Bool) {
        guard !composer.isImporting, !speechInput.isPresented else { return }
        prepareComposerSubmission()
        let draftID = composer.draftID
        let draft = composer.attributedDraft
        composer.setAttachmentMenuPresented(false)
        speechInput.begin(accessible: accessible) { text, action in
            guard composer.draftID == draftID, composer.attributedDraft == draft else {
                speechInput.notice = L10n.string("The draft changed while recording. Nothing was sent.", comment: "")
                return
            }
            composer.appendDictation(text)
            if action == .edit {
                composerFocused = true
            } else {
                if let invocation = composer.slashInvocation {
                    submitSkill(invocation.skill, argument: invocation.argument)
                } else {
                    composer.delayStopControl()
                    send()
                }
            }
        }
    }

    private func prepareComposerSubmission() {
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func enqueue(_ message: ConversationComposerModel.Message, skillInvocation: UserSkillInvocation? = nil) {
        let receipt = conversation.enqueue(
            message.text,
            attachments: message.attachments,
            skillInvocation: skillInvocation
        )
        latestSubmissionID = receipt.id
        sendHandoff = .waitingForAnchor(receipt.id)
        Log.ui.info("ChatPage.send conversation=\(conversation.id) draft=\(message.id) submission=\(receipt.id) disposition=\(receipt.disposition.rawValue) chars=\(message.text.count) attachments=\(message.attachments.count)")
    }

    private func submitSkill(_ skill: Skill, argument: String) {
        guard ensureModelAccess() else { return }
        Log.ui.info("ConversationComposer.skillSelect conversation=\(conversation.id) name=\(skill.name) services=\(skill.services.count)")
        if conversation.attachServiceDomains(skill.services) {
            Haptics.impact(.serviceAttached)
        }
        Log.ui.info("ConversationComposer.skillSubmit conversation=\(conversation.id) name=\(skill.name) argumentChars=\(argument.count)")
        let invocation = UserSkillInvocation(skill: skill, argument: argument)
        composer.draft = invocation.expandedIntent
        composer.delayStopControl()
        guard let message = composer.takeMessage() else { return }
        enqueue(message, skillInvocation: invocation)
    }

    private func beginEditing(_ block: Block) {
        guard case let .userText(text, _) = block.kind else { return }
        Log.ui.info("ChatPage.beginEditing conversation=\(conversation.id) block=\(block.id) chars=\(text.count)")
        Haptics.impact(.editStarted)
        composer.setAttachmentMenuPresented(false)
        editDraft = AttributedString(text)
        withAnimation(Theme.Animation.handoff, completionCriteria: .logicallyComplete) {
            editedBlockID = block.id
        } completion: {
            composerFocused = true
        }
    }

    private func commitEdit(blockID: UUID) {
        let trimmed = String(editDraft.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Log.ui.info("ChatPage.commitEdit conversation=\(conversation.id) block=\(blockID) chars=\(trimmed.count)")
        prepareComposerSubmission()
        withAnimation(Theme.Animation.handoff, completionCriteria: .logicallyComplete) {
            editedBlockID = nil
            editDraft = AttributedString()
        } completion: {
            latestSubmissionID = conversation.editAndRerun(at: blockID, newText: trimmed)?.id
        }
    }

    private func cancelEditing(reason: String, keepFocus: Bool) {
        guard let editedBlockID else { return }
        Log.ui.info("ChatPage.cancelEditing conversation=\(conversation.id) block=\(editedBlockID) reason=\(reason)")
        withAnimation(Theme.Animation.handoff, completionCriteria: .logicallyComplete) {
            self.editedBlockID = nil
            editDraft = AttributedString()
        } completion: {
            if keepFocus { composerFocused = true }
        }
    }

    private func openAttachment(_ att: Artifact, sourceID _: String? = nil) {
        Log.ui.info("ChatPage.openAttachment conversation=\(conversation.id) kind=\(att.kind.rawValue) name=\(att.displayName)")
        navigationArtifact = att
    }

    private func openSkill(_ skill: Skill) {
        Skills.shared.refresh()
        let current = Skills.shared.skill(named: skill.name) ?? skill
        navigationSkill = SkillDraft(current)
        Log.ui.info("ChatPage.skillNavigation select conversation=\(conversation.id) name=\(current.name)")
    }

    private func openLink(_ url: URL) {
        switch ConversationLinkDestination(url) {
        case .web(let url):
            LinkOpener.open(url: url, serviceManager: serviceManager)
        case .artifact(let filename):
            guard let artifact = chatArtifacts.first(where: {
                $0.fileName.caseInsensitiveCompare(filename) == .orderedSame
            }) else {
                Log.ui.warning("ChatPage.openLink disposition=missing-artifact filename=\(filename)")
                return
            }
            Log.ui.info("ChatPage.openLink disposition=artifact filename=\(artifact.fileName)")
            openAttachment(artifact)
        case .unsupported(let url):
            Log.ui.warning("ChatPage.openLink disposition=unsupported url=\(LogPrivacy.url(url.absoluteString))")
        }
    }

    private func beginRenamingArtifact(_ artifact: Artifact) {
        artifactMutation = .rename(artifact)
    }

    private func renameArtifact(_ artifact: Artifact, to newFilename: String) {
        Task {
            do {
                let renamed = try await onRenameArtifact(artifact, newFilename)
                artifactRevision += 1
                Log.ui.info("ChatPage.renameArtifact conversation=\(conversation.id) from=\(artifact.fileName) to=\(renamed.fileName)")
            } catch {
                Log.ui.error("ChatPage.renameArtifact conversation=\(conversation.id) from=\(artifact.fileName) error=\(error.localizedDescription)")
                artifactMutation = .renameFailed(artifact.userFacingErrorDescription(error))
            }
        }
    }

    private func deleteArtifact(_ artifact: Artifact) {
        Task {
            do {
                try await onDeleteArtifact(artifact)
                artifactRevision += 1
                Log.ui.info("ChatPage.deleteArtifact conversation=\(conversation.id) file=\(artifact.fileName)")
            } catch {
                Log.ui.error("ChatPage.deleteArtifact conversation=\(conversation.id) file=\(artifact.fileName) error=\(error.localizedDescription)")
                artifactMutation = .deleteFailed(artifact.userFacingErrorDescription(error))
            }
        }
    }

    private func importAttachment(named name: String, source: String, operation: @escaping @MainActor () async throws -> Artifact) {
        composer.importAttachment(named: name, operation: operation) { error in
            Log.ui.error("ChatPage.attach \(source) error=\(error.localizedDescription)")
            showAttachmentError(error)
        }
    }

    private func ingestPhotoItems(_ items: [PhotosPickerItem]) {
        for item in items {
            let suggested = item.itemIdentifier.map { "Photo-\($0.prefix(6)).jpg" } ?? "Photo.jpg"
            importAttachment(named: suggested, source: "photo") {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ArtifactError.imageDecodeFailed
                }
                return try await ArtifactImporter.importImageDataAsync(data, suggestedName: suggested)
            }
        }
    }

    private func ingestCameraImage(_ image: UIImage) {
        importAttachment(named: "Camera.jpg", source: "camera") {
            try await ArtifactImporter.importImageAsync(image, suggestedName: "Camera.jpg")
        }
    }

    private func ingestPastedImages(_ images: [PastedComposerImage]) {
        for image in images {
            importAttachment(named: image.suggestedName, source: "pastedImage") {
                try await ArtifactImporter.importImageDataAsync(image.data, suggestedName: image.suggestedName)
            }
        }
    }

    private func ingestFileURLs(_ urls: [URL]) {
        for url in urls {
            importAttachment(named: url.lastPathComponent, source: "file") {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await ArtifactImporter.importFileAsync(at: url)
            }
        }
    }

    private func showAttachmentError(_ error: Error) {
        showAttachmentError(error.localizedDescription)
    }

    private func showAttachmentError(_ message: String) {
        toast = Toast(message: message, role: .error)
    }
}
