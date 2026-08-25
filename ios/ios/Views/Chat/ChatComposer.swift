import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PastedComposerImage {
    let data: Data
    let suggestedName: String
}

private struct ComposerPasteDelegateInstaller: UIViewRepresentable {
    let textViewReference: ComposerTextViewReference

    func makeCoordinator() -> Coordinator {
        Coordinator(textViewReference: textViewReference)
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
        weak var installedTextView: UITextView?

        init(textViewReference: ComposerTextViewReference) {
            self.textViewReference = textViewReference
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
                installedTextView?.pasteDelegate = nil
                installedTextView = textView
                textViewReference.textView = textView
            }
            textView.pasteDelegate = self
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

@MainActor
@Observable
final class ChatComposerModel {
    struct SlashInvocation {
        let skill: Skill
        let command: String
        let argument: String
    }

    enum Surface: Equatable {
        case none
        case attachments
        case mention(String)
        case slash(String)
    }

    struct Message {
        let id: UUID
        let text: String
        let attachments: [Artifact]
    }

    struct PendingAttachment: Identifiable, Equatable {
        let id: UUID
        let displayName: String
    }

    enum DraftAttachment: Identifiable, Equatable {
        enum ID: Hashable {
            case operation(UUID)
            case artifact(String)
        }

        case importing(PendingAttachment)
        case ready(Artifact)

        var id: ID {
            switch self {
            case .importing(let pending): .operation(pending.id)
            case .ready(let artifact): .artifact(artifact.id)
            }
        }
    }

    var attributedDraft = AttributedString()
    private(set) var draftAttachments: [DraftAttachment] = []
    private(set) var draftID = UUID()
    private(set) var caretEndRequest = 0
    private var attachmentMenuPresented = false
    private var stopControlTransition: UUID?
    private var activePasteboardChangeCount: Int?
    @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]

    deinit {
        for task in importTasks.values {
            task.cancel()
        }
    }

    var draft: String {
        get { String(attributedDraft.characters) }
        set { attributedDraft = AttributedString(newValue) }
    }

    var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftAttachments.isEmpty
    }

    var canSubmit: Bool {
        !draftAttachments.contains { if case .ready = $0 { false } else { true } }
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    var isImporting: Bool {
        draftAttachments.contains { if case .importing = $0 { true } else { false } }
    }

    var suppressesStopControl: Bool {
        stopControlTransition != nil
    }

    var slashSuggestions: [Skill] {
        guard case .slash(let query) = surface else { return [] }
        let needle = query.lowercased()
        return Skills.shared.all.filter {
            needle.isEmpty || $0.name.lowercased().contains(needle)
        }
    }

    var slashInvocation: SlashInvocation? {
        slashInvocation(in: draft)
    }

    var surface: Surface {
        if attachmentMenuPresented { return .attachments }
        if let mention = activeMention { return .mention(mention) }
        if let slash = activeSlash { return .slash(slash) }
        return .none
    }

    private var activeMention: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let token = draft[draft.index(after: at)...]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }

    private var activeSlash: String? {
        guard draft.first == "/" else { return nil }
        let token = draft.dropFirst()
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }

    func startMention() {
        attachmentMenuPresented = false
        if activeMention == nil {
            draft += draft.isEmpty || draft.last?.isWhitespace == true ? "@" : " @"
        }
        caretEndRequest += 1
    }

    func finishMention() {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at])
    }

    func slashInvocation(in draft: String) -> SlashInvocation? {
        guard draft.first == "/" else { return nil }
        let commandEnd = draft.firstIndex(where: \.isWhitespace) ?? draft.endIndex
        let nameStart = draft.index(after: draft.startIndex)
        let name = String(draft[nameStart..<commandEnd])
        guard let skill = Skills.shared.all.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        return SlashInvocation(
            skill: skill,
            command: String(draft[..<commandEnd]),
            argument: String(draft[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func delayStopControl() {
        let transition = UUID()
        stopControlTransition = transition
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard self?.stopControlTransition == transition else { return }
            self?.stopControlTransition = nil
        }
    }

    func takeMessage() -> Message? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return nil }
        let attachments = draftAttachments.compactMap { item -> Artifact? in
            if case .ready(let artifact) = item { artifact } else { nil }
        }
        let message = Message(id: draftID, text: text, attachments: attachments)
        draft = ""
        draftAttachments = []
        attachmentMenuPresented = false
        draftID = UUID()
        return message
    }

    func setAttachmentMenuPresented(_ presented: Bool) {
        attachmentMenuPresented = presented
    }

    func claimPasteboardChange(_ changeCount: Int) -> Bool {
        guard activePasteboardChangeCount != changeCount else { return false }
        activePasteboardChangeCount = changeCount
        DispatchQueue.main.async { [weak self] in
            guard self?.activePasteboardChangeCount == changeCount else { return }
            self?.activePasteboardChangeCount = nil
        }
        return true
    }

    func importAttachment(
        named displayName: String,
        operation: @escaping @MainActor () async throws -> Artifact,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let pending = PendingAttachment(id: UUID(), displayName: displayName)
        let importingDraftID = draftID
        draftAttachments.append(.importing(pending))
        Log.ui.info("ChatComposer.import begin draft=\(importingDraftID) import=\(pending.id) name=\(displayName)")
        importTasks[pending.id] = Task { [weak self] in
            do {
                let artifact = try await operation()
                guard !Task.isCancelled else { return }
                self?.finishImport(pending.id, draftID: importingDraftID, artifact: artifact)
            } catch is CancellationError {
                self?.cancelImport(pending.id, draftID: importingDraftID)
            } catch {
                guard let self else { return }
                self.failImport(pending.id, draftID: importingDraftID, error: error)
                onFailure(error)
            }
        }
    }

    func attachArtifact(_ artifact: Artifact) {
        guard !draftAttachments.contains(where: { $0.id == .artifact(artifact.id) }) else {
            Log.ui.info("ChatComposer.attachment duplicate draft=\(draftID) artifact=\(artifact.id)")
            return
        }
        draftAttachments.append(.ready(artifact))
        Log.ui.info("ChatComposer.attachment artifact draft=\(draftID) artifact=\(artifact.id)")
    }

    var draftArtifactIDs: Set<String> {
        Set(draftAttachments.compactMap { item in
            if case .artifact(let id) = item.id { id } else { nil }
        })
    }

    func removeDraftAttachment(_ item: DraftAttachment) {
        draftAttachments.removeAll { $0.id == item.id }
        if case .operation(let id) = item.id { importTasks.removeValue(forKey: id)?.cancel() }
        Log.ui.info("ChatComposer.attachment remove draft=\(draftID) item=\(item.id)")
    }

    private func finishImport(_ id: UUID, draftID importingDraftID: UUID, artifact: Artifact) {
        importTasks.removeValue(forKey: id)
        guard draftID == importingDraftID else {
            draftAttachments.removeAll { $0.id == .operation(id) }
            Log.ui.info("ChatComposer.import stale draft=\(importingDraftID) current=\(draftID) import=\(id)")
            return
        }
        guard let index = draftAttachments.firstIndex(where: { $0.id == .operation(id) }) else { return }
        draftAttachments[index] = .ready(artifact)
        Log.ui.info("ChatComposer.import ready draft=\(draftID) import=\(id) artifact=\(artifact.id)")
    }

    private func cancelImport(_ id: UUID, draftID importingDraftID: UUID) {
        importTasks.removeValue(forKey: id)
        draftAttachments.removeAll { $0.id == .operation(id) }
        Log.ui.info("ChatComposer.import cancelled draft=\(importingDraftID) import=\(id)")
    }

    private func failImport(_ id: UUID, draftID importingDraftID: UUID, error: Error) {
        importTasks.removeValue(forKey: id)
        guard draftID == importingDraftID,
              draftAttachments.contains(where: { $0.id == .operation(id) }) else { return }
        draftAttachments.removeAll { $0.id == .operation(id) }
        Log.ui.error("ChatComposer.import failed draft=\(importingDraftID) import=\(id) error=\(error.localizedDescription)")
    }
}

enum AttachmentChoice {
    case camera
    case photos
    case files
    case artifacts
    case service(Service)
}

struct ChatComposer: View, Equatable {
    static let restingVerticalOffset = Theme.Spacing.md
    static let artifactButtonHeight: CGFloat = 28
    static let promptTemplateOverlayOffset = Theme.Size.minimumTouchTarget + Theme.Spacing.xs

    static func firstSurfaceTopOffset(
        isResting: Bool,
        showsPromptTemplates: Bool,
        showsArtifactButton: Bool
    ) -> CGFloat {
        let restingOffset = isResting ? restingVerticalOffset : 0
        let surfaceTouchInset: CGFloat = if showsPromptTemplates {
            max(0, (Theme.Size.minimumTouchTarget - Theme.Size.chipHeight) / 2)
        } else if showsArtifactButton {
            max(0, (Theme.Size.minimumTouchTarget - artifactButtonHeight) / 2)
        } else {
            0
        }
        let promptTemplateOffset = showsPromptTemplates ? -promptTemplateOverlayOffset : 0
        return Theme.Spacing.sm + restingOffset + promptTemplateOffset + surfaceTouchInset
    }

    private enum PromptTemplate: String, Identifiable {
        case actions
        case workflows

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .actions: "New Actions"
            case .workflows: "New Workflow"
            }
        }
    }

    @Bindable var composer: ChatComposerModel
    let attachedServices: [Service]
    let chatArtifacts: [Artifact]
    let fieldFocused: FocusState<Bool>.Binding
    let isFieldFocused: Bool
    let sessionID: UUID
    let isChatEmpty: Bool
    let isBusy: Bool
    let iconButtonSize: CGFloat
    let composerButtonSize: CGFloat
    let onOpenAttachment: (Artifact, String) -> Void
    let onOpenChatArtifact: (Artifact) -> Void
    let onPasteImages: ([PastedComposerImage]) -> Void
    let onOpenService: (Service) -> Void
    let onRemoveService: (Service) -> Void
    let onSubmitSkill: (Skill, String) -> Void
    let onPreparationIntent: (Bool) -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    private let textLineFragmentPadding: CGFloat = 5
    private let textEditorVerticalInset: CGFloat = 9
    private let textEditorOpticalOffset: CGFloat = 1

    @State private var containerWidth: CGFloat = 0
    @State private var composerTextHeight: CGFloat = 22
    @State private var composerSelection = AttributedTextSelection()
    @State private var textViewReference = ComposerTextViewReference()
    @State private var promptTemplate: PromptTemplate?
    @State private var promptPrimaryInput = ""
    @State private var promptSecondaryInput = ""

    @Environment(\.appTheme) private var appTheme

    static func == (lhs: ChatComposer, rhs: ChatComposer) -> Bool {
        lhs.composer === rhs.composer
            && lhs.attachedServices.map(\.domain) == rhs.attachedServices.map(\.domain)
            && lhs.chatArtifacts == rhs.chatArtifacts
            && lhs.isFieldFocused == rhs.isFieldFocused
            && lhs.sessionID == rhs.sessionID
            && lhs.isChatEmpty == rhs.isChatEmpty
            && lhs.isBusy == rhs.isBusy
            && lhs.iconButtonSize == rhs.iconButtonSize
            && lhs.composerButtonSize == rhs.composerButtonSize
    }

    private var empty: Bool {
        composer.isEmpty
    }

    private var reservesTrailingControl: Bool {
        !isResting || isBusy
    }

    private var trailingControlSize: CGFloat {
        max(composerButtonSize + 10, Theme.Size.minimumTouchTarget)
    }

    var body: some View {
        inputBar
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                DispatchQueue.main.async {
                    guard abs(containerWidth - width) > 0.5 else { return }
                    containerWidth = width
                }
            }
            .onChange(of: composer.canSubmit, initial: true) { _, canSubmit in
                if canSubmit { Haptics.prepareImpact() }
                onPreparationIntent(canSubmit)
            }
            .onChange(of: composer.draft) { previous, current in
                guard previous.first != "/", current.first == "/" else { return }
                Skills.shared.refresh()
            }
            .alert(promptTemplate?.title ?? "", isPresented: promptTemplatePresented) {
                if let promptTemplate {
                    promptFields(promptTemplate)
                    Button("Cancel", role: .cancel, action: resetPromptTemplate)
                    Button("Add Prompt", action: applyPromptTemplate)
                        .disabled(!promptTemplateIsComplete)
                }
            } message: {
                if let promptTemplate {
                    promptMessage(promptTemplate)
                }
            }
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
        attachedServices.isEmpty ? 6 : Theme.Spacing.xs
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
    private var composerAccessoryStrips: some View {
        if !composer.draftAttachments.isEmpty || !attachedServices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                draftAttachmentStrip
                attachedServiceStrip
            }
        }
    }

    private enum LayoutState {
        case resting
        case active
    }

    private var layoutState: LayoutState {
        isFieldFocused || !empty ? .active : .resting
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
        .padding(.top, Theme.Spacing.sm)
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
        .animation(.easeOut(duration: Theme.Animation.standard), value: isResting)
    }

    private var composerCluster: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.xs) {
            if showsArtifactButton {
                artifactButton
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 0) {
                composerAccessoryStrips
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
        .overlay(alignment: .top) {
            if showsPromptTemplates {
                promptTemplateStrip
                    .offset(y: -Self.promptTemplateOverlayOffset)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    private var composerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
    }

    private var showsArtifactButton: Bool {
        isResting && !chatArtifacts.isEmpty
    }

    private var showsPromptTemplates: Bool {
        isChatEmpty
            && !isBusy
            && composer.draft.isEmpty
            && composer.draftAttachments.isEmpty
            && attachedServices.isEmpty
    }

    private var promptTemplatePresented: Binding<Bool> {
        Binding(
            get: { promptTemplate != nil },
            set: { presented in
                if !presented { resetPromptTemplate() }
            }
        )
    }

    private var promptTemplateIsComplete: Bool {
        !promptPrimaryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptSecondaryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptTemplateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    promptTemplateButton(
                        "New Actions",
                        systemImage: "hammer",
                        template: .actions,
                        accessibilityIdentifier: A11yID.Chat.newActions
                    )
                    promptTemplateButton(
                        "New Workflows",
                        systemImage: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath",
                        template: .workflows,
                        accessibilityIdentifier: A11yID.Chat.newWorkflows
                    )
                }
            }
            .frame(minWidth: promptTemplateStripWidth)
        }
        .scrollClipDisabled()
    }

    private var promptTemplateStripWidth: CGFloat {
        isResting ? restingWidth : max(0, containerWidth - horizontalSpacing * 2)
    }

    private func promptTemplateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        template: PromptTemplate,
        accessibilityIdentifier: String
    ) -> some View {
        Button {
            resetPromptTemplate()
            promptTemplate = template
            Log.ui.info("ChatComposer.promptTemplate present chat=\(sessionID) template=\(template.rawValue)")
        } label: {
            Label(title, systemImage: systemImage)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: Theme.Size.chipHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .minimumTouchTarget()
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func promptFields(_ template: PromptTemplate) -> some View {
        switch template {
        case .actions:
            TextField("Plugin or domain", text: $promptPrimaryInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Plugin or domain")
                .accessibilityIdentifier(A11yID.Chat.newActionsService)
            TextField("Features", text: $promptSecondaryInput)
                .accessibilityLabel("Features")
                .accessibilityIdentifier(A11yID.Chat.newActionsFeatures)
        case .workflows:
            TextField("Plugins needed", text: $promptPrimaryInput)
                .accessibilityLabel("Plugins needed")
                .accessibilityIdentifier(A11yID.Chat.newWorkflowServices)
            TextField("What should it achieve?", text: $promptSecondaryInput)
                .accessibilityLabel("What should it achieve?")
                .accessibilityIdentifier(A11yID.Chat.newWorkflowOutcome)
        }
    }

    @ViewBuilder
    private func promptMessage(_ template: PromptTemplate) -> some View {
        switch template {
        case .actions:
            Text("Describe the plugin and the actions you want Ox to add.")
        case .workflows:
            Text("Describe the plugins the skill needs and its goal.")
        }
    }

    private func applyPromptTemplate() {
        guard let promptTemplate, promptTemplateIsComplete else { return }
        let primary = promptPrimaryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = promptSecondaryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        composer.draft = switch promptTemplate {
        case .actions:
            String(localized: "Create a new plugin for \(primary), or add actions to the existing plugin if one is already available.\n\nFeatures: \(secondary)")
        case .workflows:
            String(localized: "Create a new workflow as a skill.\n\nPlugins needed: \(primary)\n\nGoal: \(secondary)")
        }
        Log.ui.info("ChatComposer.promptTemplate apply chat=\(sessionID) template=\(promptTemplate.rawValue) chars=\(composer.draft.count)")
        resetPromptTemplate()
        DispatchQueue.main.async { fieldFocused.wrappedValue = true }
    }

    private func resetPromptTemplate() {
        promptTemplate = nil
        promptPrimaryInput = ""
        promptSecondaryInput = ""
    }

    private var artifactCountLabel: String {
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
            Text(verbatim: artifactCountLabel)
                .font(Theme.Fonts.captionMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(height: Self.artifactButtonHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .minimumTouchTarget()
        .accessibilityLabel(Text(verbatim: artifactCountLabel))
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

    @ViewBuilder
    private var attachedServiceStrip: some View {
        if !attachedServices.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachedServices) { picked in
                        attachedServicePill(picked)
                    }
                }
                .padding(.leading, Theme.Spacing.sm)
                .padding(.top, attachedServiceTopPadding)
            }
            .excludesCompactPageSwitch()
            .overlay { chipRowEdgeGlow }
        }
    }

    private var attachedServiceTopPadding: CGFloat {
        composer.draftAttachments.isEmpty ? Theme.Spacing.sm : 0
    }

    private var composerRow: some View {
        ZStack(alignment: .leading) {
            if composer.draft.isEmpty {
                Text("Ask Ox")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.leading, textLineFragmentPadding)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: attributedDraft, selection: $composerSelection)
                .id(composer.draftID)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(0, for: .scrollContent)
                .frame(height: composerTextHeight + textEditorVerticalInset * 2)
                .padding(.top, -textEditorVerticalInset + textEditorOpticalOffset)
                .padding(.bottom, -textEditorVerticalInset - textEditorOpticalOffset)
                .focused(fieldFocused)
                .accessibilityIdentifier(A11yID.Chat.input)
                .accessibilityValue(composer.draft.isEmpty ? Text("Ask Ox") : Text(verbatim: composer.draft))
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .tint(Theme.Colors.primary.dynamic)
                .background(ComposerPasteDelegateInstaller(textViewReference: textViewReference))
                .onChange(of: composerSelection) { _, selection in
                    selectionChanged(selection)
                }
                .onChange(of: composer.caretEndRequest) { _, _ in
                    composerSelection = AttributedTextSelection(insertionPoint: composer.attributedDraft.endIndex)
                }
            Text(attributedDraft.wrappedValue)
                .font(Theme.Fonts.bodyMd)
                .lineLimit(1...6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    DispatchQueue.main.async {
                        let measuredHeight = max(height, 22)
                        guard abs(composerTextHeight - measuredHeight) > 0.5 else { return }
                        composerTextHeight = measuredHeight
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.leading, iconButtonSize - textLineFragmentPadding)
        .padding(.trailing, reservesTrailingControl ? trailingControlSize + 2 : Theme.Spacing.lg)
        .padding(.vertical, 12)
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
        if composer.isImporting, isBusy {
            composerButton(systemName: "stop.fill", label: A11yLabel.stop, id: A11yID.Chat.stop, event: .stop, action: onStop)
        } else if composer.isImporting {
            CellularAutomatonLoader.small
                .frame(width: composerButtonSize, height: composerButtonSize)
                .padding(.trailing, 6)
                .padding(.vertical, 5)
                .accessibilityLabel("Attaching")
        } else if composer.canSubmit {
            composerButton(systemName: "arrow.up", label: A11yLabel.send, id: A11yID.Chat.send, event: .send, action: submit)
        } else if isBusy, !composer.suppressesStopControl {
            composerButton(systemName: "stop.fill", label: A11yLabel.stop, id: A11yID.Chat.stop, event: .stop, action: onStop)
        }
    }

    private func setMenu(_ visible: Bool) {
        Log.ui.info("ChatComposer.attachMenu chat=\(sessionID) visible=\(visible)")
        withAnimation(Theme.Animation.glassMorph) { composer.setAttachmentMenuPresented(visible) }
    }

    private var attachButton: some View {
        Button {
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
        .accessibilityLabel(A11yLabel.addAttachment)
        .accessibilityIdentifier(A11yID.Chat.attach)
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
            }
        )
    }

    private func composerButton(
        systemName: String,
        label: String,
        id: String,
        event: Haptics.Event,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(event)
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
        guard let invocation = composer.slashInvocation else {
            composer.delayStopControl()
            onSend()
            return
        }
        onSubmitSkill(invocation.skill, invocation.argument)
    }

    private var attributedDraft: Binding<AttributedString> {
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

    private func selectionChanged(_ selection: AttributedTextSelection) {
        let state = switch selection.indices(in: composer.attributedDraft) {
        case .insertionPoint(let index):
            "caretAtEnd=\(index == composer.attributedDraft.endIndex)"
        case .ranges:
            "range"
        }
        Log.ui.info("ChatComposer.selection chat=\(sessionID) \(state) chars=\(composer.attributedDraft.characters.count)")
    }

}

struct ComposerServicePicker: View {
    @Bindable var composer: ChatComposerModel
    let excludedDomains: Set<String>
    let space: CGFloat
    let composerHeight: CGFloat
    let onSelect: (Service) -> Void
    let onExplore: () -> Void

    @ViewBuilder
    var body: some View {
        if case .mention(let query) = composer.surface {
            ServicePickerPanel(
                query: query,
                excludedDomains: excludedDomains,
                space: space,
                onSelect: onSelect,
                onExplore: onExplore
            )
            .frame(maxWidth: Theme.ContainerWidth.readable)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, composerHeight + Theme.Spacing.xs)
        }
    }
}

struct ComposerSlashPicker: View {
    @Bindable var composer: ChatComposerModel
    let isFocused: Bool
    let space: CGFloat
    let composerHeight: CGFloat
    let onSelect: (Skill) -> Void

    @ViewBuilder
    var body: some View {
        let suggestions = composer.slashSuggestions
        if isFocused, !suggestions.isEmpty {
            SlashPickerPanel(
                suggestions: suggestions,
                space: space,
                onSelect: onSelect
            )
            .frame(maxWidth: Theme.ContainerWidth.readable)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, composerHeight + Theme.Spacing.xs)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: Theme.Animation.standard), value: suggestions.map(\.id))
        }
    }
}

struct ComposerAttachMenu: View {
    let isPresented: Bool
    let topClearance: CGFloat
    let onDismiss: () -> Void
    let onChoice: (AttachmentChoice) -> Void
    let onServices: () -> Void

    @ScaledMetric(relativeTo: .body) private var menuTextHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if isPresented {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture(perform: dismiss)
                        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in dismiss() })
                        .accessibilityHidden(true)
                    menuCard(maxHeight: availableCardHeight(in: geometry))
                        .transition(.blurReplace.combined(with: ScaleTransition(0.05, anchor: UnitPoint(x: 0.1, y: 0.88))))
                        .frame(maxWidth: Theme.ContainerWidth.readable, alignment: .leading)
                        .padding(.leading, Theme.Spacing.sm + Theme.Spacing.xs)
                        .padding(.trailing, Theme.Spacing.md)
                        .padding(.bottom, Theme.Spacing.sm)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        .accessibilityHidden(!isPresented)
    }

    private func availableCardHeight(in geometry: GeometryProxy) -> CGFloat {
        max(
            Theme.Size.minimumTouchTarget,
            geometry.size.height
                - topClearance
                - Theme.Spacing.sm * 2
        )
    }

    private func menuCard(maxHeight: CGFloat) -> some View {
        ScrollView {
            card
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(width: 270)
        .frame(height: min(idealCardHeight, maxHeight), alignment: .bottom)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var idealCardHeight: CGFloat {
        let rowHeight = max(Theme.Size.minimumTouchTarget, menuTextHeight) + Theme.Spacing.sm * 2
        return rowHeight * 5 + Theme.Spacing.sm * 2
    }

    private var card: some View {
        AttachMenuCard(
            onChoice: { choice in
                dismiss()
                onChoice(choice)
            },
            onServices: {
                dismiss()
                DispatchQueue.main.async(execute: onServices)
            }
        )
    }

    private func dismiss() {
        guard isPresented else { return }
        withAnimation(Theme.Animation.glassMorph, onDismiss)
    }
}

private struct AttachMenuCard: View {
    let onChoice: (AttachmentChoice) -> Void
    let onServices: () -> Void

    private enum Icon {
        case system(String)
        case action(OxActionIconKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Camera", icon: .system("camera"), a11yID: A11yID.Chat.Attach.camera) { onChoice(.camera) }
            row("Photos", icon: .system("photo.on.rectangle"), a11yID: A11yID.Chat.Attach.photos) { onChoice(.photos) }
            row("Files", icon: .system("paperclip"), a11yID: A11yID.Chat.Attach.files) { onChoice(.files) }
            row("Artifacts", icon: .action(.artifacts), a11yID: A11yID.Chat.Attach.artifacts) { onChoice(.artifacts) }
            row("Plugins", icon: .action(.services), a11yID: A11yID.Chat.Attach.services, action: onServices)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(width: 270, alignment: .leading)
    }

    private func row(
        _ title: LocalizedStringKey,
        icon: Icon,
        a11yID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.attachmentChoice)
            action()
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Group {
                    switch icon {
                    case .system(let symbol):
                        Image(systemName: symbol)
                            .font(.system(.body, weight: .medium))
                    case .action(let kind):
                        OxActionIcon(kind, size: 20)
                    }
                }
                    .foregroundStyle(Theme.Colors.onSurface)
                    .frame(width: 44, height: 44)
                    .background(Theme.Colors.surfaceSunken.opacity(0.8), in: Circle())
                Text(title)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(a11yID)
    }
}

private struct ServicePickerPanel: View {
    let query: String
    let excludedDomains: Set<String>
    let space: CGFloat
    let onSelect: (Service) -> Void
    let onExplore: () -> Void
    @Environment(ServiceManager.self) private var serviceManager

    @State private var results: [ServiceManager.ServiceMatch] = []
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 52

    private let maxResults = 40

    private var isLoadingServices: Bool {
        serviceManager.monoRepositoryState != .ready
    }

    private var listHeight: CGFloat {
        if results.isEmpty { return 72 }
        let cap = max(rowHeight, min(space - 72, 280))
        let statusHeight = isLoadingServices ? rowHeight : 0
        return min(CGFloat(results.count) * rowHeight + statusHeight, cap)
    }

    private var searchKey: String {
        [
            query,
            excludedDomains.sorted().joined(separator: "\u{1}"),
            String(serviceManager.monoRepositoryRevision)
        ].joined(separator: "\u{2}")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .frame(height: headerHeight + listHeight)
        .padding(.vertical, Theme.Spacing.xs)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .task(id: searchKey) { await runSearch() }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Plugins")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Spacer(minLength: 0)
            exploreButton
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var exploreButton: some View {
        Button(action: onExplore) {
            OxActionIcon(.services, size: 20)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 32, height: 28)
                .minimumTouchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plugins")
        .accessibilityIdentifier(A11yID.Chat.Attach.explore)
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            if isLoadingServices {
                MonoRepositoryLoadingStatus(
                    minHeight: rowHeight,
                    accessibilityIdentifier: A11yID.Chat.mentionLoading
                )
                    .frame(minHeight: 72)
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    LibraryDestinationIcon(.services, size: 28)
                    Text("No plugins found")
                        .font(Theme.Fonts.bodySm)
                }
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            }
        } else {
            ForEach(results) { match in
                Button { onSelect(match.service) } label: { row(match) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11yID.Chat.mention(match.service.domain))
            }
            if isLoadingServices {
                MonoRepositoryLoadingStatus(
                    minHeight: rowHeight,
                    accessibilityIdentifier: A11yID.Chat.mentionLoading
                )
            }
        }
    }

    private func row(_ match: ServiceManager.ServiceMatch) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            ServiceAvatar(service: match.service, size: 24, shape: .roundedRect(Theme.Radius.sm), monogramSize: 10)
            Text(match.service.title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .contentShape(Rectangle())
    }

    @MainActor
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
        }
        let matches = await serviceManager.search(trimmed, filter: .all)
        if Task.isCancelled { return }
        let saved = serviceManager.savedDomains
        let filtered = matches.filter { !excludedDomains.contains($0.service.domain) }
        let ranked = filtered.enumerated().sorted { lhs, rhs in
            let lSaved = saved.contains(lhs.element.service.domain)
            let rSaved = saved.contains(rhs.element.service.domain)
            if lSaved != rSaved { return lSaved }
            if trimmed.isEmpty {
                let order = lhs.element.service.title.localizedCaseInsensitiveCompare(rhs.element.service.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        results = Array(ranked.prefix(maxResults))
    }
}

private struct SlashPickerPanel: View {
    let suggestions: [Skill]
    let space: CGFloat
    let onSelect: (Skill) -> Void

    @State private var contentHeight: CGFloat = 0

    private var maxHeight: CGFloat {
        max(44, min(space - Theme.Spacing.lg, 280))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(suggestions) { skill in
                    Button { onSelect(skill) } label: { row(skill) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Chat.skill(skill.name))
                }
            }
            .padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
    }

    private func row(_ skill: Skill) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(verbatim: "/\(skill.displayName)")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
                .layoutPriority(1)
            Text(verbatim: skill.description)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
        ZStack(alignment: .topTrailing) {
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
                    .offset(x: -2, y: 4)
                    .frame(
                        width: Theme.Size.minimumTouchTarget,
                        height: Theme.Size.minimumTouchTarget,
                        alignment: .top
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: Theme.Size.minimumTouchTarget / 2, y: -10)
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
        .padding(.trailing, 32)
        .frame(minWidth: 120, maxWidth: 240, minHeight: 40, alignment: .leading)
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
