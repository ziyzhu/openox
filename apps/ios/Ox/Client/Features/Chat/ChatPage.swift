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

struct ChatPage: View {
    let chat: Chat
    let opensWithCompactTranscript: Bool
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

    @State private var composer = ChatComposerModel()
    @State private var speechInput = ChatSpeechInput()
    @Environment(\.scenePhase) private var scenePhase
    @State private var latestSubmissionID: UUID?
    @FocusState private var composerFocused: Bool
    @State private var editDraft: String = ""
    @State private var pendingArtifactPreview: Artifact?
    @State private var navigationArtifact: Artifact?
    @State private var navigationSkill: SkillDraft?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var renamingArtifact: Artifact?
    @State private var artifactRenameDraft = ""
    @State private var deletingArtifact: Artifact?
    @State private var artifactRenameError: String?
    @State private var artifactDeleteError: String?
    @State private var artifactRevision = 0

    private enum ModalPresentation: Identifiable {
        case modelPicker
        case serviceDetail(Service)
        case camera
        case edit(EditTarget)
        case photos
        case files
        case attachment(URL)
        case artifacts
        case artifactPicker

        var id: String {
            switch self {
            case .modelPicker: "modelPicker"
            case .serviceDetail(let service): "serviceDetail:\(service.domain)"
            case .camera: "camera"
            case .edit(let target): "edit:\(target.id)"
            case .photos: "photos"
            case .files: "files"
            case .attachment(let url): "attachment:\(url.absoluteString)"
            case .artifacts: "artifacts"
            case .artifactPicker: "artifactPicker"
            }
        }
    }
    @State private var modalPresentation: ModalPresentation?

    private enum AlertPresentation: Identifiable {
        case deleteChat
        case branch(UUID)
        case retry(UUID)

        var id: String {
            switch self {
            case .deleteChat: "deleteChat"
            case .branch(let id): "branch:\(id)"
            case .retry(let id): "retry:\(id)"
            }
        }
    }
    @State private var alertPresentation: AlertPresentation?

    @State private var copiedBlockId: UUID?
    @State private var messageSpeech = MessageSpeechPlayback()
    @State private var toast: Toast?
    @State private var dockAcknowledgement: ChatDock.Acknowledgement?
    @State private var runningServiceControlID: UUID?
    @State private var choiceInputFocused = false

    @State private var viewportLayout = ChatViewportLayout()
    @State private var transcriptWindow = TranscriptWindow()

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
                case .camera, .edit: modalPresentation
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
                    Log.ui.info("ChatPage.serviceDetailPresent chat=\(chat.id) domain=\(service.domain) composerFocused=\(composerFocused)")
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
                                Log.ui.info("ChatPage.artifactNavigation present chat=\(chat.id) filename=\(artifact.fileName)")
                                onArtifactNavigationChange(true)
                            }
                            .onDisappear {
                                Log.ui.info("ChatPage.artifactNavigation return chat=\(chat.id) filename=\(artifact.fileName)")
                                onArtifactNavigationChange(false)
                            }
                    }
                }
                .navigationDestination(item: $navigationSkill) { draft in
                    SkillEditorView(draft: draft, skills: .shared)
                        .onAppear {
                            Log.ui.info("ChatPage.skillNavigation present chat=\(chat.id) name=\(draft.name)")
                            onArtifactNavigationChange(true)
                        }
                        .onDisappear {
                            Log.ui.info("ChatPage.skillNavigation return chat=\(chat.id) name=\(draft.name)")
                            onArtifactNavigationChange(false)
                        }
                }
        }
        .background(Theme.Colors.chatSurface)
    }

    private var page: some View {
        let blocks = ChatBlock.project(
            chat.blocksWithTurnID,
            thinkingActivity: chat.thinkingActivity,
            isBusy: chat.isBusy
        )
        let dockState = ChatDock.project(
            interaction: activeInteraction,
            acknowledgement: dockAcknowledgement
        )
        let authProbe = chat.pendingServiceControl.flatMap { item -> Chat.PendingServiceControl? in
            guard isAttached(item.control), case .signIn = item.control else { return nil }
            return item
        }
        let transcript = pageContent(blocks)
            .toast($toast)
            .safeAreaBar(edge: .top, spacing: 0) {
                pageTopBar(blocks)
            }
            .onChange(of: toast?.id) { _, _ in
                if toast == nil {
                    copiedBlockId = nil
                    chat.clearNotice()
                }
            }
            .onChange(of: chat.notice, initial: true) { previous, notice in
                withAnimation(.easeOut(duration: 0.2)) {
                    if let message = notice.errorMessage {
                        toast = Toast(message: message, role: .error)
                    } else if previous.errorMessage != nil, toast?.role == .error {
                        toast = nil
                    }
                }
            }
            .onChange(of: serviceManager.repositoryState, initial: true) { _, state in
                guard case .failed(let failure) = state else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    let message = String(
                        format: L10n.string(
                            "Ox Server: %@",
                            comment: "Error shown on chat when the configured Ox Server cannot be reached."
                        ),
                        failure
                    )
                    toast = Toast(message: message, role: .error, duration: 4)
                }
            }
        return transcript
            .safeAreaInset(edge: .bottom, spacing: 0) {
                dock(dockState, chatBlocks: blocks)
                    .frame(maxWidth: Theme.ContainerWidth.readable)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                        scroller.viewportResized()
                    }
        }
        .background(Theme.Colors.chatSurface)
        .accessibilityHidden(composer.surface == .attachments || speechInput.isPresented)
        .overlay(alignment: .bottom) {
            servicePickerOverlay
        }
        .overlay(alignment: .bottom) {
            slashPickerOverlay
        }
        .overlay(alignment: .bottom) {
            ComposerAttachMenu(
                isPresented: composer.surface == .attachments,
                topClearance: iconButtonSize + Theme.Spacing.sm,
                onDismiss: { composer.setAttachmentMenuPresented(false) },
                onChoice: handleAttachChoice,
                onServices: startServiceMention
            )
        }
        .overlay {
            if speechInput.isPresented {
                HoldToTalkOverlay(speech: speechInput)
            }
        }
        .onChange(of: speechInput.notice) { _, message in
            guard let message else { return }
            toast = Toast(message: message, duration: 5)
            speechInput.notice = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { speechInput.interrupt() }
        }
        .onChange(of: chat.id) { _, _ in
            speechInput.cancel(reason: "chatChanged")
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
            Log.ui.info("ChatPage.onAppear chat=\(chat.id) title=\(chat.title)")
            #if targetEnvironment(simulator)
            DebugUIAPI.composer = composer
            #endif
        }
        .onDisappear {
            messageSpeech.stop(reason: "pageDisappear")
            speechInput.cancel(reason: "pageDisappear")
        }
        .task(id: chat.monoRepositoryRevision) {
            let updated = await chat.syncToMonoRepository()
            guard !updated.isEmpty else { return }
            let msg = updated.count == 1
                ? "\(updated[0]) updated"
                : "\(updated.count) services updated"
            withAnimation(.easeOut(duration: 0.2)) { toast = Toast(message: msg) }
        }
        .task(id: chat.id) {
            await refreshAttachedServiceAuth()
        }
        .task(id: authProbe?.id) {
            await resolveSignInControl(authProbe)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: sheetModal, onDismiss: presentPendingArtifactPreview) { presented in
            Group {
                switch presented {
                case .modelPicker:
                    ModelPickerSheet(chat: chat)
                        .presentationDetents([.medium, .large])
                case .serviceDetail(let service):
                    NavigationStack {
                        ServiceDetailView(
                            initialService: service,
                            primaryAction: .attach,
                            isAttached: chat.attachedServices.contains { $0.domain == service.domain },
                            onPrimaryAction: {
                                toggleServiceAttachment(service)
                                modalPresentation = nil
                            },
                            browserSessionID: chat.id
                        )
                    }
                    .presentationDetents([.medium, .large])
                case .artifacts:
                    ChatArtifactsSheet(artifacts: chatArtifacts) { artifact in
                        pendingArtifactPreview = artifact
                        modalPresentation = nil
                        Log.ui.info("ChatPage.artifactPreview select chat=\(chat.id) filename=\(artifact.fileName)")
                    }
                    .presentationDetents([.medium, .large])
                case .artifactPicker:
                    ArtifactPickerSheet(attachedIDs: composer.draftArtifactIDs) { picked in
                        picked.forEach(composer.attachArtifact)
                        Log.ui.info("ChatPage.attachArtifacts chat=\(chat.id) count=\(picked.count)")
                    }
                    .presentationDetents([.medium, .large])
                case .camera, .edit, .photos, .files, .attachment:
                    EmptyView()
                }
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.background)
        }
        .fullScreenCover(item: fullScreenModal) { presented in
            switch presented {
            case .camera:
                CameraPicker { image in
                    if let image { ingestCameraImage(image) }
                }
                .ignoresSafeArea()
            case .edit(let target):
                EditMessageView(
                    draft: $editDraft,
                    iconButtonSize: iconButtonSize,
                    composerButtonSize: composerButtonSize,
                    onCancel: { modalPresentation = nil },
                    onSend: { commitEdit(target) }
                )
            case .modelPicker, .serviceDetail, .photos, .files, .attachment, .artifacts, .artifactPicker:
                EmptyView()
            }
        }
        .alert(item: $alertPresentation) { presented in
            switch presented {
            case .deleteChat:
                Alert(
                    title: Text("Delete this chat?"),
                    message: Text("This removes the chat from your history. This can't be undone."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Delete Chat")) {
                        Log.ui.info("ChatPage.deleteChat chat=\(chat.id) blocks=\(chat.transcript.count)")
                        chat.cancelAll()
                        onDeleteChat()
                    }
                )
            case .branch(let id):
                Alert(
                    title: Text("Branch into a new chat?"),
                    message: Text("Forks this chat at this reply and switches to the new one. The original stays put."),
                    primaryButton: .cancel(),
                    secondaryButton: .default(Text("Branch")) {
                        Log.ui.info("ChatPage.branch chat=\(chat.id) atBlock=\(id)")
                        onBranch(id)
                    }
                )
            case .retry(let id):
                Alert(
                    title: Text("Regenerate this reply?"),
                    message: Text("Erases this reply and everything after it, then runs the prompt again."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Regenerate")) {
                        Log.ui.info("ChatPage.retry chat=\(chat.id) atBlock=\(id)")
                        latestSubmissionID = chat.retry(at: id)?.id
                    }
                )
            }
        }
        .artifactMutationAlerts(
            renaming: $renamingArtifact,
            renameDraft: $artifactRenameDraft,
            renameError: $artifactRenameError,
            deleting: $deletingArtifact,
            deleteError: $artifactDeleteError,
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

    private func pageContent(_ blocks: [ChatBlock]) -> some View {
        let range = transcriptWindow.resolvedRange(
            total: blocks.count,
            initialBatchSize: initialTranscriptBatchSize
        )
        return transcript(
            blocks: blocks,
            renderedBlocks: Array(blocks[range])
        )
    }

    private func pageTopBar(_ blocks: [ChatBlock]) -> some View {
        ChatPageTopBar(
            chat: chat,
            blockCount: blocks.count,
            hasArtifacts: !chatArtifacts.isEmpty,
            iconButtonSize: iconButtonSize,
            onShowSidebar: onShowSidebar,
            onToggleTemporary: onToggleTemporary,
            onPickModel: { modalPresentation = .modelPicker },
            onShowArtifacts: { modalPresentation = .artifacts },
            onCopyTranscript: { copyTranscript(blockCount: blocks.count) },
            onDeleteChat: { alertPresentation = .deleteChat }
        )
    }

    private func presentPendingArtifactPreview() {
        guard let artifact = pendingArtifactPreview else { return }
        pendingArtifactPreview = nil
        navigationArtifact = artifact
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
        Log.ui.info("ChatPage.startServiceMention chat=\(chat.id)")
    }

    @ViewBuilder
    private var servicePickerOverlay: some View {
        ComposerServicePicker(
            composer: composer,
            excludedDomains: Set(chat.attachedServices.map(\.domain)),
            space: viewportLayout.composerTop,
            composerHeight: viewportLayout.composerHeight,
            onSelect: selectMentionService,
            onExplore: openServiceExplorer
        )
    }

    private var slashPickerOverlay: some View {
        ComposerSlashPicker(
            composer: composer,
            isFocused: composerFocused,
            space: viewportLayout.composerTop,
            composerHeight: viewportLayout.composerHeight,
            onSelect: { submitSkill($0, argument: "") }
        )
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
        Log.ui.info("ChatPage.openServiceExplorer chat=\(chat.id)")
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
        Log.ui.info("ChatPage.attachService chat=\(chat.id) picked=\(picked.domain)")
        if chat.attachService(picked) {
            Haptics.impact(.serviceAttached)
        }
    }

    private func removeService(_ service: Service) {
        Log.ui.info("ChatPage.removeService chat=\(chat.id) service=\(service.domain)")
        chat.setAttachedServices(chat.attachedServices.filter { $0.domain != service.domain })
    }

    private func toggleServiceAttachment(_ service: Service) {
        if chat.attachedServices.contains(where: { $0.domain == service.domain }) {
            removeService(service)
        } else {
            attachService(service)
        }
    }

    private var anyInputFocused: Bool {
        composerFocused || choiceInputFocused
    }

    private var showsActivity: Bool {
        chat.activity.isThinking && chat.thinkingActivity == nil
    }

    private var chatArtifacts: [Artifact] {
        chat.referencedArtifacts
    }

    private var submissionAnchor: Chat.SubmissionAnchor? {
        latestSubmissionID.flatMap { chat.anchor(forSubmissionID: $0) }
    }

    private var submissionAnchorID: UUID? {
        submissionAnchor?.id
    }

    private var anchoredQueuedMessage: Chat.QueuedMessage? {
        guard case .queued(let id) = submissionAnchor else { return nil }
        return chat.queuedMessages.first { $0.id == id }
    }

    private var anchorSlack: CGFloat {
        viewportLayout.slack(hasAnchor: submissionAnchorID != nil)
    }

    private var dockClearance: CGFloat {
        ChatViewportLayout.responseComposerSpacing
    }

    private func messageControls(sourceBlockID: UUID, editableBlock: Block? = nil) -> MessageControls {
        MessageControls(
            onCopy: { text in copyMessage(text, blockId: sourceBlockID) },
            isCopied: copiedBlockId == sourceBlockID,
            onReadAloud: { text in messageSpeech.toggle(text: text, blockID: sourceBlockID) },
            isSpeaking: messageSpeech.speakingBlockID == sourceBlockID,
            canMutate: !chat.isBusy && !chat.isTemporary,
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
            canMutate: !chat.isTemporary,
            onRename: { beginRenamingArtifact($0) },
            onDelete: { deletingArtifact = $0 }
        )
    }

    @ViewBuilder
    private func chatBlockHost(_ block: ChatBlock) -> some View {
        switch block.kind {
        case .responseFooter(let text, let phase):
            ResponseFooterBlockView(
                id: block.id,
                text: text,
                isVisible: phase.isVisible,
                controls: messageControls(sourceBlockID: block.sourceBlockID)
            )
        case .userText, .userSkill, .agentContent, .thinking, .contextCompaction:
            transcriptContentBlock(block)
        }
    }

    @ViewBuilder
    private func dockHost(_ dock: ChatDock, isChatEmpty: Bool) -> some View {
        switch dock.kind {
        case .permission(let request):
            PermissionRequestCard(request: request) { option in
                chat.resolvePrompt(blockId: request.id, answer: option)
                dockAcknowledgement = .permission(request.acknowledgement(for: option))
            }
            .padding(.horizontal, Theme.Spacing.sm + Theme.Spacing.xs)
        case .choice(let request):
            AgentChoiceRequestCard(request: request, onCustomFocusChange: { focused in
                choiceInputFocused = focused
            }) { option in
                chat.resolvePrompt(blockId: request.id, answer: option)
                dockAcknowledgement = .choice(ChoiceAcknowledgement(id: request.id, selection: option))
            }
            .padding(.horizontal, Theme.Spacing.sm + Theme.Spacing.xs)
        case .serviceControl(let item):
            VStack(spacing: 0) {
                ServiceControlView(
                    control: item.control,
                    signIn: { domain in
                        runningServiceControlID = item.id
                        let succeeded = await chat.signInService(domain: domain, resumeAgent: false)
                        if !succeeded { runningServiceControlID = nil }
                        return succeeded
                    },
                    completeBotControl: { await chat.completeBotControl(domain: $0, args: $1, resumeAgent: false) },
                    completePayment: { await chat.completePayment(domain: $0, args: $1) },
                    onResolved: { result in
                        runningServiceControlID = nil
                        chat.resolveServiceControl(id: item.id, result: result)
                    }
                )
                .padding(.horizontal, Theme.Spacing.sm + Theme.Spacing.xs)
                composerBlock(isChatEmpty: isChatEmpty)
            }
        case .permissionAcknowledgement(let acknowledgement):
            VStack(spacing: 0) {
                PermissionAcknowledgementView(acknowledgement: acknowledgement)
                    .padding(.horizontal, Theme.Spacing.sm + Theme.Spacing.xs)
                composerBlock(isChatEmpty: isChatEmpty)
            }
        case .choiceAcknowledgement(let acknowledgement):
            VStack(spacing: 0) {
                ChoiceAcknowledgementView(acknowledgement: acknowledgement)
                    .padding(.horizontal, Theme.Spacing.sm + Theme.Spacing.xs)
                composerBlock(isChatEmpty: isChatEmpty)
            }
        case .composer:
            composerBlock(isChatEmpty: isChatEmpty)
        }
    }

    private func composerBlock(isChatEmpty: Bool) -> some View {
        inputBar(isChatEmpty: isChatEmpty)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds in
                guard viewportLayout.measureComposer(bounds) else { return }
                scroller.viewportResized()
            }
    }

    private func transcriptContentBlock(_ block: ChatBlock) -> some View {
        let isStreamingTail = chat.isBusy && block.sourceBlockID == chat.transcript.last?.id
        return BlockView(
            block: block,
            isStreamingTail: isStreamingTail,
            chatID: chat.id,
            continuesThinking: isStreamingTail && chat.activity.isThinking,
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

    private func editableBlock(_ block: ChatBlock) -> Block? {
        let kind: Block.Kind
        switch block.kind {
        case .userText(let text, let attachments):
            kind = .userText(text, attachments: attachments)
        case .userSkill(let invocation, let attachments):
            kind = .userSkill(invocation, attachments: attachments)
        case .agentContent, .thinking, .contextCompaction, .responseFooter:
            return nil
        }
        return Block(id: block.sourceBlockID, createdAt: block.createdAt, kind: kind)
    }

    @ViewBuilder
    private func blockRow(
        _ block: ChatBlock,
        identified: Bool = true
    ) -> some View {
        let view = chatBlockHost(block)
        let enters = block.sourceBlockID == chat.transcript.last?.id
            && Date().timeIntervalSince(block.createdAt) < 2
            && !block.isUserInitiated
            && !block.isResponseFooter
        let row = view
        .padding(.top, block.spacingBefore)
        .modifier(RowEntrance(enabled: enters && !block.isPendingThinking))

        if identified {
            row.id(block.id)
        } else {
            row
        }
    }

    private struct RowEntrance: ViewModifier {
        let enabled: Bool
        @State private var entered: Bool

        init(enabled: Bool) {
            self.enabled = enabled
            _entered = State(initialValue: !enabled)
        }

        func body(content: Content) -> some View {
            content
                .opacity(!enabled || entered ? 1 : 0)
                .onAppear {
                    guard enabled, !entered else { return }
                    withAnimation(.easeOut(duration: Theme.Animation.entrance)) { entered = true }
                }
        }
    }

    @ViewBuilder
    private var activityRow: some View {
        if showsActivity {
            ActivityBubble()
                .id("__activity")
                .transition(.opacity)
                .padding(.top, MarkdownText.blockSpacing)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func queuedRow(_ queued: Chat.QueuedMessage, identified: Bool = true) -> some View {
        let row = QueuedBubble(
            message: queued,
            onOpenAttachment: { artifact, sourceID in openAttachment(artifact, sourceID: sourceID) },
            onOpenSkill: { openSkill($0) }
        ) { chat.cancelQueued(queued.id) }
            .transition(.opacity)
            .padding(.top, MarkdownText.blockSpacing)
        if identified {
            row.id(queued.id)
        } else {
            row
        }
    }

    private var queuedRows: some View {
        ForEach(chat.queuedMessages) { queued in
            queuedRow(queued)
        }
    }

    @State private var scroller = ChatViewportController()

    private func transcript(
        blocks: [ChatBlock],
        renderedBlocks: [ChatBlock]
    ) -> some View {
        let anchoredViewportHeight = viewportLayout.anchoredContentMinimumHeight
        return GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    transcriptRows(
                        blocks: blocks,
                        renderedBlocks: renderedBlocks,
                        anchoredViewportHeight: anchoredViewportHeight,
                        scrollToTurn: { id in
                            scroller.rideToTurn(id, animated: true) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    )
                }
                .contentMargins(.bottom, dockClearance, for: .scrollContent)
                .onScrollGeometryChange(for: ChatViewportController.Frame?.self) { geo in
                    let frame = ChatViewportController.Frame(geo)
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
                        logTranscriptWindow(reason: "earlier", total: blocks.count)
                    }
                }
                .scrollPosition($scroller.position)
                .modifier(SidebarScrollLockModifier())
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollDismissesKeyboard(.interactively)
                .dismissesSelectableTextSelection {
                    Log.ui.info("ChatPage.dismissTextSelection chat=\(chat.id) via=transcriptTap")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    guard anyInputFocused else { return }
                    Log.ui.info("ChatPage.dismissKeyboard chat=\(chat.id) via=transcriptTap")
                    composerFocused = false
                    if choiceInputFocused {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            scroller.gestureStarted()
                        }
                )
                .onChange(of: blocks.count) { _, n in
                    transcriptWindow.reconcile(total: n)
                    logTranscriptWindow(reason: "blocks", total: n)
                }
                .onChange(of: chat.isBusy) { _, busy in
                    logTranscriptWindow(reason: busy ? "busy" : "settled", total: blocks.count)
                }
                .onChange(of: submissionAnchor) { old, new in
                    guard old != new, let new else { return }
                    Log.ui.info("ChatPage.submissionAnchor chat=\(chat.id) id=\(new.id)")
                    transcriptWindow.anchor(on: new.id, in: blocks.map(\.id))
                }
                .onChange(of: composerFocused) { _, focused in
                    Log.ui.info("ChatComposer.focusChange chat=\(chat.id) focused=\(focused)")
                    scroller.focusChanged(
                        anyInputFocused,
                        slack: anchorSlack
                    )
                }
                .onChange(of: choiceInputFocused) { _, focused in
                    Log.ui.info("ChatChoice.focusChange chat=\(chat.id) focused=\(focused)")
                    scroller.focusChanged(
                        anyInputFocused,
                        slack: anchorSlack
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
                    transcriptWindow.open(
                        total: blocks.count,
                        initialBatchSize: initialTranscriptBatchSize
                    )
                    Log.ui.info("RenderContext chat=\(chat.id) viewport=\(Int(outer.size.width))x\(Int(outer.size.height)) scale=\(displayScale) safeArea=\(Int(outer.safeAreaInsets.top))/\(Int(outer.safeAreaInsets.bottom)) dynamicType=\(String(describing: dynamicTypeSize)) reduceMotion=\(reduceMotion) reduceTransparency=\(reduceTransparency)")
                    Log.ui.info("ChatPage.open chat=\(chat.id) position=bottom")
                    logTranscriptWindow(reason: "open", total: blocks.count)
                    scroller.openAtBottom(chatID: "\(chat.id)", onSettled: onInitialTranscriptPresented)
                }
            }
        }
    }

    private var initialTranscriptBatchSize: Int {
        opensWithCompactTranscript ? TranscriptWindow.openingBatchSize : TranscriptWindow.batchSize
    }

    private func transcriptRows(
        blocks: [ChatBlock],
        renderedBlocks: [ChatBlock],
        anchoredViewportHeight: CGFloat,
        scrollToTurn: @escaping (TurnID) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if chat.canChangeRetention {
                emptyChatState
            }
            earlierWindowBoundary(blocks: blocks)
            if let anchor = anchoredQueuedMessage {
                ForEach(renderedBlocks) { block in
                    blockRow(block)
                }
                activityRow
                ForEach(chat.queuedMessages.filter { $0.id != anchor.id }) { queued in
                    queuedRow(queued)
                }
                VStack(spacing: 0) {
                    queuedRow(anchor, identified: false)
                        .id(anchor.id)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    viewportLayout.measureAnchorContent($0)
                }
                .frame(minHeight: anchoredViewportHeight, alignment: .top)
                .task(id: anchor.id) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollToTurn(anchor.id)
                }
            } else if let anchorID = submissionAnchorID,
                      let anchorIndex = renderedBlocks.firstIndex(where: { $0.id == anchorID }) {
                ForEach(Array(renderedBlocks[..<anchorIndex])) { block in
                    blockRow(block)
                }
                VStack(spacing: 0) {
                    blockRow(
                        renderedBlocks[anchorIndex],
                        identified: false
                    )
                    .id(anchorID)
                    ForEach(Array(renderedBlocks.dropFirst(anchorIndex + 1))) { block in
                        blockRow(block, identified: false)
                    }
                    activityRow
                    queuedRows
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    viewportLayout.measureAnchorContent($0)
                }
                .frame(minHeight: anchoredViewportHeight, alignment: .top)
                .task(id: anchorID) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollToTurn(anchorID)
                }
            } else {
                ForEach(renderedBlocks) { block in
                    blockRow(block)
                }
                activityRow
                queuedRows
            }
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

    @ViewBuilder
    private var emptyChatState: some View {
        if chat.isTemporary {
            temporaryEmptyState
        } else {
            persistedEmptyState
        }
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

    private func earlierWindowBoundary(blocks: [ChatBlock]) -> some View {
        Color.clear
            .frame(height: transcriptWindow.hasEarlier ? 1 : 0)
            .onScrollVisibilityChange(threshold: TranscriptWindow.earlierBoundaryVisibilityThreshold) { visible in
                transcriptWindow.setEarlierBoundaryVisible(visible)
                if visible { requestEarlierReveal(blocks: blocks) }
            }
    }

    private func requestEarlierReveal(blocks: [ChatBlock]) {
        transcriptWindow.requestEarlier(
            anchor: readerAnchor(in: blocks),
            isUserScrolling: scroller.isUserScrolling
        )
    }

    private func readerAnchor(in blocks: [ChatBlock]) -> UUID? {
        if let visible = scroller.visibleBlockID { return visible }
        guard blocks.indices.contains(transcriptWindow.range.lowerBound) else { return nil }
        return blocks[transcriptWindow.range.lowerBound].id
    }

    private func logTranscriptWindow(reason: String, total: Int) {
        Log.ui.info("Transcript.window chat=\(chat.id) range=\(transcriptWindow.range.lowerBound)..<\(transcriptWindow.range.upperBound) total=\(total) anchor=\(submissionAnchor?.id.uuidString ?? "none") reason=\(reason)")
    }

    private func scrollToBottomButton(_ blocks: [ChatBlock]) -> some View {
        Button {
            transcriptWindow.showLatest(total: blocks.count)
            DispatchQueue.main.async { scroller.rideToBottom() }
        } label: {
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

    private func scrollToBottomOffset(for dock: ChatDock, isChatEmpty: Bool) -> CGFloat {
        let touchTargetInset = max(0, (Theme.Size.minimumTouchTarget - composerButtonSize) / 2)
        let firstSurfaceTop: CGFloat
        switch dock.kind {
        case .composer:
            let isResting = !composerFocused && composer.isEmpty
            let showsTopStrip = !chatArtifacts.isEmpty
                || !chat.attachedServices.isEmpty
                || isChatEmpty
                    && !chat.isBusy
                    && composer.draft.isEmpty
                    && composer.draftAttachments.isEmpty
            firstSurfaceTop = ChatComposer.firstSurfaceTopOffset(
                isResting: isResting,
                showsTopStrip: showsTopStrip
            )
        case .permission,
             .choice,
             .serviceControl,
             .permissionAcknowledgement,
             .choiceAcknowledgement:
            firstSurfaceTop = 0
        }
        return firstSurfaceTop - Theme.Spacing.md - composerButtonSize - touchTargetInset
    }

    private func inputBar(isChatEmpty: Bool) -> some View {
        ChatComposer(
            composer: composer,
            speech: speechInput,
            attachedServices: chat.attachedServices,
            chatArtifacts: chatArtifacts,
            fieldFocused: $composerFocused,
            isFieldFocused: composerFocused,
            sessionID: chat.id,
            isChatEmpty: isChatEmpty,
            isBusy: chat.isBusy,
            iconButtonSize: iconButtonSize,
            composerButtonSize: composerButtonSize,
            onOpenAttachment: { artifact, sourceID in openAttachment(artifact, sourceID: sourceID) },
            onOpenChatArtifact: { openAttachment($0) },
            onPasteImages: ingestPastedImages,
            onOpenService: { serviceDetailPresentation.wrappedValue = $0 },
            onRemoveService: removeService,
            onSubmitSkill: submitSkill,
            onPreparationIntent: chat.setModelPreparationIntent,
            onSend: { send() },
            onStop: {
                Log.ui.info("ChatPage.stop chat=\(chat.id)")
                chat.stopCurrentTurn()
            },
            onSpeechBegin: beginSpeech
        )
        .equatable()
        .task(id: composerFocusRequestID) {
            guard let composerFocusRequestID else { return }
            await Task.yield()
            composerFocused = true
            Log.ui.info("ChatComposer.focusRequest chat=\(chat.id) request=\(composerFocusRequestID)")
            onComposerFocusRequestHandled(composerFocusRequestID)
        }
    }

    private func dock(
        _ dock: ChatDock,
        chatBlocks: [ChatBlock]
    ) -> some View {
        let isChatEmpty = chat.canChangeRetention && chatBlocks.isEmpty
        return dockHost(dock, isChatEmpty: isChatEmpty)
            .transition(.opacity)
            .overlay(alignment: .top) {
                if scroller.showsJumpButton {
                    scrollToBottomButton(chatBlocks)
                        .offset(y: scrollToBottomOffset(for: dock, isChatEmpty: isChatEmpty))
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: Theme.Animation.standard),
                value: dock.id
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: Theme.Animation.standard),
                value: scroller.showsJumpButton
            )
            .task(id: dockAcknowledgement?.id) {
                guard let id = dockAcknowledgement?.id else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, dockAcknowledgement?.id == id else { return }
                dockAcknowledgement = nil
            }
    }

    private var activeInteraction: Chat.Interaction? {
        guard case .serviceControl(let control) = chat.interaction else {
            return chat.interaction
        }
        return activeServiceControl(control).map(Chat.Interaction.serviceControl)
    }

    private func activeServiceControl(_ item: Chat.PendingServiceControl?) -> Chat.PendingServiceControl? {
        guard let item,
              isAttached(item.control) else { return nil }
        if case .signIn(let domain, _) = item.control,
           runningServiceControlID != item.id,
           chat.attachedService(domain: domain)?.signInState.isAuthenticated == true {
            return nil
        }
        return item
    }

    private func isAttached(_ control: ServiceControl) -> Bool {
        chat.attachedServices.contains { $0.domain == control.domain }
    }

    private func refreshAttachedServiceAuth() async {
        await withTaskGroup(of: Void.self) { group in
            for service in chat.attachedServices {
                group.addTask { @MainActor in
                    await service.resolveSignInState(reason: .chatOpen)
                }
            }
        }
    }

    private func resolveSignInControl(_ item: Chat.PendingServiceControl?) async {
        guard let item,
              case .signIn(let domain, _) = item.control,
              let service = chat.attachedService(domain: domain) else { return }
        Log.ui.info("ChatPage.authProbe start chat=\(chat.id) domain=\(domain) state=\(service.signInState.rawValue)")
        await service.resolveSignInState(reason: .chatOpen)
        guard !Task.isCancelled else {
            Log.ui.info("ChatPage.authProbe canceled chat=\(chat.id) domain=\(domain)")
            return
        }
        await service.attemptSilentSignIn(reason: .chatOpen)
        guard !Task.isCancelled else { return }
        Log.ui.info("ChatPage.authProbe done chat=\(chat.id) domain=\(domain) state=\(service.signInState.rawValue)")
        if service.signInState.isAuthenticated {
            chat.resolveServiceControl(id: item.id, result: .null)
        }
    }

    private func copyTranscript(blockCount: Int) {
        Task {
            do {
                let text = String(decoding: try await chat.exportTranscript(), as: UTF8.self)
                UIPasteboard.general.string = text
                Haptics.impact(.copy)
                Log.ui.info("ChatPage.copyTranscript chat=\(chat.id) blocks=\(blockCount) chars=\(text.count)")
                showCopiedToast()
            } catch {
                Log.ui.error("ChatPage.copyTranscript chat=\(chat.id) encode failed: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func copyMessage(_ text: String, blockId: UUID) {
        UIPasteboard.general.string = text
        Haptics.impact(.copy)
        Log.ui.info("ChatPage.copyMessage chat=\(chat.id) block=\(blockId) chars=\(text.count)")
        copiedBlockId = blockId
        showCopiedToast()
    }

    private func showCopiedToast() {
        withAnimation(.easeOut(duration: 0.2)) {
            toast = Toast(message: L10n.string("Message copied", comment: "Toast shown after the user copies a chat message to the clipboard."))
        }
    }

    private func send() {
        prepareComposerSubmission()
        guard let message = composer.takeMessage() else { return }
        enqueue(message)
    }

    private func beginSpeech(accessible: Bool) {
        guard !composer.isImporting, !speechInput.isPresented else { return }
        prepareComposerSubmission()
        let draftID = composer.draftID
        let draft = composer.attributedDraft
        messageSpeech.stop(reason: "speechInput")
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
                Haptics.impact(.send)
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

    private func enqueue(_ message: ChatComposerModel.Message, skillInvocation: UserSkillInvocation? = nil) {
        let receipt = chat.enqueue(
            message.text,
            attachments: message.attachments,
            skillInvocation: skillInvocation
        )
        latestSubmissionID = receipt.id
        Log.ui.info("ChatPage.send chat=\(chat.id) draft=\(message.id) submission=\(receipt.id) disposition=\(receipt.disposition.rawValue) chars=\(message.text.count) attachments=\(message.attachments.count)")
    }

    private func submitSkill(_ skill: Skill, argument: String) {
        Log.ui.info("ChatComposer.skillSelect chat=\(chat.id) name=\(skill.name) services=\(skill.services.count)")
        if chat.attachServiceDomains(skill.services) {
            Haptics.impact(.serviceAttached)
        }
        Log.ui.info("ChatComposer.skillSubmit chat=\(chat.id) name=\(skill.name) argumentChars=\(argument.count)")
        let invocation = UserSkillInvocation(skill: skill, argument: argument)
        prepareComposerSubmission()
        composer.draft = invocation.expandedIntent
        composer.delayStopControl()
        guard let message = composer.takeMessage() else { return }
        enqueue(message, skillInvocation: invocation)
    }

    private func beginEditing(_ block: Block) {
        guard case let .userText(text, _) = block.kind else { return }
        Log.ui.info("ChatPage.beginEditing chat=\(chat.id) block=\(block.id) chars=\(text.count)")
        Haptics.impact(.editStarted)
        editDraft = text
        modalPresentation = .edit(EditTarget(id: block.id))
    }

    private func commitEdit(_ target: EditTarget) {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Log.ui.info("ChatPage.commitEdit chat=\(chat.id) block=\(target.id) chars=\(trimmed.count)")
        modalPresentation = nil
        latestSubmissionID = chat.editAndRerun(at: target.id, newText: trimmed)?.id
    }

    private func openAttachment(_ att: Artifact, sourceID _: String? = nil) {
        Log.ui.info("ChatPage.openAttachment chat=\(chat.id) kind=\(att.kind.rawValue) name=\(att.displayName)")
        navigationArtifact = att
    }

    private func openSkill(_ skill: Skill) {
        Skills.shared.refresh()
        let current = Skills.shared.skill(named: skill.name) ?? skill
        navigationSkill = SkillDraft(current)
        Log.ui.info("ChatPage.skillNavigation select chat=\(chat.id) name=\(current.name)")
    }

    private func openLink(_ url: URL) {
        switch ChatLinkDestination(url) {
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
        artifactRenameDraft = artifact.userFacingName
        renamingArtifact = artifact
    }

    private func renameArtifact(_ artifact: Artifact, to newFilename: String) {
        Task {
            do {
                let renamed = try await onRenameArtifact(artifact, newFilename)
                artifactRevision += 1
                Log.ui.info("ChatPage.renameArtifact chat=\(chat.id) from=\(artifact.fileName) to=\(renamed.fileName)")
            } catch {
                Log.ui.error("ChatPage.renameArtifact chat=\(chat.id) from=\(artifact.fileName) error=\(error.localizedDescription)")
                artifactRenameError = artifact.userFacingErrorDescription(error)
            }
        }
    }

    private func deleteArtifact(_ artifact: Artifact) {
        Task {
            do {
                try await onDeleteArtifact(artifact)
                artifactRevision += 1
                Log.ui.info("ChatPage.deleteArtifact chat=\(chat.id) file=\(artifact.fileName)")
            } catch {
                Log.ui.error("ChatPage.deleteArtifact chat=\(chat.id) file=\(artifact.fileName) error=\(error.localizedDescription)")
                artifactDeleteError = artifact.userFacingErrorDescription(error)
            }
        }
    }

    private func ingestPhotoItems(_ items: [PhotosPickerItem]) {
        for item in items {
            let suggested = item.itemIdentifier.map { "Photo-\($0.prefix(6)).jpg" } ?? "Photo.jpg"
            composer.importAttachment(named: suggested) {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ArtifactError.imageDecodeFailed
                }
                return try await ArtifactImporter.importImageDataAsync(data, suggestedName: suggested)
            } onFailure: { error in
                Log.ui.error("ChatPage.attach photo error=\(error.localizedDescription)")
                showAttachmentError(error)
            }
        }
    }

    private func ingestCameraImage(_ image: UIImage) {
        composer.importAttachment(named: "Camera.jpg") {
            try await ArtifactImporter.importImageAsync(image, suggestedName: "Camera.jpg")
        } onFailure: { error in
            Log.ui.error("ChatPage.attach camera error=\(error.localizedDescription)")
            showAttachmentError(error)
        }
    }

    private func ingestPastedImages(_ images: [PastedComposerImage]) {
        for image in images {
            composer.importAttachment(named: image.suggestedName) {
                try await ArtifactImporter.importImageDataAsync(image.data, suggestedName: image.suggestedName)
            } onFailure: { error in
                Log.ui.error("ChatPage.attach pastedImage error=\(error.localizedDescription)")
                showAttachmentError(error)
            }
        }
    }

    private func ingestFileURLs(_ urls: [URL]) {
        for url in urls {
            composer.importAttachment(named: url.lastPathComponent) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await ArtifactImporter.importFileAsync(at: url)
            } onFailure: { error in
                Log.ui.error("ChatPage.attach file error=\(error.localizedDescription)")
                showAttachmentError(error)
            }
        }
    }

    private func showAttachmentError(_ error: Error) {
        showAttachmentError(error.localizedDescription)
    }

    private func showAttachmentError(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            toast = Toast(message: message, role: .error)
        }
    }
}
