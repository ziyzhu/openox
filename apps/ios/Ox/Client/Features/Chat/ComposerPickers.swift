import SwiftUI

struct ComposerServicePicker: View {
    @Bindable var composer: ChatComposerModel
    let excludedDomains: Set<String>
    let composerHeight: CGFloat
    let onSelect: (Service) -> Void
    let onExplore: () -> Void

    @ViewBuilder
    var body: some View {
        if case .mention(let query) = composer.surface {
            GeometryReader { geometry in
                ServicePickerPanel(
                    query: query,
                    excludedDomains: excludedDomains,
                    space: max(0, geometry.size.height - composerHeight),
                    onSelect: onSelect,
                    onExplore: onExplore
                )
                .frame(maxWidth: Theme.ContainerWidth.readable)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, composerHeight + Theme.Spacing.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

struct ComposerSlashPicker: View {
    @Bindable var composer: ChatComposerModel
    let isFocused: Bool
    let composerHeight: CGFloat
    let onSelect: (Skill) -> Void

    @ViewBuilder
    var body: some View {
        let suggestions = isFocused ? composer.slashSuggestions : []
        Group {
            if !suggestions.isEmpty {
                GeometryReader { geometry in
                    SlashPickerPanel(
                        suggestions: suggestions,
                        space: max(0, geometry.size.height - composerHeight),
                        onSelect: onSelect
                    )
                    .frame(maxWidth: Theme.ContainerWidth.readable)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, composerHeight + Theme.Spacing.xs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.standard, value: suggestions.map(\.id))
    }
}

struct ComposerAttachMenu: View {
    let onChoice: (AttachmentChoice) -> Void
    let onServices: () -> Void

    var body: some View {
        AttachMenuCard(
            onChoice: onChoice,
            onServices: onServices
        )
        .accessibilityElement(children: .contain)
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
            row("Services", icon: .action(.services), a11yID: A11yID.Chat.Attach.services, action: onServices)
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
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 30

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
        Button(action: onExplore) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text("Services")
                    .font(Theme.Fonts.labelMd)
                Spacer(minLength: 0)
                OxActionIcon(.services, size: 20)
            }
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Services")
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
                    Text("No services found")
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
            ServiceAvatar(service: match.service, size: 24, shape: .roundedRect(Theme.Radius.sm))
            Text(match.service.title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .frame(minHeight: rowHeight)
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
                let lhsRank = ServiceListOrder.rank(lhs.element.service.domain)
                let rhsRank = ServiceListOrder.rank(rhs.element.service.domain)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
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
