import SwiftUI

struct ConversationOpeningShell: View {
    let meta: ConversationMeta
    let parentTitle: String?
    let showsLoader: Bool
    let onShowSidebar: () -> Void

    @State private var composer = ConversationComposerModel()
    @State private var speech = ConversationSpeechInput()
    @State private var editDraft = AttributedString()
    @FocusState private var composerFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var iconButtonSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var composerButtonSize: CGFloat = 34

    private var surface: some ShapeStyle {
        Theme.Colors.conversationSurface.opacity(horizontalSizeClass == .compact ? 0 : 1)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if showsLoader {
                    CellularAutomatonLoader()
                        .transition(.opacity)
                        .accessibilityIdentifier(A11yID.ConversationControls.openingLoader)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : Theme.Animation.quick, value: showsLoader)
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inertComposer
                    .frame(maxWidth: Theme.ContainerWidth.readable)
                    .frame(maxWidth: .infinity)
            }
            .background(surface)
            .containerBackground(surface, for: .navigation)
            .toolbar(.hidden, for: .navigationBar)
        }
        .background(surface)
    }

    private var header: some View {
        ConversationHeader(
            title: meta.displayTitle,
            agentTitle: meta.remoteAgent.map { RemoteAgentDirectory.shared.displayName(for: $0.endpoint) } ?? Device.localAgentName,
            agentStatus: meta.remoteAgent.map { RemoteAgentDirectory.shared.statuses[$0.endpoint] ?? .checking },
            parent: meta.parentID.map { _ in ConversationAgentButton.Parent(title: parentTitle) {} },
            iconButtonSize: iconButtonSize,
            onShowSidebar: onShowSidebar,
            onPickModel: {}
        ) {
            ConversationOverflowMenu(size: iconButtonSize) {}
                .disabled(true)
        }
    }

    private var inertComposer: some View {
        ConversationComposer(
            composer: composer,
            isEditingMessage: false,
            editDraft: $editDraft,
            speech: speech,
            attachedServices: [],
            conversationFiles: [],
            fieldFocused: $composerFocused,
            isFieldFocused: false,
            sessionID: meta.id,
            isConversationEmpty: false,
            isTemporary: false,
            isBusy: false,
            floatsTopStrip: false,
            isEmbedded: false,
            iconButtonSize: iconButtonSize,
            composerButtonSize: composerButtonSize,
            onOpenAttachment: { _ in },
            onPasteImages: { _ in },
            onOpenService: { _ in },
            onRemoveService: { _ in },
            onAttachmentChoice: { _ in },
            onServices: {},
            onSubmitSkill: { _, _ in },
            onPreparationIntent: { _ in },
            onCancelEdit: {},
            onSend: {},
            onStop: {},
            onSpeechBegin: { _ in }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
