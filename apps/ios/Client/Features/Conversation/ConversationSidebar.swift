import SwiftUI

struct ConversationSidebar: View {
    enum ContentState {
        case loading
        case unavailable
        case ready
    }

    let contentState: ContentState
    let actionsEnabled: Bool
    let summaries: [ConversationMeta]
    let canLoadMore: Bool
    let activities: [UUID: Conversation.Activity]
    let currentId: UUID?
    let onLoadMore: () async -> Void
    let onSearch: () async -> Void
    let onNewConversation: () -> Void
    let onOpen: (ConversationMeta) -> Void
    let onDelete: (ConversationMeta) -> Void
    let onRename: (ConversationMeta, String) -> Void
    let onToggleFavorite: (ConversationMeta) -> Void
    let onSettings: () -> Void

    private let edgeInset = Theme.Spacing.lg
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var renaming: ConversationMeta?
    @State private var pendingDelete: ConversationMeta?
    @State private var lastDeletedID: UUID?
    @State private var titleDraft = ""
    @State private var searchQuery = ""
    @State private var searchPresented = false
    @State private var visibleCount = 20

    private let pageSize = 20

    var body: some View {
        NavigationStack {
            list
                .accessibilityIdentifier(A11yID.Sidebar.panel)
                .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) { header }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.Colors.conversationSurface.opacity(horizontalSizeClass == .compact ? 0 : 1), ignoresSafeAreaEdges: .all)
                .containerBackground(Theme.Colors.conversationSurface.opacity(horizontalSizeClass == .compact ? 0 : 1), for: .navigation)
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { settingsButton }
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { newConversationButton }
                }
                .toolbarVisibility(horizontalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
        }
        .oxSearchable(
            text: $searchQuery,
            isPresented: $searchPresented,
            placement: .toolbar,
            prompt: Text(A11yLabel.searchConversations),
            accessibilityIdentifier: A11yID.Sidebar.search
        )
        .onChange(of: searchQuery) { _, _ in visibleCount = pageSize }
        .task(id: searchPresented) {
            guard searchPresented else { return }
            await onSearch()
        }
        .alert(A11yLabel.renameConversation, isPresented: Binding(
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
        .alert("Delete this conversation?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                guard let meta = pendingDelete else { return }
                pendingDelete = nil
                lastDeletedID = meta.id
                onDelete(meta)
            }
        } message: {
            Text("This removes the conversation from your history. This can't be undone.")
        }
    }

    private var newConversationButton: some View {
        Button {
            searchPresented = false
            onNewConversation()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(.body, weight: .semibold))
        }
        .accessibilityLabel(A11yLabel.newConversation)
        .accessibilityIdentifier(A11yID.Sidebar.newConversation)
        .disabled(!actionsEnabled)
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
        .disabled(!actionsEnabled)
    }

    private var header: some View {
        Text("Conversations")
            .font(Theme.Fonts.headline)
            .foregroundStyle(Theme.Colors.onSurface)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(A11yID.Sidebar.title)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, edgeInset)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var list: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty
            ? summaries
            : summaries.filter { $0.displayTitle.localizedStandardContains(query) }
        let sorted = matching.sorted { $0.activityDate > $1.activityDate }
        let ordered = sorted.filter(\.isFavorite) + sorted.filter { !$0.isFavorite }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if contentState == .ready, ordered.isEmpty, !canLoadMore {
                    Text(LocalizedStringKey(query.isEmpty ? "Empty" : "No conversations found"))
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .padding(.horizontal, edgeInset)
                        .padding(.vertical, 11)
                } else if contentState == .ready {
                    if !query.isEmpty, canLoadMore { searchLoadingRow }
                    ForEach(ordered.prefix(visibleCount)) { row($0) }
                    if ordered.count > visibleCount || (canLoadMore && query.isEmpty) {
                        CellularAutomatonLoader.small
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.md)
                            .accessibilityLabel("Loading your conversations…")
                            .task {
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                if ordered.count > visibleCount {
                                    visibleCount = min(visibleCount + pageSize, ordered.count)
                                } else {
                                    await onLoadMore()
                                }
                            }
                            .id("\(query):\(visibleCount):\(ordered.count)")
                    }
                }
                Color.clear.frame(height: Theme.Spacing.md)
            }
            .animation(.smooth(duration: 0.35), value: lastDeletedID)
            .padding(.top, Theme.Spacing.xs)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if contentState == .loading {
                CellularAutomatonLoader()
                    .accessibilityLabel("Loading your conversations…")
            }
        }
    }

    private var searchLoadingRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader.small
                .frame(width: 20, height: 20)
            Text("Loading your conversations…")
                .font(Theme.Fonts.captionSm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .padding(.horizontal, edgeInset)
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private func row(_ meta: ConversationMeta) -> some View {
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
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier(A11yID.Sidebar.renameRow(meta.id.uuidString))
                Button(role: .destructive) {
                    pendingDelete = meta
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(A11yID.Sidebar.deleteRow(meta.id.uuidString))
            } preview: {
                ConversationContextMenuPreview(meta: meta)
            }
            .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.15))))
            .id(meta.id.uuidString)
    }

}

private struct SidebarRow: View {
    let meta: ConversationMeta
    let activity: Conversation.Activity
    let isActive: Bool
    let edgeInset: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(meta.displayTitle)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    TimelineView(.everyMinute) { context in
                        Text(verbatim: [lastModifiedText(relativeTo: context.date), agentName].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Theme.Spacing.sm) {
                    activityIndicator
                    if meta.scheduleID != nil {
                        Image(systemName: "clock")
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .buttonStyle(SidebarRowButtonStyle(isActive: isActive, edgeInset: edgeInset))
        .accessibilityLabel(meta.displayTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(A11yID.Sidebar.row(meta.id.uuidString))
    }

    private var agentName: String? {
        meta.remoteAgent.map { RemoteAgentDirectory.shared.displayName(for: $0.endpoint) }
    }

    private func lastModifiedText(relativeTo now: Date) -> String {
        var calendar = Calendar.current
        calendar.locale = AppLocale.resolvedLocale
        let isToday = calendar.isDate(meta.activityDate, inSameDayAs: now)
        let formatter = DateFormatter()
        formatter.locale = AppLocale.resolvedLocale
        formatter.dateStyle = isToday ? .none : .short
        formatter.timeStyle = isToday ? .short : .none
        return formatter.string(from: meta.activityDate)
    }

    private var accessibilityValue: String {
        let activity = activityAccessibilityValue
        let lastModified = lastModifiedText(relativeTo: Date())
        return [favoriteAccessibilityValue, agentName ?? "", lastModified, scheduledAccessibilityValue, activity]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var favoriteAccessibilityValue: String {
        meta.isFavorite ? L10n.string("Pinned") : ""
    }

    private var scheduledAccessibilityValue: String {
        meta.scheduleID == nil ? "" : L10n.string("Scheduled")
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
        case .idle(.stopped):
            Text("Stopped")
                .font(Theme.Fonts.captionSm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .lineLimit(1)
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
        case .idle(.stopped): L10n.string("Stopped")
        case .running(.thinking), .running(.streaming): L10n.string("Plowing")
        case .running(.awaiting(let action)): action.accessibilityValue
        }
    }
}

private extension Conversation.Activity.AwaitingAction {
    var badgeText: String {
        switch self {
        case .approval: L10n.string("Approve")
        case .reply: L10n.string("Reply")
        case .login: L10n.string("Log in")
        case .verification: L10n.string("Verify")
        case .payment: L10n.string("Pay")
        }
    }

    var accessibilityValue: String {
        switch self {
        case .approval: L10n.string("Awaiting approval")
        case .reply: L10n.string("Awaiting reply")
        case .login: L10n.string("Awaiting log in")
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
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Colors.onSurface.opacity(tinted ? 0.08 : 0))
            }
            .padding(.horizontal, edgeInset - Theme.Spacing.sm)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
    }
}
