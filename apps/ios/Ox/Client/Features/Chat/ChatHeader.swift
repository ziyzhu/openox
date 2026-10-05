import SwiftUI

struct ChatHeader<Trailing: View>: View {
    let modelTitle: String?
    let iconButtonSize: CGFloat
    let onShowSidebar: () -> Void
    let onPickModel: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            SidebarMenuButton(action: onShowSidebar)
            if let modelTitle {
                ChatModelButton(title: modelTitle, size: iconButtonSize, action: onPickModel)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xs)
    }
}

struct TemporaryChatButton: View {
    let isActive: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TemporaryChatIcon(isActive: isActive)
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 29, height: 29)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(isActive ? "Turn off temporary chat" : "Start temporary chat")
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier(A11yID.Chat.temporaryToggle)
    }
}

struct ChatOverflowMenu<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(A11yLabel.more)
        .accessibilityIdentifier(A11yID.Chat.more)
        .glassEffect(.regular.interactive(), in: Circle())
    }
}
