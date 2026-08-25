import SwiftUI

struct ChatPageTopBar: View {
    let chat: Chat
    let blockCount: Int
    let hasArtifacts: Bool
    let iconButtonSize: CGFloat
    let onShowSidebar: () -> Void
    let onToggleTemporary: () -> Void
    let onPickModel: () -> Void
    let onShowArtifacts: () -> Void
    let onCopyTranscript: () -> Void
    let onDeleteChat: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SidebarMenuButton(action: onShowSidebar)
            if blockCount == 0, chat.canChangeRetention || !chat.isTemporary {
                modelPill
            }
            Spacer()
            if chat.canChangeRetention {
                temporaryModeButton
            } else {
                overflowMenu
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var temporaryModeButton: some View {
        Button(action: onToggleTemporary) {
            TemporaryChatIcon(isActive: chat.isTemporary)
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 29, height: 29)
                .frame(width: iconButtonSize, height: iconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(chat.isTemporary ? "Turn off temporary chat" : "Start temporary chat")
        .accessibilityValue(chat.isTemporary ? "On" : "Off")
        .accessibilityAddTraits(chat.isTemporary ? .isSelected : [])
        .accessibilityIdentifier(A11yID.Chat.temporaryToggle)
    }

    private var modelPill: some View {
        Button(action: onPickModel) {
            HStack(spacing: 4) {
                Text(chat.model.displayName)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: iconButtonSize)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Model: \(chat.model.displayName)")
        .accessibilityIdentifier(A11yID.Chat.modelPicker)
    }

    private var overflowMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: iconButtonSize, height: iconButtonSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(A11yLabel.more)
        .accessibilityIdentifier(A11yID.Chat.more)
        .glassEffect(.regular.interactive(), in: Circle())
    }
}
