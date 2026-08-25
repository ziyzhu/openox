import SwiftUI

struct ChatSidebar: View {
    let summaries: [ChatMeta]
    let activities: [UUID: Chat.Activity]
    let currentId: UUID?
    let servicesActive: Bool
    let artifactsActive: Bool
    let skillsActive: Bool
    let showsCloseButton: Bool
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onOpen: (ChatMeta) -> Void
    let onDelete: (ChatMeta) -> Void
    let onRename: (ChatMeta, String) -> Void
    let onToggleFavorite: (ChatMeta) -> Void
    let onExplore: () -> Void
    let onArtifacts: () -> Void
    let onSkills: () -> Void
    let onSettings: () -> Void

    private let edgeInset = Theme.Spacing.lg
    @ScaledMetric(relativeTo: .title3) private var iconButtonSize: CGFloat = 44
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var renaming: ChatMeta?
    @State private var pendingDelete: ChatMeta?
    @State private var titleDraft = ""
    @State private var searchQuery = ""
    @State private var searchPresented = false

    var body: some View {
        NavigationStack {
            list
                .accessibilityIdentifier(A11yID.Sidebar.panel)
                .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) { header }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { settingsButton }
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { newChatButton }
                }
                .toolbarVisibility(horizontalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
        }
        .searchable(
            text: $searchQuery,
            isPresented: $searchPresented,
            placement: .toolbar,
            prompt: Text(A11yLabel.searchChats)
        )
        .background(Theme.Colors.surface, ignoresSafeAreaEdges: .all)
        .alert(A11yLabel.renameChat, isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $titleDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                guard let meta = renaming else { return }
                renaming = nil
                onRename(meta, titleDraft)
            }
        }
        .alert("Delete this chat?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete Chat", role: .destructive) {
                guard let meta = pendingDelete else { return }
                pendingDelete = nil
                onDelete(meta)
            }
        } message: {
            Text("This removes the chat from your history. This can't be undone.")
        }
    }

    private var newChatButton: some View {
        Button {
            searchPresented = false
            onNewChat()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(.body, weight: .semibold))
        }
        .accessibilityLabel(A11yLabel.newChat)
        .accessibilityIdentifier(A11yID.Sidebar.newChat)
    }

    private var settingsButton: some View {
        Button {
            searchPresented = false
            onSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(.body, weight: .semibold))
        }
        .accessibilityLabel(A11yLabel.settings)
        .accessibilityIdentifier(A11yID.Sidebar.settings)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Ox")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Colors.onSurface)
            previewChip
            Spacer(minLength: Theme.Spacing.md)
            if showsCloseButton {
                closeButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, edgeInset)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var closeButton: some View {
        Button {
            searchPresented = false
            onClose()
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: iconButtonSize, height: iconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(A11yLabel.closeChatHistory)
        .accessibilityIdentifier(A11yID.Sidebar.close)
    }

    private var previewChip: some View {
        Text("Preview")
            .font(Theme.Fonts.captionSm)
            .foregroundStyle(Theme.Colors.primary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(Theme.Colors.primary.opacity(0.12), in: Capsule())
    }

    private var list: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty
            ? summaries
            : summaries.filter { $0.displayTitle.localizedStandardContains(query) }
        let sorted = matching.sorted { $0.activityDate > $1.activityDate }
        let pinned = sorted.filter(\.isFavorite)
        let recents = sorted.filter { !$0.isFavorite }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                servicesRow
                artifactsRow
                skillsRow
                Color.clear.frame(height: Theme.Spacing.sm)
                if !pinned.isEmpty {
                    sectionHeader("Pinned")
                    ForEach(pinned) { row($0) }
                }
                sectionHeader("Recents")
                if recents.isEmpty {
                    Text(LocalizedStringKey(query.isEmpty ? "Empty" : "No chats found"))
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .padding(.horizontal, edgeInset)
                        .padding(.vertical, 11)
                } else {
                    ForEach(recents) { row($0) }
                }
                Color.clear.frame(height: Theme.Spacing.md)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var servicesRow: some View {
        destinationRow(.services, isActive: servicesActive, action: onExplore)
    }

    private var artifactsRow: some View {
        destinationRow(.artifacts, isActive: artifactsActive, action: onArtifacts)
    }

    private var skillsRow: some View {
        destinationRow(.skills, isActive: skillsActive, action: onSkills)
    }

    private func destinationRow(
        _ destination: LibraryDestination,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            searchPresented = false
            action()
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                LibraryDestinationIcon(destination)
                Text(destination.title)
                    .font(Theme.Fonts.bodyMd)
            }
            .foregroundStyle(Theme.Colors.onSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SidebarRowButtonStyle(isActive: isActive, edgeInset: edgeInset))
        .accessibilityLabel(destination.accessibilityLabel)
        .accessibilityIdentifier(destination.accessibilityIdentifier)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, edgeInset)
            .padding(.vertical, Theme.Spacing.sm)
    }

    private func row(_ meta: ChatMeta) -> some View {
        SidebarRow(
            meta: meta,
            activity: activities[meta.id] ?? .idle(.read),
            isActive: meta.id == currentId,
            edgeInset: edgeInset
        ) {
            searchPresented = false
            onOpen(meta)
        }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .contextMenuPreviewShape()
            .contextMenu {
                Button {
                    onToggleFavorite(meta)
                } label: {
                    Label(
                        meta.isFavorite ? A11yLabel.unpin : A11yLabel.pin,
                        systemImage: meta.isFavorite ? "pin.slash" : "pin")
                }
                .accessibilityIdentifier(A11yID.Sidebar.favoriteRow(meta.id.uuidString))
                Button {
                    titleDraft = meta.displayTitle
                    renaming = meta
                } label: {
                    Label(A11yLabel.renameChat, systemImage: "pencil")
                }
                .accessibilityIdentifier(A11yID.Sidebar.renameRow(meta.id.uuidString))
                Button(role: .destructive) {
                    pendingDelete = meta
                } label: {
                    Label(A11yLabel.deleteChat, systemImage: "trash")
                }
                .accessibilityIdentifier(A11yID.Sidebar.deleteRow(meta.id.uuidString))
            } preview: {
                ChatContextMenuPreview(meta: meta)
            }
            .id(meta.id.uuidString + (meta.isFavorite ? ".pinned" : ".recent"))
    }

}

private extension LibraryDestination {
    var accessibilityLabel: String {
        switch self {
        case .services: A11yLabel.services
        case .artifacts: A11yLabel.artifacts
        case .skills: A11yLabel.skills
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .services: A11yID.Sidebar.services
        case .artifacts: A11yID.Sidebar.artifacts
        case .skills: A11yID.Sidebar.skills
        }
    }
}

private struct SidebarRow: View {
    let meta: ChatMeta
    let activity: Chat.Activity
    let isActive: Bool
    let edgeInset: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayTitle)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(lastModifiedText(relativeTo: context.date))
                            .font(Theme.Fonts.captionSm)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                activityIndicator
            }
        }
        .buttonStyle(SidebarRowButtonStyle(isActive: isActive, edgeInset: edgeInset))
        .accessibilityLabel(meta.displayTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(A11yID.Sidebar.row(meta.id.uuidString))
    }

    private func lastModifiedText(relativeTo now: Date) -> String {
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day
        let month = 30 * day
        let elapsed = max(0, now.timeIntervalSince(meta.activityDate))
        guard elapsed >= minute else { return L10n.string("Active just now") }

        let components: DateComponents
        switch elapsed {
        case ..<hour:
            components = DateComponents(minute: -Int(elapsed / minute))
        case ..<day:
            components = DateComponents(hour: -Int(elapsed / hour))
        case ..<week:
            components = DateComponents(day: -Int(elapsed / day))
        case ..<month:
            components = DateComponents(weekOfMonth: -Int(elapsed / week))
        default:
            components = DateComponents(month: -Int(elapsed / month))
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocale.resolvedLocale
        formatter.unitsStyle = .full
        return L10n.string("Active \(formatter.localizedString(from: components))")
    }

    private var accessibilityValue: String {
        let activity = activityAccessibilityValue
        let lastModified = lastModifiedText(relativeTo: Date())
        return activity.isEmpty ? lastModified : "\(lastModified), \(activity)"
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch activity {
        case .idle(.read):
            EmptyView()
        case .idle(.unread):
            Circle()
                .fill(Theme.Colors.primary)
                .frame(width: 8, height: 8)
                .padding(.horizontal, Theme.Spacing.sm - 2)
                .accessibilityHidden(true)
        case .running(.thinking), .running(.streaming):
            CellularAutomatonLoader.small
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        case .running(.awaiting(let action)):
            Text(action.badgeText)
                .font(Theme.Fonts.captionSm)
                .foregroundStyle(Theme.Colors.primary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 3)
                .background(Theme.Colors.primary.opacity(0.12), in: Capsule())
                .accessibilityHidden(true)
        }
    }

    private var activityAccessibilityValue: String {
        switch activity {
        case .idle(.read): ""
        case .idle(.unread): L10n.string("Unread")
        case .running(.thinking), .running(.streaming): L10n.string("Plowing")
        case .running(.awaiting(let action)): action.accessibilityValue
        }
    }
}

private extension Chat.Activity.AwaitingAction {
    var badgeText: String {
        switch self {
        case .approval: L10n.string("Approve")
        case .reply: L10n.string("Reply")
        case .signIn: L10n.string("Sign in")
        case .verification: L10n.string("Verify")
        case .payment: L10n.string("Pay")
        }
    }

    var accessibilityValue: String {
        switch self {
        case .approval: L10n.string("Awaiting approval")
        case .reply: L10n.string("Awaiting reply")
        case .signIn: L10n.string("Awaiting sign in")
        case .verification: L10n.string("Awaiting verification")
        case .payment: L10n.string("Awaiting payment")
        }
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    let isActive: Bool
    let edgeInset: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let tinted = isActive || configuration.isPressed
        return configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Colors.onSurface.opacity(tinted ? 0.08 : 0))
            }
            .padding(.horizontal, edgeInset - Theme.Spacing.sm)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
    }
}
