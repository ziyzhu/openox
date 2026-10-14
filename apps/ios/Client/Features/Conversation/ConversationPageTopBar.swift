import SwiftUI

struct ConversationPageTopBar: View {
    let conversation: Conversation
    let blockCount: Int
    let hasFiles: Bool
    let showsModelPicker: Bool
    let iconButtonSize: CGFloat
    let onShowSidebar: () -> Void
    let onToggleTemporary: () -> Void
    let onPickModel: () -> Void
    let onShowFiles: () -> Void
    let onCopyTranscript: () -> Void
    let onDeleteConversation: () -> Void

    var body: some View {
        ConversationHeader(
            modelTitle: showsModelPicker && blockCount == 0 && (conversation.canChangeRetention || !conversation.isTemporary)
                ? conversation.model.displayName : nil,
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
    }

    private func overflowMenu(conversation: Conversation) -> some View {
        ConversationOverflowMenu(size: iconButtonSize) {
            Button(action: onPickModel) {
                Label("Models", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier(A11yID.ConversationControls.modelPicker)
            if hasFiles || blockCount > 0 {
                Divider()
            }
            if hasFiles {
                Button(action: onShowFiles) {
                    Label("Files", systemImage: OxActionIconKind.artifacts.systemImage)
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
                        state: conversation.state,
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
