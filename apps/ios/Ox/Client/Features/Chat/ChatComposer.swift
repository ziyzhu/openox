import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PastedComposerImage {
    let data: Data
    let suggestedName: String
}

private struct ComposerTextViewInstaller: UIViewRepresentable {
    let textViewReference: ComposerTextViewReference
    let allowsSelection: Bool
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            textViewReference: textViewReference,
            onHeightChange: onHeightChange
        )
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.install = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.install(from: view)
        }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.allowsSelection = allowsSelection
        context.coordinator.installedTextView?.isSelectable = allowsSelection
        context.coordinator.installedTextView?.isEditable = allowsSelection
        context.coordinator.scheduleHeightUpdate()
        view.scheduleInstallation()
    }

    final class ProbeView: UIView {
        var install: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleInstallation()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleInstallation()
        }

        func scheduleInstallation() {
            DispatchQueue.main.async { [weak self] in self?.install?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextPasteDelegate {
        private let textViewReference: ComposerTextViewReference
        var onHeightChange: (CGFloat) -> Void
        weak var installedTextView: UITextView?
        var allowsSelection = true
        private var heightUpdateScheduled = false

        init(
            textViewReference: ComposerTextViewReference,
            onHeightChange: @escaping (CGFloat) -> Void
        ) {
            self.textViewReference = textViewReference
            self.onHeightChange = onHeightChange
        }

        func install(from probe: UIView) {
            guard let window = probe.window else { return }
            let targetFrame = probe.convert(probe.bounds, to: window)
            let textView = textViews(in: window)
                .filter { !$0.isHidden && $0.alpha > 0 }
                .min { frameDistance($0.convert($0.bounds, to: window), targetFrame)
                    < frameDistance($1.convert($1.bounds, to: window), targetFrame) }
            guard let textView,
                  frameDistance(textView.convert(textView.bounds, to: window), targetFrame) < 2 else { return }
            if installedTextView !== textView {
                if let installedTextView {
                    installedTextView.pasteDelegate = nil
                    NotificationCenter.default.removeObserver(
                        self,
                        name: UITextView.textDidChangeNotification,
                        object: installedTextView
                    )
                }
                installedTextView = textView
                textViewReference.textView = textView
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(textDidChange),
                    name: UITextView.textDidChangeNotification,
                    object: textView
                )
            }
            textView.pasteDelegate = self
            textView.isSelectable = allowsSelection
            textView.isEditable = allowsSelection
            scheduleHeightUpdate()
        }

        func scheduleHeightUpdate() {
            guard !heightUpdateScheduled else { return }
            heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                heightUpdateScheduled = false
                updateHeight()
            }
        }

        @objc private func textDidChange(_: Notification) {
            scheduleHeightUpdate()
        }

        private func updateHeight() {
            guard let textView = installedTextView,
                  textView.bounds.width > 0 else { return }
            let fittedHeight = textView.sizeThatFits(CGSize(
                width: textView.bounds.width,
                height: .greatestFiniteMagnitude
            )).height
            let lineHeight = textView.font?.lineHeight ?? 22
            let textInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
            let minimumHeight = max(40, lineHeight + textInsets)
            let maximumHeight = minimumHeight + lineHeight * 5
            let clampedHeight = min(max(fittedHeight, minimumHeight), maximumHeight)
            let scale = textView.window?.screen.scale ?? 1
            onHeightChange(ceil(clampedHeight * scale) / scale)
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            combineItemAttributedStrings itemStrings: [NSAttributedString],
            for textRange: UITextRange
        ) -> NSAttributedString {
            guard !UIPasteboard.general.hasImages else {
                let combined = NSMutableAttributedString()
                itemStrings.forEach(combined.append)
                return combined
            }
            return NSAttributedString(string: itemStrings.map(\.string).joined())
        }

        private func textViews(in view: UIView) -> [UITextView] {
            let current = (view as? UITextView).map { [$0] } ?? []
            return current + view.subviews.flatMap(textViews)
        }

        private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
            abs(lhs.midX - rhs.midX)
                + abs(lhs.midY - rhs.midY)
                + abs(lhs.width - rhs.width)
        }
    }
}

@MainActor
private final class ComposerTextViewReference {
    weak var textView: UITextView?

    var hasMarkedText: Bool {
        textView?.markedTextRange != nil
    }
}

struct ChatComposer: View, Equatable {
    static let surfaceSpacing = Theme.Spacing.md
    static let restingVerticalOffset = Theme.Spacing.md
    private static let topStripSurfaceInset = max(
        0,
        (Theme.Size.minimumTouchTarget - Theme.Size.chipHeight) / 2
    )
    private static let topStripSpacing = surfaceSpacing - topStripSurfaceInset
    static let floatingTopStripClearance = Theme.Size.minimumTouchTarget + topStripSpacing

    static func firstSurfaceTopOffset(
        isResting: Bool,
        showsTopStrip: Bool,
        floatsTopStrip: Bool
    ) -> CGFloat {
        let restingOffset = isResting ? restingVerticalOffset : 0
        let surfaceTouchInset = showsTopStrip ? topStripSurfaceInset : 0
        let floatingOffset = floatsTopStrip ? -floatingTopStripClearance : 0
        return Theme.Spacing.sm + restingOffset + surfaceTouchInset + floatingOffset
    }

    private enum ComposerIntent: Identifiable {
        case suggested(FollowIntent)
        case importMemory

        var id: String {
            switch self {
            case .suggested(let intent): "suggested:\(intent.id)"
            case .importMemory: "importMemory"
            }
        }
    }

    private struct ImportMemoryOpportunity: Equatable {
        let sessionID: UUID
        let isEligible: Bool
    }

    @Bindable var composer: ChatComposerModel
    let isEditingMessage: Bool
    @Binding var editDraft: AttributedString
    let speech: ChatSpeechInput
    let attachedServices: [Service]
    let chatArtifacts: [Artifact]
    let fieldFocused: FocusState<Bool>.Binding
    let isFieldFocused: Bool
    let sessionID: UUID
    let isChatEmpty: Bool
    let isTemporary: Bool
    let isBusy: Bool
    let followIntents: [FollowIntent]
    let floatsTopStrip: Bool
    let isEmbedded: Bool
    let iconButtonSize: CGFloat
    let composerButtonSize: CGFloat
    let onOpenAttachment: (Artifact, String) -> Void
    let onOpenChatArtifact: (Artifact) -> Void
    let onPasteImages: ([PastedComposerImage]) -> Void
    let onOpenService: (Service) -> Void
    let onRemoveService: (Service) -> Void
    let onAttachmentChoice: (AttachmentChoice) -> Void
    let onServices: () -> Void
    let onSubmitSkill: (Skill, String) -> Void
    let onPreparationIntent: (Bool) -> Void
    let onCancelEdit: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onSpeechBegin: (Bool) -> Void

    private let textLineFragmentPadding: CGFloat = 5
    private let textEditorVerticalInset: CGFloat = 9
    private let textEditorOpticalOffset: CGFloat = 1

    @State private var containerWidth: CGFloat = 0
    @State private var composerTextEditorHeight: CGFloat = 40
    @State private var composerSelection = AttributedTextSelection()
    @State private var textViewReference = ComposerTextViewReference()
    @State private var hasShownImportMemory = false
    @AppStorage("chat.importMemoryIntentDisplays") private var importMemoryIntentDisplays = 0

    @Environment(\.appTheme) private var appTheme

    static func == (lhs: ChatComposer, rhs: ChatComposer) -> Bool {
        lhs.composer === rhs.composer
            && lhs.speech === rhs.speech
            && lhs.isEditingMessage == rhs.isEditingMessage
            && lhs.editDraft == rhs.editDraft
            && lhs.attachedServices.map(\.domain) == rhs.attachedServices.map(\.domain)
            && lhs.chatArtifacts == rhs.chatArtifacts
            && lhs.isFieldFocused == rhs.isFieldFocused
            && lhs.sessionID == rhs.sessionID
            && lhs.isChatEmpty == rhs.isChatEmpty
            && lhs.isTemporary == rhs.isTemporary
            && lhs.isBusy == rhs.isBusy
            && lhs.followIntents == rhs.followIntents
            && lhs.floatsTopStrip == rhs.floatsTopStrip
            && lhs.isEmbedded == rhs.isEmbedded
            && lhs.iconButtonSize == rhs.iconButtonSize
            && lhs.composerButtonSize == rhs.composerButtonSize
    }

    private var empty: Bool {
        isEditingMessage ? inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : composer.isEmpty
    }

    private var canSubmit: Bool {
        isEditingMessage ? !empty : composer.canSubmit
    }

    private var inputText: String {
        isEditingMessage ? String(editDraft.characters) : composer.draft
    }

    private var inputAccessibilityValue: Text {
        if !inputText.isEmpty { return Text(verbatim: inputText) }
        if isEditingMessage { return Text("Edit message") }
        return Text("Type a message")
    }

    private var trailingControlSize: CGFloat {
        max(composerButtonSize + 10, Theme.Size.minimumTouchTarget)
    }

    private var trailingControlsWidth: CGFloat {
        canSubmit || composer.isImporting || isBusy || composer.isEmpty
            ? trailingControlSize + 2
            : Theme.Spacing.lg
    }

    var body: some View {
        inputBar
            .excludesCompactPageSwitch(includingAreaBelow: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                DispatchQueue.main.async {
                    guard abs(containerWidth - width) > 0.5 else { return }
                    containerWidth = width
                }
            }
            .onChange(of: canSubmit, initial: true) { _, canSubmit in
                onPreparationIntent(canSubmit)
            }
            .onChange(of: composer.draft) { previous, current in
                guard previous.first != "/", current.first == "/" else { return }
                Skills.shared.refresh()
            }
            .onChange(of: importMemoryOpportunity, initial: true) { previous, opportunity in
                if previous.sessionID != opportunity.sessionID { hasShownImportMemory = false }
                guard opportunity.isEligible, !hasShownImportMemory, importMemoryIntentDisplays < 3 else { return }
                hasShownImportMemory = true
                importMemoryIntentDisplays += 1
                Log.ui.info("ChatComposer.importMemoryIntent shown chat=\(sessionID) display=\(importMemoryIntentDisplays)")
            }
            .onDisappear { hasShownImportMemory = false }
    }

    @ViewBuilder
    private var draftAttachmentStrip: some View {
        if !composer.draftAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(composer.draftAttachments) { item in
                        switch item {
                        case .importing(let pending):
                            PendingAttachmentChip(pending: pending) {
                                composer.removeDraftAttachment(item)
                            }
                        case .ready(let attachment):
                            let sourceID = "composer:\(sessionID.uuidString):\(composer.draftID.uuidString):\(attachment.id)"
                            DraftAttachmentChip(
                                attachment: attachment,
                                sourceID: sourceID,
                                onOpen: { onOpenAttachment(attachment, sourceID) }
                            ) {
                                composer.removeDraftAttachment(item)
                            }
                        }
                    }
                }
                .padding(.leading, Theme.Spacing.sm)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, draftAttachmentBottomPadding)
            }
            .excludesCompactPageSwitch()
            .overlay { chipRowEdgeGlow }
        }
    }

    private var draftAttachmentBottomPadding: CGFloat {
        6
    }

    private var chipRowEdgeGlow: some View {
        HStack(spacing: 0) {
            chipRowEdgeGradient
            Spacer(minLength: 0)
            chipRowEdgeGradient
                .scaleEffect(x: -1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var chipRowEdgeGradient: some View {
        LinearGradient(
            colors: [
                Theme.Colors.chatSurface.color(for: appTheme).opacity(0.8),
                Theme.Colors.chatSurface.color(for: appTheme).opacity(0.25),
                Theme.Colors.chatSurface.color(for: appTheme).opacity(0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: Theme.Spacing.md)
        .blur(radius: 1)
    }

    @ViewBuilder
    private var composerDraftStrip: some View {
        if !isEditingMessage, !composer.draftAttachments.isEmpty {
            draftAttachmentStrip
        }
    }

    private enum LayoutState {
        case resting
        case active
    }

    private var layoutState: LayoutState {
        isEmbedded || isFieldFocused || !empty ? .active : .resting
    }

    private var isResting: Bool {
        layoutState == .resting
    }

    private var centersComposer: Bool {
        isResting
    }

    private var restingWidth: CGFloat {
        containerWidth > 0 ? containerWidth * 0.84 : 330
    }

    private var horizontalSpacing: CGFloat {
        isResting ? Theme.Spacing.sm : Theme.Spacing.md
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if centersComposer {
                Spacer(minLength: 0)
            }

            composerCluster
                .frame(maxWidth: centersComposer ? restingWidth : .infinity, alignment: .leading)
                .offset(y: isResting ? Self.restingVerticalOffset : 0)

            if centersComposer {
                Spacer(minLength: 0)
            }

        }
        .padding(.horizontal, horizontalSpacing)
        .padding(.top, inputBarTopSpacing)
        .padding(.bottom, Theme.Spacing.sm)
        .background(alignment: .bottom) {
            if appTheme == .creatorPick && isFieldFocused {
                LinearGradient(
                    colors: [
                        Theme.Colors.chatSurface.color(for: .creatorPick).opacity(0),
                        Color(uiColor: .systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Theme.Spacing.lg)
            }
        }
        .animation(Theme.Animation.standard, value: isResting)
    }

    private var inputBarTopSpacing: CGFloat {
        guard isEmbedded else { return Theme.Spacing.sm }
        return showsTopStrip ? Self.topStripSpacing : Self.surfaceSpacing
    }

    private var composerCluster: some View {
        VStack(alignment: .leading, spacing: Self.topStripSpacing) {
            if showsTopStrip && !floatsTopStrip {
                composerTopStrip
                    .transition(topStripTransition)
            }

            VStack(alignment: .leading, spacing: 0) {
                composerDraftStrip
                followIntentStrip
                composerRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(composerShape)
            .background {
                Color.clear
                    .glassEffect(.regular, in: composerShape)
                    .id(appTheme)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsTopStrip && floatsTopStrip {
                composerTopStrip
                    .offset(y: -Self.floatingTopStripClearance)
                    .transition(topStripTransition)
            }
        }
    }

    private var composerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
    }

    private var topStripTransition: AnyTransition {
        .scale(scale: 0.8).combined(with: .opacity)
    }

    private var showsTopStrip: Bool {
        isEditingMessage || !chatArtifacts.isEmpty || !attachedServices.isEmpty
    }

    private var showsFollowIntents: Bool {
        !isEditingMessage
            && composer.draft.isEmpty
            && composer.draftAttachments.isEmpty
            && (!followIntents.isEmpty || showsImportMemoryIntent)
    }

    private var showsDefaultIntents: Bool {
        followIntents.isEmpty
            && !isEditingMessage
            && composer.draft.isEmpty
            && composer.draftAttachments.isEmpty
            && isChatEmpty
            && !isBusy
            && attachedServices.isEmpty
            && chatArtifacts.isEmpty
    }

    private var importMemoryOpportunity: ImportMemoryOpportunity {
        ImportMemoryOpportunity(sessionID: sessionID, isEligible: showsDefaultIntents && !isTemporary)
    }

    private var showsImportMemoryIntent: Bool {
        importMemoryOpportunity.isEligible
            && (hasShownImportMemory || importMemoryIntentDisplays < 3)
    }

    private var visibleFollowIntents: [ComposerIntent] {
        if !followIntents.isEmpty { return followIntents.map(ComposerIntent.suggested) }
        return showsImportMemoryIntent ? [.importMemory] : []
    }

    @ViewBuilder
    private var followIntentStrip: some View {
        if showsFollowIntents {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(visibleFollowIntents) { intent in
                        followIntentButton(intent)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
            }
            .excludesCompactPageSwitch()
        }
    }

    private func followIntentButton(_ intent: ComposerIntent) -> some View {
        Button {
            switch intent {
            case .suggested(let suggestion):
                let message = suggestion.message
                composer.draft = message
                Log.ui.info("ChatComposer.followIntent send chat=\(sessionID) chars=\(message.count)")
                submit()
            case .importMemory:
                guard let skill = BuiltInSkills.skills.first(where: { $0.name == "import-memory" }) else {
                    Log.ui.error("ChatComposer.importMemoryIntent missingSkill chat=\(sessionID)")
                    return
                }
                onSubmitSkill(skill, "")
            }
        } label: {
            followIntentTitle(intent)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: Theme.Size.chipHeight)
                .overlay {
                    Capsule().strokeBorder(Theme.Colors.onSurfaceMuted.opacity(0.4), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .minimumTouchTarget()
        .accessibilityIdentifier(followIntentIdentifier(intent))
    }

    private func followIntentTitle(_ intent: ComposerIntent) -> Text {
        switch intent {
        case .suggested(let suggestion):
            Text(verbatim: suggestion.label)
        case .importMemory: Text("Import memory to Ox")
        }
    }

    private func followIntentIdentifier(_ intent: ComposerIntent) -> String {
        switch intent {
        case .suggested: A11yID.Chat.followIntent
        case .importMemory: A11yID.Chat.importMemory
        }
    }

    private var artifactAccessibilityLabel: String {
        chatArtifacts.count == 1 ? "1 artifact" : "\(chatArtifacts.count) artifacts"
    }

    private var artifactButton: some View {
        Menu {
            ForEach(chatArtifacts) { artifact in
                Button {
                    Haptics.impact(.artifactTabSelected)
                    Log.ui.info("ChatComposer.artifactSelect chat=\(sessionID) filename=\(artifact.fileName)")
                    onOpenChatArtifact(artifact)
                } label: {
                    Label(
                        artifact.userFacingName,
                        systemImage: artifactSystemImage(artifact)
                    )
                }
                .accessibilityIdentifier(A11yID.Chat.Artifact.item(artifact.id))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: OxActionIconKind.artifacts.systemImage)
                Text("Artifacts")
                Text(verbatim: "· \(chatArtifacts.count)")
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(Theme.Colors.onSurface)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.chipHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .minimumTouchTarget()
        .accessibilityLabel(Text(verbatim: artifactAccessibilityLabel))
        .accessibilityIdentifier(A11yID.Chat.Artifact.open)
    }

    private func artifactSystemImage(_ artifact: Artifact) -> String {
        switch artifact.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .html: "sparkles.rectangle.stack"
        case .file: "doc"
        }
    }

    private var composerTopStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    if !chatArtifacts.isEmpty {
                        artifactButton
                    }
                    ForEach(attachedServices) { attachedServicePill($0) }
                    if isEditingMessage {
                        editingMessageChip
                    }
                }
            }
        }
        .scrollClipDisabled()
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .excludesCompactPageSwitch(includingAreaBelow: true)
    }

    private var editingMessageChip: some View {
        Button {
            Haptics.impact(.selectionConfirmed)
            onCancelEdit()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                Text("Editing message", comment: "Composer status shown while a previously sent message is being edited.")
                Image(systemName: "xmark")
                    .padding(.leading, 2)
            }
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(Theme.Colors.onSurface)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.chipHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .minimumTouchTarget()
        .accessibilityLabel(L10n.string("Cancel editing", comment: "Accessibility label for the button that cancels editing a sent message."))
        .accessibilityIdentifier(A11yID.Chat.cancelEdit)
    }

    private var composerRow: some View {
        ZStack(alignment: .leading) {
            if inputText.isEmpty {
                Group {
                    if isEditingMessage {
                        Text("Edit message", comment: "Placeholder shown while editing a previously sent message.")
                    } else {
                        Text("Type a message")
                    }
                }
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.leading, textLineFragmentPadding)
                    .transition(.identity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: attributedDraft, selection: $composerSelection)
                .id(composer.draftID)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(0, for: .scrollContent)
                .frame(height: composerTextEditorHeight)
                .padding(.top, -textEditorVerticalInset + textEditorOpticalOffset)
                .padding(.bottom, -textEditorVerticalInset - textEditorOpticalOffset)
                .focused(fieldFocused)
                .accessibilityIdentifier(A11yID.Chat.input)
                .accessibilityValue(inputAccessibilityValue)
                .accessibilityHint("Tap to type.")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .tint(Theme.Colors.primary.dynamic)
                .background(ComposerTextViewInstaller(
                    textViewReference: textViewReference,
                    allowsSelection: !speech.isPresented
                ) { height in
                    guard abs(composerTextEditorHeight - height) > 0.5 else { return }
                    composerTextEditorHeight = height
                })
                .onChange(of: composer.caretEndRequest) { _, _ in
                    composerSelection = AttributedTextSelection(insertionPoint: composer.attributedDraft.endIndex)
                }
        }
        .padding(.vertical, 12)
        .excludesCompactPageSwitch()
        .padding(.leading, iconButtonSize - textLineFragmentPadding)
        .padding(.trailing, trailingControlsWidth)
        .overlay(alignment: .bottomLeading) {
            attachButton
                .padding(.bottom, 1)
        }
        .overlay(alignment: .bottomTrailing) {
            trailingControl
                .padding(.bottom, 1)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isEditingMessage, canSubmit {
            composerButton(systemName: "arrow.up", label: A11yLabel.send, id: A11yID.Chat.send, action: submit)
        } else if isEditingMessage {
            EmptyView()
        } else if composer.isImporting, isBusy {
            composerButton(systemName: "stop.fill", label: A11yLabel.stop, id: A11yID.Chat.stop, event: .stop, action: onStop)
        } else if composer.isImporting {
            CellularAutomatonLoader.small
                .frame(width: composerButtonSize, height: composerButtonSize)
                .padding(.trailing, 6)
                .padding(.vertical, 5)
                .accessibilityLabel("Attaching")
        } else if composer.canSubmit {
            composerButton(systemName: "arrow.up", label: A11yLabel.send, id: A11yID.Chat.send, action: submit)
        } else if isBusy, !composer.suppressesStopControl {
            composerButton(systemName: "stop.fill", label: A11yLabel.stop, id: A11yID.Chat.stop, event: .stop, action: onStop)
        } else if composer.isEmpty {
            speechControl
        }
    }

    private var speechControl: some View {
        Image(systemName: "mic.fill")
            .font(.system(.subheadline, weight: .bold))
            .foregroundStyle(Theme.Colors.onSurface)
            .frame(width: composerButtonSize, height: composerButtonSize)
            .padding(.leading, 4)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .minimumTouchTarget()
            .contentShape(Circle())
            .overlay {
                HoldToTalkArea(
                    canBegin: !composer.isImporting && !speech.isPresented,
                    onTap: showHoldToTalkHint,
                    onBegin: { onSpeechBegin(false) },
                    onMove: { speech.move(to: $0, distance: $1) },
                    onRelease: { speech.release() },
                    onCancel: { speech.interrupt() }
                )
                .accessibilityHidden(true)
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Hold to talk")
            .accessibilityHint("Press and hold to talk.")
            .accessibilityIdentifier(A11yID.Chat.speechHold)
            .accessibilityAction { onSpeechBegin(true) }
    }

    private func showHoldToTalkHint() {
        Haptics.impact(.selectionConfirmed)
        speech.notice = L10n.string(
            "Press and hold to talk.",
            comment: "Hint shown when the user taps instead of holding the microphone button."
        )
        Log.ui.info("ChatComposer.speechHint chat=\(sessionID)")
    }

    private func setMenu(_ visible: Bool) {
        Log.ui.info("ChatComposer.attachMenu chat=\(sessionID) visible=\(visible)")
        composer.setAttachmentMenuPresented(visible)
    }

    private var attachmentMenuPresented: Binding<Bool> {
        Binding(
            get: { composer.surface == .attachments },
            set: setMenu
        )
    }

    private var attachButton: some View {
        Button {
            guard !isEditingMessage else { return }
            Haptics.impact(.attachmentMenu)
            setMenu(composer.surface != .attachments)
        } label: {
            Image(systemName: "plus")
                .font(.system(.title3, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: iconButtonSize, height: iconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isEditingMessage)
        .accessibilityLabel(A11yLabel.addAttachment)
        .accessibilityIdentifier(A11yID.Chat.attach)
        .popover(
            isPresented: attachmentMenuPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            ComposerAttachMenu(
                onChoice: { choice in
                    setMenu(false)
                    DispatchQueue.main.async { onAttachmentChoice(choice) }
                },
                onServices: {
                    setMenu(false)
                    DispatchQueue.main.async(execute: onServices)
                }
            )
            .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
            .presentationSizing(.fitted)
        }
    }

    private func attachedServicePill(_ picked: Service) -> some View {
        ServiceChip(
            service: picked,
            title: picked.title,
            onOpen: { onOpenService(picked) },
            showsAuthStatus: true,
            onRemove: {
                Log.ui.info("ChatComposer.detachService domain=\(picked.domain)")
                onRemoveService(picked)
            },
            fill: Theme.Colors.chipOnBackground,
            surfaceOpacity: 0
        )
        .glassEffect(.regular.interactive(), in: Capsule())
        .minimumTouchTarget()
    }

    private func composerButton(
        systemName: String,
        label: String,
        id: String,
        event: Haptics.Event? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if let event { Haptics.impact(event) }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(Theme.Colors.onPrimary)
                .frame(width: composerButtonSize, height: composerButtonSize)
                .background(Theme.Colors.primary, in: Circle())
                .padding(.leading, 4)
                .padding(.trailing, 6)
                .padding(.vertical, 5)
                .minimumTouchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func submit() {
        if isEditingMessage {
            onSend()
            return
        }
        guard let invocation = composer.slashInvocation else {
            composer.delayStopControl()
            onSend()
            return
        }
        onSubmitSkill(invocation.skill, invocation.argument)
    }

    private var attributedDraft: Binding<AttributedString> {
        if isEditingMessage {
            return Binding(
                get: { editDraft },
                set: { value in
                    if textViewReference.hasMarkedText {
                        editDraft = value
                        return
                    }
                    let text = String(value.characters).replacingOccurrences(of: "\u{FFFC}", with: "")
                    editDraft = AttributedString(text)
                }
            )
        }
        let draftID = composer.draftID
        return Binding(
            get: { composer.attributedDraft },
            set: { value in
                guard composer.draftID == draftID else {
                    Log.ui.info("ChatComposer.draftWrite stale chat=\(sessionID) draft=\(draftID) current=\(composer.draftID) chars=\(value.characters.count)")
                    return
                }
                if textViewReference.hasMarkedText {
                    composer.attributedDraft = value
                    return
                }
                let pastedImages = pastedImages(in: value)
                let bridgedDraft = NSAttributedString(value)
                let mutableDraft = NSMutableAttributedString(attributedString: bridgedDraft)
                var embeddedRanges: [NSRange] = []
                bridgedDraft.enumerateAttributes(
                    in: NSRange(location: 0, length: bridgedDraft.length)
                ) { attributes, range, _ in
                    if attributes[.attachment] != nil || attributes[.adaptiveImageGlyph] != nil {
                        embeddedRanges.append(range)
                    }
                }
                for range in embeddedRanges.reversed() {
                    mutableDraft.deleteCharacters(in: range)
                }
                while true {
                    let range = mutableDraft.mutableString.range(of: "\u{FFFC}")
                    guard range.location != NSNotFound else { break }
                    mutableDraft.deleteCharacters(in: range)
                }
                let filteredDraft = AttributedString(mutableDraft)
                let text = String(filteredDraft.characters)
                var draft = filteredDraft
                if composer.draft.first == "/" || text.first == "/" {
                    draft.foregroundColor = nil
                    if let invocation = composer.slashInvocation(in: text),
                       let range = draft.range(of: invocation.command) {
                        draft[range].foregroundColor = Theme.Colors.primary.dynamic
                    }
                }
                composer.attributedDraft = draft
                if !pastedImages.isEmpty {
                    Log.ui.info("ChatComposer.paste chat=\(sessionID) images=\(pastedImages.count)")
                    onPasteImages(pastedImages)
                }
            }
        )
    }

    private func pastedImages(in value: AttributedString) -> [PastedComposerImage] {
        let attributed = NSAttributedString(value)
        var images: [(Data, String?)] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, _, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                let original = attachment.contents ?? attachment.fileWrapper?.regularFileContents
                if let data = attachment.image?.pngData() ?? original,
                   UIImage(data: data) != nil {
                    images.append((data, attachment.fileWrapper?.preferredFilename))
                }
            } else if let glyph = attributes[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
                let data = glyph.imageContent
                if UIImage(data: data) != nil {
                    let suffix = NSAdaptiveImageGlyph.contentType.preferredFilenameExtension ?? "heic"
                    images.append((data, "Pasted Image.\(suffix)"))
                }
            }
        }
        let resolved = if images.isEmpty, value.characters.contains("\u{FFFC}") {
            (UIPasteboard.general.images ?? []).compactMap { image in
                image.pngData().map { ($0, nil as String?) }
            }
        } else {
            images
        }
        guard !resolved.isEmpty,
              composer.claimPasteboardChange(UIPasteboard.general.changeCount) else { return [] }
        return resolved.enumerated().map { index, image in
            let fallback = resolved.count == 1 ? "Pasted Image.png" : "Pasted Image \(index + 1).png"
            return PastedComposerImage(data: image.0, suggestedName: image.1 ?? fallback)
        }
    }

}

private struct DraftAttachmentChip: View {
    let attachment: Artifact
    let sourceID: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ComposerAttachmentChip(
            name: attachment.userFacingName,
            accessibilityLabel: attachment.userFacingAccessibilityLabel,
            accessibilityIdentifier: A11yID.Chat.composerAttachment(attachment.id),
            onOpen: onOpen,
            onRemove: onRemove
        ) {
            ArtifactThumbnail(
                attachment: attachment,
                style: .composer,
                previewSourceID: sourceID
            )
        }
    }
}

private struct PendingAttachmentChip: View {
    let pending: ChatComposerModel.PendingAttachment
    let onRemove: () -> Void

    private var userFacingName: String { Artifact.userFacingName(forFileName: pending.displayName) }

    var body: some View {
        ComposerAttachmentChip(
            name: userFacingName,
            accessibilityLabel: "Attaching \(userFacingName)",
            accessibilityIdentifier: A11yID.Chat.composerAttachment(pending.displayName),
            onRemove: onRemove
        ) {
            CellularAutomatonLoader.small
                .frame(width: 28, height: 28)
                .background(Theme.Colors.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct ComposerAttachmentChip<Preview: View>: View {
    let name: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    var onOpen: (() -> Void)? = nil
    let onRemove: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        ZStack(alignment: .trailing) {
            if let onOpen {
                Button(action: onOpen) { label }
                    .buttonStyle(OxPressedSurfaceButtonStyle())
            } else {
                label
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted, Theme.Colors.surface)
                    .frame(
                        width: Theme.Size.minimumTouchTarget,
                        height: Theme.Size.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(A11yLabel.remove(name))
            .accessibilityIdentifier("\(accessibilityIdentifier).remove")
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            preview()
            Text(name)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, Theme.Size.minimumTouchTarget)
        .frame(
            minWidth: 120,
            maxWidth: 240,
            minHeight: Theme.Size.minimumTouchTarget,
            alignment: .leading
        )
        .background(
            Theme.Colors.surfaceSunken,
            in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
