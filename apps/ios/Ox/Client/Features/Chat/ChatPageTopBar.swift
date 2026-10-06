import SwiftUI

struct ChatPageTopBar: View {
    let chat: Conversation
    let blockCount: Int
    let hasArtifacts: Bool
    let showsModelPicker: Bool
    let iconButtonSize: CGFloat
    let onShowSidebar: () -> Void
    let onToggleTemporary: () -> Void
    let onPickModel: () -> Void
    let onShowArtifacts: () -> Void
    let onCopyTranscript: () -> Void
    let onDeleteChat: () -> Void

    var body: some View {
        ChatHeader(
            modelTitle: showsModelPicker && blockCount == 0 && (chat.canChangeRetention || !chat.isTemporary)
                ? chat.model.displayName : nil,
            iconButtonSize: iconButtonSize,
            onShowSidebar: onShowSidebar,
            onPickModel: onPickModel
        ) {
            if chat.canChangeRetention {
                TemporaryChatButton(isActive: chat.isTemporary, size: iconButtonSize, action: onToggleTemporary)
            } else {
                overflowMenu(chat: chat)
            }
        }
    }

    private func overflowMenu(chat: Conversation) -> some View {
        ChatOverflowMenu(size: iconButtonSize) {
            Button(action: onPickModel) {
                Label("Models", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier(A11yID.Chat.modelPicker)
            if hasArtifacts || blockCount > 0 {
                Divider()
            }
            if hasArtifacts {
                Button(action: onShowArtifacts) {
                    Label("Artifacts", systemImage: OxActionIconKind.artifacts.systemImage)
                }
                .accessibilityIdentifier(A11yID.Chat.Artifact.open)
            }
            if blockCount > 0 {
                Button(action: onCopyTranscript) {
                    Label("Copy Chat", systemImage: "doc.on.doc")
                        .onAppear { Haptics.prepareImpact() }
                }
                ShareLink(
                    item: ChatPackageDocument(
                        state: chat.state,
                        fileName: ArtifactStore.sanitizedFilename(chat.title)
                    ),
                    preview: SharePreview(Text(verbatim: chat.title))
                ) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(chat.isBusy)
                .accessibilityIdentifier(A11yID.Chat.export)
                Button(role: .destructive, action: onDeleteChat) {
                    Label("Delete Chat", systemImage: "trash")
                }
                .accessibilityIdentifier(A11yID.Chat.delete)
            }
        }
    }
}
