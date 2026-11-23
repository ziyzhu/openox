import SwiftUI

struct ConversationChildrenChip: View {
    let children: [ChildConversationSnapshot]
    let onOpen: (UUID) -> Void
    let onDelete: (UUID) -> Void

    @State private var pendingDeletion: ChildConversationSnapshot?

    var body: some View {
        Menu {
            ForEach(children) { child in
                Menu {
                    Button {
                        Log.ui.info("ConversationChildren.open child=\(child.id) state=\(child.state.label)")
                        onOpen(child.id)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right")
                    }
                    .accessibilityIdentifier(A11yID.ConversationControls.Children.open(child.id))
                    Button(role: .destructive) {
                        pendingDeletion = child
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier(A11yID.ConversationControls.Children.delete(child.id))
                } label: {
                    Label {
                        Text(verbatim: child.title)
                        Text(Self.stateText(child.state))
                    } icon: {
                        Image(systemName: Self.symbol(child.state))
                    }
                }
                .accessibilityValue(Text(Self.stateText(child.state)))
                .accessibilityIdentifier(A11yID.ConversationControls.Children.item(child.id))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .accessibilityHidden(true)
                Text("Conversations")
                Text(verbatim: "· \(children.count)")
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
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(A11yID.ConversationControls.Children.chip)
        .alert(
            "Delete this conversation?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { child in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Log.ui.info("ConversationChildren.delete child=\(child.id) state=\(child.state.label)")
                onDelete(child.id)
            }
        } message: { _ in
            Text("This removes the conversation from your history. This can't be undone.")
        }
    }

    private var accessibilityLabel: String {
        let waiting = children.filter { if case .needsUser = $0.state { true } else { false } }.count
        let total = String(localized: "\(children.count) delegated conversations")
        return waiting == 0 ? total : "\(total), \(String(localized: "\(waiting) need you"))"
    }

    private static func stateText(_ state: ChildConversationState) -> LocalizedStringKey {
        switch state {
        case .running: "Running…"
        case .needsUser: "Needs you"
        case .idle: "Done"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    private static func symbol(_ state: ChildConversationState) -> String {
        switch state {
        case .running: "ellipsis.circle"
        case .needsUser: "exclamationmark.circle"
        case .idle: "checkmark.circle"
        case .stopped: "stop.circle"
        case .failed: "xmark.circle"
        }
    }
}

struct ConversationParentLink: View {
    let title: String?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.turn.up.left")
                Text(verbatim: title.map { String(localized: "From \($0)") } ?? String(localized: "From a deleted conversation"))
                    .lineLimit(1)
            }
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.chipHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(title == nil)
        .minimumTouchTarget()
        .accessibilityIdentifier(A11yID.ConversationControls.Children.parent)
    }
}
