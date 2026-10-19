import SwiftUI
import AVFAudio
import UIKit
import WebKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

private struct SidebarScrollLockModifier: ViewModifier {
    @Environment(\.sidebarInteraction) private var sidebarInteraction

    func body(content: Content) -> some View {
        content.scrollDisabled(sidebarInteraction.dragActive)
    }
}

private struct DelayedActivityKey: Equatable {
    let conversationID: UUID
    let activity: Conversation.Activity
    let transcriptRevision: UInt64
}

struct ConversationPage: View {
    private enum SendHandoff: Equatable {
        case idle
        case waitingForAnchor(submissionID: UUID, origin: CGPoint)
        case positioned(submissionID: UUID, offset: CGFloat, anchorTop: CGFloat, origin: CGPoint)
        case animating(UUID)

        var origin: CGPoint? {
            switch self {
            case .waitingForAnchor(_, let origin), .positioned(_, _, _, let origin): origin
            case .idle, .animating: nil
            }
        }
    }

    let conversation: Conversation
    let composerFocusRequestID: UUID?
    let onComposerFocusRequestHandled: (UUID) -> Void
    let onShowSidebar: () -> Void
    let onToggleTemporary: () -> Void
    let onDeleteConversation: () -> Void
    let onBranch: (UUID) -> Void
    let onOpenConversation: (UUID) -> Void
    let onRenameFile: (FileItem, String) async throws -> FileItem
    let onDeleteFile: (FileItem) async throws -> Void
    let onExploreServices: () -> Void
    let onFileNavigationChange: (Bool) -> Void
    let onInitialTranscriptPresented: () -> Void
    @Environment(ServiceManager.self) private var serviceManager
    private var providerRegistry: ProviderRegistry { .shared }
    private var isModelConfigured: Bool { providerRegistry.defaultModel != nil }

    private var modelAccessNeedsAttention: Bool {
        providerRegistry.client(id: conversation.modelSelection.providerID) == nil
    }

    @State var composer = ConversationComposerModel()
    @State private var speechInput = ConversationSpeechInput()
    @Environment(\.scenePhase) private var scenePhase
    @State private var latestSubmissionID: UUID?
    @State private var sendHandoff = SendHandoff.idle
    @State private var composerInputFrame = CGRect.zero
    @State private var submissionFrame = CGRect.null
    @State private var sendFlightBubble: SendFlight.Bubble?
    @State private var sendFlightPath: SendFlight.Path?
    @State private var sendTranscriptTail: CGFloat = 0

    private var holdsTranscript: Bool {
        switch sendHandoff {
        case .waitingForAnchor, .positioned: !reduceMotion
        case .idle, .animating: false
        }
    }
    @FocusState private var composerFocused: Bool
    @State private var editedBlockID: UUID?
    @State private var editDraft = AttributedString()
    @State private var pendingFilePreview: FileItem?
    @State private var navigationFile: FileItem?
    @State private var navigationSkill: SkillDraft?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var artifactMutation: FileMutation?
    @State private var artifactRevision = 0

    private enum ModalPresentation: Identifiable {
        case modelPicker
        case serviceDetail(Service)
        case camera
        case photos
        case files
        case attachment(URL)
        case artifacts
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
    @State private var messageFiles: [FileItem] = []
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
                case .modelPicker, .serviceDetail, .artifacts: modalPresentation
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
                    Log.ui.info("ConversationPage.serviceDetailPresent conversation=\(conversation.id) domain=\(service.domain) composerFocused=\(composerFocused)")
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
                    if let artifact = navigationFile {
                        Group {
                            if artifact.usesDedicatedPreview {
                                FileNavigationPage(artifact: artifact)
                            } else {
                                FilePreviewPresentation(artifact: artifact)
                            }
                        }
                            .onAppear {
                                Log.ui.info("ConversationPage.artifactNavigation present conversation=\(conversation.id) filename=\(artifact.fileName)")
                                onFileNavigationChange(true)
                            }
                            .onDisappear {
                                Log.ui.info("ConversationPage.artifactNavigation return conversation=\(conversation.id) filename=\(artifact.fileName)")
                                onFileNavigationChange(false)
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
                            Log.ui.info("ConversationPage.skillNavigation present conversation=\(conversation.id) name=\(draft.name)")
                            onFileNavigationChange(true)
                        }
                        .onDisappear {
                            Log.ui.info("ConversationPage.skillNavigation return conversation=\(conversation.id) name=\(draft.name)")
                            onFileNavigationChange(false)
                        }
                }
        }
        .background(Theme.Colors.conversationSurface)
    }

    private var page: some View {
        let interaction = activeInteraction
        let isSignIn = if case .serviceControl(let item) = interaction, case .signIn = item.control { true } else { false }
        let showsComposer = (interaction == nil || isSignIn) && isModelConfigured
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
        let dockedPrompt: Conversation.PendingPrompt? = if case .prompt(let prompt) = activeInteraction { prompt } else { nil }
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
            .toast($toast, accessibilityIdentifier: A11yID.ConversationControls.toast)
            .environment(\.conversationFileResolver, ConversationFileResolver(revision: conversation.artifactFilesRevision) { [conversation] path in
                await conversation.messageFile(path: path)
            })
            .task(id: MessageFilesKey(conversation: conversation.id, blocks: conversation.transcriptBlockCount,
                                      isBusy: conversation.isBusy, files: conversation.artifactFilesRevision)) {
                guard !conversation.isBusy else { return }
                messageFiles = await conversation.messageFiles()
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    pageTopBar(blockCount: totalBlockCount)
                    if modelAccessNeedsAttention {
                        ConversationModelAccessNotice { modalPresentation = .modelPicker }
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
                        comment: "Error shown on conversation when the configured Ox Server cannot be reached."
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
                VStack(spacing: 0) {
                    if showsComposer {
                        composerDock(
                            isConversationEmpty: conversation.canChangeRetention && blocks.isEmpty,
                            totalBlockCount: totalBlockCount,
                            floatsTopStrip: floatsTopStrip
                        )
                    } else if let dockedPrompt {
                        promptDock(dockedPrompt, totalBlockCount: totalBlockCount)
                    }
                }
                .frame(maxWidth: Theme.ContainerWidth.readable)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                    scroller.viewportResized()
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: dockedPrompt?.id)
        }
        .background(Theme.Colors.conversationSurface)
        .overlay(alignment: .bottom) {
            if !showsComposer, dockedPrompt == nil, scroller.showsJumpButton {
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
        .overlay(alignment: .bottom) {
            if showsComposer, editedBlockID == nil {
                ComposerWebsiteSuggestion(
                    composer: composer,
                    isFocused: composerFocused,
                    composerHeight: effectiveComposerHeight(floatsTopStrip: floatsTopStrip),
                    onOpen: openWebsiteSuggestion
                )
            }
        }
        .overlay { sendFlightOverlay }
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
        .onChange(of: ObjectIdentifier(conversation)) { _, _ in
            sendHandoff = .idle
            scroller.cancelSendHandoff()
            speechInput.cancel(reason: "conversationChanged")
            cancelEditing(reason: "conversationChanged", keepFocus: false)
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
                    ConversationFilesSheet(artifacts: conversationFiles) { artifact in
                        pendingFilePreview = artifact
                        modalPresentation = nil
                        Log.ui.info("ConversationPage.artifactPreview select conversation=\(conversation.id) filename=\(artifact.fileName)")
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
            case .modelPicker, .serviceDetail, .photos, .files, .attachment, .artifacts:
                EmptyView()
            }
        }
        .alert(item: $alertPresentation) { presented in
            switch presented {
            case .deleteConversation:
                Alert(
                    title: Text("Delete this conversation?"),
                    message: Text("This removes the conversation from your history. This can't be undone."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Delete")) {
                        Log.ui.info("ConversationPage.deleteConversation conversation=\(conversation.id) blocks=\(conversation.transcript.count)")
                        conversation.cancelAll()
                        onDeleteConversation()
                    }
                )
            case .branch(let id):
                Alert(
                    title: Text("Branch into a new conversation?"),
                    message: Text("Forks this conversation at this reply and switches to the new one. The original stays put."),
                    primaryButton: .cancel(),
                    secondaryButton: .default(Text("Branch")) {
                        Log.ui.info("ConversationPage.branch conversation=\(conversation.id) atBlock=\(id)")
                        onBranch(id)
                    }
                )
            case .retry(let id):
                Alert(
                    title: Text("Regenerate this reply?"),
                    message: Text("Creates a new branch from this prompt. The original conversation is kept."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Regenerate")) {
                        Log.ui.info("ConversationPage.retry conversation=\(conversation.id) atBlock=\(id)")
                        latestSubmissionID = conversation.retry(at: id)?.id
                    }
                )
            }
        }
        .artifactMutationAlerts(
            $artifactMutation,
            onRename: renameFile,
            onDelete: deleteFile
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
                Log.ui.error("ConversationPage.fileImporter error=\(err.localizedDescription)")
                showAttachmentError(err)
            }
        }
    }

    private func pageTopBar(blockCount: Int) -> some View {
        ConversationPageTopBar(
            conversation: conversation,
            blockCount: blockCount,
            hasFiles: !conversationFiles.isEmpty,
            showsModelPicker: isModelConfigured,
            iconButtonSize: iconButtonSize,
            onShowSidebar: onShowSidebar,
            onToggleTemporary: onToggleTemporary,
            onPickModel: { modalPresentation = .modelPicker },
            onShowFiles: { modalPresentation = .artifacts },
            onCopyTranscript: { copyTranscript(blockCount: blockCount) },
            onDeleteConversation: { alertPresentation = .deleteConversation }
        )
    }

    private func presentPendingFilePreview() {
        guard let artifact = pendingFilePreview else { return }
        pendingFilePreview = nil
        navigationFile = artifact
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
        presentPendingFilePreview()
    }

    private var artifactNavigationPresented: Binding<Bool> {
        Binding(
            get: { navigationFile != nil },
            set: { presented in
                if !presented { navigationFile = nil }
            }
        )
    }

    private func startServiceMention() {
        composer.startMention()
        DispatchQueue.main.async { composerFocused = true }
        Log.ui.info("ConversationPage.startServiceMention conversation=\(conversation.id)")
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

    private func openWebsiteSuggestion(_ url: URL) {
        Log.ui.info("ConversationPage.openWebsite conversation=\(conversation.id) host=\(url.host ?? "?")")
        composerFocused = false
        LinkOpener.open(url: url, serviceManager: serviceManager)
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
        Log.ui.info("ConversationPage.openServiceExplorer conversation=\(conversation.id)")
    }

    private func handleAttachChoice(_ choice: AttachmentChoice) {
        switch choice {
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                Log.ui.warning("ConversationPage.attachCamera: no camera on this device")
                showAttachmentError(L10n.string("This device has no camera."))
                return
            }
            modalPresentation = .camera
        case .photos:
            modalPresentation = .photos
        case .files:
            modalPresentation = .files
        case .website:
            composerFocused = false
            LinkOpener.openStartPage(serviceManager: serviceManager)
        case .service(let picked):
            attachService(picked)
        }
    }

    private func attachService(_ picked: Service) {
        Log.ui.info("ConversationPage.attachService conversation=\(conversation.id) picked=\(picked.domain)")
        if conversation.attachService(picked) {
            Haptics.impact(.serviceAttached)
        }
    }

    private func removeService(_ service: Service) {
        Log.ui.info("ConversationPage.removeService conversation=\(conversation.id) service=\(service.domain)")
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
        guard sendHandoff == .idle else { return false }
        return switch conversation.activity {
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

    private var conversationFiles: [FileItem] {
        var seen = Set<String>()
        return (messageFiles + conversation.referencedFiles).filter { seen.insert($0.fileName.lowercased()).inserted }
    }

    private struct MessageFilesKey: Equatable {
        let conversation: Conversation.ID
        let blocks: Int
        let isBusy: Bool
        let files: Int
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
            && (editedBlockID != nil || !conversationFiles.isEmpty || !conversation.attachedServices.isEmpty)
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

    private var artifactControls: FileControls {
        FileControls(
            revision: artifactRevision,
            canMutate: !conversation.isTemporary,
            onRename: { beginRenamingFile($0) },
            onDelete: { artifactMutation = .deleting($0) }
        )
    }

    @ViewBuilder
    private func conversationBlockHost(_ block: ConversationBlock, latestCanvasBlockIDs: [URL: UUID]) -> some View {
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
        case .startedConversation(let id, let title):
            Button { onOpenConversation(id) } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(title)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                }
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(ConversationInteractiveRowSurface())
            .accessibilityIdentifier("conversation.message.startedConversation.\(id.uuidString)")
            .padding(.horizontal, 4)
        case .serviceControl(let control, let interactionID):
            ConversationServiceControlBlock(
                control: control,
                interactionID: interactionID,
                conversation: conversation,
                botControlPresenter: botControlPresenter,
                serviceAuthPresenter: serviceAuthPresenter,
                isBotControlPresentedInSheet: expandedBotControlSessionID != nil,
                isServiceAuthPresentedInSheet: expandedServiceAuthSessionID != nil,
                expandBotControl: expandBotControl,
                expandServiceAuth: expandServiceAuth,
                prepareServiceControl: prepareServiceControl
            )
                .padding(.horizontal, 4)
        case .userText, .userSkill, .agentContent, .thinking, .contextCompaction:
            transcriptContentBlock(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
        }
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
            Log.ui.warning("ConversationPage.serviceControl unavailable conversation=\(conversation.id) domain=\(control.domain)")
            return false
        }
        conversation.attachService(service)
        return true
    }

    private func composerBlock(
        isConversationEmpty: Bool,
        floatsTopStrip: Bool,
        isEmbedded: Bool
    ) -> some View {
        inputBar(
            isConversationEmpty: isConversationEmpty,
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
            allowsLoader: sendHandoff == .idle,
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
        case .agentContent, .startedConversation, .thinking, .contextCompaction, .serviceControl, .responseFooter:
            return nil
        }
        return Block(id: block.sourceBlockID, createdAt: block.createdAt, kind: kind)
    }

    @ViewBuilder
    private func blockRow(
        _ block: ConversationBlock,
        latestCanvasBlockIDs: [URL: UUID],
        identified: Bool = true,
        recordsTail: Bool = false
    ) -> some View {
        let measuresTail = recordsTail && sendHandoff == .idle
        let row = conversationBlockHost(block, latestCanvasBlockIDs: latestCanvasBlockIDs)
            .padding(.top, block.spacingBefore)
            .onGeometryChange(for: CGFloat?.self) {
                measuresTail ? $0.frame(in: .global).maxY : nil
            } action: {
                guard let bottom = $0 else { return }
                scroller.transcriptTail = bottom
            }

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
        GeometryReader { outer in
            ScrollView {
                transcriptRows(
                    blocks: blocks,
                    renderedBlocks: blocks,
                    latestCanvasBlockIDs: latestCanvasBlockIDs,
                    scrollToTurn: { id in
                        await anchorBecameReady(
                            id,
                            anchorTop: outer.frame(in: .global).minY
                        )
                    }
                )
            }
            .overlayPreferenceValue(LivePageCardAnchorKey.self) { anchors in
                ConversationInlineServicePages(
                    anchors: anchors,
                    browserPage: browserPage,
                    browserPageMount: browserPageMount,
                    serviceAuthPresenter: serviceAuthPresenter,
                    botControlPresenter: botControlPresenter
                )
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
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(scroller.sizeChangeAnchor, for: .sizeChanges)
            .scrollPosition($scroller.position, anchor: .top)
            .modifier(SidebarScrollLockModifier())
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .dismissesSelectableTextSelection {
                Log.ui.info("ConversationPage.dismissTextSelection conversation=\(conversation.id) via=transcriptTap")
            }
            .simultaneousGesture(TapGesture().onEnded {
                guard anyInputFocused else { return }
                Log.ui.info("ConversationUX.intent conversation=\(conversation.id) kind=dismissKeyboard via=transcriptTap")
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
            .onChange(of: latestSubmissionID) { _, new in
                guard new != nil else { return }
                transcriptWindow.reconcile(total: totalBlockCount)
            }
            .onChange(of: submissionAnchor) { old, new in
                guard old != new, let new else { return }
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
                latestSubmissionID = nil
                sendHandoff = .idle
                transcriptWindow.open(total: totalBlockCount)
                Log.ui.info("ConversationUX.lifecycle conversation=\(conversation.id) phase=viewportOpening target=bottom range=\(transcriptWindow.range.lowerBound)..<\(transcriptWindow.range.upperBound) total=\(totalBlockCount) anchor=\(submissionAnchor?.id.uuidString ?? "none") scale=\(displayScale) dynamicType=\(String(describing: dynamicTypeSize)) reduceMotion=\(reduceMotion) reduceTransparency=\(reduceTransparency)")
                scroller.openAtBottom(conversationID: "\(conversation.id)", onSettled: onInitialTranscriptPresented)
            }
            .onDisappear { scroller.close() }
        }
    }

    private func transcriptRows(
        blocks: [ConversationBlock],
        renderedBlocks: [ConversationBlock],
        latestCanvasBlockIDs: [URL: UUID],
        scrollToTurn: @escaping (TurnID) async -> Void
    ) -> some View {
        let holdsHistory = holdsTranscript
        let historyTail = sendTranscriptTail
        return VStack(spacing: 0) {
            if conversation.canChangeRetention {
                ConversationEmptyState(
                    isModelConfigured: isModelConfigured,
                    isTemporary: conversation.isTemporary,
                    layout: viewportLayout,
                    onChooseModel: { modalPresentation = .modelPicker }
                )
            }
            earlierWindowBoundary(blocks: blocks)
            let anchorIndex = renderedBlocks.firstIndex { $0.id == anchoredTurnID }
            let hasAnchor = latestSubmissionID != nil && submissionAnchor != nil && (anchoredQueuedMessage != nil || anchorIndex != nil)
            VStack(spacing: 0) {
                ForEach(Array(renderedBlocks.prefix(hasAnchor ? anchorIndex ?? renderedBlocks.count : renderedBlocks.count))) { block in
                    blockRow(block, latestCanvasBlockIDs: latestCanvasBlockIDs, recordsTail: !hasAnchor && block.id == renderedBlocks.last?.id)
                }
                if let queued = anchoredQueuedMessage {
                    activityRow(blocks: renderedBlocks)
                    stoppedRow
                    ForEach(conversation.queuedMessages.filter { $0.id != queued.id }) { queued in
                        queuedRow(queued)
                    }
                } else if !hasAnchor {
                    activityRow(blocks: renderedBlocks)
                    stoppedRow
                    queuedRows
                }
            }
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
                guard old != new, hasAnchor, let submissionID = latestSubmissionID else { return }
                scroller.preserveTurn(submissionID)
            }
            .visualEffect { content, geometry in
                content.offset(y: holdsHistory ? historyTail - geometry.frame(in: .global).maxY : 0)
            }
            if let submissionID = latestSubmissionID, hasAnchor {
                VStack(spacing: 0) {
                    if let queued = anchoredQueuedMessage {
                        queuedRow(queued, identified: false)
                    } else if let anchorIndex {
                        blockRow(
                            renderedBlocks[anchorIndex],
                            latestCanvasBlockIDs: latestCanvasBlockIDs,
                            identified: false,
                            recordsTail: anchorIndex == renderedBlocks.count - 1
                        )
                        ForEach(Array(renderedBlocks.dropFirst(anchorIndex + 1))) { block in
                            blockRow(block, latestCanvasBlockIDs: latestCanvasBlockIDs, identified: false, recordsTail: block.id == renderedBlocks.last?.id)
                        }
                        activityRow(blocks: renderedBlocks)
                        stoppedRow
                        queuedRows
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    scroller.measureAnchorContent($0)
                }
                .environment(\.sendFlight, sendFlight)
                .coordinateSpace(.named(SendFlight.coordinateSpace))
                .offset(y: sendRiseOffset)
                .opacity(sendRiseOpacity)
                .modifier(ViewportFloorFrame(layout: viewportLayout, includesAnchorFloor: true))
                .id(submissionID)
                .onGeometryChange(for: CGRect?.self) { geometry in
                    guard case .waitingForAnchor(let id, _) = sendHandoff, id == submissionID else { return nil }
                    return geometry.frame(in: .global)
                } action: { frame in
                    guard let frame, latestSubmissionID == submissionID else { return }
                    submissionFrame = frame
                }
                .onGeometryChange(for: CGFloat?.self) { geometry in
                    guard case .positioned(let id, _, _, _) = sendHandoff, id == submissionID else { return nil }
                    return geometry.frame(in: .global).minY
                } action: { top in
                    guard let top, latestSubmissionID == submissionID,
                          case .positioned(let id, _, let anchorTop, _) = sendHandoff,
                          id == submissionID else { return }
                    if abs(top - anchorTop) < 1 {
                        animateSendRise(submissionID)
                    } else {
                        scroller.preserveTurn(submissionID)
                    }
                }
                .task(id: submissionID) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    await scrollToTurn(submissionID)
                }
            }
            Color.clear
                .frame(height: 1)
        }
        .scrollTargetLayout()
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: Theme.ContainerWidth.readable)
        .frame(maxWidth: .infinity)
        .modifier(ViewportFloorFrame(layout: viewportLayout))
        .contentShape(Rectangle())
        .background(KeyboardDismissPadding(padding: viewportLayout.composerHeight))
    }

    private func anchorBecameReady(_ anchorID: TurnID, anchorTop: CGFloat) async {
        guard latestSubmissionID == anchorID, submissionAnchor != nil,
              case .waitingForAnchor(let submissionID, let origin) = sendHandoff,
              submissionID == anchorID else { return }

        let offset = reduceMotion ? 0 : max(0, sendStartTop(origin) - anchorTop)
        sendHandoff = .positioned(submissionID: submissionID, offset: offset, anchorTop: anchorTop, origin: origin)
        scroller.beginSendHandoff(anchorID)
    }

    private func sendStartTop(_ origin: CGPoint) -> CGFloat {
        min(sendTranscriptTail, origin.y - ConversationTranscriptMetrics.blockSpacing)
    }

    private var sendRiseOffset: CGFloat {
        switch sendHandoff {
        case .waitingForAnchor(_, let origin):
            guard !reduceMotion, !submissionFrame.isNull else { return 0 }
            return max(0, sendStartTop(origin) - submissionFrame.minY)
        case .positioned(_, let offset, _, _): return offset
        case .idle, .animating: return 0
        }
    }

    private var sendFlight: SendFlight? {
        guard !reduceMotion, sendHandoff != .idle else { return nil }
        return SendFlight(origin: sendHandoff.origin) { bubble in
            guard sendFlightPath == nil else { return }
            sendFlightBubble = bubble
        }
    }

    private func sendFlightBubbleOrigin(_ textOrigin: CGPoint) -> CGPoint {
        CGPoint(x: textOrigin.x - UserBubble.textInset.width, y: textOrigin.y - UserBubble.textInset.height)
    }

    private func risingSendFlightPath(offset: CGFloat, anchorTop: CGFloat, origin: CGPoint) -> SendFlight.Path? {
        guard let sendFlightBubble, !submissionFrame.isNull else { return nil }
        let end = CGPoint(
            x: submissionFrame.minX + sendFlightBubble.frame.minX,
            y: anchorTop + sendFlightBubble.frame.minY
        )
        return SendFlight.Path(
            origin: sendFlightBubbleOrigin(origin),
            start: CGPoint(x: end.x, y: end.y + offset),
            end: end
        )
    }

    @ViewBuilder
    private var sendFlightOverlay: some View {
        if sendHandoff != .idle,
           let sendFlightBubble,
           let path = sendFlightPath ?? sendHandoff.origin.map({ .resting(at: sendFlightBubbleOrigin($0)) }) {
            GeometryReader { proxy in
                SendFlightBubbleView(
                    bubble: sendFlightBubble,
                    path: path,
                    page: proxy.frame(in: .global).origin,
                    elapsed: sendFlightPath == nil ? 0 : SendFlight.rise.settlingDuration
                )
            }
            .animation(.linear(duration: SendFlight.rise.settlingDuration), value: sendFlightPath)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var sendRiseOpacity: Double {
        guard case .waitingForAnchor = sendHandoff else { return 1 }
        return reduceMotion || submissionFrame.isNull ? 0 : 1
    }

    private func animateSendRise(_ submissionID: UUID) {
        guard case .positioned(let id, let offset, let anchorTop, let origin) = sendHandoff,
              id == submissionID else { return }
        let anchorID = submissionID
        Log.ui.info("ConversationUX.sendHandoff conversation=\(conversation.id) phase=animating submission=\(submissionID) anchor=\(anchorID) rise=\(Int(offset)) historyRise=\(Int(offset))")
        withAnimation(reduceMotion ? nil : .spring(SendFlight.rise), completionCriteria: .logicallyComplete) {
            sendFlightPath = risingSendFlightPath(offset: offset, anchorTop: anchorTop, origin: origin)
            sendHandoff = .animating(submissionID)
        } completion: {
            guard sendHandoff == .animating(submissionID) else { return }
            sendFlightPath = nil
            sendHandoff = .idle
            scroller.endSendHandoff()
            Log.ui.info("ConversationUX.sendHandoff conversation=\(conversation.id) phase=settled submission=\(submissionID) anchor=\(anchorID)")
        }
        if anyInputFocused { prepareComposerSubmission() }
    }

    private func earlierWindowBoundary(blocks: [ConversationBlock]) -> some View {
        ZStack {
            if transcriptWindow.isLoadingEarlier {
                CellularAutomatonLoader.small
                    .accessibilityLabel("Loading earlier messages…")
            }
        }
            .frame(maxWidth: .infinity)
            .frame(height: transcriptWindow.hasEarlier ? 44 : 0)
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
        Log.ui.info("ConversationUX.content conversation=\(conversation.id) reason=\(reason) range=\(transcriptWindow.range.lowerBound)..<\(transcriptWindow.range.upperBound) total=\(total) anchor=\(submissionAnchor?.id.uuidString ?? "none") busy=\(conversation.isBusy)")
    }

    private func inputBar(
        isConversationEmpty: Bool,
        floatsTopStrip: Bool,
        isEmbedded: Bool
    ) -> some View {
        ConversationComposer(
            composer: composer,
            isEditingMessage: editedBlockID != nil,
            editDraft: $editDraft,
            speech: speechInput,
            attachedServices: conversation.attachedServices,
            conversationFiles: conversationFiles,
            fieldFocused: $composerFocused,
            isFieldFocused: composerFocused,
            sessionID: conversation.id,
            isConversationEmpty: isConversationEmpty,
            isTemporary: conversation.isTemporary,
            isBusy: conversation.isBusy,
            followIntents: conversation.followIntents,
            floatsTopStrip: floatsTopStrip,
            isEmbedded: isEmbedded,
            iconButtonSize: iconButtonSize,
            composerButtonSize: composerButtonSize,
            onOpenAttachment: { artifact, sourceID in openAttachment(artifact, sourceID: sourceID) },
            onOpenConversationFile: { openAttachment($0) },
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
                Log.ui.info("ConversationPage.stop conversation=\(conversation.id)")
                conversation.stopCurrentTurn()
            },
            onSpeechBegin: beginSpeech,
            hidesPlaceholder: sendFlight != nil,
            onInputFrameChange: { composerInputFrame = $0 }
        )
        .equatable()
        .task(id: composerFocusRequestID) {
            guard let composerFocusRequestID else { return }
            await Task.yield()
            composerFocused = true
            Log.ui.info("ConversationUX.intent conversation=\(conversation.id) kind=focusRequest phase=applied request=\(composerFocusRequestID)")
            onComposerFocusRequestHandled(composerFocusRequestID)
        }
    }

    private func composerDock(
        isConversationEmpty: Bool,
        totalBlockCount: Int,
        floatsTopStrip: Bool
    ) -> some View {
        composerBlock(isConversationEmpty: isConversationEmpty, floatsTopStrip: floatsTopStrip, isEmbedded: false)
            .transition(.opacity)
            .overlay(alignment: .top) {
                if scroller.showsJumpButton {
                    ScrollToBottomControl(
                        composer: composer,
                        composerFocused: composerFocused,
                        isEditingMessage: editedBlockID != nil,
                        hasFiles: !conversationFiles.isEmpty,
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

    private func promptDock(
        _ pending: Conversation.PendingPrompt,
        totalBlockCount: Int
    ) -> some View {
        ConversationPromptCard(
            pending: pending,
            conversation: conversation,
            showsLoader: sendHandoff == .idle,
            composerButtonSize: composerButtonSize,
            onCustomFocusChange: { choiceInputFocused = $0 }
        )
            .id(pending.id)
            .background(
                Theme.Colors.conversationSurface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)
            .overlay(alignment: .top) {
                if scroller.showsJumpButton {
                    ScrollToBottomButton(composerButtonSize: composerButtonSize) {
                        transcriptWindow.showLatest(total: totalBlockCount)
                        DispatchQueue.main.async { scroller.rideToBottom() }
                    }
                        .offset(y: -Theme.Size.minimumTouchTarget - Theme.Spacing.xs)
                        .transition(.opacity)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                Log.ui.info("ConversationUX.promptDock conversation=\(conversation.id) prompt=\(pending.id) kind=\(pending.kind.rawValue) secret=\(pending.secretEntry != nil) phase=presented")
            }
            .onDisappear {
                Log.ui.info("ConversationUX.promptDock conversation=\(conversation.id) prompt=\(pending.id) phase=dismissed")
            }
    }

    private func ensureModelAccess() -> Bool {
        guard modelAccessNeedsAttention else { return true }
        Log.ui.info("ConversationPage.modelAccess blocked conversation=\(conversation.id) provider=\(conversation.modelSelection.providerID) reason=unavailable")
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
                    await service.checkAccess(reason: .conversationOpen)
                }
            }
        }
    }

    private func resolveSignInControl(_ item: Conversation.PendingServiceControl?) async {
        guard let item,
              case .signIn(let domain, _) = item.control,
              let service = conversation.attachedService(domain: domain) else { return }
        Log.ui.info("ConversationPage.authProbe start conversation=\(conversation.id) domain=\(domain) state=\(service.signInState.rawValue)")
        await service.checkAccess(policy: .current, reason: .pendingSignIn, preflight: item.accessPreflight)
        guard !Task.isCancelled else {
            Log.ui.info("ConversationPage.authProbe canceled conversation=\(conversation.id) domain=\(domain)")
            return
        }
        await service.attemptSilentSignIn(reason: .conversationOpen)
        guard !Task.isCancelled else { return }
        Log.ui.info("ConversationPage.authProbe done conversation=\(conversation.id) domain=\(domain) state=\(service.signInState.rawValue)")
        if service.signInState.isAuthenticated {
            conversation.resolveServiceControl(id: item.id, result: service.accessResult())
        } else {
            let result = await conversation.signInService(
                domain: domain,
                resumeAgent: false,
                using: service.supportsWebAuthentication ? serviceAuthPresenter : nil
            )
            conversation.resolveServiceControl(id: item.id, result: result)
        }
    }

    private func copyTranscript(blockCount: Int) {
        Task {
            do {
                let text = String(decoding: try await conversation.exportTranscript(), as: UTF8.self)
                UIPasteboard.general.string = text
                Haptics.impact(.copy)
                Log.ui.info("ConversationPage.copyTranscript conversation=\(conversation.id) blocks=\(blockCount) chars=\(text.count)")
                showCopiedToast()
            } catch {
                Log.ui.error("ConversationPage.copyTranscript conversation=\(conversation.id) encode failed: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func copyMessage(_ text: String, blockId: UUID) {
        UIPasteboard.general.string = text
        Haptics.impact(.copy)
        Log.ui.info("ConversationPage.copyMessage conversation=\(conversation.id) block=\(blockId) chars=\(text.count)")
        copiedBlockId = blockId
        showCopiedToast()
    }

    private func showCopiedToast() {
        toast = Toast(message: L10n.string("Message copied", comment: "Toast shown after the user copies a conversation message to the clipboard."))
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
        sendTranscriptTail = scroller.transcriptTail
        let receipt = conversation.enqueue(
            message.text,
            attachments: message.attachments,
            skillInvocation: skillInvocation
        )
        latestSubmissionID = receipt.id
        submissionFrame = .null
        sendFlightBubble = nil
        sendFlightPath = nil
        sendHandoff = .waitingForAnchor(submissionID: receipt.id, origin: composerInputFrame.origin)
        scroller.holdForSend(receipt.id)
        Log.ui.info("ConversationPage.send conversation=\(conversation.id) draft=\(message.id) submission=\(receipt.id) disposition=\(receipt.disposition.rawValue) chars=\(message.text.count) attachments=\(message.attachments.count)")
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
        Log.ui.info("ConversationPage.beginEditing conversation=\(conversation.id) block=\(block.id) chars=\(text.count)")
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
        Log.ui.info("ConversationPage.commitEdit conversation=\(conversation.id) block=\(blockID) chars=\(trimmed.count)")
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
        Log.ui.info("ConversationPage.cancelEditing conversation=\(conversation.id) block=\(editedBlockID) reason=\(reason)")
        withAnimation(Theme.Animation.handoff, completionCriteria: .logicallyComplete) {
            self.editedBlockID = nil
            editDraft = AttributedString()
        } completion: {
            if keepFocus { composerFocused = true }
        }
    }

    private func openAttachment(_ att: FileItem, sourceID _: String? = nil) {
        Log.ui.info("ConversationPage.openAttachment conversation=\(conversation.id) kind=\(att.kind.rawValue) name=\(att.displayName)")
        navigationFile = att
    }

    private func openSkill(_ skill: Skill) {
        Skills.shared.refresh()
        let current = Skills.shared.skill(named: skill.name) ?? skill
        guard current.owner != .system else { return }
        navigationSkill = SkillDraft(current)
        Log.ui.info("ConversationPage.skillNavigation select conversation=\(conversation.id) name=\(current.name)")
    }

    private func openLink(_ url: URL) {
        switch ConversationLinkDestination(url) {
        case .web(let url):
            LinkOpener.open(url: url, serviceManager: serviceManager)
        case .artifact(let filename):
            guard let artifact = conversationFiles.first(where: {
                $0.fileName.caseInsensitiveCompare(filename) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(filename) == .orderedSame
            }) else {
                Log.ui.warning("ConversationPage.openLink disposition=missing-artifact filename=\(filename)")
                return
            }
            Log.ui.info("ConversationPage.openLink disposition=artifact filename=\(artifact.fileName)")
            openAttachment(artifact)
        case .file(let path):
            Task {
                guard let file = await conversation.messageFile(path: path), file.exists else {
                    Log.ui.warning("ConversationPage.openLink disposition=removed-file path=\(path)")
                    toast = Toast(message: String(localized: "This file was removed."))
                    return
                }
                Log.ui.info("ConversationPage.openLink disposition=file filename=\(file.fileName)")
                openAttachment(file)
            }
        case .unsupported(let url):
            Log.ui.warning("ConversationPage.openLink disposition=unsupported url=\(LogPrivacy.url(url.absoluteString))")
        }
    }

    private func beginRenamingFile(_ artifact: FileItem) {
        artifactMutation = .rename(artifact)
    }

    private func renameFile(_ artifact: FileItem, to newFilename: String) {
        Task {
            do {
                let renamed = try await onRenameFile(artifact, newFilename)
                artifactRevision += 1
                Log.ui.info("ConversationPage.renameFile conversation=\(conversation.id) from=\(artifact.fileName) to=\(renamed.fileName)")
            } catch {
                Log.ui.error("ConversationPage.renameFile conversation=\(conversation.id) from=\(artifact.fileName) error=\(error.localizedDescription)")
                artifactMutation = .renameFailed(error.localizedDescription)
            }
        }
    }

    private func deleteFile(_ artifact: FileItem) {
        Task {
            do {
                try await onDeleteFile(artifact)
                artifactRevision += 1
                Log.ui.info("ConversationPage.deleteFile conversation=\(conversation.id) file=\(artifact.fileName)")
            } catch {
                Log.ui.error("ConversationPage.deleteFile conversation=\(conversation.id) file=\(artifact.fileName) error=\(error.localizedDescription)")
                artifactMutation = .deleteFailed(error.localizedDescription)
            }
        }
    }

    private func importAttachment(named name: String, source: String, operation: @escaping @MainActor () async throws -> FileItem) {
        composer.importAttachment(named: name, operation: operation) { error in
            Log.ui.error("ConversationPage.attach \(source) error=\(error.localizedDescription)")
            showAttachmentError(error)
        }
    }

    private func ingestPhotoItems(_ items: [PhotosPickerItem]) {
        for item in items {
            let suggested = item.itemIdentifier.map { "Photo-\($0.prefix(6)).jpg" } ?? "Photo.jpg"
            importAttachment(named: suggested, source: "photo") {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw FileError.imageDecodeFailed
                }
                return try await FileImporter.importImageDataAsync(data, suggestedName: suggested)
            }
        }
    }

    private func ingestCameraImage(_ image: UIImage) {
        importAttachment(named: "Camera.jpg", source: "camera") {
            try await FileImporter.importImageAsync(image, suggestedName: "Camera.jpg")
        }
    }

    private func ingestPastedImages(_ images: [PastedComposerImage]) {
        for image in images {
            importAttachment(named: image.suggestedName, source: "pastedImage") {
                switch image.content {
                case .data(let data):
                    try await FileImporter.importImageDataAsync(data, suggestedName: image.suggestedName)
                case .image(let value):
                    try await FileImporter.importImageAsync(value, suggestedName: image.suggestedName)
                }
            }
        }
    }

    private func ingestFileURLs(_ urls: [URL]) {
        for url in urls {
            importAttachment(named: url.lastPathComponent, source: "file") {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await FileImporter.importFileAsync(at: url)
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
