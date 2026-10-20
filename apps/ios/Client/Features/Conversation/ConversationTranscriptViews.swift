import SwiftUI
import Observation
import WebKit

private struct AttachmentThumb: View {
    let attachment: FileItem
    let sourceID: String
    let onOpen: (FileItem, String) -> Void

    var body: some View {
        FileThumbnail(
            attachment: attachment,
            style: .transcript,
            previewSourceID: sourceID
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onOpen(attachment, sourceID) }
        .accessibilityAddTraits(.isButton)
    }
}

private struct ConversationFileRow: View {
    let artifact: FileItem
    var previewSourceID: String? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if artifact.exists {
                FileThumbnail(
                    attachment: artifact,
                    style: .row,
                    previewSourceID: previewSourceID
                )
            } else {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
                    .frame(width: 44, height: 44)
                    .background(Theme.Colors.conversationSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(artifact.userFacingName)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(artifact.exists ? Theme.Colors.onSurface : Theme.Colors.conversationSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let typeName = artifact.userFacingTypeName, artifact.exists {
                    Text(typeName)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                } else if !artifact.exists {
                    Text("Deleted file")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if artifact.exists {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.conversationSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ConversationInteractiveRowSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        content
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.minimumTouchTarget)
            .conversationCardOutline()
            .contentShape(shape)
    }
}

struct StoppedTurnDivider: View {
    var body: some View {
        TranscriptStatusDivider(
            label: Text("Stopped"),
            systemImage: "stop.circle.fill",
            accessibilityIdentifier: "chat.stopped"
        )
    }
}

private struct TranscriptStatusDivider: View {
    let label: Text
    let systemImage: String
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            line
            Label { label } icon: { Image(systemName: systemImage) }
                .fixedSize()
            line
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Colors.conversationSecondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.Colors.conversationSecondary.opacity(0.2))
            .frame(height: 1)
    }
}

private struct ServiceInspectorRow: View {
    let link: ServiceInspectorLink
    let conversationID: UUID
    let rowID: UUID
    let pageMount: WebPageMountCoordinator
    @Environment(ServiceManager.self) private var serviceManager
    @State private var isPresented = false

    private var service: Service? { serviceManager.inspectionService(domain: link.domain) }
    private var browserSession: ServiceBrowserActionSession? {
        guard let service, service.domain == BrowserFunctionCatalog.internalDomain else { return nil }
        return serviceManager.browserActionSessions.existingSession(for: conversationID, service: service)
    }
    private var canInspect: Bool {
        guard let service else { return false }
        guard service.domain == BrowserFunctionCatalog.internalDomain else { return true }
        return browserSession != nil
    }
    private var page: WebPage? {
        browserSession?.webPage
    }
    private var isInline: Bool {
        pageMount.isInline(page: page, ownerID: rowID)
    }
    private var subtitle: String {
        if let host = page?.url?.host(percentEncoded: false) { return host }
        return canInspect ? String(localized: "View live page") : String(localized: "Page unavailable")
    }
    private var placeholder: LivePageCard.Placeholder {
        if canInspect { return .invitation(String(localized: "Open to view the live page")) }
        return .unavailable(String(localized: "Page unavailable"))
    }
    private var inlinePage: WebPage? {
        isInline ? page : nil
    }
    private var activatePage: (() -> Void)? {
        guard canInspect, !isInline else { return nil }
        guard let page else { return nil }
        return { pageMount.activate(page: page, ownerID: rowID) }
    }
    private var expandPageAction: (() -> Void)? {
        canInspect ? { expandPage() } : nil
    }

    var body: some View {
        LivePageCard(
            service: service,
            fallbackSystemImage: "safari",
            title: link.serviceName,
            subtitle: subtitle,
            mount: nil,
            inlinePageAnchorID: inlinePage == nil ? nil : rowID,
            isPresented: false,
            placeholder: placeholder,
            activate: activatePage,
            expand: expandPageAction,
            cancel: nil,
            accessibilityIdentifier: A11yID.ConversationControls.Message.serviceInspector(link.domain),
            expandAccessibilityIdentifier: A11yID.ServiceInspector.open,
            cancelAccessibilityIdentifier: ""
        )
        .fullScreenCover(isPresented: $isPresented, onDismiss: {
            if let page { pageMount.restore(page: page, ownerID: rowID) }
        }) {
            if let service {
                NavigationStack {
                    ServicePageInspector(service: service, browserSessionID: conversationID)
                }
            }
        }
        .onAppear {
            logInlineState(reason: "appear")
        }
        .onChange(of: isInline) { _, _ in
            logInlineState(reason: "placement")
        }
    }

    private func expandPage() {
        Task { @MainActor in
            if let page {
                guard await pageMount.detach(page: page, ownerID: rowID) else { return }
            }
            isPresented = true
        }
    }

    private func logInlineState(reason: String) {
        Log.webView.info("ServiceInspectorRow.inline reason=\(reason) row=\(rowID) mounted=\(isInline) session=\(browserSession != nil) page=\(page != nil)")
    }
}

struct ActivityBubble: View {
    private let label = L10n.string("Plowing…")

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader.small
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityIdentifier(A11yID.ConversationControls.activity)
    }
}

struct MessageControls {
    let onCopy: (String) -> Void
    let isCopied: Bool
    let canMutate: Bool
    let onBranch: () -> Void
    let onRetry: () -> Void
    let onEdit: () -> Void
}

struct FileControls {
    let revision: Int
    let canMutate: Bool
    let onRename: (FileItem) -> Void
    let onDelete: (FileItem) -> Void
}

struct SendFlight {
    static let coordinateSpace = "sendFlight"
    static let rise = Spring(duration: 0.33, bounce: 0)
    static let departure = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.25, y: 0.7),
        endControlPoint: UnitPoint(x: 0.4, y: 1)
    )
    static let departureDuration: TimeInterval = 0.2

    static func departed(after elapsed: TimeInterval) -> Double {
        departure.value(at: min(1, elapsed / departureDuration))
    }

    struct Bubble: Equatable {
        let text: String
        let frame: CGRect
    }

    struct Path: Equatable {
        let origin: CGPoint
        let start: CGPoint
        let end: CGPoint

        static func resting(at point: CGPoint) -> Path {
            Path(origin: point, start: point, end: point)
        }

        func position(elapsed: TimeInterval) -> CGPoint {
            let rise = SendFlight.rise.value(target: 1.0, time: elapsed)
            let remaining = 1 - SendFlight.departed(after: elapsed)
            return CGPoint(
                x: start.x + (end.x - start.x) * rise + (origin.x - start.x) * remaining,
                y: start.y + (end.y - start.y) * rise + (origin.y - start.y) * remaining
            )
        }
    }

    let origin: CGPoint?
    let report: (Bubble) -> Void
}

extension EnvironmentValues {
    @Entry var sendFlight: SendFlight? = nil
}

struct SendFlightBubbleView: View, Animatable {
    let bubble: SendFlight.Bubble
    let path: SendFlight.Path
    let page: CGPoint
    var elapsed: TimeInterval

    var animatableData: TimeInterval {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        let position = path.position(elapsed: elapsed)
        Text(bubble.text)
            .font(Theme.Fonts.bodyMd)
            .foregroundStyle(Theme.Colors.onSurface)
            .frame(width: bubble.frame.width - 2 * UserBubble.textInset.width, alignment: .leading)
            .padding(.horizontal, UserBubble.textInset.width)
            .padding(.vertical, UserBubble.textInset.height)
            .background(Theme.Colors.bubble.opacity(SendFlight.departed(after: elapsed)), in: UserBubble.shape)
            .offset(x: position.x - page.x, y: position.y - page.y)
    }
}

struct UserBubble: View {
    static let textInset = CGSize(width: 14, height: Theme.Spacing.md)
    static let shape = RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)

    let text: String
    let attachments: [FileItem]
    let sourcePrefix: String
    let onOpenAttachment: (FileItem, String) -> Void
    @Environment(\.sendFlight) private var sendFlight

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if attachments.count == 1 {
                attachmentThumb(at: 0)
            } else if attachments.count > 1 {
                Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: attachments.count, by: 2)), id: \.self) { index in
                        GridRow {
                            attachmentThumb(at: index)
                            if index + 1 < attachments.count {
                                attachmentThumb(at: index + 1)
                            }
                        }
                    }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    // Body font metrics add vertical whitespace around glyphs, so 12 pt reads like 14 pt horizontally.
                    .padding(.horizontal, Self.textInset.width)
                    .padding(.vertical, Self.textInset.height)
                    .background(Theme.Colors.bubble, in: Self.shape)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(SendFlight.coordinateSpace))
                    } action: {
                        sendFlight?.report(SendFlight.Bubble(text: text, frame: $0))
                    }
                    .opacity(sendFlight == nil ? 1 : 0)
            }
        }
    }

    private func attachmentThumb(at index: Int) -> some View {
        let attachment = attachments[index]
        return AttachmentThumb(
            attachment: attachment,
            sourceID: "\(sourcePrefix):\(index):\(attachment.id)",
            onOpen: onOpenAttachment
        )
    }
}

private struct UserSkillBubble: View {
    let invocation: UserSkillInvocation
    let attachments: [FileItem]
    let sourcePrefix: String
    let onOpenAttachment: (FileItem, String) -> Void
    let onOpenSkill: (Skill) -> Void

    var body: some View {
        skillBubbles.environment(\.sendFlight, nil)
    }

    private var skillBubbles: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if invocation.skill.owner == .system {
                UserBubble(
                    text: invocation.displayTitle,
                    attachments: attachments,
                    sourcePrefix: sourcePrefix,
                    onOpenAttachment: onOpenAttachment
                )
            } else {
                SkillBubble(skill: invocation.skill, onOpen: onOpenSkill)
            }

            if invocation.skill.owner != .system && (!invocation.argument.isEmpty || !attachments.isEmpty) {
                UserBubble(
                    text: invocation.argument,
                    attachments: attachments,
                    sourcePrefix: sourcePrefix,
                    onOpenAttachment: onOpenAttachment
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.ConversationControls.Message.user)
            }
        }
    }
}

private struct SkillBubble: View {
    let skill: Skill
    let onOpen: (Skill) -> Void

    var body: some View {
        Button { onOpen(skill) } label: {
            Text(verbatim: "/\(skill.displayName)")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, Theme.Spacing.md)
                .conversationCardOutline(cornerRadius: Theme.Radius.xl)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("/\(skill.displayName), \(skill.description)")
        .accessibilityIdentifier(A11yID.ConversationControls.Message.skill(skill.name))
    }
}

struct QueuedBubble: View {
    let message: Conversation.QueuedMessage
    let onOpenAttachment: (FileItem, String) -> Void
    let onOpenSkill: (Skill) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 40)
                if let invocation = message.skillInvocation {
                    UserSkillBubble(
                        invocation: invocation,
                        attachments: message.attachments,
                        sourcePrefix: "queued:\(message.id.uuidString)",
                        onOpenAttachment: onOpenAttachment,
                        onOpenSkill: onOpenSkill
                    )
                    .opacity(0.55)
                } else {
                    UserBubble(
                        text: message.text,
                        attachments: message.attachments,
                        sourcePrefix: "queued:\(message.id.uuidString)",
                        onOpenAttachment: onOpenAttachment
                    )
                    .environment(\.sendFlight, nil)
                    .opacity(0.55)
                }
            }
            Button {
                Haptics.impact(.queuedMessageCancelled)
                onCancel()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text("Queued", comment: "Tag on a conversation message the user sent while the agent was still working; it is delivered when the current turn finishes. Tapping cancels it.")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.conversationSecondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(L10n.string("Cancel queued message", comment: "Accessibility label for the button that cancels a message queued while the agent is working."))
        }
        .accessibilityElement(children: message.skillInvocation == nil ? .combine : .contain)
        .accessibilityIdentifier(A11yID.ConversationControls.Message.user)
    }
}

struct BlockView: View, Equatable {
    let block: ConversationBlock
    let isLatestCanvas: Bool
    let isStreamingTail: Bool
    let conversationID: UUID
    let browserPageMount: WebPageMountCoordinator
    let isThinkingTail: Bool
    var allowsLoader = true
    let controls: MessageControls
    let artifactControls: FileControls
    let onOpenAttachment: (FileItem, String) -> Void
    let onOpenSkill: (Skill) -> Void
    let onOpenLink: (URL) -> Void

    static func == (lhs: BlockView, rhs: BlockView) -> Bool {
        lhs.block == rhs.block
            && lhs.isLatestCanvas == rhs.isLatestCanvas
            && lhs.isStreamingTail == rhs.isStreamingTail
            && lhs.isThinkingTail == rhs.isThinkingTail
            && lhs.allowsLoader == rhs.allowsLoader
            && lhs.controls.isCopied == rhs.controls.isCopied
            && lhs.editMenuCanMutate == rhs.editMenuCanMutate
            && lhs.artifactControls.revision == rhs.artifactControls.revision
            && lhs.artifactControls.canMutate == rhs.artifactControls.canMutate
    }

    private var editMenuCanMutate: Bool? {
        if case .userText = block.kind { controls.canMutate } else { nil }
    }

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .userText(let s, let atts):
            userTextBubble(s, attachments: atts, createdAt: block.createdAt)
        case .userSkill(let invocation, let atts):
            userSkillBubble(invocation, attachments: atts, createdAt: block.createdAt)
        case .agentContent(let item):
            agentContentBubble([item])
        case let .thinking(trace):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ThinkingRow(
                    trace: trace,
                    sourceInvocations: block.sourceInvocations,
                    startedAt: block.createdAt,
                    isLive: isThinkingTail,
                    allowsLoader: allowsLoader
                )
                .padding(.horizontal, 4)
                ForEach(trace.invocations) { invocation in
                    if let row = ConversationScheduleRow(invocation: invocation) {
                        row
                    }
                }
            }
        case .contextCompaction:
            contextCompactionDivider
        case .startedConversation, .serviceControl, .responseFooter:
            EmptyView()
        }
    }

    private var contextCompactionDivider: some View {
        TranscriptStatusDivider(
            label: Text("Context compacted", comment: "Divider shown in a conversation where earlier model context was summarized."),
            systemImage: "arrow.down.right.and.arrow.up.left",
            accessibilityIdentifier: A11yID.ConversationControls.Message.contextCompaction
        )
    }

    private func userTextBubble(_ text: String, attachments: [FileItem], createdAt: Date) -> some View {
        HStack {
            Spacer(minLength: 40)
            UserBubble(
                text: text,
                attachments: attachments,
                sourcePrefix: "block:\(block.id.uuidString)",
                onOpenAttachment: onOpenAttachment
            )
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                .contextMenu {
                    Section(Self.timestampFormatter.string(from: createdAt)) {
                        Button {
                            controls.onCopy(text)
                        } label: {
                            Label(L10n.string("Copy", comment: "Context menu action on a sent message that copies its text to the clipboard."), systemImage: "doc.on.doc")
                        }
                        if controls.canMutate {
                            Button {
                                controls.onEdit()
                            } label: {
                                Label(L10n.string("Edit message", comment: "Context menu action on a sent message that loads its text back into the composer to edit and regenerate the reply."), systemImage: "pencil")
                            }
                        }
                    }
                } preview: {
                    MessageContextMenuPreview(
                        title: nil,
                        text: text,
                        attachments: attachments
                    )
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.ConversationControls.Message.user)
    }

    private func userSkillBubble(
        _ invocation: UserSkillInvocation,
        attachments: [FileItem],
        createdAt: Date
    ) -> some View {
        HStack {
            Spacer(minLength: 40)
            UserSkillBubble(
                invocation: invocation,
                attachments: attachments,
                sourcePrefix: "block:\(block.id.uuidString)",
                onOpenAttachment: onOpenAttachment,
                onOpenSkill: onOpenSkill
            )
            .contextMenuPreviewShape()
            .contextMenu {
                Section(Self.timestampFormatter.string(from: createdAt)) {
                    Button {
                        controls.onCopy(invocation.displayTitle)
                    } label: {
                        Label(L10n.string("Copy", comment: "Context menu action on a sent message that copies its text to the clipboard."), systemImage: "doc.on.doc")
                    }
                }
            } preview: {
                MessageContextMenuPreview(
                    title: invocation.skill.owner == .system ? invocation.displayTitle : "/\(invocation.skill.displayName)",
                    text: invocation.argument,
                    attachments: attachments
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @ViewBuilder
    private func agentContentBubble(_ items: [ContentItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    switch item {
                    case let .text(text), let .progress(text):
                        if !text.isEmpty {
                            agentText(text, index: index)
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .serviceControl:
                        EmptyView()
                    case let .serviceInspector(link):
                        ServiceInspectorRow(
                            link: link,
                            conversationID: conversationID,
                            rowID: block.id,
                            pageMount: browserPageMount
                        )
                            .padding(.horizontal, 4)
                    case let .shoveler(shoveler):
                        ShovelerView(
                            shoveler: shoveler,
                            accessibilityPrefix: A11yID.ConversationControls.Message.shoveler(block.id.uuidString),
                            onOpenFile: onOpenAttachment
                        )
                    case let .video(video):
                        VideoWidgetView(video: video)
                            .padding(.horizontal, 4)
                    case let .image(image):
                        ImageWidgetView(image: image)
                            .padding(.horizontal, 4)
                    case let .artifact(artifact):
                        if artifact.exists {
                            let sourceID = "block:\(block.id.uuidString):\(index):\(artifact.id)"
                            Group {
                                if artifact.kind == .html && isLatestCanvas {
                                    InlineCanvasCard(artifact: artifact, rowID: block.id)
                                } else {
                                    artifactRow(artifact, sourceID: sourceID)
                                }
                            }
                            .padding(.horizontal, 4)
                            .contextMenuPreviewShape()
                            .contextMenu {
                                FileContextMenu(artifact: artifact, canMutate: artifactControls.canMutate) {
                                    artifactControls.onRename(artifact)
                                } onDelete: {
                                    artifactControls.onDelete(artifact)
                                }
                            } preview: {
                                FileContextMenuPreview(artifact: artifact)
                            }
                        } else {
                            ConversationFileRow(artifact: artifact)
                                .padding(.horizontal, 4)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(String(
                                    format: L10n.string("Deleted file: %@"),
                                    artifact.userFacingName
                                ))
                                .accessibilityIdentifier(A11yID.ConversationControls.Message.artifact(artifact.id))
                        }
                    case let .skill(skill):
                        if skill.owner != .system {
                            ConversationSkillRow(
                                skill: skill,
                                accessibilityIdentifier: A11yID.ConversationControls.Message.skillResult(skill.id, blockID: block.id)
                            )
                        }
                    }
                }
            }
            .animation(Theme.Animation.standard, value: isStreamingTail)
        }
    }

    private func artifactRow(_ artifact: FileItem, sourceID: String) -> some View {
        Button { onOpenAttachment(artifact, sourceID) } label: {
            ConversationFileRow(artifact: artifact, previewSourceID: sourceID)
        }
        .buttonStyle(.plain)
        .modifier(ConversationInteractiveRowSurface())
        .accessibilityLabel(artifact.userFacingAccessibilityLabel)
        .accessibilityIdentifier(A11yID.ConversationControls.Message.artifact(artifact.id))
    }

    private func agentText(_ text: String, index: Int) -> some View {
        StreamingMarkdownText(source: text, accessibilityIdentifier: "message.\(block.id).item.\(index)", isStreaming: isStreamingTail)
            .environment(\.conversationLinkHandler, onOpenLink)
            .accessibilityIdentifier(A11yID.ConversationControls.Message.agent)
    }

}

struct ResponseFooterBlockView: View, Equatable {
    let id: UUID
    let text: String
    let isVisible: Bool
    let controls: MessageControls

    static func == (lhs: ResponseFooterBlockView, rhs: ResponseFooterBlockView) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.isVisible == rhs.isVisible
            && lhs.controls.isCopied == rhs.controls.isCopied
            && lhs.controls.canMutate == rhs.controls.canMutate
    }

    var body: some View {
        HStack(spacing: 1) {
            iconButton(
                systemName: controls.isCopied ? "checkmark" : "doc.on.doc",
                label: A11yLabel.copyMessage,
                id: actionIdentifier(A11yID.ConversationControls.Message.copy),
                disabled: controls.isCopied
            ) {
                controls.onCopy(text)
            }
            ShareLink(item: text) {
                controlIcon(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(A11yLabel.shareMessage)
            .accessibilityIdentifier(actionIdentifier(A11yID.ConversationControls.Message.share))
            if controls.canMutate {
                iconButton(
                    systemName: "arrow.branch",
                    label: A11yLabel.branchMessage,
                    id: actionIdentifier(A11yID.ConversationControls.Message.branch)
                ) {
                    controls.onBranch()
                }
                iconButton(
                    systemName: "arrow.clockwise",
                    label: A11yLabel.retryMessage,
                    id: actionIdentifier(A11yID.ConversationControls.Message.retry)
                ) {
                    controls.onRetry()
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }

    private func actionIdentifier(_ action: String) -> String {
        "\(action).\(id.uuidString)"
    }

    private func iconButton(
        systemName: String,
        label: String,
        id: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            controlIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func controlIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.Colors.conversationSecondary)
            .frame(width: 18, height: 28)
            .frame(width: 28, height: Theme.Size.minimumTouchTarget, alignment: .leading)
            .contentShape(Rectangle())
    }
}
