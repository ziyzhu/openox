import SwiftUI

struct ConversationPageTopBar: View {
    let conversation: Conversation
    let blockCount: Int
    let hasFiles: Bool
    let parent: ConversationAgentButton.Parent?
    let iconButtonSize: CGFloat
    let onShowSidebar: () -> Void
    let onToggleTemporary: () -> Void
    let onPickModel: () -> Void
    let onShowFiles: () -> Void
    let onCopyTranscript: () -> Void
    let onDeleteConversation: () -> Void

    var body: some View {
        ConversationHeader(
            title: conversation.title,
            agentTitle: agentTitle,
            agentStatus: conversation.remoteAgent.map { RemoteAgentDirectory.shared.statuses[$0.endpoint] ?? .checking },
            parent: parent,
            iconButtonSize: iconButtonSize,
            onShowSidebar: onShowSidebar,
            onPickModel: onPickModel
        ) {
            if conversation.canChangeRetention {
                TemporaryConversationButton(isActive: conversation.isTemporary, size: iconButtonSize, action: onToggleTemporary)
            } else {
                overflowMenu(conversation: conversation)
            }
        }
        .task(id: conversation.remoteAgent?.endpoint) {
            guard let endpoint = conversation.remoteAgent?.endpoint else { return }
            await RemoteAgentDirectory.shared.refresh(endpoint)
        }
    }

    private var agentTitle: String {
        guard conversation.remoteAgent != nil else {
            let registry = ProviderRegistry.shared
            let model = registry.model(for: conversation.modelSelection, client: registry.client(for: conversation.modelSelection))
            return "\(Device.localAgentName) · \(model.displayName)"
        }
        return [conversation.remoteAgentName, conversation.remoteModelName].compactMap(\.self).joined(separator: " · ")
    }

    private func overflowMenu(conversation: Conversation) -> some View {
        ConversationOverflowMenu(size: iconButtonSize) {
            Button(action: onPickModel) {
                Label(conversation.remoteAgent == nil ? "Models" : "Model", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier(A11yID.ConversationControls.modelMenuItem)
            if hasFiles || blockCount > 0 {
                Divider()
            }
            if hasFiles {
                Button(action: onShowFiles) {
                    Label("Files", systemImage: OxActionIconKind.files.systemImage)
                }
                .accessibilityIdentifier(A11yID.ConversationControls.FileItem.open)
            }
            if blockCount > 0 {
                Button(action: onCopyTranscript) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .onAppear { Haptics.prepareImpact() }
                }
                ShareLink(
                    item: ConversationPackageDocument(
                        state: { [conversation] in try await conversation.completeState() },
                        fileName: FileStore.sanitizedFilename(conversation.title)
                    ),
                    preview: SharePreview(Text(verbatim: conversation.title))
                ) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(conversation.isBusy)
                .accessibilityIdentifier(A11yID.ConversationControls.export)
                Button(role: .destructive, action: onDeleteConversation) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(A11yID.ConversationControls.delete)
            }
        }
    }
}

struct ConversationModelAccessNotice: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.Colors.primary)
                Text(verbatim: L10n.string("Choose a model"))
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
        .accessibilityIdentifier(A11yID.ConversationControls.modelAccessNotice)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
        .frame(maxWidth: Theme.ContainerWidth.readable)
        .frame(maxWidth: .infinity)
    }
}
